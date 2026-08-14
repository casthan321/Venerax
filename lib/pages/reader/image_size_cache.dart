import 'dart:collection';

/// A small LRU for decoded image dimensions used by continuous-mode layout.
///
/// Keeping dimensions avoids replacing every loading placeholder with a
/// differently sized image when revisiting a page. Bounding the cache prevents
/// long reading sessions from retaining one entry for every image ever seen.
class ImageSizeCache<K, V> {
  ImageSizeCache({required this.maximumSize}) : assert(maximumSize > 0);

  final int maximumSize;
  final LinkedHashMap<K, V> _values = LinkedHashMap<K, V>();

  int get length => _values.length;

  V? operator [](K key) {
    final value = _values.remove(key);
    if (value != null) {
      _values[key] = value;
    }
    return value;
  }

  void operator []=(K key, V value) {
    _values.remove(key);
    _values[key] = value;
    while (_values.length > maximumSize) {
      _values.remove(_values.keys.first);
    }
  }

  void clear() => _values.clear();
}
