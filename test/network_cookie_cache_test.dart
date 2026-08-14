import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/cookie_rules.dart';
import 'package:venera/network/network_log.dart';

void main() {
  group('cookie rules', () {
    test('requires an RFC path boundary', () {
      expect(cookiePathMatches('/foo', '/foo'), isTrue);
      expect(cookiePathMatches('/foo/bar', '/foo'), isTrue);
      expect(cookiePathMatches('/foobar', '/foo'), isFalse);
    });

    test('keeps secure cookies on HTTPS', () {
      expect(
        cookieCanBeSent(
          requestUri: Uri.parse('http://example.com/account'),
          cookieDomain: 'example.com',
          cookiePath: '/',
          secure: true,
        ),
        isFalse,
      );
      expect(
        cookieCanBeSent(
          requestUri: Uri.parse('https://sub.example.com/account'),
          cookieDomain: 'example.com',
          cookiePath: '/',
          secure: true,
        ),
        isFalse,
      );
    });

    test('rejects unrelated cookie domains', () {
      expect(cookieDomainMatches('example.com', 'attacker.example'), isFalse);
      expect(cookieDomainMatches('example.com', 'example.com'), isTrue);
      expect(cookieDomainMatches('sub.example.com', '.example.com'), isFalse);
    });

    test('computes the RFC default cookie path', () {
      expect(defaultCookiePath(''), '/');
      expect(defaultCookiePath('/account'), '/');
      expect(defaultCookiePath('/account/login'), '/account');
      expect(defaultCookiePath('/account/'), '/account');
    });

    test('accepts safe parent domains and rejects public suffixes', () {
      expect(cookieDomainAttributeIsSafe('evil.com', 'com'), isFalse);
      expect(
        cookieDomainAttributeIsSafe('foo.example.com', 'example.com'),
        isTrue,
      );
      expect(
        cookieDomainAttributeIsSafe('example.com', '.example.com'),
        isTrue,
      );
      expect(cookieDomainAttributeIsSafe('attacker.co.uk', 'co.uk'), isFalse);
      expect(
        cookieDomainAttributeIsSafe('attacker.github.io', 'github.io'),
        isFalse,
      );
    });

    test('accepts only canonical host-only database domains', () {
      expect(canonicalHostOnlyCookieDomain('example.com'), 'example.com');
      expect(canonicalHostOnlyCookieDomain('EXAMPLE.COM'), 'example.com');
      expect(canonicalHostOnlyCookieDomain('127.0.0.1'), '127.0.0.1');
      expect(canonicalHostOnlyCookieDomain('::1'), '::1');
      expect(canonicalHostOnlyCookieDomain('.example.com'), isNull);
      expect(canonicalHostOnlyCookieDomain(''), isNull);
      expect(canonicalHostOnlyCookieDomain('bad host'), isNull);
      expect(canonicalHostOnlyCookieDomain('-example.com'), isNull);
    });
  });

  test('network cache evicts before exceeding its size budget', () {
    final cache = NetworkCacheManager()..clear();
    NetworkCache entry(String path, int bytes) => NetworkCache(
      uri: Uri.parse('https://example.com/$path'),
      requestHeaders: const {},
      responseHeaders: const {},
      data: 'x',
      time: DateTime.now(),
      size: bytes,
    );

    cache.setCache(entry('first', 6 * 1024 * 1024));
    cache.setCache(entry('second', 6 * 1024 * 1024));

    expect(cache.getCache(Uri.parse('https://example.com/first')), isNull);
    expect(cache.getCache(Uri.parse('https://example.com/second')), isNotNull);
    expect(cache.size, lessThanOrEqualTo(10 * 1024 * 1024));
  });

  test('network cache accepts only complete 200 responses', () {
    final cache = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/resource');

    void receive(int statusCode) {
      cache.onResponse(
        Response<String>(
          requestOptions: RequestOptions(path: uri.toString(), method: 'GET'),
          data: 'response',
          statusCode: statusCode,
        ),
        ResponseInterceptorHandler(),
      );
    }

    receive(201);
    expect(cache.getCache(uri), isNull);
    receive(206);
    expect(cache.getCache(uri), isNull);
    receive(200);
    expect(cache.getCache(uri), isNotNull);
  });

  test('network cache separates decoded and byte response types', () {
    final cache = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/typed');
    cache.setCache(
      NetworkCache(
        uri: uri,
        requestHeaders: const {},
        responseHeaders: const {},
        data: <int>[1, 2, 3],
        time: DateTime.now(),
        size: 3,
        responseType: ResponseType.bytes,
      ),
    );

    expect(cache.getCache(uri), isNull);
    expect(cache.getCache(uri, responseType: ResponseType.bytes)?.data, <int>[
      1,
      2,
      3,
    ]);
  });

  test('network cache does not store User-Agent variants', () {
    final cache = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/vary-user-agent');
    cache.onResponse(
      Response<String>(
        requestOptions: RequestOptions(path: uri.toString(), method: 'GET'),
        data: 'variant',
        statusCode: 200,
        headers: Headers.fromMap(const {
          'vary': <String>['User-Agent'],
        }),
      ),
      ResponseInterceptorHandler(),
    );

    expect(cache.getCache(uri), isNull);
  });

  test('network cache isolates nested data and headers from mutation', () {
    final cache = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/immutable');
    final requestValues = <String>['one'];
    final requestSet = <String>{'alpha'};
    final responseValues = <String>['application/json'];
    final items = <dynamic>[
      <String, dynamic>{'id': 1},
    ];
    final data = <String, dynamic>{'items': items};

    cache.setCache(
      NetworkCache(
        uri: uri,
        requestHeaders: {'X-Values': requestValues, 'X-Set': requestSet},
        responseHeaders: {'content-type': responseValues},
        data: data,
        time: DateTime.now(),
        size: 64,
      ),
    );

    requestValues[0] = 'changed';
    requestSet.add('beta');
    responseValues[0] = 'text/plain';
    (items.single as Map<String, dynamic>)['id'] = 2;

    final first = cache.getCache(uri)!;
    expect(first.requestHeaders['X-Values'], ['one']);
    expect(first.requestHeaders['X-Set'], {'alpha'});
    expect(first.responseHeaders['content-type'], ['application/json']);
    expect(((first.data as Map<String, dynamic>)['items'] as List).single, {
      'id': 1,
    });

    (first.requestHeaders['X-Values'] as List)[0] = 'mutated again';
    (first.requestHeaders['X-Set'] as Set).add('mutated again');
    first.responseHeaders['content-type']![0] = 'application/xml';
    (((first.data as Map<String, dynamic>)['items'] as List).single
            as Map)['id'] =
        3;

    final second = cache.getCache(uri)!;
    expect(second.requestHeaders['X-Values'], ['one']);
    expect(second.requestHeaders['X-Set'], {'alpha'});
    expect(second.responseHeaders['content-type'], ['application/json']);
    expect(((second.data as Map<String, dynamic>)['items'] as List).single, {
      'id': 1,
    });
  });

  test('authenticated requests are never shared through the memory cache', () {
    expect(isPrivateNetworkRequest({'Authorization': 'Bearer secret'}), isTrue);
    expect(isPrivateNetworkRequest({'COOKIE': 'session=secret'}), isTrue);
    expect(isPrivateNetworkRequest({'X-Access-Token': 'secret'}), isTrue);
    expect(isPrivateNetworkRequest({'Accept': 'application/json'}), isFalse);
  });

  test('sensitive URL query parameters are private cache keys', () {
    expect(
      networkUriContainsSecrets(
        Uri.parse('https://example.com/profile?accessToken=secret'),
      ),
      isTrue,
    );
    expect(
      networkUriContainsSecrets(Uri.parse('https://example.com/list?page=2')),
      isFalse,
    );
  });

  test('cache header comparison is case insensitive and non-mutating', () {
    final first = <String, dynamic>{
      'Content-Type': 'application/json',
      'X-Values': <String>['one', 'two'],
      'Authorization': 'secret-a',
    };
    final second = <String, dynamic>{
      'content-type': 'application/json',
      'x-values': <String>['one', 'two'],
      'authorization': 'secret-b',
    };

    expect(NetworkCacheManager.compareHeaders(first, second), isTrue);
    expect(first, contains('Content-Type'));
    expect(second, contains('content-type'));
  });
}
