import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/archive_extraction.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-archive-extract-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'failed extraction leaves the existing comic directory intact',
    () async {
      final output = Directory('${root.path}/comic')..createSync();
      final original = File('${output.path}/page-1.jpg')
        ..writeAsStringSync('known-good');

      await expectLater(
        extractArchiveTransactionally(
          archivePath: '${root.path}/comic.zip',
          outputPath: output.path,
          scratchRoot: root.path,
          requiresSafBridge: false,
          operationId: 'failed',
          extract: (_, destination) async {
            await File(
              '$destination${Platform.pathSeparator}partial.jpg',
            ).writeAsString('partial');
            throw const FileSystemException('broken archive');
          },
          copy: (_, _) async {},
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await original.readAsString(), 'known-good');
      expect(
        Directory(root.path).listSync().where(
          (entry) => entry.path.contains('venera-extract-failed'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'successful extraction replaces the old directory as one commit',
    () async {
      final output = Directory('${root.path}/comic')..createSync();
      File('${output.path}/old.jpg').writeAsStringSync('old');

      await extractArchiveTransactionally(
        archivePath: '${root.path}/comic.zip',
        outputPath: output.path,
        scratchRoot: root.path,
        requiresSafBridge: false,
        operationId: 'success',
        extract: (_, destination) async {
          await File(
            '$destination${Platform.pathSeparator}new.jpg',
          ).writeAsString('new');
        },
        copy: (_, _) async {},
      );

      expect(await File('${output.path}/new.jpg').readAsString(), 'new');
      expect(await File('${output.path}/old.jpg').exists(), isFalse);
    },
  );

  test('validation failure is never published', () async {
    final output = Directory('${root.path}/comic')..createSync();
    File('${output.path}/old.jpg').writeAsStringSync('old');

    await expectLater(
      extractArchiveTransactionally(
        archivePath: '${root.path}/comic.zip',
        outputPath: output.path,
        scratchRoot: root.path,
        requiresSafBridge: false,
        operationId: 'invalid',
        extract: (_, destination) async {
          await File(
            '$destination${Platform.pathSeparator}metadata.txt',
          ).writeAsString('not an image');
        },
        copy: (_, _) async {},
        validate: (_) async => throw const FormatException('no images'),
      ),
      throwsA(isA<FormatException>()),
    );

    expect(await File('${output.path}/old.jpg').readAsString(), 'old');
  });

  test('cancellation after extraction never publishes staging', () async {
    final output = Directory('${root.path}/comic')..createSync();
    File('${output.path}/old.jpg').writeAsStringSync('old');
    var cancelled = false;

    await expectLater(
      extractArchiveTransactionally(
        archivePath: '${root.path}/comic.zip',
        outputPath: output.path,
        scratchRoot: root.path,
        requiresSafBridge: false,
        operationId: 'cancel-before-publish',
        extract: (_, destination) async {
          await File(
            '$destination${Platform.pathSeparator}new.jpg',
          ).writeAsString('new');
          cancelled = true;
        },
        copy: (_, _) async {},
        isCancelled: () => cancelled,
      ),
      throwsA(isA<ArchiveExtractionCancelled>()),
    );

    expect(await File('${output.path}/old.jpg').readAsString(), 'old');
    expect(await File('${output.path}/new.jpg').exists(), isFalse);
  });

  test(
    'cancellation after moving the old output restores it before publish',
    () async {
      final output = Directory('${root.path}/comic')..createSync();
      File('${output.path}/old.jpg').writeAsStringSync('old');
      final staging = Directory('${root.path}/staging')..createSync();
      File('${staging.path}/new.jpg').writeAsStringSync('new');
      var cancelled = false;
      var renameCalls = 0;

      Future<Directory> cancelAfterBackup(Directory source, String path) async {
        final renamed = await source.rename(path);
        renameCalls++;
        if (renameCalls == 1) cancelled = true;
        return renamed;
      }

      await expectLater(
        replaceDirectoryWithStaging(
          staging,
          output,
          operationId: 'cancel-after-backup',
          rename: cancelAfterBackup,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<ArchiveExtractionCancelled>()),
      );

      expect(await File('${output.path}/old.jpg').readAsString(), 'old');
      expect(await File('${output.path}/new.jpg').exists(), isFalse);
    },
  );

  test(
    'cancellation after installing staging restores previous output',
    () async {
      final output = Directory('${root.path}/comic')..createSync();
      File('${output.path}/old.jpg').writeAsStringSync('old');
      final staging = Directory('${root.path}/staging')..createSync();
      File('${staging.path}/new.jpg').writeAsStringSync('new');
      var cancelled = false;
      var renameCalls = 0;

      Future<Directory> cancelAfterInstall(
        Directory source,
        String path,
      ) async {
        final renamed = await source.rename(path);
        renameCalls++;
        if (renameCalls == 2) cancelled = true;
        return renamed;
      }

      await expectLater(
        replaceDirectoryWithStaging(
          staging,
          output,
          operationId: 'cancel-after-install',
          rename: cancelAfterInstall,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<ArchiveExtractionCancelled>()),
      );

      expect(await File('${output.path}/old.jpg').readAsString(), 'old');
      expect(await File('${output.path}/new.jpg').exists(), isFalse);
    },
  );

  test('beforeCommit runs only after cancellation checkpoints', () async {
    final output = Directory('${root.path}/comic');
    final staging = Directory('${root.path}/staging')..createSync();
    File('${staging.path}/new.jpg').writeAsStringSync('new');
    var committed = false;

    await replaceDirectoryWithStaging(
      staging,
      output,
      operationId: 'before-commit',
      isCancelled: () => false,
      beforeCommit: (_) => committed = true,
    );

    expect(committed, isTrue);
    expect(await File('${output.path}/new.jpg').readAsString(), 'new');
  });

  test('beforeCommit failure restores the previous output', () async {
    final output = Directory('${root.path}/comic')..createSync();
    File('${output.path}/old.jpg').writeAsStringSync('old');
    final staging = Directory('${root.path}/staging')..createSync();
    File('${staging.path}/new.jpg').writeAsStringSync('new');

    await expectLater(
      replaceDirectoryWithStaging(
        staging,
        output,
        operationId: 'commit-callback-failure',
        beforeCommit: (_) => throw const FileSystemException(
          'simulated metadata commit failure',
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File('${output.path}/old.jpg').readAsString(), 'old');
    expect(await File('${output.path}/new.jpg').exists(), isFalse);
  });

  test('failed publish restores the previous directory', () async {
    final output = Directory('${root.path}/comic')..createSync();
    File('${output.path}/old.jpg').writeAsStringSync('old');
    final staging = Directory('${root.path}/staging')..createSync();
    File('${staging.path}/new.jpg').writeAsStringSync('new');
    var calls = 0;

    Future<Directory> failSecondRename(Directory source, String path) async {
      calls++;
      if (calls == 2) {
        throw const FileSystemException('simulated publish failure');
      }
      return source.rename(path);
    }

    await expectLater(
      replaceDirectoryWithStaging(
        staging,
        output,
        operationId: 'rollback',
        rename: failSecondRename,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File('${output.path}/old.jpg').readAsString(), 'old');
    expect(await File('${staging.path}/new.jpg').readAsString(), 'new');
  });
}
