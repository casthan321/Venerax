import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/import_transaction.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-import-transaction-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> copyDirectory(Directory source, Directory destination) async {
    for (final entity in source.listSync()) {
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (entity is File) {
        await entity.copy('${destination.path}${Platform.pathSeparator}$name');
      } else if (entity is Directory) {
        final child = Directory(
          '${destination.path}${Platform.pathSeparator}$name',
        );
        await child.create();
        await copyDirectory(entity, child);
      }
    }
  }

  test('rolls back every applied file and directory', () async {
    final oldDatabase = File('${root.path}/history.db')
      ..writeAsStringSync('old-db');
    final incomingDatabase = File('${root.path}/incoming.db')
      ..writeAsStringSync('new-db');
    final oldSources = Directory('${root.path}/sources')..createSync();
    File('${oldSources.path}/old.js').writeAsStringSync('old-source');
    final incomingSources = Directory('${root.path}/incoming-sources')
      ..createSync();
    File('${incomingSources.path}/new.js').writeAsStringSync('new-source');

    final transaction = await ImportTransaction.prepare(
      files: [ImportFileReplacement(incomingDatabase, oldDatabase.path)],
      directories: [
        ImportDirectoryReplacement(incomingSources, oldSources.path),
      ],
      copyDirectory: copyDirectory,
      journalFile: File('${root.path}/import-journal.json'),
      operationId: 'rollback',
    );
    await transaction.apply();
    expect(await oldDatabase.readAsString(), 'new-db');
    expect(
      await File('${oldSources.path}/new.js').readAsString(),
      'new-source',
    );

    await transaction.rollback();

    expect(await oldDatabase.readAsString(), 'old-db');
    expect(
      await File('${oldSources.path}/old.js').readAsString(),
      'old-source',
    );
    expect(await File('${oldSources.path}/new.js').exists(), isFalse);
  });

  test('commit removes backups and keeps all replacements', () async {
    final destination = File('${root.path}/cookie.db')
      ..writeAsStringSync('old');
    final incoming = File('${root.path}/incoming-cookie.db')
      ..writeAsStringSync('new');
    final transaction = await ImportTransaction.prepare(
      files: [ImportFileReplacement(incoming, destination.path)],
      copyDirectory: copyDirectory,
      journalFile: File('${root.path}/import-journal.json'),
      operationId: 'commit',
    );

    await transaction.apply();
    await transaction.commit();

    expect(await destination.readAsString(), 'new');
    expect(
      root.listSync().where((entry) => entry.path.contains('before-import')),
      isEmpty,
    );
  });

  test('startup recovery rolls back applied files and settings', () async {
    final destination = File('${root.path}/history.db')
      ..writeAsStringSync('old-database');
    final incoming = File('${root.path}/incoming-history.db')
      ..writeAsStringSync('new-database');
    final settings = File('${root.path}/appdata.json')
      ..writeAsStringSync('old-settings');
    final journal = File('${root.path}/import-journal.json');
    final transaction = await ImportTransaction.prepare(
      files: [ImportFileReplacement(incoming, destination.path)],
      protectedFilePaths: [settings.path],
      copyDirectory: copyDirectory,
      journalFile: journal,
      operationId: 'crash-rollback',
    );

    await transaction.apply();
    await settings.writeAsString('new-settings');
    final recoveryJournal = jsonDecode(await journal.readAsString()) as Map;
    recoveryJournal['phase'] = 'rollingBack';

    await recoverInterruptedImportTransaction(
      journalFile: journal,
      allowedDestinationRoot: root.path,
    );

    expect(await destination.readAsString(), 'old-database');
    expect(await settings.readAsString(), 'old-settings');
    expect(await journal.exists(), isFalse);

    // A crash after restoring the backup but before deleting the journal must
    // make the next recovery pass a harmless no-op.
    await journal.writeAsString(jsonEncode(recoveryJournal), flush: true);
    await recoverInterruptedImportTransaction(
      journalFile: journal,
      allowedDestinationRoot: root.path,
    );
    expect(await destination.readAsString(), 'old-database');
    expect(await settings.readAsString(), 'old-settings');
    expect(await journal.exists(), isFalse);
    expect(
      root.listSync().where(
        (entry) =>
            entry.path.contains('before-import') ||
            entry.path.contains('.importing-'),
      ),
      isEmpty,
    );
  });

  test('startup recovery finishes a durable commit decision', () async {
    final destination = File('${root.path}/cookie.db')
      ..writeAsStringSync('old');
    final incoming = File('${root.path}/incoming-cookie.db')
      ..writeAsStringSync('new');
    final journal = File('${root.path}/import-journal.json');
    final transaction = await ImportTransaction.prepare(
      files: [ImportFileReplacement(incoming, destination.path)],
      copyDirectory: copyDirectory,
      journalFile: journal,
      operationId: 'crash-commit',
    );
    await transaction.apply();
    final journalData = jsonDecode(await journal.readAsString()) as Map;
    journalData['phase'] = 'committing';
    await journal.writeAsString(jsonEncode(journalData), flush: true);

    await recoverInterruptedImportTransaction(
      journalFile: journal,
      allowedDestinationRoot: root.path,
    );

    expect(await destination.readAsString(), 'new');
    expect(await journal.exists(), isFalse);
    expect(
      root.listSync().where((entry) => entry.path.contains('before-import')),
      isEmpty,
    );
  });

  test(
    'malformed journal cannot mutate a path outside the data root',
    () async {
      final outsideRoot = await Directory.systemTemp.createTemp(
        'venera-import-outside-',
      );
      addTearDown(() async {
        if (await outsideRoot.exists()) {
          await outsideRoot.delete(recursive: true);
        }
      });
      final outside = File('${outsideRoot.path}/keep.db')
        ..writeAsStringSync('keep');
      final journal = File('${root.path}/import-journal.json');
      await journal.writeAsString(
        jsonEncode({
          'version': 1,
          'operationId': 'escape',
          'phase': 'applying',
          'entries': [
            {
              'type': 'file',
              'destinationPath': outside.path,
              'id': 'escape-0',
              'originalExisted': false,
            },
          ],
        }),
        flush: true,
      );

      await expectLater(
        recoverInterruptedImportTransaction(
          journalFile: journal,
          allowedDestinationRoot: root.path,
        ),
        throwsFormatException,
      );
      expect(await outside.readAsString(), 'keep');
      expect(await journal.exists(), isTrue);
    },
  );
}
