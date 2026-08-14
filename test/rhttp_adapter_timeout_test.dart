import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/network/app_dio.dart';

void main() {
  RequestOptions requestOptions({
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) => RequestOptions(
    path: 'https://example.com/resource',
    sendTimeout: sendTimeout,
    receiveTimeout: receiveTimeout,
  );

  test(
    'a stalled upload maps to sendTimeout and cancels native work',
    () async {
      var cancellations = 0;
      final body = StreamController<Uint8List>();
      final controller = RHttpPhaseTimeouts(
        options: requestOptions(
          sendTimeout: const Duration(milliseconds: 30),
          receiveTimeout: const Duration(seconds: 1),
        ),
        cancelNativeRequest: () async {
          cancellations++;
        },
        hasRequestBody: true,
      );
      final subscription = controller
          .trackRequestBody(body.stream)
          .listen((_) {}, onError: (_) {});

      await expectLater(
        controller.timeoutFuture,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.sendTimeout,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cancellations, 1);
      controller.requestFailed();
      await subscription.cancel();
      await body.close();
    },
  );

  test('waiting for response headers maps to receiveTimeout', () async {
    var cancellations = 0;
    final controller = RHttpPhaseTimeouts(
      options: requestOptions(receiveTimeout: const Duration(milliseconds: 30)),
      cancelNativeRequest: () async {
        cancellations++;
      },
      hasRequestBody: false,
    );

    await expectLater(
      controller.timeoutFuture,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(cancellations, 1);
    controller.requestFailed();
  });

  test('an idle response stream maps to receiveTimeout', () async {
    var cancellations = 0;
    final source = StreamController<Uint8List>();
    final options = requestOptions(
      receiveTimeout: const Duration(milliseconds: 30),
    );
    final result = applyReceiveIdleTimeout(
      stream: source.stream,
      options: options,
      cancelNativeRequest: () async {
        cancellations++;
      },
    ).toList();
    source.add(Uint8List.fromList([1]));

    await expectLater(
      result,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(cancellations, 1);
    await source.close();
  });

  test('Duration.zero disables phase and idle response timeouts', () async {
    var cancellations = 0;
    final options = requestOptions(
      sendTimeout: Duration.zero,
      receiveTimeout: Duration.zero,
    );
    final phase = RHttpPhaseTimeouts(
      options: options,
      cancelNativeRequest: () async {
        cancellations++;
      },
      hasRequestBody: false,
    );
    final source = StreamController<Uint8List>();
    final response = applyReceiveIdleTimeout(
      stream: source.stream,
      options: options,
      cancelNativeRequest: () async {
        cancellations++;
      },
    ).toList();

    await Future<void>.delayed(const Duration(milliseconds: 50));
    source.add(Uint8List.fromList([1, 2]));
    await source.close();

    final chunks = await response;
    expect(chunks, hasLength(1));
    expect(chunks.single, <int>[1, 2]);
    expect(
      await Future.any<Object?>([
        phase.timeoutFuture.then<Object?>((_) => 'timeout'),
        Future<Object?>.delayed(
          const Duration(milliseconds: 20),
          () => 'pending',
        ),
      ]),
      'pending',
    );
    expect(cancellations, 0);
    phase.requestFailed();
  });

  test('caller cancellation disarms pending timeouts', () async {
    var cancellations = 0;
    final controller = RHttpPhaseTimeouts(
      options: requestOptions(receiveTimeout: const Duration(milliseconds: 30)),
      cancelNativeRequest: () async {
        cancellations++;
      },
      hasRequestBody: false,
    );

    await controller.cancelByCaller();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(cancellations, 1);
    expect(
      await Future.any<Object?>([
        controller.timeoutFuture.then<Object?>((_) => 'timeout'),
        Future<Object?>.delayed(
          const Duration(milliseconds: 20),
          () => 'pending',
        ),
      ]),
      'pending',
    );
    controller.requestFailed();
  });

  test('invalid certificates map to badCertificate', () {
    final options = requestOptions();
    final error = rhttp.RhttpInvalidCertificateException(
      request: rhttp.HttpRequest(url: options.uri.toString()),
      message: 'untrusted certificate',
    );

    final mapped = RHttpAdapter.mapRHttpExceptionForTesting(error, options);

    expect(mapped.type, DioExceptionType.badCertificate);
  });

  test('rhttp headers skip nulls and serialize iterable values', () {
    expect(
      serializeRHttpRequestHeaders({
        'Accept': ' application/json ',
        'X-Skip': null,
        'X-Values': <Object?>[' one ', null, 2],
        'X-Empty': <Object?>[],
      }),
      {'Accept': 'application/json', 'X-Values': 'one, 2'},
    );
  });
}
