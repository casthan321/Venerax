import 'dart:convert';

/// Whether image favorites are supported for the comic currently being read.
///
/// Downloaded source comics are file-backed too, so the image URI must not be
/// used to distinguish them from comics imported as local files.
bool supportsImageFavorites({required bool isImportedLocalComic}) {
  return !isImportedLocalComic;
}

String imageFavoriteCacheIdentity({
  required String imageKey,
  required String sourceKey,
  required String comicId,
  required String episodeId,
  required int page,
}) {
  return 'ImageFavoritesV2 ${jsonEncode(<Object>[imageKey, sourceKey, comicId, episodeId, page])}';
}

String legacyImageFavoriteCacheIdentity({
  required String imageKey,
  required String sourceKey,
  required String comicId,
  required String episodeId,
}) {
  return 'ImageFavorites $imageKey@$sourceKey@$comicId@$episodeId';
}

bool canReadLegacyImageFavoriteCache(String imageKey) => imageKey.isNotEmpty;

T? nonEmptyImageDataOrNull<T extends List<int>>(T data) {
  return data.isEmpty ? null : data;
}

/// Resolves the one-based chapter number expected by `LocalManager.getImages`.
///
/// A comic may only be partially downloaded. In that case an existing chapter
/// id is not enough: the chapter must also be present in [downloadedChapterIds].
int? resolveDownloadedFavoriteChapter({
  required bool hasChapters,
  required List<String>? chapterIds,
  required List<String> downloadedChapterIds,
  required String episodeId,
}) {
  if (!hasChapters) return 1;
  if (!downloadedChapterIds.contains(episodeId)) return null;

  final chapterIndex = chapterIds?.indexOf(episodeId) ?? -1;
  return chapterIndex < 0 ? null : chapterIndex + 1;
}

/// Resolves a one-based favorite page to the underlying local file path.
String? resolveLocalFavoriteImagePath({
  required List<String> imageKeys,
  required int page,
}) {
  final imageIndex = page - 1;
  if (imageIndex < 0 || imageIndex >= imageKeys.length) return null;

  const fileScheme = 'file://';
  final imageKey = imageKeys[imageIndex];
  if (!imageKey.startsWith(fileScheme)) return null;

  final path = imageKey.substring(fileScheme.length);
  return path.isEmpty ? null : path;
}

/// Uses a downloaded image when it is readable, otherwise runs the existing
/// cache/network fallback. Local storage errors are treated as a cache miss.
Future<T> loadLocalImageOrFallback<T extends Object>({
  required Future<T?> Function() loadLocal,
  required Future<T> Function() loadFallback,
  void Function()? afterLocalAttempt,
}) async {
  T? localImage;
  try {
    localImage = await loadLocal();
  } catch (_) {
    localImage = null;
  }

  // Keep cancellation checks outside the catch above. A cancellation must not
  // be mistaken for a local cache miss and start a network request.
  afterLocalAttempt?.call();
  return localImage ?? await loadFallback();
}
