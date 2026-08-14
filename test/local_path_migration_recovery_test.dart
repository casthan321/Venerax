import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

DynamicLibrary _openWindowsSqlite() {
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return DynamicLibrary.open('$systemRoot\\System32\\winsqlite3.dll');
}

void main() {
  late Directory root;
  late Directory dataRoot;
  late Directory oldRoot;
  late Directory newRoot;

  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, _openWindowsSqlite);
    }
  });

  tearDownAll(open.reset);

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'venera-local-migration-recovery-',
    );
    dataRoot = await Directory(FilePath.join(root.path, 'data')).create();
    oldRoot = await Directory(FilePath.join(root.path, 'old-library')).create();
    newRoot = await Directory(FilePath.join(root.path, 'new-library')).create();
    await File(
      FilePath.join(oldRoot.path, 'old-copy.txt'),
    ).writeAsString('old');
    await File(
      FilePath.join(newRoot.path, 'new-copy.txt'),
    ).writeAsString('new');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  void createLocalDatabase(String comicDirectory) {
    final database = sqlite3.open(FilePath.join(dataRoot.path, 'local.db'));
    try {
      database.execute('''
        CREATE TABLE comics (
          id TEXT NOT NULL,
          comic_type INTEGER NOT NULL,
          directory TEXT NOT NULL,
          PRIMARY KEY (id, comic_type)
        );
      ''');
      database.execute(
        'INSERT INTO comics (id, comic_type, directory) VALUES (?, ?, ?);',
        ['comic', 1, comicDirectory],
      );
    } finally {
      database.dispose();
    }
  }

  String readComicDirectory() {
    final database = sqlite3.open(FilePath.join(dataRoot.path, 'local.db'));
    try {
      return database.select('SELECT directory FROM comics;').single[0]
          as String;
    } finally {
      database.dispose();
    }
  }

  Future<void> writeQueue(String taskPath) {
    return File(
      FilePath.join(dataRoot.path, 'downloading_tasks.json'),
    ).writeAsString(
      jsonEncode([
        {'type': 'images', 'path': taskPath},
      ]),
      flush: true,
    );
  }

  Future<String> readQueuePath() async {
    final queue =
        jsonDecode(
              await File(
                FilePath.join(dataRoot.path, 'downloading_tasks.json'),
              ).readAsString(),
            )
            as List;
    return (queue.single as Map)['path'] as String;
  }

  Future<void> writeJournal(String phase) {
    return localPathMigrationJournalFile(dataRoot.path).writeAsString(
      jsonEncode({
        'version': 1,
        'operationId': 'test-migration',
        'phase': phase,
        'oldPath': oldRoot.path,
        'newPath': newRoot.path,
      }),
      flush: true,
    );
  }

  test('rolls queue and database paths back when local_path is old', () async {
    final newComicPath = FilePath.join(newRoot.path, 'comic');
    final newTaskPath = FilePath.join(newRoot.path, 'comic', 'chapter');
    createLocalDatabase(newComicPath);
    await writeQueue(newTaskPath);
    await File(
      FilePath.join(dataRoot.path, 'local_path'),
    ).writeAsString(oldRoot.path, flush: true);
    await writeJournal('committing');

    await recoverInterruptedLocalPathMigration(dataRoot.path);

    expect(readComicDirectory(), FilePath.join(oldRoot.path, 'comic'));
    expect(
      await readQueuePath(),
      FilePath.join(oldRoot.path, 'comic', 'chapter'),
    );
    expect(
      await File(FilePath.join(dataRoot.path, 'local_path')).readAsString(),
      oldRoot.path,
    );
    expect(
      await localPathMigrationJournalFile(dataRoot.path).exists(),
      isFalse,
    );
    expect(
      await File(FilePath.join(oldRoot.path, 'old-copy.txt')).exists(),
      isTrue,
    );
    expect(
      await File(FilePath.join(newRoot.path, 'new-copy.txt')).exists(),
      isTrue,
    );
  });

  test('finishes queue and database rebasing when local_path is new', () async {
    final oldComicPath = FilePath.join(oldRoot.path, 'comic');
    final oldTaskPath = FilePath.join(oldRoot.path, 'comic', 'chapter');
    createLocalDatabase(oldComicPath);
    await writeQueue(oldTaskPath);
    await File(
      FilePath.join(dataRoot.path, 'local_path'),
    ).writeAsString(newRoot.path, flush: true);
    await writeJournal('committing');

    await recoverInterruptedLocalPathMigration(dataRoot.path);

    expect(readComicDirectory(), FilePath.join(newRoot.path, 'comic'));
    expect(
      await readQueuePath(),
      FilePath.join(newRoot.path, 'comic', 'chapter'),
    );
    expect(
      await File(FilePath.join(dataRoot.path, 'local_path')).readAsString(),
      newRoot.path,
    );
    expect(
      await localPathMigrationJournalFile(dataRoot.path).exists(),
      isFalse,
    );
    expect(
      await File(FilePath.join(oldRoot.path, 'old-copy.txt')).exists(),
      isTrue,
    );
    expect(
      await File(FilePath.join(newRoot.path, 'new-copy.txt')).exists(),
      isTrue,
    );
  });
}
