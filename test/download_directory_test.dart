import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/download_directory.dart';
import 'package:venera/utils/io.dart';

void main() {
  const identity = DownloadDirectoryIdentity(
    sourceKey: 'example_source',
    comicId: 'comic-42',
  );

  test('cancel paths use normalized chapter directory names', () {
    final paths = downloadChapterDirectoryPaths(
      FilePath.join('downloads', 'comic'),
      const ['chapter/1', r'chapter\1', 'chapter:2'],
      directoryNameForChapter: (key) =>
          key.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_'),
    );

    expect(paths, [
      FilePath.join('downloads', 'comic', 'chapter_1'),
      FilePath.join('downloads', 'comic', 'chapter_2'),
    ]);
  });

  test('cancel preserves chapters downloaded before the task', () {
    String normalize(String key) => key.replaceAll(RegExp(r'[/\\]'), '_');

    final cancellable = cancellableDownloadChapterKeys(
      requestedChapterKeys: const [
        'already-downloaded',
        'new/chapter',
        r'protected\chapter',
      ],
      previouslyDownloadedChapterKeys: const [
        'already-downloaded',
        'protected/chapter',
      ],
      directoryNameForChapter: normalize,
    );

    // The differently spelled protected chapter resolves to the same on-disk
    // directory and therefore must not be deleted either.
    expect(cancellable, ['new/chapter']);
  });

  test('atomically commits an image and removes its temporary file', () async {
    final root = await Directory.systemTemp.createTemp('venera-atomic-image-');
    addTearDown(() => root.delete(recursive: true));
    final destination = root.joinFile('0.jpg');
    final temporary = root.joinFile(downloadPartialImageFileName(0, '.jpg'));

    final committed = await writeDownloadedImageAtomically(
      temporaryFile: temporary,
      destinationFile: destination,
      bytes: const [1, 2, 3],
      isCancelled: () => false,
    );

    expect(committed, isTrue);
    expect(await destination.readAsBytes(), [1, 2, 3]);
    expect(await temporary.exists(), isFalse);
  });

  test(
    'a cancelled atomic write leaves neither final nor partial data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera-cancel-image-',
      );
      addTearDown(() => root.delete(recursive: true));
      final destination = root.joinFile('0.jpg');
      final temporary = root.joinFile(downloadPartialImageFileName(0, '.jpg'));

      final committed = await writeDownloadedImageAtomically(
        temporaryFile: temporary,
        destinationFile: destination,
        bytes: const [1, 2, 3],
        isCancelled: () => true,
      );

      expect(committed, isFalse);
      expect(await destination.exists(), isFalse);
      expect(await temporary.exists(), isFalse);
    },
  );

  test('download identity round trips and rejects malformed markers', () {
    expect(DownloadDirectoryIdentity.decode(identity.encode()), identity);
    expect(DownloadDirectoryIdentity.decode([1, 2, 3]), isNull);
  });

  test('only a directory with an exact identity marker is reused', () async {
    final root = await Directory.systemTemp.createTemp('venera-recovery-');
    addTearDown(() => root.delete(recursive: true));
    final unmarked = await Directory(
      FilePath.join(root.path, 'Same title'),
    ).create();
    await File(FilePath.join(unmarked.path, '0.jpg')).writeAsBytes([1]);
    final mismatched = await Directory(
      FilePath.join(root.path, 'Same title(1)'),
    ).create();
    await ensureDownloadDirectoryIdentity(
      mismatched,
      const DownloadDirectoryIdentity(
        sourceKey: 'another_source',
        comicId: 'comic-42',
      ),
    );
    final matching = await Directory(
      FilePath.join(root.path, 'Same title(2)'),
    ).create();
    await ensureDownloadDirectoryIdentity(matching, identity);

    final reusable = await findReusableDownloadDirectory(root, identity);

    expect(reusable?.path, matching.path);
  });

  test('an existing marker is never overwritten by another comic', () async {
    final root = await Directory.systemTemp.createTemp('venera-marker-');
    addTearDown(() => root.delete(recursive: true));
    await ensureDownloadDirectoryIdentity(root, identity);
    final marker = File(FilePath.join(root.path, downloadDirectoryMarkerName));
    final originalBytes = await marker.readAsBytes();

    await expectLater(
      ensureDownloadDirectoryIdentity(
        root,
        const DownloadDirectoryIdentity(
          sourceKey: 'example_source',
          comicId: 'different-comic',
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await marker.readAsBytes(), originalBytes);
  });

  test('page scan reuses complete pages and cleans incomplete files', () async {
    final root = await Directory.systemTemp.createTemp('venera-pages-');
    addTearDown(() => root.delete(recursive: true));
    await File(FilePath.join(root.path, '0.jpg')).writeAsBytes([1, 2, 3]);
    final empty = await File(
      FilePath.join(root.path, '1.PNG'),
    ).writeAsBytes([]);
    final partial = await File(
      FilePath.join(root.path, downloadPartialImageFileName(2, '.webp')),
    ).writeAsBytes([4, 5]);
    await File(FilePath.join(root.path, '2.txt')).writeAsString('not an image');
    await File(FilePath.join(root.path, '8.webp')).writeAsBytes([4]);

    final pages = await scanExistingDownloadPages(root, expectedCount: 3);

    expect(pages.completeFiles.keys, {0});
    expect(await empty.exists(), isFalse);
    expect(await partial.exists(), isFalse);
  });

  test('finds an existing non-empty cover', () async {
    final root = await Directory.systemTemp.createTemp('venera-cover-');
    addTearDown(() => root.delete(recursive: true));
    await File(FilePath.join(root.path, 'cover.jpg')).writeAsBytes([1]);

    final cover = await findExistingDownloadCover(root);

    expect(cover.completeFile?.name, 'cover.jpg');
    expect(cover.hasInvalidFile, isFalse);
  });

  test('removes an empty cover so it can be downloaded again', () async {
    final root = await Directory.systemTemp.createTemp('venera-cover-empty-');
    addTearDown(() => root.delete(recursive: true));
    final empty = await File(
      FilePath.join(root.path, 'cover.jpg'),
    ).writeAsBytes([]);

    final cover = await findExistingDownloadCover(root);

    expect(cover.completeFile, isNull);
    expect(cover.hasInvalidFile, isFalse);
    expect(await empty.exists(), isFalse);
  });
}
