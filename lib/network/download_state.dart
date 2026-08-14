import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

const downloadImageListTimeout = Duration(seconds: 30);

Future<T> runDownloadImageListLoad<T>(
  Future<T> Function() load, {
  Duration timeout = downloadImageListTimeout,
}) {
  return Future<T>.sync(load).timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      'Comic source did not finish loading download image list',
      timeout,
    ),
  );
}

Future<void> runDownloadCleanupBeforeResume({
  required Future<void> Function() cleanup,
  required void Function() resumeNext,
}) async {
  try {
    await cleanup();
  } finally {
    resumeNext();
  }
}

/// Returns the image-list keys that still need to be fetched.
///
/// An empty list is treated as missing. A chapter without any images cannot be
/// opened as a downloaded chapter and must not make a download task complete.
List<String> missingImageListKeys(
  Iterable<String> expectedKeys,
  Map<String, List<String>>? imageLists,
) {
  return expectedKeys
      .where((key) => imageLists?[key]?.isNotEmpty != true)
      .toList();
}

bool hasCompleteImageLists(
  Iterable<String> expectedKeys,
  Map<String, List<String>>? imageLists,
) {
  final keys = expectedKeys.toList();
  return keys.isNotEmpty && missingImageListKeys(keys, imageLists).isEmpty;
}

/// Keeps restored image lists in chapter order without requiring every list
/// to be present. This lets downloading start after the first available
/// chapter while later chapters are fetched progressively.
Map<String, List<String>> orderedAvailableImageLists(
  Iterable<String> expectedKeys,
  Map<String, List<String>>? imageLists,
) {
  return {
    for (final key in expectedKeys)
      if (imageLists?[key]?.isNotEmpty == true) key: imageLists![key]!,
  };
}

int knownDownloadImageCount(Map<String, List<String>>? imageLists) {
  if (imageLists == null) return 0;
  return imageLists.values.fold(0, (total, images) => total + images.length);
}

String archiveDownloadCacheFileName({
  required String sourceKey,
  required String comicId,
  required String archiveUrl,
}) {
  final identity = md5.convert(
    utf8.encode('$sourceKey\u0000$comicId\u0000$archiveUrl'),
  );
  return 'archive_$identity.zip';
}

bool hasCompleteDownloadedPageIndexes(
  int expectedCount,
  Iterable<int> downloadedIndexes,
) {
  if (expectedCount <= 0) return false;
  final downloaded = downloadedIndexes.toSet();
  return downloaded.length == expectedCount &&
      Iterable<int>.generate(expectedCount).every(downloaded.contains);
}

/// Invalidates asynchronous work from an earlier pause/resume cycle.
///
/// Network requests are not necessarily cancellable. A token lets their
/// continuations detect that a newer run owns the task state.
class DownloadRunGuard {
  int _generation = 0;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  int start() {
    if (_isRunning) {
      throw StateError('Download is already running');
    }
    _isRunning = true;
    return ++_generation;
  }

  void stop() {
    _isRunning = false;
    _generation++;
  }

  bool isActive(int token) => _isRunning && token == _generation;
}
