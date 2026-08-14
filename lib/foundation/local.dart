import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/async_retry.dart';
import 'package:venera/utils/atomic_file.dart';
import 'package:venera/utils/coalescing_async_writer.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/maintenance_coordinator.dart';

import 'app.dart';
import 'history.dart';

/// Adds indexes for the local-library queries run by the home and library
/// pages. Local entries are relatively cheap to update, while these ordered
/// reads happen on every listener-driven rebuild.
@visibleForTesting
void ensureLocalLibraryPerformanceIndexes(Database database) {
  database.execute('''
    CREATE INDEX IF NOT EXISTS local_comics_created_at_index
    ON comics(created_at DESC);
  ''');
  database.execute('''
    CREATE INDEX IF NOT EXISTS local_comics_title_index
    ON comics(title);
  ''');
  database.execute('''
    CREATE INDEX IF NOT EXISTS local_comics_directory_index
    ON comics(directory);
  ''');
}

@visibleForTesting
final class DownloadQueueRestoreFailure {
  const DownloadQueueRestoreFailure(this.index, this.error, this.stackTrace);

  final int index;
  final Object error;
  final StackTrace stackTrace;
}

@visibleForTesting
final class DownloadQueueRestoreResult<T> {
  const DownloadQueueRestoreResult._({
    required this.tasks,
    required this.failures,
    this.documentError,
    this.documentStackTrace,
  });

  final List<T> tasks;
  final List<DownloadQueueRestoreFailure> failures;
  final Object? documentError;
  final StackTrace? documentStackTrace;

  bool get requiresFileQuarantine => documentError != null;
}

/// Decodes one persisted queue snapshot without letting a malformed task hide
/// valid tasks that follow it. A document-level error is kept separate so the
/// caller can quarantine the original snapshot instead of deleting it.
@visibleForTesting
DownloadQueueRestoreResult<T> decodeDownloadingTaskQueue<T>(
  String contents,
  T? Function(Map<String, dynamic> json) decodeTask,
) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(contents);
  } catch (error, stackTrace) {
    return DownloadQueueRestoreResult<T>._(
      tasks: const [],
      failures: const [],
      documentError: error,
      documentStackTrace: stackTrace,
    );
  }

  if (decoded is! List<dynamic>) {
    return DownloadQueueRestoreResult<T>._(
      tasks: const [],
      failures: const [],
      documentError: const FormatException(
        'Downloading task queue must be a JSON array.',
      ),
      documentStackTrace: StackTrace.current,
    );
  }

  final tasks = <T>[];
  final failures = <DownloadQueueRestoreFailure>[];
  for (var index = 0; index < decoded.length; index++) {
    try {
      final entry = decoded[index];
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Downloading task must be a JSON object.');
      }
      final task = decodeTask(Map<String, dynamic>.from(entry));
      if (task == null) {
        throw const FormatException('Unsupported downloading task type.');
      }
      tasks.add(task);
    } catch (error, stackTrace) {
      failures.add(DownloadQueueRestoreFailure(index, error, stackTrace));
    }
  }

  return DownloadQueueRestoreResult<T>._(
    tasks: List<T>.unmodifiable(tasks),
    failures: List<DownloadQueueRestoreFailure>.unmodifiable(failures),
  );
}

const localPathMigrationJournalFileName = '.venera-local-path-migration.json';

File localPathMigrationJournalFile(String dataPath) =>
    File(FilePath.join(dataPath, localPathMigrationJournalFileName));

enum _LocalPathMigrationPhase {
  copying,
  copied,
  committing,
  pathCommitted,
  rollingBack,
}

final class _LocalPathMigrationJournal {
  _LocalPathMigrationJournal._(
    this.file,
    this.oldPath,
    this.newPath,
    this.operationId,
  );

  static const version = 1;

  final File file;
  final String oldPath;
  final String newPath;
  final String operationId;

  static Future<_LocalPathMigrationJournal> begin({
    required String dataPath,
    required String oldPath,
    required String newPath,
  }) async {
    final file = localPathMigrationJournalFile(dataPath);
    if (await file.exists()) {
      throw StateError(
        'An unfinished storage migration must be recovered first',
      );
    }
    final journal = _LocalPathMigrationJournal._(
      file,
      oldPath,
      newPath,
      '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}',
    );
    await journal.writePhase(_LocalPathMigrationPhase.copying);
    return journal;
  }

  Future<void> writePhase(_LocalPathMigrationPhase phase) {
    return writeStringAtomically(
      file,
      jsonEncode({
        'version': version,
        'operationId': operationId,
        'phase': phase.name,
        'oldPath': oldPath,
        'newPath': newPath,
      }),
    );
  }

  Future<void> finish() async {
    if (await file.exists()) await file.delete();
  }
}

/// Reconciles a storage-root migration before LocalManager opens local.db or
/// restores the downloading queue.
///
/// `local_path` is the commit record: a crash before it changes rolls all
/// persisted paths back to [oldPath], while a crash after it changes completes
/// rebasing to [newPath]. Both physical roots are deliberately retained during
/// startup recovery; deleting a user-visible directory is never required to
/// make metadata consistent again.
Future<void> recoverInterruptedLocalPathMigration(String dataPath) async {
  final journalFile = localPathMigrationJournalFile(dataPath);
  if (!await journalFile.exists()) return;
  final decoded = jsonDecode(await journalFile.readAsString());
  if (decoded is! Map<String, dynamic> ||
      decoded['version'] != _LocalPathMigrationJournal.version ||
      decoded['operationId'] is! String ||
      !(RegExp(
        r'^[A-Za-z0-9._-]+$',
      ).hasMatch(decoded['operationId'] as String)) ||
      decoded['phase'] is! String ||
      decoded['oldPath'] is! String ||
      decoded['newPath'] is! String) {
    throw const FormatException('Invalid local path migration journal');
  }
  final oldPath = decoded['oldPath'] as String;
  final newPath = decoded['newPath'] as String;
  if (oldPath.isEmpty ||
      newPath.isEmpty ||
      FilePath.isSameOrWithin(oldPath, newPath) ||
      FilePath.isSameOrWithin(newPath, oldPath)) {
    throw const FormatException('Unsafe local path migration journal');
  }
  final phase = _LocalPathMigrationPhase.values.firstWhere(
    (value) => value.name == decoded['phase'],
    orElse: () =>
        throw const FormatException('Unknown local path migration phase'),
  );
  final configuredPathFile = File(FilePath.join(dataPath, 'local_path'));
  var configuredPath = '';
  if (await configuredPathFile.exists()) {
    configuredPath = await configuredPathFile.readAsString();
  }
  final completeNewPath =
      phase == _LocalPathMigrationPhase.pathCommitted ||
      (phase == _LocalPathMigrationPhase.committing &&
          configuredPath == newPath);
  final targetPath = completeNewPath ? newPath : oldPath;
  final sourcePath = completeNewPath ? oldPath : newPath;
  if (!await Directory(targetPath).exists()) {
    throw FileSystemException(
      'Storage migration recovery target is unavailable',
      targetPath,
    );
  }

  _rebaseLocalComicDatabase(
    File(FilePath.join(dataPath, 'local.db')),
    sourcePath,
    targetPath,
  );
  await _rebasePersistedDownloadingTasks(
    File(FilePath.join(dataPath, 'downloading_tasks.json')),
    sourcePath,
    targetPath,
  );
  await writeStringAtomically(configuredPathFile, targetPath);
  await journalFile.delete();
}

void _rebaseLocalComicDatabase(
  File databaseFile,
  String sourcePath,
  String targetPath,
) {
  if (!databaseFile.existsSync()) return;
  final database = sqlite3.open(databaseFile.path);
  try {
    final hasComicsTable = database
        .select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'comics';",
        )
        .isNotEmpty;
    if (!hasComicsTable) return;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = database.select(
        'SELECT id, comic_type, directory FROM comics;',
      );
      for (final row in rows) {
        final directory = row[2] as String;
        final rebased = FilePath.rebaseWithin(
          sourcePath,
          targetPath,
          directory,
        );
        if (rebased == null || rebased == directory) continue;
        database.execute(
          'UPDATE comics SET directory = ? '
          'WHERE id = ? AND comic_type = ?;',
          [rebased, row[0], row[1]],
        );
      }
      database.execute('COMMIT;');
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    }
  } finally {
    database.dispose();
  }
}

Future<void> _rebasePersistedDownloadingTasks(
  File queueFile,
  String sourcePath,
  String targetPath,
) async {
  if (!await queueFile.exists()) return;
  final decoded = jsonDecode(await queueFile.readAsString());
  if (decoded is! List) {
    throw const FormatException('Downloading task queue must be a JSON array');
  }
  var changed = false;
  for (final value in decoded) {
    if (value is! Map || value['path'] is! String) continue;
    final currentPath = value['path'] as String;
    final rebased = FilePath.rebaseWithin(sourcePath, targetPath, currentPath);
    if (rebased == null || rebased == currentPath) continue;
    value['path'] = rebased;
    changed = true;
  }
  if (changed) {
    await writeStringAtomically(queueFile, jsonEncode(decoded));
  }
}

File _quarantineInvalidDownloadQueue(File file) {
  final suffix = DateTime.now().toUtc().millisecondsSinceEpoch;
  var candidate = File('${file.path}.corrupt-$suffix');
  var collision = 1;
  while (candidate.existsSync()) {
    candidate = File('${file.path}.corrupt-$suffix-$collision');
    collision++;
  }
  return file.renameSync(candidate.path);
}

final class LocalComicDirectoryMissingException implements Exception {
  const LocalComicDirectoryMissingException(this.path);

  final String path;

  @override
  String toString() => 'Local comic directory does not exist: $path';
}

String? _localComicParentPath(String path) {
  var normalized = path.replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    if (RegExp(r'^[A-Za-z]:/$').hasMatch(normalized)) break;
    normalized = normalized.substring(0, normalized.length - 1);
  }

  final separator = normalized.lastIndexOf('/');
  if (normalized.startsWith('android://')) {
    // Never climb above the granted document path into the synthetic
    // `android://` root. Its existence does not prove that this grant/storage
    // is currently reachable.
    if (separator < 'android://'.length) return null;
    return normalized.substring(0, separator);
  }
  if (separator < 0) return null;
  if (separator == 0) return '/';
  if (separator == 2 && RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
    return normalized.substring(0, separator + 1);
  }
  return normalized.substring(0, separator);
}

/// Whether a missing comic/chapter path is conclusively absent rather than
/// hidden by temporarily unavailable storage.
///
/// Relative comic directories belong to [configuredLibraryPath], while
/// absolute and SAF-backed comics use their own parent. This avoids treating
/// an unrelated, accessible library root as proof that an absolute SD/SAF path
/// was deleted.
Future<bool> isLocalComicDirectoryDefinitelyMissing({
  required String comicDirectory,
  required String comicBaseDir,
  required String configuredLibraryPath,
  required bool hasChapters,
  Future<bool> Function(String path)? directoryExists,
}) async {
  final anchors = <String>[];
  if (hasChapters) {
    anchors.add(comicBaseDir);
  }
  final isLibraryRelative =
      !comicDirectory.contains('/') && !comicDirectory.contains('\\');
  if (isLibraryRelative) {
    anchors.add(configuredLibraryPath);
  } else {
    final parent = _localComicParentPath(comicBaseDir);
    if (parent != null) anchors.add(parent);
  }

  final exists = directoryExists ?? (path) => Directory(path).exists();
  for (final anchor in anchors.toSet()) {
    try {
      if (await exists(anchor)) return true;
    } catch (_) {
      // An inaccessible evidence path cannot prove deletion.
    }
  }
  return false;
}

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  LocalComic.fromRow(Row row)
    : id = row[0] as String,
      title = row[1] as String,
      subtitle = row[2] as String,
      tags = List.from(jsonDecode(row[3] as String)),
      directory = row[4] as String,
      chapters = ComicChapters.fromJsonOrNull(jsonDecode(row[5] as String)),
      cover = row[6] as String,
      comicType = ComicType(row[7] as int),
      downloadedChapters = List.from(jsonDecode(row[8] as String)),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row[9] as int);

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  @override
  String get description => "";

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  late final CoalescingAsyncWriter<String> _downloadingTaskWriter =
      CoalescingAsyncWriter<String>((contents) {
        return writeStringAtomically(
          File(FilePath.join(App.dataPath, 'downloading_tasks.json')),
          contents,
        );
      });

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  bool _isChangingPath = false;

  bool _downloadQueueResumeDeferred = false;

  void _resumeDownloadQueueOrDefer() {
    if (downloadingTasks.isEmpty) return;
    if (_isChangingPath) {
      _downloadQueueResumeDeferred = true;
      return;
    }
    downloadingTasks.first.resume();
  }

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) {
    if (_isChangingPath) {
      return Future.value('Storage path migration is already in progress');
    }
    final maintenance = MaintenanceCoordinator.instance;
    if (maintenance.isActive) {
      return Future.value('Another data maintenance operation is in progress');
    }
    return maintenance.run('Move Local Comics', () => _setNewPath(newPath));
  }

  Future<String?> _setNewPath(String newPath) async {
    if (_isChangingPath) return "Storage path migration is already in progress";
    _isChangingPath = true;
    try {
      if (FilePath.isSameOrWithin(path, newPath)) {
        return "New directory cannot be inside the current directory";
      }
      var newDir = Directory(newPath);
      if (!await newDir.exists()) {
        return "Directory does not exist";
      }
      if (!await newDir.list().isEmpty) {
        return "Directory is not empty";
      }

      final oldPath = path;
      final oldDirectory = directory;
      final taskSnapshot = List<DownloadTask>.of(downloadingTasks);
      final queueWasRunning = taskSnapshot.firstOrNull?.isPaused == false;
      final previousTaskPaths = HashMap<DownloadTask, String?>.identity();
      final previousComicDirectories =
          <({String id, int comicType, String directory})>[];
      final configuredPathFile = File(
        FilePath.join(App.dataPath, 'local_path'),
      );

      void resumeQueueIfNeeded() {
        if (queueWasRunning) _resumeDownloadQueueOrDefer();
      }

      try {
        await Future.wait(taskSnapshot.map((task) => task.pauseAndWait()));
      } catch (e, s) {
        Log.error('IO', 'Failed to pause downloads for migration: $e', s);
        resumeQueueIfNeeded();
        return e.toString();
      }

      late final _LocalPathMigrationJournal migrationJournal;
      try {
        migrationJournal = await _LocalPathMigrationJournal.begin(
          dataPath: App.dataPath,
          oldPath: oldPath,
          newPath: newPath,
        );
      } catch (e, s) {
        Log.error(
          'IO',
          'Failed to start the storage path migration journal: $e',
          s,
        );
        resumeQueueIfNeeded();
        return e.toString();
      }

      try {
        await copyDirectoryIsolate(oldDirectory, newDir);
        await migrationJournal.writePhase(_LocalPathMigrationPhase.copied);
      } catch (e, s) {
        Log.error("IO", e, s);
        await newDir.deleteContents(recursive: true).catchError((_) {});
        try {
          await migrationJournal.finish();
        } catch (journalError, journalStackTrace) {
          Log.error(
            'IO',
            'Failed to clear the aborted storage migration journal: '
                '$journalError',
            journalStackTrace,
          );
        }
        resumeQueueIfNeeded();
        return e.toString();
      }

      try {
        await migrationJournal.writePhase(_LocalPathMigrationPhase.committing);
        for (final task in downloadingTasks) {
          final taskPath = task.path;
          if (taskPath == null) continue;
          final rebased = FilePath.rebaseWithin(oldPath, newPath, taskPath);
          if (rebased != null && rebased != taskPath) {
            previousTaskPaths[task] = taskPath;
            task.path = rebased;
          }
        }
        final comicRows = _db.select(
          'SELECT id, comic_type, directory FROM comics;',
        );
        for (final row in comicRows) {
          final id = row[0] as String;
          final comicType = row[1] as int;
          final comicDirectory = row[2] as String;
          final rebased = FilePath.rebaseWithin(
            oldPath,
            newPath,
            comicDirectory,
          );
          if (rebased == null || rebased == comicDirectory) continue;
          previousComicDirectories.add((
            id: id,
            comicType: comicType,
            directory: comicDirectory,
          ));
          _db.execute(
            'UPDATE comics SET directory = ? '
            'WHERE id = ? AND comic_type = ?;',
            [rebased, id, comicType],
          );
        }
        await saveCurrentDownloadingTasks();
        await writeStringAtomically(configuredPathFile, newPath);
      } catch (e, s) {
        Log.error('IO', 'Failed to commit storage path migration: $e', s);
        var configuredPathIsNew = false;
        try {
          configuredPathIsNew =
              await configuredPathFile.exists() &&
              await configuredPathFile.readAsString() == newPath;
        } catch (readError, readStackTrace) {
          Log.error(
            'IO',
            'Failed to read the storage path commit record: $readError',
            readStackTrace,
          );
        }
        if (configuredPathIsNew) {
          // The path file is the durable commit record. An atomic path write
          // may report a late cleanup error after the rename itself already
          // succeeded; rolling back from that state could make crash recovery
          // choose the opposite direction.
          Log.error(
            'IO',
            'The storage path commit record is already durable; completing '
                'the migration despite the late error.',
          );
        } else {
          try {
            await migrationJournal.writePhase(
              _LocalPathMigrationPhase.rollingBack,
            );
          } catch (journalError, journalStackTrace) {
            // With local_path still pointing at the old root, every earlier
            // journal phase also selects rollback during startup recovery.
            Log.error(
              'IO',
              'Failed to record storage migration rollback: $journalError',
              journalStackTrace,
            );
          }
          var durableRollbackSucceeded = true;
          for (final entry in previousTaskPaths.entries) {
            if (downloadingTasks.any((task) => identical(task, entry.key))) {
              entry.key.path = entry.value;
            }
          }
          for (final comic in previousComicDirectories.reversed) {
            try {
              _db.execute(
                'UPDATE comics SET directory = ? '
                'WHERE id = ? AND comic_type = ?;',
                [comic.directory, comic.id, comic.comicType],
              );
            } catch (restoreError, restoreStackTrace) {
              durableRollbackSucceeded = false;
              Log.error(
                'IO',
                'Failed to restore a local comic path after migration: '
                    '$restoreError',
                restoreStackTrace,
              );
            }
          }
          try {
            await saveCurrentDownloadingTasks();
          } catch (restoreError, restoreStackTrace) {
            durableRollbackSucceeded = false;
            Log.error(
              'IO',
              'Failed to restore download paths after migration: $restoreError',
              restoreStackTrace,
            );
          }
          try {
            await writeStringAtomically(configuredPathFile, oldPath);
          } catch (restoreError, restoreStackTrace) {
            durableRollbackSucceeded = false;
            Log.error(
              'IO',
              'Failed to restore the configured storage path after migration: '
                  '$restoreError',
              restoreStackTrace,
            );
          }
          if (durableRollbackSucceeded) {
            await newDir.deleteContents(recursive: true).catchError((_) {});
            try {
              await migrationJournal.finish();
            } catch (journalError, journalStackTrace) {
              Log.error(
                'IO',
                'Failed to clear the rolled-back storage migration journal: '
                    '$journalError',
                journalStackTrace,
              );
            }
          } else {
            Log.error(
              'IO',
              'Storage migration rollback was not fully persisted; preserving '
                  'the new directory at $newPath to avoid data loss.',
            );
          }
          resumeQueueIfNeeded();
          return e.toString();
        }
      }

      try {
        await migrationJournal.writePhase(
          _LocalPathMigrationPhase.pathCommitted,
        );
      } catch (journalError, journalStackTrace) {
        // local_path already selects the new root. Leaving an older
        // `committing` phase is safe because startup uses that commit record.
        Log.error(
          'IO',
          'Failed to advance the storage migration journal: $journalError',
          journalStackTrace,
        );
      }
      path = newPath;
      notifyListeners();
      try {
        _checkNoMedia();
      } catch (error, stackTrace) {
        Log.error(
          'IO',
          'Failed to create .nomedia after migration: $error',
          stackTrace,
        );
      }
      try {
        await oldDirectory.deleteContents(recursive: true);
      } catch (error, stackTrace) {
        // The new root and persisted queue are already committed. Keeping an
        // old duplicate is safer than rolling back to a directory that may
        // have become unavailable between copy and cleanup.
        Log.error(
          'IO',
          'Failed to clean the previous storage path: $error',
          stackTrace,
        );
      }
      try {
        await migrationJournal.finish();
      } catch (journalError, journalStackTrace) {
        Log.error(
          'IO',
          'Failed to clear the committed storage migration journal: '
              '$journalError',
          journalStackTrace,
        );
      }
      resumeQueueIfNeeded();
      return null;
    } finally {
      _isChangingPath = false;
      if (_downloadQueueResumeDeferred) {
        _downloadQueueResumeDeferred = false;
        _resumeDownloadQueueOrDefer();
      }
    }
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  static const _pathValidationAttempts = 4;

  Future<void> _checkPathValidation({required bool createIfMissing}) async {
    final targetPath = path;
    try {
      await retryAsync<void>(
        (_) => Isolate.run(
          () => overrideIO(() {
            final targetDirectory = Directory(targetPath);
            if (!targetDirectory.existsSync()) {
              if (!createIfMissing) {
                throw FileSystemException(
                  'Configured local comic directory is unavailable',
                  targetPath,
                );
              }
              targetDirectory.createSync(recursive: true);
            }

            final testFile = File(
              FilePath.join(targetPath, '.venera_write_test'),
            );
            try {
              testFile.writeAsBytesSync(const [0x56], flush: true);
              final persistedBytes = testFile.readAsBytesSync();
              if (persistedBytes.length != 1 || persistedBytes.single != 0x56) {
                throw FileSystemException(
                  'Cannot write to local comic directory',
                  targetPath,
                );
              }
            } finally {
              if (testFile.existsSync()) {
                testFile.deleteSync();
              }
            }
          }),
        ),
        maxAttempts: _pathValidationAttempts,
        delayForAttempt: (failedAttempt) =>
            Duration(milliseconds: 100 << (failedAttempt - 1)),
      );
    } catch (error, stackTrace) {
      Log.error(
        "IO",
        "Local comic path remains configured but is unavailable: "
            "$targetPath\n$error",
        stackTrace,
      );
      Error.throwWithStackTrace(
        FileSystemException(
          'Local comic directory is unavailable after '
          '$_pathValidationAttempts attempts: $error',
          targetPath,
        ),
        stackTrace,
      );
    }
  }

  Future<void> init() async {
    _db = sqlite3.open('${App.dataPath}/local.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    ensureLocalLibraryPerformanceIndexes(_db);
    final configuredPathFile = File(FilePath.join(App.dataPath, 'local_path'));
    final hasConfiguredPath = await configuredPathFile.exists();
    if (hasConfiguredPath) {
      path = await configuredPathFile.readAsString();
      if (path.isEmpty) {
        throw FileSystemException(
          'Configured local comic path is empty',
          configuredPathFile.path,
        );
      }
    } else {
      path = await findDefaultPath();
    }
    await _checkPathValidation(createIfMissing: !hasConfiguredPath);
    _checkNoMedia();
    await ComicSourceManager().ensureInit();
    restoreDownloadingTasks();
  }

  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse((res.first[0])) + 1).toString();
  }

  /// Inserts a newly imported comic without replacing an existing row.
  ///
  /// The id is allocated and inserted synchronously inside the caller's local
  /// database transaction. This is intentionally separate from [add], whose
  /// update semantics use `INSERT OR REPLACE` for download progress merging.
  String insertImportedNew(LocalComic comic) {
    final id = findValidId(comic.comicType);
    _db.execute(
      '''
      INSERT INTO comics (
        id, title, subtitle, tags, directory, chapters, cover, comic_type,
        downloadedChapters, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(comic.downloadedChapters),
        comic.createdAt.millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  /// Removes only the row created by an import receipt.
  ///
  /// Matching the unique published directory prevents compensation from
  /// deleting a different comic that later acquired the same numeric id.
  bool removeImported(
    String id,
    ComicType comicType,
    String expectedDirectory,
  ) {
    _db.execute(
      'DELETE FROM comics '
      'WHERE id = ? AND comic_type = ? AND directory = ?;',
      [id, comicType.value, expectedDirectory],
    );
    final removed = (_db.select('SELECT changes();').first[0] as int) > 0;
    if (removed) notifyListeners();
    return removed;
  }

  /// Runs a synchronous import batch in one SQLite savepoint.
  T runInTransaction<T>(T Function() operation) {
    _db.execute('SAVEPOINT venera_local_import_batch;');
    try {
      final result = operation();
      if (result is Future) {
        throw StateError('Local database transactions must be synchronous');
      }
      _db.execute('RELEASE SAVEPOINT venera_local_import_batch;');
      notifyListeners();
      return result;
    } catch (_) {
      try {
        _db.execute('ROLLBACK TO SAVEPOINT venera_local_import_batch;');
      } finally {
        _db.execute('RELEASE SAVEPOINT venera_local_import_batch;');
        notifyListeners();
      }
      rethrow;
    }
  }

  void add(LocalComic comic, [String? id]) {
    var old = find(id ?? comic.id, comic.comicType);
    var downloaded = comic.downloadedChapters;
    if (old != null) {
      downloaded.addAll(old.downloadedChapters);
    }
    _db.execute(
      'INSERT OR REPLACE INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded),
        comic.createdAt.millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
  }

  void remove(String id, ComicType comicType) {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    var res = _db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    _db.dispose();
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAt(ep - 1)
          : (ep as String);
      cid = getChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    if (!await directory.exists()) {
      if (await isLocalComicDirectoryDefinitelyMissing(
        comicDirectory: comic.directory,
        comicBaseDir: comic.baseDir,
        configuredLibraryPath: path,
        hasChapters: comic.hasChapters,
      )) {
        throw LocalComicDirectoryMissingException(directory.path);
      }
      throw FileSystemException(
        'Local comic storage is unavailable',
        directory.path,
      );
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        if (!isSupportedComicImage(entity)) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  /// Invalidates stale downloaded metadata without deleting files from disk.
  ///
  /// The reader uses this when the database says a network chapter is local,
  /// but its directory is missing or contains no readable images. Keeping the
  /// files untouched lets users inspect or recover a partially downloaded
  /// directory while allowing the reader to fall back to the network source.
  /// Chapterless downloads are represented by the comic row itself, so their
  /// stale row must be removed instead of updating an empty chapter list.
  void invalidateDownloadedContent(String id, ComicType type, int ep) {
    final comic = find(id, type);
    if (comic == null) return;
    if (comic.chapters == null) {
      if (comic.comicType == ComicType.local) return;
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        id,
        type.value,
      ]);
      notifyListeners();
      return;
    }
    final chapterId = comic.chapters!.ids.elementAtOrNull(ep - 1);
    if (chapterId == null) return;
    final downloaded = comic.downloadedChapters
        .where((chapter) => chapter != chapterId)
        .toList();
    _db.execute(
      'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
      [jsonEncode(downloaded), id, type.value],
    );
    notifyListeners();
  }

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(comic.baseDir);
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    add(task.toLocalComic());
    downloadingTasks.remove(task);
    notifyListeners();
    scheduleCurrentDownloadingTasksSave();
    _resumeDownloadQueueOrDefer();
  }

  void removeTask(DownloadTask task) {
    final wasCurrent = downloadingTasks.firstOrNull == task;
    downloadingTasks.remove(task);
    notifyListeners();
    scheduleCurrentDownloadingTasksSave();
    if (wasCurrent) {
      _resumeDownloadQueueOrDefer();
    }
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      scheduleCurrentDownloadingTasksSave();
      if (shouldResume) {
        _resumeDownloadQueueOrDefer();
      }
    }
  }

  Future<void> saveCurrentDownloadingTasks() async {
    final tasks = downloadingTasks.map((task) => task.toJson()).toList();
    await _downloadingTaskWriter.schedule(jsonEncode(tasks));
  }

  /// Persists the latest queue state without exposing fire-and-forget write
  /// failures as unhandled asynchronous errors.
  void scheduleCurrentDownloadingTasksSave() {
    unawaited(
      saveCurrentDownloadingTasks().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        Log.error(
          'LocalManager',
          'Failed to persist download queue: $error',
          stackTrace,
        );
      }),
    );
  }

  void restoreDownloadingTasks() {
    final file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (!file.existsSync()) return;

    late final String contents;
    try {
      contents = file.readAsStringSync();
    } catch (error, stackTrace) {
      Log.error(
        'LocalManager',
        'Failed to read downloading tasks: $error',
        stackTrace,
      );
      return;
    }

    final restored = decodeDownloadingTaskQueue<DownloadTask>(
      contents,
      DownloadTask.fromJson,
    );
    if (restored.requiresFileQuarantine) {
      String? quarantinedPath;
      try {
        quarantinedPath = _quarantineInvalidDownloadQueue(file).path;
      } catch (error, stackTrace) {
        Log.error(
          'LocalManager',
          'Failed to quarantine invalid downloading task queue: $error',
          stackTrace,
        );
      }
      final disposition = quarantinedPath == null
          ? 'The original file was kept in place.'
          : 'The original file was moved to $quarantinedPath.';
      Log.error(
        'LocalManager',
        'Failed to parse downloading task queue: '
            '${restored.documentError}. $disposition',
        restored.documentStackTrace,
      );
      return;
    }

    downloadingTasks.addAll(restored.tasks);
    for (final failure in restored.failures) {
      Log.error(
        'LocalManager',
        'Skipped invalid downloading task at index ${failure.index}: '
            '${failure.error}',
        failure.stackTrace,
      );
    }
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    scheduleCurrentDownloadingTasksSave();
    _resumeDownloadQueueOrDefer();
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      _scheduleDirectoryDeletion([c.baseDir]);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    notifyListeners();
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    var shouldRemovedDirs = <String>[];
    for (var chapter in chapters) {
      shouldRemovedDirs.add(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
      );
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _scheduleDirectoryDeletion(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <String>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          shouldRemovedDirs.add(c.baseDir);
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _scheduleDirectoryDeletion(shouldRemovedDirs);
    }
  }

  static void _scheduleDirectoryDeletion(List<String> directoryPaths) {
    deleteDirectories(directoryPaths).then(
      (errors) {
        for (final error in errors) {
          Log.error("LocalManager", error);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        Log.error(
          "LocalManager",
          "Failed to delete local files: $error",
          stackTrace,
        );
      },
    );
  }

  /// Deletes directories in a separate isolate to avoid blocking the UI.
  ///
  /// Only paths are sent to the isolate. In particular, an [AndroidDirectory]
  /// descriptor belongs to the isolate in which it was opened and must not be
  /// copied to another isolate. The directory is reopened under [overrideIO]
  /// after the isolate's SAF worker has started.
  static Future<List<String>> deleteDirectories(List<String> directoryPaths) {
    final paths = directoryPaths.toSet().toList(growable: false);
    if (paths.isEmpty) return Future.value(const <String>[]);
    return Isolate.run(() async {
      final worker = SAFTaskWorker();
      await worker.init();
      try {
        return await overrideIO(() async {
          final errors = <String>[];
          for (final path in paths) {
            try {
              final dir = Directory(path);
              if (await dir.exists()) {
                await dir.delete(recursive: true);
              }
            } catch (error) {
              errors.add("Failed to delete $path: $error");
            }
          }
          return errors;
        });
      } finally {
        worker.dispose();
      }
    });
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
