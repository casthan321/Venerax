import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';

void main() {
  test('reader image cache identity includes the processing page', () {
    const first = ReaderImageProvider(
      'https://example.test/image',
      'source',
      'comic',
      'chapter',
      1,
    );
    const second = ReaderImageProvider(
      'https://example.test/image',
      'source',
      'comic',
      'chapter',
      2,
    );

    expect(first.key, isNot(second.key));
    expect(first, isNot(equals(second)));
  });
}
