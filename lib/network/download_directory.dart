import 'dart:convert';

import 'package:venera/utils/io.dart';

const downloadDirectoryMarkerName = '.venera_download.json';
const downloadPartialFileSuffix = '.venera-part';

String downloadPartialImageFileName(int index, String extension) {
  return downloadPartialFileName('$index$extension');
}

String downloadPartialFileName(String destinationName) =>
    '$destinationName$downloadPartialFileSuffix';

bool isDownloadPartialImageFileName(String name) {
  return name.endsWith(downloadPartialFileSuffix);
}

Future<bool> writeDownloadedImageAtomically({
  required File temporaryFile,
  required File destinationFile,
  required List<int> bytes,
  required bool Function() isCancelled,
}) async {
  if (bytes.isEmpty) {
    throw ArgumentError.value(bytes, 'bytes', 'Downloaded image is empty');
  }

  var committed = false;
  try {
    await temporaryFile.writeAsBytes(bytes, flush: true);
    if (isCancelled()) return false;
    if (await destinationFile.exists()) {
      // Another successful writer won the race. Preserve its final file and
      // discard this temporary copy rather than creating an overwrite gap.
      return !isCancelled();
    }
    if (isCancelled()) return false;
    await temporaryFile.rename(destinationFile.path);
    committed = true;
    return true;
  } finally {
    if (!committed) {
      await temporaryFile.deleteIgnoreError();
    }
  }
}

List<String> downloadChapterDirectoryPaths(
  String rootPath,
  Iterable<String> chapterKeys, {
  required String Function(String chapterKey) directoryNameForChapter,
}) {
  return chapterKeys
      .map(directoryNameForChapter)
      .map((name) => FilePath.join(rootPath, name))
      .toSet()
      .toList(growable: false);
}

List<String> cancellableDownloadChapterKeys({
  required Iterable<String> requestedChapterKeys,
  required Iterable<String> previouslyDownloadedChapterKeys,
  required String Function(String chapterKey) directoryNameForChapter,
}) {
  final previouslyDownloaded = previouslyDownloadedChapterKeys.toSet();
  final protectedDirectoryNames = previouslyDownloaded
      .map(directoryNameForChapter)
      .toSet();
  return requestedChapterKeys
      .where(
        (key) =>
            !previouslyDownloaded.contains(key) &&
            !protectedDirectoryNames.contains(directoryNameForChapter(key)),
      )
      .toSet()
      .toList(growable: false);
}

class DownloadDirectoryIdentity {
  const DownloadDirectoryIdentity({
    required this.sourceKey,
    required this.comicId,
  });

  final String sourceKey;
  final String comicId;

  List<int> encode() => utf8.encode(
    jsonEncode({'version': 1, 'source': sourceKey, 'comicId': comicId}),
  );

  static DownloadDirectoryIdentity? decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map || json['version'] != 1) return null;
      final sourceKey = json['source'];
      final comicId = json['comicId'];
      if (sourceKey is! String || comicId is! String) return null;
      return DownloadDirectoryIdentity(sourceKey: sourceKey, comicId: comicId);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadDirectoryIdentity &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId;

  @override
  int get hashCode => Object.hash(sourceKey, comicId);
}

Future<Directory?> findReusableDownloadDirectory(
  Directory root,
  DownloadDirectoryIdentity identity,
) async {
  final matches = <Directory>[];
  await for (final entity in root.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final marker = File(
      FilePath.join(entity.path, downloadDirectoryMarkerName),
    );
    if (!await marker.exists()) continue;
    final savedIdentity = DownloadDirectoryIdentity.decode(
      await marker.readAsBytes(),
    );
    if (savedIdentity == identity) matches.add(entity);
  }
  matches.sort((a, b) => a.path.compareTo(b.path));
  return matches.firstOrNull;
}

Future<void> ensureDownloadDirectoryIdentity(
  Directory directory,
  DownloadDirectoryIdentity identity,
) async {
  final marker = File(
    FilePath.join(directory.path, downloadDirectoryMarkerName),
  );
  if (await marker.exists()) {
    final savedIdentity = DownloadDirectoryIdentity.decode(
      await marker.readAsBytes(),
    );
    if (savedIdentity != identity) {
      throw FileSystemException(
        'Download directory belongs to a different comic',
        directory.path,
      );
    }
    return;
  }
  await marker.writeAsBytes(identity.encode(), flush: true);
}

class ExistingDownloadArtifacts {
  const ExistingDownloadArtifacts({required this.completeFiles});

  final Map<int, File> completeFiles;
}

Future<ExistingDownloadArtifacts> scanExistingDownloadPages(
  Directory directory, {
  required int expectedCount,
}) async {
  if (!await directory.exists()) {
    return const ExistingDownloadArtifacts(completeFiles: <int, File>{});
  }

  final candidates = <File>[];
  final partialFiles = <File>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    if (isDownloadPartialImageFileName(entity.name)) {
      partialFiles.add(entity);
    } else if (isSupportedComicImage(entity)) {
      candidates.add(entity);
    }
  }
  for (final partialFile in partialFiles) {
    await partialFile.deleteIgnoreError();
  }
  candidates.sort((a, b) => a.path.compareTo(b.path));

  final completeFiles = <int, File>{};
  for (final file in candidates) {
    final index = int.tryParse(file.name.split('.').first);
    if (index == null || index < 0 || index >= expectedCount) continue;
    if (await file.length() > 0) {
      completeFiles.putIfAbsent(index, () => file);
    } else {
      // A zero-byte final file is not progress. Remove it so the page can be
      // downloaded again instead of trapping every resume in an error state.
      await file.deleteIgnoreError();
    }
  }
  return ExistingDownloadArtifacts(completeFiles: completeFiles);
}

class ExistingDownloadCover {
  const ExistingDownloadCover({
    required this.completeFile,
    required this.hasInvalidFile,
  });

  final File? completeFile;
  final bool hasInvalidFile;
}

Future<ExistingDownloadCover> findExistingDownloadCover(
  Directory directory,
) async {
  if (!await directory.exists()) {
    return const ExistingDownloadCover(
      completeFile: null,
      hasInvalidFile: false,
    );
  }
  final candidates = <File>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !entity.name.toLowerCase().startsWith('cover.')) {
      continue;
    }
    if (isDownloadPartialImageFileName(entity.name)) {
      await entity.deleteIgnoreError();
    } else if (isSupportedComicImage(entity)) {
      if (await entity.length() > 0) {
        candidates.add(entity);
      } else {
        await entity.deleteIgnoreError();
      }
    }
  }
  candidates.sort((a, b) => a.path.compareTo(b.path));
  return ExistingDownloadCover(
    completeFile: candidates.firstOrNull,
    hasInvalidFile: false,
  );
}
