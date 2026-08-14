import 'dart:math' as math;

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Chooses the page that occupies the largest part of the reader viewport.
///
/// [ItemPositionsListener] may keep a small trailing part of the previous page
/// as the first item in its iterable. Using that item for history and warmup
/// makes image preloading lag one page behind what the user is actually
/// reading. Ties prefer [currentPage] so resting exactly between pages does not
/// make the page indicator oscillate.
int selectDominantContinuousPage({
  required Iterable<ItemPosition> positions,
  required int currentPage,
  required int maxPage,
}) {
  if (maxPage < 1) return 1;

  const epsilon = 0.000001;
  var selectedPage = currentPage.clamp(1, maxPage);
  var bestVisibleExtent = -1.0;
  var foundVisiblePage = false;

  for (final position in positions) {
    if (position.index < 1 || position.index > maxPage) continue;

    final visibleStart = math.max(0.0, position.itemLeadingEdge);
    final visibleEnd = math.min(1.0, position.itemTrailingEdge);
    final visibleExtent = math.max(0.0, visibleEnd - visibleStart);
    if (visibleExtent <= 0) continue;

    final isClearlyMoreVisible = visibleExtent > bestVisibleExtent + epsilon;
    final isTie = (visibleExtent - bestVisibleExtent).abs() <= epsilon;
    final shouldWinTie =
        isTie &&
        (position.index == currentPage ||
            (selectedPage != currentPage &&
                (position.index - currentPage).abs() <
                    (selectedPage - currentPage).abs()));

    if (!foundVisiblePage || isClearlyMoreVisible || shouldWinTie) {
      selectedPage = position.index;
      bestVisibleExtent = visibleExtent;
      foundVisiblePage = true;
    }
  }

  return selectedPage;
}
