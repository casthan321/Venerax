import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:venera/utils/atomic_file.dart';

const _comicSourceTransactionVersion = 1;
const _comicSourceJournalName = '.venera-comic-source-install-journal.json';

File comicSourceInstallJournalFile(String dataRoot) =>
    File(p.join(dataRoot, _comicSourceJournalName));

/// A crash-safe publication transaction for executable comic-source scripts.
///
/// A journal is written before any installed file or source data is moved.
/// Deleting that journal is the sole commit point. If the process exits before
/// that point, startup recovery restores the previous script, private data and
/// only the affected application settings.
class ComicSourceInstallTransaction {
  ComicSourceInstallTransaction._({
    required this.dataRoot,
    required this.journalFile,
    required this.destination,
    required this.staging,
    required this.backup,
    required this.dataFile,
    required this.dataBackup,
    required this.journal,
  });

  final String dataRoot;
  final File journalFile;
  final File destination;
  final File staging;
  final File backup;
  final File dataFile;
  final File dataBackup;
  final Map<String, dynamic> journal;

  static Future<ComicSourceInstallTransaction> prepare({
    required String dataRoot,
    required String kind,
    required String sourceKey,
    required String expectedVersion,
    required File destination,
    required String newScript,
    required Map<String, dynamic> beforeSettings,
    required Map<String, dynamic>? newBinding,
    required bool clearSourceData,
  }) async {
    if (!const {'install', 'switch', 'update'}.contains(kind) ||
        !RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(sourceKey) ||
        expectedVersion.isEmpty ||
        expectedVersion.length > 80) {
      throw const FormatException('Invalid comic source transaction metadata');
    }
    final normalizedRoot = p.normalize(p.absolute(dataRoot));
    final comicSourceRoot = p.join(normalizedRoot, 'comic_source');
    final normalizedDestination = p.normalize(p.absolute(destination.path));
    if (p.dirname(normalizedDestination) != comicSourceRoot ||
        p.extension(normalizedDestination).toLowerCase() != '.js') {
      throw const FormatException('Unsafe comic source destination');
    }
    await Directory(comicSourceRoot).create(recursive: true);
    final journalFile = comicSourceInstallJournalFile(normalizedRoot);
    if (await journalFile.exists()) {
      throw StateError('A comic source transaction is pending recovery');
    }

    final operationId = _randomOperationId();
    final fileName = p.basename(normalizedDestination);
    final staging = File(
      p.join(comicSourceRoot, '.$fileName.$operationId.new'),
    );
    final backup = File(p.join(comicSourceRoot, '.$fileName.$operationId.old'));
    final dataFile = File(p.join(comicSourceRoot, '$sourceKey.data'));
    final dataBackup = File(
      p.join(comicSourceRoot, '.$sourceKey.data.$operationId.old'),
    );
    final destinationFile = File(normalizedDestination);
    final originalScriptExisted = await destinationFile.exists();
    final originalDataExisted = await dataFile.exists();
    final newBytes = utf8.encode(newScript);
    final journal = <String, dynamic>{
      'version': _comicSourceTransactionVersion,
      'operationId': operationId,
      'kind': kind,
      'sourceKey': sourceKey,
      'expectedVersion': expectedVersion,
      'destination': p.relative(normalizedDestination, from: normalizedRoot),
      'staging': p.relative(staging.path, from: normalizedRoot),
      'backup': p.relative(backup.path, from: normalizedRoot),
      'dataFile': p.relative(dataFile.path, from: normalizedRoot),
      'dataBackup': p.relative(dataBackup.path, from: normalizedRoot),
      'originalScriptExisted': originalScriptExisted,
      'originalDataExisted': originalDataExisted,
      'oldScriptSha256': originalScriptExisted
          ? await _fileSha256(destinationFile)
          : null,
      'oldDataSha256': originalDataExisted ? await _fileSha256(dataFile) : null,
      'newScriptSha256': sha256.convert(newBytes).toString(),
      'clearSourceData': clearSourceData,
      'beforeSettings': jsonDecode(jsonEncode(beforeSettings)),
      'newBinding': newBinding == null
          ? null
          : jsonDecode(jsonEncode(newBinding)),
    };

    await writeStringAtomically(journalFile, jsonEncode(journal));
    try {
      await staging.writeAsBytes(newBytes, flush: true);
      return ComicSourceInstallTransaction._(
        dataRoot: normalizedRoot,
        journalFile: journalFile,
        destination: destinationFile,
        staging: staging,
        backup: backup,
        dataFile: dataFile,
        dataBackup: dataBackup,
        journal: journal,
      );
    } catch (_) {
      // Nothing has been published at this point.  Avoid running the startup
      // recovery path against live in-memory settings; only the temporary
      // artifacts created by prepare() need to be removed.
      await _deleteBestEffort(staging);
      await _deleteBestEffort(journalFile);
      rethrow;
    }
  }

  Future<void> publish() async {
    await _expectHash(staging, journal['newScriptSha256'] as String);
    if (journal['clearSourceData'] == true && await dataFile.exists()) {
      await dataFile.rename(dataBackup.path);
    }
    if (await destination.exists()) {
      await destination.rename(backup.path);
    }
    await staging.rename(destination.path);
  }

  Future<void> commit() async {
    await _expectHash(destination, journal['newScriptSha256'] as String);
    await journalFile.delete();
    await _deleteBestEffort(backup);
    await _deleteBestEffort(dataBackup);
    await _deleteBestEffort(staging);
  }

  Future<void> rollback(
    Future<void> Function(Map<String, dynamic> beforeSettings)
    restoreRuntimeSettings,
  ) async {
    await _rollbackFiles(dataRoot, journal);
    final before = Map<String, dynamic>.from(journal['beforeSettings'] as Map);
    await restoreRuntimeSettings(before);
    await _deleteBestEffort(staging);
    await _deleteBestEffort(backup);
    await _deleteBestEffort(dataBackup);
    await journalFile.delete();
  }
}

/// Restores an interrupted transaction before Appdata or ComicSourceManager
/// opens the files involved in it.
Future<void> recoverInterruptedComicSourceInstall(String dataRoot) async {
  final normalizedRoot = p.normalize(p.absolute(dataRoot));
  final journalFile = comicSourceInstallJournalFile(normalizedRoot);
  if (!await journalFile.exists()) return;
  final decoded = jsonDecode(await journalFile.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Invalid comic source transaction journal');
  }
  final journal = Map<String, dynamic>.from(decoded);
  _validateJournal(normalizedRoot, journal);
  await _rollbackFiles(normalizedRoot, journal);
  await _restoreSettingsFile(
    File(p.join(normalizedRoot, 'appdata.json')),
    Map<String, dynamic>.from(journal['beforeSettings'] as Map),
    restoreMissingFields: true,
  );
  await _restoreSettingsFile(
    File(p.join(normalizedRoot, 'syncdata.json')),
    Map<String, dynamic>.from(journal['beforeSettings'] as Map),
    restoreMissingFields: false,
  );
  for (final key in const ['staging', 'backup', 'dataBackup']) {
    await _deleteBestEffort(_journalFile(normalizedRoot, journal, key));
  }
  await journalFile.delete();
}

Future<void> _rollbackFiles(
  String dataRoot,
  Map<String, dynamic> journal,
) async {
  _validateJournal(dataRoot, journal);
  final destination = _journalFile(dataRoot, journal, 'destination');
  final staging = _journalFile(dataRoot, journal, 'staging');
  final backup = _journalFile(dataRoot, journal, 'backup');
  final dataFile = _journalFile(dataRoot, journal, 'dataFile');
  final dataBackup = _journalFile(dataRoot, journal, 'dataBackup');
  final originalScriptExisted = journal['originalScriptExisted'] == true;
  final originalDataExisted = journal['originalDataExisted'] == true;

  if (originalScriptExisted) {
    if (await backup.exists()) {
      await _deleteBestEffort(destination);
      await backup.rename(destination.path);
    } else {
      await _expectHash(destination, journal['oldScriptSha256'] as String);
    }
  } else if (await destination.exists()) {
    await _expectHash(destination, journal['newScriptSha256'] as String);
    await destination.delete();
  }

  if (journal['clearSourceData'] == true) {
    if (originalDataExisted) {
      if (await dataBackup.exists()) {
        await _deleteBestEffort(dataFile);
        await dataBackup.rename(dataFile.path);
      } else {
        await _expectHash(dataFile, journal['oldDataSha256'] as String);
      }
    } else {
      await _deleteBestEffort(dataFile);
    }
  }
  await _deleteBestEffort(staging);
}

void _validateJournal(String dataRoot, Map<String, dynamic> journal) {
  if (journal['version'] != _comicSourceTransactionVersion ||
      journal['operationId'] is! String ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(journal['operationId'] as String) ||
      !const {'install', 'switch', 'update'}.contains(journal['kind']) ||
      journal['sourceKey'] is! String ||
      !RegExp(
        r'^[A-Za-z0-9_]{1,80}$',
      ).hasMatch(journal['sourceKey'] as String) ||
      journal['beforeSettings'] is! Map ||
      journal['newScriptSha256'] is! String ||
      (journal['originalScriptExisted'] == true &&
          journal['oldScriptSha256'] is! String) ||
      (journal['originalDataExisted'] == true &&
          journal['oldDataSha256'] is! String)) {
    throw const FormatException('Invalid comic source transaction journal');
  }
  final comicSourceRoot = p.join(
    p.normalize(p.absolute(dataRoot)),
    'comic_source',
  );
  for (final key in const [
    'destination',
    'staging',
    'backup',
    'dataFile',
    'dataBackup',
  ]) {
    final file = _journalFile(dataRoot, journal, key);
    if (!p.isWithin(comicSourceRoot, file.path) ||
        p.isAbsolute(journal[key] as String)) {
      throw const FormatException('Unsafe comic source transaction path');
    }
  }
  final destination = _journalFile(dataRoot, journal, 'destination');
  if (p.dirname(destination.path) != comicSourceRoot ||
      p.extension(destination.path).toLowerCase() != '.js') {
    throw const FormatException('Unsafe comic source destination');
  }
}

File _journalFile(String dataRoot, Map<String, dynamic> journal, String key) {
  final value = journal[key];
  if (value is! String || value.isEmpty) {
    throw const FormatException('Invalid comic source transaction path');
  }
  return File(p.normalize(p.join(p.absolute(dataRoot), value)));
}

Future<void> _restoreSettingsFile(
  File file,
  Map<String, dynamic> beforeSettings, {
  required bool restoreMissingFields,
}) async {
  if (!await file.exists()) return;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map || decoded['settings'] is! Map) {
    throw const FormatException('Invalid appdata during source recovery');
  }
  final root = Map<String, dynamic>.from(decoded);
  final settings = Map<String, dynamic>.from(root['settings'] as Map);
  for (final entry in beforeSettings.entries) {
    if (restoreMissingFields || settings.containsKey(entry.key)) {
      settings[entry.key] = jsonDecode(jsonEncode(entry.value));
    }
  }
  root['settings'] = settings;
  await writeStringAtomically(file, jsonEncode(root));
}

Future<String> _fileSha256(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

Future<void> _expectHash(File file, String expected) async {
  if (!await file.exists() || await _fileSha256(file) != expected) {
    throw StateError('Comic source transaction file verification failed');
  }
}

Future<void> _deleteBestEffort(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // A hidden backup is safer than turning a committed transaction into an
    // apparent failure. Startup recovery never executes these file names.
  }
}

String _randomOperationId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
