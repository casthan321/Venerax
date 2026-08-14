/// Identifies the latest asynchronous request in a stateful workflow.
///
/// A caller starts a new generation for every logical refresh and applies an
/// asynchronous result only while its token is still current. This does not
/// cancel the underlying operation; it prevents a stale completion from
/// replacing newer UI state.
final class LatestAsyncRequest {
  int _generation = 0;

  int start() => ++_generation;

  bool isCurrent(int token) => token == _generation;

  void invalidate() {
    _generation++;
  }
}
