import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_favorite_support.dart';

void main() {
  group('image favorite eligibility', () {
    test('allows a downloaded source comic even when its pages are files', () {
      expect(supportsImageFavorites(isImportedLocalComic: false), isTrue);
    });

    test('continues to reject an imported local comic', () {
      expect(supportsImageFavorites(isImportedLocalComic: true), isFalse);
    });
  });

  group('image favorite cache identity', () {
    test('distinguishes legacy favorites from different pages', () {
      final first = imageFavoriteCacheIdentity(
        imageKey: '',
        sourceKey: 'source',
        comicId: 'comic',
        episodeId: 'episode',
        page: 1,
      );
      final second = imageFavoriteCacheIdentity(
        imageKey: '',
        sourceKey: 'source',
        comicId: 'comic',
        episodeId: 'episode',
        page: 2,
      );

      expect(first, isNot(second));
    });

    test('reads legacy cache only when its image key is unambiguous', () {
      expect(canReadLegacyImageFavoriteCache('image-key'), isTrue);
      expect(canReadLegacyImageFavoriteCache(''), isFalse);
      expect(
        legacyImageFavoriteCacheIdentity(
          imageKey: 'image-key',
          sourceKey: 'source',
          comicId: 'comic',
          episodeId: 'episode',
        ),
        'ImageFavorites image-key@source@comic@episode',
      );
    });

    test('treats empty image data as unavailable', () {
      expect(nonEmptyImageDataOrNull(<int>[]), isNull);
      expect(nonEmptyImageDataOrNull(<int>[1, 2, 3]), [1, 2, 3]);
    });
  });

  group('downloaded favorite lookup', () {
    test('converts a downloaded episode id to a one-based chapter', () {
      expect(
        resolveDownloadedFavoriteChapter(
          hasChapters: true,
          chapterIds: const ['episode-a', 'episode-b'],
          downloadedChapterIds: const ['episode-a', 'episode-b'],
          episodeId: 'episode-a',
        ),
        1,
      );
      expect(
        resolveDownloadedFavoriteChapter(
          hasChapters: true,
          chapterIds: const ['episode-a', 'episode-b'],
          downloadedChapterIds: const ['episode-a', 'episode-b'],
          episodeId: 'episode-b',
        ),
        2,
      );
    });

    test('does not read an undownloaded chapter from a partial download', () {
      expect(
        resolveDownloadedFavoriteChapter(
          hasChapters: true,
          chapterIds: const ['episode-a', 'episode-b'],
          downloadedChapterIds: const ['episode-a'],
          episodeId: 'episode-b',
        ),
        isNull,
      );
      expect(
        resolveDownloadedFavoriteChapter(
          hasChapters: true,
          chapterIds: const ['episode-a'],
          downloadedChapterIds: const ['missing'],
          episodeId: 'missing',
        ),
        isNull,
      );
    });

    test('uses chapter one for a chapterless downloaded comic', () {
      expect(
        resolveDownloadedFavoriteChapter(
          hasChapters: false,
          chapterIds: null,
          downloadedChapterIds: const [],
          episodeId: '0',
        ),
        1,
      );
    });

    test('converts a one-based page and strips only the file scheme', () {
      const images = ['file:///downloads/1.jpg', r'file://C:\downloads\2.jpg'];

      expect(
        resolveLocalFavoriteImagePath(imageKeys: images, page: 1),
        '/downloads/1.jpg',
      );
      expect(
        resolveLocalFavoriteImagePath(imageKeys: images, page: 2),
        r'C:\downloads\2.jpg',
      );
    });

    test('rejects invalid pages and non-file image keys', () {
      expect(
        resolveLocalFavoriteImagePath(
          imageKeys: const ['https://example.com/1.jpg'],
          page: 1,
        ),
        isNull,
      );
      expect(
        resolveLocalFavoriteImagePath(
          imageKeys: const ['file:///downloads/1.jpg'],
          page: 0,
        ),
        isNull,
      );
      expect(
        resolveLocalFavoriteImagePath(
          imageKeys: const ['file:///downloads/1.jpg'],
          page: 2,
        ),
        isNull,
      );
    });
  });

  group('local image fallback', () {
    test('offline mode uses a readable downloaded image', () async {
      var fallbackCalls = 0;

      final image = await loadLocalImageOrFallback<String>(
        loadLocal: () async => 'downloaded image',
        loadFallback: () async {
          fallbackCalls++;
          return 'network image';
        },
      );

      expect(image, 'downloaded image');
      expect(fallbackCalls, 0);
    });

    test('missing local image falls back to the online loader', () async {
      var fallbackCalls = 0;

      final image = await loadLocalImageOrFallback<String>(
        loadLocal: () async => null,
        loadFallback: () async {
          fallbackCalls++;
          return 'network image';
        },
      );

      expect(image, 'network image');
      expect(fallbackCalls, 1);
    });

    test('local storage errors also fall back to the online loader', () async {
      var fallbackCalls = 0;

      final image = await loadLocalImageOrFallback<String>(
        loadLocal: () async => throw StateError('missing'),
        loadFallback: () async {
          fallbackCalls++;
          return 'network image';
        },
      );

      expect(image, 'network image');
      expect(fallbackCalls, 1);
    });

    test('cancellation after local lookup does not start fallback', () async {
      var fallbackCalls = 0;

      await expectLater(
        loadLocalImageOrFallback<String>(
          loadLocal: () async => null,
          afterLocalAttempt: () => throw StateError('cancelled'),
          loadFallback: () async {
            fallbackCalls++;
            return 'network image';
          },
        ),
        throwsStateError,
      );
      expect(fallbackCalls, 0);
    });
  });
}
