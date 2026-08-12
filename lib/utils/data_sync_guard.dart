import 'package:venera/foundation/res.dart';

typedef DataSyncExceptionHandler =
    void Function(Object error, StackTrace stackTrace, String message);

/// Converts an exception from a data-sync entry point to the same [Res] error
/// contract used for ordinary WebDAV failures.
///
/// The exception handler is best-effort: logging or UI notification failures
/// must not turn a handled background-sync failure into an unhandled Future.
Future<Res<T>> guardDataSyncOperation<T>(
  Future<Res<T>> Function() operation, {
  DataSyncExceptionHandler? onException,
}) async {
  try {
    return await operation();
  } catch (error, stackTrace) {
    final message = _safeErrorMessage(error);
    try {
      onException?.call(error, stackTrace, message);
    } catch (_) {
      // Error reporting must never make an automatic sync crash the app.
    }
    return Res.error(message);
  }
}

String _safeErrorMessage(Object error) {
  try {
    return error.toString();
  } catch (_) {
    return error.runtimeType.toString();
  }
}
