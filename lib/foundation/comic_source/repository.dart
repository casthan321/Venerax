import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/network_log.dart';

const defaultComicSourceRepositoryUrl =
    'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json';
const defaultComicSourceRepositoryName = 'Venera Official';

const _retiredRepositoryHost = 'git.nyne.dev';
const _maxRepositoryUrlLength = 2048;
const maxComicSourceManifestBytes = 1024 * 1024;
const maxComicSourceScriptBytes = 2 * 1024 * 1024;
const maxComicSourceManifestEntries = 1000;
const maxComicSourceDescriptionLength = 1000;

@immutable
class ComicSourceRepository {
  const ComicSourceRepository({
    required this.id,
    required this.name,
    required this.indexUrl,
    required this.enabled,
  });

  final String id;
  final String name;
  final String indexUrl;
  final bool enabled;

  Uri get indexUri => Uri.parse(indexUrl);

  ComicSourceRepository copyWith({
    String? id,
    String? name,
    String? indexUrl,
    bool? enabled,
  }) {
    return ComicSourceRepository(
      id: id ?? this.id,
      name: name ?? this.name,
      indexUrl: indexUrl ?? this.indexUrl,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'indexUrl': indexUrl,
    'enabled': enabled,
  };

  static ComicSourceRepository? tryParse(Object? value) {
    if (value is! Map) return null;
    final rawUrl = value['indexUrl'] ?? value['url'];
    if (rawUrl is! String) return null;
    try {
      final normalizedUrl = normalizeComicSourceRepositoryUrl(rawUrl);
      final rawName = value['name'];
      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : repositoryNameFromUrl(normalizedUrl);
      final rawId = value['id'];
      final id = rawId is String && _repositoryIdPattern.hasMatch(rawId)
          ? rawId
          : comicSourceRepositoryId(normalizedUrl);
      return ComicSourceRepository(
        id: id,
        name: name,
        indexUrl: normalizedUrl,
        enabled: value['enabled'] is bool ? value['enabled'] as bool : true,
      );
    } on FormatException {
      return null;
    }
  }
}

final _repositoryIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

String comicSourceRepositoryId(String normalizedUrl) =>
    'repo_${sha256.convert(utf8.encode(normalizedUrl)).toString().substring(0, 16)}';

String repositoryNameFromUrl(String url) {
  final uri = Uri.parse(url);
  return uri.host.isEmpty ? 'Repository' : uri.host;
}

String normalizeComicSourceRepositoryUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty || trimmed.length > _maxRepositoryUrlLength) {
    throw const FormatException('Invalid repository URL');
  }
  if (trimmed.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const FormatException('Invalid repository URL');
  }
  // Dart's URI parser only recognizes an authority for lower-case schemes,
  // while URI schemes are case-insensitive by specification.
  final parseInput = trimmed.replaceFirst(
    RegExp(r'^https:', caseSensitive: false),
    'https:',
  );
  final parsed = Uri.tryParse(parseInput);
  if (parsed == null ||
      !parsed.hasScheme ||
      parsed.scheme.toLowerCase() != 'https' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty) {
    throw const FormatException(
      'Repository URL must be an HTTPS URL without credentials',
    );
  }
  if (networkUriContainsSecrets(parsed)) {
    throw const FormatException('Repository URL must not contain credentials');
  }

  final normalizedPath = parsed.normalizePath();
  final normalized = Uri(
    scheme: 'https',
    host: normalizedPath.host.toLowerCase(),
    port: normalizedPath.hasPort && normalizedPath.port != 443
        ? normalizedPath.port
        : null,
    pathSegments: normalizedPath.pathSegments,
    query: normalizedPath.hasQuery ? normalizedPath.query : null,
  );
  final value = normalized.toString();
  if (value.length > _maxRepositoryUrlLength) {
    throw const FormatException('Repository URL is too long');
  }
  return value;
}

bool sameComicSourceRepositoryOrigin(Uri first, Uri second) {
  int effectivePort(Uri uri) => uri.hasPort ? uri.port : 443;
  return first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      effectivePort(first) == effectivePort(second);
}

String migrateRetiredComicSourceRepositoryUrl(String input) {
  final parsed = Uri.tryParse(input.trim());
  if (parsed != null && parsed.host.toLowerCase() == _retiredRepositoryHost) {
    return defaultComicSourceRepositoryUrl;
  }
  return input;
}

List<ComicSourceRepository> readComicSourceRepositories({
  required Object? storedRepositories,
  required Object? legacyUrl,
}) {
  if (storedRepositories is List) {
    return _deduplicateRepositories(
      storedRepositories
          .map(ComicSourceRepository.tryParse)
          .whereType<ComicSourceRepository>(),
    );
  }

  final legacy = legacyUrl is String
      ? migrateRetiredComicSourceRepositoryUrl(legacyUrl)
      : defaultComicSourceRepositoryUrl;
  try {
    final normalized = normalizeComicSourceRepositoryUrl(legacy);
    return <ComicSourceRepository>[
      ComicSourceRepository(
        id: normalized == defaultComicSourceRepositoryUrl
            ? 'official'
            : comicSourceRepositoryId(normalized),
        name: normalized == defaultComicSourceRepositoryUrl
            ? defaultComicSourceRepositoryName
            : repositoryNameFromUrl(normalized),
        indexUrl: normalized,
        enabled: true,
      ),
    ];
  } on FormatException {
    return const <ComicSourceRepository>[
      ComicSourceRepository(
        id: 'official',
        name: defaultComicSourceRepositoryName,
        indexUrl: defaultComicSourceRepositoryUrl,
        enabled: true,
      ),
    ];
  }
}

bool migrateComicSourceRepositorySettings(Map<String, dynamic> settings) {
  var storedRepositories = settings['comicSourceRepositories'];
  final originallyMigratingLegacy = storedRepositories is! List;
  final legacyUrl = settings['comicSourceListUrl'];
  final legacyMirror = settings['comicSourceRepositoriesLegacyMirror'];
  if (storedRepositories is List &&
      legacyUrl is String &&
      legacyMirror is String) {
    try {
      final normalizedLegacy = normalizeComicSourceRepositoryUrl(legacyUrl);
      final normalizedMirror = normalizeComicSourceRepositoryUrl(legacyMirror);
      if (normalizedLegacy != normalizedMirror) {
        // An older app only knows comicSourceListUrl. If it changed that field
        // while preserving the unknown list field, treat the legacy edit as a
        // deliberate single-repository configuration instead of discarding it.
        storedRepositories = null;
      }
    } on FormatException {
      // Invalid legacy edits cannot replace a validated repository list.
    }
  }
  final repositories = readComicSourceRepositories(
    storedRepositories: storedRepositories,
    legacyUrl: legacyUrl,
  );
  final encoded = repositories
      .map((repository) => repository.toJson())
      .toList(growable: false);
  final legacy = legacyComicSourceRepositoryUrl(repositories);
  final existingLegacyReview = settings['comicSourceLegacyUrlNeedsReview'];
  final legacyUrlForReview = originallyMigratingLegacy && legacyUrl is String
      ? _legacyRepositoryUrlForReview(legacyUrl)
      : existingLegacyReview is String
      ? _legacyRepositoryUrlForReview(existingLegacyReview)
      : null;
  final stored = settings['comicSourceRepositories'];
  final changed =
      stored is! List ||
      jsonEncode(stored) != jsonEncode(encoded) ||
      settings['comicSourceListUrl'] != legacy ||
      settings['comicSourceRepositoriesLegacyMirror'] != legacy ||
      settings['comicSourceLegacyUrlNeedsReview'] != legacyUrlForReview;
  settings['comicSourceRepositories'] = encoded;
  settings['comicSourceListUrl'] = legacy;
  settings['comicSourceRepositoriesLegacyMirror'] = legacy;
  settings['comicSourceLegacyUrlNeedsReview'] = legacyUrlForReview;
  return changed;
}

String? _legacyRepositoryUrlForReview(String value) {
  final trimmed = value.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null ||
      parsed.scheme.toLowerCase() != 'http' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      networkUriContainsSecrets(parsed)) {
    return null;
  }
  return trimmed.length <= _maxRepositoryUrlLength ? trimmed : null;
}

List<ComicSourceRepository> normalizeComicSourceRepositories(
  Iterable<ComicSourceRepository> repositories,
) {
  final normalized = <ComicSourceRepository>[];
  for (final repository in repositories) {
    final url = normalizeComicSourceRepositoryUrl(repository.indexUrl);
    final name = repository.name.trim().isEmpty
        ? repositoryNameFromUrl(url)
        : repository.name.trim();
    normalized.add(
      repository.copyWith(
        id: _repositoryIdPattern.hasMatch(repository.id)
            ? repository.id
            : comicSourceRepositoryId(url),
        name: name,
        indexUrl: url,
      ),
    );
  }
  return _deduplicateRepositories(normalized);
}

List<ComicSourceRepository> _deduplicateRepositories(
  Iterable<ComicSourceRepository> repositories,
) {
  final seenUrls = <String>{};
  final seenIds = <String>{};
  final result = <ComicSourceRepository>[];
  for (final repository in repositories) {
    if (seenUrls.contains(repository.indexUrl) ||
        seenIds.contains(repository.id)) {
      continue;
    }
    seenUrls.add(repository.indexUrl);
    seenIds.add(repository.id);
    result.add(repository);
  }
  return result;
}

String legacyComicSourceRepositoryUrl(
  Iterable<ComicSourceRepository> repositories,
) {
  final list = repositories.toList(growable: false);
  if (list.isEmpty) return defaultComicSourceRepositoryUrl;
  for (final repository in list) {
    if (repository.enabled) return repository.indexUrl;
  }
  return list.first.indexUrl;
}

@immutable
class ComicSourceManifestEntry {
  const ComicSourceManifestEntry({
    required this.repositoryId,
    required this.repositoryName,
    required this.repositoryIndexUrl,
    required this.name,
    required this.key,
    required this.version,
    required this.downloadUrl,
    this.description,
  });

  final String repositoryId;
  final String repositoryName;
  final String repositoryIndexUrl;
  final String name;
  final String key;
  final String version;
  final String downloadUrl;
  final String? description;
}

@immutable
class ComicSourceRepositorySnapshot {
  const ComicSourceRepositorySnapshot({
    required this.repository,
    required this.finalIndexUrl,
    required this.entries,
    required this.invalidEntryCount,
  });

  final ComicSourceRepository repository;
  final String finalIndexUrl;
  final List<ComicSourceManifestEntry> entries;
  final int invalidEntryCount;
}

@immutable
class ComicSourceRepositoryFailure {
  const ComicSourceRepositoryFailure({
    required this.repository,
    required this.message,
  });

  final ComicSourceRepository repository;
  final String message;
}

@immutable
class ComicSourceRepositoryCatalog {
  const ComicSourceRepositoryCatalog({
    required this.snapshots,
    required this.failures,
  });

  final List<ComicSourceRepositorySnapshot> snapshots;
  final List<ComicSourceRepositoryFailure> failures;

  List<ComicSourceManifestEntry> get entries =>
      snapshots.expand((snapshot) => snapshot.entries).toList(growable: false);
}

@immutable
class ComicSourceRepositoryDocument {
  const ComicSourceRepositoryDocument({
    required this.text,
    required this.finalUri,
  });

  final String text;
  final Uri finalUri;
}

class ComicSourceRepositoryException implements Exception {
  const ComicSourceRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef ComicSourceRepositoryFetcher =
    Future<ComicSourceRepositoryDocument> Function(Uri uri, int maxBytes);

class ComicSourceRepositoryService {
  const ComicSourceRepositoryService({this.fetcher = fetchComicSourceDocument});

  final ComicSourceRepositoryFetcher fetcher;

  Future<ComicSourceRepositoryCatalog> load(
    Iterable<ComicSourceRepository> repositories,
  ) async {
    final enabled = repositories
        .where((repository) => repository.enabled)
        .toList(growable: false);
    if (enabled.isEmpty) {
      return const ComicSourceRepositoryCatalog(snapshots: [], failures: []);
    }

    final outcomes = List<_RepositoryLoadOutcome?>.filled(enabled.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < enabled.length) {
        final index = nextIndex++;
        final repository = enabled[index];
        try {
          final document = await fetcher(
            repository.indexUri,
            maxComicSourceManifestBytes,
          );
          outcomes[index] = _RepositoryLoadOutcome.snapshot(
            parseComicSourceRepositoryManifest(
              document.text,
              repository: repository,
              finalIndexUri: document.finalUri,
            ),
          );
        } catch (error) {
          outcomes[index] = _RepositoryLoadOutcome.failure(
            ComicSourceRepositoryFailure(
              repository: repository,
              message: error is ComicSourceRepositoryException
                  ? error.message
                  : 'Failed to load repository',
            ),
          );
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(math.min(4, enabled.length), (_) => worker()),
    );
    return ComicSourceRepositoryCatalog(
      snapshots: outcomes
          .map((outcome) => outcome?.snapshot)
          .whereType<ComicSourceRepositorySnapshot>()
          .toList(growable: false),
      failures: outcomes
          .map((outcome) => outcome?.failure)
          .whereType<ComicSourceRepositoryFailure>()
          .toList(growable: false),
    );
  }
}

class _RepositoryLoadOutcome {
  const _RepositoryLoadOutcome({this.snapshot, this.failure});

  factory _RepositoryLoadOutcome.snapshot(
    ComicSourceRepositorySnapshot snapshot,
  ) => _RepositoryLoadOutcome(snapshot: snapshot);

  factory _RepositoryLoadOutcome.failure(
    ComicSourceRepositoryFailure failure,
  ) => _RepositoryLoadOutcome(failure: failure);

  final ComicSourceRepositorySnapshot? snapshot;
  final ComicSourceRepositoryFailure? failure;
}

ComicSourceRepositorySnapshot parseComicSourceRepositoryManifest(
  String text, {
  required ComicSourceRepository repository,
  required Uri finalIndexUri,
}) {
  if (utf8.encode(text).length > maxComicSourceManifestBytes) {
    throw const ComicSourceRepositoryException('Repository index is too large');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const ComicSourceRepositoryException('Invalid repository JSON');
  }
  if (decoded is! List) {
    throw const ComicSourceRepositoryException(
      'Repository index must contain a JSON list',
    );
  }
  if (decoded.length > maxComicSourceManifestEntries) {
    throw const ComicSourceRepositoryException(
      'Repository contains too many entries',
    );
  }

  final entries = <ComicSourceManifestEntry>[];
  var invalidEntryCount = 0;
  for (final rawEntry in decoded) {
    try {
      entries.add(
        _parseManifestEntry(
          rawEntry,
          repository: repository,
          finalIndexUri: finalIndexUri,
        ),
      );
    } on ComicSourceRepositoryException {
      invalidEntryCount++;
    }
  }
  return ComicSourceRepositorySnapshot(
    repository: repository,
    finalIndexUrl: normalizeComicSourceRepositoryUrl(finalIndexUri.toString()),
    entries: List.unmodifiable(entries),
    invalidEntryCount: invalidEntryCount,
  );
}

ComicSourceManifestEntry _parseManifestEntry(
  Object? value, {
  required ComicSourceRepository repository,
  required Uri finalIndexUri,
}) {
  if (value is! Map) {
    throw const ComicSourceRepositoryException('Invalid repository entry');
  }
  final name = value['name'];
  final key = value['key'];
  final version = value['version'];
  if (name is! String ||
      name.trim().isEmpty ||
      name.length > 200 ||
      key is! String ||
      key.length > 80 ||
      !RegExp(r'^[A-Za-z0-9_]+$').hasMatch(key) ||
      version is! String ||
      version.length > 80 ||
      parseComicSourceVersion(version) == null) {
    throw const ComicSourceRepositoryException('Invalid repository entry');
  }

  final fileNameCamel = value['fileName'];
  final fileNameLower = value['filename'];
  if (fileNameCamel != null &&
      fileNameLower != null &&
      fileNameCamel.toString() != fileNameLower.toString()) {
    throw const ComicSourceRepositoryException(
      'Conflicting fileName and filename fields',
    );
  }
  final fileName = fileNameCamel ?? fileNameLower;
  final explicitUrl = value['url'];
  if ((fileName == null && explicitUrl == null) ||
      (fileName != null && explicitUrl != null) ||
      (fileName != null && fileName is! String) ||
      (explicitUrl != null && explicitUrl is! String)) {
    throw const ComicSourceRepositoryException('Invalid source download URL');
  }
  final relativeOrAbsolute = (explicitUrl ?? fileName) as String;
  if (relativeOrAbsolute.trim().isEmpty || relativeOrAbsolute.length > 2048) {
    throw const ComicSourceRepositoryException('Invalid source download URL');
  }
  final resolved = finalIndexUri.resolve(relativeOrAbsolute.trim());
  late final String normalizedDownloadUrl;
  try {
    normalizedDownloadUrl = normalizeComicSourceRepositoryUrl(
      resolved.toString(),
    );
  } on FormatException {
    throw const ComicSourceRepositoryException('Invalid source download URL');
  }

  final description = value['description'];
  if (description is String &&
      description.length > maxComicSourceDescriptionLength) {
    throw const ComicSourceRepositoryException(
      'Comic source description is too long',
    );
  }
  return ComicSourceManifestEntry(
    repositoryId: repository.id,
    repositoryName: repository.name,
    repositoryIndexUrl: repository.indexUrl,
    name: name.trim(),
    key: key,
    version: version.trim(),
    downloadUrl: normalizedDownloadUrl,
    description: description is String && description.trim().isNotEmpty
        ? description.trim()
        : null,
  );
}

@immutable
class ParsedComicSourceVersion implements Comparable<ParsedComicSourceVersion> {
  const ParsedComicSourceVersion(
    this.major,
    this.minor,
    this.patch,
    this.suffix,
  );

  final int major;
  final int minor;
  final int patch;
  final String? suffix;

  @override
  int compareTo(ParsedComicSourceVersion other) {
    for (final comparison in <int>[
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (comparison != 0) return comparison;
    }
    if (suffix == other.suffix) return 0;
    if (suffix == null) return other.suffix == 'hotfix' ? -1 : 1;
    if (other.suffix == null) return suffix == 'hotfix' ? 1 : -1;
    return suffix!.compareTo(other.suffix!);
  }
}

ParsedComicSourceVersion? parseComicSourceVersion(String value) {
  final match = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:[-.]([A-Za-z0-9][A-Za-z0-9.-]*))?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final major = int.tryParse(match.group(1)!);
  final minor = int.tryParse(match.group(2)!);
  final patch = int.tryParse(match.group(3)!);
  if (major == null || minor == null || patch == null) return null;
  return ParsedComicSourceVersion(major, minor, patch, match.group(4));
}

@immutable
class InstalledComicSourceVersion {
  const InstalledComicSourceVersion({
    required this.key,
    required this.version,
    required this.updateUrl,
    this.repositoryId,
    this.boundDownloadUrl,
  });

  final String key;
  final String version;
  final String updateUrl;
  final String? repositoryId;
  final String? boundDownloadUrl;
}

Map<String, ComicSourceManifestEntry> selectComicSourceUpdates({
  required Iterable<InstalledComicSourceVersion> installedSources,
  required Iterable<ComicSourceManifestEntry> entries,
}) {
  final entriesByKey = <String, List<ComicSourceManifestEntry>>{};
  for (final entry in entries) {
    entriesByKey.putIfAbsent(entry.key, () => []).add(entry);
  }
  final updates = <String, ComicSourceManifestEntry>{};
  for (final installed in installedSources) {
    final currentVersion = parseComicSourceVersion(installed.version);
    if (currentVersion == null) continue;
    final candidates = entriesByKey[installed.key] ?? const [];
    String? expectedUrl;
    try {
      expectedUrl = normalizeComicSourceRepositoryUrl(
        installed.boundDownloadUrl?.isNotEmpty == true
            ? installed.boundDownloadUrl!
            : installed.updateUrl,
      );
    } on FormatException {
      continue;
    }
    ComicSourceManifestEntry? selected;
    ParsedComicSourceVersion? selectedVersion;
    for (final candidate in candidates) {
      if (candidate.downloadUrl != expectedUrl) continue;
      if (installed.repositoryId != null &&
          candidate.repositoryId != installed.repositoryId) {
        continue;
      }
      final candidateVersion = parseComicSourceVersion(candidate.version);
      if (candidateVersion == null ||
          candidateVersion.compareTo(currentVersion) <= 0) {
        continue;
      }
      if (selectedVersion == null ||
          candidateVersion.compareTo(selectedVersion) > 0) {
        selected = candidate;
        selectedVersion = candidateVersion;
      }
    }
    if (selected != null) updates[installed.key] = selected;
  }
  return updates;
}

Future<ComicSourceRepositoryDocument> fetchComicSourceDocument(
  Uri initialUri,
  int maxBytes,
) async {
  final initialUrl = normalizeComicSourceRepositoryUrl(initialUri.toString());
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (status) =>
          status != null && status >= 200 && status < 400,
    ),
  );
  dio.httpClientAdapter = RHttpAdapter(forceVerifyCertificates: true);
  var current = Uri.parse(initialUrl);
  final visited = <String>{};
  try {
    for (var redirects = 0; redirects <= 5; redirects++) {
      final canonical = normalizeComicSourceRepositoryUrl(current.toString());
      if (!visited.add(canonical)) {
        throw const ComicSourceRepositoryException('Repository redirect loop');
      }
      final response = await dio.getUri<ResponseBody>(
        current,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          headers: const <String, dynamic>{
            'accept': 'application/json, text/plain, application/javascript',
            'cache-control': 'no-cache',
          },
        ),
      );
      final responseBody = response.data;
      try {
        final status = response.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          if (redirects == 5) {
            throw const ComicSourceRepositoryException(
              'Too many repository redirects',
            );
          }
          final location = response.headers.value('location');
          if (location == null || location.trim().isEmpty) {
            throw const ComicSourceRepositoryException(
              'Invalid repository redirect',
            );
          }
          final next = current.resolve(location.trim());
          try {
            current = Uri.parse(
              normalizeComicSourceRepositoryUrl(next.toString()),
            );
          } on FormatException {
            throw const ComicSourceRepositoryException(
              'Unsafe repository redirect',
            );
          }
          continue;
        }
        if (status != 200 || responseBody == null) {
          throw ComicSourceRepositoryException(
            'Repository returned HTTP $status',
          );
        }
        final declaredLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        if (declaredLength != null && declaredLength > maxBytes) {
          throw const ComicSourceRepositoryException(
            'Repository file is too large',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in responseBody.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const ComicSourceRepositoryException(
              'Repository file is too large',
            );
          }
          bytes.add(chunk);
        }
        try {
          return ComicSourceRepositoryDocument(
            text: utf8.decode(bytes.takeBytes()),
            finalUri: current,
          );
        } on FormatException {
          throw const ComicSourceRepositoryException(
            'Repository file is not valid UTF-8',
          );
        }
      } finally {
        // ignore: invalid_use_of_internal_member
        responseBody?.close();
      }
    }
    throw const ComicSourceRepositoryException('Too many repository redirects');
  } on DioException catch (error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      throw const ComicSourceRepositoryException(
        'Repository request timed out',
      );
    }
    throw const ComicSourceRepositoryException('Repository network error');
  } finally {
    dio.close(force: true);
  }
}
