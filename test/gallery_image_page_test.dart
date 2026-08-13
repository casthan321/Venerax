import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera/pages/reader/gallery_image_page.dart';

void main() {
  test('gallery image uses the stable custom-child path', () {
    const child = SizedBox(key: ValueKey('loaded-image'));
    final controller = PhotoViewController();
    addTearDown(controller.dispose);

    final page = buildStableGalleryImagePage(
      child: child,
      viewportSize: const Size(400, 800),
      controller: controller,
    );

    expect(page.child, same(child));
    expect(page.imageProvider, isNull);
    expect(page.childSize, const Size(400, 800));
    expect(page.controller, same(controller));
  });
}
