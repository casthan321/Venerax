import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'download_directory.dart';
import 'download_state.dart';
import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() {
    _runGuard.stop();
    stopRecorder();

    final localManager = LocalManager();
    final local = localManager.find(id, comicType);
    final downloadPath = path;

    final cancelledTasks = tasks.values
        .where((task) => !task.isComplete)
        .toList(growable: false);
    final pendingWrapperCancellation = _pendingWrapperCancellation;
    final pendingAtomicWrite = _pendingAtomicWrite;
    for (final task in cancelledTasks) {
      if (!task.isComplete) {
        task.cancel();
      }
    }
    tasks.clear();

    localManager.removeTask(this);
    final requestedChapterKeys =
        chapters ?? comic?.chapters?.allChapters.keys ?? const <String>[];
    final cancellableChapterKeys = local == null
        ? const <String>[]
        : cancellableDownloadChapterKeys(
            requestedChapterKeys: requestedChapterKeys,
            previouslyDownloadedChapterKeys: local.downloadedChapters,
            directoryNameForChapter: LocalManager.getChapterDirectoryName,
          );
    final paths = downloadPath == null
        ? const <String>[]
        : local == null
        ? <String>[downloadPath]
        : downloadChapterDirectoryPaths(
            downloadPath,
            cancellableChapterKeys,
            directoryNameForChapter: LocalManager.getChapterDirectoryName,
          );
    if (paths.isEmpty &&
        cancelledTasks.isEmpty &&
        pendingWrapperCancellation == null &&
        pendingAtomicWrite == null) {
      localManager.downloadingTasks.firstOrNull?.resume();
      return;
    }
    unawaited(
      runDownloadCleanupBeforeResume(
        cleanup: () => _deleteCancelledDownloadFiles(
          paths,
          cancelledTasks,
          pendingWrapperCancellation,
          pendingAtomicWrite,
        ),
        resumeNext: () => localManager.downloadingTasks.firstOrNull?.resume(),
      ),
    );
  }

  Future<void> _deleteCancelledDownloadFiles(
    List<String> paths,
    List<_ImageDownloadWrapper> cancelledTasks,
    Future<void>? pendingWrapperCancellation,
    Future<void>? pendingAtomicWrite,
  ) async {
    try {
      await Future.wait(<Future<void>>[
        if (pendingWrapperCancellation != null) pendingWrapperCancellation,
        if (pendingAtomicWrite != null) pendingAtomicWrite,
        ...cancelledTasks.map((task) => task.waitForCancellation()),
      ]);
      final errors = await LocalManager.deleteDirectories(paths);
      for (final error in errors) {
        Log.error("Download", error);
      }
    } catch (error, stackTrace) {
      Log.error(
        "Download",
        "Failed to delete cancelled download: $error",
        stackTrace,
      );
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _runGuard.stop();
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    final cancelledTasks = <_ImageDownloadWrapper>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        cancelledTasks.add(entry.value);
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    _pendingWrapperCancellation = cancelledTasks.isEmpty
        ? null
        : Future.wait(cancelledTasks.map((task) => task.waitForCancellation()));
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  final DownloadRunGuard _runGuard = DownloadRunGuard();

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  Future<void>? _pendingWrapperCancellation;
  Future<void>? _pendingAtomicWrite;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  List<String> get _expectedImageListKeys {
    final comicChapters = comic!.chapters;
    if (comicChapters == null) {
      return const [''];
    }
    if (chapters == null) {
      return comicChapters.allChapters.keys.toList();
    }
    final requested = chapters!.toSet();
    return comicChapters.allChapters.keys.where(requested.contains).toList();
  }

  bool _isRunActive(int runToken) => _runGuard.isActive(runToken);

  void _scheduleTasks(
    int runToken,
    Directory saveTo,
    Set<int> existingImageIndexes,
  ) {
    if (!_isRunActive(runToken)) {
      return;
    }
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
        alreadyDownloaded: existingImageIndexes.contains(i),
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete && _isRunActive(runToken)) {
          _scheduleTasks(runToken, saveTo, existingImageIndexes);
        }
      });
      downloading++;
    }
  }

  Future<bool> _ensureImageLists(int runToken) async {
    final expectedKeys = _expectedImageListKeys;
    if (chapters != null && expectedKeys.length != chapters!.toSet().length) {
      _setError("Error: Some selected chapters are unavailable");
      return false;
    }
    if (expectedKeys.isEmpty) {
      _setError("Error: No chapters to download");
      return false;
    }

    _images ??= {};
    var fetchedCount =
        expectedKeys.length -
        missingImageListKeys(expectedKeys, _images).length;

    for (final key in expectedKeys) {
      if (_images![key]?.isNotEmpty == true) {
        continue;
      }

      _message = comic!.chapters == null
          ? "Fetching image list..."
          : "Fetching image list ($fetchedCount/${expectedKeys.length})...";
      notifyListeners();
      final res = await _runWithRetry(() async {
        final r = await runDownloadImageListLoad(
          () => source.loadComicPages!(
            comicId,
            comic!.chapters == null ? null : key,
          ),
        );
        if (r.error) {
          throw r.errorMessage ?? "Failed to fetch image list";
        }
        if (r.data.isEmpty) {
          throw "Image list is empty";
        }
        return List<String>.from(r.data);
      });
      if (!_isRunActive(runToken)) {
        return false;
      }
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return false;
      }

      _images![key] = res.data;
      fetchedCount++;
      // Persist partial list progress. A restored task will fetch only the
      // missing chapters instead of mistaking the partial map for completion.
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isRunActive(runToken)) {
        return false;
      }
    }

    if (!hasCompleteImageLists(expectedKeys, _images)) {
      _setError("Error: Image list is incomplete");
      return false;
    }

    // Serialized maps from an interrupted older version can be partial or in
    // an unexpected order. Normalize them before using [_chapter] as an index.
    _images = {for (final key in expectedKeys) key: _images![key]!};
    _totalCount = _images!.values.fold(
      0,
      (total, images) => total + images.length,
    );
    _message = "$_downloadedCount/$_totalCount";
    notifyListeners();
    await LocalManager().saveCurrentDownloadingTasks();
    return _isRunActive(runToken);
  }

  @override
  void resume() async {
    if (_runGuard.isRunning) return;
    final runToken = _runGuard.start();
    _isError = false;
    _message = "Resuming...";
    notifyListeners();
    runRecorder();

    final pendingWrapperCancellation = _pendingWrapperCancellation;
    final pendingAtomicWrite = _pendingAtomicWrite;
    if (pendingWrapperCancellation != null || pendingAtomicWrite != null) {
      await Future.wait(<Future<void>>[
        if (pendingWrapperCancellation != null) pendingWrapperCancellation,
        if (pendingAtomicWrite != null) pendingAtomicWrite,
      ]);
      if (identical(_pendingWrapperCancellation, pendingWrapperCancellation)) {
        _pendingWrapperCancellation = null;
      }
      if (identical(_pendingAtomicWrite, pendingAtomicWrite)) {
        _pendingAtomicWrite = null;
      }
      if (!_isRunActive(runToken)) {
        return;
      }
    }

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunActive(runToken)) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    final downloadIdentity = DownloadDirectoryIdentity(
      sourceKey: source.key,
      comicId: comicId,
    );
    if (path == null) {
      try {
        final localManager = LocalManager();
        Directory? dir;
        if (localManager.find(comicId, comicType) == null) {
          dir = await findReusableDownloadDirectory(
            localManager.directory,
            downloadIdentity,
          );
        }
        dir ??= await localManager.findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!_isRunActive(runToken)) {
          return;
        }
        if (!(await dir.exists())) {
          await dir.create();
        }
        if (!_isRunActive(runToken)) {
          return;
        }
        path = dir.path;
      } catch (e, s) {
        if (!_isRunActive(runToken)) {
          return;
        }
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    try {
      final downloadDirectory = Directory(path!);
      if (!await downloadDirectory.exists()) {
        await downloadDirectory.create(recursive: true);
      }
      await ensureDownloadDirectoryIdentity(
        downloadDirectory,
        downloadIdentity,
      );
    } catch (e, s) {
      if (!_isRunActive(runToken)) {
        return;
      }
      Log.error('Download', 'Failed to identify download directory: $e', s);
      _setError('Error: $e');
      return;
    }
    if (!_isRunActive(runToken)) {
      return;
    }

    await LocalManager().saveCurrentDownloadingTasks();
    if (!_isRunActive(runToken)) {
      return;
    }

    if (_cover == null) {
      try {
        final existingCover = await findExistingDownloadCover(Directory(path!));
        if (!_isRunActive(runToken)) {
          return;
        }
        if (existingCover.hasInvalidFile) {
          throw FileSystemException(
            'Existing download contains an empty cover file',
            path,
          );
        }
        if (existingCover.completeFile != null) {
          _cover = 'file://${existingCover.completeFile!.path}';
          notifyListeners();
        }
      } catch (e, s) {
        Log.error('Download', 'Failed to inspect existing cover: $e', s);
        _setError('Error: $e');
        return;
      }
    }

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        if (!_isRunActive(runToken)) {
          throw "Download was paused";
        }
        Uint8List? data;
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
        )) {
          if (!_isRunActive(runToken)) {
            throw "Download was paused";
          }
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        if (!_isRunActive(runToken)) {
          throw "Download was paused";
        }
        final fileType = detectFileType(data);
        final fileName = "cover${fileType.ext}";
        if (!isSupportedComicImagePath(fileName)) {
          throw "Downloaded cover is not a supported image";
        }
        final file = File(FilePath.join(path!, fileName));
        final temporaryFile = File(
          FilePath.join(path!, downloadPartialFileName(fileName)),
        );
        final atomicWrite = writeDownloadedImageAtomically(
          temporaryFile: temporaryFile,
          destinationFile: file,
          bytes: data,
          isCancelled: () => !_isRunActive(runToken),
        );
        final pendingAtomicWrite = atomicWrite
            .then<void>((_) {})
            .catchError((_) {});
        _pendingAtomicWrite = pendingAtomicWrite;
        late final bool committed;
        try {
          committed = await atomicWrite;
        } finally {
          if (identical(_pendingAtomicWrite, pendingAtomicWrite)) {
            _pendingAtomicWrite = null;
          }
        }
        if (!committed || !_isRunActive(runToken)) {
          throw "Download was paused";
        }
        return "file://${file.path}";
      });
      if (!_isRunActive(runToken)) {
        return;
      }
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isRunActive(runToken)) {
        return;
      }
    }

    if (!await _ensureImageLists(runToken)) {
      return;
    }

    // Persistent counters from an older task cannot prove that the files are
    // still present. Re-scan every selected chapter and rebuild progress.
    _chapter = 0;
    _index = 0;
    _downloadedCount = 0;
    _message = "$_downloadedCount/$_totalCount";
    notifyListeners();

    while (_chapter < _images!.length) {
      if (!_isRunActive(runToken)) {
        return;
      }
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      final chapterKey = _images!.keys.elementAt(_chapter);
      final saveTo = comic!.chapters == null
          ? Directory(path!)
          : Directory(
              FilePath.join(
                path!,
                LocalManager.getChapterDirectoryName(chapterKey),
              ),
            );
      try {
        if (!await saveTo.exists()) {
          await saveTo.create(recursive: true);
        }
        final existingPages = await scanExistingDownloadPages(
          saveTo,
          expectedCount: images.length,
        );
        final existingImageIndexes = existingPages.completeFiles.keys.toSet();
        while (_index < images.length) {
          _scheduleTasks(runToken, saveTo, existingImageIndexes);
          var task = tasks[_index]!;
          await task.wait();
          if (!_isRunActive(runToken)) {
            return;
          }
          if (task.error != null) {
            Log.error("Download", task.error.toString());
            _setError("Error: ${task.error}");
            return;
          }
          _index++;
          _downloadedCount++;
          _message = "$_downloadedCount/$_totalCount";
          await LocalManager().saveCurrentDownloadingTasks();
          if (!_isRunActive(runToken)) {
            return;
          }
        }
      } catch (e, s) {
        if (!_isRunActive(runToken)) {
          return;
        }
        Log.error('Download', 'Failed to resume existing download: $e', s);
        _setError('Error: $e');
        return;
      }
      _index = 0;
      _chapter++;
    }

    if (!hasCompleteImageLists(_expectedImageListKeys, _images)) {
      _setError("Error: Image list is incomplete");
      return;
    }
    try {
      final hasCompleteFiles = await _hasCompleteDownloadedFiles();
      if (!_isRunActive(runToken)) {
        return;
      }
      if (!hasCompleteFiles) {
        _setError("Error: Downloaded image files are incomplete");
        return;
      }
    } catch (error, stackTrace) {
      if (!_isRunActive(runToken)) {
        return;
      }
      Log.error(
        "Download",
        "Failed to verify downloaded images: $error",
        stackTrace,
      );
      _setError("Error: $error");
      return;
    }
    if (!_isRunActive(runToken)) {
      return;
    }
    _runGuard.stop();
    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _runGuard.stop();
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  Future<bool> _hasCompleteDownloadedFiles() async {
    for (final entry in _images!.entries) {
      final directory = comic!.chapters == null
          ? Directory(path!)
          : Directory(
              FilePath.join(
                path!,
                LocalManager.getChapterDirectoryName(entry.key),
              ),
            );
      final artifacts = await scanExistingDownloadPages(
        directory,
        expectedCount: entry.value.length,
      );
      if (!hasCompleteDownloadedPageIndexes(
        entry.value.length,
        artifacts.completeFiles.keys,
      )) {
        return false;
      }
    }
    return true;
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
        source: ComicSource.find(json["source"])!,
        comicId: json["comicId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        chapters: ListOrNull.from(json["chapters"]),
      )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_runGuard.isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      // Only advertise chapters that passed image-list validation and whose
      // images reached the completion gate above.
      downloadedChapters: comic!.chapters == null ? [] : _expectedImageListKeys,
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 3,
}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index, {
    bool alreadyDownloaded = false,
  }) {
    if (alreadyDownloaded) {
      isComplete = true;
      _download = Future.value();
    } else {
      _download = start();
    }
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  late final Future<void> _download;

  StreamIterator<ImageDownloadProgress>? _iterator;

  void cancel() {
    if (isCancelled || isComplete) {
      return;
    }
    isCancelled = true;
    _completeWaiters();
  }

  Future<void> waitForCancellation() async {
    cancel();
    try {
      await _iterator?.cancel();
    } catch (error, stackTrace) {
      Log.error(
        "Download",
        "Failed to cancel image stream: $error",
        stackTrace,
      );
    }
    await _download;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void _completeWaiters() {
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  Future<void> start() async {
    int lastBytes = 0;
    final iterator = StreamIterator(
      ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
      ),
    );
    _iterator = iterator;
    try {
      while (await iterator.moveNext()) {
        if (isCancelled) {
          return;
        }
        final p = iterator.current;
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          final imageBytes = p.imageBytes!;
          final fileType = detectFileType(imageBytes);
          final fileName = "$index${fileType.ext}";
          if (!isSupportedComicImagePath(fileName)) {
            throw "Downloaded data is not a supported comic image";
          }
          final file = saveTo.joinFile(fileName);
          final temporaryFile = saveTo.joinFile(
            downloadPartialImageFileName(index, fileType.ext),
          );
          final committed = await writeDownloadedImageAtomically(
            temporaryFile: temporaryFile,
            destinationFile: file,
            bytes: imageBytes,
            isCancelled: () => isCancelled,
          );
          if (!committed || isCancelled) {
            return;
          }
          isComplete = true;
          _completeWaiters();
          return;
        }
      }
      if (!isComplete && !isCancelled) {
        throw "Image download completed without data";
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        await start();
        return;
      }
      error = e.toString();
      _completeWaiters();
    } finally {
      if (identical(_iterator, iterator)) {
        _iterator = null;
      }
      try {
        await iterator.cancel();
      } catch (error, stackTrace) {
        if (!isCancelled) {
          Log.error(
            "Download",
            "Failed to close image stream: $error",
            stackTrace,
          );
        }
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete || isCancelled || error != null) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile = File(
      FilePath.join(App.dataPath, "archive_downloading.zip"),
    );

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )..path = json["path"];
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
