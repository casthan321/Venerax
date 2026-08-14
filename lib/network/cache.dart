import 'dart:typed_data';
import 'package:venera/network/app_dio.dart';

import 'network_log.dart';

class NetworkCache {
  final Uri uri;

  final Map<String, dynamic> requestHeaders;

  final Map<String, List<String>> responseHeaders;

  final Object? data;

  final DateTime time;

  final int size;

  final ResponseType responseType;

  const NetworkCache({
    required this.uri,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.data,
    required this.time,
    required this.size,
    this.responseType = ResponseType.json,
  });
}

class NetworkCacheManager implements Interceptor {
  NetworkCacheManager._();

  static final NetworkCacheManager instance = NetworkCacheManager._();

  factory NetworkCacheManager() => instance;

  final Map<(Uri, ResponseType), NetworkCache> _cache = {};

  int size = 0;

  NetworkCache? getCache(
    Uri uri, {
    ResponseType responseType = ResponseType.json,
  }) {
    final cache = _cache[(uri, responseType)];
    return cache == null ? null : _copyCache(cache);
  }

  static const _maxCacheSize = 10 * 1024 * 1024;

  void setCache(NetworkCache cache) {
    final snapshot = _copyCache(cache);
    final key = (snapshot.uri, snapshot.responseType);
    if (_cache.containsKey(key)) {
      size -= _cache[key]!.size;
      _cache.remove(key);
    }
    if (snapshot.size > _maxCacheSize) return;
    while (_cache.isNotEmpty && size + snapshot.size > _maxCacheSize) {
      size -= _cache.values.first.size;
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = snapshot;
    size += snapshot.size;
  }

  void removeCache(Uri uri, {ResponseType? responseType}) {
    final keys = responseType == null
        ? _cache.keys.where((key) => key.$1 == uri).toList(growable: false)
        : <(Uri, ResponseType)>[(uri, responseType)];
    for (final key in keys) {
      final cache = _cache.remove(key);
      if (cache != null) size -= cache.size;
    }
  }

  void clear() {
    _cache.clear();
    size = 0;
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.method != "GET") {
      return handler.next(err);
    }
    return handler.next(err);
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.method != "GET") {
      return handler.next(options);
    }
    final cacheTime = removeHeaderCaseInsensitive(
      options.headers,
      'cache-time',
    )?.toString();
    final requestCacheControl = headerValueCaseInsensitive(
      options.headers,
      'cache-control',
    )?.toString().toLowerCase();
    if (isPrivateNetworkRequest(options.headers) ||
        networkUriContainsSecrets(options.uri) ||
        requestCacheControl?.contains(
              RegExp(r'\b(?:no-cache|no-store|max-age\s*=\s*0)\b'),
            ) ==
            true) {
      return handler.next(options);
    }
    final cacheKey = (options.uri, options.responseType);
    var cache = _cache[cacheKey];
    if (cache == null ||
        !compareHeaders(options.headers, cache.requestHeaders)) {
      return handler.next(options);
    } else {
      if (cacheTime == 'no') {
        removeCache(options.uri, responseType: options.responseType);
        return handler.next(options);
      }
    }
    var time = DateTime.now();
    var diff = time.difference(cache.time);
    if (cacheTime == 'long' && diff < const Duration(hours: 6)) {
      return handler.resolve(
        Response(
          requestOptions: options,
          data: _copyCacheData(cache.data),
          headers: Headers.fromMap(_copyResponseHeaders(cache.responseHeaders))
            ..set('venera-cache', 'true'),
          statusCode: 200,
        ),
      );
    } else if (diff < const Duration(seconds: 5)) {
      return handler.resolve(
        Response(
          requestOptions: options,
          data: _copyCacheData(cache.data),
          headers: Headers.fromMap(_copyResponseHeaders(cache.responseHeaders))
            ..set('venera-cache', 'true'),
          statusCode: 200,
        ),
      );
    } else if (diff < const Duration(hours: 2)) {
      var o = options.copyWith(method: "HEAD");
      var dio = AppDio();
      try {
        var response = await dio.fetch(o);
        if (response.statusCode == 200 &&
            compareHeaders(cache.responseHeaders, response.headers.map)) {
          return handler.resolve(
            Response(
              requestOptions: options,
              data: _copyCacheData(cache.data),
              headers: Headers.fromMap(
                _copyResponseHeaders(cache.responseHeaders),
              )..set('venera-cache', 'true'),
              statusCode: 200,
            ),
          );
        }
      } on DioException catch (error) {
        if (options.cancelToken?.isCancelled == true) {
          return handler.reject(error);
        }
        // Revalidation is an optimization. A failed HEAD must not prevent the
        // original GET from reaching a server that may not support HEAD.
      }
    }
    removeCache(options.uri, responseType: options.responseType);
    handler.next(options);
  }

  static bool compareHeaders(Map<String, dynamic> a, Map<String, dynamic> b) {
    a = _normalizedHeaders(a);
    b = _normalizedHeaders(b);
    const shouldIgnore = [
      'cache-time',
      'prevent-parallel',
      'date',
      'x-varnish',
      'cf-ray',
      'connection',
      'vary',
      'content-encoding',
      'report-to',
      'server-timing',
      'token',
      'set-cookie',
      'cf-cache-status',
      'cf-request-id',
      'cf-ray',
      'authorization',
      'user-agent',
    ];
    for (var key in shouldIgnore) {
      a.remove(key);
      b.remove(key);
    }
    if (a.length != b.length) {
      return false;
    }
    for (var key in a.keys) {
      if (a[key] is List && b[key] is List) {
        if (a[key].length != b[key].length) {
          return false;
        }
        for (var i = 0; i < a[key].length; i++) {
          if (a[key][i] != b[key][i]) {
            return false;
          }
        }
      } else if (a[key] != b[key]) {
        return false;
      }
    }
    return true;
  }

  static Map<String, dynamic> _normalizedHeaders(Map<String, dynamic> source) {
    final normalized = <String, dynamic>{};
    for (final entry in source.entries) {
      normalized[entry.key.toLowerCase()] = entry.value is List
          ? List<Object?>.from(entry.value as List)
          : entry.value;
    }
    return normalized;
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (response.requestOptions.method != "GET") {
      return handler.next(response);
    }
    if (response.statusCode != 200) {
      return handler.next(response);
    }
    final cacheControl = response.headers.value('cache-control')?.toLowerCase();
    final vary = response.headers.value('vary');
    if (isPrivateNetworkRequest(response.requestOptions.headers) ||
        networkUriContainsSecrets(response.requestOptions.uri) ||
        response.headers['set-cookie']?.isNotEmpty == true ||
        cacheControl?.contains(
              RegExp(r'\b(?:no-store|private|no-cache|max-age\s*=\s*0)\b'),
            ) ==
            true ||
        vary?.split(',').any((value) {
              final name = value.trim().toLowerCase();
              return name == '*' || name == 'user-agent';
            }) ==
            true) {
      return handler.next(response);
    }
    var size = _calculateSize(response.data);
    if (size != null && size < 1024 * 1024 && size > 0) {
      var cache = NetworkCache(
        uri: response.requestOptions.uri,
        requestHeaders: Map<String, dynamic>.from(
          response.requestOptions.headers,
        ),
        responseHeaders: Map.from(response.headers.map),
        data: response.data,
        time: DateTime.now(),
        size: size,
        responseType: response.requestOptions.responseType,
      );
      setCache(cache);
    }
    handler.next(response);
  }

  static int? _calculateSize(Object? data) {
    if (data == null) {
      return 0;
    }
    if (data is List<int>) {
      return data.length;
    }
    if (data is Uint8List) {
      return data.length;
    }
    if (data is String) {
      if (data.trim().isEmpty) {
        return 0;
      }
      if (data.length < 512 && data.contains("IP address")) {
        return 0;
      }
      return data.length * 4;
    }
    if (data is Map) {
      return data.toString().length * 4;
    }
    return null;
  }

  static NetworkCache _copyCache(NetworkCache cache) => NetworkCache(
    uri: cache.uri,
    requestHeaders: _copyRequestHeaders(cache.requestHeaders),
    responseHeaders: _copyResponseHeaders(cache.responseHeaders),
    data: _copyCacheData(cache.data),
    time: cache.time,
    size: cache.size,
    responseType: cache.responseType,
  );

  static Map<String, dynamic> _copyRequestHeaders(
    Map<String, dynamic> headers,
  ) => headers.map((key, value) => MapEntry(key, _copyCacheData(value)));

  static Map<String, List<String>> _copyResponseHeaders(
    Map<String, List<String>> headers,
  ) => headers.map((key, value) => MapEntry(key, List<String>.from(value)));

  static Object? _copyCacheData(Object? data) {
    if (data is Uint8List) return Uint8List.fromList(data);
    if (data is List<int>) return List<int>.from(data);
    if (data is List<String>) return List<String>.from(data);
    if (data is List) {
      return data.map<Object?>(_copyCacheData).toList(growable: false);
    }
    if (data is Set) {
      return data.map<Object?>(_copyCacheData).toSet();
    }
    if (data is Iterable) {
      return data.map<Object?>(_copyCacheData).toList(growable: false);
    }
    if (data is Map) {
      if (data.keys.every((key) => key is String)) {
        return <String, dynamic>{
          for (final entry in data.entries)
            entry.key as String: _copyCacheData(entry.value),
        };
      }
      return <dynamic, dynamic>{
        for (final entry in data.entries)
          _copyCacheData(entry.key): _copyCacheData(entry.value),
      };
    }
    return data;
  }
}

bool isPrivateNetworkRequest(Map<String, dynamic> headers) {
  return networkHeadersContainSecrets(headers);
}
