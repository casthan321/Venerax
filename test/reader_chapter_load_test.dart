import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader_chapter_load.dart';

void main() {
  group('runReaderChapterLoad', () {
    test('returns a completed chapter result', () async {
      final result = await runReaderChapterLoad(
        () async => <String>['page-1'],
        timeout: const Duration(milliseconds: 20),
      );

      expect(result, <String>['page-1']);
    });

    test('preserves source errors', () async {
      final sourceError = StateError('source failed');

      await expectLater(
        runReaderChapterLoad<int>(
          () => Future<int>.error(sourceError),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(same(sourceError)),
      );
    });

    test('turns a never-completing source into a retryable timeout', () async {
      await expectLater(
        runReaderChapterLoad<int>(
          () => Completer<int>().future,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.duration,
            'duration',
            const Duration(milliseconds: 5),
          ),
        ),
      );
    });
  });

  group('clampReaderPage', () {
    test('keeps a valid page', () {
      expect(clampReaderPage(7, 18), 7);
    });

    test('clamps stale history above the loaded chapter range', () {
      expect(clampReaderPage(13, 1), 1);
    });

    test('clamps non-positive pages and empty ranges to page one', () {
      expect(clampReaderPage(0, 18), 1);
      expect(clampReaderPage(4, 0), 1);
    });
  });

  group('downloaded content invalidation', () {
    test('preserves metadata after a temporary enumeration failure', () {
      expect(
        classifyDownloadedContentInvalidation(
          hasChapters: true,
          directoryDefinitelyMissing: false,
          enumerationCompleted: false,
          imageCount: 0,
        ),
        DownloadedContentInvalidation.none,
      );
    });

    test('invalidates a chapter only after confirmed missing or empty', () {
      expect(
        classifyDownloadedContentInvalidation(
          hasChapters: true,
          directoryDefinitelyMissing: true,
          enumerationCompleted: false,
          imageCount: 0,
        ),
        DownloadedContentInvalidation.chapter,
      );
      expect(
        classifyDownloadedContentInvalidation(
          hasChapters: true,
          directoryDefinitelyMissing: false,
          enumerationCompleted: true,
          imageCount: 0,
        ),
        DownloadedContentInvalidation.chapter,
      );
    });

    test('invalidates the comic record for chapterless downloads', () {
      expect(
        classifyDownloadedContentInvalidation(
          hasChapters: false,
          directoryDefinitelyMissing: false,
          enumerationCompleted: true,
          imageCount: 0,
        ),
        DownloadedContentInvalidation.comic,
      );
    });

    test('keeps metadata when enumeration finds an image', () {
      expect(
        classifyDownloadedContentInvalidation(
          hasChapters: false,
          directoryDefinitelyMissing: false,
          enumerationCompleted: true,
          imageCount: 1,
        ),
        DownloadedContentInvalidation.none,
      );
    });
  });
}
