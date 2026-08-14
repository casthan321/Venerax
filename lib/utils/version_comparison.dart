/// Returns whether [candidate] is a newer semantic version than [current].
///
/// Invalid versions are treated as non-updates so a malformed remote
/// `pubspec.yaml` can never crash the update checker.
bool isVersionNewer(String candidate, String current) {
  final candidateVersion = _SemanticVersion.tryParse(candidate);
  final currentVersion = _SemanticVersion.tryParse(current);
  if (candidateVersion == null || currentVersion == null) return false;
  return candidateVersion.compareTo(currentVersion) > 0;
}

bool isPreReleaseVersion(String version) =>
    _SemanticVersion.tryParse(version)?.preRelease != null;

/// Returns whether [candidate] should be offered to a user on [current].
///
/// Stable installations do not receive prereleases unless they explicitly opt
/// in. Once a prerelease is installed, newer prereleases remain discoverable
/// so beta users are not stranded on an older build.
bool shouldOfferVersionUpdate({
  required String candidate,
  required String current,
  required bool allowPreRelease,
}) {
  if (isPreReleaseVersion(candidate) &&
      !allowPreRelease &&
      !isPreReleaseVersion(current)) {
    return false;
  }
  return isVersionNewer(candidate, current);
}

final class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.major, this.minor, this.patch, this.preRelease);

  final int major;
  final int minor;
  final int patch;
  final List<String>? preRelease;

  static final _pattern = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  static _SemanticVersion? tryParse(String raw) {
    final normalized = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final match = _pattern.firstMatch(normalized);
    if (match == null) return null;
    final preRelease = match.group(4)?.split('.');
    return _SemanticVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      preRelease,
    );
  }

  @override
  int compareTo(_SemanticVersion other) {
    for (final comparison in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (comparison != 0) return comparison;
    }

    final left = preRelease;
    final right = other.preRelease;
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    for (var index = 0; index < left.length && index < right.length; index++) {
      final leftNumber = int.tryParse(left[index]);
      final rightNumber = int.tryParse(right[index]);
      final int comparison;
      if (leftNumber != null && rightNumber != null) {
        comparison = leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null) {
        comparison = -1;
      } else if (rightNumber != null) {
        comparison = 1;
      } else {
        comparison = left[index].compareTo(right[index]);
      }
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(right.length);
  }
}
