import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/import_transaction.dart';
import 'package:venera/utils/keyed_async_gate.dart';
import 'package:venera/utils/maintenance_coordinator.dart';
import 'package:venera/utils/zip_extraction.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

@visibleForTesting
Future<void> snapshotSqliteDatabase(
  String sourcePath,
  String destinationPath, {
  Database Function(String path)? openDatabase,
}) async {
  final sourceFile = File(sourcePath);
  if (!await sourceFile.exists()) {
    throw FileSystemException('SQLite database does not exist', sourcePath);
  }
  final destinationFile = File(destinationPath);
  await destinationFile.parent.create(recursive: true);
  await destinationFile.deleteIgnoreError();

  final opener = openDatabase ?? sqlite3.open;
  final source = opener(sourcePath);
  final destination = opener(destinationPath);
  try {
    await source.backup(destination, nPage: 100).drain<void>();
    _assertSqliteIntegrity(destination, destinationPath);
  } finally {
    destination.dispose();
    source.dispose();
  }
}

@visibleForTesting
void validateSqliteDatabase(
  String path, {
  Database Function(String path)? openDatabase,
  Iterable<String> requiredTables = const [],
}) {
  if (!File(path).existsSync()) {
    throw FileSystemException('SQLite database does not exist', path);
  }
  final database = (openDatabase ?? sqlite3.open)(path);
  try {
    _assertSqliteIntegrity(database, path);
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table';")
        .map((row) => row['name'] as String)
        .toSet();
    final missing = requiredTables.where((table) => !tables.contains(table));
    if (missing.isNotEmpty) {
      throw FileSystemException(
        'SQLite database is missing required tables: ${missing.join(', ')}',
        path,
      );
    }
  } finally {
    database.dispose();
  }
}

void _assertSqliteIntegrity(Database database, String path) {
  final rows = database.select('PRAGMA integrity_check;');
  if (rows.isEmpty ||
      rows.any((row) => row.values.first.toString().toLowerCase() != 'ok')) {
    throw FileSystemException('SQLite integrity check failed', path);
  }
}

@visibleForTesting
bool isSafeImportedSqliteIdentifier(Object? value) {
  return value is String &&
      value.isNotEmpty &&
      !value.contains('"') &&
      !value.contains('\u0000') &&
      !value.toLowerCase().startsWith('sqlite_');
}

@visibleForTesting
Future<void> prepareCloudSourceImport(
  Directory importedSourceDirectory,
  Directory liveSourceDirectory,
) async {
  if (!await importedSourceDirectory.exists()) return;
  await for (final entity in importedSourceDirectory.list()) {
    if (entity is File && entity.path.endsWith('.data')) {
      await entity.deleteIgnoreError();
    }
  }
  if (!await liveSourceDirectory.exists()) return;
  await for (final entity in liveSourceDirectory.list()) {
    if (entity is! File || !entity.path.endsWith('.data')) continue;
    final sourceKey = entity.name.substring(
      0,
      entity.name.length - '.data'.length,
    );
    if (await importedSourceDirectory.joinFile('$sourceKey.js').exists()) {
      await entity.copy(importedSourceDirectory.joinFile(entity.name).path);
    }
  }
}

/// Replaces an imported file without renaming it across filesystems.
///
/// Import archives are extracted under the cache directory, which can be on a
/// different Windows drive from the application data directory. A direct
/// [File.rename] fails in that case. Copying to a staging file beside the
/// destination first also keeps the live file intact until the copy finishes.
Future<void> replaceImportedFile(File source, String destinationPath) async {
  if (!await source.exists()) {
    throw FileSystemException('Imported file does not exist', source.path);
  }

  final suffix = DateTime.now().microsecondsSinceEpoch;
  final destination = File(destinationPath);
  final staging = File('$destinationPath.importing-$suffix');
  final backup = File('$destinationPath.before-import-$suffix');
  var destinationMoved = false;

  try {
    await source.copy(staging.path);
    if (await source.length() != await staging.length()) {
      throw FileSystemException(
        'Imported file copy is incomplete',
        staging.path,
      );
    }

    if (await destination.exists()) {
      await destination.rename(backup.path);
      destinationMoved = true;
    }
    await staging.rename(destination.path);
    if (destinationMoved) {
      await backup.deleteIgnoreError();
    }
  } catch (_) {
    if (destinationMoved &&
        !await destination.exists() &&
        await backup.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  } finally {
    await staging.deleteIgnoreError();
  }
}

@visibleForTesting
bool dataExportIncludesDeviceSecrets({required bool sync}) => !sync;

Future<File> exportAppData([bool sync = true]) async {
  await HistoryManager().waitForAsyncTasks();
  await appdata.saveData(false);
  var time = DateTime.now().microsecondsSinceEpoch;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  final includeDeviceSecrets = dataExportIncludesDeviceSecrets(sync: sync);
  await Isolate.run(() async {
    final snapshotDirectory = Directory(
      FilePath.join(App.cachePath, 'export-snapshot-$time'),
    );
    snapshotDirectory.createSync(recursive: true);
    var historyFile = FilePath.join(dataPath, "history.db");
    var localFavoriteFile = FilePath.join(dataPath, "local_favorite.db");
    var appdata = FilePath.join(
      dataPath,
      sync ? "syncdata.json" : "appdata.json",
    );
    var cookies = FilePath.join(dataPath, "cookie.db");
    final historySnapshot = FilePath.join(snapshotDirectory.path, 'history.db');
    final favoritesSnapshot = FilePath.join(
      snapshotDirectory.path,
      'local_favorite.db',
    );
    final cookieSnapshot = FilePath.join(snapshotDirectory.path, 'cookie.db');
    try {
      await snapshotSqliteDatabase(historyFile, historySnapshot);
      await snapshotSqliteDatabase(localFavoriteFile, favoritesSnapshot);
      // WebDAV archives are stored remotely without end-to-end encryption.
      // Keep login cookies only in an explicit local export; synchronized
      // backups contain settings/library data but no reusable sessions.
      if (includeDeviceSecrets) {
        await snapshotSqliteDatabase(cookies, cookieSnapshot);
      }

      final zipFile = ZipFile.open(cacheFilePath);
      try {
        zipFile.addFile("history.db", historySnapshot);
        zipFile.addFile("local_favorite.db", favoritesSnapshot);
        zipFile.addFile("appdata.json", appdata);
        if (includeDeviceSecrets) {
          zipFile.addFile("cookie.db", cookieSnapshot);
        }
        for (var file in Directory(
          FilePath.join(dataPath, "comic_source"),
        ).listSync()) {
          if (file is File &&
              (includeDeviceSecrets || !file.path.endsWith('.data'))) {
            // Source .data files may contain account/password pairs. Keep
            // them in an explicit local export, never in plaintext WebDAV.
            zipFile.addFile("comic_source/${file.name}", file.path);
          }
        }
      } finally {
        zipFile.close();
      }
    } finally {
      snapshotDirectory.deleteIfExistsSync(recursive: true);
    }
  });
  return cacheFile;
}

final _dataImportGate = KeyedAsyncGate<String>();

Future<void> importAppData(File file, [bool checkVersion = false]) {
  return _dataImportGate.run(
    'application-data',
    () => _runDataImportMaintenance(() => _importAppData(file, checkVersion)),
  );
}

Future<T> _runDataImportMaintenance<T>(Future<T> Function() operation) async {
  final maintenance = MaintenanceCoordinator.instance;
  return maintenance.run('Import App Data', () async {
    final localManager = LocalManager();
    final taskSnapshot = List<DownloadTask>.of(localManager.downloadingTasks);
    final previouslyRunning = taskSnapshot
        .where((task) => !task.isPaused)
        .toSet();
    try {
      await Future.wait(taskSnapshot.map((task) => task.pauseAndWait()));
      return await operation();
    } finally {
      final current = localManager.downloadingTasks.firstOrNull;
      if (current != null && previouslyRunning.contains(current)) {
        current.resume();
      }
    }
  });
}

Future<void> _importAppData(File file, bool checkVersion) async {
  final operationId =
      '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  var cacheDirPath = FilePath.join(App.cachePath, 'temp-data-$operationId');
  var cacheDir = Directory(cacheDirPath);
  cacheDir.createSync(recursive: true);
  try {
    await Isolate.run(() {
      extractZipChecked(file.path, cacheDirPath);
    });
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    var cookieFile = cacheDir.joinFile("cookie.db");
    if (checkVersion && appdataFile.existsSync()) {
      var data = jsonDecode(await appdataFile.readAsString());
      var version = data["settings"]["dataVersion"];
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return;
      }
    }
    if (await historyFile.exists()) {
      await Isolate.run(
        () => validateSqliteDatabase(
          historyFile.path,
          requiredTables: const ['history'],
        ),
      );
    }
    if (await localFavoriteFile.exists()) {
      await Isolate.run(
        () => validateSqliteDatabase(
          localFavoriteFile.path,
          requiredTables: const ['folder_order', 'folder_sync'],
        ),
      );
    }
    if (await cookieFile.exists()) {
      await Isolate.run(
        () => validateSqliteDatabase(
          cookieFile.path,
          requiredTables: const ['cookies'],
        ),
      );
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    final importedSourceDirectory = Directory(comicSourceDir);
    if (checkVersion && await importedSourceDirectory.exists()) {
      // Cloud backups deliberately exclude source account data. Also strip it
      // from legacy cloud archives, then carry forward only this device's data
      // for source scripts that still exist in the incoming configuration.
      await prepareCloudSourceImport(
        importedSourceDirectory,
        Directory(FilePath.join(App.dataPath, 'comic_source')),
      );
    }
    Map<String, dynamic>? importedAppdata;
    if (await appdataFile.exists()) {
      final decoded = jsonDecode(await appdataFile.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Imported appdata must be a JSON object');
      }
      importedAppdata = Map<String, dynamic>.from(decoded);
    }

    final hasHistory = await historyFile.exists();
    final hasFavorites = await localFavoriteFile.exists();
    final hasCookies = await cookieFile.exists();
    final hasSources = await importedSourceDirectory.exists();
    final cookiePath = FilePath.join(App.dataPath, 'cookie.db');
    final historyManager = HistoryManager();
    final favoritesManager = LocalFavoritesManager();
    var historyOpen = hasHistory;
    var favoritesOpen = hasFavorites;
    var cookieOpen = hasCookies;
    var appdataChanged = false;
    final previousAppdata =
        jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
    if (importedAppdata != null) {
      // Flush the exact pre-import settings before the transaction snapshots
      // appdata.json and syncdata.json for crash recovery.
      await appdata.saveData(false);
    }

    Future<void> runManagerSteps(
      Iterable<(String, Future<void> Function())> steps,
    ) async {
      final failures = <String>[];
      for (final (label, operation) in steps) {
        try {
          await operation();
        } catch (error, stackTrace) {
          failures.add('$label: $error');
          Log.error('Data import', '$label failed: $error', stackTrace);
        }
      }
      if (failures.isNotEmpty) {
        throw StateError(failures.join('\n'));
      }
    }

    Future<void> closeAffectedManagers() {
      return runManagerSteps([
        if (historyOpen)
          (
            'Close history database',
            () async {
              await historyManager.waitForAsyncTasks();
              historyManager.close();
              historyOpen = false;
            },
          ),
        if (favoritesOpen)
          (
            'Close favorites database',
            () async {
              favoritesManager.close();
              favoritesOpen = false;
            },
          ),
        if (cookieOpen)
          (
            'Close cookie database',
            () async {
              SingleInstanceCookieJar.instance?.dispose();
              SingleInstanceCookieJar.instance = null;
              cookieOpen = false;
            },
          ),
      ]);
    }

    Future<void> reopenAffectedManagers() {
      return runManagerSteps([
        if (hasHistory && !historyOpen)
          (
            'Open history database',
            () async {
              try {
                await historyManager.init();
                historyOpen = true;
              } catch (_) {
                // init opens SQLite before running migrations. Ensure that a
                // later migration failure cannot leave a Windows file handle
                // behind and prevent the import transaction from rolling back.
                try {
                  historyManager.close();
                } catch (_) {}
                historyOpen = false;
                rethrow;
              }
            },
          ),
        if (hasFavorites && !favoritesOpen)
          (
            'Open favorites database',
            () async {
              try {
                await favoritesManager.init();
                favoritesOpen = true;
              } catch (_) {
                try {
                  favoritesManager.close();
                } catch (_) {}
                favoritesOpen = false;
                rethrow;
              }
            },
          ),
        if (hasCookies && !cookieOpen)
          (
            'Open cookie database',
            () async {
              SingleInstanceCookieJar(cookiePath);
              // Mark the handle open before resetting QuickJS. If reset fails,
              // rollback must still close the newly opened SQLite connection.
              cookieOpen = true;
              await JsEngine.reset();
            },
          ),
      ]);
    }

    final transaction = await ImportTransaction.prepare(
      files: [
        if (hasHistory)
          ImportFileReplacement(
            historyFile,
            FilePath.join(App.dataPath, 'history.db'),
          ),
        if (hasFavorites)
          ImportFileReplacement(
            localFavoriteFile,
            FilePath.join(App.dataPath, 'local_favorite.db'),
          ),
        if (hasCookies) ImportFileReplacement(cookieFile, cookiePath),
      ],
      directories: [
        if (hasSources)
          ImportDirectoryReplacement(
            importedSourceDirectory,
            FilePath.join(App.dataPath, 'comic_source'),
          ),
      ],
      protectedFilePaths: [
        if (importedAppdata != null)
          FilePath.join(App.dataPath, 'appdata.json'),
        if (importedAppdata != null)
          FilePath.join(App.dataPath, 'syncdata.json'),
      ],
      copyDirectory: copyDirectoryIsolate,
      journalFile: appDataImportJournalFile(App.dataPath),
      operationId: operationId,
    );

    Object? importError;
    StackTrace? importStackTrace;
    try {
      await closeAffectedManagers();
      await transaction.apply();
      await reopenAffectedManagers();

      if (importedAppdata != null) {
        appdataChanged = true;
        if (checkVersion) {
          await appdata.syncData(importedAppdata, upload: false);
        } else {
          await appdata.restoreImportedData(importedAppdata);
        }
      }
      if (hasSources || hasCookies) {
        // Resetting QuickJS invalidates every JSInvokable held by the current
        // source objects, even when the archive contains no source files.
        await ComicSourceManager().reload(failOnInvalidSource: hasSources);
      }
      await transaction.commit();
    } catch (error, stackTrace) {
      importError = error;
      importStackTrace = stackTrace;
      final rollbackFailures = <String>[];
      Future<void> restoreStep(
        String label,
        Future<void> Function() operation,
      ) async {
        try {
          await operation();
        } catch (rollbackError, rollbackStackTrace) {
          rollbackFailures.add('$label: $rollbackError');
          Log.error(
            'Data import rollback',
            '$label failed: $rollbackError',
            rollbackStackTrace,
          );
        }
      }

      await restoreStep('Close imported databases', closeAffectedManagers);
      await restoreStep('Restore original files', transaction.rollback);
      await restoreStep('Reopen original databases', reopenAffectedManagers);
      if (appdataChanged) {
        await restoreStep(
          'Restore application settings',
          () => appdata.restoreSnapshot(previousAppdata),
        );
      }
      if (hasSources || hasCookies) {
        await restoreStep(
          'Reload original comic sources',
          ComicSourceManager().reload,
        );
      }
      if (rollbackFailures.isNotEmpty) {
        Log.error(
          'Data import rollback',
          'Import failed and some rollback steps need attention:\n'
              '${rollbackFailures.join('\n')}',
        );
      }
    }
    if (importError != null) {
      Error.throwWithStackTrace(importError, importStackTrace!);
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

Future<void> importPicaData(File file) {
  return _dataImportGate.run(
    'application-data',
    () => _runDataImportMaintenance(() => _importPicaData(file)),
  );
}

Future<void> _importPicaData(File file) async {
  final operationId =
      '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  var cacheDirPath = FilePath.join(App.cachePath, 'temp-pica-$operationId');
  var cacheDir = Directory(cacheDirPath);
  cacheDir.createSync(recursive: true);
  try {
    await Isolate.run(() {
      extractZipChecked(file.path, cacheDirPath);
    });
    final favoritesManager = LocalFavoritesManager();
    final historyManager = HistoryManager();
    // Keep both live databases inside savepoints for the complete legacy
    // import. A malformed row must not be logged as success after permanently
    // applying only the rows that happened to precede it.
    favoritesManager.runInTransaction(() {
      historyManager.runInTransaction(() {
        var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
        if (localFavoriteFile.existsSync()) {
          final db = sqlite3.open(localFavoriteFile.path);
          try {
            var folderNames = db
                .select("SELECT name FROM sqlite_master WHERE type='table';")
                .map((e) => e["name"] as String)
                .toList();
            folderNames.removeWhere(
              (e) => e == "folder_order" || e == "folder_sync",
            );
            if (folderNames.any(
              (name) => !isSafeImportedSqliteIdentifier(name),
            )) {
              throw const FormatException(
                'Imported favorites contain an unsafe folder name',
              );
            }
            for (var folderSyncValue in db.select(
              "SELECT * FROM folder_sync;",
            )) {
              var folderName = folderSyncValue["folder_name"];
              if (!isSafeImportedSqliteIdentifier(folderName)) {
                throw const FormatException(
                  'Imported favorites contain an unsafe linked folder name',
                );
              }
              String sourceKey = folderSyncValue["key"];
              sourceKey = sourceKey.toLowerCase() == "htmanga"
                  ? "wnacg"
                  : sourceKey;
              // 有值就跳过
              if (favoritesManager.findLinked(folderName).$1 != null) {
                continue;
              }
              favoritesManager.linkFolderToNetwork(
                folderName,
                sourceKey,
                jsonDecode(folderSyncValue["sync_data"])["folderId"],
              );
            }
            for (var folderName in folderNames) {
              if (!favoritesManager.existsFolder(folderName)) {
                favoritesManager.createFolder(folderName);
              }
              for (var comic in db.select("SELECT * FROM \"$folderName\";")) {
                favoritesManager.addComic(
                  folderName,
                  FavoriteItem(
                    id: comic['target'],
                    name: comic['name'],
                    coverPath: comic['cover_path'],
                    author: comic['author'],
                    type: ComicType(switch (comic['type']) {
                      0 => 'picacg'.hashCode,
                      1 => 'ehentai'.hashCode,
                      2 => 'jm'.hashCode,
                      3 => 'hitomi'.hashCode,
                      4 => 'wnacg'.hashCode,
                      6 => 'nhentai'.hashCode,
                      _ => comic['type'],
                    }),
                    tags: comic['tags'].split(','),
                  ),
                );
              }
            }
          } finally {
            db.dispose();
          }
        }

        var historyFile = cacheDir.joinFile("history.db");
        if (historyFile.existsSync()) {
          final db = sqlite3.open(historyFile.path);
          try {
            for (var comic in db.select("SELECT * FROM history;")) {
              historyManager.addHistory(
                History.fromMap({
                  "type": switch (comic['type']) {
                    0 => 'picacg'.hashCode,
                    1 => 'ehentai'.hashCode,
                    2 => 'jm'.hashCode,
                    3 => 'hitomi'.hashCode,
                    4 => 'wnacg'.hashCode,
                    5 => 'nhentai'.hashCode,
                    _ => comic['type'],
                  },
                  "id": comic['target'],
                  "max_page": comic["max_page"],
                  "ep": comic["ep"],
                  "page": comic["page"],
                  "time": comic["time"],
                  "title": comic["title"],
                  "subtitle": comic["subtitle"],
                  "cover": comic["cover"],
                  "readEpisode": [comic["ep"]],
                }),
              );
            }
            List<ImageFavoritesComic> imageFavoritesComicList =
                ImageFavoriteManager().comics;
            for (var comic in db.select("SELECT * FROM image_favorites;")) {
              String sourceKey = comic["id"].split("-")[0];
              // 换名字了, 绅士漫画
              if (sourceKey.toLowerCase() == "htmanga") {
                sourceKey = "wnacg";
              }
              if (ComicSource.find(sourceKey) == null) {
                continue;
              }
              String id = comic["id"].split("-")[1];
              int page = comic["page"];
              // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
              int ep = comic["ep"] == 0 ? 1 : comic["ep"];
              String title = comic["title"];
              String epName = "";
              ImageFavoritesComic? tempComic = imageFavoritesComicList
                  .firstWhereOrNull(
                    (e) => e.id == id && e.sourceKey == sourceKey,
                  );
              ImageFavorite curImageFavorite = ImageFavorite(
                page,
                "",
                null,
                "",
                id,
                ep,
                sourceKey,
                epName,
              );
              if (tempComic == null) {
                tempComic = ImageFavoritesComic(
                  id,
                  [],
                  title,
                  sourceKey,
                  [],
                  [],
                  DateTime.now(),
                  "",
                  {},
                  "",
                  1,
                );
                tempComic.imageFavoritesEp = [
                  ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
                ];
                imageFavoritesComicList.add(tempComic);
              } else {
                ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                    .firstWhereOrNull((e) => e.ep == ep);
                if (tempEp == null) {
                  tempComic.imageFavoritesEp.add(
                    ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
                  );
                } else {
                  // 如果已经有这个page了, 就不添加了
                  if (tempEp.imageFavorites.firstWhereOrNull(
                        (e) => e.page == page,
                      ) ==
                      null) {
                    tempEp.imageFavorites.add(curImageFavorite);
                  }
                }
              }
            }
            for (var temp in imageFavoritesComicList) {
              ImageFavoriteManager().addOrUpdateOrDelete(
                temp,
                temp == imageFavoritesComicList.last,
              );
            }
          } finally {
            db.dispose();
          }
        }
      });
    });
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
