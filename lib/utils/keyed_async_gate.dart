import 'dart:async';

/// Runs operations with the same [key] sequentially without polling.
///
/// Different keys remain fully concurrent. A failed operation releases the
/// next waiter, and an idle key is removed so the map does not grow forever.
class KeyedAsyncGate<K> {
  final Map<K, Future<void>> _tails = {};

  int get activeKeyCount => _tails.length;

  Future<T> run<T>(K key, Future<T> Function() operation) async {
    final previous = _tails[key] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = previous.then<void>(
      (_) => release.future,
      onError: (_, _) => release.future,
    );
    _tails[key] = tail;

    try {
      try {
        await previous;
      } catch (_) {
        // Failure belongs to the previous caller. It must not poison the key.
      }
      return await operation();
    } finally {
      release.complete();
      if (identical(_tails[key], tail)) {
        _tails.remove(key);
      }
    }
  }
}
