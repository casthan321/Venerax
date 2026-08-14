import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data_sync_guard.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

void main() {
  test('WebDAV retention keeps current upload and prunes safely', () {
    final names = [
      for (var day = 1; day <= 11; day++) '$day-$day.venera',
      '12-1-device-a.venera',
      '12-2-device-b.venera',
      '.12-2.venera.uploading-1',
    ];

    final remove = webDavBackupNamesToPrune(
      names,
      currentName: '12-2-device-b.venera',
    );

    expect(remove, contains('1-1.venera'));
    expect(remove, isNot(contains('12-2-device-b.venera')));
    expect(remove, isNot(contains('.12-2.venera.uploading-1')));
  });

  test('WebDAV latest backup compares numeric version values', () {
    final latest = latestWebDavBackupName([
      '20000-9.venera',
      '20000-10-device.venera',
      '.20000-99.venera.uploading-1',
      null,
      'garbage.venera',
    ]);

    expect(latest?.name, '20000-10-device.venera');
    expect(latest?.version, 10);
  });

  test('WebDAV latest backup prioritizes version over a later day', () {
    final latest = latestWebDavBackupName([
      '20001-9-clock-ahead.venera',
      '20000-10-clock-behind.venera',
    ]);

    expect(latest?.name, '20000-10-clock-behind.venera');
    expect(latest?.version, 10);
  });

  test('WebDAV latest selection exposes same-version forks', () {
    final latest = latestWebDavBackupVersionEntries([
      '20000-10-device-a.venera',
      '20001-10-device-b.venera',
      '20002-9-older.venera',
      '20000-10-device-a.venera',
    ]);

    expect(latest.map((backup) => backup.name), [
      '20000-10-device-a.venera',
      '20001-10-device-b.venera',
    ]);
  });

  test('WebDAV clients receive finite transfer timeouts', () {
    final client = newClient('https://example.com');

    configureWebDavClientTimeouts(client);

    expect(client.c.options.connectTimeout, webDavConnectTimeout);
    expect(client.c.options.sendTimeout, webDavSendTimeout);
    expect(client.c.options.receiveTimeout, webDavReceiveTimeout);
  });

  test('WebDAV clients use observable safe redirects', () {
    final client = newClient('https://example.com');

    configureWebDavClientRedirects(client);
    configureWebDavClientRedirects(client);

    expect(
      client.c.interceptors.whereType<DioRedirectInterceptor>(),
      hasLength(1),
    );
  });

  test(
    'WebDAV temporary download is removed after an import failure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-webdav-download-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File('${directory.path}${Platform.pathSeparator}backup.tmp');

      await expectLater(
        withTemporaryWebDavDownload<void>(file, (temporaryFile) async {
          await temporaryFile.writeAsString('partial backup');
          throw const FormatException('invalid backup');
        }),
        throwsA(isA<FormatException>()),
      );

      expect(await file.exists(), isFalse);
    },
  );

  test('WebDAV retention never deletes a version newer than current', () {
    final remove = webDavBackupNamesToPrune(
      [
        for (var version = 1; version <= 10; version++) '20000-$version.venera',
        '20000-50-other-device.venera',
      ],
      currentName: '20000-10-local.venera',
      maximumBackups: 3,
    );

    expect(remove, isNot(contains('20000-50-other-device.venera')));
  });

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
