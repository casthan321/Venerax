import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/pages/keyed_future_cache.dart';
import 'package:venera/pages/webview_diagnostics.dart';
import 'package:venera/pages/webview_proxy.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';
import 'dart:io' as io;

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

extension WebviewExtension on InAppWebViewController {
  Future<List<io.Cookie>?> getCookies(String url) async {
    if (url.isEmpty) return const [];
    if (url.length > 1 && url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    CookieManager cookieManager = CookieManager.instance(
      webViewEnvironment: AppWebview.webViewEnvironment,
    );
    final cookies = await cookieManager.getCookies(
      url: WebUri(url),
      webViewController: this,
    );
    var res = <io.Cookie>[];
    for (var cookie in cookies) {
      var c = io.Cookie(cookie.name, cookie.value);
      c.domain = cookie.domain;
      res.add(c);
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: "navigator.userAgent");
    if (res is String) {
      if (res.length >= 2 &&
          (res[0] == "'" || res[0] == "\"") &&
          res[res.length - 1] == res[0]) {
        res = res.substring(1, res.length - 1);
      }
    }
    return res is String ? res : null;
  }
}

class AppWebview extends StatefulWidget {
  const AppWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.singlePage = false,
    this.onStarted,
    this.onLoadStop,
    super.key,
  });

  final String initialUrl;

  final void Function(String title, InAppWebViewController controller)?
  onTitleChange;

  final bool Function(String url, InAppWebViewController controller)?
  onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final void Function(InAppWebViewController controller)? onLoadStop;

  final bool singlePage;

  static WebViewEnvironment? webViewEnvironment;

  static final _windowsEnvironmentCache =
      KeyedFutureCache<String?, WebViewEnvironment>((browserArguments) {
        return WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: "${App.dataPath}\\webview",
            additionalBrowserArguments: browserArguments,
          ),
        );
      });

  static Future<WebViewEnvironment> getWindowsEnvironment(
    String? browserArguments,
  ) async {
    final environment = await _windowsEnvironmentCache.getOrCreate(
      browserArguments,
    );
    webViewEnvironment = environment;
    return environment;
  }

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

class _AppWebviewState extends State<AppWebview> {
  InAppWebViewController? controller;

  String title = "Webview";

  double _progress = 0;

  Uri? _currentUri;

  WebviewFailure? _failure;

  late final WebviewProxyConfiguration _proxyConfiguration;

  late final WebviewProxyPlatform _proxyPlatform;

  late Future<WebViewEnvironment?> future;

  @override
  void initState() {
    super.initState();
    _proxyPlatform = App.isWindows
        ? WebviewProxyPlatform.windows
        : App.isAndroid
        ? WebviewProxyPlatform.android
        : WebviewProxyPlatform.other;
    _proxyConfiguration = resolveWebviewProxyConfigurationOrSystem(
      setting: appdata.settings['proxy'],
      platform: _proxyPlatform,
      onInvalid: (error, stackTrace) {
        // Do not include the setting in logs: it may contain a password.
        Log.error(
          'WebView proxy',
          'Invalid proxy setting; using the system proxy: $error',
          stackTrace,
        );
      },
    );
    future = _createWebviewEnvironment();
    _currentUri = Uri.tryParse(widget.initialUrl);
  }

  String get _proxyModeLabel => switch (_proxyConfiguration.mode) {
    WebviewProxyMode.system => 'System',
    WebviewProxyMode.direct => 'Direct',
    WebviewProxyMode.manual => 'Manual',
  };

  Future<void> _reload() async {
    final activeController = controller;
    if (mounted) {
      setState(() {
        _failure = null;
        _progress = 0;
        if (activeController == null) {
          future = _createWebviewEnvironment();
        }
      });
    }
    await activeController?.reload();
  }

  Future<Uri?> _visibleUri() async {
    try {
      final value = await controller?.getUrl();
      return value == null ? _currentUri : Uri.tryParse(value.toString());
    } catch (_) {
      return _currentUri;
    }
  }

  Future<void> _openExternally() async {
    final uri = await _visibleUri();
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    await launchUrlString(uri.toString(), mode: LaunchMode.externalApplication);
  }

  Future<void> _copyVisibleLink() async {
    final uri = await _visibleUri();
    if (uri == null) return;
    await Clipboard.setData(ClipboardData(text: uri.toString()));
  }

  void _setFailure(WebviewFailure failure) {
    if (!mounted) return;
    setState(() {
      _failure = failure;
      _progress = 1;
    });
  }

  Future<WebViewEnvironment?> _createWebviewEnvironment() async {
    if (_proxyConfiguration.androidAction != AndroidWebviewProxyAction.none) {
      final proxyAvailable = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      if (proxyAvailable) {
        final proxyController = ProxyController.instance();
        switch (_proxyConfiguration.androidAction) {
          case AndroidWebviewProxyAction.clear:
            await proxyController.clearProxyOverride();
            break;
          case AndroidWebviewProxyAction.direct:
            await proxyController.setProxyOverride(
              settings: ProxySettings(
                directs: _proxyConfiguration.androidDirects,
              ),
            );
            break;
          case AndroidWebviewProxyAction.manual:
            await proxyController.setProxyOverride(
              settings: ProxySettings(
                proxyRules: [ProxyRule(url: _proxyConfiguration.proxyUrl!)],
              ),
            );
            break;
          case AndroidWebviewProxyAction.none:
            break;
        }
      }
    }
    if (!App.isWindows) {
      return null;
    }
    return AppWebview.getWindowsEnvironment(
      _proxyConfiguration.windowsBrowserArguments,
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = [
      Tooltip(
        message: "More",
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () {
            showMenuX(context, Offset(context.width, context.padding.top), [
              MenuEntry(
                icon: Icons.open_in_browser,
                text: "Open in browser".tl,
                onClick: _openExternally,
              ),
              MenuEntry(
                icon: Icons.copy,
                text: "Copy link".tl,
                onClick: _copyVisibleLink,
              ),
              MenuEntry(
                icon: Icons.refresh,
                text: "Reload".tl,
                onClick: _reload,
              ),
            ]);
          },
        ),
      ),
    ];

    final body = FutureBuilder<WebViewEnvironment?>(
      future: future,
      builder: (context, e) {
        if (e.error != null) {
          return WebviewFailureView(
            failure: WebviewFailure(
              kind: WebviewFailureKind.environment,
              host: safeWebviewHost(_currentUri),
              stage: 'WebView initialization',
              detail: 'The embedded browser environment could not be created.',
            ),
            proxyMode: _proxyModeLabel,
            onRetry: _reload,
            onOpenExternally: _openExternally,
          );
        }
        if (e.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          children: [
            Positioned.fill(child: createWebviewWithEnvironment(e.data)),
            if (_progress > 0 && _progress < 1.0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(value: _progress),
              ),
            if (_failure case final failure?)
              Positioned.fill(
                child: ColoredBox(
                  color: context.colorScheme.surface,
                  child: WebviewFailureView(
                    failure: failure,
                    proxyMode: _proxyModeLabel,
                    onRetry: _reload,
                    onOpenExternally: _openExternally,
                  ),
                ),
              ),
          ],
        );
      },
    );

    return Scaffold(
      appBar: Appbar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: actions,
      ),
      body: body,
    );
  }

  Widget createWebviewWithEnvironment(WebViewEnvironment? e) {
    return InAppWebView(
      webViewEnvironment: e,
      initialSettings: InAppWebViewSettings(isInspectable: kDebugMode),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      onTitleChanged: (c, t) {
        if (mounted) {
          setState(() {
            title = t ?? "Webview";
          });
        }
        widget.onTitleChange?.call(title, controller!);
      },
      shouldOverrideUrlLoading: (c, r) async {
        final nextUrl = r.request.url?.toString() ?? '';
        final nextUri = Uri.tryParse(nextUrl);
        final res = widget.onNavigation?.call(nextUrl, c) ?? false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          if (nextUri != null && mounted) {
            setState(() {
              _currentUri = nextUri;
              _failure = null;
              _progress = 0;
            });
          }
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) {
        controller = c;
        widget.onStarted?.call(c);
      },
      onLoadStart: (c, url) {
        if (!mounted) return;
        setState(() {
          _currentUri = url == null
              ? _currentUri
              : Uri.tryParse(url.toString());
          _failure = null;
          _progress = 0;
        });
      },
      onReceivedHttpAuthRequest:
          (App.isWindows || App.isAndroid) &&
              _proxyConfiguration.credentials != null
          ? (controller, challenge) async {
              final protectionSpace = challenge.protectionSpace;
              if (!_proxyConfiguration.matchesAuthenticationTarget(
                platform: _proxyPlatform,
                host: protectionSpace.host,
                port: protectionSpace.port,
                scheme: protectionSpace.protocol,
              )) {
                return null;
              }
              if (challenge.previousFailureCount > 1) {
                return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
              }
              final credentials = _proxyConfiguration.credentials!;
              return HttpAuthResponse(
                action: HttpAuthResponseAction.PROCEED,
                username: credentials.username,
                password: credentials.password,
                permanentPersistence: false,
              );
            }
          : null,
      onLoadStop: (c, r) {
        if (mounted) {
          setState(() {
            _currentUri = r == null ? _currentUri : Uri.tryParse(r.toString());
            _progress = 1;
          });
        }
        widget.onLoadStop?.call(c);
      },
      onReceivedError: (c, request, error) async {
        final current = await _visibleUri();
        final requestUri = Uri.tryParse(request.url.toString());
        if (requestUri == null ||
            error.type == WebResourceErrorType.CANCELLED ||
            !isMainFrameWebRequest(
              isForMainFrame: request.isForMainFrame,
              requestUri: requestUri,
              currentUri: current,
            )) {
          return;
        }
        _setFailure(
          WebviewFailure(
            kind: WebviewFailureKind.network,
            host: safeWebviewHost(requestUri),
            stage: 'Main document request',
            detail: error.description,
          ),
        );
      },
      onReceivedHttpError: (c, request, response) async {
        final current = await _visibleUri();
        final requestUri = Uri.tryParse(request.url.toString());
        final status = response.statusCode;
        if (requestUri == null ||
            status == null ||
            status < 400 ||
            // The single-page mode is the user-driven challenge view. Its
            // expected 403/429 document must remain visible and interactive.
            (widget.singlePage && (status == 403 || status == 429)) ||
            !isMainFrameWebRequest(
              isForMainFrame: request.isForMainFrame,
              requestUri: requestUri,
              currentUri: current,
            )) {
          return;
        }
        _setFailure(
          WebviewFailure(
            kind: WebviewFailureKind.http,
            host: safeWebviewHost(requestUri),
            stage: 'HTTP response',
            detail: response.reasonPhrase?.trim().isNotEmpty == true
                ? response.reasonPhrase!
                : 'The website returned status $status.',
            statusCode: status,
          ),
        );
      },
      onReceivedServerTrustAuthRequest: (c, challenge) async {
        final protectionSpace = challenge.protectionSpace;
        _setFailure(
          WebviewFailure(
            kind: WebviewFailureKind.tls,
            host: safeWebviewHost(
              Uri(
                scheme: protectionSpace.protocol,
                host: protectionSpace.host,
                port: protectionSpace.port,
              ),
            ),
            stage: 'TLS certificate validation',
            detail:
                'The certificate was not trusted. Venera Community did not bypass this check.',
          ),
        );
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.CANCEL,
        );
      },
      onProgressChanged: (c, p) {
        if (mounted) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );
  }
}

class WebviewFailureView extends StatelessWidget {
  const WebviewFailureView({
    required this.failure,
    required this.proxyMode,
    required this.onRetry,
    required this.onOpenExternally,
    super.key,
  });

  final WebviewFailure failure;
  final String proxyMode;
  final Future<void> Function() onRetry;
  final Future<void> Function() onOpenExternally;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                failure.kind == WebviewFailureKind.tls
                    ? Icons.gpp_maybe_outlined
                    : Icons.cloud_off_outlined,
                size: 48,
                color: context.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                failure.title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(failure.detail, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Host: ${failure.host}'),
                    Text('Stage: ${failure.stage}'),
                    Text('Proxy mode: $proxyMode'),
                    if (failure.statusCode != null)
                      Text('HTTP status: ${failure.statusCode}'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text('Retry'.tl),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenExternally,
                    icon: const Icon(Icons.open_in_browser),
                    label: Text('Open in browser'.tl),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  DesktopWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.onStarted,
    this.onClose,
  });

  Webview? _webview;

  String? _ua;

  String? title;

  String? currentUrl;

  void onMessage(String message) {
    try {
      final json = jsonDecode(message);
      if (json is! Map || json["id"] != "document_created") return;
      final data = json["data"];
      if (data is! Map) return;
      final nextTitle = data["title"];
      final nextUserAgent = data["ua"];
      final nextUrl = data["url"];
      if (nextTitle is! String ||
          nextUserAgent is! String ||
          nextUrl is! String) {
        return;
      }
      title = nextTitle;
      _ua = nextUserAgent;
      currentUrl = nextUrl;
      onTitleChange?.call(nextTitle, this);
    } catch (error, stackTrace) {
      Log.error('Desktop WebView message', error, stackTrace);
    }
  }

  String? get userAgent => _ua;

  Timer? timer;
  bool _isPolling = false;
  bool _closeNotified = false;

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    onClose?.call();
  }

  void _runTimer() {
    timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollDocument());
    });
  }

  Future<void> _pollDocument() async {
    final webview = _webview;
    if (webview == null || _isPolling) return;
    _isPolling = true;
    try {
      const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
      final message = await webview.evaluateJavaScript(js);
      if (message != null && identical(_webview, webview)) {
        onMessage(message);
      }
    } catch (error, stackTrace) {
      if (identical(_webview, webview)) {
        Log.error('Desktop WebView polling', error, stackTrace);
      }
    } finally {
      _isPolling = false;
    }
  }

  Future<void> open() async {
    if (_webview != null) return;
    _closeNotified = false;
    try {
      final webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          useWindowPositionAndSize: true,
          userDataFolderWindows: "${App.dataPath}\\webview",
          title: "Venera Community WebView",
          proxy: (await getNetworkProxy())?.credentialFreeUrl,
        ),
      );
      _webview = webview;
      webview.addOnWebMessageReceivedCallback(onMessage);
      webview.setOnNavigation((value) {
        var url = value;
        try {
          final decoded = jsonDecode(value);
          if (decoded is String) url = decoded;
        } catch (_) {}
        currentUrl = url;
        return onNavigation?.call(url, this);
      });
      currentUrl = initialUrl;
      webview.launch(initialUrl, triggerOnUrlRequestEvent: false);
      _runTimer();
      unawaited(
        webview.onClose.then((_) {
          if (identical(_webview, webview)) {
            _webview = null;
          }
          timer?.cancel();
          timer = null;
          _notifyClosed();
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (identical(_webview, webview)) {
        onStarted?.call(this);
      }
    } catch (error, stackTrace) {
      Log.error('Desktop WebView', error, stackTrace);
      close();
      _notifyClosed();
    }
  }

  Future<String?> evaluateJavascript(String source) async {
    final webview = _webview;
    if (webview == null) return null;
    return webview.evaluateJavaScript(source);
  }

  Future<Map<String, String>> getCookies(String url) async {
    final webview = _webview;
    if (webview == null) return const {};
    var allCookies = await webview.getAllCookies();
    var res = <String, String>{};
    for (var c in allCookies) {
      if (_cookieMatch(url, c.domain)) {
        res[_removeCode0(c.name)] = _removeCode0(c.value);
      }
    }
    return res;
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  bool _cookieMatch(String url, String domain) {
    domain = _removeCode0(domain);
    var host = Uri.parse(url).host;
    var acceptedHost = _getAcceptedDomains(host);
    return acceptedHost.contains(domain.removeAllBlank);
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  void close() {
    final webview = _webview;
    _webview = null;
    timer?.cancel();
    timer = null;
    webview?.close();
  }
}
