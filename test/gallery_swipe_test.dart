import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/gallery_swipe.dart';

void main() {
  group('resolveGallerySwipeIntent', () {
    test('maps left/up drags to next and right/down drags to previous', () {
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -61,
          primaryVelocity: 0,
          viewportExtent: 400,
          reverse: false,
        ),
        GallerySwipeIntent.next,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: 61,
          primaryVelocity: 0,
          viewportExtent: 400,
          reverse: false,
        ),
        GallerySwipeIntent.previous,
      );
    });

    test('reverses physical directions for right-to-left galleries', () {
      expect(
        resolveGallerySwipeIntent(
          dragDelta: 61,
          primaryVelocity: 0,
          viewportExtent: 400,
          reverse: true,
        ),
        GallerySwipeIntent.next,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -61,
          primaryVelocity: 0,
          viewportExtent: 400,
          reverse: true,
        ),
        GallerySwipeIntent.previous,
      );
    });

    test('ignores a drag below both distance and velocity thresholds', () {
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -59,
          primaryVelocity: -899,
          viewportExtent: 400,
          reverse: false,
        ),
        isNull,
      );
    });

    test('uses velocity for a short flick', () {
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -20,
          primaryVelocity: -900,
          viewportExtent: 400,
          reverse: false,
        ),
        GallerySwipeIntent.next,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: 20,
          primaryVelocity: 900,
          viewportExtent: 400,
          reverse: true,
        ),
        GallerySwipeIntent.next,
      );
    });

    test(
      'keeps a qualifying drag direction over opposite release velocity',
      () {
        expect(
          resolveGallerySwipeIntent(
            dragDelta: -80,
            primaryVelocity: 2000,
            viewportExtent: 400,
            reverse: false,
          ),
          GallerySwipeIntent.next,
        );
      },
    );

    test('clamps the distance threshold for small and large viewports', () {
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -47,
          primaryVelocity: 0,
          viewportExtent: 100,
          reverse: false,
        ),
        isNull,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -48,
          primaryVelocity: 0,
          viewportExtent: 100,
          reverse: false,
        ),
        GallerySwipeIntent.next,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -139,
          primaryVelocity: 0,
          viewportExtent: 2000,
          reverse: false,
        ),
        isNull,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -140,
          primaryVelocity: 0,
          viewportExtent: 2000,
          reverse: false,
        ),
        GallerySwipeIntent.next,
      );
    });

    test('rejects non-finite or non-positive geometry', () {
      expect(
        resolveGallerySwipeIntent(
          dragDelta: double.nan,
          primaryVelocity: 0,
          viewportExtent: 400,
          reverse: false,
        ),
        isNull,
      );
      expect(
        resolveGallerySwipeIntent(
          dragDelta: -100,
          primaryVelocity: 0,
          viewportExtent: 0,
          reverse: false,
        ),
        isNull,
      );
    });
  });
}
