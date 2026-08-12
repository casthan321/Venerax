import 'dart:async';

/// Runs at most one asynchronous operation at a time and coalesces requests
/// received while it is running into one follow-up operation.
///
/// Errors are reported through [onError] and do not prevent a queued follow-up
/// operation from running.
final class CoalescingAsyncRunner {
  CoalescingAsyncRunner({
    required Future<void> Function() operation,
    required void Function(Object error, StackTrace stackTrace) onError,
    void Function(bool isRunning)? onRunningChanged,
  }) : _operation = operation,
       _onError = onError,
       _onRunningChanged = onRunningChanged;

  final Future<void> Function() _operation;
  final void Function(Object error, StackTrace stackTrace) _onError;
  final void Function(bool isRunning)? _onRunningChanged;

  bool _isRunning = false;
  bool _rerunRequested = false;
  bool _isDisposed = false;
  Completer<void>? _idleCompleter;

  bool get isRunning => _isRunning;

  /// Requests a run and completes after this run and any coalesced follow-up
  /// run have both finished.
  Future<void> request() {
    if (_isDisposed) {
      return Future.value();
    }
    if (_isRunning) {
      _rerunRequested = true;
      return _idleCompleter!.future;
    }

    _isRunning = true;
    final idleCompleter = Completer<void>();
    _idleCompleter = idleCompleter;
    unawaited(_drain(idleCompleter));
    _onRunningChanged?.call(true);
    return idleCompleter.future;
  }

  Future<void> _drain(Completer<void> idleCompleter) async {
    try {
      do {
        _rerunRequested = false;
        try {
          await Future<void>.sync(_operation);
        } catch (error, stackTrace) {
          if (!_isDisposed) {
            _onError(error, stackTrace);
          }
        }
      } while (_rerunRequested && !_isDisposed);
    } finally {
      _isRunning = false;
      _idleCompleter = null;
      try {
        if (!_isDisposed) {
          _onRunningChanged?.call(false);
        }
      } finally {
        idleCompleter.complete();
      }
    }
  }

  void dispose() {
    _isDisposed = true;
    _rerunRequested = false;
  }
}
