import 'dart:async';

import 'package:dio/dio.dart';

import 'network_log.dart';

const _redirectStatusCodes = {301, 302, 303, 307, 308};

/// A single-subscription upload body that can create a fresh stream for every
/// redirect hop. Plain streams cannot be replayed safely after a 3xx response.
final class ReplayableByteStream extends Stream<List<int>> {
  const ReplayableByteStream(this._open);

  final Stream<List<int>> Function() _open;

  ReplayableByteStream replay() => ReplayableByteStream(_open);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _open().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

Uri? resolveRedirectLocation({
  required Uri currentUri,
  required int statusCode,
  required String? location,
}) {
  if (!_redirectStatusCodes.contains(statusCode) || location == null) {
    return null;
  }
  final parsed = Uri.tryParse(location.trim());
  if (parsed == null) return null;
  final resolved = currentUri.resolveUri(parsed);
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  return resolved;
}

bool redirectChangesOrigin(Uri current, Uri next) =>
    current.scheme.toLowerCase() != next.scheme.toLowerCase() ||
    current.host.toLowerCase() != next.host.toLowerCase() ||
    _effectivePort(current) != _effectivePort(next);

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
}

String redirectMethod(int statusCode, String currentMethod) {
  final method = currentMethod.toUpperCase();
  if (statusCode == 303 && method != 'HEAD') return 'GET';
  if ((statusCode == 301 || statusCode == 302) && method == 'POST') {
    return 'GET';
  }
  return method;
}

Map<String, dynamic> redirectHeaders(
  Map<String, dynamic> source, {
  required bool changesOrigin,
  required bool preservesBody,
}) {
  final result = Map<String, dynamic>.from(source);
  for (final key in result.keys.toList(growable: false)) {
    final normalized = key.toLowerCase();
    if ((changesOrigin &&
            (normalized == 'host' || isSensitiveNetworkName(normalized))) ||
        (!preservesBody &&
            (normalized == 'content-length' ||
                normalized == 'content-type' ||
                normalized == 'transfer-encoding'))) {
      result.remove(key);
    }
  }
  return result;
}

RequestOptions redirectedRequestOptions({
  required RequestOptions previous,
  required Uri nextUri,
  required int statusCode,
  required int redirectsRemaining,
}) {
  final method = redirectMethod(statusCode, previous.method);
  final preservesBody = method == previous.method.toUpperCase();
  final previousData = previous.data;
  final redirectedData = switch (previousData) {
    ReplayableByteStream stream when preservesBody => stream.replay(),
    FormData formData when preservesBody => formData.clone(),
    Stream<dynamic>() when preservesBody => throw StateError(
      'A redirect cannot safely replay a single-subscription request body',
    ),
    _ when preservesBody => previousData,
    _ => null,
  };
  final redirected = previous.copyWith(
    path: nextUri.toString(),
    method: method,
    data: redirectedData,
    headers: redirectHeaders(
      previous.headers,
      changesOrigin: redirectChangesOrigin(previous.uri, nextUri),
      preservesBody: preservesBody,
    ),
    // Keep the flag enabled at zero so a subsequent 3xx is reported as an
    // explicit max-redirects failure rather than silently returned.
    followRedirects: true,
    maxRedirects: redirectsRemaining,
  );
  redirected.data = redirectedData;
  if (!preservesBody) {
    redirected.contentType = null;
    for (final key in redirected.headers.keys.toList(growable: false)) {
      if (const {
        'content-length',
        'content-type',
        'transfer-encoding',
      }.contains(key.toLowerCase())) {
        redirected.headers.remove(key);
      }
    }
  }
  return redirected;
}
