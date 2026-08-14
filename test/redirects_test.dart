import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/redirects.dart';

void main() {
  test('resolves only HTTP redirect targets', () {
    final current = Uri.parse('https://example.test/a/page');
    expect(
      resolveRedirectLocation(
        currentUri: current,
        statusCode: 302,
        location: '../login',
      ),
      Uri.parse('https://example.test/login'),
    );
    expect(
      resolveRedirectLocation(
        currentUri: current,
        statusCode: 302,
        location: 'file:///secret',
      ),
      isNull,
    );
  });

  test('cross-origin redirect strips credentials and host', () {
    final headers = redirectHeaders(
      {
        'Authorization': 'Bearer secret',
        'Cookie': 'sid=secret',
        'X-Api-Key': 'api-secret',
        'X-Token': 'source-secret',
        'X-Session-Id': 'session-secret',
        'Host': 'one.test',
        'Accept': 'application/json',
      },
      changesOrigin: true,
      preservesBody: true,
    );

    expect(headers, {'Accept': 'application/json'});
  });

  test('303 converts POST to GET and removes entity headers', () {
    final previous = RequestOptions(
      path: 'https://one.test/submit',
      method: 'POST',
      data: 'body',
      headers: {
        'Content-Type': 'text/plain',
        'Content-Length': '4',
        'Authorization': 'same-origin',
      },
    );

    final redirected = redirectedRequestOptions(
      previous: previous,
      nextUri: Uri.parse('https://one.test/result'),
      statusCode: 303,
      redirectsRemaining: 2,
    );

    expect(redirected.method, 'GET');
    expect(redirected.data, isNull);
    expect(redirected.headers, {'Authorization': 'same-origin'});
    expect(redirected.maxRedirects, 2);
    expect(redirected.followRedirects, isTrue);
  });

  test('reopens a replayable upload body for every redirect hop', () async {
    var opened = 0;
    final previous = RequestOptions(
      path: 'https://one.test/upload',
      method: 'PUT',
      data: ReplayableByteStream(() {
        opened++;
        return Stream.value(<int>[1, 2, 3]);
      }),
    );

    final first = redirectedRequestOptions(
      previous: previous,
      nextUri: Uri.parse('https://one.test/upload-2'),
      statusCode: 307,
      redirectsRemaining: 2,
    );
    final second = redirectedRequestOptions(
      previous: first,
      nextUri: Uri.parse('https://one.test/upload-3'),
      statusCode: 308,
      redirectsRemaining: 1,
    );

    expect(await (first.data as Stream<List<int>>).single, [1, 2, 3]);
    expect(await (second.data as Stream<List<int>>).single, [1, 2, 3]);
    expect(opened, 2);
  });

  test('refuses to replay an ordinary single-subscription stream', () {
    final previous = RequestOptions(
      path: 'https://one.test/upload',
      method: 'PUT',
      data: Stream.value(<int>[1, 2, 3]),
    );

    expect(
      () => redirectedRequestOptions(
        previous: previous,
        nextUri: Uri.parse('https://one.test/upload-2'),
        statusCode: 307,
        redirectsRemaining: 2,
      ),
      throwsStateError,
    );
  });

  test('clones multipart form data before preserving a redirect body', () {
    final form = FormData.fromMap({'name': 'reader'});
    final previous = RequestOptions(
      path: 'https://one.test/upload',
      method: 'POST',
      data: form,
    );

    final redirected = redirectedRequestOptions(
      previous: previous,
      nextUri: Uri.parse('https://one.test/upload-2'),
      statusCode: 307,
      redirectsRemaining: 2,
    );

    expect(redirected.data, isA<FormData>());
    expect(identical(redirected.data, form), isFalse);
  });
}
