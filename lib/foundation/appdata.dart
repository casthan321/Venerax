import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/repository.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/atomic_file.dart';
import 'package:venera/utils/coalescing_async_writer.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';

const _comicSourceRepositorySyncFields = <String>{
  'comicSourceListUrl',
  'comicSourceRepositories',
  'comicSourceRepositoriesLegacyMirror',
};

@visibleForTesting
Map<String, dynamic> mergeLocalAppdataForRestore(
  Map<String, dynamic> current,
  Map<String, dynamic> imported,
) {
  final currentSettings = current['settings'];
  final mergedSettings = currentSettings is Map
      ? Map<String, dynamic>.from(currentSettings)
      : <String, dynamic>{};
  final importedSettings = imported['settings'];
  if (importedSettings is Map) {
    mergedSettings.addAll(Map<String, dynamic>.from(importedSettings));
  }
  return <String, dynamic>{
    'settings': mergedSettings,
    'searchHistory': List<dynamic>.from(
      imported['searchHistory'] ?? current['searchHistory'] ?? const [],
    ),
  };
}

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  late final CoalescingAsyncWriter<_AppdataWrite> _appdataWriter =
      CoalescingAsyncWriter<_AppdataWrite>(
        _writeAppdata,
        mergePending: (pending, next) => _AppdataWrite(
          data: next.data,
          syncData: next.syncData,
          syncRequested: pending.syncRequested || next.syncRequested,
        ),
      );

  late final CoalescingAsyncWriter<String> _implicitDataWriter =
      CoalescingAsyncWriter<String>(_writeImplicitDataSnapshot);

  Future<void> saveData([bool sync = true]) {
    final json = toJson();
    final data = jsonEncode(json);
    late final String syncData;
    final disableSyncFieldsValue = json["settings"]["disableSyncFields"];
    final disableSyncFields = disableSyncFieldsValue is String
        ? disableSyncFieldsValue
        : '';
    final jsonForSync = sanitizedAppdataForSync(
      json,
      disabledFields: <String>{
        ..._disableSync,
        ...splitField(disableSyncFields),
      },
    );
    syncData = jsonEncode(jsonForSync);
    return _observePersistence(
      _appdataWriter.schedule(
        _AppdataWrite(data: data, syncData: syncData, syncRequested: sync),
      ),
      'Failed to persist application settings',
    );
  }

  Future<void> _writeAppdata(_AppdataWrite write) async {
    final writes = <Future<void>>[
      writeStringAtomically(
        File(FilePath.join(App.dataPath, 'appdata.json')),
        write.data,
      ),
    ];
    writes.add(
      writeStringAtomically(
        File(FilePath.join(App.dataPath, 'syncdata.json')),
        write.syncData,
      ),
    );
    await Future.wait(writes);
    if (write.syncRequested) {
      unawaited(DataSync().uploadData());
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
    "comicSourceLegacyUrlNeedsReview",
  ];

  /// Sync data from another device
  Future<void> syncData(Map<String, dynamic> data, {bool upload = true}) {
    if (data['settings'] is Map) {
      var settings = data['settings'] as Map<String, dynamic>;

      List<String> customDisableSync = splitField(
        this.settings["disableSyncFields"] as String,
      );
      final repositoriesSyncDisabled = customDisableSync.any(
        _comicSourceRepositorySyncFields.contains,
      );
      final bindingsSyncDisabled = customDisableSync.contains(
        'comicSourceRepositoryBindings',
      );

      for (var key in settings.keys) {
        if (repositoriesSyncDisabled &&
            (key == 'comicSourceListUrl' ||
                key == 'comicSourceRepositories' ||
                key == 'comicSourceRepositoriesLegacyMirror')) {
          continue;
        }
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          this.settings[key] = settings[key];
        }
      }
      final importsRepositorySettings =
          !repositoriesSyncDisabled &&
          settings.keys.any(_comicSourceRepositorySyncFields.contains);
      if (importsRepositorySettings &&
          settings.containsKey('comicSourceListUrl') &&
          !settings.containsKey('comicSourceRepositories')) {
        this.settings._data['comicSourceRepositories'] = null;
      }
      if (importsRepositorySettings &&
          !bindingsSyncDisabled &&
          !settings.containsKey('comicSourceRepositoryBindings')) {
        this.settings._data['comicSourceRepositoryBindings'] =
            <String, dynamic>{};
      }
      migrateComicSourceRepositorySettings(this.settings._data);
    }
    searchHistory = List.from(data['searchHistory'] ?? []);
    return saveData(upload);
  }

  /// Restores an exact in-memory snapshot after a failed transactional import.
  /// Device-only values are included because the snapshot originated from this
  /// same installation rather than from an untrusted remote backup.
  Future<void> restoreSnapshot(Map<String, dynamic> snapshot) {
    final snapshotSettings = snapshot['settings'];
    if (snapshotSettings is Map) {
      settings._replaceAll(Map<String, dynamic>.from(snapshotSettings));
      migrateComicSourceRepositorySettings(settings._data);
    }
    searchHistory = List<String>.from(snapshot['searchHistory'] ?? const []);
    return saveData(false);
  }

  /// Restores a user-selected local backup, including device-only settings.
  ///
  /// Older backups may not contain settings introduced by newer versions, so
  /// imported keys are merged over the current defaults instead of replacing
  /// the settings map wholesale.
  Future<void> restoreImportedData(Map<String, dynamic> imported) {
    final merged = mergeLocalAppdataForRestore(toJson(), imported);
    final mergedSettings = Map<String, dynamic>.from(merged['settings'] as Map);
    final importedSettings = imported['settings'];
    if (importedSettings is Map &&
        importedSettings.containsKey('comicSourceListUrl') &&
        !importedSettings.containsKey('comicSourceRepositories')) {
      mergedSettings['comicSourceRepositories'] = null;
    }
    if (importedSettings is Map &&
        !importedSettings.containsKey('comicSourceRepositoryBindings')) {
      mergedSettings['comicSourceRepositoryBindings'] = <String, dynamic>{};
    }
    settings._replaceAll(mergedSettings);
    migrateComicSourceRepositorySettings(settings._data);
    searchHistory = List<String>.from(merged['searchHistory'] as List);
    return saveData(false);
  }

  var implicitData = <String, dynamic>{};

  Future<void> writeImplicitData() {
    return _observePersistence(
      _implicitDataWriter.schedule(jsonEncode(implicitData)),
      'Failed to persist device state',
    );
  }

  Future<void> _observePersistence(Future<void> operation, String message) {
    // Most setting writes originate in synchronous UI callbacks. Registering
    // an error listener here prevents an ignored Future from becoming an
    // unhandled zone error, while returning the original Future still lets
    // explicit callers await and react to the same failure.
    unawaited(
      operation.catchError((Object error, StackTrace stackTrace) {
        Log.error('Appdata', '$message: $error', stackTrace);
      }),
    );
    return operation;
  }

  Future<void> _writeImplicitDataSnapshot(String data) {
    return writeStringAtomically(
      File(FilePath.join(App.dataPath, 'implicitData.json')),
      data,
    );
  }

  @override
  Future<void> doInit() async {
    var dataPath = (await getApplicationSupportDirectory()).path;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (await file.exists()) {
      try {
        var json = jsonDecode(await file.readAsString());
        for (var key in (json['settings'] as Map<String, dynamic>).keys) {
          if (json['settings'][key] != null) {
            settings[key] = json['settings'][key];
          }
        }
        searchHistory = List.from(json['searchHistory']);
      } catch (e) {
        Log.error("Appdata", "Failed to load appdata", e);
        Log.info("Appdata", "Resetting appdata");
        file.deleteIgnoreError();
      }
    }
    final migratedRepositories = migrateComicSourceRepositorySettings(
      settings._data,
    );
    if ((settings["deviceId"] as String).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    } else if (migratedRepositories) {
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        implicitData = jsonDecode(await implicitDataFile.readAsString());
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
    }
  }
}

class _AppdataWrite {
  const _AppdataWrite({
    required this.data,
    required this.syncData,
    required this.syncRequested,
  });

  final String data;
  final String syncData;
  final bool syncRequested;
}

@visibleForTesting
Map<String, dynamic> sanitizedAppdataForSync(
  Map<String, dynamic> source, {
  required Iterable<String> disabledFields,
}) {
  final copy = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  final settings = copy['settings'];
  if (settings is Map<String, dynamic>) {
    final disabled = disabledFields.toSet();
    if (disabled.any(_comicSourceRepositorySyncFields.contains)) {
      disabled.addAll(_comicSourceRepositorySyncFields);
    }
    for (final field in disabled) {
      settings.remove(field);
    }
  }
  return copy;
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': false,
    'receiveBetaUpdates': false,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': defaultComicSourceRepositoryUrl,
    // Null is a migration sentinel. It lets an older installation's custom
    // comicSourceListUrl become the first repository instead of being hidden
    // by a newly introduced default list.
    'comicSourceRepositories': null,
    'comicSourceRepositoriesLegacyMirror': null,
    'comicSourceSelectedRepositoryId': null,
    'comicSourceLegacyUrlNeedsReview': null,
    'comicSourceRepositoryBindings': <String, dynamic>{},
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void _replaceAll(Map<String, dynamic> values) {
    _data
      ..clear()
      ..addAll(values);
    notifyListeners();
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';
