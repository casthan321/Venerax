import 'dart:async';
import 'dart:collection';

typedef AsyncResourceFactory<K, V> = Future<V> Function(K key);
typedef ResourceDisposer<V> = void Function(V value);

final class AsyncResourceLease<V> {
  AsyncResourceLease(this.value, this._onRelease);

  final V value;
  final void Function() _onRelease;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

/// A small LRU pool for expensive asynchronous resources.
///
/// Entries with active leases are never evicted. A failed factory is removed,
/// so a transient initialization failure can be retried by the next caller.
final class AsyncResourcePool<K, V> {
  AsyncResourcePool({
    required this.maximumEntries,
    required AsyncResourceFactory<K, V> create,
    required ResourceDisposer<V> dispose,
  }) : assert(maximumEntries > 0),
       _create = create,
       _dispose = dispose;

  final int maximumEntries;
  final AsyncResourceFactory<K, V> _create;
  final ResourceDisposer<V> _dispose;
  final LinkedHashMap<K, _ResourceEntry<V>> _entries = LinkedHashMap();

  int get length => _entries.length;

  Future<AsyncResourceLease<V>> acquire(K key) async {
    var entry = _entries.remove(key);
    entry ??= _ResourceEntry(Future<V>.sync(() => _create(key)));
    _entries[key] = entry;
    entry.users++;
    final acquiredEntry = entry;
    _trim();

    try {
      final value = await acquiredEntry.future;
      return AsyncResourceLease(value, () => _release(acquiredEntry));
    } catch (_) {
      acquiredEntry.users--;
      if (identical(_entries[key], acquiredEntry)) _entries.remove(key);
      _trim();
      rethrow;
    }
  }

  void _release(_ResourceEntry<V> entry) {
    if (entry.users > 0) entry.users--;
    _trim();
  }

  void _trim() {
    while (_entries.length > maximumEntries) {
      MapEntry<K, _ResourceEntry<V>>? idle;
      for (final candidate in _entries.entries) {
        if (candidate.value.users == 0) {
          idle = candidate;
          break;
        }
      }
      if (idle == null) return;
      _entries.remove(idle.key);
      unawaited(idle.value.future.then<void>(_dispose, onError: (_) {}));
    }
  }
}

final class _ResourceEntry<V> {
  _ResourceEntry(this.future);

  final Future<V> future;
  int users = 0;
}
