/// Serializes one comic source's private-data writes and permanently retires
/// an old source instance before its script or ownership is replaced.
class ComicSourceDataWriteGate {
  Future<void> _tail = Future<void>.value();
  bool _retired = false;

  bool get isRetired => _retired;

  Future<bool> run(Future<bool> Function() operation) {
    if (_retired) return Future<bool>.value(false);
    final previous = _tail;
    final result = () async {
      try {
        await previous;
      } catch (_) {
        // A failed older write must not poison a later ownership check.
      }
      if (_retired) return false;
      return operation();
    }();
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> retire() async {
    _retired = true;
    await _tail;
  }
}
