import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/scroll_tap_guard.dart';

void main() {
  test('scroll start blocks taps immediately', () {
    final scheduler = _FakeScheduler();
    final guard = ScrollTapGuard(schedule: scheduler.schedule);

    guard.onScrollStart();

    expect(guard.shouldIgnoreTap, isTrue);
    expect(scheduler.callbacks, isEmpty);
  });

  test('scroll end keeps taps blocked until the release delay', () {
    final scheduler = _FakeScheduler();
    final guard = ScrollTapGuard(schedule: scheduler.schedule);

    guard.onScrollStart();
    guard.onScrollEnd();

    expect(guard.shouldIgnoreTap, isTrue);
    expect(scheduler.callbacks, hasLength(1));
    expect(scheduler.callbacks.single.delay, const Duration(milliseconds: 300));

    scheduler.callbacks.single.run();
    expect(guard.shouldIgnoreTap, isFalse);
  });

  test('a new scroll cancels a pending release', () {
    final scheduler = _FakeScheduler();
    final guard = ScrollTapGuard(schedule: scheduler.schedule);

    guard.onScrollStart();
    guard.onScrollEnd();
    final staleRelease = scheduler.callbacks.single;

    guard.onScrollStart();
    expect(staleRelease.isCanceled, isTrue);
    staleRelease.run();
    expect(guard.shouldIgnoreTap, isTrue);

    guard.onScrollEnd();
    scheduler.callbacks.last.run();
    expect(guard.shouldIgnoreTap, isFalse);
  });

  test('dispose cancels a pending release', () {
    final scheduler = _FakeScheduler();
    final guard = ScrollTapGuard(schedule: scheduler.schedule);

    guard.onScrollStart();
    guard.onScrollEnd();
    final release = scheduler.callbacks.single;

    guard.dispose();
    expect(release.isCanceled, isTrue);
    expect(guard.shouldIgnoreTap, isFalse);

    release.run();
    guard.onScrollStart();
    expect(guard.shouldIgnoreTap, isFalse);
  });
}

class _FakeScheduler {
  final callbacks = <_FakeScheduledCallback>[];

  CancelScheduledCallback schedule(Duration delay, void Function() callback) {
    final scheduled = _FakeScheduledCallback(delay, callback);
    callbacks.add(scheduled);
    return scheduled.cancel;
  }
}

class _FakeScheduledCallback {
  _FakeScheduledCallback(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool isCanceled = false;

  void cancel() {
    isCanceled = true;
  }

  void run() {
    if (!isCanceled) callback();
  }
}
