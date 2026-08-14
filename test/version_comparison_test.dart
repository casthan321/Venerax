import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/version_comparison.dart';

void main() {
  test('compares stable semantic versions', () {
    expect(isVersionNewer('1.7.0', '1.6.5'), isTrue);
    expect(isVersionNewer('1.6.5', '1.6.5'), isFalse);
    expect(isVersionNewer('1.6.4', '1.6.5'), isFalse);
  });

  test('orders prereleases below their stable release', () {
    expect(isVersionNewer('1.7.0-beta.2', '1.7.0-beta.1'), isTrue);
    expect(isVersionNewer('1.7.0', '1.7.0-beta.2'), isTrue);
    expect(isVersionNewer('1.7.0-beta.1', '1.7.0'), isFalse);
  });

  test('implements numeric and lexical prerelease ordering', () {
    expect(isVersionNewer('1.7.0-beta.10', '1.7.0-beta.2'), isTrue);
    expect(isVersionNewer('1.7.0-rc.1', '1.7.0-beta.99'), isTrue);
    expect(isVersionNewer('1.7.0-beta.1.1', '1.7.0-beta.1'), isTrue);
  });

  test('ignores build metadata and rejects malformed input safely', () {
    expect(isVersionNewer('v1.7.0-beta.2+171', '1.7.0-beta.1+170'), isTrue);
    expect(isVersionNewer('not-a-version', '1.6.5'), isFalse);
    expect(isVersionNewer('1.7', '1.6.5'), isFalse);
  });

  test('detects prerelease channels without confusing build metadata', () {
    expect(isPreReleaseVersion('1.7.0-beta.1+170'), isTrue);
    expect(isPreReleaseVersion('1.7.0+170'), isFalse);
    expect(isPreReleaseVersion('invalid'), isFalse);
  });

  test('stable users only receive prereleases after opting in', () {
    expect(
      shouldOfferVersionUpdate(
        candidate: '1.8.0-beta.1+180',
        current: '1.7.0+171',
        allowPreRelease: false,
      ),
      isFalse,
    );
    expect(
      shouldOfferVersionUpdate(
        candidate: '1.8.0-beta.1+180',
        current: '1.7.0+171',
        allowPreRelease: true,
      ),
      isTrue,
    );
  });

  test('prerelease installations continue receiving beta updates', () {
    expect(
      shouldOfferVersionUpdate(
        candidate: '1.8.0-beta.2+181',
        current: '1.8.0-beta.1+180',
        allowPreRelease: false,
      ),
      isTrue,
    );
  });

  test('stable release is offered to old stable and beta installations', () {
    for (final current in ['1.6.4', '1.6.5', '1.7.0-beta.1']) {
      expect(
        shouldOfferVersionUpdate(
          candidate: '1.7.0+171',
          current: current,
          allowPreRelease: false,
        ),
        isTrue,
        reason: '1.7.0 should be offered to $current',
      );
    }
  });
}
