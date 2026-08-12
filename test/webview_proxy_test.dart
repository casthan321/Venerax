import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webview_proxy.dart';

void main() {
  group('Windows WebView2 proxy', () {
    test('system keeps the WebView2 system proxy', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'system',
        platform: WebviewProxyPlatform.windows,
      );

      expect(config.mode, WebviewProxyMode.system);
      expect(config.windowsBrowserArguments, isNull);
      expect(config.androidAction, AndroidWebviewProxyAction.none);
    });

    test('direct explicitly disables proxy resolution', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'direct',
        platform: WebviewProxyPlatform.windows,
      );

      expect(config.windowsBrowserArguments, '--proxy-server=direct://');
      expect(config.androidAction, AndroidWebviewProxyAction.none);
    });

    test('manual proxy becomes a credential-free browser argument', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'alice:secret@127.0.0.1:7890',
        platform: WebviewProxyPlatform.windows,
      );

      expect(
        config.windowsBrowserArguments,
        '--proxy-server=http://127.0.0.1:7890',
      );
      expect(config.windowsBrowserArguments, isNot(contains('secret')));
      expect(config.proxyUrl, isNot(contains('alice')));
      expect(config.credentials, (username: 'alice', password: 'secret'));
      expect(
        config.matchesAuthenticationTarget(
          platform: WebviewProxyPlatform.windows,
          host: '127.0.0.1',
          port: 7890,
          scheme: 'http',
        ),
        isTrue,
      );
    });

    test('credentials are not sent to a different endpoint', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'alice:secret@proxy.example:7890',
        platform: WebviewProxyPlatform.windows,
      );

      expect(
        config.matchesAuthenticationTarget(
          platform: WebviewProxyPlatform.windows,
          host: 'example.com',
          port: 7890,
          scheme: 'http',
        ),
        isFalse,
      );
      expect(
        config.matchesAuthenticationTarget(
          platform: WebviewProxyPlatform.windows,
          host: 'proxy.example',
          port: 8080,
          scheme: 'http',
        ),
        isFalse,
      );
      expect(
        config.matchesAuthenticationTarget(
          platform: WebviewProxyPlatform.windows,
          host: 'proxy.example',
          port: 7890,
          scheme: 'https',
        ),
        isFalse,
      );
    });
  });

  group('Android WebView proxy', () {
    test('system clears a previous process override', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'system',
        platform: WebviewProxyPlatform.android,
      );

      expect(config.androidAction, AndroidWebviewProxyAction.clear);
      expect(config.windowsBrowserArguments, isNull);
    });

    test('direct explicitly matches every URL scheme', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'direct',
        platform: WebviewProxyPlatform.android,
      );

      expect(config.androidAction, AndroidWebviewProxyAction.direct);
      expect(config.androidDirects, ['*']);
      expect(config.windowsBrowserArguments, isNull);
    });

    test('manual uses ProxyController with a normalized URL', () {
      final config = resolveWebviewProxyConfiguration(
        setting: '127.0.0.1:7890',
        platform: WebviewProxyPlatform.android,
      );

      expect(config.androidAction, AndroidWebviewProxyAction.manual);
      expect(config.proxyUrl, 'http://127.0.0.1:7890');
      expect(config.windowsBrowserArguments, isNull);
    });

    test('auth uses only the challenged host reported by Android WebView', () {
      final config = resolveWebviewProxyConfiguration(
        setting: 'alice:secret@proxy.example:7890',
        platform: WebviewProxyPlatform.android,
      );

      // The Android plugin fills protocol/port from the page URL, not the
      // challenged auth endpoint. They must not cause a false negative.
      expect(
        config.matchesAuthenticationTarget(
          platform: WebviewProxyPlatform.android,
          host: 'PROXY.EXAMPLE',
          port: 443,
          scheme: 'https',
        ),
        isTrue,
      );
      expect(
        config.matchesAuthenticationTarget(
          platform: WebviewProxyPlatform.android,
          host: 'origin.example',
          port: 7890,
          scheme: 'http',
        ),
        isFalse,
      );
    });
  });

  group('manual proxy normalization', () {
    test('special credentials are encoded and round trip safely', () {
      final setting = normalizeManualWebviewProxySetting(
        host: 'Proxy.Example',
        port: '8080',
        username: 'al@ice:name',
        password: 'p@ss:% word"',
      );
      expect(
        setting,
        'al%40ice%3Aname:p%40ss%3A%25%20word%22@proxy.example:8080',
      );

      final config = resolveWebviewProxyConfiguration(
        setting: setting,
        platform: WebviewProxyPlatform.windows,
      );
      expect(config.credentials, (
        username: 'al@ice:name',
        password: 'p@ss:% word"',
      ));
      expect(config.windowsBrowserArguments, isNot(contains('p%40ss')));
      expect(config.windowsBrowserArguments, isNot(contains('word')));
    });

    test('IPv6 is bracketed canonically and supports a port', () {
      final setting = normalizeManualWebviewProxySetting(
        host: '2001:DB8::1',
        port: '7890',
      );
      final config = resolveWebviewProxyConfiguration(
        setting: setting,
        platform: WebviewProxyPlatform.windows,
      );

      expect(setting, '[2001:db8::1]:7890');
      expect(config.proxyHost, '2001:db8::1');
      expect(config.proxyUrl, 'http://[2001:db8::1]:7890');
    });

    test('non-http scheme and default port are retained', () {
      final setting = normalizeManualWebviewProxySetting(
        scheme: 'socks5',
        host: 'localhost',
      );
      final config = resolveWebviewProxyConfiguration(
        setting: setting,
        platform: WebviewProxyPlatform.windows,
      );

      expect(setting, 'socks5://localhost');
      expect(config.proxyPort, 1080);
      expect(config.hasExplicitPort, isFalse);
      expect(config.proxyUrl, 'socks5://localhost');
    });

    test('invalid saved setting safely falls back without echoing it', () {
      Object? reportedError;
      final config = resolveWebviewProxyConfigurationOrSystem(
        setting: 'alice:%not-encoded@proxy.example:7890',
        platform: WebviewProxyPlatform.windows,
        onInvalid: (error, _) => reportedError = error,
      );

      expect(reportedError, isA<FormatException>());
      expect(reportedError.toString(), isNot(contains('alice')));
      expect(config.mode, WebviewProxyMode.system);
      expect(config.windowsBrowserArguments, isNull);
    });

    test('fallback remains safe when error reporting throws', () {
      final config = resolveWebviewProxyConfigurationOrSystem(
        setting: 'alice:%not-encoded@proxy.example:7890',
        platform: WebviewProxyPlatform.windows,
        onInvalid: (_, _) => throw StateError('logger unavailable'),
      );

      expect(config.mode, WebviewProxyMode.system);
      expect(config.windowsBrowserArguments, isNull);
    });

    test('non-string legacy setting safely falls back to system', () {
      Object? reportedError;
      final config = resolveWebviewProxyConfigurationOrSystem(
        setting: <String, Object?>{'unexpected': true},
        platform: WebviewProxyPlatform.windows,
        onInvalid: (error, _) => reportedError = error,
      );

      expect(reportedError, isA<FormatException>());
      expect(config.mode, WebviewProxyMode.system);
      expect(config.windowsBrowserArguments, isNull);
    });

    test('save rejects unsafe hosts and invalid ports', () {
      expect(
        () => normalizeManualWebviewProxySetting(
          host: '127.0.0.1 --disable-web-security',
          port: '7890',
        ),
        throwsFormatException,
      );
      expect(
        () => normalizeManualWebviewProxySetting(
          host: 'proxy.example',
          port: '0',
        ),
        throwsFormatException,
      );
      expect(
        () => normalizeManualWebviewProxySetting(
          host: 'proxy.example',
          port: '65536',
        ),
        throwsFormatException,
      );
      expect(
        () => normalizeManualWebviewProxySetting(
          host: 'proxy.example',
          password: 'secret',
        ),
        throwsFormatException,
      );
    });
  });

  test('other platforms never select an Android or Windows proxy API', () {
    final config = resolveWebviewProxyConfiguration(
      setting: '127.0.0.1:7890',
      platform: WebviewProxyPlatform.other,
    );

    expect(config.androidAction, AndroidWebviewProxyAction.none);
    expect(config.windowsBrowserArguments, isNull);
  });

  test('raw manual setting cannot inject another browser argument', () {
    expect(
      () => resolveWebviewProxyConfiguration(
        setting: '127.0.0.1:7890 --disable-web-security',
        platform: WebviewProxyPlatform.windows,
      ),
      throwsFormatException,
    );
  });

  test('manual host cannot inject a Chromium proxy mapping', () {
    expect(
      () => resolveWebviewProxyConfiguration(
        setting: 'proxy.example;https=attacker.example:8080',
        platform: WebviewProxyPlatform.windows,
      ),
      throwsFormatException,
    );
    expect(
      () => normalizeManualWebviewProxySetting(host: 'proxy_name.example'),
      throwsFormatException,
    );
  });
}
