import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

/// Builds a zoomable gallery page whose image lifecycle belongs to [child].
///
/// The image-provider branch in the bundled photo_view fork can reset its
/// loading flag when inherited media data changes, even if it resolves to the
/// same already-loaded image stream. A custom child preserves PhotoView's
/// gestures without putting that faulty wrapper around the image.
PhotoViewGalleryPageOptions buildStableGalleryImagePage({
  required Widget child,
  required Size viewportSize,
  required PhotoViewController controller,
}) {
  return PhotoViewGalleryPageOptions.customChild(
    childSize: viewportSize,
    filterQuality: FilterQuality.medium,
    controller: controller,
    minScale: PhotoViewComputedScale.contained * 1.0,
    maxScale: PhotoViewComputedScale.covered * 10.0,
    child: child,
  );
}

/// Returns zoom-controller pages that are safely outside the gallery's small
/// live-page window and can be disposed.
Iterable<int> galleryControllerPagesToEvict({
  required Iterable<int> controllerPages,
  required int currentPage,
  int retainedRadius = 2,
}) {
  assert(retainedRadius >= 0);
  return controllerPages.where(
    (page) => (page - currentPage).abs() > retainedRadius,
  );
}
