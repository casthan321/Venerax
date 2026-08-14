import 'package:flutter/foundation.dart';

/// Prevents overlapping mutations of the global comic-source runtime.
///
/// Parsing and reloading a source mutates the shared JavaScript engine, so even
/// operations for different source keys must not run at the same time.
class ComicSourceMutationGate extends ChangeNotifier {
  bool _isActive = false;

  bool get isActive => _isActive;

  /// Runs [operation] when the gate is idle.
  ///
  /// Returns false without queueing when another mutation is already active.
  Future<bool> run(Future<void> Function() operation) async {
    if (_isActive) return false;
    _isActive = true;
    notifyListeners();
    try {
      await operation();
      return true;
    } finally {
      _isActive = false;
      notifyListeners();
    }
  }
}
