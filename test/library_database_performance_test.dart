import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';

DynamicLibrary _openWindowsSqlite() {
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return DynamicLibrary.open('$systemRoot\\System32\\winsqlite3.dll');
}

Database _openMemoryDatabase() {
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, _openWindowsSqlite);
  }
  return sqlite3.openInMemory();
}

String _queryPlan(Database database, String sql, [List<Object?>? values]) {
  return database
      .select('EXPLAIN QUERY PLAN $sql', values ?? const [])
      .map((row) => row['detail'])
      .join('\n');
}

void main() {
  tearDown(open.reset);

  test('history time index serves recent-history ordering', () {
    final database = _openMemoryDatabase();
    addTearDown(database.dispose);
    _createHistoryTable(database);

    ensureHistoryPerformanceIndexes(database);

    expect(
      _queryPlan(database, 'SELECT * FROM history ORDER BY time DESC LIMIT 20'),
      contains('history_time_index'),
    );
  });

  test('history lookup caches a database result and validates its type', () {
    final database = _openMemoryDatabase();
    addTearDown(database.dispose);
    _createHistoryTable(database);
    final type = ComicType(42);
    database.execute(
      'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['comic', 'Original', '', '', 1, type.value, 1, 1, '', 1, null],
    );
    final manager = HistoryManager.withDatabase(database);

    final first = manager.find('comic', type);
    expect(first?.title, 'Original');
    database.execute('UPDATE history SET title = ? WHERE id = ?', [
      'Changed behind manager',
      'comic',
    ]);

    expect(identical(manager.find('comic', type), first), isTrue);
    expect(manager.find('comic', ComicType(43)), isNull);
  });

  test('closing history manager clears record and id caches', () {
    final database = _openMemoryDatabase();
    _createHistoryTable(database);
    final type = ComicType(42);
    database.execute(
      'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['comic', 'Cached', '', '', 1, type.value, 1, 1, '', 1, null],
    );
    final manager = HistoryManager.withDatabase(database);
    addTearDown(() {
      if (manager.isInitialized) manager.close();
    });

    expect(manager.find('comic', type)?.title, 'Cached');
    expect(manager.hasLoadedHistoryIdCache, isTrue);
    expect(manager.cachedHistories, isNotEmpty);

    manager.close();

    expect(manager.hasLoadedHistoryIdCache, isFalse);
    expect(manager.cachedHistories, isEmpty);
  });

  test('history schema preserves equal ids from different sources', () {
    final database = _openMemoryDatabase();
    addTearDown(database.dispose);
    _createHistoryTable(database);
    database.execute(
      'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['same-id', 'First source', '', '', 1, 41, 1, 1, '', 1, null],
    );

    ensureHistorySchema(database);
    database.execute(
      'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['same-id', 'Second source', '', '', 2, 42, 1, 1, '', 1, null],
    );

    final rows = database.select(
      'SELECT title, type FROM history WHERE id = ? ORDER BY type',
      ['same-id'],
    );
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['title']), ['First source', 'Second source']);
    final primaryKey =
        database
            .select('PRAGMA table_info(history);')
            .where((row) => (row['pk'] as int) > 0)
            .toList()
          ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
    expect(primaryKey.map((row) => row['name']), ['id', 'type']);
  });

  test('history cache keeps equal ids from different sources independent', () {
    final database = _openMemoryDatabase();
    addTearDown(database.dispose);
    _createHistoryTable(database);
    ensureHistorySchema(database);
    database.execute(
      'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['same-id', 'First source', '', '', 1, 41, 1, 1, '', 1, null],
    );
    database.execute(
      'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['same-id', 'Second source', '', '', 2, 42, 1, 1, '', 1, null],
    );
    final manager = HistoryManager.withDatabase(database);

    expect(manager.find('same-id', ComicType(41))?.title, 'First source');
    expect(manager.find('same-id', ComicType(42))?.title, 'Second source');
  });

  test('history import batch rolls back rows and runtime caches together', () {
    final database = _openMemoryDatabase();
    addTearDown(database.dispose);
    _createHistoryTable(database);
    final manager = HistoryManager.withDatabase(database);

    expect(
      () => manager.runInTransaction<void>(() {
        database.execute(
          'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          ['partial', 'Partial', '', '', 1, 42, 1, 1, '', 1, null],
        );
        manager.updateCache();
        throw const FormatException('malformed later import row');
      }),
      throwsA(isA<FormatException>()),
    );

    expect(database.select('SELECT * FROM history'), isEmpty);
    expect(manager.find('partial', ComicType(42)), isNull);
  });

  test('local-library indexes serve its frequent sorts and name lookup', () {
    final database = _openMemoryDatabase();
    addTearDown(database.dispose);
    database.execute('''
      CREATE TABLE comics (
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

    ensureLocalLibraryPerformanceIndexes(database);

    expect(
      _queryPlan(database, 'SELECT * FROM comics ORDER BY created_at DESC'),
      contains('local_comics_created_at_index'),
    );
    expect(
      _queryPlan(database, 'SELECT * FROM comics ORDER BY title DESC'),
      contains('local_comics_title_index'),
    );
    final nameLookupPlan = _queryPlan(
      database,
      'SELECT * FROM comics WHERE title = ? OR directory = ?',
      ['Comic title', 'comic-directory'],
    );
    expect(nameLookupPlan, contains('local_comics_title_index'));
    expect(nameLookupPlan, contains('local_comics_directory_index'));
  });
}

void _createHistoryTable(Database database) {
  database.execute('''
    CREATE TABLE history (
      id TEXT PRIMARY KEY,
      title TEXT,
      subtitle TEXT,
      cover TEXT,
      time INTEGER,
      type INTEGER,
      ep INTEGER,
      page INTEGER,
      readEpisode TEXT,
      max_page INTEGER,
      chapter_group INTEGER
    );
  ''');
}
