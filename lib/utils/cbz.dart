import 'dart:convert';
import 'dart:math';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/comic_archive_import.dart';
import 'package:venera/utils/comic_import_transaction.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ComicMetaData {
  final String title;

  final String author;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      author = json['author'],
      tags = List<String>.from(json['tags']),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      start = json['start'],
      end = json['end'];

  ComicChapter({required this.title, required this.start, required this.end});
}

/// Owns a newly published comic directory until database/favorite registration
/// succeeds. A failed batch can therefore remove every directory it published.
final class PendingCbzImport implements PendingComicArtifact {
  PendingCbzImport._(
    this.comic,
    this.directory,
    this._ownershipMarker,
    this._ownershipToken,
  );

  final LocalComic comic;
  final Directory directory;
  final File _ownershipMarker;
  final String _ownershipToken;

  bool _resolved = false;

  @override
  void commit() {
    _resolved = true;
    try {
      if (_ownershipMarker.existsSync() &&
          _ownershipMarker.readAsStringSync() == _ownershipToken) {
        _ownershipMarker.deleteSync();
      }
    } catch (_) {
      // The registration is already durable. A stale hidden marker is safer
      // than failing after both databases have committed.
    }
  }

  @override
  Future<void> rollback() async {
    if (_resolved) return;
    if (!await directory.exists()) {
      _resolved = true;
      return;
    }
    if (!await _ownershipMarker.exists() ||
        await _ownershipMarker.readAsString() != _ownershipToken) {
      throw ComicArchiveImportException(
        'Refusing to remove a comic directory no longer owned by this import: '
        '${directory.path}',
      );
    }
    await directory.delete(recursive: true);
    _resolved = true;
  }
}

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    var fileType = await checkType(file);
    if (fileType.mime == 'application/zip') {
      await extractComicZipChecked(file.path, out.path);
    } else if (fileType.mime == "application/x-7z-compressed") {
      await extractComicSevenZipChecked(file.path, out.path);
    } else {
      throw Exception('Unsupported archive type');
    }
  }

  static Future<PendingCbzImport> import(File file) async {
    final extractionRoot = await Directory(
      App.cachePath,
    ).createTemp('cbz_import_');
    try {
      await extractArchive(file, extractionRoot);
      final extractedContents = extractionRoot.listSync(followLinks: false);
      final contentRoot =
          extractedContents.length == 1 && extractedContents.first is Directory
          ? extractedContents.first as Directory
          : extractionRoot;

      final fallbackTitle = file.basenameWithoutExt;
      final metaData = _readMetadata(contentRoot, fallbackTitle);
      if (LocalManager().findByName(metaData.title) != null) {
        throw Exception('Comic with name ${metaData.title} already exists');
      }

      final files = contentRoot
          .listSync(followLinks: false)
          .whereType<File>()
          .where(isSupportedComicImage)
          .toList();
      if (files.isEmpty) {
        throw Exception('No images found in the archive');
      }
      files.sort(_compareComicImageFiles);

      var coverFile = files.firstWhereOrNull(
        (file) => file.basenameWithoutExt.toLowerCase() == 'cover',
      );
      if (coverFile != null && files.length > 1) {
        files.remove(coverFile);
      } else {
        coverFile ??= files.first;
      }

      Map<String, String>? chapterMap;
      List<List<File>>? chapterFiles;
      final chapters = metaData.chapters;
      if (chapters != null && chapters.isNotEmpty) {
        chapterMap = <String, String>{};
        chapterFiles = <List<File>>[];
        for (var index = 0; index < chapters.length; index++) {
          final chapter = chapters[index];
          if (chapter.start < 1 ||
              chapter.end < chapter.start ||
              chapter.end > files.length) {
            throw ComicArchiveImportException(
              'Invalid chapter range for "${chapter.title}": '
              '${chapter.start}-${chapter.end}',
            );
          }
          chapterMap[index.toString()] = chapter.title;
          chapterFiles.add(files.sublist(chapter.start - 1, chapter.end));
        }
      }

      final comicChapters = ComicChapters.fromJsonOrNull(chapterMap);
      final downloadedChapters = chapterMap?.keys.toList() ?? <String>[];
      final coverExtension = coverFile.extension.toLowerCase();
      final coverName = 'cover.$coverExtension';
      final expectedFiles = <String, int>{};
      const ownershipMarkerName = '.venera-import-owner';
      final ownershipToken = _createOwnershipToken();
      final comicId = LocalManager().findValidId(ComicType.local);
      final createdAt = DateTime.now();

      final destination = await buildComicDirectoryTransactionally(
        libraryRoot: LocalManager().directory,
        title: metaData.title,
        isNameReserved: (name) => LocalManager().findByName(name) != null,
        build: (staging) async {
          final marker = File(FilePath.join(staging.path, ownershipMarkerName));
          await marker.writeAsString(ownershipToken, flush: true);
          expectedFiles[ownershipMarkerName] = utf8
              .encode(ownershipToken)
              .length;
          await _copyComicFile(coverFile!, staging, coverName, expectedFiles);
          if (chapterFiles == null) {
            for (var index = 0; index < files.length; index++) {
              final source = files[index];
              final relativePath =
                  '${index + 1}.${source.extension.toLowerCase()}';
              await _copyComicFile(
                source,
                staging,
                relativePath,
                expectedFiles,
              );
            }
          } else {
            for (
              var chapterIndex = 0;
              chapterIndex < chapterFiles.length;
              chapterIndex++
            ) {
              final pages = chapterFiles[chapterIndex];
              for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
                final source = pages[pageIndex];
                final relativePath = FilePath.join(
                  chapterIndex.toString(),
                  '${pageIndex + 1}.${source.extension.toLowerCase()}',
                );
                await _copyComicFile(
                  source,
                  staging,
                  relativePath,
                  expectedFiles,
                );
              }
            }
          }
        },
        validate: (directory) =>
            _validateComicDirectory(directory, expectedFiles),
      );

      final comic = LocalComic(
        id: comicId,
        title: metaData.title,
        subtitle: metaData.author,
        tags: metaData.tags,
        comicType: ComicType.local,
        directory: destination.name,
        chapters: comicChapters,
        downloadedChapters: downloadedChapters,
        cover: coverName,
        createdAt: createdAt,
      );
      return PendingCbzImport._(
        comic,
        destination,
        File(FilePath.join(destination.path, ownershipMarkerName)),
        ownershipToken,
      );
    } finally {
      await extractionRoot.deleteIgnoreError(recursive: true);
    }
  }

  static ComicMetaData _readMetadata(Directory root, String fallbackTitle) {
    final metadataFile = File(FilePath.join(root.path, 'metadata.json'));
    if (metadataFile.existsSync()) {
      if (metadataFile.lengthSync() > 1024 * 1024) {
        throw const ComicArchiveImportException(
          'Comic metadata exceeds the 1 MiB limit',
        );
      }
      try {
        final metadata = ComicMetaData.fromJson(
          jsonDecode(metadataFile.readAsStringSync()),
        );
        if (metadata.title.trim().isNotEmpty) {
          return ComicMetaData(
            title: metadata.title.trim(),
            author: metadata.author,
            tags: metadata.tags,
            chapters: metadata.chapters,
          );
        }
      } catch (_) {
        // Invalid optional metadata does not make an otherwise valid CBZ
        // unreadable. The archive filename remains a safe fallback title.
      }
    }
    return ComicMetaData(title: fallbackTitle, author: '', tags: const []);
  }

  static int _compareComicImageFiles(File a, File b) {
    final aIndex = int.tryParse(a.basenameWithoutExt);
    final bIndex = int.tryParse(b.basenameWithoutExt);
    if (aIndex != null && bIndex != null) {
      return aIndex.compareTo(bIndex);
    }
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  }

  static String _createOwnershipToken() {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  static Future<void> _copyComicFile(
    File source,
    Directory destination,
    String relativePath,
    Map<String, int> expectedFiles,
  ) async {
    if (expectedFiles.containsKey(relativePath)) {
      throw ComicArchiveImportException(
        'Comic import generated duplicate file: $relativePath',
      );
    }
    final expectedSize = await source.length();
    final target = File(FilePath.join(destination.path, relativePath));
    await target.parent.create(recursive: true);
    await source.copyMem(target.path);
    if (!await target.exists() || await target.length() != expectedSize) {
      throw ComicArchiveImportException(
        'Failed to verify imported file: $relativePath',
      );
    }
    expectedFiles[relativePath] = expectedSize;
  }

  static Future<void> _validateComicDirectory(
    Directory directory,
    Map<String, int> expectedFiles,
  ) async {
    if (expectedFiles.isEmpty) {
      throw const ComicArchiveImportException('Comic import produced no files');
    }
    final actualFileCount = directory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .length;
    if (actualFileCount != expectedFiles.length) {
      throw ComicArchiveImportException(
        'Comic directory contains $actualFileCount files; '
        'expected ${expectedFiles.length}',
      );
    }
    for (final entry in expectedFiles.entries) {
      final file = File(FilePath.join(directory.path, entry.key));
      if (!await file.exists() || await file.length() != entry.value) {
        throw ComicArchiveImportException(
          'Comic directory validation failed for ${entry.key}',
        );
      }
    }
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_export'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    List<ComicChapter>? chapters;
    if (comic.chapters == null) {
      var images = await LocalManager().getImages(comic.id, comic.comicType, 1);
      int i = 1;
      for (var image in images) {
        var src = File(image.replaceFirst('file://', ''));
        var width = images.length.toString().length;
        var dstName =
            '${i.toString().padLeft(width, '0')}.${image.split('.').last}';
        var dst = File(FilePath.join(cache.path, dstName));
        await src.copyMem(dst.path);
        i++;
      }
    } else {
      chapters = [];
      var allImages = <String>[];
      for (var c in comic.downloadedChapters) {
        var chapterName = comic.chapters![c];
        var images = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          c,
        );
        allImages.addAll(images);
        var chapter = ComicChapter(
          title: chapterName!,
          start: chapters.length + 1,
          end: chapters.length + images.length,
        );
        chapters.add(chapter);
      }
      int i = 1;
      for (var image in allImages) {
        var src = File(image);
        var width = allImages.length.toString().length;
        var dstName =
            '${i.toString().padLeft(width, '0')}.${image.split('.').last}';
        var dst = File(FilePath.join(cache.path, dstName));
        await src.copyMem(dst.path);
        i++;
      }
    }
    var cover = comic.coverFile;
    await cover.copyMem(
      FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
    );
    final metaData = ComicMetaData(
      title: comic.title,
      author: comic.subtitle,
      tags: comic.tags,
      chapters: chapters,
    );
    await File(
      FilePath.join(cache.path, 'metadata.json'),
    ).writeAsString(jsonEncode(metaData));
    await File(
      FilePath.join(cache.path, 'ComicInfo.xml'),
    ).writeAsString(_buildComicInfoXml(metaData));
    var cbz = File(outFilePath);
    if (cbz.existsSync()) cbz.deleteSync();
    await _compress(cache.path, cbz.path);
    cache.deleteSync(recursive: true);
    return cbz;
  }

  static String _buildComicInfoXml(ComicMetaData data) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    if (data.author.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(data.author)}</Writer>');
    }

    if (data.tags.isNotEmpty) {
      var tags = data.tags;
      if (tags.length > 5) {
        tags = tags.sublist(0, 5);
      }
      buffer.writeln('  <Genre>${_escapeXml(tags.join(', '))}</Genre>');
    }

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _compress(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }
}
