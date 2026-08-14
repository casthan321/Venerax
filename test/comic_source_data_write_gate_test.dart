import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/data_write_gate.dart';

void main() {
  test(
    'retirement drains an active write and rejects all later writes',
    () async {
      final gate = ComicSourceDataWriteGate();
      final entered = Completer<void>();
      final release = Completer<void>();
      var writes = 0;

      final active = gate.run(() async {
        writes++;
        entered.complete();
        await release.future;
        return true;
      });
      await entered.future;

      var retired = false;
      final retirement = gate.retire().then((_) => retired = true);
      await Future<void>.delayed(Duration.zero);
      expect(retired, isFalse);
      expect(await gate.run(() async => true), isFalse);

      release.complete();
      expect(await active, isTrue);
      await retirement;
      expect(retired, isTrue);
      expect(writes, 1);
    },
  );

  test('retirement prevents a queued write from starting', () async {
    final gate = ComicSourceDataWriteGate();
    final entered = Completer<void>();
    final release = Completer<void>();
    final active = gate.run(() async {
      entered.complete();
      await release.future;
      return true;
    });
    await entered.future;
    var queuedRan = false;
    final queued = gate.run(() async {
      queuedRan = true;
      return true;
    });

    final retirement = gate.retire();
    release.complete();
    expect(await active, isTrue);
    expect(await queued, isFalse);
    await retirement;
    expect(queuedRan, isFalse);
  });
}
