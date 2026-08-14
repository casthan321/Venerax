import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/network/cookie_jar.dart';

DynamicLibrary _openWindowsSqlite() {
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return DynamicLibrary.open('$systemRoot\\System32\\winsqlite3.dll');
}

void main() {
  late Directory directory;
  late CookieJarSql jar;

  setUp(() async {
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, _openWindowsSqlite);
    }
    directory = await Directory.systemTemp.createTemp('venera-cookie-test-');
    jar = CookieJarSql('${directory.path}${Platform.pathSeparator}cookies.db');
  });

  tearDown(() async {
    jar.dispose();
    open.reset();
    await directory.delete(recursive: true);
  });

  test('keeps Secure cookies off HTTP requests', () {
    jar.saveFromResponse(Uri.parse('https://example.com/'), [
      Cookie('session', 'secret')
        ..path = '/'
        ..secure = true,
    ]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('http://example.com/')),
      '',
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
      'session=secret',
    );
  });

  test('rejects Secure cookies received over HTTP', () {
    jar.saveFromResponse(Uri.parse('http://example.com/'), [
      Cookie('session', 'secret')
        ..path = '/'
        ..secure = true,
    ]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
      isEmpty,
    );
  });

  test('enforces __Secure- and __Host- prefix requirements', () {
    jar.saveFromResponse(Uri.parse('https://example.com/account'), [
      Cookie('__Secure-missing', 'rejected')..path = '/',
      Cookie('__Secure-valid', 'kept')
        ..path = '/'
        ..secure = true,
      Cookie('__Host-domain', 'rejected')
        ..domain = 'example.com'
        ..path = '/'
        ..secure = true,
      Cookie('__Host-path', 'rejected')
        ..path = '/account'
        ..secure = true,
      Cookie('__Host-valid', 'kept')
        ..path = '/'
        ..secure = true,
    ]);

    final header = jar.loadForRequestCookieHeader(
      Uri.parse('https://example.com/account'),
    );
    expect(header, contains('__Secure-valid=kept'));
    expect(header, contains('__Host-valid=kept'));
    expect(header, isNot(contains('__Secure-missing')));
    expect(header, isNot(contains('__Host-domain')));
    expect(header, isNot(contains('__Host-path')));
  });

  test('shares a valid same-host Domain cookie with subdomains', () {
    jar.saveFromResponse(Uri.parse('https://example.com/'), [
      Cookie('host', 'only')..path = '/',
      Cookie('shared', 'domain')
        ..domain = 'example.com'
        ..path = '/',
    ]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
      allOf(contains('host=only'), contains('shared=domain')),
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://sub.example.com/')),
      'shared=domain',
    );
  });

  test('shares a registrable parent-domain cookie across sibling hosts', () {
    jar.saveFromResponse(Uri.parse('https://sub.example.com/'), [
      Cookie('shared', 'value')
        ..domain = 'example.com'
        ..path = '/',
    ]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
      'shared=value',
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://api.example.com/')),
      'shared=value',
    );
  });

  test('loads every valid parent-domain scope for a deep subdomain', () {
    jar.saveFromResponse(Uri.parse('https://auth.example.co.uk/login'), [
      Cookie('root', 'one')..domain = 'example.co.uk',
    ]);
    jar.saveFromResponse(Uri.parse('https://auth.team.example.co.uk/login'), [
      Cookie('team', 'two')..domain = 'team.example.co.uk',
    ]);

    final cookies = jar.loadForRequest(
      Uri.parse('https://api.auth.team.example.co.uk/reader'),
    );
    expect(
      {for (final cookie in cookies) cookie.name: cookie.value},
      {'team': 'two', 'root': 'one'},
    );
  });

  test('rejects public and private suffix Domain attributes', () {
    jar.saveFromResponse(Uri.parse('https://evil.com/'), [
      Cookie('public', 'rejected')
        ..domain = 'com'
        ..path = '/',
    ]);
    jar.saveFromResponse(Uri.parse('https://attacker.co.uk/'), [
      Cookie('country', 'rejected')
        ..domain = 'co.uk'
        ..path = '/',
    ]);
    jar.saveFromResponse(Uri.parse('https://attacker.github.io/'), [
      Cookie('private', 'rejected')
        ..domain = 'github.io'
        ..path = '/',
    ]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://victim.com/')),
      isEmpty,
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://victim.co.uk/')),
      isEmpty,
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://victim.github.io/')),
      isEmpty,
    );
  });

  test('Max-Age expiry deletes a stored cookie immediately', () {
    final uri = Uri.parse('https://example.com/account/login');
    jar.saveFromResponse(uri, [Cookie('session', 'secret')]);
    expect(
      jar.loadForRequestCookieHeader(
        Uri.parse('https://example.com/account/profile'),
      ),
      'session=secret',
    );

    jar.saveFromResponse(uri, [Cookie('session', '')..maxAge = 0]);
    expect(
      jar.loadForRequestCookieHeader(
        Uri.parse('https://example.com/account/profile'),
      ),
      isEmpty,
    );
  });

  test('missing Path uses the request directory instead of the whole site', () {
    jar.saveFromResponse(Uri.parse('https://example.com/account/login'), [
      Cookie('scoped', 'value'),
    ]);

    expect(
      jar.loadForRequestCookieHeader(
        Uri.parse('https://example.com/account/profile'),
      ),
      'scoped=value',
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/public')),
      isEmpty,
    );
  });

  test('uses RFC path boundaries and prefers the longest matching path', () {
    jar.saveFromResponse(Uri.parse('https://example.com/foo'), [
      Cookie('scope', 'root')..path = '/',
      Cookie('scope', 'nested')..path = '/foo',
    ]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/foo/bar')),
      'scope=nested',
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/foobar')),
      'scope=root',
    );
  });

  test('startup purges legacy domain and invalid host rows', () {
    final databasePath = '${directory.path}${Platform.pathSeparator}cookies.db';
    jar.dispose();
    final database = sqlite3.open(databasePath);
    database.execute(
      '''
      INSERT OR REPLACE INTO cookies
        (name, value, domain, path, expires, secure, httpOnly)
      VALUES (?, ?, ?, ?, NULL, 0, 0);
      ''',
      ['safe', 'kept', 'example.com', '/'],
    );
    for (final entry in <(String, Object?)>[
      ('legacy-parent', '.example.com'),
      ('public-suffix', '.com'),
      ('empty', ''),
      ('whitespace', 'bad host'),
      ('bad-label', '-example.com'),
      ('noncanonical', 'EXAMPLE.COM'),
    ]) {
      database.execute(
        '''
        INSERT OR REPLACE INTO cookies
          (name, value, domain, path, expires, secure, httpOnly)
        VALUES (?, ?, ?, ?, NULL, 0, 0);
        ''',
        [entry.$1, 'removed', entry.$2, '/'],
      );
    }
    database.dispose();

    jar = CookieJarSql(databasePath);

    final inspector = sqlite3.open(databasePath);
    try {
      expect(
        inspector
            .select('SELECT name, domain FROM cookies ORDER BY name;')
            .map((row) => (row['name'], row['domain']))
            .toList(),
        [('safe', 'example.com')],
      );
    } finally {
      inspector.dispose();
    }
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
      'safe=kept',
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://sub.example.com/')),
      isEmpty,
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://victim.com/')),
      isEmpty,
    );
  });

  test('legacy schemas migrate existing rows as host-only cookies', () {
    final databasePath =
        '${directory.path}${Platform.pathSeparator}legacy-cookies.db';
    final database = sqlite3.open(databasePath);
    database.execute('''
      CREATE TABLE cookies (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        domain TEXT NOT NULL,
        path TEXT,
        expires INTEGER,
        secure INTEGER,
        httpOnly INTEGER,
        PRIMARY KEY (name, domain, path)
      );
    ''');
    database.execute('INSERT INTO cookies VALUES (?, ?, ?, ?, NULL, 0, 0);', [
      'legacy',
      'kept',
      'example.com',
      '/',
    ]);
    database.dispose();

    final legacyJar = CookieJarSql(databasePath);
    try {
      expect(
        legacyJar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
        'legacy=kept',
      );
      expect(
        legacyJar.loadForRequestCookieHeader(
          Uri.parse('https://sub.example.com/'),
        ),
        isEmpty,
      );
    } finally {
      legacyJar.dispose();
    }
  });

  test('failed initialization releases the SQLite file handle', () {
    final databasePath =
        '${directory.path}${Platform.pathSeparator}invalid-schema.db';
    final database = sqlite3.open(databasePath);
    database.execute('CREATE VIEW cookies AS SELECT 1 AS value;');
    database.dispose();

    expect(() => CookieJarSql(databasePath), throwsA(anything));

    final renamed = File('$databasePath.renamed');
    File(databasePath).renameSync(renamed.path);
    expect(renamed.existsSync(), isTrue);
  });
}
