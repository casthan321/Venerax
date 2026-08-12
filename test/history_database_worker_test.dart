import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/history.dart';

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
  test('history isolate writer keeps the main connection usable', () async {
    final tempDirectory = Directory.systemTemp.createTempSync(
      'venera-history-worker-',
    );
    final databasePath = '${tempDirectory.path}/history.db';
    final mainDatabase = _openTestDatabase(databasePath);
    addTearDown(() {
      mainDatabase.dispose();
      open.reset();
      tempDirectory.deleteSync(recursive: true);
    });
    mainDatabase.execute('''
      create table history (
        id text primary key,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int,
        chapter_group int
      );
    ''');

    await writeHistoryToDatabaseInIsolate(databasePath, [
      'comic-1',
      'Comic 1',
      '',
      'cover-1',
      1,
      42,
      1,
      3,
      '1',
      10,
      null,
    ], openDatabase: _openTestDatabase);

    final inserted = mainDatabase.select(
      'select title, page from history where id = ?',
      ['comic-1'],
    );
    expect(inserted.single['title'], 'Comic 1');
    expect(inserted.single['page'], 3);

    // This write uses the original connection. It would fail if the worker had
    // wrapped and closed the main connection's native pointer.
    mainDatabase.execute('update history set page = ? where id = ?', [
      4,
      'comic-1',
    ]);
    expect(
      mainDatabase.select('select page from history where id = ?', [
        'comic-1',
      ]).single['page'],
      4,
    );
  });

  test('history isolate writer waits for a short database lock', () async {
    final tempDirectory = Directory.systemTemp.createTempSync(
      'venera-history-busy-',
    );
    final databasePath = '${tempDirectory.path}/history.db';
    final mainDatabase = _openTestDatabase(databasePath);
    addTearDown(() {
      mainDatabase.dispose();
      open.reset();
      tempDirectory.deleteSync(recursive: true);
    });
    mainDatabase.execute('''
      create table history (
        id text primary key,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int,
        chapter_group int
      );
    ''');
    mainDatabase.execute('BEGIN EXCLUSIVE;');

    final write = writeHistoryToDatabaseInIsolate(databasePath, [
      'comic-busy',
      'Comic Busy',
      '',
      'cover',
      1,
      42,
      1,
      3,
      '1',
      10,
      null,
    ], openDatabase: _openTestDatabase);
    final completion = expectLater(
      write.timeout(const Duration(seconds: 3)),
      completes,
    );
    // Hold the lock longer than the worker's native busy timeout so the
    // explicit BUSY/LOCKED retry path is exercised on every platform.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    mainDatabase.execute('COMMIT;');

    await completion;
    expect(mainDatabase.select('select count(*) from history;').single[0], 1);
  });

  test('history async queue reports a failure and continues', () async {
    final queue = HistoryAsyncWriteQueue();
    final errors = <Object>[];
    var secondWriteCompleted = false;

    final first = queue.add(
      () async => throw StateError('simulated write failure'),
      onError: (error, _) => errors.add(error),
    );
    final second = queue.add(
      () async => secondWriteCompleted = true,
      onError: (error, _) => errors.add(error),
    );

    await queue.drain();
    await Future.wait([first, second]);
    expect(errors, hasLength(1));
    expect(errors.single, isA<StateError>());
    expect(secondWriteCompleted, isTrue);
  });

  test('history async queue contains an error-reporter failure', () async {
    final queue = HistoryAsyncWriteQueue();

    await queue.add(
      () async => throw StateError('simulated write failure'),
      onError: (_, _) => throw StateError('simulated logger failure'),
    );

    await queue.drain();
  });
}
