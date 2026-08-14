import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/image_size_cache.dart';

class _CollidingKey {
  const _CollidingKey(this.value);

  final String value;

  @override
  int get hashCode => 1;

  @override
  bool operator ==(Object other) =>
      other is _CollidingKey && other.value == value;
}

void main() {
  test('evicts the least recently used image dimension', () {
    final cache = ImageSizeCache<String, int>(maximumSize: 2)
      ..['first'] = 1
      ..['second'] = 2;

    expect(cache['first'], 1);
    cache['third'] = 3;

    expect(cache['first'], 1);
    expect(cache['second'], isNull);
    expect(cache['third'], 3);
    expect(cache.length, 2);
  });

  test('updating an existing key refreshes it without growing', () {
    final cache = ImageSizeCache<String, int>(maximumSize: 2)
      ..['first'] = 1
      ..['second'] = 2
      ..['first'] = 10
      ..['third'] = 3;

    expect(cache['first'], 10);
    expect(cache['second'], isNull);
    expect(cache.length, 2);
  });

  test('keeps distinct image providers even when their hashes collide', () {
    final cache = ImageSizeCache<_CollidingKey, int>(maximumSize: 2)
      ..[const _CollidingKey('first')] = 1
      ..[const _CollidingKey('second')] = 2;

    expect(cache[const _CollidingKey('first')], 1);
    expect(cache[const _CollidingKey('second')], 2);
  });
}
