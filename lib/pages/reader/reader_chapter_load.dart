import 'dart:async';

const readerChapterLoadTimeout = Duration(seconds: 30);

Future<T> runReaderChapterLoad<T>(
  Future<T> Function() load, {
  Duration timeout = readerChapterLoadTimeout,
}) {
  return Future<T>.sync(load).timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      'Comic source did not finish loading chapter pages',
      timeout,
    ),
  );
}

int clampReaderPage(int page, int maxPage) {
  if (maxPage < 1) {
    return 1;
  }
  return page.clamp(1, maxPage);
}

enum DownloadedContentInvalidation { none, chapter, comic }

/// Classifies when a downloaded marker is known to be stale.
///
/// A failed enumeration is deliberately not enough evidence: removable
/// storage and SAF grants can be temporarily unavailable. Only a confirmed
/// missing directory or an enumeration that completed with no images may
/// invalidate metadata.
DownloadedContentInvalidation classifyDownloadedContentInvalidation({
  required bool hasChapters,
  required bool directoryDefinitelyMissing,
  required bool enumerationCompleted,
  required int imageCount,
}) {
  final isDefinitelyUnavailable =
      directoryDefinitelyMissing || (enumerationCompleted && imageCount == 0);
  if (!isDefinitelyUnavailable) {
    return DownloadedContentInvalidation.none;
  }
  return hasChapters
      ? DownloadedContentInvalidation.chapter
      : DownloadedContentInvalidation.comic;
}
