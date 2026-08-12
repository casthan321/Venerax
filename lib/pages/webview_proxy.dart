enum WebviewProxyPlatform { android, windows, other }

enum WebviewProxyMode { system, direct, manual }

enum AndroidWebviewProxyAction { none, clear, direct, manual }

typedef WebviewProxyCredentials = ({String username, String password});

class WebviewProxyConfiguration {
  const WebviewProxyConfiguration({
    required this.mode,
    required this.normalizedSetting,
    required this.androidAction,
    this.androidDirects = const [],
    this.proxyUrl,
    this.windowsBrowserArguments,
    this.credentials,
    this.proxyHost,
    this.proxyPort,
    this.proxyScheme,
    this.hasExplicitPort = false,
  });

  final WebviewProxyMode mode;
  final String normalizedSetting;
  final AndroidWebviewProxyAction androidAction;
  final List<String> androidDirects;

  /// A credential-free proxy URL suitable for native proxy configuration.
  final String? proxyUrl;

  /// Chromium command-line arguments must never contain proxy credentials.
  final String? windowsBrowserArguments;
  final WebviewProxyCredentials? credentials;
  final String? proxyHost;
  final int? proxyPort;
  final String? proxyScheme;
  final bool hasExplicitPort;

  /// Whether an HTTP-auth challenge belongs to the configured proxy.
  ///
  /// WebView2 reports the challenged endpoint, including its port. Android's
  /// WebView API reports the challenged host but derives protocol and port from
  /// the currently loaded page, so those two Android values cannot safely be
  /// interpreted as proxy metadata. In either case credentials are never sent
  /// to a challenge for a different host.
  bool matchesAuthenticationTarget({
    required WebviewProxyPlatform platform,
    required String host,
    int? port,
    String? scheme,
  }) {
    if (credentials == null || proxyHost == null || proxyPort == null) {
      return false;
    }
    if (_normalizeHostForComparison(proxyHost!) !=
        _normalizeHostForComparison(host)) {
      return false;
    }
    if (platform == WebviewProxyPlatform.android) {
      return true;
    }
    if (port != null && port > 0 && proxyPort != port) {
      return false;
    }
    return scheme == null ||
        scheme.isEmpty ||
        proxyScheme == null ||
        proxyScheme!.toLowerCase() == scheme.toLowerCase();
  }
}

/// Resolves a setting while treating corrupt legacy values as `system`.
///
/// [onInvalid] receives only the parser error; callers must not log [setting]
/// because it may contain a proxy password.
WebviewProxyConfiguration resolveWebviewProxyConfigurationOrSystem({
  required Object? setting,
  required WebviewProxyPlatform platform,
  void Function(Object error, StackTrace stackTrace)? onInvalid,
}) {
  try {
    if (setting is! String) {
      throw const FormatException('Invalid proxy setting');
    }
    return resolveWebviewProxyConfiguration(
      setting: setting,
      platform: platform,
    );
  } catch (error, stackTrace) {
    // Error reporting is best effort: a logger must never turn a corrupt
    // legacy setting into an application-startup failure.
    try {
      onInvalid?.call(error, stackTrace);
    } catch (_) {}
    return resolveWebviewProxyConfiguration(
      setting: 'system',
      platform: platform,
    );
  }
}

WebviewProxyConfiguration resolveWebviewProxyConfiguration({
  required String setting,
  required WebviewProxyPlatform platform,
}) {
  final value = setting.trim();
  if (value == 'system') {
    return WebviewProxyConfiguration(
      mode: WebviewProxyMode.system,
      normalizedSetting: 'system',
      androidAction: platform == WebviewProxyPlatform.android
          ? AndroidWebviewProxyAction.clear
          : AndroidWebviewProxyAction.none,
    );
  }
  if (value == 'direct') {
    return WebviewProxyConfiguration(
      mode: WebviewProxyMode.direct,
      normalizedSetting: 'direct',
      androidAction: platform == WebviewProxyPlatform.android
          ? AndroidWebviewProxyAction.direct
          : AndroidWebviewProxyAction.none,
      androidDirects: platform == WebviewProxyPlatform.android
          ? const ['*']
          : const [],
      windowsBrowserArguments: platform == WebviewProxyPlatform.windows
          ? '--proxy-server=direct://'
          : null,
    );
  }

  final endpoint = _parseManualProxy(value);
  return WebviewProxyConfiguration(
    mode: WebviewProxyMode.manual,
    normalizedSetting: endpoint.normalizedSetting,
    androidAction: platform == WebviewProxyPlatform.android
        ? AndroidWebviewProxyAction.manual
        : AndroidWebviewProxyAction.none,
    proxyUrl: endpoint.url,
    windowsBrowserArguments: platform == WebviewProxyPlatform.windows
        ? '--proxy-server=${endpoint.url}'
        : null,
    credentials: endpoint.credentials,
    proxyHost: endpoint.host,
    proxyPort: endpoint.port,
    proxyScheme: endpoint.scheme,
    hasExplicitPort: endpoint.hasExplicitPort,
  );
}

/// Validates fields from the settings screen and returns a canonical value.
///
/// User info is percent-encoded before it is persisted, so delimiters inside a
/// username or password cannot change the proxy endpoint when it is read back.
String normalizeManualWebviewProxySetting({
  required String host,
  String port = '',
  String username = '',
  String password = '',
  String scheme = 'http',
}) {
  final normalizedHost = _validateAndNormalizeHost(host);
  final normalizedScheme = _validateScheme(scheme);
  final normalizedPort = port.trim();
  if (password.isNotEmpty && username.isEmpty) {
    throw const FormatException('Username cannot be empty');
  }

  final buffer = StringBuffer('$normalizedScheme://');
  if (username.isNotEmpty) {
    buffer.write(Uri.encodeComponent(username));
    buffer.write(':');
    buffer.write(Uri.encodeComponent(password));
    buffer.write('@');
  }
  buffer.write(_formatHost(normalizedHost));
  if (normalizedPort.isNotEmpty) {
    buffer.write(':$normalizedPort');
  }

  return resolveWebviewProxyConfiguration(
    setting: buffer.toString(),
    platform: WebviewProxyPlatform.other,
  ).normalizedSetting;
}

typedef _ManualProxyEndpoint = ({
  String url,
  String normalizedSetting,
  String host,
  int port,
  bool hasExplicitPort,
  String scheme,
  WebviewProxyCredentials? credentials,
});

_ManualProxyEndpoint _parseManualProxy(String setting) {
  if (setting.isEmpty || _containsControlCharacter(setting)) {
    throw const FormatException('Invalid manual proxy');
  }

  var scheme = 'http';
  var authority = setting;
  final schemeSeparator = setting.indexOf('://');
  if (schemeSeparator >= 0) {
    scheme = _validateScheme(setting.substring(0, schemeSeparator));
    authority = setting.substring(schemeSeparator + 3);
  }
  if (authority.isEmpty ||
      authority.contains('/') ||
      authority.contains('?') ||
      authority.contains('#')) {
    throw const FormatException('Invalid manual proxy');
  }

  String? encodedUserInfo;
  final userInfoSeparator = authority.lastIndexOf('@');
  if (userInfoSeparator >= 0) {
    encodedUserInfo = authority.substring(0, userInfoSeparator);
    authority = authority.substring(userInfoSeparator + 1);
    if (encodedUserInfo.isEmpty || authority.isEmpty) {
      throw const FormatException('Invalid manual proxy credentials');
    }
  }

  final parsedAuthority = _parseAuthority(authority, scheme);
  WebviewProxyCredentials? credentials;
  if (encodedUserInfo != null) {
    final separator = encodedUserInfo.indexOf(':');
    final encodedUsername = separator < 0
        ? encodedUserInfo
        : encodedUserInfo.substring(0, separator);
    final encodedPassword = separator < 0
        ? ''
        : encodedUserInfo.substring(separator + 1);
    try {
      final username = Uri.decodeComponent(encodedUsername);
      final password = Uri.decodeComponent(encodedPassword);
      if (username.isEmpty) {
        throw const FormatException('Invalid manual proxy username');
      }
      credentials = (username: username, password: password);
    } catch (_) {
      throw const FormatException('Invalid manual proxy credentials');
    }
  }

  final hostForUrl = _formatHost(parsedAuthority.host);
  final explicitPort = parsedAuthority.hasExplicitPort
      ? ':${parsedAuthority.port}'
      : '';
  final url = '$scheme://$hostForUrl$explicitPort';
  final normalizedUserInfo = credentials == null
      ? ''
      : '${Uri.encodeComponent(credentials.username)}:'
            '${Uri.encodeComponent(credentials.password)}@';
  final schemePrefix = scheme == 'http' ? '' : '$scheme://';
  final normalizedSetting =
      '$schemePrefix$normalizedUserInfo$hostForUrl$explicitPort';

  return (
    url: url,
    normalizedSetting: normalizedSetting,
    host: parsedAuthority.host,
    port: parsedAuthority.port,
    hasExplicitPort: parsedAuthority.hasExplicitPort,
    scheme: scheme,
    credentials: credentials,
  );
}

typedef _ParsedProxyAuthority = ({String host, int port, bool hasExplicitPort});

_ParsedProxyAuthority _parseAuthority(String authority, String scheme) {
  String host;
  String portText = '';
  var hasExplicitPort = false;

  if (authority.startsWith('[')) {
    final bracket = authority.indexOf(']');
    if (bracket < 0) {
      throw const FormatException('Invalid proxy host');
    }
    host = authority.substring(1, bracket);
    final remainder = authority.substring(bracket + 1);
    if (remainder.isNotEmpty) {
      if (!remainder.startsWith(':') || remainder.length == 1) {
        throw const FormatException('Invalid proxy port');
      }
      portText = remainder.substring(1);
      hasExplicitPort = true;
    }
  } else {
    final colonCount = ':'.allMatches(authority).length;
    if (colonCount == 1) {
      final separator = authority.lastIndexOf(':');
      host = authority.substring(0, separator);
      portText = authority.substring(separator + 1);
      hasExplicitPort = true;
    } else {
      // A bare IPv6 literal is accepted only without an explicit port. Use
      // brackets (`[::1]:8080`) whenever a port is required.
      host = authority;
    }
  }

  host = _validateAndNormalizeHost(host);
  final port = hasExplicitPort
      ? _parsePort(portText)
      : _defaultProxyPort(scheme);
  return (host: host, port: port, hasExplicitPort: hasExplicitPort);
}

String _validateScheme(String scheme) {
  final value = scheme.trim().toLowerCase();
  const supportedSchemes = {'http', 'https', 'socks', 'socks4', 'socks5'};
  if (!supportedSchemes.contains(value)) {
    throw const FormatException('Unsupported proxy scheme');
  }
  return value;
}

String _validateAndNormalizeHost(String host) {
  var value = host.trim();
  if (value.startsWith('[') && value.endsWith(']') && value.length > 2) {
    value = value.substring(1, value.length - 1);
  }
  if (value.isEmpty ||
      _containsControlCharacter(value) ||
      RegExp(r'\s').hasMatch(value) ||
      value.contains('/') ||
      value.contains('\\') ||
      value.contains('@') ||
      value.contains('?') ||
      value.contains('#') ||
      value.contains('[') ||
      value.contains(']') ||
      value.contains('%') ||
      value.contains("'") ||
      value.contains('"')) {
    throw const FormatException('Invalid proxy host');
  }

  if (value.contains(':')) {
    // IPv6 literals may contain only hexadecimal groups, colons and the dots
    // used by IPv4-mapped addresses. Zone identifiers are intentionally not
    // supported because `%` has URL-escaping semantics.
    if (!RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(value)) {
      throw const FormatException('Invalid proxy host');
    }
  } else if (RegExp(r'^[0-9.]+$').hasMatch(value)) {
    final octets = value.split('.');
    if (octets.length != 4 ||
        octets.any((octet) {
          final number = int.tryParse(octet);
          return octet.isEmpty || number == null || number > 255;
        })) {
      throw const FormatException('Invalid proxy host');
    }
  } else {
    // Manual proxy hosts are deliberately limited to safe ASCII DNS labels.
    // Internationalized names remain supported through their `xn--` form.
    if (value.length > 253 ||
        value
            .split('.')
            .any(
              (label) =>
                  label.isEmpty ||
                  label.length > 63 ||
                  !RegExp(
                    r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$',
                  ).hasMatch(label),
            )) {
      throw const FormatException('Invalid proxy host');
    }
  }

  // Uri performs strict validation of DNS, IPv4 and IPv6 hosts and normalizes
  // host casing without ever including credentials in an error message.
  final uri = Uri.tryParse('http://${_formatHost(value)}');
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('Invalid proxy host');
  }
  return uri.host.toLowerCase();
}

int _parsePort(String value) {
  if (value.isEmpty || !RegExp(r'^\d+$').hasMatch(value)) {
    throw const FormatException('Proxy port must be a number');
  }
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw const FormatException('Proxy port must be between 1 and 65535');
  }
  return port;
}

bool _containsControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}

String _formatHost(String host) => host.contains(':') ? '[$host]' : host;

String _normalizeHostForComparison(String host) {
  var value = host.trim().toLowerCase();
  if (value.startsWith('[') && value.endsWith(']') && value.length > 2) {
    value = value.substring(1, value.length - 1);
  }
  return value;
}

int _defaultProxyPort(String scheme) => switch (scheme) {
  'https' => 443,
  'socks' || 'socks4' || 'socks5' => 1080,
  _ => 80,
};
