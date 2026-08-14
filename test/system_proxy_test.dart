import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/system_proxy.dart';

void main() {
  group('selectSystemProxy', () {
    test('accepts a hostname endpoint', () {
      expect(selectSystemProxy('Proxy.Example:8080'), 'proxy.example:8080');
    });

    test('prefers HTTPS from a Windows protocol map', () {
      expect(
        selectSystemProxy('http=plain.example:8080; https=secure.example:8443'),
        'secure.example:8443',
      );
    });

    test('keeps HTTP and HTTPS protocol routes separate', () {
      final configuration = parseSystemProxyConfiguration(
        'http=plain.example:8080; https=secure.example:8443',
      );

      expect(configuration.routes, hasLength(2));
      expect(
        configuration.endpointForScheme('http')?.authority,
        'plain.example:8080',
      );
      expect(
        configuration.endpointForScheme('https')?.authority,
        'secure.example:8443',
      );
    });

    test('does not apply an HTTP-only route to HTTPS requests', () {
      final configuration = parseSystemProxyConfiguration(
        'http=plain.example:8080',
      );

      expect(configuration.endpointForScheme('http'), isNotNull);
      expect(configuration.endpointForScheme('https'), isNull);
    });

    test('uses a bare endpoint as a catch-all route', () {
      final configuration = parseSystemProxyConfiguration('proxy.example:8080');

      expect(
        configuration.routes.single.condition,
        SystemProxyRouteCondition.all,
      );
      expect(
        configuration.endpointForScheme('https')?.authority,
        'proxy.example:8080',
      );
    });

    test('falls back to HTTP and strips a supported scheme', () {
      expect(
        selectSystemProxy('http=http://proxy.example:3128'),
        'proxy.example:3128',
      );
    });

    test('supports bracketed IPv6', () {
      expect(selectSystemProxy('[2001:db8::1]:8080'), '[2001:db8::1]:8080');
    });

    test('preserves an explicit SOCKS protocol for capable clients', () {
      final selection = selectSystemProxyEndpoint(
        'socks=socks5://proxy.example:1080',
      );
      expect(selection?.scheme, 'socks5');
      expect(selection?.authority, 'proxy.example:1080');
      expect(selection?.url, 'socks5://proxy.example:1080');
    });

    test('preserves an explicit HTTPS proxy transport', () {
      final configuration = parseSystemProxyConfiguration(
        'https=https://proxy.example:8443',
      );

      expect(configuration.endpointForScheme('https')?.scheme, 'https');
      expect(
        configuration.endpointForScheme('https')?.url,
        'https://proxy.example:8443',
      );
    });

    test('puts a SOCKS proxy after scheme-specific routes as fallback', () {
      final configuration = parseSystemProxyConfiguration(
        'http=plain.example:8080;socks=socks.example:1080',
      );

      expect(
        configuration.endpointForScheme('http')?.authority,
        'plain.example:8080',
      );
      expect(
        configuration.endpointForScheme('https')?.url,
        'socks5://socks.example:1080',
      );
    });

    test('reports unsupported PAC, bypass, and protocol entries', () {
      final configuration = parseSystemProxyConfiguration(
        'pac=http://config.example/proxy.pac;'
        'bypass=localhost;ftp=ftp.example:8080',
      );

      expect(configuration.routes, isEmpty);
      expect(
        configuration.issues,
        containsAll(<SystemProxyIssue>{
          SystemProxyIssue.unsupportedAutomaticConfiguration,
          SystemProxyIssue.unsupportedBypassRules,
          SystemProxyIssue.unsupportedProtocol,
        }),
      );
    });

    test('recognizes privacy-safe Windows automatic proxy markers', () {
      final configuration = parseSystemProxyConfiguration(
        'autodetect=1;autoconfig=1;bypass=1',
      );

      expect(configuration.routes, isEmpty);
      expect(configuration.hasAutomaticConfiguration, isTrue);
      expect(configuration.requiresManualProxyForNativeHttp, isTrue);
      expect(
        configuration.issues,
        containsAll(<SystemProxyIssue>{
          SystemProxyIssue.unsupportedAutomaticConfiguration,
          SystemProxyIssue.unsupportedBypassRules,
        }),
      );
    });

    test('keeps static routes when automatic settings also exist', () {
      final configuration = parseSystemProxyConfiguration(
        'http=plain.example:8080;autodetect=1;autoconfig=1;bypass=1',
      );

      expect(configuration.routes, hasLength(1));
      expect(configuration.hasAutomaticConfiguration, isTrue);
      expect(configuration.requiresManualProxyForNativeHttp, isFalse);
      expect(
        configuration.endpointForScheme('http')?.authority,
        'plain.example:8080',
      );
    });

    test('Windows bridge exposes markers but not PAC or bypass contents', () {
      final source = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();

      expect(source, contains('"autodetect=1"'));
      expect(source, contains('"autoconfig=1"'));
      expect(source, contains('"bypass=1"'));
      expect(
        source,
        isNot(contains('Utf8FromUtf16(config.lpszAutoConfigUrl)')),
      );
      expect(source, isNot(contains('Utf8FromUtf16(config.lpszProxyBypass)')));
    });

    test('keeps the first duplicate route and reports the conflict', () {
      final configuration = parseSystemProxyConfiguration(
        'https=first.example:8443;https=second.example:9443',
      );

      expect(
        configuration.endpointForScheme('https')?.authority,
        'first.example:8443',
      );
      expect(configuration.issues, contains(SystemProxyIssue.duplicateRoute));
    });

    test('treats no proxy and empty input as direct', () {
      expect(selectSystemProxy('No Proxy'), isNull);
      expect(selectSystemProxy('  '), isNull);
    });

    test('rejects invalid ports, unsafe hosts and credentials', () {
      expect(selectSystemProxy('proxy.example:0'), isNull);
      expect(selectSystemProxy('proxy.example:65536'), isNull);
      expect(selectSystemProxy('proxy.example;evil:8080'), isNull);
      expect(selectSystemProxy('user@proxy.example:8080'), isNull);
      expect(selectSystemProxy('proxy_name.example:8080'), isNull);
    });
  });
}
