import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/download_state.dart';

void main() {
  group('bounded image-list loading', () {
    test('returns a completed source result', () async {
      expect(
        await runDownloadImageListLoad(
          () async => 'images',
          timeout: const Duration(milliseconds: 20),
        ),
        'images',
      );
    });

    test('turns a never-completing source into a retryable timeout', () async {
      await expectLater(
        runDownloadImageListLoad<void>(
          () => Completer<void>().future,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('cancel cleanup ordering', () {
    test('does not resume the queue until cleanup finishes', () async {
      final cleanup = Completer<void>();
      final events = <String>[];

      final operation = runDownloadCleanupBeforeResume(
        cleanup: () {
          events.add('cleanup');
          return cleanup.future;
        },
        resumeNext: () => events.add('resume'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, ['cleanup']);

      cleanup.complete();
      await operation;
      expect(events, ['cleanup', 'resume']);
    });

    test('resumes the queue even when cleanup fails', () async {
      var resumed = false;

      await expectLater(
        runDownloadCleanupBeforeResume(
          cleanup: () => Future<void>.error(StateError('cleanup failed')),
          resumeNext: () => resumed = true,
        ),
        throwsStateError,
      );
      expect(resumed, isTrue);
    });
  });

  group('image-list completion', () {
    const expected = ['chapter-1', 'chapter-2', 'chapter-3'];

    test('a partial restored map is not complete', () {
      final imageLists = {
        'chapter-1': ['1.jpg'],
        'chapter-2': ['2.jpg'],
      };

      expect(hasCompleteImageLists(expected, imageLists), isFalse);
      expect(missingImageListKeys(expected, imageLists), ['chapter-3']);
    });

    test('an empty chapter image list is treated as failed', () {
      final imageLists = {
        'chapter-1': ['1.jpg'],
        'chapter-2': <String>[],
        'chapter-3': ['3.jpg'],
      };

      expect(hasCompleteImageLists(expected, imageLists), isFalse);
      expect(missingImageListKeys(expected, imageLists), ['chapter-2']);
    });

    test('all requested chapters need non-empty image lists', () {
      final imageLists = {
        'chapter-1': ['1.jpg'],
        'chapter-2': ['2.jpg'],
        'chapter-3': ['3.jpg'],
        'unrequested': ['extra.jpg'],
      };

      expect(hasCompleteImageLists(expected, imageLists), isTrue);
      expect(missingImageListKeys(expected, imageLists), isEmpty);
    });

    test('an empty request cannot complete a download', () {
      expect(hasCompleteImageLists(const [], const {}), isFalse);
    });
  });

  group('downloaded page completion', () {
    test('requires every zero-based page index', () {
      expect(hasCompleteDownloadedPageIndexes(3, const [0, 1, 2]), isTrue);
      expect(hasCompleteDownloadedPageIndexes(3, const [0, 2]), isFalse);
      expect(hasCompleteDownloadedPageIndexes(3, const [1, 2, 3]), isFalse);
      expect(hasCompleteDownloadedPageIndexes(0, const []), isFalse);
    });
  });

  group('download run guard', () {
    test('pause invalidates work from the previous run', () {
      final guard = DownloadRunGuard();
      final firstRun = guard.start();

      expect(guard.isActive(firstRun), isTrue);
      guard.stop();

      expect(guard.isActive(firstRun), isFalse);
      expect(guard.isRunning, isFalse);
    });

    test('a resumed run does not reactivate an older continuation', () {
      final guard = DownloadRunGuard();
      final firstRun = guard.start();
      guard.stop();
      final resumedRun = guard.start();

      expect(guard.isActive(firstRun), isFalse);
      expect(guard.isActive(resumedRun), isTrue);
    });
  });
}
