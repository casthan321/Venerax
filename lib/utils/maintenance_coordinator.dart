import 'dart:async';

import 'package:flutter/foundation.dart';

/// Tracks short, non-interruptible maintenance operations that replace live
/// application data. UI entry points may still be cancelled before acquiring
/// a lease, but closing the process while a lease is active must be blocked.
class MaintenanceCoordinator with ChangeNotifier {
  MaintenanceCoordinator._();

  static final MaintenanceCoordinator instance = MaintenanceCoordinator._();

  static final Object _zoneKey = Object();

  Future<void> _tail = Future<void>.value();
  int _pendingCount = 0;
  String? _reason;

  bool get isActive => _pendingCount > 0;

  String? get reason => _reason;

  Future<void> waitUntilIdle() {
    return _tail;
  }

  /// Runs [operation] under the application-wide maintenance lock.
  ///
  /// Independent callers are served in FIFO order. Calls made from inside the
  /// current operation are reentrant, which allows a WebDAV download to invoke
  /// the normal import pipeline without deadlocking itself.
  Future<T> run<T>(String reason, Future<T> Function() operation) {
    final inheritedOwner = Zone.current[_zoneKey];
    if (inheritedOwner is _MaintenanceOwner &&
        identical(inheritedOwner.coordinator, this)) {
      return _runReentrant(inheritedOwner, reason, operation);
    }
    return _runExclusive(reason, operation);
  }

  Future<T> _runExclusive<T>(
    String reason,
    Future<T> Function() operation,
  ) async {
    _pendingCount++;
    final predecessor = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await predecessor;

    final owner = _MaintenanceOwner(this, reason);
    _reason = reason;
    notifyListeners();
    try {
      return await runZoned(
        operation,
        zoneValues: <Object, Object>{_zoneKey: owner},
      );
    } finally {
      _pendingCount--;
      _reason = null;
      notifyListeners();
      release.complete();
    }
  }

  Future<T> _runReentrant<T>(
    _MaintenanceOwner owner,
    String reason,
    Future<T> Function() operation,
  ) async {
    owner.reasons.add(reason);
    _reason = reason;
    notifyListeners();
    try {
      return await operation();
    } finally {
      owner.reasons.removeLast();
      _reason = owner.reasons.last;
      notifyListeners();
    }
  }
}

final class _MaintenanceOwner {
  _MaintenanceOwner(this.coordinator, String reason) : reasons = [reason];

  final MaintenanceCoordinator coordinator;
  final List<String> reasons;
}
