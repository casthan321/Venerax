/// A destination condition from a Windows/Android system proxy map.
enum SystemProxyRouteCondition { http, https, all }

/// A proxy endpoint after validation and normalization.
class SystemProxySelection {
  const SystemProxySelection({required this.scheme, required this.authority});

  /// Transport protocol used to connect to the proxy itself.
  final String scheme;
  final String authority;

  String get url => '$scheme://$authority';
}

class SystemProxyRoute {
  const SystemProxyRoute({required this.condition, required this.endpoint});

  final SystemProxyRouteCondition condition;
  final SystemProxySelection endpoint;
}

/// Problems that prevent part of the operating-system proxy configuration
/// from being represented safely by the native HTTP stack.
enum SystemProxyIssue {
  invalidEntry,
  duplicateRoute,
  unsupportedProtocol,
  unsupportedAutomaticConfiguration,
  unsupportedBypassRules,
}

/// Parsed static routes returned by the platform bridge.
///
/// A bare endpoint is an `all` fallback. Protocol maps keep HTTP and HTTPS as
/// separate routes; an absent route means a direct connection for that target
/// scheme. The route order is specific HTTP/HTTPS rules first and an optional
/// catch-all (normally SOCKS or a bare endpoint) last.
class SystemProxyConfiguration {
  SystemProxyConfiguration({
    required Iterable<SystemProxyRoute> routes,
    Iterable<SystemProxyIssue> issues = const [],
  }) : routes = List.unmodifiable(routes),
       issues = Set.unmodifiable(issues);

  final List<SystemProxyRoute> routes;
  final Set<SystemProxyIssue> issues;

  bool get isEmpty => routes.isEmpty;

  bool get hasAutomaticConfiguration =>
      issues.contains(SystemProxyIssue.unsupportedAutomaticConfiguration);

  /// Native HTTP stacks must not silently connect directly when the operating
  /// system relies exclusively on automatic proxy discovery or a PAC file.
  bool get requiresManualProxyForNativeHttp =>
      routes.isEmpty && hasAutomaticConfiguration;

  SystemProxySelection? endpointForScheme(String scheme) {
    final normalized = scheme.toLowerCase();
    for (final route in routes) {
      if ((route.condition == SystemProxyRouteCondition.http &&
              normalized == 'http') ||
          (route.condition == SystemProxyRouteCondition.https &&
              normalized == 'https')) {
        return route.endpoint;
      }
    }
    for (final route in routes) {
      if (route.condition == SystemProxyRouteCondition.all) {
        return route.endpoint;
      }
    }
    return null;
  }
}

/// Parses the static proxy string returned by the platform bridge.
///
/// WinHTTP and Android may return one endpoint (`proxy.example:8080`) or a
/// semicolon-separated map such as
/// `http=proxy-a:8080;https=proxy-b:8443`. The map keys describe the target
/// request scheme, not the transport scheme of the proxy endpoint.
SystemProxyConfiguration parseSystemProxyConfiguration(String rawValue) {
  final value = rawValue.trim();
  if (value.isEmpty || value.toLowerCase() == 'no proxy') {
    return SystemProxyConfiguration(routes: const []);
  }

  final routes = <SystemProxyRouteCondition, SystemProxyRoute>{};
  final seenConditions = <SystemProxyRouteCondition>{};
  final issues = <SystemProxyIssue>{};
  for (final part in value.split(';')) {
    final entry = part.trim();
    if (entry.isEmpty) continue;
    final separator = entry.indexOf('=');
    if (separator < 0) {
      _addRoute(
        routes: routes,
        seenConditions: seenConditions,
        issues: issues,
        condition: SystemProxyRouteCondition.all,
        endpoint: _normalizeProxyEndpoint(entry, 'http'),
      );
      continue;
    }

    final key = entry.substring(0, separator).trim().toLowerCase();
    final candidate = entry.substring(separator + 1).trim();
    final route = switch (key) {
      'http' => (
        condition: SystemProxyRouteCondition.http,
        defaultScheme: 'http',
      ),
      'https' => (
        condition: SystemProxyRouteCondition.https,
        defaultScheme: 'http',
      ),
      'socks' => (
        condition: SystemProxyRouteCondition.all,
        defaultScheme: 'socks5',
      ),
      _ => null,
    };
    if (route == null) {
      issues.add(switch (key) {
        'pac' ||
        'autodetect' ||
        'autoconfig' ||
        'autoconfigurl' => SystemProxyIssue.unsupportedAutomaticConfiguration,
        'bypass' ||
        'proxybypass' ||
        'override' ||
        'proxyoverride' => SystemProxyIssue.unsupportedBypassRules,
        _ => SystemProxyIssue.unsupportedProtocol,
      });
      continue;
    }
    _addRoute(
      routes: routes,
      seenConditions: seenConditions,
      issues: issues,
      condition: route.condition,
      endpoint: _normalizeProxyEndpoint(candidate, route.defaultScheme),
    );
  }

  return SystemProxyConfiguration(
    routes: [
      if (routes[SystemProxyRouteCondition.http] case final route?) route,
      if (routes[SystemProxyRouteCondition.https] case final route?) route,
      if (routes[SystemProxyRouteCondition.all] case final route?) route,
    ],
    issues: issues,
  );
}

void _addRoute({
  required Map<SystemProxyRouteCondition, SystemProxyRoute> routes,
  required Set<SystemProxyRouteCondition> seenConditions,
  required Set<SystemProxyIssue> issues,
  required SystemProxyRouteCondition condition,
  required SystemProxySelection? endpoint,
}) {
  if (!seenConditions.add(condition)) {
    issues.add(SystemProxyIssue.duplicateRoute);
    return;
  }
  if (endpoint == null) {
    issues.add(SystemProxyIssue.invalidEntry);
    return;
  }
  routes[condition] = SystemProxyRoute(
    condition: condition,
    endpoint: endpoint,
  );
}

/// Compatibility helper for old APIs that can represent only one endpoint.
///
/// This must not be used to configure an HTTP client because doing so would
/// collapse protocol-specific routes. New callers should use
/// [parseSystemProxyConfiguration].
String? selectSystemProxy(String rawValue) =>
    selectSystemProxyEndpoint(rawValue)?.authority;

/// Returns a preferred endpoint for credential-free diagnostics only.
SystemProxySelection? selectSystemProxyEndpoint(String rawValue) {
  final configuration = parseSystemProxyConfiguration(rawValue);
  return configuration.endpointForScheme('https') ??
      configuration.endpointForScheme('http');
}

SystemProxySelection? _normalizeProxyEndpoint(
  String candidate,
  String defaultScheme,
) {
  if (candidate.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f) ||
      candidate.contains('@') ||
      candidate.contains('?') ||
      candidate.contains('#') ||
      candidate.contains('\\')) {
    return null;
  }

  var value = candidate;
  var selectedScheme = defaultScheme;
  final schemeSeparator = value.indexOf('://');
  if (schemeSeparator >= 0) {
    final scheme = value.substring(0, schemeSeparator).toLowerCase();
    if (!const {
      'http',
      'https',
      'socks',
      'socks4',
      'socks5',
    }.contains(scheme)) {
      return null;
    }
    selectedScheme = scheme;
    value = value.substring(schemeSeparator + 3);
  }
  if (value.isEmpty || value.contains('/')) return null;

  String host;
  String portText;
  if (value.startsWith('[')) {
    final bracket = value.indexOf(']');
    if (bracket <= 1 ||
        bracket + 2 >= value.length ||
        value[bracket + 1] != ':') {
      return null;
    }
    host = value.substring(1, bracket).toLowerCase();
    portText = value.substring(bracket + 2);
    if (!RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(host)) return null;
  } else {
    if (':'.allMatches(value).length != 1) return null;
    final separator = value.lastIndexOf(':');
    host = value.substring(0, separator).toLowerCase();
    portText = value.substring(separator + 1);
    if (!_isSafeHost(host)) return null;
  }

  if (!RegExp(r'^\d+$').hasMatch(portText)) return null;
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) return null;
  final authority = host.contains(':') ? '[$host]:$port' : '$host:$port';
  return SystemProxySelection(scheme: selectedScheme, authority: authority);
}

bool _isSafeHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
    final octets = host.split('.');
    return octets.length == 4 &&
        octets.every((octet) {
          final number = int.tryParse(octet);
          return octet.isNotEmpty && number != null && number <= 255;
        });
  }
  return host
      .split('.')
      .every(
        (label) =>
            label.isNotEmpty &&
            label.length <= 63 &&
            RegExp(
              r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$',
            ).hasMatch(label),
      );
}
