import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/comic_archive_import.dart';
import 'package:venera/utils/zip_extraction.dart';
import 'package:zip_flutter/zip_flutter.dart' show ZipException;

void main() {
  group('comic archive metadata preflight', () {
    const smallBudget = ZipExtractionBudget(
      maxEntries: 3,
      maxSingleFileBytes: 100,
      maxTotalUncompressedBytes: 150,
      maxPathDepth: 3,
      maxCompressionRatio: 10,
    );

    test('accepts bounded portable entries', () {
      expect(
        () => validateComicArchiveMetadata(
          const [
            ZipArchiveEntryMetadata(
              name: 'chapter/1.jpg',
              isDirectory: false,
              uncompressedBytes: 80,
            ),
            ZipArchiveEntryMetadata(
              name: 'chapter/2.jpg',
              isDirectory: false,
              uncompressedBytes: 60,
            ),
          ],
          budget: smallBudget,
          archiveCompressedBytes: 20,
        ),
        returnsNormally,
      );
    });

    test('rejects traversal and absolute paths before extraction', () {
      for (final name in <String>[
        '../outside.jpg',
        '/absolute.jpg',
        r'C:\absolute.jpg',
      ]) {
        expect(
          () => validateComicArchiveMetadata([
            ZipArchiveEntryMetadata(
              name: name,
              isDirectory: false,
              uncompressedBytes: 1,
            ),
          ], budget: smallBudget),
          throwsA(anything),
          reason: name,
        );
      }
    });

    test('rejects entry count, depth, single-file, and total limits', () {
      final cases = <List<ZipArchiveEntryMetadata>>[
        const [
          ZipArchiveEntryMetadata(
            name: '1.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
          ZipArchiveEntryMetadata(
            name: '2.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
          ZipArchiveEntryMetadata(
            name: '3.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
          ZipArchiveEntryMetadata(
            name: '4.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
        ],
        const [
          ZipArchiveEntryMetadata(
            name: 'a/b/c/d.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
        ],
        const [
          ZipArchiveEntryMetadata(
            name: 'large.jpg',
            isDirectory: false,
            uncompressedBytes: 101,
          ),
        ],
        const [
          ZipArchiveEntryMetadata(
            name: '1.jpg',
            isDirectory: false,
            uncompressedBytes: 80,
          ),
          ZipArchiveEntryMetadata(
            name: '2.jpg',
            isDirectory: false,
            uncompressedBytes: 80,
          ),
        ],
      ];

      for (final entries in cases) {
        expect(
          () => validateComicArchiveMetadata(entries, budget: smallBudget),
          throwsA(anything),
        );
      }
    });

    test('rejects aliases and file-directory conflicts', () {
      final cases = <List<ZipArchiveEntryMetadata>>[
        const [
          ZipArchiveEntryMetadata(
            name: 'Page.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
          ZipArchiveEntryMetadata(
            name: 'page.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
        ],
        const [
          ZipArchiveEntryMetadata(
            name: 'chapter',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
          ZipArchiveEntryMetadata(
            name: 'chapter/1.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
        ],
      ];

      for (final entries in cases) {
        expect(
          () => validateComicArchiveMetadata(entries, budget: smallBudget),
          throwsA(isA<ComicArchiveImportException>()),
        );
      }
    });
  });

  group('transactional comic directory publishing', () {
    late Directory temporaryRoot;

    setUp(() {
      temporaryRoot = Directory.systemTemp.createTempSync(
        'venera_cbz_transaction_test_',
      );
    });

    tearDown(() {
      if (temporaryRoot.existsSync()) {
        temporaryRoot.deleteSync(recursive: true);
      }
    });

    test('sanitized title collisions publish to a unique directory', () async {
      final existing = Directory(
        '${temporaryRoot.path}${Platform.pathSeparator}A B',
      )..createSync();
      final sentinel = File(
        '${existing.path}${Platform.pathSeparator}sentinel.txt',
      )..writeAsStringSync('original');
      final expected = <String, int>{'cover.jpg': 3};

      final published = await buildComicDirectoryTransactionally(
        libraryRoot: temporaryRoot,
        title: 'A:B',
        build: (staging) {
          File(
            '${staging.path}${Platform.pathSeparator}cover.jpg',
          ).writeAsBytesSync([1, 2, 3]);
        },
        validate: (directory) {
          _expectFiles(directory, expected);
        },
      );

      expect(published.path, isNot(existing.path));
      expect(published.path, endsWith('A B (1)'));
      expect(sentinel.readAsStringSync(), 'original');
      expect(
        temporaryRoot.listSync().where(
          (entity) => entity.path
              .split(Platform.pathSeparator)
              .last
              .startsWith(comicImportStagingPrefix),
        ),
        isEmpty,
      );
    });

    test(
      'failed build removes staging and leaves no final directory',
      () async {
        await expectLater(
          buildComicDirectoryTransactionally(
            libraryRoot: temporaryRoot,
            title: 'Failed Comic',
            build: (staging) {
              File(
                '${staging.path}${Platform.pathSeparator}partial.jpg',
              ).writeAsBytesSync([1]);
              throw StateError('copy failed');
            },
            validate: (_) {},
          ),
          throwsStateError,
        );

        expect(temporaryRoot.listSync(), isEmpty);
      },
    );

    test(
      'failed post-publish validation rolls back published output',
      () async {
        var validationCount = 0;
        await expectLater(
          buildComicDirectoryTransactionally(
            libraryRoot: temporaryRoot,
            title: 'Post Validation Failure',
            build: (staging) {
              File(
                '${staging.path}${Platform.pathSeparator}cover.jpg',
              ).writeAsBytesSync([1]);
            },
            validate: (_) {
              validationCount++;
              if (validationCount == 2) {
                throw StateError('provider changed output');
              }
            },
          ),
          throwsStateError,
        );

        expect(temporaryRoot.listSync(), isEmpty);
      },
    );
  });

  group('comic ZIP extraction preflight', () {
    late Directory temporaryRoot;

    setUp(() {
      temporaryRoot = Directory.systemTemp.createTempSync(
        'venera_comic_zip_preflight_test_',
      );
    });

    tearDown(() {
      if (temporaryRoot.existsSync()) {
        temporaryRoot.deleteSync(recursive: true);
      }
    });

    test('detects an existing output before any output is written', () {
      final destination = Directory('${temporaryRoot.path}/output')
        ..createSync();
      final sentinel = File('${destination.path}/taken.jpg')
        ..writeAsBytesSync([9]);

      expect(
        () => preflightZipOutputCollisions(destination.path, const [
          'first.jpg',
          'taken.jpg',
        ]),
        throwsA(isA<ZipException>()),
      );

      expect(File('${destination.path}/first.jpg').existsSync(), isFalse);
      expect(sentinel.readAsBytesSync(), [9]);
    });

    test('rejects an existing file ancestor path', () {
      final destination = Directory('${temporaryRoot.path}/output')
        ..createSync();
      File('${destination.path}/chapter').writeAsBytesSync([9]);

      expect(
        () => preflightZipOutputCollisions(destination.path, const [
          'chapter/1.jpg',
        ]),
        throwsA(isA<ZipException>()),
      );
    });
  });

  test('reserved Windows device titles are made portable', () {
    expect(sanitizeComicDirectoryName('CON'), '_CON');
    expect(sanitizeComicDirectoryName('nul.txt'), '_nul.txt');
  });
}

void _expectFiles(Directory directory, Map<String, int> expected) {
  final files = directory.listSync(recursive: true).whereType<File>().toList();
  expect(files, hasLength(expected.length));
  for (final entry in expected.entries) {
    final file = File('${directory.path}${Platform.pathSeparator}${entry.key}');
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), entry.value);
  }
}
