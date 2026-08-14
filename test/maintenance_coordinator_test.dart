import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/maintenance_coordinator.dart';

void main() {
  test('maintenance lease stays active until async work completes', () async {
    final coordinator = MaintenanceCoordinator.instance;
    final completer = Completer<void>();
    final states = <bool>[];
    void listener() => states.add(coordinator.isActive);
    coordinator.addListener(listener);
    addTearDown(() => coordinator.removeListener(listener));

    final operation = coordinator.run('Import App Data', () async {
      expect(coordinator.isActive, isTrue);
      expect(coordinator.reason, 'Import App Data');
      await completer.future;
      return 42;
    });
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.isActive, isTrue);
    completer.complete();
    expect(await operation, 42);
    expect(coordinator.isActive, isFalse);
    expect(coordinator.reason, isNull);
    expect(states, [true, false]);
  });

  test('independent callers run in FIFO order without overlapping', () async {
    final coordinator = MaintenanceCoordinator.instance;
    final releaseFirst = Completer<void>();
    final events = <String>[];
    final first = coordinator.run('first', () async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
    });
    final second = coordinator.run('second', () async {
      events.add('second-start');
      events.add('second-end');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second-start', 'second-end']);
  });

  test(
    'nested maintenance is reentrant and restores the outer reason',
    () async {
      final coordinator = MaintenanceCoordinator.instance;
      final reasons = <String?>[];

      await coordinator.run('Download Data', () async {
        reasons.add(coordinator.reason);
        await coordinator.run('Import App Data', () async {
          reasons.add(coordinator.reason);
        });
        reasons.add(coordinator.reason);
      });

      expect(reasons, ['Download Data', 'Import App Data', 'Download Data']);
      expect(coordinator.isActive, isFalse);
    },
  );

  test('idle waiter includes operations already queued', () async {
    final coordinator = MaintenanceCoordinator.instance;
    final release = Completer<void>();
    final first = coordinator.run('first', () => release.future);
    final second = coordinator.run('second', () async {});
    var idle = false;
    final waiter = coordinator.waitUntilIdle().then((_) => idle = true);

    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse);
    release.complete();
    await Future.wait([first, second, waiter]);
    expect(idle, isTrue);
  });

  test('maintenance lease is released after a failure', () async {
    final coordinator = MaintenanceCoordinator.instance;

    await expectLater(
      coordinator.run<void>(
        'Import App Data',
        () async => throw StateError('invalid import'),
      ),
      throwsStateError,
    );

    expect(coordinator.isActive, isFalse);
  });
}
