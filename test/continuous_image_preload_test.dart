import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/continuous_image_preload.dart';

void main() {
  group('continuous image preload plan', () {
    test('pre-caches only the nearest page and downloads the remainder', () {
      final plan = planContinuousImagePreload(
        currentPage: 4,
        maxPage: 12,
        preloadCount: 4,
      );

      expect(plan.preCachePage, 5);
      expect(plan.preDownloadPages, [6, 7, 8]);
    });

    test('keeps the look-ahead window inside the chapter', () {
      final plan = planContinuousImagePreload(
        currentPage: 9,
        maxPage: 10,
        preloadCount: 4,
      );

      expect(plan.preCachePage, 10);
      expect(plan.preDownloadPages, isEmpty);
    });

    test('promotes a previously downloaded page to the decode slot', () {
      final firstPlan = planContinuousImagePreload(
        currentPage: 1,
        maxPage: 10,
        preloadCount: 4,
      );
      final nextPlan = planContinuousImagePreload(
        currentPage: 2,
        maxPage: 10,
        preloadCount: 4,
      );

      expect(firstPlan.preDownloadPages, contains(3));
      expect(nextPlan.preCachePage, 3);
    });

    test('does no work at the last page or with preloading disabled', () {
      expect(
        planContinuousImagePreload(
          currentPage: 10,
          maxPage: 10,
          preloadCount: 4,
        ).preCachePage,
        isNull,
      );
      expect(
        planContinuousImagePreload(
          currentPage: 4,
          maxPage: 10,
          preloadCount: 0,
        ).preDownloadPages,
        isEmpty,
      );
    });
  });
}
