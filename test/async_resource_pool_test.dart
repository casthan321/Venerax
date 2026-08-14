import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/async_resource_pool.dart';

void main() {
  test('reuses an expensive resource for the same key', () async {
    var created = 0;
    final pool = AsyncResourcePool<String, int>(
      maximumEntries: 2,
      create: (_) async => ++created,
      dispose: (_) {},
    );

    final first = await pool.acquire('same');
    final second = await pool.acquire('same');
    expect(first.value, second.value);
    expect(created, 1);
    first.release();
    second.release();
  });

  test('does not evict a resource while it has an active lease', () async {
    final disposed = <String>[];
    final pool = AsyncResourcePool<String, String>(
      maximumEntries: 1,
      create: (key) async => key,
      dispose: disposed.add,
    );

    final first = await pool.acquire('first');
    final second = await pool.acquire('second');
    expect(disposed, isEmpty);
    first.release();
    await Future<void>.delayed(Duration.zero);
    expect(disposed, ['first']);
    second.release();
  });

  test('allows retry after a failed creation', () async {
    var attempts = 0;
    final pool = AsyncResourcePool<String, int>(
      maximumEntries: 1,
      create: (_) async {
        if (attempts++ == 0) throw StateError('temporary');
        return 42;
      },
      dispose: (_) {},
    );

    await expectLater(pool.acquire('key'), throwsStateError);
    final lease = await pool.acquire('key');
    expect(lease.value, 42);
    lease.release();
  });
}
