import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/keyed_async_gate.dart';

void main() {
  test('serializes operations sharing a key without polling', () async {
    final gate = KeyedAsyncGate<String>();
    final firstRelease = Completer<void>();
    final order = <String>[];

    final first = gate.run('comic', () async {
      order.add('first-start');
      await firstRelease.future;
      order.add('first-end');
    });
    final second = gate.run('comic', () async {
      order.add('second');
    });
    await Future<void>.delayed(Duration.zero);

    expect(order, ['first-start']);
    firstRelease.complete();
    await Future.wait([first, second]);
    expect(order, ['first-start', 'first-end', 'second']);
    expect(gate.activeKeyCount, 0);
  });

  test('allows different keys to run concurrently', () async {
    final gate = KeyedAsyncGate<String>();
    final release = Completer<void>();
    var secondStarted = false;

    final first = gate.run('one', () => release.future);
    final second = gate.run('two', () async => secondStarted = true);
    await second;

    expect(secondStarted, isTrue);
    release.complete();
    await first;
  });

  test('a failed operation does not poison later requests', () async {
    final gate = KeyedAsyncGate<String>();
    final first = gate.run<void>('comic', () async {
      throw StateError('network failed');
    });
    final second = gate.run('comic', () async => 42);

    await expectLater(first, throwsStateError);
    await expectLater(second, completion(42));
    expect(gate.activeKeyCount, 0);
  });
}
