import 'dart:io';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data.dart';

DynamicLibrary _openWindowsSqlite() {
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return DynamicLibrary.open('$systemRoot\\System32\\winsqlite3.dll');
}

Database _openTestDatabase(String path) {
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, _openWindowsSqlite);
  }
  return sqlite3.open(path);
}

void main() {
  test('cloud exports exclude reusable device credentials', () {
    expect(dataExportIncludesDeviceSecrets(sync: true), isFalse);
    expect(dataExportIncludesDeviceSecrets(sync: false), isTrue);
  });

  test('local restore includes device settings and keeps newer defaults', () {
    final restored = mergeLocalAppdataForRestore(
      {
        'settings': {
          'proxy': 'system',
          'webdav': <String>[],
          'newSetting': true,
        },
        'searchHistory': <String>['current'],
      },
      {
        'settings': {
          'proxy': 'http://127.0.0.1:7890',
          'webdav': <String>['https://dav.example', 'user', 'pass'],
          'disableSyncFields': 'readerMode',
        },
        'searchHistory': <String>['restored'],
      },
    );

    expect(restored['settings'], {
      'proxy': 'http://127.0.0.1:7890',
      'webdav': <String>['https://dav.example', 'user', 'pass'],
      'newSetting': true,
      'disableSyncFields': 'readerMode',
    });
    expect(restored['searchHistory'], <String>['restored']);
  });

  test('imported SQLite identifiers cannot inject quoted SQL', () {
    expect(isSafeImportedSqliteIdentifier('Favorites'), isTrue);
    expect(isSafeImportedSqliteIdentifier('漫画 收藏'), isTrue);
    expect(
      isSafeImportedSqliteIdentifier('bad"; DROP TABLE history;--'),
      isFalse,
    );
    expect(isSafeImportedSqliteIdentifier('sqlite_master'), isFalse);
    expect(isSafeImportedSqliteIdentifier(''), isFalse);
    expect(isSafeImportedSqliteIdentifier(null), isFalse);
  });

  test(
    'cloud source import keeps only local data for retained scripts',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera-source-cloud-import-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final imported = Directory(
        '${root.path}${Platform.pathSeparator}imported',
      )..createSync();
      final live = Directory('${root.path}${Platform.pathSeparator}live')
        ..createSync();
      File(
        '${imported.path}${Platform.pathSeparator}kept.js',
      ).writeAsStringSync('script');
      File(
        '${imported.path}${Platform.pathSeparator}kept.data',
      ).writeAsStringSync('legacy-cloud-secret');
      File(
        '${imported.path}${Platform.pathSeparator}removed.data',
      ).writeAsStringSync('legacy-orphan-secret');
      File(
        '${live.path}${Platform.pathSeparator}kept.data',
      ).writeAsStringSync('device-secret');
      File(
        '${live.path}${Platform.pathSeparator}removed.data',
      ).writeAsStringSync('removed-source-secret');

      await prepareCloudSourceImport(imported, live);

      expect(
        File(
          '${imported.path}${Platform.pathSeparator}kept.data',
        ).readAsStringSync(),
        'device-secret',
      );
      expect(
        File(
          '${imported.path}${Platform.pathSeparator}removed.data',
        ).existsSync(),
        isFalse,
      );
    },
  );

  tearDown(open.reset);

  test('stages imported files beside destination before replacement', () async {
    final root = await Directory.systemTemp.createTemp('venera-import-test-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final sourceDirectory = await Directory(
      '${root.path}${Platform.pathSeparator}source',
    ).create();
    final destinationDirectory = await Directory(
      '${root.path}${Platform.pathSeparator}destination',
    ).create();
    final source = File(
      '${sourceDirectory.path}${Platform.pathSeparator}history.db',
    );
    final destination = File(
      '${destinationDirectory.path}${Platform.pathSeparator}history.db',
    );
    await source.writeAsString('new database bytes');
    await destination.writeAsString('old database bytes');

    await replaceImportedFile(source, destination.path);

    expect(await destination.readAsString(), 'new database bytes');
    // The extracted source remains available until the import transaction is
    // complete; this proves the replacement does not use a cross-drive rename.
    expect(await source.readAsString(), 'new database bytes');
    expect(
      destinationDirectory.listSync().where(
        (entry) => entry.path.contains('.before-import-'),
      ),
      isEmpty,
    );
    expect(
      destinationDirectory.listSync().where(
        (entry) => entry.path.contains('.importing-'),
      ),
      isEmpty,
    );
  });

  test('SQLite snapshot is consistent while the source stays open', () async {
    final root = await Directory.systemTemp.createTemp('venera-snapshot-test-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final sourcePath = '${root.path}${Platform.pathSeparator}source.db';
    final destinationPath = '${root.path}${Platform.pathSeparator}snapshot.db';
    final source = _openTestDatabase(sourcePath);
    addTearDown(source.dispose);
    source.execute('CREATE TABLE values_table (value TEXT);');
    source.execute('INSERT INTO values_table VALUES (?)', ['preserved']);

    await snapshotSqliteDatabase(
      sourcePath,
      destinationPath,
      openDatabase: _openTestDatabase,
    );

    final snapshot = _openTestDatabase(destinationPath);
    try {
      expect(
        snapshot.select('SELECT value FROM values_table').single['value'],
        'preserved',
      );
      expect(
        snapshot.select('PRAGMA integrity_check;').single.values.first,
        'ok',
      );
    } finally {
      snapshot.dispose();
    }
    source.execute('INSERT INTO values_table VALUES (?)', ['still-open']);
  });

  test('SQLite validation rejects a corrupt import before replacement', () {
    final root = Directory.systemTemp.createTempSync('venera-corrupt-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final corrupt = File('${root.path}${Platform.pathSeparator}corrupt.db')
      ..writeAsStringSync('not a sqlite database');

    expect(
      () =>
          validateSqliteDatabase(corrupt.path, openDatabase: _openTestDatabase),
      throwsA(anything),
    );
  });

  test('SQLite validation rejects a valid database with the wrong schema', () {
    final root = Directory.systemTemp.createTempSync('venera-schema-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}${Platform.pathSeparator}wrong.db';
    final database = _openTestDatabase(path);
    database.execute('CREATE TABLE unrelated (value TEXT);');
    database.dispose();

    expect(
      () => validateSqliteDatabase(
        path,
        openDatabase: _openTestDatabase,
        requiredTables: const ['history'],
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
