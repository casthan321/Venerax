import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';

void main() {
  test(
    'window placement accepts negative coordinates for secondary displays',
    () {
      const rect = Rect.fromLTWH(-1600, -200, 1200, 800);

      expect(WindowPlacement.validate(rect), isTrue);
      expect(
        WindowPlacement.hasAccessibleTitleBar(rect, const [
          Rect.fromLTWH(-1920, -300, 1920, 1080),
          Rect.fromLTWH(0, 0, 2560, 1440),
        ]),
        isTrue,
      );
    },
  );

  test('window placement rejects corrupt geometry', () {
    expect(
      WindowPlacement.validate(const Rect.fromLTWH(double.nan, 0, 900, 600)),
      isFalse,
    );
    expect(
      WindowPlacement.validate(const Rect.fromLTWH(0, 0, 100, 100)),
      isFalse,
    );
  });

  test('window placement parser validates all persisted fields', () {
    final placement = WindowPlacement.tryParse(const {
      'x': -1200,
      'y': 40,
      'width': 1000,
      'height': 700,
      'isMaximized': true,
    });

    expect(placement, isNotNull);
    expect(placement!.rect, const Rect.fromLTWH(-1200, 40, 1000, 700));
    expect(placement.isMaximized, isTrue);
    expect(
      WindowPlacement.tryParse(const {
        'x': 0,
        'y': 0,
        'width': '900',
        'height': 600,
        'isMaximized': false,
      }),
      isNull,
    );
  });

  test('off-screen or inaccessible title bars are rejected', () {
    const workAreas = [Rect.fromLTWH(0, 0, 1920, 1040)];

    expect(
      WindowPlacement.hasAccessibleTitleBar(
        const Rect.fromLTWH(3000, 0, 900, 600),
        workAreas,
      ),
      isFalse,
    );
    expect(
      WindowPlacement.hasAccessibleTitleBar(
        const Rect.fromLTWH(100, -100, 900, 600),
        workAreas,
      ),
      isFalse,
    );
    expect(
      WindowPlacement.hasAccessibleTitleBar(
        const Rect.fromLTWH(-840, 20, 900, 600),
        workAreas,
      ),
      isFalse,
    );
    expect(
      WindowPlacement.hasAccessibleTitleBar(
        const Rect.fromLTWH(-800, 20, 900, 600),
        workAreas,
      ),
      isTrue,
    );
  });
}
