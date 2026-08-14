enum WebviewFailureKind { environment, network, http, tls }

class WebviewFailure {
  const WebviewFailure({
    required this.kind,
    required this.host,
    required this.stage,
    required this.detail,
    this.statusCode,
  });

  final WebviewFailureKind kind;
  final String host;
  final String stage;
  final String detail;
  final int? statusCode;

  String get title => switch (kind) {
    WebviewFailureKind.environment => 'WebView could not start',
    WebviewFailureKind.network => 'Page could not be loaded',
    WebviewFailureKind.http => 'Website returned an error',
    WebviewFailureKind.tls => 'Secure connection failed',
  };
}

/// Whether an error callback belongs to the top-level document. Some WebView
/// implementations do not provide [isForMainFrame], so the current document
/// URL is used as a conservative fallback.
bool isMainFrameWebRequest({
  required bool? isForMainFrame,
  required Uri requestUri,
  required Uri? currentUri,
}) {
  if (isForMainFrame != null) return isForMainFrame;
  if (currentUri == null) return false;
  return _withoutFragment(requestUri) == _withoutFragment(currentUri);
}

String safeWebviewHost(Uri? uri) {
  if (uri == null || uri.host.isEmpty) return 'Unknown host';
  if (!uri.hasPort) return uri.host;
  final defaultPort =
      (uri.scheme == 'https' && uri.port == 443) ||
      (uri.scheme == 'http' && uri.port == 80);
  return defaultPort ? uri.host : '${uri.host}:${uri.port}';
}

Uri _withoutFragment(Uri uri) => uri.replace(fragment: '');
