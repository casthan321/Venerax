import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_7zip/flutter_7zip.dart' as seven_zip;
import 'package:path/path.dart' as p;
import 'package:venera/utils/io.dart' show sanitizeFileName;
import 'package:venera/utils/zip_extraction.dart';
import 'package:zip_flutter/zip_flutter.dart' show ZipException;

/// A deliberately tighter budget than application-data backups use.
///
/// Comic archives contain compressed images, so a very high expansion ratio or
/// a single enormous entry is not expected. ZIP and 7Z imports share this
/// budget to avoid format-specific resource-limit bypasses.
const comicArchiveExtractionBudget = ZipExtractionBudget(
  maxEntries: 20000,
  maxSingleFileBytes: 128 * 1024 * 1024,
  maxTotalUncompressedBytes: 2 * 1024 * 1024 * 1024,
  maxPathDepth: 16,
  maxCompressionRatio: 1000,
);

const comicImportStagingPrefix = '.venera-cbz-import-';

class ComicArchiveImportException implements Exception {
  const ComicArchiveImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Applies the common comic-archive budget and portable path checks.
///
/// This is public so the 7Z preflight can be unit-tested without loading a
/// native archive fixture. Every entry must be inspected before extraction.
void validateComicArchiveMetadata(
  Iterable<ZipArchiveEntryMetadata> metadata, {
  ZipExtractionBudget budget = comicArchiveExtractionBudget,
  int? archiveCompressedBytes,
}) {
  final entries = metadata.toList(growable: false);
  validateZipMetadata(
    entries,
    budget: budget,
    archiveCompressedBytes: archiveCompressedBytes,
  );

  final entryKinds = <String, bool>{};
  for (final entry in entries) {
    final parts = _portableArchivePathParts(entry.name);
    if (parts.isEmpty) {
      throw ComicArchiveImportException(
        'Archive entry has no usable path: ${entry.name}',
      );
    }
    for (final part in parts) {
      if (!_isPortableArchivePathSegment(part)) {
        throw ComicArchiveImportException(
          'Archive entry is not portable: ${entry.name}',
        );
      }
    }

    // Treat paths case-insensitively even on case-sensitive hosts. A library
    // can be moved between Android and Windows, and aliases must never cause a
    // later entry to replace an earlier one.
    final key = parts.join('/').toLowerCase();
    if (entryKinds.containsKey(key)) {
      throw ComicArchiveImportException(
        'Archive contains duplicate output paths: ${entry.name}',
      );
    }
    entryKinds[key] = entry.isDirectory;
  }

  for (final entry in entryKinds.entries) {
    final parts = entry.key.split('/');
    for (var depth = 1; depth < parts.length; depth++) {
      final ancestor = parts.take(depth).join('/');
      if (entryKinds[ancestor] == false) {
        throw ComicArchiveImportException(
          'Archive file is also used as a directory: $ancestor',
        );
      }
    }
  }
}

Future<void> extractComicZipChecked(
  String archivePath,
  String destinationPath,
) {
  return Isolate.run(
    () => extractZipChecked(
      archivePath,
      destinationPath,
      budget: comicArchiveExtractionBudget,
      additionalMetadataValidation: (metadata, archiveCompressedBytes) {
        validateComicArchiveMetadata(
          metadata,
          budget: comicArchiveExtractionBudget,
          archiveCompressedBytes: archiveCompressedBytes,
        );
      },
    ),
  );
}

Future<void> extractComicSevenZipChecked(
  String archivePath,
  String destinationPath,
) {
  return Isolate.run(
    () => _extractComicSevenZipCheckedSync(archivePath, destinationPath),
  );
}

void _extractComicSevenZipCheckedSync(
  String archivePath,
  String destinationPath,
) {
  // flutter_7zip exposes entry sizes as native size_t. On a 32-bit process a
  // malicious >4 GiB size can be truncated before Dart sees it, so the stated
  // budget cannot be enforced reliably. Fail closed on that ABI.
  if (sizeOf<IntPtr>() < 8) {
    throw const ComicArchiveImportException(
      'Safe 7Z import is unavailable on 32-bit platforms',
    );
  }

  final destination = Directory(destinationPath)..createSync(recursive: true);
  if (destination.listSync(followLinks: false).isNotEmpty) {
    throw const ComicArchiveImportException(
      '7Z extraction destination must be empty',
    );
  }

  seven_zip.SZArchive? archive;
  try {
    archive = seven_zip.SZArchive.open(archivePath);
    final entryCount = archive.numFiles;
    if (entryCount <= 0) {
      throw const ComicArchiveImportException('7Z archive contains no entries');
    }
    if (entryCount > comicArchiveExtractionBudget.maxEntries) {
      throw ComicArchiveImportException(
        '7Z archive contains $entryCount entries, exceeding the limit of '
        '${comicArchiveExtractionBudget.maxEntries}',
      );
    }

    final entries = <seven_zip.ArchiveFile>[];
    for (var index = 0; index < entryCount; index++) {
      entries.add(archive.getFile(index));
    }
    validateComicArchiveMetadata(
      entries.map(
        (entry) => ZipArchiveEntryMetadata(
          name: entry.name,
          isDirectory: entry.isDirectory,
          uncompressedBytes: entry.size,
        ),
      ),
      archiveCompressedBytes: File(archivePath).lengthSync(),
    );

    final destinationAbsolute = p.normalize(p.absolute(destination.path));
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final outputPath = _checkedArchiveOutputPath(
        destinationAbsolute,
        entry.name,
      );
      if (entry.isDirectory) {
        if (File(outputPath).existsSync()) {
          throw ComicArchiveImportException(
            '7Z directory conflicts with a file: ${entry.name}',
          );
        }
        Directory(outputPath).createSync(recursive: true);
        continue;
      }

      if (File(outputPath).existsSync() || Directory(outputPath).existsSync()) {
        throw ComicArchiveImportException(
          '7Z entry would overwrite another output: ${entry.name}',
        );
      }
      File(outputPath).parent.createSync(recursive: true);
      archive.extractToFile(index, outputPath);
      final output = File(outputPath);
      if (!output.existsSync()) {
        throw ComicArchiveImportException(
          '7Z entry was not extracted: ${entry.name}',
        );
      }
      final actualSize = output.lengthSync();
      if (actualSize != entry.size) {
        throw ComicArchiveImportException(
          '7Z entry ${entry.name} extracted with $actualSize bytes; '
          'expected ${entry.size}',
        );
      }
    }
  } on ZipException catch (error) {
    throw ComicArchiveImportException('Unsafe 7Z archive: ${error.message}');
  } finally {
    archive?.dispose();
  }
}

/// Builds a comic in a unique hidden directory, validates it, then publishes
/// it under a collision-free sanitized name.
///
/// A failed build, validation, or publish removes both the staging directory
/// and any final directory produced by a non-atomic filesystem provider. The
/// final validation is important for Android SAF, whose rename implementation
/// can internally copy rather than perform a native atomic rename.
Future<Directory> buildComicDirectoryTransactionally({
  required Directory libraryRoot,
  required String title,
  required FutureOr<void> Function(Directory staging) build,
  required FutureOr<void> Function(Directory directory) validate,
  bool Function(String directoryName)? isNameReserved,
}) async {
  if (!await libraryRoot.exists()) {
    throw ComicArchiveImportException(
      'Local comic directory does not exist: ${libraryRoot.path}',
    );
  }

  final staging = _createUniqueStagingDirectory(libraryRoot);
  Directory? published;
  try {
    await build(staging);
    if (staging.listSync(followLinks: false).isEmpty) {
      throw const ComicArchiveImportException(
        'Comic import produced an empty directory',
      );
    }
    await validate(staging);
    published = await _publishStagingDirectory(
      staging: staging,
      libraryRoot: libraryRoot,
      title: title,
      isNameReserved: isNameReserved,
    );
    await validate(published);
    return published;
  } catch (error, stackTrace) {
    final cleanupErrors = <Object>[];
    for (final directory in <Directory?>[published, staging]) {
      if (directory == null) continue;
      try {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (cleanupError) {
        cleanupErrors.add(cleanupError);
      }
    }
    if (cleanupErrors.isNotEmpty) {
      Error.throwWithStackTrace(
        ComicArchiveImportException(
          'Comic import failed ($error), and temporary data could not be '
          'removed: ${cleanupErrors.join('; ')}',
        ),
        stackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

Directory _createUniqueStagingDirectory(Directory libraryRoot) {
  final random = Random.secure();
  for (var attempt = 0; attempt < 100; attempt++) {
    final token = List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    final staging = Directory(
      p.join(libraryRoot.path, '$comicImportStagingPrefix$token'),
    );
    if (_entityExists(staging.path)) continue;
    staging.createSync();
    return staging;
  }
  throw const ComicArchiveImportException(
    'Could not allocate a unique comic import directory',
  );
}

Future<Directory> _publishStagingDirectory({
  required Directory staging,
  required Directory libraryRoot,
  required String title,
  bool Function(String directoryName)? isNameReserved,
}) async {
  final baseName = sanitizeComicDirectoryName(title);
  final occupiedNames = libraryRoot
      .listSync(followLinks: false)
      .map((entity) => p.basename(entity.path).toLowerCase())
      .toSet();

  for (var index = 0; index < 10000; index++) {
    final directoryName = _directoryNameWithSuffix(baseName, index);
    final foldedName = directoryName.toLowerCase();
    final destinationPath = p.join(libraryRoot.path, directoryName);
    if (occupiedNames.contains(foldedName) ||
        (isNameReserved?.call(directoryName) ?? false) ||
        _entityExists(destinationPath)) {
      occupiedNames.add(foldedName);
      continue;
    }

    try {
      return await staging.rename(destinationPath);
    } on FileSystemException {
      // Another import can win the same title between the check and rename.
      // A completed comic directory is non-empty, so supported filesystems do
      // not replace it with this staging directory. Retry with a suffix.
      if (_entityExists(destinationPath) && await staging.exists()) {
        occupiedNames.add(foldedName);
        continue;
      }
      rethrow;
    }
  }
  throw ComicArchiveImportException(
    'No available directory name for comic "$title"',
  );
}

String sanitizeComicDirectoryName(String title) {
  final withoutControls = title.replaceAll(RegExp(r'[\x00-\x1f]'), ' ');
  var result = sanitizeFileName(withoutControls, maxLength: 120);
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  return result;
}

String _directoryNameWithSuffix(String baseName, int index) {
  if (index == 0) return baseName;
  final suffix = ' ($index)';
  final availableBaseLength = 120 - suffix.length;
  final truncatedBase = baseName.length <= availableBaseLength
      ? baseName
      : baseName.substring(0, availableBaseLength).trimRight();
  return '$truncatedBase$suffix';
}

String _checkedArchiveOutputPath(String destinationAbsolute, String name) {
  final parts = _portableArchivePathParts(name);
  final outputPath = p.normalize(p.joinAll([destinationAbsolute, ...parts]));
  if (!p.isWithin(destinationAbsolute, outputPath)) {
    throw ComicArchiveImportException(
      'Archive entry escapes the extraction directory: $name',
    );
  }
  return outputPath;
}

List<String> _portableArchivePathParts(String name) {
  return name
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList(growable: false);
}

bool _isPortableArchivePathSegment(String segment) {
  if (segment.endsWith('.') || segment.endsWith(' ')) return false;
  if (RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(segment)) return false;
  return !RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(segment);
}

bool _entityExists(String path) {
  if (File(path).existsSync() || Directory(path).existsSync()) return true;
  try {
    return Link(path).existsSync();
  } on FileSystemException {
    return false;
  } on UnsupportedError {
    return false;
  }
}
