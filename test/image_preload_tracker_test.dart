import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/image_preload_tracker.dart';

void main() {
  test('coalesces duplicate image downloads', () {
    final tracker = ReaderImagePreloadTracker(10);

    expect(tracker.requestDownload(4), isTrue);
    expect(tracker.requestDownload(4), isFalse);
  });

  test('promotes a downloaded image into the decoded cache once', () {
    final tracker = ReaderImagePreloadTracker(10);

    expect(tracker.requestDownload(4), isTrue);
    expect(tracker.requestPrecache(4), isTrue);
    expect(tracker.requestPrecache(4), isFalse);
    expect(tracker.requestDownload(4), isFalse);
  });

  test('precache also satisfies a later download request', () {
    final tracker = ReaderImagePreloadTracker(10);

    expect(tracker.requestPrecache(4), isTrue);
    expect(tracker.requestDownload(4), isFalse);
  });

  test('rejects pages outside the current chapter', () {
    final tracker = ReaderImagePreloadTracker(10);

    expect(tracker.requestDownload(0), isFalse);
    expect(tracker.requestPrecache(11), isFalse);
  });
}
