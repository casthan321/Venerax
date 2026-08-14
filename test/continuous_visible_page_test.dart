import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/pages/reader/continuous_visible_page.dart';

void main() {
  ItemPosition position(int index, double leading, double trailing) {
    return ItemPosition(
      index: index,
      itemLeadingEdge: leading,
      itemTrailingEdge: trailing,
    );
  }

  group('dominant continuous page', () {
    test('uses visible area instead of the iterable first item', () {
      final page = selectDominantContinuousPage(
        positions: [position(4, -0.9, 0.1), position(5, 0.1, 1.0)],
        currentPage: 4,
        maxPage: 10,
      );

      expect(page, 5);
    });

    test('keeps the current page when visible areas tie', () {
      final page = selectDominantContinuousPage(
        positions: [position(4, -0.5, 0.5), position(5, 0.5, 1.0)],
        currentPage: 4,
        maxPage: 10,
      );

      expect(page, 4);
    });

    test('ignores leading and trailing sentinel items', () {
      expect(
        selectDominantContinuousPage(
          positions: [
            position(0, 0.0, 1.0),
            position(1, 0.2, 0.8),
            position(11, 0.0, 1.0),
          ],
          currentPage: 1,
          maxPage: 10,
        ),
        1,
      );
    });

    test('falls back to the clamped current page without visible items', () {
      expect(
        selectDominantContinuousPage(
          positions: const [],
          currentPage: 12,
          maxPage: 10,
        ),
        10,
      );
    });
  });
}
