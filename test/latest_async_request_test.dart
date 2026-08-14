import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/latest_async_request.dart';

void main() {
  test('only the latest started request remains current', () {
    final requests = LatestAsyncRequest();

    final first = requests.start();
    expect(requests.isCurrent(first), isTrue);

    final second = requests.start();
    expect(requests.isCurrent(first), isFalse);
    expect(requests.isCurrent(second), isTrue);
  });

  test('invalidate makes an in-flight request stale', () {
    final requests = LatestAsyncRequest();
    final token = requests.start();

    requests.invalidate();

    expect(requests.isCurrent(token), isFalse);
  });
}
