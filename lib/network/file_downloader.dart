import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/file_download_protocol.dart';
import 'package:venera/utils/atomic_file.dart';

const _downloadConnectTimeout = Duration(seconds: 20);
const _downloadSendTimeout = Duration(seconds: 30);
const _downloadReceiveIdleTimeout = Duration(seconds: 60);

class FileDownloader {
  FileDownloader(
    this.url,
    this.savePath, {
    this.maxConcurrent = 4,
    int? chunkSize,
    Dio? dio,
  }) : assert(maxConcurrent > 0),
       assert(chunkSize == null || chunkSize > 0),
       _configuredChunkSize = chunkSize,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: _downloadConnectTimeout,
               sendTimeout: _downloadSendTimeout,
               receiveTimeout: _downloadReceiveIdleTimeout,
             ),
           ),
       _ownsDio = dio == null;

  final String url;
  final String savePath;
  final int maxConcurrent;
  final int? _configuredChunkSize;
  final Dio _dio;
  final bool _ownsDio;

  final Set<CancelToken> _activeRequests = {};
  final Stopwatch _checkpointClock = Stopwatch()..start();

  late final File _partFile = File('$savePath.part');
  late final File _checkpointFile = File('$savePath.download');
  late StreamController<DownloadingStatus> _resultStream;

  Future<void>? _completion;
  Future<void> _checkpointWrites = Future.value();
  RandomAccessFile? _file;
  _SerialRandomAccessWriter? _writer;
  _RemoteFileInfo? _rangeRemote;
  List<DownloadBlockState> _blocks = [];
  Timer? _reportTimer;

  bool _started = false;
  bool _canceled = false;
  bool _rangeInProgress = false;
  int _currentBytes = 0;
  int _lastBytes = 0;
  int _fileSize = 0;
  int _checkpointChunkSize = 0;
  int _dirtyCheckpointBytes = 0;

  Stream<DownloadingStatus> start() {
    if (_started) {
      return Stream.error(
        StateError('A FileDownloader can only be started once'),
      );
    }
    _started = true;
    _resultStream = StreamController<DownloadingStatus>(
      onCancel: () => unawaited(stop()),
    );
    _completion = _download();
    return _resultStream.stream;
  }

  Future<void> stop() async {
    if (_canceled) {
      await _completion;
      return;
    }
    _canceled = true;
    _cancelActiveRequests('Download canceled');
    await _completion;
  }

  Future<void> _download() async {
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await _configureClient();
      final remote = await _probeRemote();
      if (_canceled) return;

      _startReporter();
      if (remote.supportsRanges && remote.totalBytes != null) {
        await _prepareRangeDownload(remote);
        _emitStatus();
        try {
          await _downloadRanges(remote);
        } on _RangeIgnoredException {
          if (_canceled) return;
          await _discardRangeDownload();
          await _downloadSingleStream(remote);
        }
      } else {
        await _downloadSingleStream(remote);
      }

      if (_canceled) return;
      await _closeOutputFile();
      await _commitPartFile();
      await _deleteIfExists(_checkpointFile);
      _rangeInProgress = false;
      _rangeRemote = null;
      _emitStatus(isFinished: true);
    } catch (error, stackTrace) {
      if (!_canceled) {
        failure = error;
        failureStackTrace = stackTrace;
      }
    } finally {
      _reportTimer?.cancel();
      if (_rangeInProgress) {
        try {
          await _persistCheckpoint(force: true);
        } catch (error, stackTrace) {
          failure ??= error;
          failureStackTrace ??= stackTrace;
        }
      }
      try {
        await _closeOutputFile();
      } catch (error, stackTrace) {
        failure ??= error;
        failureStackTrace ??= stackTrace;
      }
      if (_ownsDio) _dio.close(force: true);
      if (failure != null && !_canceled && !_resultStream.isClosed) {
        _resultStream.addError(failure, failureStackTrace!);
      }
      if (!_resultStream.isClosed) await _resultStream.close();
    }
  }

  Future<void> _configureClient() async {
    if (_ownsDio) {
      _dio.httpClientAdapter = RHttpAdapter();
    }
    configureFileDownloadInterceptors(_dio);
  }

  Future<_RemoteFileInfo> _probeRemote() async {
    int? headLength;
    String? headEtag;
    String? headLastModified;

    final headToken = _newRequestToken();
    try {
      final response = await _dio.request<ResponseBody>(
        url,
        cancelToken: headToken,
        options: Options(
          method: 'HEAD',
          responseType: ResponseType.stream,
          headers: const {'Accept-Encoding': 'identity'},
          validateStatus: _acceptProbeStatus,
        ),
      );
      final status = response.statusCode ?? 0;
      await _cancelResponseBody(response.data);
      if (status >= 200 && status < 300) {
        headLength = _contentLength(response.headers);
        headEtag = response.headers.value('etag');
        headLastModified = response.headers.value('last-modified');
      }
    } on DioException catch (error) {
      if (_canceled && error.type == DioExceptionType.cancel) rethrow;
      // Many CDNs and signed download endpoints reject or terminate HEAD even
      // though GET is permitted. Treat HEAD as an optional hint and let the
      // bytes=0-0 probe produce the authoritative error. Certificate failures
      // remain terminal and must never be bypassed.
      if (error.type == DioExceptionType.badCertificate) rethrow;
    } finally {
      _activeRequests.remove(headToken);
    }

    if (_canceled) throw const _DownloadCanceledException();

    final rangeToken = _newRequestToken();
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: rangeToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: const {
            'Range': 'bytes=0-0',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
          },
          validateStatus: _acceptProbeStatus,
        ),
      );
      final status = response.statusCode ?? 0;
      final etag = response.headers.value('etag') ?? headEtag;
      final lastModified =
          response.headers.value('last-modified') ?? headLastModified;

      if (status == HttpStatus.partialContent) {
        final range = parseDownloadContentRange(
          response.headers.value('content-range'),
        );
        final responseLength = _contentLength(response.headers);
        final isValid =
            range != null &&
            range.start == 0 &&
            range.endInclusive == 0 &&
            (responseLength == null || responseLength == 1) &&
            _hasIdentityEncoding(response.headers);
        await _cancelResponseBody(response.data);
        if (!isValid) {
          throw FileDownloadException(
            'Server returned an invalid Content-Range for bytes=0-0',
          );
        }
        return _RemoteFileInfo(
          totalBytes: range.totalBytes,
          supportsRanges: true,
          etag: etag,
          lastModified: lastModified,
        );
      }

      if (status == HttpStatus.ok) {
        final responseLength = _hasIdentityEncoding(response.headers)
            ? _contentLength(response.headers)
            : null;
        await _cancelResponseBody(response.data);
        return _RemoteFileInfo(
          totalBytes: responseLength ?? headLength,
          supportsRanges: false,
          etag: etag,
          lastModified: lastModified,
        );
      }

      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        final total = parseUnsatisfiedDownloadLength(
          response.headers.value('content-range'),
        );
        await _cancelResponseBody(response.data);
        if (total == 0) {
          return _RemoteFileInfo(
            totalBytes: 0,
            supportsRanges: true,
            etag: etag,
            lastModified: lastModified,
          );
        }
      } else {
        await _cancelResponseBody(response.data);
      }
      throw FileDownloadException('Range probe failed with HTTP $status');
    } finally {
      _activeRequests.remove(rangeToken);
    }
  }

  Future<void> _prepareRangeDownload(_RemoteFileInfo remote) async {
    final totalBytes = remote.totalBytes!;
    _fileSize = totalBytes;
    DownloadCheckpoint? checkpoint;
    if (await _partFile.exists() && await _checkpointFile.exists()) {
      try {
        checkpoint = DownloadCheckpoint.fromJson(
          jsonDecode(await _checkpointFile.readAsString()),
        );
        if (checkpoint == null ||
            !checkpoint.isValidFor(
              currentUrl: url,
              currentTotalBytes: totalBytes,
              partFileLength: await _partFile.length(),
              currentEtag: remote.etag,
              currentLastModified: remote.lastModified,
            )) {
          checkpoint = null;
        }
      } catch (_) {
        checkpoint = null;
      }
    }

    if (checkpoint == null) {
      await _deleteIfExists(_partFile);
      await _deleteIfExists(_checkpointFile);
      _checkpointChunkSize = _resolveChunkSize(totalBytes);
      _blocks = createDownloadBlocks(totalBytes, _checkpointChunkSize);
      _currentBytes = 0;
    } else {
      _checkpointChunkSize = checkpoint.chunkSize;
      _blocks = checkpoint.blocks;
      _currentBytes = checkpoint.downloadedBytes;
    }
    _lastBytes = _currentBytes;

    await _partFile.create(recursive: true);
    _file = await _partFile.open(mode: FileMode.append);
    await _file!.truncate(totalBytes);
    _writer = _SerialRandomAccessWriter(_file!);
    _rangeRemote = remote;
    _rangeInProgress = true;
    await _persistCheckpoint(force: true, remote: remote);
  }

  int _resolveChunkSize(int totalBytes) {
    final configured = _configuredChunkSize;
    if (configured != null) return configured;
    if (totalBytes > 1024 * 1024 * 1024) return 64 * 1024 * 1024;
    if (totalBytes > 512 * 1024 * 1024) return 32 * 1024 * 1024;
    return 16 * 1024 * 1024;
  }

  Future<void> _downloadRanges(_RemoteFileInfo remote) async {
    final pending = _blocks.where((block) => !block.isComplete).toList();
    if (pending.isEmpty) return;

    var cursor = 0;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> worker() async {
      while (!_canceled && firstError == null) {
        if (cursor >= pending.length) return;
        final block = pending[cursor++];
        try {
          await _fetchRange(block, remote);
        } catch (error, stackTrace) {
          if (firstError == null) {
            firstError = error;
            firstStackTrace = stackTrace;
            _cancelActiveRequests('Another range request failed');
          }
          return;
        }
      }
    }

    final workerCount = maxConcurrent < pending.length
        ? maxConcurrent
        : pending.length;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    if (_canceled) throw const _DownloadCanceledException();
  }

  Future<void> _fetchRange(
    DownloadBlockState block,
    _RemoteFileInfo remote,
  ) async {
    final requestStart = block.start + block.downloadedBytes;
    final requestEnd = block.endExclusive - 1;
    final expectedBytes = requestEnd - requestStart + 1;
    final headers = <String, Object>{
      'Range': 'bytes=$requestStart-$requestEnd',
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
    };
    final validator = DownloadCheckpoint(
      url: url,
      totalBytes: remote.totalBytes!,
      chunkSize: _checkpointChunkSize,
      etag: remote.etag,
      lastModified: remote.lastModified,
      blocks: _blocks,
    ).ifRangeValidator;
    if (validator != null) headers['If-Range'] = validator;

    final token = _newRequestToken();
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          validateStatus: _acceptProbeStatus,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == HttpStatus.ok) {
        await _cancelResponseBody(response.data);
        throw const _RangeIgnoredException();
      }
      if (status != HttpStatus.partialContent) {
        await _cancelResponseBody(response.data);
        throw FileDownloadException(
          'Range $requestStart-$requestEnd failed with HTTP $status',
        );
      }

      final range = parseDownloadContentRange(
        response.headers.value('content-range'),
      );
      final responseLength = _contentLength(response.headers);
      if (range == null ||
          range.start != requestStart ||
          range.endInclusive != requestEnd ||
          range.totalBytes != remote.totalBytes ||
          (responseLength != null && responseLength != expectedBytes) ||
          !_hasIdentityEncoding(response.headers)) {
        await _cancelResponseBody(response.data);
        throw FileDownloadException(
          'Invalid Content-Range for requested bytes '
          '$requestStart-$requestEnd/${remote.totalBytes}',
        );
      }

      final body = response.data;
      if (body == null) {
        throw FileDownloadException(
          'Range $requestStart-$requestEnd returned no body',
        );
      }
      var receivedBytes = 0;
      await for (final data in body.stream) {
        if (_canceled) throw const _DownloadCanceledException();
        if (receivedBytes + data.length > expectedBytes) {
          throw FileDownloadException(
            'Range $requestStart-$requestEnd returned too many bytes',
          );
        }
        await _writer!.write(requestStart + receivedBytes, data);
        receivedBytes += data.length;
        block.downloadedBytes += data.length;
        _currentBytes += data.length;
        _dirtyCheckpointBytes += data.length;
        await _persistCheckpoint(remote: remote);
      }
      if (receivedBytes != expectedBytes) {
        throw FileDownloadException(
          'Range $requestStart-$requestEnd ended after $receivedBytes of '
          '$expectedBytes bytes',
        );
      }
    } finally {
      _activeRequests.remove(token);
    }
  }

  Future<void> _discardRangeDownload() async {
    await _persistCheckpoint(force: true);
    await _closeOutputFile();
    _rangeInProgress = false;
    _rangeRemote = null;
    _blocks = [];
    _currentBytes = 0;
    _lastBytes = 0;
    _dirtyCheckpointBytes = 0;
    await _deleteIfExists(_partFile);
    await _deleteIfExists(_checkpointFile);
  }

  Future<void> _downloadSingleStream(_RemoteFileInfo remote) async {
    _rangeInProgress = false;
    _rangeRemote = null;
    _blocks = [];
    _currentBytes = 0;
    _lastBytes = 0;
    await _deleteIfExists(_checkpointFile);
    await _deleteIfExists(_partFile);
    await _partFile.create(recursive: true);
    _file = await _partFile.open(mode: FileMode.write);
    _writer = null;

    final token = _newRequestToken();
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: const {'Accept': '*/*', 'Accept-Encoding': 'identity'},
          validateStatus: _acceptProbeStatus,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 ||
          status >= 300 ||
          status == HttpStatus.partialContent) {
        await _cancelResponseBody(response.data);
        throw FileDownloadException('Full download failed with HTTP $status');
      }

      final responseLength = _hasIdentityEncoding(response.headers)
          ? _contentLength(response.headers)
          : null;
      final expectedBytes = responseLength ?? remote.totalBytes;
      _fileSize = expectedBytes ?? 0;
      _emitStatus();

      final body = response.data;
      if (body == null) {
        throw FileDownloadException('Full download returned no body');
      }
      await for (final data in body.stream) {
        if (_canceled) throw const _DownloadCanceledException();
        await _file!.writeFrom(data);
        _currentBytes += data.length;
        if (expectedBytes != null && _currentBytes > expectedBytes) {
          throw FileDownloadException(
            'Full download exceeded the expected $expectedBytes bytes',
          );
        }
      }
      if (expectedBytes != null && _currentBytes != expectedBytes) {
        throw FileDownloadException(
          'Full download ended after $_currentBytes of $expectedBytes bytes',
        );
      }
      _fileSize = expectedBytes ?? _currentBytes;
    } finally {
      _activeRequests.remove(token);
    }
  }

  Future<void> _persistCheckpoint({
    bool force = false,
    _RemoteFileInfo? remote,
  }) async {
    if (!_rangeInProgress) return;
    if (!force &&
        _dirtyCheckpointBytes < 1024 * 1024 &&
        _checkpointClock.elapsed < const Duration(milliseconds: 750)) {
      return;
    }
    final info =
        remote ??
        _rangeRemote ??
        _RemoteFileInfo(totalBytes: _fileSize, supportsRanges: true);
    final snapshot = jsonEncode(
      DownloadCheckpoint(
        url: url,
        totalBytes: _fileSize,
        chunkSize: _checkpointChunkSize,
        etag: info.etag,
        lastModified: info.lastModified,
        blocks: _blocks,
      ).toJson(),
    );
    _dirtyCheckpointBytes = 0;
    _checkpointClock.reset();

    await _writer?.flush();
    final previousWrite = _checkpointWrites;
    final nextWrite = previousWrite.then(
      (_) => writeStringAtomically(_checkpointFile, snapshot),
    );
    _checkpointWrites = nextWrite;
    await nextWrite;
  }

  void _startReporter() {
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_canceled || _resultStream.isClosed) return;
      final speed = _currentBytes - _lastBytes;
      _lastBytes = _currentBytes;
      _resultStream.add(DownloadingStatus(_currentBytes, _fileSize, speed));
    });
  }

  void _emitStatus({bool isFinished = false}) {
    if (_canceled || _resultStream.isClosed) return;
    _resultStream.add(
      DownloadingStatus(_currentBytes, _fileSize, 0, isFinished),
    );
  }

  CancelToken _newRequestToken() {
    final token = CancelToken();
    if (_canceled) {
      token.cancel('Download canceled');
    } else {
      _activeRequests.add(token);
    }
    return token;
  }

  void _cancelActiveRequests(Object reason) {
    for (final token in _activeRequests.toList()) {
      if (!token.isCancelled) token.cancel(reason);
    }
  }

  Future<void> _closeOutputFile() async {
    final file = _file;
    if (file == null) return;
    _file = null;
    _writer = null;
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await file.flush();
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    }
    try {
      await file.close();
    } catch (error, stackTrace) {
      failure ??= error;
      failureStackTrace ??= stackTrace;
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStackTrace!);
    }
  }

  Future<void> _commitPartFile() async {
    if (!await _partFile.exists()) {
      throw FileDownloadException('Temporary download file is missing');
    }
    await replaceFileWithStaging(_partFile, File(savePath));
  }

  static bool _acceptProbeStatus(int? status) =>
      status != null && status >= 200 && status < 600;

  static int? _contentLength(Headers headers) {
    final value = headers.value('content-length');
    if (value == null) return null;
    final parsed = int.tryParse(value.trim());
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  static bool _hasIdentityEncoding(Headers headers) {
    final encoding = headers.value('content-encoding');
    return encoding == null ||
        encoding.trim().isEmpty ||
        encoding.trim().toLowerCase() == 'identity';
  }

  static Future<void> _cancelResponseBody(ResponseBody? body) async {
    if (body == null) return;
    final subscription = body.stream.listen((_) {});
    await subscription.cancel();
  }

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}

@visibleForTesting
void configureFileDownloadInterceptors(Dio dio) {
  final cookieJar = SingleInstanceCookieJar.instance;
  if (cookieJar != null &&
      !dio.interceptors.any((interceptor) => interceptor is CookieManagerSql)) {
    dio.interceptors.add(CookieManagerSql(cookieJar));
  }
  if (!dio.interceptors.any(
    (interceptor) => interceptor is DioRedirectInterceptor,
  )) {
    // RHttp deliberately disables native redirects because it cannot expose
    // intermediate Set-Cookie headers or the final URL. Follow every hop as a
    // Dio request instead, just like AppDio, so signed/CDN archive links keep
    // working without sacrificing cookie isolation.
    dio.interceptors.add(
      DioRedirectInterceptor(dio, followRedirectsWhenNativeDisabled: true),
    );
  }
}

class DownloadingStatus {
  const DownloadingStatus(
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond, [
    this.isFinished = false,
  ]);

  final int downloadedBytes;
  final int totalBytes;
  final bool isFinished;
  final int bytesPerSecond;

  @override
  String toString() =>
      'Downloaded: $downloadedBytes/$totalBytes '
      '${isFinished ? "Finished" : ""}';
}

class FileDownloadException implements Exception {
  const FileDownloadException(this.message);

  final String message;

  @override
  String toString() => 'FileDownloadException: $message';
}

class _SerialRandomAccessWriter {
  _SerialRandomAccessWriter(this._file);

  final RandomAccessFile _file;
  Future<void> _tail = Future.value();

  Future<void> write(int offset, Uint8List bytes) {
    final operation = _tail.then((_) async {
      await _file.setPosition(offset);
      await _file.writeFrom(bytes);
    });
    _tail = operation;
    return operation;
  }

  Future<void> flush() {
    final operation = _tail.then((_) => _file.flush());
    _tail = operation;
    return operation;
  }
}

class _RemoteFileInfo {
  const _RemoteFileInfo({
    required this.totalBytes,
    required this.supportsRanges,
    this.etag,
    this.lastModified,
  });

  final int? totalBytes;
  final bool supportsRanges;
  final String? etag;
  final String? lastModified;
}

class _RangeIgnoredException implements Exception {
  const _RangeIgnoredException();
}

class _DownloadCanceledException implements Exception {
  const _DownloadCanceledException();
}
