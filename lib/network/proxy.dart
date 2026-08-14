import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview_proxy.dart';

import 'system_proxy.dart';

class NetworkProxyEndpoint {
  const NetworkProxyEndpoint({
    required this.scheme,
    required this.url,
    required this.credentialFreeUrl,
    required this.authority,
    this.username,
    this.password,
  });

  final String scheme;

  /// URL accepted by rhttp. It may contain percent-encoded credentials.
  final String url;

  /// URL safe for Chromium command-line configuration and diagnostics.
  final String credentialFreeUrl;
  final String authority;
  final String? username;
  final String? password;

  bool get hasCredentials => username != null;
}

enum NetworkProxyCondition { http, https, all }

class NetworkProxyRoute {
  const NetworkProxyRoute({required this.condition, required this.endpoint});

  final NetworkProxyCondition condition;
  final NetworkProxyEndpoint endpoint;

  bool matchesScheme(String scheme) => switch (condition) {
    NetworkProxyCondition.http => scheme.toLowerCase() == 'http',
    NetworkProxyCondition.https => scheme.toLowerCase() == 'https',
    NetworkProxyCondition.all => true,
  };
}

/// Complete proxy routing used by native HTTP clients.
///
/// [usesSystemResolution] keeps embedded browsers on their operating-system
/// resolver instead of converting system settings into one Chromium proxy
/// argument. That preserves PAC and bypass behavior in the browser even though
/// the native HTTP bridge currently exposes static routes only.
class NetworkProxyConfiguration {
  NetworkProxyConfiguration({
    required Iterable<NetworkProxyRoute> routes,
    this.usesSystemResolution = false,
    this.blocksNativeHttp = false,
  }) : _routes = List.unmodifiable(routes);

  NetworkProxyConfiguration.all(
    NetworkProxyEndpoint endpoint, {
    this.usesSystemResolution = false,
    this.blocksNativeHttp = false,
  }) : _routes = List.unmodifiable([
         NetworkProxyRoute(
           condition: NetworkProxyCondition.all,
           endpoint: endpoint,
         ),
       ]);

  static const unsupportedAutomaticProxyMessage =
      'The system uses automatic proxy discovery or a PAC file, which native '
      'HTTP requests cannot evaluate safely. Native HTTP access was blocked; '
      'select a manual proxy in Settings and try again.';

  final List<NetworkProxyRoute> _routes;
  final bool usesSystemResolution;
  final bool blocksNativeHttp;

  /// Routes for native HTTP clients. Reading them fails closed for an
  /// automatic-only system configuration, while [credentialFreeUrl] can still
  /// leave WebView2 on the operating-system resolver.
  List<NetworkProxyRoute> get routes {
    if (blocksNativeHttp) {
      throw UnsupportedError(unsupportedAutomaticProxyMessage);
    }
    return _routes;
  }

  NetworkProxyEndpoint? endpointForScheme(String scheme) {
    for (final route in routes) {
      if (route.condition != NetworkProxyCondition.all &&
          route.matchesScheme(scheme)) {
        return route.endpoint;
      }
    }
    for (final route in routes) {
      if (route.condition == NetworkProxyCondition.all) {
        return route.endpoint;
      }
    }
    return null;
  }

  /// Safe value for the desktop WebView constructor.
  ///
  /// System mode intentionally returns null so WebView2 continues using the
  /// OS resolver (including PAC and bypass rules). A split manual route is not
  /// currently exposed by settings and therefore also cannot be flattened.
  String? get credentialFreeUrl {
    if (usesSystemResolution || _routes.length != 1) return null;
    final route = _routes.single;
    if (route.condition != NetworkProxyCondition.all) return null;
    return route.endpoint.credentialFreeUrl;
  }

  String directiveFor(Uri uri) {
    final endpoint = endpointForScheme(uri.scheme);
    if (endpoint == null) return 'DIRECT';
    if (endpoint.scheme != 'http') {
      throw UnsupportedError(
        'The dart:io HTTP client cannot use ${endpoint.scheme} proxy '
        'transports',
      );
    }
    return 'PROXY ${endpoint.authority}';
  }
}

NetworkProxyConfiguration? _cachedProxy;

DateTime? _cachedProxyTime;

Future<NetworkProxyConfiguration?> getNetworkProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  final proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

/// Compatibility helper for APIs expecting a credential-free host:port.
/// Split or scheme-limited configurations deliberately return null because
/// selecting one endpoint would route some requests through the wrong proxy.
Future<String?> getProxy() async {
  final configuration = await getNetworkProxy();
  if (configuration == null || configuration.routes.length != 1) return null;
  final route = configuration.routes.single;
  return route.condition == NetworkProxyCondition.all
      ? route.endpoint.authority
      : null;
}

void configureHttpClientProxy(
  HttpClient client,
  NetworkProxyConfiguration? proxy,
) {
  if (proxy != null) {
    for (final route in proxy.routes) {
      if (route.endpoint.scheme != 'http') {
        throw UnsupportedError(
          'The dart:io HTTP client cannot use '
          '${route.endpoint.scheme} proxy transports',
        );
      }
    }
  }
  client.findProxy = (uri) => proxy?.directiveFor(uri) ?? 'DIRECT';
  final authenticatedEndpoints = proxy?.routes
      .map((route) => route.endpoint)
      .where((endpoint) => endpoint.hasCredentials)
      .toList(growable: false);
  if (authenticatedEndpoints?.isNotEmpty == true) {
    client.authenticateProxy = (host, port, scheme, realm) {
      for (final endpoint in authenticatedEndpoints!) {
        if (host.toLowerCase() != endpoint.authorityHost.toLowerCase() ||
            port != endpoint.authorityPort) {
          continue;
        }
        client.addProxyCredentials(
          host,
          port,
          realm ?? '',
          HttpClientBasicCredentials(
            endpoint.username!,
            endpoint.password ?? '',
          ),
        );
        return Future.value(true);
      }
      return Future.value(false);
    };
  }
}

extension on NetworkProxyEndpoint {
  String get authorityHost {
    if (authority.startsWith('[')) {
      return authority.substring(1, authority.indexOf(']'));
    }
    return authority.substring(0, authority.lastIndexOf(':'));
  }

  int get authorityPort =>
      int.parse(authority.substring(authority.lastIndexOf(':') + 1));
}

String? _lastSystemProxyDiagnostic;

Future<NetworkProxyConfiguration?> _getProxy() async {
  final setting = appdata.settings['proxy'];
  var normalizedSetting = setting;
  final parsed = resolveWebviewProxyConfigurationOrSystem(
    setting: setting,
    platform: WebviewProxyPlatform.other,
    onInvalid: (error, stackTrace) {
      normalizedSetting = 'system';
      Log.error(
        'Proxy settings',
        'Invalid saved proxy setting; using the system proxy: $error',
        stackTrace,
      );
    },
  );
  if (parsed.mode == WebviewProxyMode.direct) return null;

  if (parsed.mode == WebviewProxyMode.manual && normalizedSetting != 'system') {
    final normalized = parsed.normalizedSetting;
    final url = normalized.contains('://')
        ? normalized
        : '${parsed.proxyScheme ?? 'http'}://$normalized';
    return NetworkProxyConfiguration.all(
      NetworkProxyEndpoint(
        scheme: parsed.proxyScheme ?? 'http',
        url: url,
        credentialFreeUrl: parsed.proxyUrl!,
        authority: _formatAuthority(parsed.proxyHost!, parsed.proxyPort!),
        username: parsed.credentials?.username,
        password: parsed.credentials?.password,
      ),
    );
  }

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (error, stackTrace) {
      Log.error(
        'System proxy',
        'Unable to read the static system proxy (${error.runtimeType})',
        stackTrace,
      );
      return null;
    }
  } else {
    res = "No Proxy";
  }
  final systemProxy = parseSystemProxyConfiguration(res);
  _reportSystemProxyLimitations(systemProxy);
  if (systemProxy.isEmpty && !systemProxy.requiresManualProxyForNativeHttp) {
    return null;
  }
  return NetworkProxyConfiguration(
    usesSystemResolution: true,
    blocksNativeHttp: systemProxy.requiresManualProxyForNativeHttp,
    routes: systemProxy.routes.map(
      (route) => NetworkProxyRoute(
        condition: switch (route.condition) {
          SystemProxyRouteCondition.http => NetworkProxyCondition.http,
          SystemProxyRouteCondition.https => NetworkProxyCondition.https,
          SystemProxyRouteCondition.all => NetworkProxyCondition.all,
        },
        endpoint: NetworkProxyEndpoint(
          scheme: route.endpoint.scheme,
          url: route.endpoint.url,
          credentialFreeUrl: route.endpoint.url,
          authority: route.endpoint.authority,
        ),
      ),
    ),
  );
}

void _reportSystemProxyLimitations(SystemProxyConfiguration configuration) {
  final messages = <String>[];
  if (!configuration.isEmpty && (App.isWindows || App.isAndroid)) {
    messages.add(
      'The platform bridge supplies static proxy endpoints only. PAC and '
      'proxy-bypass rules cannot be applied to native HTTP requests; embedded '
      'web views continue using the operating-system resolver.',
    );
  }
  if (configuration.issues.isNotEmpty) {
    final issueNames = configuration.issues.map((issue) => issue.name).toList()
      ..sort();
    messages.add(
      'Some system proxy entries were not applied: ${issueNames.join(', ')}.',
    );
  }
  if (messages.isEmpty) return;
  final diagnostic = messages.join(' ');
  if (_lastSystemProxyDiagnostic == diagnostic) return;
  _lastSystemProxyDiagnostic = diagnostic;
  Log.warning('System proxy limitations', diagnostic);
}

String _formatAuthority(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';
