import 'dart:async' show Future, StreamController;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_favorite_support.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'image_favorites_provider.dart' as image_provider;

class ImageFavoritesProvider
    extends BaseImageProvider<image_provider.ImageFavoritesProvider> {
  /// Image provider for imageFavorites
  const ImageFavoritesProvider(this.imageFavorite);

  final ImageFavorite imageFavorite;

  int get page => imageFavorite.page;

  String get sourceKey => imageFavorite.sourceKey;

  String get cid => imageFavorite.id;

  String get eid => imageFavorite.eid;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    return loadLocalImageOrFallback(
      loadLocal: getImageFromLocal,
      afterLocalAttempt: checkStop,
      loadFallback: () => _loadFromCacheOrNetwork(chunkEvents, checkStop),
    );
  }

  Future<Uint8List> _loadFromCacheOrNetwork(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    var imageKey = imageFavorite.imageKey;
    var cacheImage = await readFromCache();
    checkStop?.call();
    if (cacheImage != null) {
      return cacheImage;
    }
    var gotImageKey = false;
    if (imageKey == "") {
      imageKey = await getImageKey();
      checkStop?.call();
      gotImageKey = true;
    }
    Uint8List image;
    try {
      image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
    } catch (e) {
      if (gotImageKey) {
        rethrow;
      } else {
        imageKey = await getImageKey();
        image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
      }
    }
    await writeToCache(image);
    return image;
  }

  Future<void> writeToCache(Uint8List image) async {
    var fileName = md5.convert(key.codeUnits).toString();
    var file = File(FilePath.join(App.cachePath, 'image_favorites', fileName));
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    await file.writeAsBytes(image);
  }

  Future<Uint8List?> readFromCache() async {
    final current = await _readCacheFile(key);
    if (current != null) {
      return current;
    }

    // A legacy cache without page is safe only when imageKey identifies the
    // image. Empty-key favorites from different pages shared one legacy key.
    if (!canReadLegacyImageFavoriteCache(imageFavorite.imageKey)) {
      return null;
    }
    final legacy = await _readCacheFile(
      legacyImageFavoriteCacheIdentity(
        imageKey: imageFavorite.imageKey,
        sourceKey: imageFavorite.sourceKey,
        comicId: imageFavorite.id,
        episodeId: imageFavorite.eid,
      ),
    );
    if (legacy != null) {
      await writeToCache(legacy);
    }
    return legacy;
  }

  static Future<Uint8List?> _readCacheFile(String cacheKey) async {
    final fileName = md5.convert(cacheKey.codeUnits).toString();
    final file = File(
      FilePath.join(App.cachePath, 'image_favorites', fileName),
    );
    if (!await file.exists()) {
      return null;
    }
    return nonEmptyImageDataOrNull(await file.readAsBytes());
  }

  /// Delete a image favorite cache
  static Future<void> deleteFromCache(ImageFavorite imageFavorite) async {
    final cacheKeys = <String>{
      imageFavoriteCacheIdentity(
        imageKey: imageFavorite.imageKey,
        sourceKey: imageFavorite.sourceKey,
        comicId: imageFavorite.id,
        episodeId: imageFavorite.eid,
        page: imageFavorite.page,
      ),
      // Clean up files written by versions whose provider key omitted page.
      legacyImageFavoriteCacheIdentity(
        imageKey: imageFavorite.imageKey,
        sourceKey: imageFavorite.sourceKey,
        comicId: imageFavorite.id,
        episodeId: imageFavorite.eid,
      ),
    };
    for (final cacheKey in cacheKeys) {
      final fileName = md5.convert(cacheKey.codeUnits).toString();
      final file = File(
        FilePath.join(App.cachePath, 'image_favorites', fileName),
      );
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<Uint8List?> getImageFromLocal() async {
    final comicType = ComicType.fromKey(sourceKey);
    final localComic = LocalManager().find(cid, comicType);
    if (localComic == null) {
      return null;
    }

    final chapter = resolveDownloadedFavoriteChapter(
      hasChapters: localComic.hasChapters,
      chapterIds: localComic.chapters?.ids.toList(),
      downloadedChapterIds: localComic.downloadedChapters,
      episodeId: eid,
    );
    if (chapter == null) {
      return null;
    }

    final images = await LocalManager().getImages(cid, comicType, chapter);
    final path = resolveLocalFavoriteImagePath(imageKeys: images, page: page);
    if (path == null) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    return nonEmptyImageDataOrNull(await file.readAsBytes());
  }

  Future<Uint8List> getImageFromNetwork(
    String imageKey,
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    await for (var progress in ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
    )) {
      checkStop?.call();
      if (chunkEvents != null) {
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        );
      }
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  Future<String> getImageKey() async {
    String sourceKey = imageFavorite.sourceKey;
    String cid = imageFavorite.id;
    String eid = imageFavorite.eid;
    var page = imageFavorite.page;
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null) {
      throw "Error: Comic source not found.";
    }
    var res = await comicSource.loadComicPages!(cid, eid);
    return res.data[page - 1];
  }

  @override
  Future<ImageFavoritesProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => imageFavoriteCacheIdentity(
    imageKey: imageFavorite.imageKey,
    sourceKey: imageFavorite.sourceKey,
    comicId: imageFavorite.id,
    episodeId: imageFavorite.eid,
    page: imageFavorite.page,
  );
}
