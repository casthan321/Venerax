import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/file_download_protocol.dart';
import 'package:venera/network/file_downloader.dart';

void main() {
  late Directory temporaryDirectory;
  final servers = <HttpServer>[];

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'venera_file_downloader_test_',
    );
  });

  tearDown(() async {
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<Uri> serve(FutureOr<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    return Uri.parse('http://${server.address.host}:${server.port}/archive');
  }

  test(
    'downloads concurrent ranges without corrupting random writes',
    () async {
      final data = List<int>.generate(96 * 1024, (index) => index % 251);
      final requestedRanges = <String>[];
      final uri = await serve((request) async {
        expect(request.headers.value('accept-encoding'), 'identity');
        if (request.method == 'HEAD') {
          request.response.contentLength = data.length;
          request.response.headers.set('etag', '"range-v1"');
          await request.response.close();
          return;
        }

        final rangeHeader = request.headers.value('range')!;
        requestedRanges.add(rangeHeader);
        final range = _parseRequestRange(rangeHeader);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes ${range.$1}-${range.$2}/${data.length}',
        );
        request.response.headers.set('etag', '"range-v1"');
        request.response.contentLength = range.$2 - range.$1 + 1;
        await Future<void>.delayed(
          Duration(milliseconds: (range.$1 ~/ 4096) % 4),
        );
        request.response.add(data.sublist(range.$1, range.$2 + 1));
        await request.response.close();
      });
      final destination = File('${temporaryDirectory.path}/archive.zip');

      final statuses = await FileDownloader(
        uri.toString(),
        destination.path,
        maxConcurrent: 4,
        chunkSize: 4096,
        dio: Dio(),
      ).start().toList();

      expect(statuses.last.isFinished, isTrue);
      expect(statuses.last.downloadedBytes, data.length);
      expect(await destination.readAsBytes(), data);
      expect(requestedRanges.length, greaterThan(2));
      expect(await File('${destination.path}.part').exists(), isFalse);
      expect(await File('${destination.path}.download').exists(), isFalse);
    },
  );

  test('does not trust a legacy preallocated file as completed', () async {
    final data = List<int>.generate(12 * 1024, (index) => (index * 17) % 255);
    final uri = await serve((request) async {
      if (request.method == 'HEAD') {
        request.response.contentLength = data.length;
        await request.response.close();
        return;
      }
      final range = _parseRequestRange(request.headers.value('range')!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes ${range.$1}-${range.$2}/${data.length}',
      );
      request.response.contentLength = range.$2 - range.$1 + 1;
      request.response.add(data.sublist(range.$1, range.$2 + 1));
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/legacy-partial.zip');
    await destination.writeAsBytes(List<int>.filled(data.length, 0));
    await File(
      '${destination.path}.download',
    ).writeAsString('0-${data.length}-128');

    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      chunkSize: 4096,
      dio: Dio(),
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(await destination.readAsBytes(), data);
  });

  test('HEAD without a length is not mistaken for a completed file', () async {
    final data = utf8.encode('chunked response with no HEAD content length');
    var fullGetCount = 0;
    final uri = await serve((request) async {
      expect(request.headers.value('accept-encoding'), 'identity');
      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }
      if (request.headers.value('range') != null) {
        request.response.add(data);
        await request.response.close();
        return;
      }
      fullGetCount++;
      request.response.add(data);
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/unknown-size.zip');

    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      dio: Dio(),
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(statuses.last.totalBytes, data.length);
    expect(statuses.last.downloadedBytes, data.length);
    expect(await destination.readAsBytes(), data);
    expect(fullGetCount, 1);
  });

  test(
    'falls back to one stream when HEAD is 405 and Range is ignored',
    () async {
      final data = List<int>.generate(24 * 1024, (index) => (index * 7) % 256);
      var rangeGetCount = 0;
      var fullGetCount = 0;
      final uri = await serve((request) async {
        expect(request.headers.value('accept-encoding'), 'identity');
        if (request.method == 'HEAD') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }
        request.response.contentLength = data.length;
        if (request.headers.value('range') != null) {
          rangeGetCount++;
        } else {
          fullGetCount++;
        }
        request.response.add(data);
        await request.response.close();
      });
      final destination = File('${temporaryDirectory.path}/fallback.zip');

      final statuses = await FileDownloader(
        uri.toString(),
        destination.path,
        dio: Dio(),
      ).start().toList();

      expect(statuses.last.isFinished, isTrue);
      expect(await destination.readAsBytes(), data);
      expect(rangeGetCount, 1);
      expect(fullGetCount, 1);
    },
  );

  test('continues with GET when a CDN blocks HEAD with 403', () async {
    final data = utf8.encode('GET remains available when HEAD is blocked');
    var rangeProbeCount = 0;
    var fullGetCount = 0;
    final uri = await serve((request) async {
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (request.headers.value('range') != null) {
        rangeProbeCount++;
      } else {
        fullGetCount++;
      }
      request.response.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/head-blocked.zip');

    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      dio: Dio(),
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(rangeProbeCount, 1);
    expect(fullGetCount, 1);
    expect(await destination.readAsBytes(), data);
  });

  test('follows CDN redirects when native redirects are disabled', () async {
    final data = utf8.encode('redirected archive payload');
    var redirectedRequests = 0;
    final uri = await serve((request) async {
      if (request.uri.path == '/archive') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('location', '/cdn/archive.zip');
        await request.response.close();
        return;
      }
      redirectedRequests++;
      if (request.method == 'HEAD') {
        request.response.contentLength = data.length;
        await request.response.close();
        return;
      }
      request.response.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/redirected.zip');
    final dio = Dio(BaseOptions(followRedirects: false));

    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      dio: dio,
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(redirectedRequests, greaterThanOrEqualTo(3));
    expect(await destination.readAsBytes(), data);
  });

  test('does not trust a same-length final file without a validator', () async {
    final data = utf8.encode('new archive bytes');
    final uri = await serve((request) async {
      if (request.method == 'HEAD') {
        request.response.contentLength = data.length;
        request.response.headers.set('etag', '"new-version"');
        await request.response.close();
        return;
      }
      final range = _parseRequestRange(request.headers.value('range')!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes ${range.$1}-${range.$2}/${data.length}',
      );
      request.response.headers.set('etag', '"new-version"');
      request.response.contentLength = range.$2 - range.$1 + 1;
      request.response.add(data.sublist(range.$1, range.$2 + 1));
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/same-length.zip');
    await destination.writeAsBytes(List<int>.filled(data.length, 0));

    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      chunkSize: 4,
      dio: Dio(),
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(await destination.readAsBytes(), data);
  });

  test('falls back safely when later block requests return HTTP 200', () async {
    final data = List<int>.generate(20 * 1024, (index) => (index * 11) % 256);
    var fullGetCount = 0;
    final uri = await serve((request) async {
      if (request.method == 'HEAD') {
        request.response.contentLength = data.length;
        request.response.headers.set('etag', '"changes-range-behavior"');
        await request.response.close();
        return;
      }
      final rangeHeader = request.headers.value('range');
      if (rangeHeader == 'bytes=0-0') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes 0-0/${data.length}',
        );
        request.response.headers.set('etag', '"changes-range-behavior"');
        request.response.contentLength = 1;
        request.response.add(data.sublist(0, 1));
      } else {
        if (rangeHeader == null) fullGetCount++;
        request.response.contentLength = data.length;
        request.response.add(data);
      }
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/late-fallback.zip');

    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      maxConcurrent: 3,
      chunkSize: 4096,
      dio: Dio(),
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(fullGetCount, 1);
    expect(await destination.readAsBytes(), data);
  });

  test('rejects a mismatched Content-Range before corrupting output', () async {
    final data = List<int>.generate(8192, (index) => index % 199);
    final uri = await serve((request) async {
      if (request.method == 'HEAD') {
        request.response.contentLength = data.length;
        await request.response.close();
        return;
      }
      final range = _parseRequestRange(request.headers.value('range')!);
      final isProbe = range == (0, 0);
      final responseStart = isProbe ? 0 : range.$1 + 1;
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes $responseStart-${range.$2}/${data.length}',
      );
      final responseData = data.sublist(responseStart, range.$2 + 1);
      request.response.contentLength = responseData.length;
      request.response.add(responseData);
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/invalid-range.zip');
    final downloader = FileDownloader(
      uri.toString(),
      destination.path,
      chunkSize: 1024,
      dio: Dio(),
    );

    await expectLater(
      downloader.start().drain<void>(),
      throwsA(
        isA<FileDownloadException>().having(
          (error) => error.message,
          'message',
          contains('Invalid Content-Range'),
        ),
      ),
    );

    expect(await destination.exists(), isFalse);
  });

  test('cancel waits for writes and a new downloader resumes safely', () async {
    final data = List<int>.generate(256 * 1024, (index) => (index * 13) % 253);
    final firstActualRange = Completer<void>();
    final resumedOffsets = <int>[];
    var isSecondRun = false;
    final uri = await serve((request) async {
      if (request.method == 'HEAD') {
        request.response.contentLength = data.length;
        request.response.headers.set('etag', '"resume-v1"');
        await request.response.close();
        return;
      }
      final range = _parseRequestRange(request.headers.value('range')!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes ${range.$1}-${range.$2}/${data.length}',
      );
      request.response.headers.set('etag', '"resume-v1"');
      request.response.contentLength = range.$2 - range.$1 + 1;
      if (range != (0, 0)) {
        if (isSecondRun) {
          resumedOffsets.add(range.$1);
        } else if (range.$1 > 0 && !firstActualRange.isCompleted) {
          // maxConcurrent is one for the first run, so receiving the second
          // block proves that the first block reached the random-access writer.
          firstActualRange.complete();
        }
      }
      for (var offset = range.$1; offset <= range.$2; offset += 2048) {
        final end = (offset + 2048).clamp(0, range.$2 + 1);
        request.response.add(data.sublist(offset, end));
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      await request.response.close();
    });
    final destination = File('${temporaryDirectory.path}/resume.zip');
    final first = FileDownloader(
      uri.toString(),
      destination.path,
      maxConcurrent: 1,
      chunkSize: 64 * 1024,
      dio: Dio(),
    );
    final firstDone = first.start().drain<void>();

    await firstActualRange.future;
    await first.stop();
    await firstDone;

    final checkpointFile = File('${destination.path}.download');
    expect(await checkpointFile.exists(), isTrue);
    final checkpoint = DownloadCheckpoint.fromJson(
      jsonDecode(await checkpointFile.readAsString()),
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.downloadedBytes, greaterThan(0));
    expect(checkpoint.downloadedBytes, lessThan(data.length));
    expect(await destination.exists(), isFalse);

    isSecondRun = true;
    final statuses = await FileDownloader(
      uri.toString(),
      destination.path,
      maxConcurrent: 2,
      chunkSize: 64 * 1024,
      dio: Dio(),
    ).start().toList();

    expect(statuses.last.isFinished, isTrue);
    expect(resumedOffsets, contains(checkpoint.downloadedBytes));
    expect(await destination.readAsBytes(), data);
  });
}

(int, int) _parseRequestRange(String value) {
  final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(value);
  if (match == null) throw FormatException('Invalid Range header: $value');
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}
