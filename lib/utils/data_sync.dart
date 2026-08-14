import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/redirects.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync_guard.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/maintenance_coordinator.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

const webDavConnectTimeout = Duration(seconds: 30);
const webDavSendTimeout = Duration(minutes: 10);
const webDavReceiveTimeout = Duration(minutes: 10);

@visibleForTesting
void configureWebDavClientTimeouts(
  Client client, {
  Duration connectTimeout = webDavConnectTimeout,
  Duration sendTimeout = webDavSendTimeout,
  Duration receiveTimeout = webDavReceiveTimeout,
}) {
  client.setConnectTimeout(connectTimeout.inMilliseconds);
  client.setSendTimeout(sendTimeout.inMilliseconds);
  client.setReceiveTimeout(receiveTimeout.inMilliseconds);
}

@visibleForTesting
void configureWebDavClientRedirects(Client client) {
  if (client.c.interceptors.any(
    (interceptor) => interceptor is DioRedirectInterceptor,
  )) {
    return;
  }
  client.c.interceptors.add(DioRedirectInterceptor(client.c));
}

Client _createWebDavClient(String url, String user, String password) {
  final client = newClient(
    url,
    user: user,
    password: password,
    adapter: RHttpAdapter(),
  );
  configureWebDavClientTimeouts(client);
  configureWebDavClientRedirects(client);
  return client;
}

@visibleForTesting
Future<T> withTemporaryWebDavDownload<T>(
  File file,
  Future<T> Function(File file) operation,
) async {
  try {
    return await operation(file);
  } finally {
    await file.deleteIgnoreError();
  }
}

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      unawaited(downloadData());
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    if (isEnabled) {
      unawaited(uploadData());
    }
  }

  bool _handleWindowClose() {
    if (_isUploading || _isDownloading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    final windowFrame = WindowFrame.of(App.rootContext);
    showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (_isUploading || _isDownloading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await windowFrame.forceCloseWindow();
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData() {
    return guardDataSyncOperation(
      () => MaintenanceCoordinator.instance.run('Upload Data', _uploadData),
      onException: (error, stackTrace, message) {
        _handleSyncException('Upload Data', error, stackTrace, message);
      },
    );
  }

  Future<Res<bool>> _uploadData() async {
    if (isDownloading) return const Res(true);
    if (_haveWaitingTask) return const Res(true);
    while (isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    try {
      notifyListeners();
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      final client = _createWebDavClient(url, user, pass);

      final configuredVersion = appdata.settings['dataVersion'] is int
          ? appdata.settings['dataVersion'] as int
          : 0;
      final existingNames = (await client.readDir(
        '/',
      )).map((entry) => entry.name).toList();
      final remoteLatestCandidates = latestWebDavBackupVersionEntries(
        existingNames,
      );
      final remoteLatest = remoteLatestCandidates.firstOrNull;
      if (remoteLatestCandidates.length > 1 &&
          remoteLatest!.version >= configuredVersion) {
        _lastError =
            'Conflicting WebDAV backups exist for version '
            '${remoteLatest.version}. Resolve them before uploading.';
        return Res.error(_lastError!);
      }
      if (remoteLatest != null && remoteLatest.version > configuredVersion) {
        _lastError =
            'A newer WebDAV backup exists. Download it before uploading.';
        return const Res.error(
          'A newer WebDAV backup exists. Download it before uploading.',
        );
      }
      final previousVersion = configuredVersion;
      final nextVersion = configuredVersion + 1;
      late File data;
      // Build the archive with the proposed next version, then immediately
      // restore the live version. It is committed only after the remote file
      // has been fully uploaded and promoted.
      try {
        appdata.settings['dataVersion'] = nextVersion;
        await appdata.saveData(false);
        data = await exportAppData(true);
      } finally {
        appdata.settings['dataVersion'] = previousVersion;
        await appdata.saveData(false);
      }
      var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000).toString();
      final uploadNonce = DateTime.now().microsecondsSinceEpoch;
      final filename = '$time-$nextVersion-$uploadNonce.venera';
      final temporaryName =
          '.$filename.uploading-${DateTime.now().microsecondsSinceEpoch}';
      try {
        final dataLength = await data.length();
        await client.c.wdWriteWithStream(
          client,
          temporaryName,
          ReplayableByteStream(data.openRead),
          dataLength,
        );
        final uploaded = (await client.readDir(
          '/',
        )).firstWhereOrNull((entry) => entry.name == temporaryName);
        if (uploaded == null || uploaded.size != dataLength) {
          throw StateError('Uploaded WebDAV backup failed size verification');
        }
        await client.rename(temporaryName, filename, false);

        appdata.settings['dataVersion'] = nextVersion;
        await appdata.saveData(false);

        try {
          final files = (await client.readDir('/'))
              .where(
                (entry) =>
                    entry.name != null && entry.name!.endsWith('.venera'),
              )
              .toList();
          for (final name in webDavBackupNamesToPrune(
            files.map((entry) => entry.name!),
            currentName: filename,
          )) {
            await client.remove(name);
          }
        } catch (error, stackTrace) {
          // Retention cleanup is not part of the upload transaction. Keeping
          // an extra valid backup is preferable to reporting a false failure.
          Log.warning(
            'Upload Data',
            'Backup uploaded, but old backup cleanup failed: $error\n$stackTrace',
          );
        }
      } catch (_) {
        try {
          await client.remove(temporaryName);
        } catch (_) {}
        rethrow;
      } finally {
        await data.deleteIgnoreError();
      }
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() {
    return guardDataSyncOperation(
      () => MaintenanceCoordinator.instance.run('Download Data', _downloadData),
      onException: (error, stackTrace, message) {
        _handleSyncException('Data Sync', error, stackTrace, message);
      },
    );
  }

  Future<Res<bool>> _downloadData() async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    try {
      notifyListeners();
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      final client = _createWebDavClient(url, user, pass);

      final files = await client.readDir('/');
      final latestCandidates = latestWebDavBackupVersionEntries(
        files.map((entry) => entry.name),
      );
      if (latestCandidates.isEmpty) {
        throw 'No data file found';
      }
      if (latestCandidates.length > 1) {
        throw StateError(
          'Conflicting WebDAV backups exist for version '
          '${latestCandidates.first.version}. Resolve them before syncing.',
        );
      }
      final latest = latestCandidates.single;
      var currentVersion = appdata.settings['dataVersion'];
      if (currentVersion is int && latest.version <= currentVersion) {
        Log.info("Data Sync", 'No new data to download');
        return const Res(true);
      }
      Log.info("Data Sync", "Downloading data from WebDAV server");
      final localFile = File(
        FilePath.join(
          App.cachePath,
          '.webdav-download-${DateTime.now().microsecondsSinceEpoch}.venera',
        ),
      );
      await withTemporaryWebDavDownload(localFile, (temporaryFile) async {
        await client.read2File(latest.name, temporaryFile.path);
        await importAppData(temporaryFile, true);
      });
      Log.info("Data Sync", "Data downloaded successfully");
      return const Res(true);
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  void _handleSyncException(
    String title,
    Object error,
    StackTrace stackTrace,
    String message,
  ) {
    _lastError = message;
    try {
      Log.error(title, error, stackTrace);
    } finally {
      notifyListeners();
    }
  }
}

@visibleForTesting
List<String> webDavBackupNamesToPrune(
  Iterable<String> names, {
  required String currentName,
  int maximumBackups = 10,
}) {
  final backups =
      names
          .map(parseWebDavBackupName)
          .whereType<WebDavBackupName>()
          .toSet()
          .toList()
        ..sort(_compareWebDavBackupNames);
  final remove = <String>[];
  while (backups.length > maximumBackups) {
    final oldest = backups.removeAt(0);
    final current = parseWebDavBackupName(currentName);
    if (oldest.name != currentName &&
        (current == null || oldest.version <= current.version)) {
      remove.add(oldest.name);
    }
  }
  return remove;
}

@immutable
class WebDavBackupName {
  const WebDavBackupName({
    required this.name,
    required this.day,
    required this.version,
  });

  final String name;
  final int day;
  final int version;

  @override
  bool operator ==(Object other) =>
      other is WebDavBackupName && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

@visibleForTesting
WebDavBackupName? parseWebDavBackupName(String? name) {
  if (name == null) return null;
  final match = RegExp(
    r'^(\d+)-(\d+)(?:-[A-Za-z0-9._-]+)?\.venera$',
  ).firstMatch(name);
  if (match == null) return null;
  final day = int.tryParse(match.group(1)!);
  final version = int.tryParse(match.group(2)!);
  if (day == null || version == null) return null;
  return WebDavBackupName(name: name, day: day, version: version);
}

int _compareWebDavBackupNames(WebDavBackupName a, WebDavBackupName b) {
  final versionComparison = a.version.compareTo(b.version);
  if (versionComparison != 0) return versionComparison;
  final dayComparison = a.day.compareTo(b.day);
  if (dayComparison != 0) return dayComparison;
  return a.name.compareTo(b.name);
}

@visibleForTesting
List<WebDavBackupName> latestWebDavBackupVersionEntries(
  Iterable<String?> names,
) {
  final backups = names
      .map(parseWebDavBackupName)
      .whereType<WebDavBackupName>()
      .toSet()
      .toList();
  if (backups.isEmpty) return const [];
  backups.sort(_compareWebDavBackupNames);
  final latestVersion = backups.last.version;
  return backups
      .where((backup) => backup.version == latestVersion)
      .toList(growable: false);
}

@visibleForTesting
WebDavBackupName? latestWebDavBackupName(Iterable<String?> names) {
  return latestWebDavBackupVersionEntries(names).lastOrNull;
}
