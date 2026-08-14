import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

const _insertHistorySql = """
  insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
  values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
""";

const _historyWriteLockTimeout = Duration(seconds: 5);
const _historyWriteRetryDelay = Duration(milliseconds: 50);

const _createHistoryTableSql = '''
  CREATE TABLE IF NOT EXISTS history (
    id TEXT,
    title TEXT,
    subtitle TEXT,
    cover TEXT,
    time INTEGER,
    type INTEGER,
    ep INTEGER,
    page INTEGER,
    readEpisode TEXT,
    max_page INTEGER,
    chapter_group INTEGER,
    PRIMARY KEY (id, type)
  );
''';

const _historyColumnList =
    'id, title, subtitle, cover, time, type, ep, page, '
    'readEpisode, max_page, chapter_group';

/// Upgrades the legacy id-only primary key to `(id, type)`.
///
/// Comic ids are only unique inside a source. Keeping `id` as the sole key
/// silently replaces a history row when two sources use the same id.
@visibleForTesting
void ensureHistorySchema(Database database) {
  database.execute(_createHistoryTableSql);
  var columns = database.select('PRAGMA table_info(history);');
  if (!columns.any((column) => column['name'] == 'chapter_group')) {
    database.execute('ALTER TABLE history ADD COLUMN chapter_group INTEGER;');
    columns = database.select('PRAGMA table_info(history);');
  }

  final primaryKeyColumns =
      columns.where((column) => (column['pk'] as int) > 0).toList()
        ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
  final alreadyComposite =
      primaryKeyColumns.length == 2 &&
      primaryKeyColumns[0]['name'] == 'id' &&
      primaryKeyColumns[1]['name'] == 'type';
  if (alreadyComposite) return;

  database.execute('BEGIN IMMEDIATE;');
  try {
    database.execute('DROP TABLE IF EXISTS history_schema_migration;');
    database.execute(
      _createHistoryTableSql.replaceFirst(
        'IF NOT EXISTS history',
        'history_schema_migration',
      ),
    );
    database.execute('''
      INSERT OR REPLACE INTO history_schema_migration ($_historyColumnList)
      SELECT $_historyColumnList FROM history;
    ''');
    database.execute('DROP TABLE history;');
    database.execute('ALTER TABLE history_schema_migration RENAME TO history;');
    database.execute('COMMIT;');
  } catch (_) {
    database.execute('ROLLBACK;');
    rethrow;
  }
}

/// Adds indexes used by the history list without rebuilding existing data.
///
/// Both [HistoryManager.getAll] and [HistoryManager.getRecent] are ordered by
/// the latest read time. Without this index SQLite has to scan the complete
/// table and create a temporary B-tree whenever a listener refreshes the UI.
@visibleForTesting
void ensureHistoryPerformanceIndexes(Database database) {
  database.execute('''
    CREATE INDEX IF NOT EXISTS history_time_index
    ON history(time DESC);
  ''');
}

Future<void> _executeHistoryWriteWithLockRetry(
  Database database,
  List<Object?> values,
) async {
  final elapsed = Stopwatch()..start();
  while (true) {
    try {
      database.execute(_insertHistorySql, values);
      return;
    } on SqliteException catch (error) {
      final isLockContention =
          error.resultCode == SqlError.SQLITE_BUSY ||
          error.resultCode == SqlError.SQLITE_LOCKED;
      if (!isLockContention || elapsed.elapsed >= _historyWriteLockTimeout) {
        rethrow;
      }
      await Future<void>.delayed(_historyWriteRetryDelay);
    }
  }
}

/// Writes a history row on an isolate-owned database connection.
///
/// A sqlite connection must not be shared across isolates. The database path
/// and row values are copied to the worker instead, and the connection opened
/// there is always disposed before the worker completes.
@visibleForTesting
Future<void> writeHistoryToDatabaseInIsolate(
  String databasePath,
  List<Object?> values, {
  Database Function(String path)? openDatabase,
}) {
  return Isolate.run(() async {
    final db = (openDatabase ?? sqlite3.open)(databasePath);
    try {
      // The UI isolate may briefly hold a read/write transaction. Waiting is
      // preferable to dropping the reader's progress with SQLITE_BUSY. Some
      // SQLite builds return BUSY while preparing under an exclusive lock
      // without invoking the busy handler, so retain a short native timeout
      // and also retry those two lock-contention result codes explicitly.
      db.execute('PRAGMA busy_timeout = 250;');
      await _executeHistoryWriteWithLockRetry(db, values);
    } finally {
      db.dispose();
    }
  });
}

/// Serializes history writes and contains task/reporting failures.
///
/// Reader progress updates are intentionally fire-and-forget at call sites.
/// Therefore every returned future must complete without an unhandled error,
/// while [drain] must still include work queued behind the active operation.
@visibleForTesting
class HistoryAsyncWriteQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> add(
    Future<void> Function() task, {
    required void Function(Object error, StackTrace stackTrace) onError,
  }) {
    final completion = _tail.then((_) async {
      try {
        await task();
      } catch (error, stackTrace) {
        try {
          onError(error, stackTrace);
        } catch (_) {
          // Logging is best effort and must not create an unhandled Future.
        }
      }
    });
    _tail = completion;
    return completion;
  }

  Future<void> drain() => _tail;
}

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(row["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
      title = row["title"],
      subtitle = row["subtitle"],
      cover = row["cover"],
      ep = row["ep"],
      page = row["page"],
      id = row["id"],
      readEpisode = Set<String>.from(
        (row["readEpisode"] as String)
            .split(',')
            .where((element) => element != ""),
      ),
      maxPage = row["max_page"],
      group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  @visibleForTesting
  HistoryManager.withDatabase(Database database)
    : _db = database,
      _databasePath = '' {
    isInitialized = true;
  }

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  late String _databasePath;

  int get length => _db.select("select count(*) from history;").first[0] as int;

  /// Cache of history ids. Improve the performance of find operation.
  Set<String>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  @visibleForTesting
  bool get hasLoadedHistoryIdCache => _cachedHistoryIds != null;

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _clearRuntimeCaches();
    _databasePath = "${App.dataPath}/history.db";
    final database = sqlite3.open(_databasePath);
    _db = database;
    try {
      ensureHistorySchema(database);
      ensureHistoryPerformanceIndexes(database);
      ImageFavoriteManager().init();
      isInitialized = true;
      notifyListeners();
    } catch (_) {
      isInitialized = false;
      _clearRuntimeCaches();
      database.dispose();
      rethrow;
    }
  }

  final _asyncWrites = HistoryAsyncWriteQueue();

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) {
    return _asyncWrites.add(
      () async {
        await writeHistoryToDatabaseInIsolate(_databasePath, [
          newItem.id,
          newItem.title,
          newItem.subtitle,
          newItem.cover,
          newItem.time.millisecondsSinceEpoch,
          newItem.type.value,
          newItem.ep,
          newItem.page,
          newItem.readEpisode.join(','),
          newItem.maxPage,
          newItem.group,
        ]);
        if (_cachedHistoryIds == null) {
          updateCache();
        } else {
          _cachedHistoryIds!.add(_historyCacheKey(newItem.id, newItem.type));
        }
        _cacheHistory(newItem);
        notifyListeners();
      },
      onError: (error, stackTrace) {
        Log.error(
          'History',
          'Failed to save reading progress: $error',
          stackTrace,
        );
      },
    );
  }

  /// Waits for the active write and every write already queued behind it.
  Future<void> waitForAsyncTasks() => _asyncWrites.drain();

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    _db.execute(_insertHistorySql, [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ]);
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds!.add(_historyCacheKey(newItem.id, newItem.type));
    }
    _cacheHistory(newItem);
    notifyListeners();
  }

  void clearHistory() {
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type.value],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) {
    _db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    _cachedHistoryIds = <String>{};
    var res = _db.select("""
        select id, type from history;
      """);
    for (var element in res) {
      _cachedHistoryIds!.add(
        _historyCacheKey(
          element['id'] as String,
          ComicType(element['type'] as int),
        ),
      );
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryIds!.contains(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    final cacheKey = _historyCacheKey(id, type);
    if (!_cachedHistoryIds!.contains(cacheKey)) {
      return null;
    }
    final cachedHistory = cachedHistories[cacheKey];
    if (cachedHistory != null) {
      return cachedHistory;
    }

    var res = _db.select(
      """
      select * from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      return null;
    }
    final history = History.fromRow(res.first);
    _cacheHistory(history);
    return history;
  }

  void _cacheHistory(History history) {
    // Removing and reinserting turns the map's insertion order into a tiny
    // LRU. Frequently opened comics then survive the bounded eviction policy.
    final cacheKey = _historyCacheKey(history.id, history.type);
    cachedHistories.remove(cacheKey);
    cachedHistories[cacheKey] = history;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
  }

  static String _historyCacheKey(String id, ComicType type) {
    return '${type.value}:$id';
  }

  void _clearRuntimeCaches() {
    _cachedHistoryIds = null;
    cachedHistories.clear();
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  void close() {
    _clearRuntimeCaches();
    isInitialized = false;
    _db.dispose();
  }

  /// Runs a synchronous batch as one SQLite savepoint and restores all runtime
  /// caches if any row conversion or write fails.
  T runInTransaction<T>(T Function() operation) {
    _db.execute('SAVEPOINT venera_history_batch;');
    try {
      final result = operation();
      _db.execute('RELEASE SAVEPOINT venera_history_batch;');
      return result;
    } catch (_) {
      try {
        _db.execute('ROLLBACK TO SAVEPOINT venera_history_batch;');
      } finally {
        _db.execute('RELEASE SAVEPOINT venera_history_batch;');
        updateCache();
        notifyListeners();
      }
      rethrow;
    }
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and type == ?;
        """,
          [history.id, history.type.value],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return false;
          }
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return false;
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(
          RefreshProgress(total, current, success, failed, skipped),
        );
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var channel = Channel<History>(10);

    () async {
      var c = 0;
      for (var history in historiesToRefresh) {
        await channel.push(history);
        c++;
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var history = await channel.pop();
          if (history == null) {
            break;
          }
          var result = await _refreshSingleHistory(history);
          current++;
          if (result) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
