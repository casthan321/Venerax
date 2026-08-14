import 'dart:convert';
import 'dart:typed_data';

const _maskedValue = '********';

bool isSensitiveNetworkName(Object? name) {
  final normalized = name.toString().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return const [
    'authorization',
    'cookie',
    'password',
    'passwd',
    'secret',
    'token',
    'apikey',
    'signature',
    'credential',
    'session',
  ].any(normalized.contains);
}

bool networkHeadersContainSecrets(Map<String, dynamic> headers) =>
    headers.keys.any(isSensitiveNetworkName);

bool networkUriContainsSecrets(Uri uri) =>
    uri.userInfo.isNotEmpty ||
    uri.queryParametersAll.keys.any(isSensitiveNetworkName);

Map<String, dynamic> redactNetworkHeaders(Map<String, dynamic> headers) {
  return headers.map(
    (key, value) =>
        MapEntry(key, isSensitiveNetworkName(key) ? _maskedValue : value),
  );
}

Object? headerValueCaseInsensitive(Map<String, dynamic> headers, String name) {
  final target = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == target) return entry.value;
  }
  return null;
}

Object? removeHeaderCaseInsensitive(Map<String, dynamic> headers, String name) {
  final target = name.toLowerCase();
  Object? value;
  for (final key in headers.keys.toList(growable: false)) {
    if (key.toLowerCase() == target) {
      value ??= headers[key];
      headers.remove(key);
    }
  }
  return value;
}

String safeNetworkUri(Uri uri) {
  final query = <String, dynamic>{};
  uri.queryParametersAll.forEach((key, values) {
    query[key] = isSensitiveNetworkName(key)
        ? _maskedValue
        : values.length == 1
        ? values.single
        : values;
  });
  return uri
      .replace(userInfo: '', queryParameters: query.isEmpty ? null : query)
      .removeFragment()
      .toString();
}

String summarizeNetworkPayload(Object? data, {int maxCharacters = 768}) {
  if (data == null) return '<empty>';
  if (data is Uint8List || data is List<int>) {
    return '<bytes length=${(data as List<int>).length}>';
  }
  if (data is Stream) return '<stream>';

  String text;
  if (data is Map || data is List) {
    try {
      text = jsonEncode(_redactStructuredValue(data));
    } catch (_) {
      text = '<${data.runtimeType}>';
    }
  } else {
    text = data.toString();
  }
  text = _redactTextSecrets(text);
  if (text.length <= maxCharacters) return text;
  return '${text.substring(0, maxCharacters)}... <truncated>';
}

String summarizeNetworkPayloadMetadata(Object? data) {
  if (data == null) return '<empty>';
  if (data is Uint8List || data is List<int>) {
    return '<bytes length=${(data as List<int>).length}>';
  }
  if (data is String) return '<text length=${data.length}>';
  if (data is Map) return '<map entries=${data.length}>';
  if (data is List) return '<list length=${data.length}>';
  if (data is Stream) return '<stream>';
  return '<${data.runtimeType}>';
}

Object? _redactStructuredValue(Object? value) {
  if (value is Map) {
    return value.map(
      (key, child) => MapEntry(
        key.toString(),
        isSensitiveNetworkName(key)
            ? _maskedValue
            : _redactStructuredValue(child),
      ),
    );
  }
  if (value is List) return value.map(_redactStructuredValue).toList();
  if (value is Uint8List) return '<bytes length=${value.length}>';
  return value;
}

String _redactTextSecrets(String text) {
  return text
      .replaceAll(
        RegExp(
          r'("(?:password|passwd|secret|clientSecret|token|accessToken|refreshToken|session|api[_-]?key|authorization|cookie|signature|credential)"\s*:\s*)"[^"]*"',
          caseSensitive: false,
        ),
        r'$1"********"',
      )
      .replaceAll(
        RegExp(
          r'((?:password|passwd|secret|clientSecret|token|accessToken|refreshToken|session|api[_-]?key|signature|credential)=)[^&\s]+',
          caseSensitive: false,
        ),
        r'$1********',
      );
}
