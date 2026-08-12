import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/favorites.dart';

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
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'venera-database-worker-',
    );
  });

  tearDown(() async {
    open.reset();
    await temporaryDirectory.delete(recursive: true);
  });

  test('favorites worker leaves the main database connection usable', () async {
    final databasePath = p.join(temporaryDirectory.path, 'favorites.db');
    final mainDatabase = _openTestDatabase(databasePath);
    addTearDown(mainDatabase.dispose);
    mainDatabase.execute('''
      create table "reading" (
        id text not null,
        type integer not null
      );
    ''');
    mainDatabase.execute('insert into "reading" (id, type) values (?, ?);', [
      'comic-id',
      42,
    ]);

    final hashes = await LocalFavoritesManager.loadFavoriteHashesInIsolate(
      const ['reading'],
      databasePath,
      openDatabase: _openTestDatabase,
    );

    expect(hashes['comic-id'.hashCode ^ 42], 1);
    expect(mainDatabase.select('select count(*) from "reading";').first[0], 1);
    mainDatabase.execute('update "reading" set type = ? where id = ?;', [
      43,
      'comic-id',
    ]);
    expect(
      mainDatabase.select('select type from "reading" where id = ?;', [
        'comic-id',
      ]).first[0],
      43,
    );
  });

  test(
    'cache scan worker leaves the main database connection usable',
    () async {
      final databasePath = p.join(temporaryDirectory.path, 'cache.db');
      final cacheDirectory = await Directory(
        p.join(temporaryDirectory.path, 'cache'),
      ).create();
      final bucket = await Directory(p.join(cacheDirectory.path, '0')).create();
      final managedFile = File(p.join(bucket.path, 'managed.bin'));
      await managedFile.writeAsBytes(const [1, 2, 3, 4]);

      final mainDatabase = _openTestDatabase(databasePath);
      addTearDown(mainDatabase.dispose);
      mainDatabase.execute('''
      create table cache (
        key text primary key not null,
        dir text not null,
        name text not null,
        expires integer not null,
        type text
      );
    ''');
      mainDatabase.execute(
        'insert into cache (key, dir, name, expires) values (?, ?, ?, ?);',
        ['key', '0', 'managed.bin', 1],
      );

      final scan = await scanCacheDirectoryInIsolate(
        databasePath,
        cacheDirectory.path,
        openDatabase: _openTestDatabase,
      );

      expect(scan.totalSize, 4);
      expect(scan.unmanagedFiles, isEmpty);
      expect(mainDatabase.select('select count(*) from cache;').first[0], 1);
      mainDatabase.execute('update cache set expires = ? where key = ?;', [
        2,
        'key',
      ]);
      expect(
        mainDatabase.select('select expires from cache where key = ?;', [
          'key',
        ]).first[0],
        2,
      );
    },
  );
}
