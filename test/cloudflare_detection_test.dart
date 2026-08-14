import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cloudflare_detection.dart';

void main() {
  group('isCloudflareChallengeResponse', () {
    test('accepts the official cf-mitigated signal case-insensitively', () {
      expect(
        isCloudflareChallengeResponse(
          statusCode: 503,
          headers: const {
            'CF-Mitigated': ['Challenge'],
          },
        ),
        isTrue,
      );
    });

    test('does not classify an ordinary forbidden response as a challenge', () {
      expect(
        isCloudflareChallengeResponse(
          statusCode: 403,
          headers: const {
            'server': ['cloudflare'],
          },
          body: '<html><title>Forbidden</title></html>',
        ),
        isFalse,
      );
    });

    test('accepts a conservative header and body fallback', () {
      expect(
        isCloudflareChallengeResponse(
          statusCode: 403,
          headers: const {
            'cf-ray': ['example'],
          },
          body: '<script src="/cdn-cgi/challenge-platform/x.js"></script>',
        ),
        isTrue,
      );
    });

    test('requires a challenge status for body markers', () {
      expect(
        isCloudflareChallengeResponse(
          statusCode: 200,
          headers: const {},
          body:
              '<form id="challenge-form"></form><script>window._cf_chl_opt={}</script>',
        ),
        isFalse,
      );
    });
  });

  group('safeChallengeUri', () {
    test('removes credentials, query and fragment', () {
      final safe = safeChallengeUri(
        Uri.parse('https://user:secret@example.com:8443/path?q=token#secret'),
      );
      expect(safe.toString(), 'https://example.com:8443/path');
    });

    test('rejects non-web URLs', () {
      expect(
        () => safeChallengeUri(Uri.parse('file:///secret')),
        throwsFormatException,
      );
    });
  });

  test(
    'challengeNavigationUri retains query only for in-process navigation',
    () {
      final uri = challengeNavigationUri(
        Uri.parse('https://user:secret@example.com/path?state=abc#private'),
      );
      expect(uri.toString(), 'https://example.com/path?state=abc');
      expect(safeChallengeUri(uri).toString(), 'https://example.com/path');
    },
  );

  group('haveSameWebOrigin', () {
    test('normalizes default ports', () {
      expect(
        haveSameWebOrigin(
          Uri.parse('https://example.com/a'),
          Uri.parse('https://EXAMPLE.com:443/b'),
        ),
        isTrue,
      );
    });

    test('rejects scheme, port and subdomain changes', () {
      final origin = Uri.parse('https://example.com/');
      expect(
        haveSameWebOrigin(origin, Uri.parse('http://example.com/')),
        false,
      );
      expect(
        haveSameWebOrigin(origin, Uri.parse('https://example.com:444/')),
        false,
      );
      expect(
        haveSameWebOrigin(origin, Uri.parse('https://www.example.com/')),
        false,
      );
    });
  });
}
