/// Shares an asynchronous resource creation for equal keys.
///
/// Failed creations are evicted so a later request can retry. A new key starts
/// a new creation without invalidating callers that still await an older key.
final class KeyedFutureCache<K, V> {
  KeyedFutureCache(this._create);

  final Future<V> Function(K key) _create;

  K? _key;
  bool _hasKey = false;
  Future<V>? _future;

  Future<V> getOrCreate(K key) {
    final cached = _future;
    if (_hasKey && _key == key && cached != null) {
      return cached;
    }

    final creation = Future<V>.sync(() => _create(key));
    late final Future<V> guarded;
    guarded = creation.then(
      (value) => value,
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_future, guarded)) {
          _future = null;
          _key = null;
          _hasKey = false;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _key = key;
    _hasKey = true;
    _future = guarded;
    return guarded;
  }
}
