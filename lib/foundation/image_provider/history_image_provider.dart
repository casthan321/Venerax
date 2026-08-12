import 'dart:async' show Future, StreamController;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_cover_fallback.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    final refreshBeforeLoad = !history.cover.contains('/');
    if (refreshBeforeLoad) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
    }

    return loadHistoryCoverWithRefresh(
      initialCover: history.cover,
      refreshBeforeLoad: refreshBeforeLoad,
      loadCover: (url) => _loadCover(url, chunkEvents, checkStop),
      refreshCover: () => _refreshCover(checkStop),
    );
  }

  Future<String> _refreshCover(void Function() checkStop) async {
    var comicSource =
        history.type.comicSource ?? (throw "Comic source not found.");
    var loader =
        comicSource.loadComicInfo ?? (throw "Comic info loader not found.");
    var comic = await loader(history.id);
    checkStop();
    if (comic.error) {
      throw comic.errorMessage ?? "Failed to refresh history cover.";
    }

    final url = comic.data.cover;
    if (url.isEmpty) {
      throw "History cover is empty.";
    }
    history.cover = url;
    HistoryManager().addHistory(history);
    return url;
  }

  Future<Uint8List> _loadCover(
    String url,
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";
}
