import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync_guard.dart';

void main() {
  group('guardDataSyncOperation', () {
    test('returns a successful result unchanged', () async {
      const expected = Res<bool>(true);

      final result = await guardDataSyncOperation(() async => expected);

      expect(identical(result, expected), isTrue);
    });

    test(
      'preserves an ordinary error result for manual sync callers',
      () async {
        const expected = Res<bool>.error('WebDAV rejected the request');
        var exceptionHandlerCalled = false;

        final result = await guardDataSyncOperation(
          () async => expected,
          onException: (_, __, ___) => exceptionHandlerCalled = true,
        );

        expect(identical(result, expected), isTrue);
        expect(result.errorMessage, 'WebDAV rejected the request');
        expect(exceptionHandlerCalled, isFalse);
      },
    );

    test('converts a synchronous exception to an error result', () async {
      Object? reportedError;
      StackTrace? reportedStackTrace;
      String? reportedMessage;

      final result = await guardDataSyncOperation<bool>(
        () => throw StateError('invalid WebDAV configuration'),
        onException: (error, stackTrace, message) {
          reportedError = error;
          reportedStackTrace = stackTrace;
          reportedMessage = message;
        },
      );

      expect(result.error, isTrue);
      expect(result.errorMessage, contains('invalid WebDAV configuration'));
      expect(reportedError, isA<StateError>());
      expect(reportedStackTrace, isNotNull);
      expect(reportedMessage, result.errorMessage);
    });

    test('converts an asynchronous exception to an error result', () async {
      var exceptionHandlerCalled = false;

      final result = await guardDataSyncOperation<bool>(
        () async {
          await Future<void>.delayed(Duration.zero);
          throw Exception('Invalid Status Code 502');
        },
        onException: (_, __, message) {
          exceptionHandlerCalled = true;
          expect(message, contains('Invalid Status Code 502'));
        },
      );

      expect(result.error, isTrue);
      expect(result.errorMessage, contains('Invalid Status Code 502'));
      expect(exceptionHandlerCalled, isTrue);
    });

    test('does not rethrow if error reporting itself fails', () async {
      final result = await guardDataSyncOperation<bool>(
        () async => throw Exception('network unavailable'),
        onException: (_, __, ___) => throw Exception('logger unavailable'),
      );

      expect(result.error, isTrue);
      expect(result.errorMessage, contains('network unavailable'));
    });
  });
}
