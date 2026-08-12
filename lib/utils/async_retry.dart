typedef RetryDelay = Duration Function(int failedAttempt);
typedef RetryWait = Future<void> Function(Duration delay);

Duration _defaultRetryDelay(int failedAttempt) =>
    Duration(milliseconds: 100 * failedAttempt);

Future<void> _defaultRetryWait(Duration delay) => Future<void>.delayed(delay);

/// Runs an asynchronous operation until it succeeds or [maxAttempts] is
/// reached.
///
/// [failedAttempt] and the attempt passed to [operation] are one-based. The
/// original error and stack trace from the final attempt are preserved.
Future<T> retryAsync<T>(
  Future<T> Function(int attempt) operation, {
  int maxAttempts = 3,
  RetryDelay delayForAttempt = _defaultRetryDelay,
  RetryWait wait = _defaultRetryWait,
}) async {
  if (maxAttempts < 1) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
  }

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await operation(attempt);
    } catch (error, stackTrace) {
      if (attempt == maxAttempts) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final delay = delayForAttempt(attempt);
      if (delay.isNegative) {
        throw ArgumentError.value(
          delay,
          'delayForAttempt',
          'must not be negative',
        );
      }
      if (delay != Duration.zero) {
        await wait(delay);
      }
    }
  }

  throw StateError('retryAsync completed without a result');
}
