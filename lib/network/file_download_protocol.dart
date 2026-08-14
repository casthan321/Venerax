class DownloadContentRange {
  const DownloadContentRange({
    required this.start,
    required this.endInclusive,
    required this.totalBytes,
  });

  final int start;
  final int endInclusive;
  final int totalBytes;

  int get length => endInclusive - start + 1;
}

DownloadContentRange? parseDownloadContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;

  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start == null ||
      end == null ||
      total == null ||
      start < 0 ||
      end < start ||
      total <= end) {
    return null;
  }
  return DownloadContentRange(
    start: start,
    endInclusive: end,
    totalBytes: total,
  );
}

int? parseUnsatisfiedDownloadLength(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

class DownloadBlockState {
  DownloadBlockState({
    required this.start,
    required this.endExclusive,
    this.downloadedBytes = 0,
  });

  final int start;
  final int endExclusive;
  int downloadedBytes;

  int get length => endExclusive - start;
  bool get isComplete => downloadedBytes == length;

  Map<String, Object> toJson() => {
    'start': start,
    'endExclusive': endExclusive,
    'downloadedBytes': downloadedBytes,
  };

  static DownloadBlockState? fromJson(Object? value) {
    if (value is! Map) return null;
    final start = value['start'];
    final endExclusive = value['endExclusive'];
    final downloadedBytes = value['downloadedBytes'];
    if (start is! int || endExclusive is! int || downloadedBytes is! int) {
      return null;
    }
    return DownloadBlockState(
      start: start,
      endExclusive: endExclusive,
      downloadedBytes: downloadedBytes,
    );
  }
}

class DownloadCheckpoint {
  const DownloadCheckpoint({
    required this.url,
    required this.totalBytes,
    required this.chunkSize,
    required this.blocks,
    this.etag,
    this.lastModified,
  });

  static const version = 1;

  final String url;
  final int totalBytes;
  final int chunkSize;
  final String? etag;
  final String? lastModified;
  final List<DownloadBlockState> blocks;

  int get downloadedBytes =>
      blocks.fold(0, (total, block) => total + block.downloadedBytes);

  String? get ifRangeValidator {
    final currentEtag = etag;
    if (currentEtag != null &&
        currentEtag.isNotEmpty &&
        !currentEtag.trimLeft().startsWith('W/')) {
      return currentEtag;
    }
    return lastModified;
  }

  bool isValidFor({
    required String currentUrl,
    required int currentTotalBytes,
    required int partFileLength,
    String? currentEtag,
    String? currentLastModified,
  }) {
    if (url != currentUrl ||
        totalBytes != currentTotalBytes ||
        partFileLength != totalBytes ||
        totalBytes < 0 ||
        chunkSize <= 0) {
      return false;
    }

    // A URL and length are not a resource identity. Without a strong ETag or
    // Last-Modified value, the server may have replaced the content with a
    // same-sized file since the checkpoint was written. Restarting is safer
    // than stitching bytes from two different revisions together.
    final validator = ifRangeValidator;
    if (validator == null) return false;

    if (etag != null && etag != currentEtag) return false;
    if (lastModified != null && lastModified != currentLastModified) {
      return false;
    }

    if (totalBytes == 0) return blocks.isEmpty;
    if (blocks.isEmpty) return false;

    var nextStart = 0;
    for (final block in blocks) {
      if (block.start != nextStart ||
          block.endExclusive <= block.start ||
          block.endExclusive > totalBytes ||
          block.downloadedBytes < 0 ||
          block.downloadedBytes > block.length) {
        return false;
      }
      nextStart = block.endExclusive;
    }
    return nextStart == totalBytes;
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'url': url,
    'totalBytes': totalBytes,
    'chunkSize': chunkSize,
    'etag': etag,
    'lastModified': lastModified,
    'blocks': blocks.map((block) => block.toJson()).toList(),
  };

  static DownloadCheckpoint? fromJson(Object? value) {
    if (value is! Map || value['version'] != version) return null;
    final url = value['url'];
    final totalBytes = value['totalBytes'];
    final chunkSize = value['chunkSize'];
    final etag = value['etag'];
    final lastModified = value['lastModified'];
    final rawBlocks = value['blocks'];
    if (url is! String ||
        totalBytes is! int ||
        chunkSize is! int ||
        etag is! String? ||
        lastModified is! String? ||
        rawBlocks is! List) {
      return null;
    }
    final blocks = <DownloadBlockState>[];
    for (final rawBlock in rawBlocks) {
      final block = DownloadBlockState.fromJson(rawBlock);
      if (block == null) return null;
      blocks.add(block);
    }
    return DownloadCheckpoint(
      url: url,
      totalBytes: totalBytes,
      chunkSize: chunkSize,
      etag: etag,
      lastModified: lastModified,
      blocks: blocks,
    );
  }
}

List<DownloadBlockState> createDownloadBlocks(int totalBytes, int chunkSize) {
  if (totalBytes < 0) {
    throw ArgumentError.value(totalBytes, 'totalBytes', 'must not be negative');
  }
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  return [
    for (var start = 0; start < totalBytes; start += chunkSize)
      DownloadBlockState(
        start: start,
        endExclusive: (start + chunkSize).clamp(0, totalBytes),
      ),
  ];
}
