import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/log.dart';

import 'cookie_rules.dart';
import 'network_log.dart';

class CookieJarSql {
  late Database _db;

  final String path;

  DateTime? _lastExpiryCleanup;

  CookieJarSql(this.path) {
    init();
  }

  void init() {
    final database = sqlite3.open(path);
    _db = database;
    try {
      _db.execute('''
      CREATE TABLE IF NOT EXISTS cookies (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        domain TEXT NOT NULL,
        path TEXT,
        expires INTEGER,
        secure INTEGER,
        httpOnly INTEGER,
        hostOnly INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (name, domain, path)
      );
    ''');
      final columns = _db
          .select('PRAGMA table_info(cookies);')
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();
      if (!columns.contains('hostOnly')) {
        _db.execute(
          'ALTER TABLE cookies '
          'ADD COLUMN hostOnly INTEGER NOT NULL DEFAULT 1;',
        );
      }
      _db.execute('''
      CREATE INDEX IF NOT EXISTS cookies_domain_idx ON cookies(domain);
    ''');
      _purgeUnsafeStoredDomains();
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  void _purgeUnsafeStoredDomains() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final rows = _db.select('SELECT rowid, domain, hostOnly FROM cookies;');
      for (final row in rows) {
        final storedDomain = row['domain'];
        final canonical = canonicalHostOnlyCookieDomain(storedDomain);
        final hostOnly = row['hostOnly'] == 1;
        if (canonical == null ||
            canonical != storedDomain ||
            (!hostOnly && !isRegistrableCookieDomain(canonical))) {
          _db.execute('DELETE FROM cookies WHERE rowid = ?;', [row['rowid']]);
        }
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    if (cookies.isEmpty) return;
    final now = DateTime.now();
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (final cookie in cookies) {
        final responseHost = canonicalHostOnlyCookieDomain(uri.host);
        if (responseHost == null) {
          Log.warning('Network', 'Ignored a cookie for an invalid host');
          continue;
        }
        if (!cookieCanBeStored(
          responseUri: uri,
          name: cookie.name,
          secure: cookie.secure,
          domain: cookie.domain,
          path: cookie.path,
        )) {
          Log.warning(
            'Network',
            'Ignored a cookie that violates secure cookie requirements',
          );
          continue;
        }
        final requestedDomain = cookie.domain;
        if (requestedDomain != null &&
            !cookieDomainAttributeIsSafe(uri.host, requestedDomain)) {
          Log.warning(
            'Network',
            'Ignored an unsafe cross-host cookie Domain attribute',
          );
          continue;
        }
        final domain = requestedDomain == null
            ? responseHost
            : canonicalCookieDomainAttribute(requestedDomain)!;
        final hostOnly = requestedDomain == null;
        final path =
            cookie.path == null ||
                cookie.path!.isEmpty ||
                !cookie.path!.startsWith('/')
            ? defaultCookiePath(uri.path)
            : cookie.path!;
        final maxAge = cookie.maxAge;
        if (maxAge != null && maxAge <= 0) {
          _db.execute(
            'DELETE FROM cookies WHERE name = ? AND domain = ? AND path = ?;',
            [cookie.name, domain, path],
          );
          continue;
        }
        final expires = maxAge == null
            ? cookie.expires
            : now.add(Duration(seconds: maxAge));
        if (expires != null && !expires.isAfter(now)) {
          _db.execute(
            'DELETE FROM cookies WHERE name = ? AND domain = ? AND path = ?;',
            [cookie.name, domain, path],
          );
          continue;
        }
        _db.execute(
          '''
          INSERT OR REPLACE INTO cookies
            (name, value, domain, path, expires, secure, httpOnly, hostOnly)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          [
            cookie.name,
            cookie.value,
            domain,
            path,
            expires?.millisecondsSinceEpoch,
            cookie.secure ? 1 : 0,
            cookie.httpOnly ? 1 : 0,
            hostOnly ? 1 : 0,
          ],
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  List<_StoredCookie> _loadForHost(String host) {
    final domains = _candidateCookieDomains(host);
    final placeholders = List.filled(domains.length, '?').join(', ');
    final rows = _db.select('''
      SELECT name, value, domain, path, expires, secure, httpOnly, hostOnly
      FROM cookies
      WHERE domain IN ($placeholders)
      ORDER BY length(path) DESC, hostOnly DESC, length(domain) DESC;
    ''', domains);

    return rows
        .map(
          (row) => _StoredCookie(
            Cookie(row['name'] as String, row['value'] as String)
              ..domain = row['domain'] as String
              ..path = row['path'] as String
              ..expires = row['expires'] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(row['expires'] as int)
              ..secure = row['secure'] == 1
              ..httpOnly = row['httpOnly'] == 1,
            hostOnly: row['hostOnly'] == 1,
          ),
        )
        .toList();
  }

  List<String> _candidateCookieDomains(String host) {
    final candidates = <String>[host];
    if (host.contains(':') || RegExp(r'^\d+(?:\.\d+){3}$').hasMatch(host)) {
      return candidates;
    }
    final labels = host.split('.');
    for (var index = 1; index < labels.length; index++) {
      final candidate = labels.sublist(index).join('.');
      if (!isRegistrableCookieDomain(candidate)) continue;
      candidates.add(candidate);
    }
    return candidates;
  }

  List<_StoredCookie> _loadMatching(Uri uri) {
    final host = canonicalHostOnlyCookieDomain(uri.host);
    if (host == null) return const [];

    final now = DateTime.now();
    if (_lastExpiryCleanup == null ||
        now.difference(_lastExpiryCleanup!) >= const Duration(minutes: 1)) {
      _db.execute(
        'DELETE FROM cookies WHERE expires IS NOT NULL AND expires < ?;',
        [now.millisecondsSinceEpoch],
      );
      _lastExpiryCleanup = now;
    }
    return _loadForHost(host)
        .where(
          (stored) =>
              (stored.cookie.expires == null ||
                  !stored.cookie.expires!.isBefore(now)) &&
              cookieCanBeSent(
                requestUri: uri,
                cookieDomain: stored.cookie.domain,
                cookiePath: stored.cookie.path,
                secure: stored.cookie.secure,
                hostOnly: stored.hostOnly,
              ),
        )
        .toList(growable: false);
  }

  List<Cookie> loadForRequest(Uri uri) {
    return _loadMatching(
      uri,
    ).map((stored) => stored.cookie).toList(growable: false);
  }

  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeader) {
    var cookies = <Cookie>[];
    for (var header in cookieHeader) {
      try {
        var cookie = Cookie.fromSetCookieValue(header);
        cookies.add(cookie);
      } catch (_) {
        Log.warning('Network', 'Ignored an invalid Set-Cookie header');
        continue;
      }
    }
    saveFromResponse(uri, cookies);
  }

  String loadForRequestCookieHeader(Uri uri) {
    final map = <String, Cookie>{};
    for (final stored in _loadMatching(uri)) {
      map.putIfAbsent(stored.cookie.name, () => stored.cookie);
    }
    return map.entries
        .map((cookie) => '${cookie.value.name}=${cookie.value.value}')
        .join('; ');
  }

  void delete(Uri uri, String name) {
    for (final stored in _loadMatching(uri)) {
      if (stored.cookie.name != name) continue;
      _db.execute(
        'DELETE FROM cookies WHERE name = ? AND domain = ? AND path = ?;',
        [name, stored.cookie.domain, stored.cookie.path],
      );
    }
  }

  void deleteUri(Uri uri) {
    for (final stored in _loadMatching(uri)) {
      _db.execute(
        'DELETE FROM cookies WHERE name = ? AND domain = ? AND path = ?;',
        [stored.cookie.name, stored.cookie.domain, stored.cookie.path],
      );
    }
  }

  void deleteAll() {
    _db.execute('''
      DELETE FROM cookies;
    ''');
  }

  void dispose() {
    _db.dispose();
  }
}

class _StoredCookie {
  const _StoredCookie(this.cookie, {required this.hostOnly});

  final Cookie cookie;
  final bool hostOnly;
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;

  static Future<SingleInstanceCookieJar> createInstance() async {
    if (instance != null) {
      return instance!;
    }
    var dataPath = (await getApplicationSupportDirectory()).path;
    instance = SingleInstanceCookieJar("$dataPath/cookie.db");
    return instance!;
  }
}

class CookieManagerSql extends Interceptor {
  final CookieJarSql cookieJar;

  CookieManagerSql(this.cookieJar);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    var cookies = cookieJar.loadForRequestCookieHeader(options.uri);
    if (cookies.isNotEmpty) {
      final existing = removeHeaderCaseInsensitive(options.headers, 'cookie');
      if (existing != null && existing.toString().trim().isNotEmpty) {
        cookies = "$existing; $cookies";
      }
      options.headers["cookie"] = cookies;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    cookieJar.saveFromResponseCookieHeader(
      response.requestOptions.uri,
      response.headers["set-cookie"] ?? [],
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final response = err.response;
    if (response != null) {
      cookieJar.saveFromResponseCookieHeader(
        response.requestOptions.uri,
        response.headers['set-cookie'] ?? const [],
      );
    }
    handler.next(err);
  }
}
