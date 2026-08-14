import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:venera/utils/atomic_file.dart';

typedef ImportDirectoryCopier =
    Future<void> Function(Directory source, Directory destination);

const appDataImportJournalFileName = '.venera-app-import-journal.json';

File appDataImportJournalFile(String dataPath) =>
    File(p.join(dataPath, appDataImportJournalFileName));

class ImportFileReplacement {
  const ImportFileReplacement(this.source, this.destinationPath);

  final File source;
  final String destinationPath;
}

class ImportDirectoryReplacement {
  const ImportDirectoryReplacement(this.source, this.destinationPath);

  final Directory source;
  final String destinationPath;
}

/// Stages imported resources beside their live destinations and records every
/// recovery-relevant path before touching live data.
///
/// The journal remains in `appDataImportJournalFileName` until either rollback
/// has restored all originals or commit has made every replacement final.
class ImportTransaction {
  ImportTransaction._(this._entries, this._journalFile, this._operationId);

  static const _journalVersion = 1;

  final List<_ImportEntry> _entries;
  final File _journalFile;
  final String _operationId;
  var _applied = false;
  var _finished = false;

  static Future<ImportTransaction> prepare({
    Iterable<ImportFileReplacement> files = const [],
    Iterable<ImportDirectoryReplacement> directories = const [],
    Iterable<String> protectedFilePaths = const [],
    required ImportDirectoryCopier copyDirectory,
    required File journalFile,
    String? operationId,
  }) async {
    final id =
        operationId ??
        '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
    if (!_isSafeOperationId(id)) {
      throw ArgumentError.value(
        id,
        'operationId',
        'contains unsafe characters',
      );
    }
    if (await journalFile.exists()) {
      throw StateError(
        'An unfinished import transaction must be recovered first',
      );
    }

    final entries = <_ImportEntry>[];
    final destinations = <String>{};
    var index = 0;
    for (final replacement in files) {
      if (!await replacement.source.exists()) {
        throw FileSystemException(
          'Imported file does not exist',
          replacement.source.path,
        );
      }
      _addUniqueDestination(destinations, replacement.destinationPath);
      entries.add(
        _ImportFileEntry(
          replacement.source,
          replacement.destinationPath,
          '$id-${index++}',
          originalExisted: await File(replacement.destinationPath).exists(),
        ),
      );
    }
    for (final replacement in directories) {
      if (!await replacement.source.exists()) {
        throw FileSystemException(
          'Imported directory does not exist',
          replacement.source.path,
        );
      }
      _addUniqueDestination(destinations, replacement.destinationPath);
      entries.add(
        _ImportDirectoryEntry(
          replacement.source,
          replacement.destinationPath,
          '$id-${index++}',
          copyDirectory,
          originalExisted: await Directory(
            replacement.destinationPath,
          ).exists(),
        ),
      );
    }
    for (final destinationPath in protectedFilePaths) {
      _addUniqueDestination(destinations, destinationPath);
      entries.add(
        _ImportProtectedFileEntry(
          destinationPath,
          '$id-${index++}',
          originalExisted: await File(destinationPath).exists(),
        ),
      );
    }

    final transaction = ImportTransaction._(entries, journalFile, id);
    await transaction._writeJournal(_ImportPhase.preparing);
    try {
      for (final entry in entries) {
        await entry.stage();
      }
      await transaction._writeJournal(_ImportPhase.prepared);
      return transaction;
    } catch (_) {
      var cleanupSucceeded = true;
      for (final entry in entries.reversed) {
        try {
          await entry.cleanupBeforeApply();
        } catch (_) {
          cleanupSucceeded = false;
        }
      }
      if (cleanupSucceeded) await _deleteFile(journalFile);
      rethrow;
    }
  }

  Future<void> apply() async {
    if (_finished || _applied) throw StateError('Import transaction is closed');
    try {
      await _writeJournal(_ImportPhase.applying);
      for (final entry in _entries) {
        await entry.apply();
      }
      _applied = true;
      await _writeJournal(_ImportPhase.applied);
    } catch (_) {
      await rollback();
      rethrow;
    }
  }

  Future<void> commit() async {
    if (_finished) return;
    if (!_applied && _entries.isNotEmpty) {
      throw StateError('Import transaction has not been applied');
    }

    // Persist the commit decision before deleting a single backup. Recovery
    // can then only finish cleanup and never roll a partially committed set
    // back to a mixture of old and new resources.
    await _writeJournal(_ImportPhase.committing);
    var cleanupSucceeded = true;
    for (final entry in _entries) {
      try {
        await entry.commit();
      } catch (_) {
        cleanupSucceeded = false;
      }
    }
    if (cleanupSucceeded) await _deleteFile(_journalFile);
    _finished = true;
  }

  Future<void> rollback() async {
    if (_finished) return;
    try {
      await _writeJournal(_ImportPhase.rollingBack);
    } catch (_) {
      // The previous `applying`/`applied` phase already instructs startup to
      // roll back. Continue restoring live files even if this phase update was
      // denied.
    }

    Object? firstError;
    StackTrace? firstStackTrace;
    for (final entry in _entries.reversed) {
      try {
        await entry.rollback();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _finished = true;
    if (firstError == null) {
      await _deleteFile(_journalFile);
      return;
    }
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }

  Future<void> _writeJournal(_ImportPhase phase) {
    return writeStringAtomically(
      _journalFile,
      jsonEncode({
        'version': _journalVersion,
        'operationId': _operationId,
        'phase': phase.name,
        'entries': _entries.map((entry) => entry.toJson()).toList(),
      }),
    );
  }
}

/// Recovers an app-data import before any manager opens its SQLite database.
///
/// Applying transactions are rolled back. Once the durable commit decision is
/// present, recovery keeps the new live resources and only finishes cleanup.
Future<void> recoverInterruptedImportTransaction({
  required File journalFile,
  required String allowedDestinationRoot,
}) async {
  if (!await journalFile.exists()) return;
  final decoded = jsonDecode(await journalFile.readAsString());
  if (decoded is! Map<String, dynamic> ||
      decoded['version'] != ImportTransaction._journalVersion ||
      decoded['operationId'] is! String ||
      decoded['phase'] is! String ||
      decoded['entries'] is! List) {
    throw const FormatException('Invalid import transaction journal');
  }
  final operationId = decoded['operationId'] as String;
  if (!_isSafeOperationId(operationId)) {
    throw const FormatException('Unsafe import transaction operation id');
  }
  final phase = _ImportPhase.values.firstWhere(
    (value) => value.name == decoded['phase'],
    orElse: () =>
        throw const FormatException('Unknown import transaction phase'),
  );
  final entries = <_ImportRecoveryEntry>[];
  final destinations = <String>{};
  final serializedEntries = decoded['entries'] as List;
  for (var index = 0; index < serializedEntries.length; index++) {
    final value = serializedEntries[index];
    if (value is! Map) {
      throw const FormatException('Invalid import transaction entry');
    }
    final entry = _ImportRecoveryEntry.fromJson(
      Map<String, dynamic>.from(value),
      allowedDestinationRoot: allowedDestinationRoot,
    );
    if (entry.id != '$operationId-$index' ||
        destinations.any(
          (destination) => _pathsOverlap(destination, entry.destinationPath),
        )) {
      throw const FormatException('Inconsistent import transaction entry');
    }
    destinations.add(entry.destinationPath);
    entries.add(entry);
  }

  switch (phase) {
    case _ImportPhase.preparing:
    case _ImportPhase.prepared:
      for (final entry in entries.reversed) {
        await entry.cleanupBeforeApply();
      }
      break;
    case _ImportPhase.applying:
    case _ImportPhase.applied:
    case _ImportPhase.rollingBack:
      for (final entry in entries.reversed) {
        await entry.rollback();
      }
      break;
    case _ImportPhase.committing:
      for (final entry in entries) {
        await entry.commit();
      }
      break;
  }
  await _deleteFile(journalFile);
}

enum _ImportPhase {
  preparing,
  prepared,
  applying,
  applied,
  rollingBack,
  committing,
}

void _addUniqueDestination(Set<String> destinations, String destinationPath) {
  final normalized = p.normalize(p.absolute(destinationPath));
  if (destinations.any(
    (destination) => _pathsOverlap(destination, normalized),
  )) {
    throw ArgumentError('Duplicate import destination: $destinationPath');
  }
  destinations.add(normalized);
}

bool _pathsOverlap(String first, String second) =>
    p.equals(first, second) ||
    p.isWithin(first, second) ||
    p.isWithin(second, first);

bool _isSafeOperationId(String id) =>
    id.isNotEmpty && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);

abstract class _ImportEntry {
  String get type;
  String get destinationPath;
  String get id;
  bool get originalExisted;

  Future<void> stage();
  Future<void> apply();
  Future<void> commit();
  Future<void> rollback();
  Future<void> cleanupBeforeApply();

  Map<String, dynamic> toJson() => {
    'type': type,
    'destinationPath': destinationPath,
    'id': id,
    'originalExisted': originalExisted,
  };
}

class _ImportFileEntry extends _ImportEntry {
  _ImportFileEntry(
    this.source,
    this.destinationPath,
    this.id, {
    required this.originalExisted,
  }) : staging = File('$destinationPath.importing-$id'),
       backup = File('$destinationPath.before-import-$id');

  final File source;
  @override
  final String destinationPath;
  @override
  final String id;
  @override
  final bool originalExisted;
  final File staging;
  final File backup;

  @override
  String get type => 'file';

  @override
  Future<void> stage() async {
    await staging.parent.create(recursive: true);
    await _deleteFile(staging);
    await _deleteFile(backup);
    await source.copy(staging.path);
    if (await source.length() != await staging.length()) {
      throw FileSystemException(
        'Imported file copy is incomplete',
        staging.path,
      );
    }
  }

  @override
  Future<void> apply() async {
    final destination = File(destinationPath);
    if (originalExisted) {
      if (!await destination.exists()) {
        throw FileSystemException(
          'Import destination disappeared',
          destinationPath,
        );
      }
      await destination.rename(backup.path);
    }
    await staging.rename(destinationPath);
  }

  @override
  Future<void> rollback() => _ImportRecoveryEntry(
    type: type,
    destinationPath: destinationPath,
    id: id,
    originalExisted: originalExisted,
  ).rollback();

  @override
  Future<void> commit() => _ImportRecoveryEntry(
    type: type,
    destinationPath: destinationPath,
    id: id,
    originalExisted: originalExisted,
  ).commit();

  @override
  Future<void> cleanupBeforeApply() async {
    await _deleteFile(staging);
    await _deleteFile(backup);
  }
}

class _ImportDirectoryEntry extends _ImportEntry {
  _ImportDirectoryEntry(
    this.source,
    this.destinationPath,
    this.id,
    this.copyDirectory, {
    required this.originalExisted,
  }) : staging = Directory('$destinationPath.importing-$id'),
       backup = Directory('$destinationPath.before-import-$id');

  final Directory source;
  @override
  final String destinationPath;
  @override
  final String id;
  @override
  final bool originalExisted;
  final Directory staging;
  final Directory backup;
  final ImportDirectoryCopier copyDirectory;

  @override
  String get type => 'directory';

  @override
  Future<void> stage() async {
    await _deleteDirectory(staging);
    await _deleteDirectory(backup);
    await staging.create(recursive: true);
    await copyDirectory(source, staging);
  }

  @override
  Future<void> apply() async {
    final destination = Directory(destinationPath);
    if (originalExisted) {
      if (!await destination.exists()) {
        throw FileSystemException(
          'Import destination disappeared',
          destinationPath,
        );
      }
      await destination.rename(backup.path);
    }
    await staging.rename(destinationPath);
  }

  @override
  Future<void> rollback() => _ImportRecoveryEntry(
    type: type,
    destinationPath: destinationPath,
    id: id,
    originalExisted: originalExisted,
  ).rollback();

  @override
  Future<void> commit() => _ImportRecoveryEntry(
    type: type,
    destinationPath: destinationPath,
    id: id,
    originalExisted: originalExisted,
  ).commit();

  @override
  Future<void> cleanupBeforeApply() async {
    await _deleteDirectory(staging);
    await _deleteDirectory(backup);
  }
}

/// Copies a rollback-only snapshot while leaving the live settings file in
/// place. The import may then update it through Appdata's merge semantics.
class _ImportProtectedFileEntry extends _ImportEntry {
  _ImportProtectedFileEntry(
    this.destinationPath,
    this.id, {
    required this.originalExisted,
  }) : backup = File('$destinationPath.before-import-$id');

  @override
  final String destinationPath;
  @override
  final String id;
  @override
  final bool originalExisted;
  final File backup;

  @override
  String get type => 'protectedFile';

  @override
  Future<void> stage() async {
    await backup.parent.create(recursive: true);
    await _deleteFile(backup);
    if (!originalExisted) return;
    final destination = File(destinationPath);
    await destination.copy(backup.path);
    if (await destination.length() != await backup.length()) {
      throw FileSystemException(
        'Protected file snapshot is incomplete',
        backup.path,
      );
    }
  }

  @override
  Future<void> apply() async {}

  @override
  Future<void> rollback() => _ImportRecoveryEntry(
    type: type,
    destinationPath: destinationPath,
    id: id,
    originalExisted: originalExisted,
  ).rollback();

  @override
  Future<void> commit() => _deleteFile(backup);

  @override
  Future<void> cleanupBeforeApply() => _deleteFile(backup);
}

class _ImportRecoveryEntry {
  const _ImportRecoveryEntry({
    required this.type,
    required this.destinationPath,
    required this.id,
    required this.originalExisted,
  });

  factory _ImportRecoveryEntry.fromJson(
    Map<String, dynamic> json, {
    required String allowedDestinationRoot,
  }) {
    final type = json['type'];
    final destinationPath = json['destinationPath'];
    final id = json['id'];
    final originalExisted = json['originalExisted'];
    if (!const {'file', 'directory', 'protectedFile'}.contains(type) ||
        destinationPath is! String ||
        id is! String ||
        !_isSafeOperationId(id) ||
        originalExisted is! bool) {
      throw const FormatException('Invalid import recovery entry');
    }
    final root = p.normalize(p.absolute(allowedDestinationRoot));
    final destination = p.normalize(p.absolute(destinationPath));
    if (!p.isWithin(root, destination)) {
      throw const FormatException('Import destination escapes data root');
    }
    return _ImportRecoveryEntry(
      type: type as String,
      destinationPath: destination,
      id: id,
      originalExisted: originalExisted,
    );
  }

  final String type;
  final String destinationPath;
  final String id;
  final bool originalExisted;

  File get _fileStaging => File('$destinationPath.importing-$id');
  File get _fileBackup => File('$destinationPath.before-import-$id');
  Directory get _directoryStaging =>
      Directory('$destinationPath.importing-$id');
  Directory get _directoryBackup =>
      Directory('$destinationPath.before-import-$id');

  Future<void> cleanupBeforeApply() async {
    switch (type) {
      case 'file':
        await _deleteFile(_fileStaging);
        await _deleteFile(_fileBackup);
        return;
      case 'directory':
        await _deleteDirectory(_directoryStaging);
        await _deleteDirectory(_directoryBackup);
        return;
      case 'protectedFile':
        await _deleteFile(_fileBackup);
        return;
    }
  }

  Future<void> rollback() async {
    switch (type) {
      case 'file':
        final destination = File(destinationPath);
        if (originalExisted) {
          if (await _fileBackup.exists()) {
            await _deleteFile(destination);
            await _fileBackup.rename(destinationPath);
          } else if (!await destination.exists()) {
            throw FileSystemException(
              'Original import file and its backup are both missing',
              destinationPath,
            );
          }
        } else {
          await _deleteFile(destination);
        }
        await _deleteFile(_fileStaging);
        return;
      case 'directory':
        final destination = Directory(destinationPath);
        if (originalExisted) {
          if (await _directoryBackup.exists()) {
            await _deleteDirectory(destination);
            await _directoryBackup.rename(destinationPath);
          } else if (!await destination.exists()) {
            throw FileSystemException(
              'Original import directory and its backup are both missing',
              destinationPath,
            );
          }
        } else {
          await _deleteDirectory(destination);
        }
        await _deleteDirectory(_directoryStaging);
        return;
      case 'protectedFile':
        final destination = File(destinationPath);
        if (originalExisted) {
          if (await _fileBackup.exists()) {
            await _deleteFile(destination);
            await _fileBackup.rename(destinationPath);
          } else if (!await destination.exists()) {
            throw FileSystemException(
              'Protected import file and its snapshot are both missing',
              destinationPath,
            );
          }
        } else {
          await _deleteFile(destination);
        }
        return;
    }
  }

  Future<void> commit() async {
    switch (type) {
      case 'file':
        if (!await File(destinationPath).exists()) {
          throw FileSystemException(
            'Committed import file is missing',
            destinationPath,
          );
        }
        await _deleteFile(_fileStaging);
        await _deleteFile(_fileBackup);
        return;
      case 'directory':
        if (!await Directory(destinationPath).exists()) {
          throw FileSystemException(
            'Committed import directory is missing',
            destinationPath,
          );
        }
        await _deleteDirectory(_directoryStaging);
        await _deleteDirectory(_directoryBackup);
        return;
      case 'protectedFile':
        await _deleteFile(_fileBackup);
        return;
    }
  }
}

Future<void> _deleteFile(File file) async {
  if (await file.exists()) await file.delete();
}

Future<void> _deleteDirectory(Directory directory) async {
  if (await directory.exists()) await directory.delete(recursive: true);
}
