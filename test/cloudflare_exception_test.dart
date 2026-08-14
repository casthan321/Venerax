import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cloudflare.dart';

void main() {
  test('typed exception preserves Dio context and exposes only a safe URL', () {
    final request = RequestOptions(
      path: 'https://user:secret@example.com/protected?token=private#fragment',
    );
    final response = Response<String>(
      requestOptions: request,
      statusCode: 403,
      data: 'challenge',
    );

    final exception = CloudflareException.fromResponse(response);

    expect(exception.requestOptions, same(request));
    expect(exception.response, same(response));
    expect(exception.navigationUri.query, 'token=private');
    expect(
      exception.toString(),
      'CloudflareException: https://example.com/protected',
    );
    expect(exception.toString(), isNot(contains('secret')));
    expect(exception.toString(), isNot(contains('private')));
  });

  test('legacy string reconstruction accepts safe web URLs only', () {
    expect(
      CloudflareException.fromString(
        'CloudflareException: https://example.com/protected',
      )?.challengeUri,
      Uri.parse('https://example.com/protected'),
    );
    expect(
      CloudflareException.fromString('CloudflareException: file:///secret'),
      isNull,
    );
  });
}
