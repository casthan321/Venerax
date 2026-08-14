import 'dart:convert';

const _maximumInspectedBodyBytes = 256 * 1024;

/// Detects a Cloudflare challenge without treating every HTTP 403 as one.
///
/// `cf-mitigated: challenge` is Cloudflare's explicit signal. The HTML
/// fallback is deliberately conservative: it requires a challenge status and
/// either multiple Cloudflare-specific markers or one marker plus a
/// Cloudflare response header.
bool isCloudflareChallengeResponse({
  required int? statusCode,
  required Map<String, List<String>> headers,
  Object? body,
}) {
  final normalizedHeaders = <String, List<String>>{
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  final mitigation = normalizedHeaders['cf-mitigated'];
  if (mitigation?.any((value) => value.trim().toLowerCase() == 'challenge') ==
      true) {
    return true;
  }

  if (statusCode != 403 && statusCode != 429) return false;

  final html = _bodyText(body).toLowerCase();
  if (html.isEmpty) return false;

  final markerCount = <String>[
    '/cdn-cgi/challenge-platform/',
    'window._cf_chl_opt',
    'id="challenge-form"',
    "id='challenge-form'",
    'cf-chl-widget',
  ].where(html.contains).length;
  if (markerCount >= 2) return true;

  final server = normalizedHeaders['server']?.join(',').toLowerCase() ?? '';
  final hasCloudflareHeader =
      server.contains('cloudflare') ||
      normalizedHeaders.containsKey('cf-ray') ||
      normalizedHeaders.containsKey('cf-cache-status');
  return markerCount == 1 && hasCloudflareHeader;
}

/// Removes credentials, query parameters and fragments before an URL can be
/// rendered in an error message or reconstructed from that message.
Uri safeChallengeUri(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Unsupported challenge URL');
  }
  if (uri.host.isEmpty) {
    throw const FormatException('Challenge URL has no host');
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path.isEmpty ? '/' : uri.path,
  );
}

/// URL used inside the verification WebView. It retains the request query (it
/// may select the protected resource) but removes credentials and fragments.
/// Unlike [safeChallengeUri], this value must never be rendered or logged.
Uri challengeNavigationUri(Uri uri) {
  safeChallengeUri(uri);
  return uri.replace(userInfo: '').removeFragment();
}

/// Web origin comparison: scheme, host and effective port must all match.
bool haveSameWebOrigin(Uri first, Uri second) {
  if ((first.scheme != 'http' && first.scheme != 'https') ||
      (second.scheme != 'http' && second.scheme != 'https')) {
    return false;
  }
  return first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      _effectivePort(first) == _effectivePort(second);
}

String _bodyText(Object? body) {
  if (body is String) {
    if (body.length <= _maximumInspectedBodyBytes) return body;
    return body.substring(0, _maximumInspectedBodyBytes);
  }
  if (body is List<int>) {
    final bytes = body.length <= _maximumInspectedBodyBytes
        ? body
        : body.sublist(0, _maximumInspectedBodyBytes);
    return utf8.decode(bytes, allowMalformed: true);
  }
  return '';
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
}
