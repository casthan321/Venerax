import 'dart:async';

typedef AsyncValueWriter<T> = Future<void> Function(T value);
typedef PendingValueMerger<T> = T Function(T pending, T next);

/// Serializes asynchronous writes and collapses queued values into one batch.
///
/// A write that is already in progress is never interrupted. Values scheduled
/// while it runs are merged into a single follow-up write, so rapid UI changes
/// do not create an unbounded queue of stale disk operations. Every caller is
/// completed only after the batch containing its value has been written.
class CoalescingAsyncWriter<T> {
  CoalescingAsyncWriter(this._write, {PendingValueMerger<T>? mergePending})
    : _mergePending = mergePending ?? ((_, next) => next);

  final AsyncValueWriter<T> _write;
  final PendingValueMerger<T> _mergePending;

  _PendingWrite<T>? _pending;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  Future<void> schedule(T value) {
    final completer = Completer<void>();
    final pending = _pending;
    if (pending == null) {
      _pending = _PendingWrite(value, [completer]);
    } else {
      pending.value = _mergePending(pending.value, value);
      pending.waiters.add(completer);
    }

    if (!_isRunning) {
      _isRunning = true;
      scheduleMicrotask(_drain);
    }
    return completer.future;
  }

  Future<void> _drain() async {
    while (true) {
      final batch = _pending;
      if (batch == null) {
        _isRunning = false;
        return;
      }
      _pending = null;

      try {
        await _write(batch.value);
      } catch (error, stackTrace) {
        for (final waiter in batch.waiters) {
          waiter.completeError(error, stackTrace);
        }
        continue;
      }

      for (final waiter in batch.waiters) {
        waiter.complete();
      }
    }
  }
}

class _PendingWrite<T> {
  _PendingWrite(this.value, this.waiters);

  T value;
  final List<Completer<void>> waiters;
}
