import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/mutation_gate.dart';
import 'package:venera/foundation/comic_source/repository.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/comic_source_install_transaction.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/maintenance_coordinator.dart';
import 'package:venera/utils/translations.dart';

final _comicSourceMutationGate = ComicSourceMutationGate();

Future<bool> _runComicSourceMutation(Future<void> Function() operation) async {
  final ran = await _comicSourceMutationGate.run(operation);
  if (!ran) {
    App.rootContext.showMessage(
      message: 'Another comic source operation is in progress'.tl,
    );
  }
  return ran;
}

List<ComicSourceRepository> _configuredComicSourceRepositories() {
  return readComicSourceRepositories(
    storedRepositories: appdata.settings['comicSourceRepositories'],
    legacyUrl: appdata.settings['comicSourceListUrl'],
  );
}

Map<String, Map<String, dynamic>> _comicSourceRepositoryBindings() {
  final stored = appdata.settings['comicSourceRepositoryBindings'];
  if (stored is! Map) return <String, Map<String, dynamic>>{};
  final result = <String, Map<String, dynamic>>{};
  for (final entry in stored.entries) {
    if (entry.key is! String || entry.value is! Map) continue;
    final binding = entry.value as Map;
    final repositoryId = binding['repositoryId'];
    final downloadUrl = binding['downloadUrl'];
    final repositoryIndexUrl = binding['repositoryIndexUrl'];
    final finalDownloadUrl = binding['finalDownloadUrl'];
    final version = binding['version'];
    if (repositoryId is! String ||
        repositoryId.isEmpty ||
        downloadUrl is! String) {
      continue;
    }
    try {
      final normalizedDownloadUrl = normalizeComicSourceRepositoryUrl(
        downloadUrl,
      );
      final normalizedIndexUrl = repositoryIndexUrl is String
          ? normalizeComicSourceRepositoryUrl(repositoryIndexUrl)
          : null;
      final normalizedFinalDownloadUrl = finalDownloadUrl is String
          ? normalizeComicSourceRepositoryUrl(finalDownloadUrl)
          : null;
      final normalizedVersion =
          version is String && parseComicSourceVersion(version.trim()) != null
          ? version.trim()
          : null;
      result[entry.key as String] = <String, dynamic>{
        'repositoryId': repositoryId,
        'downloadUrl': normalizedDownloadUrl,
        if (normalizedIndexUrl != null)
          'repositoryIndexUrl': normalizedIndexUrl,
        if (normalizedFinalDownloadUrl != null)
          'finalDownloadUrl': normalizedFinalDownloadUrl,
        if (normalizedVersion != null) 'version': normalizedVersion,
      };
    } on FormatException {
      continue;
    }
  }
  return result;
}

Future<void> _saveComicSourceRepositories(
  List<ComicSourceRepository> repositories,
) async {
  final normalized = normalizeComicSourceRepositories(repositories);
  appdata.settings['comicSourceRepositories'] = normalized
      .map((repository) => repository.toJson())
      .toList(growable: false);
  appdata.settings['comicSourceListUrl'] = legacyComicSourceRepositoryUrl(
    normalized,
  );
  appdata.settings['comicSourceRepositoriesLegacyMirror'] =
      appdata.settings['comicSourceListUrl'];
  appdata.settings['comicSourceLegacyUrlNeedsReview'] = null;
  await appdata.saveData();
}

const _comicSourceManagedSettingKeys = <String>[
  'explore_pages',
  'categories',
  'favorites',
  'searchSources',
  'comicSourceRepositoryBindings',
];

Map<String, dynamic> _snapshotComicSourceSettings() => <String, dynamic>{
  for (final key in _comicSourceManagedSettingKeys)
    key: jsonDecode(jsonEncode(appdata.settings[key])),
};

void _restoreComicSourceSettings(Map<String, dynamic> snapshot) {
  for (final key in _comicSourceManagedSettingKeys) {
    appdata.settings[key] = snapshot[key];
  }
}

bool _sameComicSourceBinding(
  Map<String, dynamic>? first,
  Map<String, dynamic>? second,
) {
  if (first == null || second == null) return first == null && second == null;
  if (first.length != second.length) return false;
  return first.entries.every((entry) => second[entry.key] == entry.value);
}

bool _sameComicSourceFileAndVersion(ComicSource current, ComicSource expected) {
  return current.key == expected.key &&
      current.version == expected.version &&
      p.equals(p.normalize(current.filePath), p.normalize(expected.filePath));
}

Never _throwComicSourceChangedDuringOperation() {
  throw StateError('Comic source changed while the operation was waiting');
}

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    await _runComicSourceMutation(() => _updateUnlocked(source, showLoading));
  }

  static Future<void> _updateUnlocked(
    ComicSource source,
    bool showLoading,
  ) async {
    final manager = ComicSourceManager();
    final binding = _comicSourceRepositoryBindings()[source.key];
    var repositoryUpdateUrl =
        manager.availableUpdateUrl(source.key) ??
        binding?['downloadUrl'] as String?;
    var expectedRepositoryVersion = manager.availableUpdates[source.key];
    bool cancel = false;
    LoadingDialogController? controller;
    if (showLoading) {
      controller = showLoadingDialog(
        App.rootContext,
        onCancel: () => cancel = true,
        barrierDismissible: false,
      );
    }
    try {
      if (binding != null && expectedRepositoryVersion == null) {
        final checked = await checkComicSourceUpdate();
        if (cancel) return;
        if (checked < 0) {
          throw const ComicSourceRepositoryException(
            'Failed to check repository updates',
          );
        }
        expectedRepositoryVersion = manager.availableUpdates[source.key];
        repositoryUpdateUrl = manager.availableUpdateUrl(source.key);
        if (expectedRepositoryVersion == null || repositoryUpdateUrl == null) {
          if (showLoading) {
            App.rootContext.showMessage(message: 'No updates found'.tl);
            return;
          }
          throw const ComicSourceRepositoryException('No updates found');
        }
      }
      final downloadUrl = repositoryUpdateUrl ?? source.url;
      if (repositoryUpdateUrl == null && !downloadUrl.isURL) {
        if (showLoading) {
          App.rootContext.showMessage(message: 'Invalid url config'.tl);
          return;
        }
        throw const ComicSourceRepositoryException('Invalid url config');
      }
      late final String script;
      Uri? finalRepositoryScriptUri;
      if (repositoryUpdateUrl != null) {
        final document = await fetchComicSourceDocument(
          Uri.parse(repositoryUpdateUrl),
          maxComicSourceScriptBytes,
        );
        script = document.text;
        finalRepositoryScriptUri = document.finalUri;
        if (cancel) return;
        final previousFinalUrl = binding?['finalDownloadUrl'];
        if (previousFinalUrl is String &&
            !sameComicSourceRepositoryOrigin(
              Uri.parse(previousFinalUrl),
              document.finalUri,
            )) {
          controller?.close();
          controller = null;
          final trusted = await _confirmRepositoryRedirectChange(
            Uri.parse(previousFinalUrl),
            document.finalUri,
          );
          if (!trusted) return;
        }
      } else {
        final response = await AppDio().get<String>(
          downloadUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: {"cache-time": "no"},
          ),
        );
        script = response.data!;
      }
      if (cancel) return;
      await MaintenanceCoordinator.instance.run(
        'Manage Comic Sources',
        () async {
          if (cancel) return;
          final lockedSource = manager.find(source.key);
          final lockedBinding = _comicSourceRepositoryBindings()[source.key];
          if (!identical(lockedSource, source) ||
              !_sameComicSourceBinding(lockedBinding, binding)) {
            _throwComicSourceChangedDuringOperation();
          }
          ComicSource? parsed;
          try {
            parsed = await ComicSourceParser().parse(
              script,
              source.filePath,
              loadData: false,
              runInit: false,
            );
            if (parsed.key != source.key) {
              throw ComicSourceParseException(
                'Updated source key does not match the repository entry',
              );
            }
            if (expectedRepositoryVersion != null &&
                parsed.version != expectedRepositoryVersion) {
              throw ComicSourceParseException(
                'Updated source version does not match the repository entry',
              );
            }
          } finally {
            await manager.reload(preserveAvailableUpdates: true);
          }
          if (cancel) return;
          Map<String, dynamic>? newBinding;
          if (binding != null && finalRepositoryScriptUri != null) {
            newBinding = <String, dynamic>{
              ...binding,
              'version': parsed.version,
              'finalDownloadUrl': normalizeComicSourceRepositoryUrl(
                finalRepositoryScriptUri.toString(),
              ),
            };
          }
          final settingsSnapshot = _snapshotComicSourceSettings();
          final transaction = await ComicSourceInstallTransaction.prepare(
            dataRoot: App.dataPath,
            kind: 'update',
            sourceKey: source.key,
            expectedVersion: parsed.version,
            destination: io.File(source.filePath),
            newScript: script,
            beforeSettings: settingsSnapshot,
            newBinding: newBinding,
            clearSourceData: false,
          );
          if (cancel) {
            await transaction.rollback((beforeSettings) async {
              _restoreComicSourceSettings(beforeSettings);
              await appdata.saveData(false);
            });
            return;
          }
          try {
            final publicationSource = manager.find(source.key);
            if (publicationSource == null ||
                !_sameComicSourceFileAndVersion(publicationSource, source) ||
                !await manager.retireDataWrites(
                  source.key,
                  expected: publicationSource,
                )) {
              _throwComicSourceChangedDuringOperation();
            }
            // Publication is intentionally non-interruptible once it starts.
            // Close the cancellable loading UI before the atomic commit window.
            controller?.close();
            controller = null;
            await transaction.publish();
            await manager.reload(preserveAvailableUpdates: true);
            final installed = manager.find(source.key);
            if (installed == null ||
                installed.version != parsed.version ||
                !p.equals(
                  p.normalize(installed.filePath),
                  p.normalize(io.File(source.filePath).absolute.path),
                )) {
              throw ComicSourceParseException(
                'Updated source failed to reload',
              );
            }
            if (newBinding != null) {
              final bindings = _comicSourceRepositoryBindings();
              bindings[source.key] = newBinding;
              appdata.settings['comicSourceRepositoryBindings'] = bindings;
            }
            await appdata.saveData(false);
            await transaction.commit();
            unawaited(appdata.saveData());
            manager.clearAvailableUpdate(source.key);
          } catch (error, stackTrace) {
            try {
              await transaction.rollback((beforeSettings) async {
                _restoreComicSourceSettings(beforeSettings);
                await appdata.saveData(false);
              });
              await manager.reload(preserveAvailableUpdates: true);
            } catch (rollbackError, rollbackStackTrace) {
              Log.error(
                'Update comic source rollback',
                '$rollbackError\n$rollbackStackTrace',
              );
            }
            Error.throwWithStackTrace(error, stackTrace);
          }
        },
      );
    } catch (e) {
      if (cancel) return;
      if (showLoading) {
        App.rootContext.showMessage(message: e.toString().tl);
      } else {
        rethrow;
      }
    } finally {
      controller?.close();
    }
    if (showLoading) {
      App.forceRebuild();
    }
  }

  static Future<bool> _confirmRepositoryRedirectChange(
    Uri previous,
    Uri current,
  ) async {
    return await showDialog<bool>(
          context: App.rootContext,
          builder: (dialogContext) => AlertDialog(
            title: Text('Source download host changed'.tl),
            content: Text(
              'The source download moved from @oldHost to @newHost. Continue only if you trust the new host.'
                  .tlParams({
                    'oldHost': previous.host,
                    'newHost': current.host,
                  }),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text('Cancel'.tl),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text('Continue'.tl),
              ),
            ],
          ),
        ) ??
        false;
  }

  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      ComicSourceManager().replaceAvailableUpdates(const <String, String>{});
      return 0;
    }
    final repositories = _configuredComicSourceRepositories();
    final catalog = await const ComicSourceRepositoryService().load(
      repositories,
    );
    for (final failure in catalog.failures) {
      Log.warning(
        'Comic source repository',
        '${failure.repository.name}: ${failure.message}',
      );
    }
    if (catalog.snapshots.isEmpty && catalog.failures.isNotEmpty) {
      ComicSourceManager().replaceAvailableUpdates(const <String, String>{});
      return -1;
    }
    final bindings = _comicSourceRepositoryBindings();
    final installed = ComicSource.all().map((source) {
      final binding = bindings[source.key];
      return InstalledComicSourceVersion(
        key: source.key,
        version: source.version,
        updateUrl: source.url,
        repositoryId: binding?['repositoryId'] as String?,
        boundDownloadUrl: binding?['downloadUrl'] as String?,
      );
    });
    final candidates = selectComicSourceUpdates(
      installedSources: installed,
      entries: catalog.entries,
    );
    ComicSourceManager().replaceAvailableUpdates(
      candidates.map((key, entry) => MapEntry(key, entry.version)),
      downloadUrls: candidates.map(
        (key, entry) => MapEntry(key, entry.downloadUrl),
      ),
    );
    return candidates.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";

  void updateUI() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
    _comicSourceMutationGate.addListener(updateUI);
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(updateUI);
    _comicSourceMutationGate.removeListener(updateUI);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await _runComicSourceMutation(() async {
          final manager = ComicSourceManager();
          if (!await manager.retireDataWrites(source.key, expected: source)) {
            _throwComicSourceChangedDuringOperation();
          }
          var file = File(source.filePath);
          await file.delete();
          manager.remove(source.key);
          final bindings = _comicSourceRepositoryBindings();
          if (bindings.remove(source.key) != null) {
            appdata.settings['comicSourceRepositoryBindings'] = bindings;
            await appdata.saveData();
          }
          _validatePages();
          App.forceRebuild();
        });
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: const Text("Reload Configs"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("cancel"),
              ),
              TextButton(
                onPressed: () async {
                  await _runComicSourceMutation(() async {
                    await ComicSourceManager().reload();
                    App.forceRebuild();
                  });
                },
                child: const Text("continue"),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await _runComicSourceMutation(() async {
          await ComicSourceManager().reload();
          if (mounted) setState(() {});
        });
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text("Add comic source".tl),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
              decoration: InputDecoration(
                hintText: "URL",
                border: const UnderlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffix: IconButton(
                  onPressed: _comicSourceMutationGate.isActive
                      ? null
                      : () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: _comicSourceMutationGate.isActive
                  ? null
                  : handleAddSource,
            ).paddingHorizontal(16).paddingBottom(8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: Icon(Icons.article_outlined),
                  label: Text("Comic Source list".tl),
                  onPressed: _comicSourceMutationGate.isActive
                      ? null
                      : () {
                          showPopUpWidget(
                            App.rootContext,
                            _ComicSourceList(handleAddRepositorySource),
                          );
                        },
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _comicSourceMutationGate.isActive
                      ? null
                      : _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
              ],
            ).paddingHorizontal(12).paddingVertical(8),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await _runComicSourceMutation(() => addSource(content, fileName));
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString().tl);
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/casthan321/Venera-Community/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddRepositorySource(ComicSourceManifestEntry entry) {
    return handleAddSource(entry.downloadUrl, repositoryEntry: entry);
  }

  Future<void> handleAddSource(
    String url, {
    ComicSourceManifestEntry? repositoryEntry,
  }) {
    return _runComicSourceMutation(
      () => _handleAddSourceUnlocked(url, repositoryEntry: repositoryEntry),
    ).then((_) {});
  }

  Future<void> _handleAddSourceUnlocked(
    String url, {
    ComicSourceManifestEntry? repositoryEntry,
  }) async {
    if (url.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(url.trim());
    var fileName = repositoryEntry == null
        ? (uri?.pathSegments.lastOrNull ?? 'source.js')
        : '${repositoryEntry.key}.js';
    fileName = sanitizeFileName(fileName, maxLength: 100);
    if (fileName.trim().isEmpty) fileName = 'source.js';
    bool cancel = false;
    var loadingClosed = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      late final String script;
      Uri? finalRepositoryScriptUri;
      if (repositoryEntry != null) {
        final document = await fetchComicSourceDocument(
          Uri.parse(repositoryEntry.downloadUrl),
          maxComicSourceScriptBytes,
        );
        script = document.text;
        finalRepositoryScriptUri = document.finalUri;
        if (cancel) return;
        controller.close();
        loadingClosed = true;
        final confirmed = await _confirmRepositorySourceInstall(
          repositoryEntry,
          document.finalUri,
          replacingExisting: ComicSource.find(repositoryEntry.key) != null,
        );
        if (!confirmed) return;
      } else {
        final response = await AppDio().get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: {"cache-time": "no"},
          ),
        );
        script = response.data!;
      }
      if (cancel) return;
      final existingSource = repositoryEntry == null
          ? null
          : ComicSource.find(repositoryEntry.key);
      if (existingSource == null) {
        await addSource(
          script,
          fileName,
          repositoryEntry: repositoryEntry,
          finalRepositoryScriptUri: finalRepositoryScriptUri,
        );
      } else {
        await _replaceSourceFromRepository(
          existingSource,
          script,
          repositoryEntry!,
          finalRepositoryScriptUri!,
        );
      }
    } catch (e, s) {
      if (cancel) return;
      context.showMessage(message: e.toString().tl);
      Log.error("Add comic source", "$e\n$s");
    } finally {
      if (!loadingClosed) controller.close();
    }
  }

  Future<bool> _confirmRepositorySourceInstall(
    ComicSourceManifestEntry entry,
    Uri finalScriptUri, {
    required bool replacingExisting,
  }) async {
    final repositoryHost = Uri.parse(entry.repositoryIndexUrl).host;
    final requestedHost = Uri.parse(entry.downloadUrl).host;
    return await showDialog<bool>(
          context: App.rootContext,
          builder: (dialogContext) => AlertDialog(
            title: Text('Trust and install source?'.tl),
            content: Text(
              <String>[
                'Comic sources execute JavaScript code. Only continue if you trust @source from @repo. Repository: @repositoryHost. Requested script: @requestedHost. Final script: @finalHost.'
                    .tlParams({
                      'source': entry.name,
                      'repo': entry.repositoryName,
                      'repositoryHost': repositoryHost,
                      'requestedHost': requestedHost,
                      'finalHost': finalScriptUri.host,
                    }),
                if (replacingExisting)
                  'This will replace the installed source with the same key.'
                      .tl,
                if (replacingExisting)
                  'Switching repositories clears the existing source account, password, and private data.'
                      .tl,
              ].join('\n\n'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text('Cancel'.tl),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text('Install'.tl),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> addSource(
    String js,
    String fileName, {
    ComicSourceManifestEntry? repositoryEntry,
    Uri? finalRepositoryScriptUri,
  }) async {
    if (repositoryEntry != null && finalRepositoryScriptUri != null) {
      await _installRepositorySource(
        js,
        fileName,
        repositoryEntry,
        finalRepositoryScriptUri,
      );
      return;
    }
    final settingsSnapshot = _snapshotComicSourceSettings();
    ComicSource? comicSource;
    try {
      comicSource = await ComicSourceParser().createAndParse(js, fileName);
      if (repositoryEntry != null &&
          (comicSource.key != repositoryEntry.key ||
              comicSource.version != repositoryEntry.version)) {
        throw ComicSourceParseException(
          'Downloaded source does not match the repository entry',
        );
      }
      ComicSourceManager().add(comicSource);
      _addAllPagesWithComicSource(comicSource);
      if (repositoryEntry != null) {
        final bindings = _comicSourceRepositoryBindings();
        bindings[comicSource.key] = <String, dynamic>{
          'repositoryId': repositoryEntry.repositoryId,
          'repositoryIndexUrl': repositoryEntry.repositoryIndexUrl,
          'downloadUrl': repositoryEntry.downloadUrl,
          if (finalRepositoryScriptUri != null)
            'finalDownloadUrl': normalizeComicSourceRepositoryUrl(
              finalRepositoryScriptUri.toString(),
            ),
        };
        appdata.settings['comicSourceRepositoryBindings'] = bindings;
      }
      await appdata.saveData();
      App.forceRebuild();
    } catch (error, stackTrace) {
      if (comicSource != null) {
        await File(comicSource.filePath).deleteIgnoreError();
      }
      _restoreComicSourceSettings(settingsSnapshot);
      try {
        await ComicSourceManager().reload(preserveAvailableUpdates: true);
        await appdata.saveData();
      } catch (rollbackError, rollbackStackTrace) {
        Log.error(
          'Add comic source rollback',
          '$rollbackError\n$rollbackStackTrace',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _installRepositorySource(
    String script,
    String fileName,
    ComicSourceManifestEntry repositoryEntry,
    Uri finalRepositoryScriptUri,
  ) async {
    await MaintenanceCoordinator.instance.run('Manage Comic Sources', () async {
      final manager = ComicSourceManager();
      if (manager.find(repositoryEntry.key) != null) {
        _throwComicSourceChangedDuringOperation();
      }
      final destination = await _availableComicSourceFile(fileName);
      ComicSource? parsed;
      try {
        parsed = await ComicSourceParser().parse(
          script,
          destination.path,
          loadData: false,
          runInit: false,
        );
        if (parsed.key != repositoryEntry.key ||
            parsed.version != repositoryEntry.version) {
          throw ComicSourceParseException(
            'Downloaded source does not match the repository entry',
          );
        }
      } finally {
        await manager.reload(preserveAvailableUpdates: true);
      }
      final settingsSnapshot = _snapshotComicSourceSettings();
      final binding = _repositoryBinding(
        repositoryEntry,
        finalRepositoryScriptUri,
      );
      final transaction = await ComicSourceInstallTransaction.prepare(
        dataRoot: App.dataPath,
        kind: 'install',
        sourceKey: parsed.key,
        expectedVersion: parsed.version,
        destination: destination,
        newScript: script,
        beforeSettings: settingsSnapshot,
        newBinding: binding,
        // A previously deleted source can leave <key>.data behind.  A fresh
        // repository install must not silently hand that private state to a
        // newly downloaded script with the same key.
        clearSourceData: true,
      );
      try {
        if (manager.find(parsed.key) != null) {
          _throwComicSourceChangedDuringOperation();
        }
        await transaction.publish();
        await manager.reload(preserveAvailableUpdates: true);
        final installed = manager.find(parsed.key);
        if (installed == null ||
            installed.version != parsed.version ||
            !p.equals(
              p.normalize(installed.filePath),
              p.normalize(destination.absolute.path),
            )) {
          throw ComicSourceParseException('Updated source failed to reload');
        }
        _addAllPagesWithComicSource(installed);
        final bindings = _comicSourceRepositoryBindings();
        bindings[installed.key] = binding;
        appdata.settings['comicSourceRepositoryBindings'] = bindings;
        await appdata.saveData(false);
        await transaction.commit();
        unawaited(appdata.saveData());
        App.forceRebuild();
      } catch (error, stackTrace) {
        try {
          await transaction.rollback((beforeSettings) async {
            _restoreComicSourceSettings(beforeSettings);
            await appdata.saveData(false);
          });
          await manager.reload(preserveAvailableUpdates: true);
        } catch (rollbackError, rollbackStackTrace) {
          Log.error(
            'Add comic source rollback',
            '$rollbackError\n$rollbackStackTrace',
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  Future<void> _replaceSourceFromRepository(
    ComicSource existing,
    String script,
    ComicSourceManifestEntry repositoryEntry,
    Uri finalRepositoryScriptUri,
  ) async {
    final bindingSnapshot = _comicSourceRepositoryBindings()[existing.key];
    await MaintenanceCoordinator.instance.run('Manage Comic Sources', () async {
      final manager = ComicSourceManager();
      final lockedSource = manager.find(existing.key);
      final lockedBinding = _comicSourceRepositoryBindings()[existing.key];
      if (!identical(lockedSource, existing) ||
          !_sameComicSourceBinding(lockedBinding, bindingSnapshot)) {
        _throwComicSourceChangedDuringOperation();
      }
      ComicSource? parsed;
      try {
        parsed = await ComicSourceParser().parse(
          script,
          existing.filePath,
          loadData: false,
          runInit: false,
        );
        if (parsed.key != repositoryEntry.key ||
            parsed.version != repositoryEntry.version) {
          throw ComicSourceParseException(
            'Downloaded source does not match the repository entry',
          );
        }
      } finally {
        await manager.reload(preserveAvailableUpdates: true);
      }
      final settingsSnapshot = _snapshotComicSourceSettings();
      final binding = _repositoryBinding(
        repositoryEntry,
        finalRepositoryScriptUri,
      );
      final transaction = await ComicSourceInstallTransaction.prepare(
        dataRoot: App.dataPath,
        kind: 'switch',
        sourceKey: existing.key,
        expectedVersion: parsed.version,
        destination: File(existing.filePath),
        newScript: script,
        beforeSettings: settingsSnapshot,
        newBinding: binding,
        clearSourceData: true,
      );
      try {
        final publicationSource = manager.find(existing.key);
        if (publicationSource == null ||
            !_sameComicSourceFileAndVersion(publicationSource, existing) ||
            !await manager.retireDataWrites(
              existing.key,
              expected: publicationSource,
            )) {
          _throwComicSourceChangedDuringOperation();
        }
        await transaction.publish();
        await manager.reload(preserveAvailableUpdates: true);
        final installed = manager.find(repositoryEntry.key);
        if (installed == null ||
            installed.version != repositoryEntry.version ||
            !p.equals(
              p.normalize(installed.filePath),
              p.normalize(File(existing.filePath).absolute.path),
            )) {
          throw ComicSourceParseException('Updated source failed to reload');
        }
        _validatePages();
        _addAllPagesWithComicSource(installed);
        final bindings = _comicSourceRepositoryBindings();
        bindings[installed.key] = binding;
        appdata.settings['comicSourceRepositoryBindings'] = bindings;
        await appdata.saveData(false);
        await transaction.commit();
        unawaited(appdata.saveData());
        manager.clearAvailableUpdate(installed.key);
        App.forceRebuild();
      } catch (error, stackTrace) {
        try {
          await transaction.rollback((beforeSettings) async {
            _restoreComicSourceSettings(beforeSettings);
            await appdata.saveData(false);
          });
          await manager.reload(preserveAvailableUpdates: true);
        } catch (rollbackError, rollbackStackTrace) {
          Log.error(
            'Replace comic source rollback',
            '$rollbackError\n$rollbackStackTrace',
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  Future<File> _availableComicSourceFile(String fileName) async {
    final directory = Directory(FilePath.join(App.dataPath, 'comic_source'));
    await directory.create(recursive: true);
    final extension = fileName.toLowerCase().endsWith('.js') ? '' : '.js';
    final safeName = '$fileName$extension';
    var candidate = File(FilePath.join(directory.path, safeName));
    var suffix = 0;
    final base = p.basenameWithoutExtension(safeName);
    while (await candidate.exists()) {
      candidate = File(FilePath.join(directory.path, '$base(${suffix++}).js'));
    }
    return candidate;
  }

  Map<String, dynamic> _repositoryBinding(
    ComicSourceManifestEntry entry,
    Uri finalScriptUri,
  ) {
    return <String, dynamic>{
      'repositoryId': entry.repositoryId,
      'repositoryIndexUrl': entry.repositoryIndexUrl,
      'downloadUrl': entry.downloadUrl,
      'version': entry.version,
      'finalDownloadUrl': normalizeComicSourceRepositoryUrl(
        finalScriptUri.toString(),
      ),
    };
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(ComicSourceManifestEntry) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  static const _newRepository = '__new_repository__';

  late List<ComicSourceRepository> repositories;
  late final TextEditingController repositoryUrlController;
  ComicSourceRepositoryCatalog? catalog;
  bool isLoading = false;
  bool isSavingRepositories = false;
  bool isAddingRepository = false;
  bool repositoryUrlDirty = false;
  int loadGeneration = 0;
  String selectedRepositoryId = _newRepository;
  late String persistedSelectedRepositoryId;

  @override
  void initState() {
    super.initState();
    repositories = _configuredComicSourceRepositories();
    final savedSelection = appdata.settings['comicSourceSelectedRepositoryId'];
    final enabled = repositories.where((repository) => repository.enabled);
    selectedRepositoryId =
        savedSelection is String &&
            repositories.any((repository) => repository.id == savedSelection)
        ? savedSelection
        : enabled.firstOrNull?.id ??
              repositories.firstOrNull?.id ??
              _newRepository;
    persistedSelectedRepositoryId = selectedRepositoryId;
    isAddingRepository = selectedRepositoryId == _newRepository;
    repositoryUrlController = TextEditingController(
      text: _selectedRepository?.indexUrl ?? '',
    );
    _comicSourceMutationGate.addListener(_handleMutationChanged);
    unawaited(load());
  }

  void _handleMutationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    loadGeneration++;
    _comicSourceMutationGate.removeListener(_handleMutationChanged);
    repositoryUrlController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++loadGeneration;
    setState(() {
      isLoading = true;
      catalog = null;
    });
    final selected = _selectedRepository;
    final repositoriesToLoad = selected == null
        ? const <ComicSourceRepository>[]
        : <ComicSourceRepository>[selected];
    final result = await const ComicSourceRepositoryService().load(
      repositoriesToLoad,
    );
    if (!mounted || generation != loadGeneration) return;
    setState(() {
      catalog = result;
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Comic Source list".tl,
      body: buildBody(),
    );
  }

  Widget buildBody() {
    final currentSources = <String, ComicSource>{
      for (final source in ComicSource.all()) source.key: source,
    };
    final bindings = _comicSourceRepositoryBindings();
    final entries = (catalog?.entries ?? const <ComicSourceManifestEntry>[])
        .where((entry) => entry.repositoryId == selectedRepositoryId)
        .toList(growable: false);

    return ListView.builder(
      itemCount: entries.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _buildRepositoryPanel();
        if (index == 1) return _buildCatalogStatus(entries.length);
        final entry = entries[index - 2];
        final installedSource = currentSources[entry.key];
        final installed = installedSource != null;
        final installedFromThisEntry =
            installedSource != null &&
            _entryMatchesInstalledSource(
              entry,
              installedSource,
              bindings[entry.key],
            );
        return ListTile(
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            <String>[
              entry.version,
              if (entry.description != null) entry.description!,
              'Source from @repo'.tlParams({'repo': entry.repositoryName}),
            ].join('\n'),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: installedFromThisEntry
              ? Semantics(
                  label: 'Installed'.tl,
                  child: const Icon(Icons.check, size: 20).paddingRight(8),
                )
              : installed
              ? FilledButton.tonal(
                  onPressed:
                      isLoading ||
                          isSavingRepositories ||
                          _comicSourceMutationGate.isActive
                      ? null
                      : () => _confirmInstall(entry),
                  child: Semantics(
                    label: 'Switch to @source'.tlParams({'source': entry.name}),
                    button: true,
                    child: ExcludeSemantics(child: Text('Switch'.tl)),
                  ),
                )
              : FilledButton.tonal(
                  onPressed:
                      isLoading ||
                          isSavingRepositories ||
                          _comicSourceMutationGate.isActive
                      ? null
                      : () => _confirmInstall(entry),
                  child: Semantics(
                    label: 'Add @source'.tlParams({'source': entry.name}),
                    button: true,
                    child: ExcludeSemantics(child: Text('Add'.tl)),
                  ),
                ),
        );
      },
    );
  }

  bool _entryMatchesInstalledSource(
    ComicSourceManifestEntry entry,
    ComicSource source,
    Map<String, dynamic>? binding,
  ) {
    if (binding != null) {
      return binding['repositoryId'] == entry.repositoryId &&
          binding['downloadUrl'] == entry.downloadUrl;
    }
    try {
      return normalizeComicSourceRepositoryUrl(source.url) == entry.downloadUrl;
    } on FormatException {
      return false;
    }
  }

  Widget _buildRepositoryPanel() {
    final selected = _selectedRepository;
    final editingUrl = isAddingRepository || selected != null;
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text('Repository URL'.tl),
            subtitle: Text(
              'Select, add, and save repository addresses here.'.tl,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(selectedRepositoryId),
                    isExpanded: true,
                    initialValue: selectedRepositoryId,
                    decoration: InputDecoration(
                      labelText: 'Saved repositories'.tl,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final repository in repositories)
                        DropdownMenuItem(
                          value: repository.id,
                          child: Text(
                            repository.enabled
                                ? repository.name
                                : '@name (disabled)'.tlParams({
                                    'name': repository.name,
                                  }),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (isAddingRepository)
                        DropdownMenuItem(
                          value: _newRepository,
                          child: Text('New repository'.tl),
                        ),
                    ],
                    onChanged:
                        isSavingRepositories ||
                            _comicSourceMutationGate.isActive
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(_selectRepository(value));
                            }
                          },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Add repository'.tl,
                  onPressed:
                      isSavingRepositories || _comicSourceMutationGate.isActive
                      ? null
                      : _startAddingRepository,
                  icon: const Icon(Icons.add),
                ),
                if (selected != null)
                  PopupMenuButton<_RepositoryAction>(
                    enabled:
                        !isSavingRepositories &&
                        !_comicSourceMutationGate.isActive,
                    tooltip: 'Actions for @name'.tlParams({
                      'name': selected.name,
                    }),
                    onSelected: (action) {
                      final index = repositories.indexWhere(
                        (repository) => repository.id == selected.id,
                      );
                      if (index >= 0) _handleRepositoryAction(action, index);
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _RepositoryAction.test,
                        child: Text('Test connection'.tl),
                      ),
                      PopupMenuItem(
                        value: _RepositoryAction.edit,
                        child: Text('Edit repository details'.tl),
                      ),
                      PopupMenuItem(
                        value: _RepositoryAction.moveUp,
                        enabled: repositories.indexOf(selected) > 0,
                        child: Text('Move up'.tl),
                      ),
                      PopupMenuItem(
                        value: _RepositoryAction.moveDown,
                        enabled:
                            repositories.indexOf(selected) + 1 <
                            repositories.length,
                        child: Text('Move down'.tl),
                      ),
                      PopupMenuItem(
                        value: _RepositoryAction.delete,
                        child: Text('Delete'.tl),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: repositoryUrlController,
              enabled:
                  editingUrl &&
                  !isSavingRepositories &&
                  !_comicSourceMutationGate.isActive,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(
                labelText: 'Repository URL'.tl,
                hintText: 'https://example.com/index.json',
                helperText: isAddingRepository
                    ? 'Enter a repository address and save it.'.tl
                    : "The URL should point to a 'index.json' file".tl,
              ),
              onChanged: (_) => setState(() => repositoryUrlDirty = true),
              onSubmitted: (_) => unawaited(_saveInlineRepository()),
            ),
          ),
          if (appdata.settings['comicSourceLegacyUrlNeedsReview'] is String)
            ListTile(
              leading: Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text('Legacy repository needs review'.tl),
              subtitle: SelectableText(
                'For security, this old HTTP repository was disabled. Add an HTTPS replacement: @url'
                    .tlParams({
                      'url':
                          appdata.settings['comicSourceLegacyUrlNeedsReview']
                              as String,
                    }),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => launchUrlString(
                    'https://github.com/casthan321/Venera-Community/blob/master/doc/comic_source.md',
                  ),
                  icon: const Icon(Icons.help_outline),
                  label: Text('Help'.tl),
                ),
                if (isAddingRepository || repositoryUrlDirty)
                  TextButton(
                    onPressed:
                        isSavingRepositories ||
                            _comicSourceMutationGate.isActive
                        ? null
                        : _cancelInlineRepositoryEdit,
                    child: Text('Cancel'.tl),
                  ),
                if (isAddingRepository || repositoryUrlDirty)
                  FilledButton.tonalIcon(
                    onPressed:
                        isSavingRepositories ||
                            _comicSourceMutationGate.isActive
                        ? null
                        : _saveInlineRepository,
                    icon: const Icon(Icons.save_outlined),
                    label: Text('Save'.tl),
                  ),
                FilledButton.tonalIcon(
                  onPressed: isLoading || isSavingRepositories ? null : load,
                  icon: const Icon(Icons.refresh),
                  label: Text('Refresh'.tl),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Repository addresses are saved. Select one to show its sources below.'
                  .tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogStatus(int visibleEntryCount) {
    final enabled = repositories
        .where((repository) => repository.enabled)
        .toList(growable: false);
    final failures =
        catalog?.failures ?? const <ComicSourceRepositoryFailure>[];
    final invalidEntries =
        catalog?.snapshots.fold<int>(
          0,
          (total, snapshot) => total + snapshot.invalidEntryCount,
        ) ??
        0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isLoading)
            const LinearProgressIndicator().paddingTop(8)
          else if (isAddingRepository)
            _statusText('Save the new repository to load its sources'.tl)
          else if (repositories.isEmpty)
            _statusText('No saved repositories'.tl)
          else if (_selectedRepository != null && !_selectedRepository!.enabled)
            _statusText('Selected repository is disabled'.tl)
          else if (enabled.isEmpty)
            _statusText('No enabled repositories'.tl)
          else if (catalog != null && visibleEntryCount == 0)
            _statusText('No comic sources found'.tl),
          if (failures.isNotEmpty)
            _statusText(
              '@count repositories failed to load: @names'.tlParams({
                'count': failures.length.toString(),
                'names': failures
                    .map((failure) => failure.repository.name)
                    .join(', '),
              }),
              isError: true,
            ),
          if (invalidEntries > 0)
            _statusText(
              '@count invalid repository entries were ignored'.tlParams({
                'count': invalidEntries.toString(),
              }),
              isError: true,
            ),
        ],
      ),
    );
  }

  Widget _statusText(String text, {bool isError = false}) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          text,
          style: TextStyle(
            color: isError ? Theme.of(context).colorScheme.error : null,
          ),
        ),
      ),
    );
  }

  Future<void> _confirmInstall(ComicSourceManifestEntry entry) async {
    await widget.onAdd(entry);
    if (mounted) setState(() {});
  }

  ComicSourceRepository? get _selectedRepository => repositories
      .firstWhereOrNull((repository) => repository.id == selectedRepositoryId);

  Future<void> _selectRepository(String id) async {
    if (isSavingRepositories || _comicSourceMutationGate.isActive) return;
    final repository = repositories.firstWhereOrNull(
      (candidate) => candidate.id == id,
    );
    if (repository == null) return;
    final previousSelection = persistedSelectedRepositoryId;
    setState(() {
      selectedRepositoryId = id;
      isAddingRepository = false;
      repositoryUrlDirty = false;
      repositoryUrlController.text = repository.indexUrl;
      isSavingRepositories = true;
      catalog = null;
    });
    appdata.settings['comicSourceSelectedRepositoryId'] = id;
    try {
      await appdata.saveData(false);
      persistedSelectedRepositoryId = id;
      if (mounted) await load();
    } catch (error, stackTrace) {
      appdata.settings['comicSourceSelectedRepositoryId'] =
          previousSelection == _newRepository ? null : previousSelection;
      try {
        await appdata.saveData(false);
      } catch (rollbackError, rollbackStackTrace) {
        Log.error(
          'Comic source repository selection rollback',
          '$rollbackError\n$rollbackStackTrace',
        );
      }
      Log.error('Comic source repository selection', '$error\n$stackTrace');
      if (mounted) {
        final previousRepository = repositories.firstWhereOrNull(
          (candidate) => candidate.id == previousSelection,
        );
        setState(() {
          selectedRepositoryId = previousSelection;
          isAddingRepository = previousSelection == _newRepository;
          repositoryUrlController.text = previousRepository?.indexUrl ?? '';
        });
        context.showMessage(message: 'Failed to save repositories'.tl);
      }
    } finally {
      if (mounted) setState(() => isSavingRepositories = false);
    }
  }

  void _startAddingRepository() {
    setState(() {
      selectedRepositoryId = _newRepository;
      isAddingRepository = true;
      repositoryUrlDirty = false;
      repositoryUrlController.clear();
    });
  }

  void _cancelInlineRepositoryEdit() {
    final nextSelection =
        repositories.any(
          (repository) => repository.id == persistedSelectedRepositoryId,
        )
        ? persistedSelectedRepositoryId
        : repositories
                  .firstWhereOrNull((repository) => repository.enabled)
                  ?.id ??
              repositories.firstOrNull?.id ??
              _newRepository;
    final repository = repositories.firstWhereOrNull(
      (candidate) => candidate.id == nextSelection,
    );
    setState(() {
      selectedRepositoryId = nextSelection;
      isAddingRepository = nextSelection == _newRepository;
      repositoryUrlDirty = false;
      repositoryUrlController.text = repository?.indexUrl ?? '';
    });
    appdata.settings['comicSourceSelectedRepositoryId'] =
        nextSelection == _newRepository ? null : nextSelection;
    unawaited(load());
  }

  Future<void> _saveInlineRepository() async {
    if (isSavingRepositories || _comicSourceMutationGate.isActive) return;
    late final String normalized;
    try {
      normalized = normalizeComicSourceRepositoryUrl(
        repositoryUrlController.text,
      );
    } on FormatException catch (error) {
      context.showMessage(message: error.message.toString().tl);
      return;
    }
    final selected = _selectedRepository;
    final selectedIndex = selected == null
        ? -1
        : repositories.indexOf(selected);
    if (repositories.asMap().entries.any(
      (entry) =>
          entry.key != selectedIndex && entry.value.indexUrl == normalized,
    )) {
      context.showMessage(message: 'Repository already exists'.tl);
      return;
    }
    final updated = List<ComicSourceRepository>.from(repositories);
    late final ComicSourceRepository saved;
    if (isAddingRepository || selected == null) {
      saved = ComicSourceRepository(
        id: comicSourceRepositoryId(normalized),
        name: repositoryNameFromUrl(normalized),
        indexUrl: normalized,
        enabled: true,
      );
      updated.add(saved);
    } else {
      saved = selected.copyWith(indexUrl: normalized, enabled: true);
      updated[selectedIndex] = saved;
    }
    await _persistAndReload(updated, selectedAfterSave: saved.id);
  }

  Future<void> _editRepository([
    ComicSourceRepository? existing,
    int? existingIndex,
  ]) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.indexUrl ?? '');
    final formKey = GlobalKey<FormState>();
    var enabled = existing?.enabled ?? true;
    final result = await showDialog<ComicSourceRepository>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? 'Add repository'.tl : 'Edit repository'.tl,
          ),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: 'Repository name'.tl,
                    ),
                    maxLength: 100,
                  ),
                  TextFormField(
                    controller: urlController,
                    decoration: InputDecoration(
                      labelText: 'Repository URL'.tl,
                      helperText:
                          "The URL should point to a 'index.json' file".tl,
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    validator: (value) {
                      try {
                        final normalized = normalizeComicSourceRepositoryUrl(
                          value ?? '',
                        );
                        final duplicate = repositories.asMap().entries.any(
                          (item) =>
                              item.key != existingIndex &&
                              item.value.indexUrl == normalized,
                        );
                        if (duplicate) return 'Repository already exists'.tl;
                        return null;
                      } on FormatException catch (error) {
                        return error.message.toString().tl;
                      }
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Enable repository'.tl),
                    value: enabled,
                    onChanged: (value) {
                      setDialogState(() => enabled = value);
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                final normalized = normalizeComicSourceRepositoryUrl(
                  urlController.text,
                );
                Navigator.pop(
                  dialogContext,
                  ComicSourceRepository(
                    id: existing?.id ?? comicSourceRepositoryId(normalized),
                    name: nameController.text.trim().isEmpty
                        ? repositoryNameFromUrl(normalized)
                        : nameController.text.trim(),
                    indexUrl: normalized,
                    enabled: enabled,
                  ),
                );
              },
              child: Text('Save'.tl),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    urlController.dispose();
    if (result == null) return;
    final updated = List<ComicSourceRepository>.from(repositories);
    if (existingIndex == null) {
      updated.add(result);
    } else {
      updated[existingIndex] = result;
    }
    await _persistAndReload(updated);
  }

  Future<void> _persistAndReload(
    List<ComicSourceRepository> updated, {
    String? selectedAfterSave,
  }) async {
    if (!mounted || isSavingRepositories) return;
    final previous = repositories;
    final previousSelection = persistedSelectedRepositoryId;
    final previousLegacyReview =
        appdata.settings['comicSourceLegacyUrlNeedsReview'];
    final normalized = normalizeComicSourceRepositories(updated);
    setState(() {
      repositories = normalized;
      isSavingRepositories = true;
      catalog = null;
      if (selectedAfterSave != null &&
          repositories.any(
            (repository) => repository.id == selectedAfterSave,
          )) {
        selectedRepositoryId = selectedAfterSave;
      }
      if (!repositories.any(
        (repository) => repository.id == selectedRepositoryId,
      )) {
        selectedRepositoryId =
            repositories
                .where((repository) => repository.enabled)
                .firstOrNull
                ?.id ??
            repositories.firstOrNull?.id ??
            _newRepository;
      }
      isAddingRepository = selectedRepositoryId == _newRepository;
      repositoryUrlDirty = false;
      repositoryUrlController.text = _selectedRepository?.indexUrl ?? '';
      appdata.settings['comicSourceSelectedRepositoryId'] =
          selectedRepositoryId == _newRepository ? null : selectedRepositoryId;
    });
    try {
      await _saveComicSourceRepositories(normalized);
      persistedSelectedRepositoryId = selectedRepositoryId;
      ComicSourceManager().replaceAvailableUpdates(const <String, String>{});
      if (!mounted) return;
      await load();
    } catch (error, stackTrace) {
      appdata.settings['comicSourceRepositories'] = previous
          .map((repository) => repository.toJson())
          .toList(growable: false);
      appdata.settings['comicSourceListUrl'] = legacyComicSourceRepositoryUrl(
        previous,
      );
      appdata.settings['comicSourceRepositoriesLegacyMirror'] =
          appdata.settings['comicSourceListUrl'];
      appdata.settings['comicSourceLegacyUrlNeedsReview'] =
          previousLegacyReview;
      appdata.settings['comicSourceSelectedRepositoryId'] =
          previousSelection == _newRepository ? null : previousSelection;
      persistedSelectedRepositoryId = previousSelection;
      try {
        await appdata.saveData(false);
      } catch (rollbackError, rollbackStackTrace) {
        Log.error(
          'Comic source repositories rollback',
          '$rollbackError\n$rollbackStackTrace',
        );
      }
      Log.error('Comic source repositories', '$error\n$stackTrace');
      if (mounted) {
        setState(() {
          repositories = previous;
          selectedRepositoryId = previousSelection;
          isAddingRepository = previousSelection == _newRepository;
          repositoryUrlDirty = false;
          repositoryUrlController.text = _selectedRepository?.indexUrl ?? '';
        });
        context.showMessage(message: 'Failed to save repositories'.tl);
      }
    } finally {
      if (mounted) setState(() => isSavingRepositories = false);
    }
  }

  void _handleRepositoryAction(_RepositoryAction action, int index) {
    switch (action) {
      case _RepositoryAction.test:
        unawaited(_testRepository(repositories[index]));
        break;
      case _RepositoryAction.edit:
        unawaited(_editRepository(repositories[index], index));
        break;
      case _RepositoryAction.moveUp:
        if (index > 0) unawaited(_moveRepository(index, index - 1));
        break;
      case _RepositoryAction.moveDown:
        if (index + 1 < repositories.length) {
          unawaited(_moveRepository(index, index + 1));
        }
        break;
      case _RepositoryAction.delete:
        unawaited(_deleteRepository(index));
        break;
    }
  }

  Future<void> _moveRepository(int from, int to) async {
    final updated = List<ComicSourceRepository>.from(repositories);
    final repository = updated.removeAt(from);
    updated.insert(to, repository);
    await _persistAndReload(updated);
  }

  Future<void> _deleteRepository(int index) async {
    final repository = repositories[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete repository?'.tl),
        content: Text(
          'Delete repository @name? Installed comic sources will be kept.'
              .tlParams({'name': repository.name}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = List<ComicSourceRepository>.from(repositories)
      ..removeAt(index);
    await _persistAndReload(updated);
  }

  Future<void> _testRepository(ComicSourceRepository repository) async {
    final controller = showLoadingDialog(context, barrierDismissible: false);
    try {
      final result = await const ComicSourceRepositoryService().load([
        repository.copyWith(enabled: true),
      ]);
      if (!mounted) return;
      if (result.snapshots.isNotEmpty) {
        context.showMessage(
          message: 'Repository connection succeeded: @count sources'.tlParams({
            'count': result.entries.length.toString(),
          }),
        );
      } else {
        context.showMessage(
          // Static repository errors are translated; dynamic HTTP errors
          // remain concise and retain the status code.
          message: (result.failures.firstOrNull?.message ?? 'Network error').tl,
        );
      }
    } finally {
      controller.close();
    }
  }
}

enum _RepositoryAction { test, edit, moveUp, moveDown, delete }

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    try {
      var count = await ComicSourcePage.checkComicSourceUpdate();
      if (!mounted) return;
      if (count == -1) {
        context.showMessage(message: "Network error".tl);
      } else if (count == 0) {
        context.showMessage(message: "No updates".tl);
      } else {
        showUpdateDialog();
      }
    } catch (error, stackTrace) {
      Log.error('Comic source update check', '$error\n$stackTrace');
      if (mounted) context.showMessage(message: "Network error".tl);
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate) {
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
      );
      int current = 0;
      int total = ComicSourceManager().availableUpdates.length;
      try {
        var shouldUpdate = ComicSourceManager().availableUpdates.keys.toList();
        for (var key in shouldUpdate) {
          var source = ComicSource.find(key)!;
          await ComicSourcePage.update(source, false);
          current++;
          loadingController.setProgress(current / total);
        }
      } catch (e) {
        context.showMessage(message: e.toString());
      }
      loadingController.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: Row(
              children: [
                Text(source.name, style: ts.s18),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    source.version,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (hasUpdate)
                  Tooltip(
                    message: newVersion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "New Version".tl,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ).paddingLeft(4),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "Edit".tl,
                  child: IconButton(
                    onPressed: _comicSourceMutationGate.isActive
                        ? null
                        : () => widget.edit(source),
                    icon: const Icon(Icons.edit_note),
                  ),
                ),
                Tooltip(
                  message: "Update".tl,
                  child: IconButton(
                    onPressed: _comicSourceMutationGate.isActive
                        ? null
                        : () => widget.update(source),
                    icon: const Icon(Icons.update),
                  ),
                ),
                Tooltip(
                  message: "Delete".tl,
                  child: IconButton(
                    onPressed: _comicSourceMutationGate.isActive
                        ? null
                        : () => widget.delete(source),
                    icon: const Icon(Icons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(children: buildSourceSettings().toList()),
        ),
        SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current =
                item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                )['text'] ??
                current;
          }
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: (current as String).ts(source.key),
              values: (item.value['options'] as List)
                  .map<String>(
                    (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                source.data['settings'][key] =
                    item.value['options'][i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
