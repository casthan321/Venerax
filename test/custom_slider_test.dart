import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';

void main() {
  Widget buildSlider({
    required ValueChanged<double> onChanged,
    bool reversed = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: CustomSlider(
            min: 1,
            max: 100,
            value: 1,
            divisions: 99,
            onChanged: onChanged,
            focusNode: null,
            reversed: reversed,
          ),
        ),
      ),
    );
  }

  testWidgets('commits only the final value of a horizontal drag', (
    tester,
  ) async {
    final values = <double>[];
    await tester.pumpWidget(buildSlider(onChanged: values.add));

    final slider = find.byType(CustomSlider);
    final track = find.descendant(
      of: slider,
      matching: find.byType(GestureDetector),
    );
    final bounds = tester.getRect(track);
    final gesture = await tester.startGesture(
      bounds.centerLeft + const Offset(1, 0),
    );
    await gesture.moveTo(bounds.center);
    await tester.pump();

    expect(values, isEmpty);

    await gesture.moveTo(bounds.centerRight - const Offset(1, 0));
    await gesture.up();
    await tester.pump();

    expect(values, hasLength(1));
    expect(values.single, 100);
  });

  testWidgets('keeps reversed slider direction while dragging', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(buildSlider(onChanged: values.add, reversed: true));

    final slider = find.byType(CustomSlider);
    final track = find.descendant(
      of: slider,
      matching: find.byType(GestureDetector),
    );
    final bounds = tester.getRect(track);
    final gesture = await tester.startGesture(bounds.center);
    await gesture.moveTo(bounds.centerLeft + const Offset(1, 0));
    await gesture.up();
    await tester.pump();

    expect(values, hasLength(1));
    expect(values.single, 100);
  });
}
