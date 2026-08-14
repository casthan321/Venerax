import 'dart:async';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';

import 'cloudflare_detection.dart';
import 'cookie_jar.dart';

class CloudflareException extends DioException {
  CloudflareException._({
    required super.requestOptions,
    required this.challengeUri,
    required this.navigationUri,
    super.response,
    super.error,
    super.stackTrace,
    super.type = DioExceptionType.badResponse,
    super.message = 'Cloudflare verification required',
  });

  factory CloudflareException.fromResponse(Response<dynamic> response) {
    final navigationUri = challengeNavigationUri(response.requestOptions.uri);
    return CloudflareException._(
      requestOptions: response.requestOptions,
      challengeUri: safeChallengeUri(navigationUri),
      navigationUri: navigationUri,
      response: response,
    );
  }

  factory CloudflareException.fromUrl(String url) {
    final navigationUri = challengeNavigationUri(Uri.parse(url));
    final uri = safeChallengeUri(navigationUri);
    return CloudflareException._(
      requestOptions: RequestOptions(path: uri.toString()),
      challengeUri: uri,
      navigationUri: navigationUri,
    );
  }

  final Uri challengeUri;

  /// Full in-process navigation target. Never include this in diagnostics: a
  /// query may contain source-specific state or credentials.
  final Uri navigationUri;

  String get url => challengeUri.toString();

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    final match = RegExp(
      r'^CloudflareException: (https?://\S+)$',
    ).firstMatch(message.trim());
    if (match == null) return null;
    try {
      return CloudflareException.fromUrl(match.group(1)!);
    } catch (_) {
      return null;
    }
  }

  @override
  CloudflareException copyWith({
    RequestOptions? requestOptions,
    Response<dynamic>? response,
    DioExceptionType? type,
    Object? error,
    StackTrace? stackTrace,
    String? message,
  }) {
    final nextRequest = requestOptions ?? this.requestOptions;
    final nextNavigationUri = requestOptions == null
        ? navigationUri
        : challengeNavigationUri(nextRequest.uri);
    return CloudflareException._(
      requestOptions: nextRequest,
      challengeUri: safeChallengeUri(nextNavigationUri),
      navigationUri: nextNavigationUri,
      response: response ?? this.response,
      type: type ?? this.type,
      error: error ?? this.error,
      stackTrace: stackTrace ?? this.stackTrace,
      message: message ?? this.message,
    );
  }
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.headers['cookie'].toString().contains('cf_clearance')) {
      options.headers['user-agent'] = appdata.implicitData['ua'] ?? webUA;
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final response = err.response;
    handler.next(response == null ? err : _check(response) ?? err);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final err = _check(response);
    if (err != null) {
      handler.reject(err);
      return;
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (isCloudflareChallengeResponse(
      statusCode: response.statusCode,
      headers: response.headers.map,
      body: response.data,
    )) {
      return CloudflareException.fromResponse(response);
    }
    return null;
  }
}

final Map<String, _CloudflarePassFlight> _activeCloudflarePasses = {};

class _CloudflarePassFlight {
  _CloudflarePassFlight(Uri uri) : future = _performCloudflarePass(uri);

  final Future<bool> future;
  final List<void Function()> _callbacks = [];
  bool _callbacksRun = false;

  void addCallback(void Function() callback) {
    if (_callbacks.any((existing) => identical(existing, callback))) return;
    _callbacks.add(callback);
    if (_callbacksRun) _runCallback(callback);
  }

  Future<void> complete() async {
    if (!await future || _callbacksRun) return;
    _callbacksRun = true;
    for (final callback in List<void Function()>.of(_callbacks)) {
      _runCallback(callback);
    }
  }

  void _runCallback(void Function() callback) {
    try {
      callback();
    } catch (_, stackTrace) {
      Log.error('Cloudflare', 'Retry callback failed', stackTrace);
    }
  }
}

/// Opens one verification window per origin. Closing the window is a
/// cancellation and deliberately does not retry the failed network request.
Future<void> passCloudflare(
  CloudflareException exception,
  void Function() onFinished,
) async {
  final uri = exception.navigationUri;
  final key = '${uri.scheme}://${uri.host}:${uri.port}';
  final pass = _activeCloudflarePasses.putIfAbsent(
    key,
    () => _CloudflarePassFlight(uri),
  );
  pass.addCallback(onFinished);
  try {
    await pass.complete();
  } catch (_, stackTrace) {
    Log.error('Cloudflare', 'Verification could not be completed', stackTrace);
  } finally {
    if (identical(_activeCloudflarePasses[key], pass)) {
      _activeCloudflarePasses.remove(key);
    }
  }
}

Future<bool> _performCloudflarePass(Uri uri) async {
  final url = uri.toString();

  // flutter_inappwebview is unavailable on Linux, so use the desktop window.
  if (App.isLinux) {
    final result = Completer<bool>();
    var checking = false;
    late final DesktopWebview webview;

    Future<void> check(DesktopWebview controller) async {
      if (checking || result.isCompleted) return;
      checking = true;
      try {
        final currentUri = Uri.tryParse(controller.currentUrl ?? '');
        if (currentUri == null || !haveSameWebOrigin(uri, currentUri)) return;
        final isChallenging = _javascriptBoolean(
          await controller.evaluateJavascript(_challengeProbe),
        );
        if (isChallenging) return;
        final clearance = (await controller.getCookies(
          currentUri.toString(),
        ))['cf_clearance'];
        if (clearance == null || clearance.isEmpty) return;

        _saveClearanceCookie(uri, clearance);
        final ua = controller.userAgent;
        if (ua != null && ua.isNotEmpty) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        result.complete(true);
        controller.close();
      } catch (_, stackTrace) {
        Log.error('Cloudflare', 'Verification check failed', stackTrace);
      } finally {
        checking = false;
      }
    }

    webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (_, controller) => check(controller),
      onClose: () {
        if (!result.isCompleted) result.complete(false);
      },
    );
    await webview.open();
    return result.future;
  }

  final result = Completer<bool>();
  var checking = false;

  Future<void> check(InAppWebViewController controller) async {
    if (checking || result.isCompleted) return;
    checking = true;
    try {
      final currentUri = Uri.tryParse((await controller.getUrl()).toString());
      if (currentUri == null || !haveSameWebOrigin(uri, currentUri)) return;
      final isChallenging = _javascriptBoolean(
        await controller.evaluateJavascript(source: _challengeProbe),
      );
      if (isChallenging) return;

      final cookies = await controller.getCookies(currentUri.toString()) ?? [];
      io.Cookie? clearance;
      for (final cookie in cookies) {
        if (cookie.name == 'cf_clearance' && cookie.value.isNotEmpty) {
          clearance = cookie;
          break;
        }
      }
      if (clearance == null) return;

      _saveClearanceCookie(uri, clearance.value);
      final ua = await controller.getUA();
      if (ua != null && ua.isNotEmpty) {
        appdata.implicitData['ua'] = ua;
        appdata.writeImplicitData();
      }
      result.complete(true);
      App.rootPop();
    } catch (_, stackTrace) {
      Log.error('Cloudflare', 'Verification check failed', stackTrace);
    } finally {
      checking = false;
    }
  }

  try {
    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (_, controller) => check(controller),
        onLoadStop: check,
        onStarted: (controller) async {
          final ua = await controller.getUA();
          if (ua != null && ua.isNotEmpty) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
        },
      ),
    );
  } catch (_, stackTrace) {
    Log.error('Cloudflare', 'Verification window failed', stackTrace);
  }
  if (!result.isCompleted) result.complete(false);
  return result.future;
}

void _saveClearanceCookie(Uri uri, String value) {
  final cookie = io.Cookie('cf_clearance', value)
    ..path = '/'
    ..secure = true
    ..httpOnly = true;
  SingleInstanceCookieJar.instance?.saveFromResponse(uri, [cookie]);
}

bool _javascriptBoolean(Object? value) {
  if (value is bool) return value;
  final text = value?.toString().trim().toLowerCase();
  return text == 'true' || text == '"true"' || text == "'true'";
}

const _challengeProbe = '''
(() => Boolean(
  document.querySelector(
    '#challenge-form, [id^="cf-chl"], '
    'script[src*="/cdn-cgi/challenge-platform/"]'
  ) || typeof window._cf_chl_opt !== 'undefined'
))()
''';
