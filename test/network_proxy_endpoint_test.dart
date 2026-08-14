import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/network/system_proxy.dart';

void main() {
  test('proxy endpoint never exposes credentials in its diagnostic URL', () {
    const endpoint = NetworkProxyEndpoint(
      scheme: 'http',
      url: 'http://user:secret@example.com:8080',
      credentialFreeUrl: 'http://example.com:8080',
      authority: 'example.com:8080',
      username: 'user',
      password: 'secret',
    );

    expect(endpoint.hasCredentials, isTrue);
    expect(endpoint.credentialFreeUrl, isNot(contains('secret')));
    expect(endpoint.authority, 'example.com:8080');
  });

  test('dart:io fails clearly instead of misusing a SOCKS proxy', () {
    const endpoint = NetworkProxyEndpoint(
      scheme: 'socks5',
      url: 'socks5://proxy.example:1080',
      credentialFreeUrl: 'socks5://proxy.example:1080',
      authority: 'proxy.example:1080',
    );

    expect(
      () => configureHttpClientProxy(
        HttpClient(),
        NetworkProxyConfiguration.all(endpoint),
      ),
      throwsUnsupportedError,
    );
  });

  test('scheme-specific routing never collapses into one endpoint', () {
    final routing = NetworkProxyConfiguration(
      usesSystemResolution: true,
      routes: const [
        NetworkProxyRoute(
          condition: NetworkProxyCondition.http,
          endpoint: NetworkProxyEndpoint(
            scheme: 'http',
            url: 'http://plain.example:8080',
            credentialFreeUrl: 'http://plain.example:8080',
            authority: 'plain.example:8080',
          ),
        ),
        NetworkProxyRoute(
          condition: NetworkProxyCondition.https,
          endpoint: NetworkProxyEndpoint(
            scheme: 'http',
            url: 'http://secure.example:8443',
            credentialFreeUrl: 'http://secure.example:8443',
            authority: 'secure.example:8443',
          ),
        ),
      ],
    );

    expect(
      routing.directiveFor(Uri.parse('http://comic.example/page')),
      'PROXY plain.example:8080',
    );
    expect(
      routing.directiveFor(Uri.parse('https://comic.example/page')),
      'PROXY secure.example:8443',
    );
    expect(
      routing.directiveFor(Uri.parse('ftp://comic.example/page')),
      'DIRECT',
    );
    expect(routing.credentialFreeUrl, isNull);
  });

  test('system routes leave embedded browsers on the OS resolver', () {
    final routing = NetworkProxyConfiguration.all(
      const NetworkProxyEndpoint(
        scheme: 'http',
        url: 'http://proxy.example:8080',
        credentialFreeUrl: 'http://proxy.example:8080',
        authority: 'proxy.example:8080',
      ),
      usesSystemResolution: true,
    );

    expect(routing.credentialFreeUrl, isNull);
  });

  test('automatic-only system proxy fails closed for native HTTP', () {
    final system = parseSystemProxyConfiguration(
      'autodetect=1;autoconfig=1;bypass=1',
    );
    final routing = NetworkProxyConfiguration(
      routes: const <NetworkProxyRoute>[],
      usesSystemResolution: true,
      blocksNativeHttp: system.requiresManualProxyForNativeHttp,
    );

    expect(routing.credentialFreeUrl, isNull);
    expect(
      () => routing.routes,
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('select a manual proxy'),
        ),
      ),
    );
    expect(() => buildRHttpProxySettings(routing), throwsUnsupportedError);
    expect(
      () => configureHttpClientProxy(HttpClient(), routing),
      throwsUnsupportedError,
    );
  });

  test('static system route remains usable alongside PAC markers', () {
    final system = parseSystemProxyConfiguration(
      'http=plain.example:8080;autodetect=1;autoconfig=1;bypass=1',
    );
    final routing = NetworkProxyConfiguration(
      routes: system.routes.map(
        (route) => NetworkProxyRoute(
          condition: NetworkProxyCondition.http,
          endpoint: NetworkProxyEndpoint(
            scheme: route.endpoint.scheme,
            url: route.endpoint.url,
            credentialFreeUrl: route.endpoint.url,
            authority: route.endpoint.authority,
          ),
        ),
      ),
      usesSystemResolution: true,
      blocksNativeHttp: system.requiresManualProxyForNativeHttp,
    );

    expect(routing.routes, hasLength(1));
    expect(
      routing.directiveFor(Uri.parse('http://comic.example/page')),
      'PROXY plain.example:8080',
    );
    expect(routing.credentialFreeUrl, isNull);
  });

  test('rhttp receives HTTP and HTTPS conditions independently', () {
    final routing = NetworkProxyConfiguration(
      routes: const [
        NetworkProxyRoute(
          condition: NetworkProxyCondition.http,
          endpoint: NetworkProxyEndpoint(
            scheme: 'http',
            url: 'http://plain.example:8080',
            credentialFreeUrl: 'http://plain.example:8080',
            authority: 'plain.example:8080',
          ),
        ),
        NetworkProxyRoute(
          condition: NetworkProxyCondition.https,
          endpoint: NetworkProxyEndpoint(
            scheme: 'http',
            url: 'http://secure.example:8443',
            credentialFreeUrl: 'http://secure.example:8443',
            authority: 'secure.example:8443',
          ),
        ),
      ],
    );

    final routes = buildRHttpProxyRoutes(routing).cast<rhttp.StaticProxy>();
    expect(routes, hasLength(2));
    expect(routes[0].url, 'http://plain.example:8080');
    expect(routes[0].condition, rhttp.ProxyCondition.onlyHttp);
    expect(routes[1].url, 'http://secure.example:8443');
    expect(routes[1].condition, rhttp.ProxyCondition.onlyHttps);
    expect(buildRHttpProxySettings(routing), isNot(isA<rhttp.StaticProxy>()));
  });

  test('a manual all-route remains one rhttp static proxy', () {
    final routing = NetworkProxyConfiguration.all(
      const NetworkProxyEndpoint(
        scheme: 'http',
        url: 'http://proxy.example:8080',
        credentialFreeUrl: 'http://proxy.example:8080',
        authority: 'proxy.example:8080',
      ),
    );

    final settings = buildRHttpProxySettings(routing);
    expect(settings, isA<rhttp.StaticProxy>());
    expect((settings as rhttp.StaticProxy).condition, rhttp.ProxyCondition.all);
  });
}
