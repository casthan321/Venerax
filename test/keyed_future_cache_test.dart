import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/keyed_future_cache.dart';

void main() {
  test('equal keys share an in-flight resource creation', () async {
    final created = Completer<int>();
    var createCount = 0;
    final cache = KeyedFutureCache<String, int>((key) {
      createCount++;
      return created.future;
    });

    final first = cache.getOrCreate('system');
    final second = cache.getOrCreate('system');
    expect(identical(first, second), isTrue);
    expect(createCount, 1);

    created.complete(42);
    expect(await first, 42);
    expect(await second, 42);
  });

  test('different keys create independent resources', () async {
    var createCount = 0;
    final cache = KeyedFutureCache<String?, String>((key) async {
      createCount++;
      return key ?? 'system';
    });

    expect(await cache.getOrCreate(null), 'system');
    expect(
      await cache.getOrCreate('--proxy-server=http://localhost:8080'),
      '--proxy-server=http://localhost:8080',
    );
    expect(createCount, 2);
  });

  test('failed creation is evicted and can be retried', () async {
    var createCount = 0;
    final cache = KeyedFutureCache<String, int>((key) async {
      createCount++;
      if (createCount == 1) throw StateError('WebView2 unavailable');
      return 7;
    });

    await expectLater(cache.getOrCreate('system'), throwsStateError);
    expect(await cache.getOrCreate('system'), 7);
    expect(createCount, 2);
  });
}
