import 'dart:math' as math;

import 'package:flutter/foundation.dart';

@immutable
class ContinuousImagePreloadPlan {
  const ContinuousImagePreloadPlan({
    required this.preCachePage,
    required this.preDownloadPages,
  });

  const ContinuousImagePreloadPlan.empty()
    : preCachePage = null,
      preDownloadPages = const [];

  /// The nearest unread page. It is decoded into Flutter's in-memory image
  /// cache so entering it does not have to decode and relayout at once.
  final int? preCachePage;

  /// More distant pages. These only need their compressed bytes on disk until
  /// they become the nearest unread page.
  final List<int> preDownloadPages;
}

/// Keeps continuous-reader warmup bounded: decode only the next page, while
/// downloading the remaining configured look-ahead window.
ContinuousImagePreloadPlan planContinuousImagePreload({
  required int currentPage,
  required int maxPage,
  required int preloadCount,
}) {
  if (currentPage < 1 || currentPage >= maxPage || preloadCount <= 0) {
    return const ContinuousImagePreloadPlan.empty();
  }

  final preCachePage = currentPage + 1;
  final lastPage = math.min(maxPage, currentPage + preloadCount);
  return ContinuousImagePreloadPlan(
    preCachePage: preCachePage,
    preDownloadPages: [
      for (var page = preCachePage + 1; page <= lastPage; page++) page,
    ],
  );
}
