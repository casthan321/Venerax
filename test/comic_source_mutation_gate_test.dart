import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/mutation_gate.dart';

void main() {
  test('rejects overlapping comic source mutations without queueing', () async {
    final gate = ComicSourceMutationGate();
    final release = Completer<void>();
    var secondRan = false;

    final first = gate.run(() => release.future);
    expect(gate.isActive, isTrue);
    expect(
      await gate.run(() async {
        secondRan = true;
      }),
      isFalse,
    );
    expect(secondRan, isFalse);

    release.complete();
    expect(await first, isTrue);
    expect(gate.isActive, isFalse);
  });

  test('releases the gate after an operation fails', () async {
    final gate = ComicSourceMutationGate();

    await expectLater(
      gate.run(() async => throw StateError('failed')),
      throwsStateError,
    );
    expect(gate.isActive, isFalse);
    expect(await gate.run(() async {}), isTrue);
  });
}
