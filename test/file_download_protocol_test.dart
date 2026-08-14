import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/file_download_protocol.dart';

void main() {
  group('parseDownloadContentRange', () {
    test('accepts a complete byte range', () {
      final range = parseDownloadContentRange('bytes 10-19/100');

      expect(range?.start, 10);
      expect(range?.endInclusive, 19);
      expect(range?.totalBytes, 100);
      expect(range?.length, 10);
    });

    test('rejects wildcard, reversed and out-of-bounds ranges', () {
      expect(parseDownloadContentRange('bytes 0-0/*'), isNull);
      expect(parseDownloadContentRange('bytes 9-2/10'), isNull);
      expect(parseDownloadContentRange('bytes 0-10/10'), isNull);
      expect(parseDownloadContentRange('garbage'), isNull);
    });

    test('parses an unsatisfied zero-length response', () {
      expect(parseUnsatisfiedDownloadLength('bytes */0'), 0);
      expect(parseUnsatisfiedDownloadLength('bytes 0-0/1'), isNull);
    });
  });

  group('DownloadCheckpoint', () {
    test('round-trips a valid resume state', () {
      final checkpoint = DownloadCheckpoint(
        url: 'https://example.test/archive.zip',
        totalBytes: 20,
        chunkSize: 10,
        etag: '"revision-1"',
        blocks: [
          DownloadBlockState(start: 0, endExclusive: 10, downloadedBytes: 7),
          DownloadBlockState(start: 10, endExclusive: 20),
        ],
      );

      final restored = DownloadCheckpoint.fromJson(checkpoint.toJson());

      expect(restored, isNotNull);
      expect(restored!.downloadedBytes, 7);
      expect(restored.ifRangeValidator, '"revision-1"');
      expect(
        restored.isValidFor(
          currentUrl: checkpoint.url,
          currentTotalBytes: 20,
          partFileLength: 20,
          currentEtag: '"revision-1"',
        ),
        isTrue,
      );
    });

    test('rejects changed resources and malformed block layouts', () {
      final changed = DownloadCheckpoint(
        url: 'https://example.test/archive.zip',
        totalBytes: 20,
        chunkSize: 10,
        etag: '"old"',
        blocks: [
          DownloadBlockState(start: 0, endExclusive: 10),
          DownloadBlockState(start: 10, endExclusive: 20),
        ],
      );
      expect(
        changed.isValidFor(
          currentUrl: changed.url,
          currentTotalBytes: 20,
          partFileLength: 20,
          currentEtag: '"new"',
        ),
        isFalse,
      );

      final overlapping = DownloadCheckpoint(
        url: changed.url,
        totalBytes: 20,
        chunkSize: 10,
        blocks: [
          DownloadBlockState(start: 0, endExclusive: 12),
          DownloadBlockState(start: 10, endExclusive: 20),
        ],
      );
      expect(
        overlapping.isValidFor(
          currentUrl: changed.url,
          currentTotalBytes: 20,
          partFileLength: 20,
        ),
        isFalse,
      );
    });

    test('uses Last-Modified when a strong ETag is unavailable', () {
      final weak = DownloadCheckpoint(
        url: 'https://example.test/archive.zip',
        totalBytes: 1,
        chunkSize: 1,
        etag: 'W/"weak"',
        lastModified: 'Wed, 12 Aug 2026 12:00:00 GMT',
        blocks: [DownloadBlockState(start: 0, endExclusive: 1)],
      );

      expect(weak.ifRangeValidator, weak.lastModified);
    });

    test('does not resume a same-sized resource without a validator', () {
      final checkpoint = DownloadCheckpoint(
        url: 'https://example.test/archive.zip',
        totalBytes: 10,
        chunkSize: 10,
        blocks: [
          DownloadBlockState(start: 0, endExclusive: 10, downloadedBytes: 5),
        ],
      );

      expect(
        checkpoint.isValidFor(
          currentUrl: checkpoint.url,
          currentTotalBytes: 10,
          partFileLength: 10,
        ),
        isFalse,
      );
    });
  });
}
