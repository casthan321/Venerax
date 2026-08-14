/// Tracks reader image warmup for the lifetime of one chapter.
///
/// Download and decode are tracked independently because a page downloaded in
/// the wider look-ahead window must still be promoted to Flutter's decoded
/// image cache when it becomes the nearest page.
class ReaderImagePreloadTracker {
  ReaderImagePreloadTracker(int imageCount)
    : assert(imageCount >= 0),
      _imageCount = imageCount;

  final int _imageCount;
  final Set<int> _downloadRequested = <int>{};
  final Set<int> _precacheRequested = <int>{};

  bool requestDownload(int imagePage) {
    if (!_isValid(imagePage) || _downloadRequested.contains(imagePage)) {
      return false;
    }
    _downloadRequested.add(imagePage);
    return true;
  }

  bool requestPrecache(int imagePage) {
    if (!_isValid(imagePage) || _precacheRequested.contains(imagePage)) {
      return false;
    }
    _precacheRequested.add(imagePage);
    _downloadRequested.add(imagePage);
    return true;
  }

  bool _isValid(int imagePage) => imagePage >= 1 && imagePage <= _imageCount;
}
