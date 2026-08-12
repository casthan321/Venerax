part of 'settings_page.dart';

class NetworkSettings extends StatefulWidget {
  const NetworkSettings({super.key});

  @override
  State<NetworkSettings> createState() => _NetworkSettingsState();
}

class _NetworkSettingsState extends State<NetworkSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Network".tl)),
        _PopupWindowSetting(
          title: "Proxy".tl,
          builder: () => const _ProxySettingView(),
        ).toSliver(),
        _PopupWindowSetting(
          title: "DNS Overrides".tl,
          builder: () => const _DNSOverrides(),
        ).toSliver(),
        _SliderSetting(
          title: "Download Threads".tl,
          settingsIndex: 'downloadThreads',
          interval: 1,
          min: 1,
          max: 16,
        ).toSliver(),
      ],
    );
  }
}

class _ProxySettingView extends StatefulWidget {
  const _ProxySettingView();

  @override
  State<_ProxySettingView> createState() => _ProxySettingViewState();
}

class _ProxySettingViewState extends State<_ProxySettingView> {
  String type = '';
  String host = '';
  String port = '';
  String username = '';
  String password = '';
  String scheme = 'http';
  String? manualProxyError;

  String _formatProxyError(Object error) {
    if (error is FormatException) {
      return error.message.toString();
    }
    return 'Invalid manual proxy';
  }

  // Percent-encoded USERNAME:PASSWORD@HOST:PORT.
  String toProxyStr() {
    if (type == 'direct') {
      return 'direct';
    } else if (type == 'system') {
      return 'system';
    }
    return normalizeManualWebviewProxySetting(
      scheme: scheme,
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }

  void parseProxyString(Object? proxy) {
    final config = resolveWebviewProxyConfigurationOrSystem(
      setting: proxy,
      platform: WebviewProxyPlatform.other,
      onInvalid: (error, stackTrace) {
        // Never log [proxy], because the legacy setting may include a password.
        Log.error(
          'Proxy settings',
          'Invalid saved proxy setting; showing system proxy: $error',
          stackTrace,
        );
      },
    );
    switch (config.mode) {
      case WebviewProxyMode.direct:
        type = 'direct';
        return;
      case WebviewProxyMode.system:
        type = 'system';
        return;
      case WebviewProxyMode.manual:
        type = 'manual';
        scheme = config.proxyScheme ?? 'http';
        host = config.proxyHost ?? '';
        port = config.hasExplicitPort ? config.proxyPort!.toString() : '';
        username = config.credentials?.username ?? '';
        password = config.credentials?.password ?? '';
    }
  }

  @override
  void initState() {
    var proxy = appdata.settings['proxy'];
    parseProxyString(proxy);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Proxy".tl,
      body: SingleChildScrollView(
        child: RadioGroup<String>(
          groupValue: type,
          onChanged: (v) {
            setState(() {
              type = v ?? type;
              manualProxyError = null;
            });
            if (type != 'manual') {
              appdata.settings['proxy'] = toProxyStr();
              appdata.saveData();
            }
          },
          child: Column(
            children: [
              RadioListTile<String>(title: Text("Direct".tl), value: 'direct'),
              RadioListTile<String>(title: Text("System".tl), value: 'system'),
              RadioListTile(title: Text("Manual".tl), value: 'manual'),
              if (type == 'manual') buildManualProxy(),
            ],
          ),
        ),
      ),
    );
  }

  var formKey = GlobalKey<FormState>();

  Widget buildManualProxy() {
    return Form(
      key: formKey,
      child: Column(
        children: [
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Host".tl,
            ),
            controller: TextEditingController(text: host),
            onChanged: (v) {
              host = v;
            },
            validator: (v) {
              if (v?.trim().isEmpty ?? true) {
                return "Host cannot be empty".tl;
              }
              try {
                normalizeManualWebviewProxySetting(host: v!);
              } catch (error) {
                return _formatProxyError(error).tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Port".tl,
            ),
            controller: TextEditingController(text: port),
            onChanged: (v) {
              port = v;
            },
            validator: (v) {
              if (v?.isEmpty ?? true) {
                return null;
              }
              final parsedPort = int.tryParse(v!);
              if (parsedPort == null) {
                return "Port must be a number".tl;
              }
              if (parsedPort < 1 || parsedPort > 65535) {
                return "Proxy port must be between 1 and 65535".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Username".tl,
            ),
            controller: TextEditingController(text: username),
            onChanged: (v) {
              username = v;
            },
            validator: (v) {
              if ((v?.isEmpty ?? false) && password.isNotEmpty) {
                return "Username cannot be empty".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Password".tl,
            ),
            controller: TextEditingController(text: password),
            onChanged: (v) {
              password = v;
            },
          ),
          if (manualProxyError != null) ...[
            const SizedBox(height: 8),
            Text(
              manualProxyError!.tl,
              style: TextStyle(color: context.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                try {
                  final normalizedSetting = toProxyStr();
                  appdata.settings['proxy'] = normalizedSetting;
                  appdata.saveData();
                  App.rootContext.pop();
                } catch (error) {
                  setState(() {
                    manualProxyError = _formatProxyError(error);
                  });
                }
              }
            },
            child: Text("Save".tl),
          ),
        ],
      ),
    ).paddingHorizontal(16).paddingTop(16);
  }
}

class _DNSOverrides extends StatefulWidget {
  const _DNSOverrides();

  @override
  State<_DNSOverrides> createState() => __DNSOverridesState();
}

class __DNSOverridesState extends State<_DNSOverrides> {
  var overrides = <(TextEditingController, TextEditingController)>[];

  @override
  void initState() {
    for (var entry in (appdata.settings['dnsOverrides'] as Map).entries) {
      if (entry.key is String && entry.value is String) {
        overrides.add((
          TextEditingController(text: entry.key),
          TextEditingController(text: entry.value),
        ));
      }
    }
    super.initState();
  }

  @override
  void dispose() {
    var map = <String, String>{};
    for (var entry in overrides) {
      map[entry.$1.text] = entry.$2.text;
    }
    appdata.settings['dnsOverrides'] = map;
    appdata.saveData();
    JsEngine().resetDio();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "DNS Overrides".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            _SwitchSetting(
              title: "Enable DNS Overrides".tl,
              settingKey: "enableDnsOverrides",
            ),
            _SwitchSetting(title: "Server Name Indication", settingKey: "sni"),
            const SizedBox(height: 8),
            Container(
              height: 1,
              margin: EdgeInsets.symmetric(horizontal: 8),
              color: context.colorScheme.outlineVariant,
            ),
            for (var i = 0; i < overrides.length; i++) buildOverride(i),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  overrides.add((
                    TextEditingController(),
                    TextEditingController(),
                  ));
                });
              },
              icon: const Icon(Icons.add),
              label: Text("Add".tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildOverride(int index) {
    var entry = overrides[index];
    return Container(
      key: ValueKey(index),
      height: 48,
      margin: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.colorScheme.outlineVariant),
          left: BorderSide(color: context.colorScheme.outlineVariant),
          right: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "Domain".tl,
              ),
              controller: entry.$1,
            ).paddingHorizontal(8),
          ),
          Container(width: 1, color: context.colorScheme.outlineVariant),
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "IP".tl,
              ),
              controller: entry.$2,
            ).paddingHorizontal(8),
          ),
          Container(width: 1, color: context.colorScheme.outlineVariant),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              setState(() {
                overrides.removeAt(index);
              });
            },
          ),
        ],
      ),
    );
  }
}
