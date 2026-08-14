import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/atomic_file.dart';
import 'package:venera/utils/coalescing_async_writer.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  group('CoalescingAsyncWriter', () {
    test('collapses synchronous requests into the latest value', () async {
      final written = <int>[];
      final writer = CoalescingAsyncWriter<int>((value) async {
        written.add(value);
      });

      final first = writer.schedule(1);
      final second = writer.schedule(2);
      final third = writer.schedule(3);
      await Future.wait([first, second, third]);

      expect(written, [3]);
      expect(writer.isRunning, isFalse);
    });

    test('coalesces updates received while a write is active', () async {
      final firstWrite = Completer<void>();
      final started = Completer<void>();
      final written = <int>[];
      final writer = CoalescingAsyncWriter<int>((value) async {
        written.add(value);
        if (value == 1) {
          started.complete();
          await firstWrite.future;
        }
      });

      final first = writer.schedule(1);
      await started.future;
      final second = writer.schedule(2);
      final third = writer.schedule(3);
      firstWrite.complete();
      await Future.wait([first, second, third]);

      expect(written, [1, 3]);
    });

    test('merges metadata from collapsed requests', () async {
      final written = <({int value, bool sync})>[];
      final writer = CoalescingAsyncWriter<({int value, bool sync})>(
        (value) async => written.add(value),
        mergePending: (pending, next) =>
            (value: next.value, sync: pending.sync || next.sync),
      );

      await Future.wait([
        writer.schedule((value: 1, sync: true)),
        writer.schedule((value: 2, sync: false)),
      ]);

      expect(written, [(value: 2, sync: true)]);
    });

    test('continues with later requests after a failed batch', () async {
      var attempts = 0;
      final writer = CoalescingAsyncWriter<int>((_) async {
        attempts++;
        if (attempts == 1) throw StateError('disk unavailable');
      });

      await expectLater(writer.schedule(1), throwsStateError);
      await expectLater(writer.schedule(2), completes);

      expect(attempts, 2);
      expect(writer.isRunning, isFalse);
    });
  });

  test(
    'atomic string write replaces content and cleans temporary file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-appdata-write-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File(
        '${directory.path}${Platform.pathSeparator}data.json',
      );
      final temporary = File('${destination.path}.tmp');
      await destination.writeAsString('old');
      await temporary.writeAsString('stale');

      await writeStringAtomically(destination, 'new');

      expect(await destination.readAsString(), 'new');
      expect(await temporary.exists(), isFalse);
    },
  );

  test(
    'cloud settings snapshot removes credentials without mutating local data',
    () {
      final local = <String, dynamic>{
        'settings': <String, dynamic>{
          'proxy': 'user:password@proxy.example:8080',
          'webdav': ['https://dav.example', 'user', 'password'],
          'deviceId': 'device-secret',
          'theme_mode': 'dark',
        },
        'searchHistory': <String>['comic'],
      };

      final sanitized = sanitizedAppdataForSync(
        local,
        disabledFields: const ['proxy', 'webdav', 'deviceId'],
      );
      final settings = sanitized['settings'] as Map<String, dynamic>;

      expect(settings, isNot(contains('proxy')));
      expect(settings, isNot(contains('webdav')));
      expect(settings, isNot(contains('deviceId')));
      expect(settings['theme_mode'], 'dark');
      expect(
        (local['settings'] as Map<String, dynamic>)['proxy'],
        contains('password'),
      );
    },
  );
}
