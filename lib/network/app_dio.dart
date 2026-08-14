import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/network_log.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/network/redirects.dart';
import 'package:venera/utils/async_resource_pool.dart';
import 'package:venera/utils/keyed_async_gate.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final isPrivate =
        networkHeadersContainSecrets(err.requestOptions.headers) ||
        networkUriContainsSecrets(err.requestOptions.uri);
    Log.error(
      "Network",
      '${err.requestOptions.method} '
          '${safeNetworkUri(err.requestOptions.uri)}\n'
          '${err.type.name}: ${err.error.runtimeType}\n'
          'response: ${isPrivate
              ? '<protected>'
              : kDebugMode
              ? summarizeNetworkPayload(err.response?.data)
              : summarizeNetworkPayloadMetadata(err.response?.data)}',
    );
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final isPrivate =
        networkHeadersContainSecrets(response.requestOptions.headers) ||
        networkUriContainsSecrets(response.requestOptions.uri);
    final headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      "Network",
      'Response ${safeNetworkUri(response.realUri)} ${response.statusCode}\n'
          'headers:\n${redactNetworkHeaders(headers)}\n'
          'body: ${isPrivate
              ? '<protected>'
              : kDebugMode
              ? summarizeNetworkPayload(response.data)
              : summarizeNetworkPayloadMetadata(response.data)}',
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final headers = redactNetworkHeaders(options.headers);
    final isPrivate =
        networkHeadersContainSecrets(options.headers) ||
        networkUriContainsSecrets(options.uri);
    Log.info(
      "Network",
      '${options.method} ${safeNetworkUri(options.uri)}\n'
          'headers:\n$headers\n'
          'body: ${options.extra["maskDataInLog"] == true || isPrivate
              ? "<protected>"
              : kDebugMode
              ? summarizeNetworkPayload(options.data)
              : summarizeNetworkPayloadMetadata(options.data)}',
    );
    options.connectTimeout ??= const Duration(seconds: 15);
    options.receiveTimeout ??= const Duration(seconds: 15);
    options.sendTimeout ??= const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = RHttpAdapter();
    if (App.isInitialized) {
      interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
      interceptors.add(DioRedirectInterceptor(this));
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final KeyedAsyncGate<String> _requestGate = KeyedAsyncGate<String>();

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final preventParallel = options?.headers == null
        ? false
        : removeHeaderCaseInsensitive(
                options!.headers!,
                'prevent-parallel',
              )?.toString().toLowerCase() ==
              'true';
    if (!preventParallel) {
      return super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    }
    return _requestGate.run(
      path,
      () => super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      ),
    );
  }
}

/// Follows redirects as real Dio requests so every 3xx response passes through
/// CookieManager and response interceptors. Native rhttp redirects do not
/// expose the effective URL or intermediate Set-Cookie headers.
class DioRedirectInterceptor extends Interceptor {
  DioRedirectInterceptor(
    this.dio, {
    this.followRedirectsWhenNativeDisabled = false,
  });

  final Dio dio;
  final bool followRedirectsWhenNativeDisabled;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final request = response.requestOptions;
    final location = response.headers.value('location');
    final next = resolveRedirectLocation(
      currentUri: request.uri,
      statusCode: response.statusCode ?? 0,
      location: location,
    );
    if (next == null || !_shouldFollow(request)) {
      handler.next(response);
      return;
    }
    if (request.maxRedirects <= 0) {
      handler.reject(
        DioException(
          requestOptions: request,
          response: response,
          type: DioExceptionType.badResponse,
          message: 'Maximum redirects exceeded',
        ),
      );
      return;
    }

    late RequestOptions nextOptions;
    try {
      nextOptions = redirectedRequestOptions(
        previous: request,
        nextUri: next,
        statusCode: response.statusCode!,
        redirectsRemaining: request.maxRedirects - 1,
      );
      _keepNativeRedirectsDisabled(nextOptions);
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: request,
          response: response,
          error: error,
          stackTrace: stackTrace,
          type: DioExceptionType.unknown,
          message: 'Redirect request body is not replayable',
        ),
      );
      return;
    }
    try {
      _closeRedirectBody(response.data);
      final redirected = await dio.fetch<dynamic>(nextOptions);
      handler.resolve(redirected);
    } on DioException catch (error) {
      handler.reject(error);
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: nextOptions,
          error: error,
          stackTrace: stackTrace,
          type: DioExceptionType.unknown,
          message: 'Redirect request failed',
        ),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final request = err.requestOptions;
    final next = response == null
        ? null
        : resolveRedirectLocation(
            currentUri: request.uri,
            statusCode: response.statusCode ?? 0,
            location: response.headers.value('location'),
          );
    if (next == null || !_shouldFollow(request)) {
      handler.next(err);
      return;
    }
    if (request.maxRedirects <= 0) {
      handler.reject(err.copyWith(message: 'Maximum redirects exceeded'));
      return;
    }
    late RequestOptions nextOptions;
    try {
      nextOptions = redirectedRequestOptions(
        previous: request,
        nextUri: next,
        statusCode: response!.statusCode!,
        redirectsRemaining: request.maxRedirects - 1,
      );
      _keepNativeRedirectsDisabled(nextOptions);
    } catch (error, stackTrace) {
      handler.reject(
        err.copyWith(
          error: error,
          stackTrace: stackTrace,
          message: 'Redirect request body is not replayable',
        ),
      );
      return;
    }
    try {
      _closeRedirectBody(response.data);
      final redirected = await dio.fetch<dynamic>(nextOptions);
      handler.resolve(redirected);
    } on DioException catch (redirectError) {
      handler.reject(redirectError);
    } catch (redirectError, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: nextOptions,
          error: redirectError,
          stackTrace: stackTrace,
          type: DioExceptionType.unknown,
          message: 'Redirect request failed',
        ),
      );
    }
  }

  static void _closeRedirectBody(Object? data) {
    // ignore: invalid_use_of_internal_member
    if (data is ResponseBody) data.close();
  }

  bool _shouldFollow(RequestOptions request) =>
      request.followRedirects || followRedirectsWhenNativeDisabled;

  void _keepNativeRedirectsDisabled(RequestOptions options) {
    if (followRedirectsWhenNativeDisabled) {
      // The interceptor owns redirect handling in this mode. Keeping the
      // transport flag disabled ensures every hop remains observable to Dio,
      // including its CookieManager and cross-origin credential filtering.
      options.followRedirects = false;
    }
  }
}

class RHttpAdapter implements HttpClientAdapter {
  RHttpAdapter({this.forceVerifyCertificates = false});

  final bool forceVerifyCertificates;

  static final AsyncResourcePool<
    _RHttpTransportConfiguration,
    rhttp.RhttpClient
  >
  _clients = AsyncResourcePool(
    maximumEntries: 4,
    create: (configuration) =>
        rhttp.RhttpClient.create(settings: configuration.settings),
    dispose: (client) => client.dispose(),
  );

  Future<_RHttpTransportConfiguration> _configuration(
    RequestOptions options,
  ) async {
    final proxy = await getNetworkProxy();
    final configuredConnectTimeout = options.connectTimeout;
    return _RHttpTransportConfiguration(
      proxy: proxy,
      dnsOverrides: _getOverrides(),
      sni: appdata.settings['sni'] != false,
      verifyCertificates:
          forceVerifyCertificates ||
          appdata.settings['ignoreBadCertificate'] != true,
      connectTimeout: _enabledTimeout(
        configuredConnectTimeout ?? const Duration(seconds: 15),
      ),
    );
  }

  static Map<String, List<String>> _getOverrides() {
    if (appdata.settings['enableDnsOverrides'] != true) return {};
    final config = appdata.settings['dnsOverrides'];
    final result = <String, List<String>>{};
    if (config is Map) {
      for (final entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }

  @override
  void close({bool force = false}) {
    // Clients are shared across short-lived AppDio instances. Idle clients are
    // evicted by the bounded pool when a transport configuration changes.
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = 'venera/v${App.version}';
    }

    final lease = await _clients.acquire(await _configuration(options));
    final cancellation = _RHttpCancellation(rhttp.CancelToken());
    final phaseTimeouts = RHttpPhaseTimeouts(
      options: options,
      cancelNativeRequest: cancellation.cancel,
      hasRequestBody: requestStream != null,
    );
    if (cancelFuture != null) {
      unawaited(
        cancelFuture
            .then<void>((_) async {
              await phaseTimeouts.cancelByCaller();
            })
            .catchError((Object error, StackTrace stackTrace) {
              Log.warning(
                'Network cancellation',
                'Failed to cancel the native request (${error.runtimeType})',
              );
            }),
      );
    }

    late final Future<rhttp.HttpResponse> responseFuture;
    rhttp.HttpResponse response;
    try {
      responseFuture = lease.value.request(
        method: rhttp.HttpMethod(options.method),
        url: options.uri.toString(),
        expectBody: rhttp.HttpExpectBody.stream,
        body: requestStream == null
            ? null
            : rhttp.HttpBody.stream(
                phaseTimeouts.trackRequestBody(requestStream),
              ),
        cancelToken: cancellation.token,
        onSendProgress: options.onSendProgress,
        onReceiveProgress: options.onReceiveProgress,
        headers: rhttp.HttpHeaders.rawMap(
          serializeRHttpRequestHeaders(options.headers),
        ),
      );
      response = await Future.any([
        responseFuture,
        phaseTimeouts.timeoutFuture,
      ]);
      phaseTimeouts.responseHeadersReceived();
    } catch (error, stackTrace) {
      phaseTimeouts.requestFailed();
      if (phaseTimeouts.isTriggeredTimeout(error)) {
        unawaited(
          responseFuture.then<void>(
            (_) => lease.release(),
            onError: (Object _, StackTrace __) => lease.release(),
          ),
        );
      } else {
        lease.release();
      }
      Error.throwWithStackTrace(
        _asDioException(error, options, stackTrace),
        stackTrace,
      );
    }

    if (response is! rhttp.HttpStreamResponse) {
      lease.release();
      throw StateError('Invalid response type: ${response.runtimeType}');
    }
    final headers = <String, List<String>>{};
    for (final entry in response.headers) {
      final key = entry.$1.toLowerCase();
      headers.putIfAbsent(key, () => []).add(entry.$2);
    }
    return ResponseBody(
      _wrapResponseStream(response.body, options, lease, cancellation),
      response.statusCode,
      statusMessage: _getStatusMessage(response.statusCode),
      isRedirect: false,
      headers: headers,
      onClose: () {
        _releaseLeaseAfterCancellation(cancellation.cancel(), lease);
      },
    );
  }

  static Stream<Uint8List> _wrapResponseStream(
    Stream<Uint8List> stream,
    RequestOptions options,
    AsyncResourceLease<rhttp.RhttpClient> lease,
    _RHttpCancellation cancellation,
  ) async* {
    final responseStream = applyReceiveIdleTimeout(
      stream: stream,
      options: options,
      cancelNativeRequest: cancellation.cancel,
    );
    try {
      await for (final chunk in responseStream) {
        yield chunk;
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _asDioException(error, options, stackTrace),
        stackTrace,
      );
    } finally {
      final cancellationOperation = cancellation.operation;
      if (cancellationOperation == null) {
        lease.release();
      } else {
        _releaseLeaseAfterCancellation(cancellationOperation, lease);
      }
    }
  }

  static DioException _asDioException(
    Object error,
    RequestOptions options,
    StackTrace stackTrace,
  ) {
    if (error is DioException) return error;
    final type = switch (error) {
      rhttp.RhttpCancelException() => DioExceptionType.cancel,
      rhttp.RhttpTimeoutException() => DioExceptionType.connectionTimeout,
      rhttp.RhttpInvalidCertificateException() =>
        DioExceptionType.badCertificate,
      rhttp.RhttpConnectionException() => DioExceptionType.connectionError,
      rhttp.RhttpRedirectException() => DioExceptionType.badResponse,
      _ => DioExceptionType.unknown,
    };
    final message = switch (error) {
      rhttp.RhttpCancelException() => 'Request canceled',
      rhttp.RhttpTimeoutException() => 'Connection timed out',
      rhttp.RhttpInvalidCertificateException() =>
        'Certificate validation failed',
      rhttp.RhttpConnectionException() => 'Connection failed',
      rhttp.RhttpRedirectException() => 'Redirect failed',
      _ => 'Network request failed (${error.runtimeType})',
    };
    return DioException(
      requestOptions: options,
      type: type,
      error: error,
      stackTrace: stackTrace,
      message: message,
    );
  }

  @visibleForTesting
  static DioException mapRHttpExceptionForTesting(
    Object error,
    RequestOptions options,
  ) => _asDioException(error, options, StackTrace.empty);

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => 'OK',
      201 => 'Created',
      202 => 'Accepted',
      204 => 'No Content',
      206 => 'Partial Content',
      301 => 'Moved Permanently',
      302 => 'Found',
      400 => 'Invalid Status Code 400: The Request is invalid.',
      401 => 'Invalid Status Code 401: The Request is unauthorized.',
      403 =>
        'Invalid Status Code 403: No permission to access the resource. Check your account or network.',
      404 => 'Invalid Status Code 404: Not found.',
      429 =>
        'Invalid Status Code 429: Too many requests. Please try again later.',
      _ => 'Invalid Status Code $statusCode',
    };
  }
}

@visibleForTesting
Map<String, String> serializeRHttpRequestHeaders(Map<String, dynamic> headers) {
  final result = <String, String>{};
  for (final entry in headers.entries) {
    final value = entry.value;
    if (value == null) continue;
    if (value is Iterable) {
      final values = value
          .where((element) => element != null)
          .map((element) => element.toString().trim())
          .toList(growable: false);
      if (values.isEmpty) continue;
      result[entry.key] = values.join(', ');
    } else {
      result[entry.key] = value.toString().trim();
    }
  }
  return result;
}

final class _RHttpCancellation {
  _RHttpCancellation(this.token);

  final rhttp.CancelToken token;
  Future<void>? _operation;

  Future<void>? get operation => _operation;

  Future<void> cancel() => _operation ??= token.cancel();
}

void _releaseLeaseAfterCancellation(
  Future<void> cancellation,
  AsyncResourceLease<rhttp.RhttpClient> lease,
) {
  unawaited(
    cancellation.then<void>(
      (_) => lease.release(),
      onError: (Object error, StackTrace stackTrace) {
        Log.warning(
          'Network cancellation',
          'Failed to finish native cancellation (${error.runtimeType})',
        );
        lease.release();
      },
    ),
  );
}

Duration? _enabledTimeout(Duration? timeout) {
  if (timeout == null || timeout <= Duration.zero) return null;
  return timeout;
}

@visibleForTesting
final class RHttpPhaseTimeouts {
  RHttpPhaseTimeouts({
    required this.options,
    required Future<void> Function() cancelNativeRequest,
    required bool hasRequestBody,
  }) : _cancelNativeRequest = cancelNativeRequest,
       _hasRequestBody = hasRequestBody {
    if (!hasRequestBody) {
      _requestBodyFinished();
    }
  }

  final RequestOptions options;
  final Future<void> Function() _cancelNativeRequest;
  final bool _hasRequestBody;
  final Completer<Never> _timeoutCompleter = Completer();

  Timer? _sendTimer;
  Timer? _responseHeaderTimer;
  bool _bodyFinished = false;
  bool _headersReceived = false;
  bool _cancelledByCaller = false;
  DioException? _triggeredTimeout;

  Future<Never> get timeoutFuture => _timeoutCompleter.future;

  bool isTriggeredTimeout(Object error) => identical(_triggeredTimeout, error);

  Stream<Uint8List> trackRequestBody(Stream<Uint8List> stream) async* {
    _startSendTimer();
    try {
      yield* stream;
    } finally {
      _requestBodyFinished();
    }
  }

  void _startSendTimer() {
    if (!_hasRequestBody ||
        _bodyFinished ||
        _sendTimer != null ||
        _timeoutCompleter.isCompleted) {
      return;
    }
    final sendTimeout = _enabledTimeout(options.sendTimeout);
    if (sendTimeout == null) return;
    _sendTimer = Timer(
      sendTimeout,
      () => _triggerTimeout(
        DioException.sendTimeout(timeout: sendTimeout, requestOptions: options),
      ),
    );
  }

  void _requestBodyFinished() {
    if (_bodyFinished) return;
    _bodyFinished = true;
    _sendTimer?.cancel();
    _sendTimer = null;
    if (_cancelledByCaller ||
        _headersReceived ||
        _timeoutCompleter.isCompleted) {
      return;
    }

    final receiveTimeout = _enabledTimeout(options.receiveTimeout);
    if (receiveTimeout != null) {
      _responseHeaderTimer = Timer(
        receiveTimeout,
        () => _triggerTimeout(
          DioException.receiveTimeout(
            timeout: receiveTimeout,
            requestOptions: options,
          ),
        ),
      );
    }
  }

  void responseHeadersReceived() {
    _headersReceived = true;
    _cancelTimers();
  }

  void requestFailed() {
    _headersReceived = true;
    _cancelTimers();
  }

  Future<void> cancelByCaller() async {
    _cancelledByCaller = true;
    _cancelTimers();
    await _cancelNativeRequest();
  }

  void _triggerTimeout(DioException error) {
    if (_headersReceived ||
        _cancelledByCaller ||
        _timeoutCompleter.isCompleted) {
      return;
    }
    _cancelTimers();
    _triggeredTimeout = error;
    _timeoutCompleter.completeError(error, StackTrace.current);
    _cancelNativeRequestWithoutWaiting();
  }

  void _cancelTimers() {
    _sendTimer?.cancel();
    _sendTimer = null;
    _responseHeaderTimer?.cancel();
    _responseHeaderTimer = null;
  }

  void _cancelNativeRequestWithoutWaiting() {
    unawaited(
      _cancelNativeRequest().catchError((Object error, StackTrace stackTrace) {
        Log.warning(
          'Network cancellation',
          'Failed to cancel a timed-out request (${error.runtimeType})',
        );
      }),
    );
  }
}

@visibleForTesting
Stream<Uint8List> applyReceiveIdleTimeout({
  required Stream<Uint8List> stream,
  required RequestOptions options,
  required Future<void> Function() cancelNativeRequest,
}) {
  final receiveTimeout = _enabledTimeout(options.receiveTimeout);
  if (receiveTimeout == null) return stream;
  return stream.timeout(
    receiveTimeout,
    onTimeout: (sink) {
      unawaited(
        cancelNativeRequest().catchError((Object error, StackTrace stackTrace) {
          Log.warning(
            'Network cancellation',
            'Failed to cancel an idle response (${error.runtimeType})',
          );
        }),
      );
      sink
        ..addError(
          DioException.receiveTimeout(
            timeout: receiveTimeout,
            requestOptions: options,
          ),
        )
        ..close();
    },
  );
}

final class _RHttpTransportConfiguration {
  _RHttpTransportConfiguration({
    required this.proxy,
    required Map<String, List<String>> dnsOverrides,
    required this.sni,
    required this.verifyCertificates,
    required this.connectTimeout,
  }) : dnsOverrides = Map.unmodifiable(
         Map.fromEntries(
           dnsOverrides.entries.toList()
             ..sort((left, right) => left.key.compareTo(right.key)),
         ),
       ),
       _fingerprint = jsonEncode([
         proxy?.routes
             .map((route) => [route.condition.name, route.endpoint.url])
             .toList(growable: false),
         dnsOverrides.entries
             .map((entry) => [entry.key, ...entry.value])
             .toList()
           ..sort((left, right) => left.first.compareTo(right.first)),
         sni,
         verifyCertificates,
         connectTimeout?.inMilliseconds,
       ]);

  final NetworkProxyConfiguration? proxy;
  final Map<String, List<String>> dnsOverrides;
  final bool sni;
  final bool verifyCertificates;
  final Duration? connectTimeout;
  final String _fingerprint;

  rhttp.ClientSettings get settings => rhttp.ClientSettings(
    proxySettings: buildRHttpProxySettings(proxy),
    redirectSettings: const rhttp.RedirectSettings.none(),
    timeoutSettings: rhttp.TimeoutSettings(
      connectTimeout: connectTimeout,
      keepAliveTimeout: const Duration(seconds: 60),
      keepAlivePing: const Duration(seconds: 30),
    ),
    throwOnStatusCode: false,
    dnsSettings: rhttp.DnsSettings.static(overrides: dnsOverrides),
    tlsSettings: rhttp.TlsSettings(
      sni: sni,
      verifyCertificates: verifyCertificates,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is _RHttpTransportConfiguration &&
      other._fingerprint == _fingerprint;

  @override
  int get hashCode => _fingerprint.hashCode;
}

@visibleForTesting
rhttp.ProxySettings buildRHttpProxySettings(
  NetworkProxyConfiguration? configuration,
) {
  if (configuration == null || configuration.routes.isEmpty) {
    return const rhttp.ProxySettings.noProxy();
  }
  final routes = buildRHttpProxyRoutes(configuration);
  if (configuration.routes.length == 1 &&
      configuration.routes.single.condition == NetworkProxyCondition.all) {
    return rhttp.ProxySettings.proxy(configuration.routes.single.endpoint.url);
  }
  return rhttp.ProxySettings.list(routes);
}

@visibleForTesting
List<rhttp.CustomProxy> buildRHttpProxyRoutes(
  NetworkProxyConfiguration configuration,
) => configuration.routes
    .map<rhttp.CustomProxy>(
      (route) => rhttp.StaticProxy(
        url: route.endpoint.url,
        condition: switch (route.condition) {
          NetworkProxyCondition.http => rhttp.ProxyCondition.onlyHttp,
          NetworkProxyCondition.https => rhttp.ProxyCondition.onlyHttps,
          NetworkProxyCondition.all => rhttp.ProxyCondition.all,
        },
      ),
    )
    .toList(growable: false);
