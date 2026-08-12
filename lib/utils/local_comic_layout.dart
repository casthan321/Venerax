import 'package:path/path.dart' as path;

typedef LocalComicDirectoryLayout = ({List<String> chapters, String coverPath});

/// Resolves a local comic's chapters and cover from already filtered images.
///
/// A comic may contain images at its root, chapter directories, or both. When
/// the root has no images, the first image in the first non-empty chapter is
/// used as the cover and its chapter-relative path is retained.
LocalComicDirectoryLayout? resolveLocalComicDirectoryLayout({
  required Iterable<String> rootImages,
  required Map<String, Iterable<String>> chapterImages,
}) {
  final sortedRootImages = rootImages.toList()..sort();
  final sortedChapters = chapterImages.keys.toList()..sort();

  String? coverPath;
  for (final image in sortedRootImages) {
    if (image.startsWith('cover')) {
      coverPath = image;
      break;
    }
  }
  if (coverPath == null && sortedRootImages.isNotEmpty) {
    coverPath = sortedRootImages.first;
  }

  if (coverPath == null) {
    for (final chapter in sortedChapters) {
      final images = chapterImages[chapter]!.toList()..sort();
      if (images.isNotEmpty) {
        coverPath = path.join(chapter, images.first);
        break;
      }
    }
  }

  if (coverPath == null) return null;
  return (chapters: sortedChapters, coverPath: coverPath);
}
