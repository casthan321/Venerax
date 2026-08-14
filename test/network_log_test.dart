import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/network_log.dart';

void main() {
  test('redacts sensitive headers without mutating the input', () {
    final original = <String, dynamic>{
      'Authorization': 'Bearer secret',
      'SET-COOKIE': ['session=secret'],
      'Accept': 'application/json',
    };
    final redacted = redactNetworkHeaders(original);

    expect(redacted['Authorization'], '********');
    expect(redacted['SET-COOKIE'], '********');
    expect(redacted['Accept'], 'application/json');
    expect(original['Authorization'], 'Bearer secret');
  });

  test('internal headers are consumed case insensitively', () {
    final headers = <String, dynamic>{
      'HTTP_CLIENT': 'dart:io',
      'Accept': 'application/json',
    };

    expect(headerValueCaseInsensitive(headers, 'http_client'), 'dart:io');
    expect(removeHeaderCaseInsensitive(headers, 'http_client'), 'dart:io');
    expect(headers, {'Accept': 'application/json'});
  });

  test('removes user info and sensitive query values from URLs', () {
    final safe = safeNetworkUri(
      Uri.parse(
        'https://user:pass@example.com/image?token=abc&width=300#secret',
      ),
    );
    expect(safe, contains('width=300'));
    expect(safe, isNot(contains('user')));
    expect(safe, isNot(contains('pass')));
    expect(safe, isNot(contains('abc')));
    expect(safe, isNot(contains('#secret')));
    expect(safe, isNot(endsWith('#')));
  });

  test('does not append an empty fragment to fragment-free URLs', () {
    expect(
      safeNetworkUri(Uri.parse('https://example.com/image')),
      'https://example.com/image',
    );
  });

  test('recognizes camelCase and signed-request secret names', () {
    for (final name in [
      'accessToken',
      'refreshToken',
      'clientSecret',
      'session_id',
      'X-Amz-Credential',
      'X-Amz-Signature',
    ]) {
      expect(isSensitiveNetworkName(name), isTrue, reason: name);
    }
    expect(isSensitiveNetworkName('width'), isFalse);
  });

  test('summarizes bytes and redacts structured payload secrets', () {
    expect(summarizeNetworkPayload(Uint8List(1024)), '<bytes length=1024>');
    final summary = summarizeNetworkPayload({
      'username': 'reader',
      'password': 'plain-text-secret',
    });
    expect(summary, contains('reader'));
    expect(summary, isNot(contains('plain-text-secret')));
  });

  test('release metadata summaries never serialize payload contents', () {
    expect(summarizeNetworkPayloadMetadata('top-secret'), '<text length=10>');
    expect(
      summarizeNetworkPayloadMetadata({'token': 'top-secret'}),
      '<map entries=1>',
    );
  });
}
