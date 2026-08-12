import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/async_retry.dart';
import 'package:venera/utils/io.dart';

void main() {
  group('comic image filtering', () {
    test('accepts supported extensions case-insensitively', () {
      expect(isSupportedComicImagePath('/comic/001.jpg'), isTrue);
      expect(isSupportedComicImagePath('/comic/002.JPEG'), isTrue);
      expect(isSupportedComicImagePath('/comic/003.WeBp'), isTrue);
    });

    test('rejects non-image and extensionless files', () {
      expect(isSupportedComicImagePath('/comic/ComicInfo.xml'), isFalse);
      expect(isSupportedComicImagePath('/comic/notes.txt'), isFalse);
      expect(isSupportedComicImagePath('/comic/README'), isFalse);
    });
  });

  group('storage path validation', () {
    test('keeps absolute SAF comic directories unchanged', () {
      const directory = 'android://1234-ABCD:Comics/Example';
      final comic = LocalComic(
        id: '1',
        title: 'Example',
        subtitle: '',
        tags: const [],
        directory: directory,
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

      expect(comic.baseDir, directory);
    });

    test('recognizes SAF descendants of primary storage paths', () {
      expect(
        FilePath.isSameOrWithin(
          '/storage/emulated/0/venera',
          'android://primary:venera/downloads',
        ),
        isTrue,
      );
    });

    test('recognizes SAF descendants on removable storage', () {
      expect(
        FilePath.isSameOrWithin(
          'android://1234-ABCD:Venera',
          '/storage/1234-ABCD/Venera/downloads',
        ),
        isTrue,
      );
      expect(
        FilePath.isSameOrWithin(
          'android://1234-ABCD:Venera',
          'android://5678-EFGH:Venera/downloads',
        ),
        isFalse,
      );
    });

    test(
      'confirms a missing comic directory while the library root is reachable',
      () async {
        final libraryRoot = await Directory.systemTemp.createTemp(
          'venera-library-root-',
        );
        addTearDown(() => libraryRoot.delete(recursive: true));
        final comicBaseDir = FilePath.join(libraryRoot.path, 'missing-comic');

        expect(
          await isLocalComicDirectoryDefinitelyMissing(
            comicDirectory: 'missing-comic',
            comicBaseDir: comicBaseDir,
            configuredLibraryPath: libraryRoot.path,
            hasChapters: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'absolute SAF comics do not use an unrelated configured root',
      () async {
        const comicBaseDir = 'android://primary:Comics/Example';
        final checkedPaths = <String>[];

        final isMissing = await isLocalComicDirectoryDefinitelyMissing(
          comicDirectory: comicBaseDir,
          comicBaseDir: comicBaseDir,
          configuredLibraryPath: '/unrelated/library',
          hasChapters: false,
          directoryExists: (path) async {
            checkedPaths.add(path);
            return path == 'android://primary:Comics';
          },
        );

        expect(isMissing, isTrue);
        expect(checkedPaths, ['android://primary:Comics']);
      },
    );
  });

  group('bounded async retry', () {
    test('retries transient failures and then returns the result', () async {
      var calls = 0;
      final waited = <Duration>[];

      final result = await retryAsync<int>(
        (attempt) async {
          calls++;
          if (attempt < 3) throw StateError('temporarily unavailable');
          return 42;
        },
        maxAttempts: 4,
        delayForAttempt: (attempt) => Duration(milliseconds: attempt * 10),
        wait: (delay) async => waited.add(delay),
      );

      expect(result, 42);
      expect(calls, 3);
      expect(waited, const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ]);
    });

    test('rethrows the final error after exhausting attempts', () async {
      final finalError = StateError('still unavailable');
      var calls = 0;

      await expectLater(
        retryAsync<void>(
          (_) async {
            calls++;
            throw finalError;
          },
          maxAttempts: 3,
          delayForAttempt: (_) => Duration.zero,
        ),
        throwsA(same(finalError)),
      );
      expect(calls, 3);
    });

    test('rejects a non-positive attempt limit', () async {
      await expectLater(
        retryAsync<void>((_) async {}, maxAttempts: 0),
        throwsArgumentError,
      );
    });
  });

  test('background directory deletion removes nested contents', () async {
    final root = await Directory.systemTemp.createTemp('venera-delete-test-');
    addTearDown(() => root.delete(recursive: true).catchError((_) => root));
    final comic = await Directory(FilePath.join(root.path, 'comic')).create();
    await File(FilePath.join(comic.path, 'page.jpg')).writeAsBytes([1, 2, 3]);
    final chapter = await Directory(
      FilePath.join(comic.path, 'chapter'),
    ).create();
    await File(FilePath.join(chapter.path, 'page.jpg')).writeAsBytes([4, 5, 6]);

    final errors = await LocalManager.deleteDirectories([comic.path]);

    expect(errors, isEmpty);
    expect(await comic.exists(), isFalse);
  });

  test('isolated directory copy includes nested files', () async {
    final root = await Directory.systemTemp.createTemp('venera-copy-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = await Directory(FilePath.join(root.path, 'source')).create();
    final nested = await Directory(
      FilePath.join(source.path, 'chapter'),
    ).create();
    await File(FilePath.join(source.path, 'cover.jpg')).writeAsBytes([1, 2]);
    await File(FilePath.join(nested.path, 'page.jpg')).writeAsBytes([3, 4]);
    final destination = await Directory(
      FilePath.join(root.path, 'destination'),
    ).create();

    await copyDirectoryIsolate(source, destination);

    expect(
      await File(FilePath.join(destination.path, 'cover.jpg')).readAsBytes(),
      [1, 2],
    );
    expect(
      await File(
        FilePath.join(destination.path, 'chapter', 'page.jpg'),
      ).readAsBytes(),
      [3, 4],
    );
  });
}
