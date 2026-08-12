enum GallerySwipeIntent { previous, next }

const double _gallerySwipeDistanceRatio = 0.15;
const double _gallerySwipeMinDistance = 48;
const double _gallerySwipeMaxDistance = 140;
const double _gallerySwipeVelocityThreshold = 900;

/// Resolves a completed gallery drag without depending on reader state.
///
/// [dragDelta] and [primaryVelocity] use Flutter's pointer direction: negative
/// values mean left/up and positive values mean right/down. When [reverse] is
/// true, those directions are reversed for right-to-left galleries.
GallerySwipeIntent? resolveGallerySwipeIntent({
  required double dragDelta,
  required double primaryVelocity,
  required double viewportExtent,
  required bool reverse,
}) {
  if (!dragDelta.isFinite ||
      !primaryVelocity.isFinite ||
      !viewportExtent.isFinite ||
      viewportExtent <= 0) {
    return null;
  }

  final distanceThreshold = (viewportExtent * _gallerySwipeDistanceRatio).clamp(
    _gallerySwipeMinDistance,
    _gallerySwipeMaxDistance,
  );
  final passedDistance = dragDelta.abs() >= distanceThreshold;
  final passedVelocity =
      primaryVelocity.abs() >= _gallerySwipeVelocityThreshold;
  if (!passedDistance && !passedVelocity) {
    return null;
  }

  // A deliberate long drag should not be reversed by a small last-moment
  // flick. Velocity decides only when distance alone was insufficient.
  final direction = passedDistance ? dragDelta : primaryVelocity;
  final isNext = reverse ? direction > 0 : direction < 0;
  return isNext ? GallerySwipeIntent.next : GallerySwipeIntent.previous;
}
