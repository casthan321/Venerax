/// Owns the logical input lock for one reader page animation at a time.
///
/// A controller animation may finish after a direct jump has superseded it.
/// Tokens keep that stale completion from changing the current lock state.
class PageAnimationGuard {
  int _generation = 0;
  bool _isAnimating = false;

  bool get isAnimating => _isAnimating;

  int start() {
    if (_isAnimating) {
      throw StateError('A page animation is already active');
    }
    _isAnimating = true;
    return ++_generation;
  }

  /// Returns whether [token] still owned the lock and was released.
  bool finish(int token) {
    if (!_isAnimating || token != _generation) {
      return false;
    }
    _isAnimating = false;
    return true;
  }

  /// Invalidates an outstanding completion and releases the logical lock.
  void cancel() {
    _generation++;
    _isAnimating = false;
  }
}

int? failedPageAnimationFallbackTarget({
  required bool animationFailed,
  required bool tokenReleased,
  required bool isDisposed,
  required int targetPage,
}) {
  if (!animationFailed || !tokenReleased || isDisposed) {
    return null;
  }
  return targetPage;
}
