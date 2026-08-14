import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/utils/comic_source_install_transaction.dart';

void main() {
  late Directory root;
  late Directory sourceDirectory;
  late File appdataFile;
  late File syncdataFile;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-source-transaction-');
    sourceDirectory = Directory(p.join(root.path, 'comic_source'));
    await sourceDirectory.create();
    appdataFile = File(p.join(root.path, 'appdata.json'));
    syncdataFile = File(p.join(root.path, 'syncdata.json'));
    final initial = jsonEncode({
      'settings': {
        'comicSourceRepositoryBindings': {
          'demo': {'repositoryId': 'old'},
        },
        'searchSources': ['demo'],
        'unrelated': 'keep',
      },
      'searchHistory': <String>[],
    });
    await appdataFile.writeAsString(initial);
    await syncdataFile.writeAsString(initial);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Map<String, dynamic> beforeSettings() => {
    'comicSourceRepositoryBindings': {
      'demo': {'repositoryId': 'old'},
    },
    'searchSources': ['demo'],
  };

  test(
    'commit publishes the new script and removes recovery artifacts',
    () async {
      final destination = File(p.join(sourceDirectory.path, 'demo.js'));
      await destination.writeAsString('old script');
      final transaction = await ComicSourceInstallTransaction.prepare(
        dataRoot: root.path,
        kind: 'update',
        sourceKey: 'demo',
        expectedVersion: '2.0.0',
        destination: destination,
        newScript: 'new script',
        beforeSettings: beforeSettings(),
        newBinding: const {'repositoryId': 'new'},
        clearSourceData: false,
      );

      await transaction.publish();
      await transaction.commit();

      expect(await destination.readAsString(), 'new script');
      expect(await comicSourceInstallJournalFile(root.path).exists(), isFalse);
      expect(
        sourceDirectory.listSync().whereType<File>().map((file) => file.path),
        everyElement(isNot(contains('.old'))),
      );
    },
  );

  test('startup recovery restores script, private data, and settings', () async {
    final destination = File(p.join(sourceDirectory.path, 'demo.js'));
    final data = File(p.join(sourceDirectory.path, 'demo.data'));
    await destination.writeAsString('old script');
    await data.writeAsString('old private data');
    final transaction = await ComicSourceInstallTransaction.prepare(
      dataRoot: root.path,
      kind: 'switch',
      sourceKey: 'demo',
      expectedVersion: '2.0.0',
      destination: destination,
      newScript: 'new script',
      beforeSettings: beforeSettings(),
      newBinding: const {'repositoryId': 'new'},
      clearSourceData: true,
    );
    await transaction.publish();
    await data.writeAsString('new private data');
    final changed = jsonDecode(await appdataFile.readAsString());
    changed['settings']['comicSourceRepositoryBindings'] = {
      'demo': {'repositoryId': 'new'},
    };
    changed['settings']['unrelated'] = 'keep-newer';
    await appdataFile.writeAsString(jsonEncode(changed));

    await recoverInterruptedComicSourceInstall(root.path);
    await recoverInterruptedComicSourceInstall(root.path);

    expect(await destination.readAsString(), 'old script');
    expect(await data.readAsString(), 'old private data');
    final recovered = jsonDecode(await appdataFile.readAsString());
    expect(
      recovered['settings']['comicSourceRepositoryBindings']['demo']['repositoryId'],
      'old',
    );
    expect(recovered['settings']['unrelated'], 'keep-newer');
    expect(await comicSourceInstallJournalFile(root.path).exists(), isFalse);
  });

  test('startup recovery removes an interrupted new installation', () async {
    final destination = File(p.join(sourceDirectory.path, 'new_source.js'));
    final transaction = await ComicSourceInstallTransaction.prepare(
      dataRoot: root.path,
      kind: 'install',
      sourceKey: 'new_source',
      expectedVersion: '1.0.0',
      destination: destination,
      newScript: 'new script',
      beforeSettings: beforeSettings(),
      newBinding: const {'repositoryId': 'new'},
      clearSourceData: false,
    );
    await transaction.publish();

    await recoverInterruptedComicSourceInstall(root.path);

    expect(await destination.exists(), isFalse);
    expect(await comicSourceInstallJournalFile(root.path).exists(), isFalse);
  });

  test('rejects a journal path that escapes the data root', () async {
    await comicSourceInstallJournalFile(root.path).writeAsString(
      jsonEncode({
        'version': 1,
        'operationId': ''.padLeft(32, '0'),
        'kind': 'install',
        'sourceKey': 'demo',
        'expectedVersion': '1.0.0',
        'destination': p.join('..', 'outside.js'),
        'staging': p.join('comic_source', '.demo.new'),
        'backup': p.join('comic_source', '.demo.old'),
        'dataFile': p.join('comic_source', 'demo.data'),
        'dataBackup': p.join('comic_source', '.demo.data.old'),
        'originalScriptExisted': false,
        'originalDataExisted': false,
        'newScriptSha256': ''.padLeft(64, '0'),
        'clearSourceData': false,
        'beforeSettings': <String, dynamic>{},
      }),
    );

    await expectLater(
      recoverInterruptedComicSourceInstall(root.path),
      throwsFormatException,
    );
    expect(await comicSourceInstallJournalFile(root.path).exists(), isTrue);
  });
}
