import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/repository.dart';

void main() {
  group('repository URL validation', () {
    test('normalizes HTTPS URLs and removes fragments', () {
      expect(
        normalizeComicSourceRepositoryUrl(
          '  HTTPS://Example.COM:443/a/../index.json?channel=stable#section  ',
        ),
        'https://example.com/index.json?channel=stable',
      );
    });

    test('rejects unsafe schemes, credentials, and sensitive queries', () {
      for (final value in <String>[
        'http://example.com/index.json',
        'ftp://example.com/index.json',
        'file:///tmp/index.json',
        'https://user:password@example.com/index.json',
        'https://example.com/index.json?access_token=secret',
        '/relative/index.json',
      ]) {
        expect(
          () => normalizeComicSourceRepositoryUrl(value),
          throwsFormatException,
          reason: value,
        );
      }
    });

    test('compares final download origins including effective ports', () {
      expect(
        sameComicSourceRepositoryOrigin(
          Uri.parse('https://CDN.example/source.js'),
          Uri.parse('https://cdn.example:443/redirected.js'),
        ),
        isTrue,
      );
      expect(
        sameComicSourceRepositoryOrigin(
          Uri.parse('https://cdn.example/source.js'),
          Uri.parse('https://other.example/source.js'),
        ),
        isFalse,
      );
      expect(
        sameComicSourceRepositoryOrigin(
          Uri.parse('https://cdn.example:8443/source.js'),
          Uri.parse('https://cdn.example/source.js'),
        ),
        isFalse,
      );
    });
  });

  group('repository settings migration', () {
    test('migrates a legacy custom repository without adding the default', () {
      final settings = <String, dynamic>{
        'comicSourceListUrl': 'https://catalog.example/custom/index.json',
        'comicSourceRepositories': null,
      };

      expect(migrateComicSourceRepositorySettings(settings), isTrue);

      final repositories = readComicSourceRepositories(
        storedRepositories: settings['comicSourceRepositories'],
        legacyUrl: settings['comicSourceListUrl'],
      );
      expect(repositories, hasLength(1));
      expect(
        repositories.single.indexUrl,
        'https://catalog.example/custom/index.json',
      );
      expect(settings['comicSourceListUrl'], repositories.single.indexUrl);
    });

    test('migrates the retired host to the official repository', () {
      final repositories = readComicSourceRepositories(
        storedRepositories: null,
        legacyUrl: 'https://git.nyne.dev/venera/index.json',
      );

      expect(repositories.single.id, 'official');
      expect(repositories.single.indexUrl, defaultComicSourceRepositoryUrl);
    });

    test('keeps an explicitly empty repository list', () {
      final repositories = readComicSourceRepositories(
        storedRepositories: const [],
        legacyUrl: defaultComicSourceRepositoryUrl,
      );

      expect(repositories, isEmpty);
    });

    test('deduplicates canonical URLs while preserving order', () {
      final first = ComicSourceRepository(
        id: 'first',
        name: 'First',
        indexUrl: 'https://EXAMPLE.com:443/a/../index.json',
        enabled: true,
      );
      final duplicate = ComicSourceRepository(
        id: 'second',
        name: 'Second',
        indexUrl: 'https://example.com/index.json#ignored',
        enabled: true,
      );

      final normalized = normalizeComicSourceRepositories([first, duplicate]);

      expect(normalized, hasLength(1));
      expect(normalized.single.id, 'first');
      expect(normalized.single.indexUrl, 'https://example.com/index.json');
    });

    test('a rejected id collision does not poison a later valid URL', () {
      final normalized = normalizeComicSourceRepositories(const [
        ComicSourceRepository(
          id: 'shared',
          name: 'First',
          indexUrl: 'https://first.example/index.json',
          enabled: true,
        ),
        ComicSourceRepository(
          id: 'shared',
          name: 'Rejected',
          indexUrl: 'https://second.example/index.json',
          enabled: true,
        ),
        ComicSourceRepository(
          id: 'accepted',
          name: 'Accepted',
          indexUrl: 'https://second.example/index.json',
          enabled: true,
        ),
      ]);

      expect(normalized.map((repository) => repository.id), [
        'shared',
        'accepted',
      ]);
    });

    test('honors a legacy URL changed by an older app', () {
      final settings = <String, dynamic>{
        'comicSourceListUrl': 'https://new.example/index.json',
        'comicSourceRepositoriesLegacyMirror': 'https://old.example/index.json',
        'comicSourceRepositories': <Map<String, dynamic>>[
          const ComicSourceRepository(
            id: 'old',
            name: 'Old',
            indexUrl: 'https://old.example/index.json',
            enabled: true,
          ).toJson(),
        ],
      };

      expect(migrateComicSourceRepositorySettings(settings), isTrue);
      final repositories = readComicSourceRepositories(
        storedRepositories: settings['comicSourceRepositories'],
        legacyUrl: settings['comicSourceListUrl'],
      );
      expect(repositories, hasLength(1));
      expect(repositories.single.indexUrl, 'https://new.example/index.json');
      expect(
        settings['comicSourceRepositoriesLegacyMirror'],
        'https://new.example/index.json',
      );
    });

    test('preserves a safe legacy HTTP URL for manual review', () {
      final settings = <String, dynamic>{
        'comicSourceListUrl': 'http://legacy.example/index.json',
        'comicSourceRepositories': null,
      };

      expect(migrateComicSourceRepositorySettings(settings), isTrue);
      expect(
        settings['comicSourceLegacyUrlNeedsReview'],
        'http://legacy.example/index.json',
      );
      expect(
        (settings['comicSourceRepositories'] as List).single['indexUrl'],
        defaultComicSourceRepositoryUrl,
      );
      expect(migrateComicSourceRepositorySettings(settings), isFalse);
      expect(
        settings['comicSourceLegacyUrlNeedsReview'],
        'http://legacy.example/index.json',
      );
    });
  });

  group('repository manifest parsing', () {
    const repository = ComicSourceRepository(
      id: 'repo',
      name: 'Example catalog',
      indexUrl: 'https://example.com/catalog/index.json',
      enabled: true,
    );

    test('supports fileName and filename and resolves against final URI', () {
      final snapshot = parseComicSourceRepositoryManifest(
        jsonEncode([
          {
            'name': 'One',
            'key': 'one',
            'version': '1.2.3',
            'fileName': 'scripts/one.js',
          },
          {
            'name': 'Two',
            'key': 'two_2',
            'version': '2.0.0-hotfix',
            'filename': '../two.js',
          },
        ]),
        repository: repository,
        finalIndexUri: Uri.parse(
          'https://cdn.example.com/catalog/v2/index.json?mirror=1',
        ),
      );

      expect(snapshot.invalidEntryCount, 0);
      expect(snapshot.entries, hasLength(2));
      expect(
        snapshot.entries[0].downloadUrl,
        'https://cdn.example.com/catalog/v2/scripts/one.js',
      );
      expect(
        snapshot.entries[1].downloadUrl,
        'https://cdn.example.com/catalog/two.js',
      );
      expect(snapshot.entries[0].repositoryName, 'Example catalog');
    });

    test('isolates invalid entries without hiding valid entries', () {
      final snapshot = parseComicSourceRepositoryManifest(
        jsonEncode([
          {
            'name': 'Valid',
            'key': 'valid',
            'version': '1.0.0',
            'fileName': 'valid.js',
          },
          {'name': 'Missing fields'},
          {
            'name': 'Conflict',
            'key': 'conflict',
            'version': '1.0.0',
            'fileName': 'a.js',
            'filename': 'b.js',
          },
          {
            'name': 'Unsafe',
            'key': 'unsafe',
            'version': '1.0.0',
            'url': 'http://example.com/unsafe.js',
          },
          {
            'name': 'Too verbose',
            'key': 'verbose',
            'version': '1.0.0',
            'fileName': 'verbose.js',
            'description': List<String>.filled(
              maxComicSourceDescriptionLength + 1,
              'x',
            ).join(),
          },
        ]),
        repository: repository,
        finalIndexUri: Uri.parse(repository.indexUrl),
      );

      expect(snapshot.entries.single.key, 'valid');
      expect(snapshot.invalidEntryCount, 4);
    });

    test('rejects a non-list root and oversized manifests', () {
      expect(
        () => parseComicSourceRepositoryManifest(
          '{}',
          repository: repository,
          finalIndexUri: Uri.parse(repository.indexUrl),
        ),
        throwsA(isA<ComicSourceRepositoryException>()),
      );
      expect(
        () => parseComicSourceRepositoryManifest(
          List<String>.filled(maxComicSourceManifestBytes + 1, 'x').join(),
          repository: repository,
          finalIndexUri: Uri.parse(repository.indexUrl),
        ),
        throwsA(isA<ComicSourceRepositoryException>()),
      );
    });
  });

  test(
    'loads enabled repositories independently and keeps input order',
    () async {
      final requested = <String>[];
      final repositories = <ComicSourceRepository>[
        const ComicSourceRepository(
          id: 'first',
          name: 'First',
          indexUrl: 'https://first.example/index.json',
          enabled: true,
        ),
        const ComicSourceRepository(
          id: 'disabled',
          name: 'Disabled',
          indexUrl: 'https://disabled.example/index.json',
          enabled: false,
        ),
        const ComicSourceRepository(
          id: 'broken',
          name: 'Broken',
          indexUrl: 'https://broken.example/index.json',
          enabled: true,
        ),
        const ComicSourceRepository(
          id: 'last',
          name: 'Last',
          indexUrl: 'https://last.example/index.json',
          enabled: true,
        ),
      ];
      final service = ComicSourceRepositoryService(
        fetcher: (uri, _) async {
          requested.add(uri.host);
          if (uri.host == 'broken.example') {
            throw const ComicSourceRepositoryException('offline');
          }
          final key = uri.host.split('.').first;
          return ComicSourceRepositoryDocument(
            text: jsonEncode([
              {
                'name': key,
                'key': key,
                'version': '1.0.0',
                'fileName': '$key.js',
              },
            ]),
            finalUri: uri,
          );
        },
      );

      final catalog = await service.load(repositories);

      expect(requested, isNot(contains('disabled.example')));
      expect(catalog.snapshots.map((value) => value.repository.id), [
        'first',
        'last',
      ]);
      expect(catalog.entries.map((value) => value.key), ['first', 'last']);
      expect(catalog.failures.single.repository.id, 'broken');
    },
  );

  group('update selection', () {
    const officialEntry = ComicSourceManifestEntry(
      repositoryId: 'official',
      repositoryName: 'Official',
      repositoryIndexUrl: 'https://repo.example/index.json',
      name: 'Example',
      key: 'example',
      version: '1.2.0',
      downloadUrl: 'https://repo.example/example.js',
    );
    const conflictingEntry = ComicSourceManifestEntry(
      repositoryId: 'other',
      repositoryName: 'Other',
      repositoryIndexUrl: 'https://other.example/index.json',
      name: 'Example fork',
      key: 'example',
      version: '9.0.0',
      downloadUrl: 'https://other.example/example.js',
    );

    test('selects only the exact bound repository and URL', () {
      final updates = selectComicSourceUpdates(
        installedSources: const [
          InstalledComicSourceVersion(
            key: 'example',
            version: '1.0.0',
            updateUrl: 'https://self.example/example.js',
            repositoryId: 'official',
            boundDownloadUrl: 'https://repo.example/example.js',
          ),
        ],
        entries: const [conflictingEntry, officialEntry],
      );

      expect(updates['example'], same(officialEntry));
    });

    test('does not allow a different repository to take over a key', () {
      final updates = selectComicSourceUpdates(
        installedSources: const [
          InstalledComicSourceVersion(
            key: 'example',
            version: '1.0.0',
            updateUrl: 'https://repo.example/example.js',
          ),
        ],
        entries: const [conflictingEntry],
      );

      expect(updates, isEmpty);
    });

    test('ignores invalid or non-newer versions', () {
      expect(parseComicSourceVersion('1.0'), isNull);
      final updates = selectComicSourceUpdates(
        installedSources: const [
          InstalledComicSourceVersion(
            key: 'example',
            version: '2.0.0',
            updateUrl: 'https://repo.example/example.js',
          ),
        ],
        entries: const [officialEntry],
      );
      expect(updates, isEmpty);
    });
  });
}
