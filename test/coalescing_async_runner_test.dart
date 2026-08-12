import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/coalescing_async_runner.dart';

void main() {
  test('requests during a run are coalesced into one follow-up run', () async {
    final firstRun = Completer<void>();
    final secondRun = Completer<void>();
    final secondRunStarted = Completer<void>();
    final runningStates = <bool>[];
    var runCount = 0;

    final runner = CoalescingAsyncRunner(
      operation: () async {
        runCount++;
        if (runCount == 1) {
          await firstRun.future;
        } else {
          secondRunStarted.complete();
          await secondRun.future;
        }
      },
      onError: (error, stackTrace) => fail('Unexpected error: $error'),
      onRunningChanged: runningStates.add,
    );

    final completed = runner.request();
    runner.request();
    runner.request();

    expect(runCount, 1);
    expect(runner.isRunning, isTrue);
    firstRun.complete();
    await secondRunStarted.future;

    expect(runCount, 2);
    expect(runner.isRunning, isTrue);
    secondRun.complete();
    await completed;

    expect(runCount, 2);
    expect(runner.isRunning, isFalse);
    expect(runningStates, [true, false]);
  });

  test('an error does not discard a queued follow-up run', () async {
    final firstRun = Completer<void>();
    final secondRun = Completer<void>();
    final secondRunStarted = Completer<void>();
    final errors = <Object>[];
    var runCount = 0;

    final runner = CoalescingAsyncRunner(
      operation: () async {
        runCount++;
        if (runCount == 1) {
          await firstRun.future;
          throw StateError('database read failed');
        }
        secondRunStarted.complete();
        await secondRun.future;
      },
      onError: (error, stackTrace) => errors.add(error),
    );

    final completed = runner.request();
    runner.request();
    firstRun.complete();
    await secondRunStarted.future;

    expect(runCount, 2);
    expect(errors, hasLength(1));
    expect(errors.single, isA<StateError>());
    expect(runner.isRunning, isTrue);
    secondRun.complete();
    await completed;

    expect(runner.isRunning, isFalse);
  });
}
