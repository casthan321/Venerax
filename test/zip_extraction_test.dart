import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/zip_extraction.dart';
import 'package:zip_flutter/zip_flutter.dart' show ZipException;

void main() {
  test('accepts portable relative archive entry paths', () {
    expect(isSafeZipEntryName('chapter/page.jpg'), isTrue);
    expect(isSafeZipEntryName(r'chapter\page.jpg'), isTrue);
    expect(isSafeZipEntryName('./chapter/page.jpg'), isTrue);
    expect(isSafeZipEntryName('folder/'), isTrue);
  });

  test('rejects absolute, drive-qualified, and traversal entries', () {
    for (final entry in <String>[
      '',
      '/absolute/page.jpg',
      r'C:\absolute\page.jpg',
      '../escaped.jpg',
      'chapter/../../escaped.jpg',
      r'chapter\..\escaped.jpg',
    ]) {
      expect(isSafeZipEntryName(entry), isFalse, reason: entry);
    }
  });

  group('ZIP metadata budget', () {
    const budget = ZipExtractionBudget(
      maxEntries: 3,
      maxSingleFileBytes: 100,
      maxTotalUncompressedBytes: 200,
      maxPathDepth: 3,
      maxCompressionRatio: 10,
    );

    test('accepts a bounded long-comic-shaped archive', () {
      expect(
        () => validateZipMetadata(
          const [
            ZipArchiveEntryMetadata(
              name: 'chapter/001.jpg',
              isDirectory: false,
              uncompressedBytes: 80,
              compressedBytes: 40,
            ),
            ZipArchiveEntryMetadata(
              name: 'chapter/002.jpg',
              isDirectory: false,
              uncompressedBytes: 90,
              compressedBytes: 45,
            ),
          ],
          budget: budget,
          archiveCompressedBytes: 90,
        ),
        returnsNormally,
      );
    });

    test('rejects excessive entries, file size, total size, and depth', () {
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
            name: 'large.jpg',
            isDirectory: false,
            uncompressedBytes: 101,
          ),
        ],
        const [
          ZipArchiveEntryMetadata(
            name: '1.jpg',
            isDirectory: false,
            uncompressedBytes: 100,
          ),
          ZipArchiveEntryMetadata(
            name: '2.jpg',
            isDirectory: false,
            uncompressedBytes: 101,
          ),
        ],
        const [
          ZipArchiveEntryMetadata(
            name: 'one/two/three/page.jpg',
            isDirectory: false,
            uncompressedBytes: 1,
          ),
        ],
      ];

      for (final metadata in cases) {
        expect(
          () => validateZipMetadata(metadata, budget: budget),
          throwsA(isA<ZipException>()),
        );
      }
    });

    test('rejects entry and whole-archive compression bombs', () {
      expect(
        () => validateZipMetadata(const [
          ZipArchiveEntryMetadata(
            name: 'bomb.bin',
            isDirectory: false,
            uncompressedBytes: 100,
            compressedBytes: 1,
          ),
        ], budget: budget),
        throwsA(isA<ZipException>()),
      );
      expect(
        () => validateZipMetadata(
          const [
            ZipArchiveEntryMetadata(
              name: 'page.jpg',
              isDirectory: false,
              uncompressedBytes: 100,
            ),
          ],
          budget: budget,
          archiveCompressedBytes: 1,
        ),
        throwsA(isA<ZipException>()),
      );
    });
  });
}
