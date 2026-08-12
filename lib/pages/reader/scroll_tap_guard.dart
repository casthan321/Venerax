import 'dart:async';

typedef CancelScheduledCallback = void Function();
typedef DelayedCallbackScheduler =
    CancelScheduledCallback Function(Duration delay, void Function() callback);

CancelScheduledCallback _scheduleWithTimer(
  Duration delay,
  void Function() callback,
) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

/// Prevents a touch used to finish or stop scrolling from becoming a tap.
class ScrollTapGuard {
  ScrollTapGuard({
    this.releaseDelay = const Duration(milliseconds: 300),
    DelayedCallbackScheduler? schedule,
  }) : _schedule = schedule ?? _scheduleWithTimer;

  final Duration releaseDelay;
  final DelayedCallbackScheduler _schedule;

  CancelScheduledCallback? _cancelPendingRelease;
  bool _shouldIgnoreTap = false;
  bool _isDisposed = false;

  bool get shouldIgnoreTap => _shouldIgnoreTap;

  void onScrollStart() {
    if (_isDisposed) return;
    _cancelRelease();
    _shouldIgnoreTap = true;
  }

  void onScrollEnd() {
    if (_isDisposed) return;
    _cancelRelease();
    _cancelPendingRelease = _schedule(releaseDelay, () {
      if (_isDisposed) return;
      _shouldIgnoreTap = false;
      _cancelPendingRelease = null;
    });
  }

  void dispose() {
    _isDisposed = true;
    _cancelRelease();
    _shouldIgnoreTap = false;
  }

  void _cancelRelease() {
    _cancelPendingRelease?.call();
    _cancelPendingRelease = null;
  }
}
