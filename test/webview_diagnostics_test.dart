import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webview_diagnostics.dart';

void main() {
  group('isMainFrameWebRequest', () {
    test('uses the platform main-frame signal when available', () {
      expect(
        isMainFrameWebRequest(
          isForMainFrame: true,
          requestUri: Uri.parse('https://example.com/image.png'),
          currentUri: Uri.parse('https://example.com/page'),
        ),
        isTrue,
      );
      expect(
        isMainFrameWebRequest(
          isForMainFrame: false,
          requestUri: Uri.parse('https://example.com/page'),
          currentUri: Uri.parse('https://example.com/page'),
        ),
        isFalse,
      );
    });

    test('ignores fragment differences in the fallback', () {
      expect(
        isMainFrameWebRequest(
          isForMainFrame: null,
          requestUri: Uri.parse('https://example.com/page#two'),
          currentUri: Uri.parse('https://example.com/page#one'),
        ),
        isTrue,
      );
    });

    test('does not turn unknown subresource failures into page failures', () {
      expect(
        isMainFrameWebRequest(
          isForMainFrame: null,
          requestUri: Uri.parse('https://cdn.example.com/image.png'),
          currentUri: Uri.parse('https://example.com/page'),
        ),
        isFalse,
      );
    });
  });

  test('safeWebviewHost excludes path, query and default ports', () {
    expect(
      safeWebviewHost(Uri.parse('https://user:pass@example.com:443/a?q=x')),
      'example.com',
    );
    expect(
      safeWebviewHost(Uri.parse('https://example.com:8443/a')),
      'example.com:8443',
    );
  });
}
