import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/image_format.dart';

void main() {
  group('isGifImage', () {
    test('rejects empty and truncated data', () {
      expect(isGifImage(Uint8List(0)), isFalse);
      expect(isGifImage(Uint8List.fromList('GIF89'.codeUnits)), isFalse);
    });

    test('rejects non-GIF image data', () {
      expect(
        isGifImage(Uint8List.fromList(<int>[137, 80, 78, 71, 13, 10, 26, 10])),
        isFalse,
      );
    });

    test('accepts GIF87a data', () {
      expect(
        isGifImage(Uint8List.fromList(<int>[...'GIF87a'.codeUnits, 0, 1])),
        isTrue,
      );
    });

    test('accepts GIF89a data', () {
      expect(
        isGifImage(Uint8List.fromList(<int>[...'GIF89a'.codeUnits, 0, 1])),
        isTrue,
      );
    });

    test('rejects a near-match signature', () {
      expect(isGifImage(Uint8List.fromList('GIF89b'.codeUnits)), isFalse);
    });
  });
}
