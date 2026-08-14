import 'dart:io';

import 'package:zip_flutter/zip_flutter.dart';

const defaultZipExtractionBudget = ZipExtractionBudget(
  maxEntries: 100000,
  maxSingleFileBytes: 1024 * 1024 * 1024,
  maxTotalUncompressedBytes: 16 * 1024 * 1024 * 1024,
  maxPathDepth: 32,
  // SQLite backups can contain large runs of empty pages, while comic images
  // are normally already compressed. A generous ceiling avoids rejecting
  // legitimate backups but still blocks classic tiny-input ZIP bombs.
  maxCompressionRatio: 1000,
);

class ZipExtractionBudget {
  const ZipExtractionBudget({
    required this.maxEntries,
    required this.maxSingleFileBytes,
    required this.maxTotalUncompressedBytes,
    required this.maxPathDepth,
    this.maxCompressionRatio,
  }) : assert(maxEntries > 0),
       assert(maxSingleFileBytes > 0),
       assert(maxTotalUncompressedBytes > 0),
       assert(maxPathDepth > 0),
       assert(maxCompressionRatio == null || maxCompressionRatio > 0);

  final int maxEntries;
  final int maxSingleFileBytes;
  final int maxTotalUncompressedBytes;
  final int maxPathDepth;
  final double? maxCompressionRatio;
}

class ZipArchiveEntryMetadata {
  const ZipArchiveEntryMetadata({
    required this.name,
    required this.isDirectory,
    required this.uncompressedBytes,
    this.compressedBytes,
  });

  final String name;
  final bool isDirectory;
  final int uncompressedBytes;
  final int? compressedBytes;
}

typedef ZipMetadataValidator =
    void Function(
      List<ZipArchiveEntryMetadata> metadata,
      int archiveCompressedBytes,
    );

void validateZipMetadata(
  Iterable<ZipArchiveEntryMetadata> metadata, {
  ZipExtractionBudget budget = defaultZipExtractionBudget,
  int? archiveCompressedBytes,
}) {
  final entries = metadata.toList(growable: false);
  if (entries.isEmpty) {
    throw const ZipException('Archive contains no entries');
  }
  if (entries.length > budget.maxEntries) {
    throw ZipException(
      'Archive contains ${entries.length} entries, exceeding the limit of '
      '${budget.maxEntries}',
    );
  }

  var totalUncompressedBytes = 0;
  for (final entry in entries) {
    if (!isSafeZipEntryName(entry.name)) {
      throw ZipException('Unsafe archive entry: ${entry.name}');
    }
    final pathDepth = entry.name
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .length;
    if (pathDepth > budget.maxPathDepth) {
      throw ZipException(
        'Archive entry path is $pathDepth levels deep, exceeding the limit '
        'of ${budget.maxPathDepth}: ${entry.name}',
      );
    }
    if (entry.uncompressedBytes < 0) {
      throw ZipException('Archive entry has an invalid size: ${entry.name}');
    }
    if (!entry.isDirectory &&
        entry.uncompressedBytes > budget.maxSingleFileBytes) {
      throw ZipException(
        'Archive entry is too large (${entry.uncompressedBytes} bytes): '
        '${entry.name}',
      );
    }
    totalUncompressedBytes += entry.uncompressedBytes;
    if (totalUncompressedBytes > budget.maxTotalUncompressedBytes) {
      throw ZipException(
        'Archive expands beyond the ${budget.maxTotalUncompressedBytes}-byte '
        'limit',
      );
    }
    _validateCompressionRatio(
      entry.uncompressedBytes,
      entry.compressedBytes,
      budget.maxCompressionRatio,
      entry.name,
    );
  }

  _validateCompressionRatio(
    totalUncompressedBytes,
    archiveCompressedBytes,
    budget.maxCompressionRatio,
    'archive',
  );
}

void _validateCompressionRatio(
  int uncompressedBytes,
  int? compressedBytes,
  double? maximumRatio,
  String label,
) {
  if (maximumRatio == null || compressedBytes == null) return;
  if (compressedBytes < 0) {
    throw ZipException('$label has an invalid compressed size');
  }
  if (uncompressedBytes == 0) return;
  if (compressedBytes == 0 ||
      uncompressedBytes / compressedBytes > maximumRatio) {
    throw ZipException(
      '$label exceeds the maximum compression ratio of $maximumRatio',
    );
  }
}

/// Returns whether an archive entry is a relative path that stays inside the
/// extraction directory. This check is intentionally platform independent so
/// archives created on another operating system remain safe to inspect.
bool isSafeZipEntryName(String name) {
  final normalized = name.replaceAll('\\', '/');
  return normalized.isNotEmpty &&
      !normalized.startsWith('/') &&
      !RegExp(r'^[A-Za-z]:').hasMatch(normalized) &&
      !normalized.split('/').any((part) => part == '..');
}

/// Extracts a ZIP entry by entry so native read/write failures are surfaced.
///
/// `ZipFile.openAndExtract` in zip_flutter 0.0.13 discards the native
/// `zip_extract` return code. A damaged archive can therefore look successful
/// after writing only part of its contents. This checked path validates names,
/// uses the entry APIs that throw on failure, and confirms non-empty files have
/// their declared size before any staging directory is published.
void extractZipChecked(
  String archivePath,
  String destinationPath, {
  ZipExtractionBudget budget = defaultZipExtractionBudget,
  ZipMetadataValidator? additionalMetadataValidation,
}) {
  final destination = Directory(destinationPath)..createSync(recursive: true);
  final destinationAbsolute = destination.absolute.path;
  final separator = Platform.pathSeparator;
  final destinationPrefix = destinationAbsolute.endsWith(separator)
      ? destinationAbsolute
      : '$destinationAbsolute$separator';
  final zip = ZipFile.openRead(archivePath);
  try {
    final entries = zip.getAllEntries();
    final archiveCompressedBytes = File(archivePath).lengthSync();
    final metadata = entries
        .map(
          (entry) => ZipArchiveEntryMetadata(
            name: entry.name,
            isDirectory: entry.isDir,
            uncompressedBytes: entry.size,
          ),
        )
        .toList(growable: false);
    validateZipMetadata(
      metadata,
      budget: budget,
      archiveCompressedBytes: archiveCompressedBytes,
    );
    additionalMetadataValidation?.call(metadata, archiveCompressedBytes);

    // Inspect every destination before writing the first byte. Besides making
    // collisions fail atomically, checking every path segment prevents an
    // existing symlink below the destination from redirecting extraction.
    preflightZipOutputCollisions(
      destinationAbsolute,
      entries.map((entry) => entry.name),
    );

    for (final entry in entries) {
      final relativeParts = _zipRelativeParts(entry.name);
      if (relativeParts.isEmpty) continue;
      final relative = relativeParts.join(separator);
      final outputPath = File('$destinationPrefix$relative').absolute.path;
      if (outputPath != destinationAbsolute &&
          !outputPath.startsWith(destinationPrefix)) {
        throw ZipException('Archive entry escapes destination: ${entry.name}');
      }
      if (entry.isDir) {
        if (File(outputPath).existsSync() || Link(outputPath).existsSync()) {
          throw ZipException(
            'Archive directory collides with an existing output: ${entry.name}',
          );
        }
        Directory(outputPath).createSync(recursive: true);
      } else {
        if (File(outputPath).existsSync() ||
            Directory(outputPath).existsSync() ||
            Link(outputPath).existsSync()) {
          throw ZipException(
            'Archive file collides with an existing output: ${entry.name}',
          );
        }
        entry.writeToFile(outputPath);
        final actualSize = File(outputPath).lengthSync();
        if (actualSize != entry.size) {
          throw ZipException(
            'Extracted ${entry.name} with $actualSize bytes, expected ${entry.size}',
          );
        }
      }
    }
  } finally {
    zip.close();
  }
}

List<String> _zipRelativeParts(String name) {
  return name
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList(growable: false);
}

/// Rejects every existing leaf or ancestor before extraction starts.
///
/// This is public so the no-partial-write contract can be tested without
/// loading zip_flutter's native library in a Dart test process.
void preflightZipOutputCollisions(
  String destinationPath,
  Iterable<String> entryNames,
) {
  final destinationAbsolute = Directory(destinationPath).absolute.path;
  for (final entryName in entryNames) {
    if (!isSafeZipEntryName(entryName)) {
      throw ZipException('Unsafe archive entry: $entryName');
    }
    var currentPath = destinationAbsolute;
    for (final part in _zipRelativeParts(entryName)) {
      currentPath = File(
        '$currentPath${Platform.pathSeparator}$part',
      ).absolute.path;
      if (File(currentPath).existsSync() ||
          Directory(currentPath).existsSync() ||
          Link(currentPath).existsSync()) {
        throw ZipException(
          'Archive output collides with an existing path: $entryName',
        );
      }
    }
  }
}
