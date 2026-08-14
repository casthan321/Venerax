import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:venera/utils/comic_import_transaction.dart';
import 'package:venera/utils/maintenance_coordinator.dart';
import 'package:venera/utils/translations.dart';
import 'cbz.dart';
import 'io.dart';
import 'local_comic_layout.dart';

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  Future<bool> cbz() async {
    var file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    if (file == null) {
      return false;
    }
    return MaintenanceCoordinator.instance.run('Import Comics', () async {
      var controller = showLoadingDialog(App.rootContext, allowCancel: false);
      PendingCbzImport? pendingImport;
      try {
        pendingImport = await CBZ.import(File(file.path));
      } catch (e, s) {
        Log.error("Import Comic", e.toString(), s);
        App.rootContext.showMessage(message: e.toString());
      }
      controller.close();
      if (pendingImport == null) return false;
      return _registerPendingCbzImports({
        selectedFolder: [pendingImport],
      });
    });
  }

  Future<bool> multipleCbz() async {
    var picker = DirectoryPicker();
    var dir = await picker.pickDirectory(directAccess: true);
    if (dir != null) {
      return MaintenanceCoordinator.instance.run('Import Comics', () async {
        var files = (await dir.list().toList()).whereType<File>().toList();
        const supportedExtensions = ['cbz', 'zip', '7z', 'cb7'];
        files.removeWhere((e) => !supportedExtensions.contains(e.extension));
        var controller = showLoadingDialog(App.rootContext, allowCancel: false);
        var pendingImports = <PendingCbzImport>[];
        for (var file in files) {
          try {
            pendingImports.add(await CBZ.import(file));
          } catch (e, s) {
            Log.error("Import Comic", e.toString(), s);
          }
        }
        if (pendingImports.isEmpty) {
          App.rootContext.showMessage(message: "No valid comics found".tl);
        }
        controller.close();
        if (pendingImports.isEmpty) return false;
        return _registerPendingCbzImports({selectedFolder: pendingImports});
      });
    }
    return false;
  }

  Future<bool> ehViewer() async {
    var dbFile = await selectFile(ext: ['db']);
    final picker = DirectoryPicker();
    final comicSrc = await picker.pickDirectory();
    Map<String?, List<LocalComic>> imported = {};
    if (dbFile == null || comicSrc == null) {
      return false;
    }

    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );

    try {
      var db = sql.sqlite3.open(dbFile.path);

      Future<List<LocalComic>> validateComics(List<sql.Row> comics) async {
        List<LocalComic> imported = [];
        for (var comic in comics) {
          if (cancelled) {
            return imported;
          }
          var comicDir = Directory(
            FilePath.join(comicSrc.path, comic['DIRNAME'] as String),
          );
          String titleJP = comic['TITLE_JPN'] == null
              ? ""
              : comic['TITLE_JPN'] as String;
          String title = titleJP == "" ? comic['TITLE'] as String : titleJP;
          int timeStamp = comic['TIME'] as int;
          DateTime downloadTime = timeStamp != 0
              ? DateTime.fromMillisecondsSinceEpoch(timeStamp)
              : DateTime.now();
          var comicObj = await _checkSingleComic(
            comicDir,
            title: title,
            tags: [
              //1 >> x
              [
                "MISC",
                "DOUJINSHI",
                "MANGA",
                "ARTISTCG",
                "GAMECG",
                "IMAGE SET",
                "COSPLAY",
                "ASIAN PORN",
                "NON-H",
                "WESTERN",
              ][(log(comic['CATEGORY'] as int) / ln2).floor()],
            ],
            createTime: downloadTime,
          );
          if (comicObj == null) {
            continue;
          }
          imported.add(comicObj);
        }
        return imported;
      }

      var tags = <String>[""];
      tags.addAll(
        db
            .select("""
            SELECT * FROM DOWNLOAD_LABELS LB
            ORDER BY  LB.TIME DESC;
          """)
            .map((r) => r['LABEL'] as String)
            .toList(),
      );

      for (var tag in tags) {
        if (cancelled) {
          break;
        }
        var folderName = tag == '' ? '(EhViewer)Default'.tl : '(EhViewer)$tag';
        var comicList = db.select("""
              SELECT * 
              FROM DOWNLOAD_DIRNAME DN
              LEFT JOIN DOWNLOADS DL
              ON DL.GID = DN.GID
              WHERE DL.LABEL ${tag == '' ? 'IS NULL' : '= \'$tag\''} AND DL.STATE = 3
              ORDER BY DL.TIME DESC
            """).toList();

        var validComics = await validateComics(comicList);
        imported[folderName] = validComics;
        if (validComics.isNotEmpty &&
            !LocalFavoritesManager().existsFolder(folderName)) {
          LocalFavoritesManager().createFolder(folderName);
        }
      }
      db.dispose();

      //Android specific
      var cache = FilePath.join(App.cachePath, dbFile.name);
      await File(cache).deleteIgnoreError();
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, copyToLocal);
  }

  Future<bool> directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) {
      return false;
    }
    Map<String?, List<LocalComic>> imported = {selectedFolder: []};
    try {
      if (single) {
        var result = await _checkSingleComic(path);
        if (result != null) {
          imported[selectedFolder]!.add(result);
        } else {
          App.rootContext.showMessage(message: "Invalid Comic".tl);
          return false;
        }
      } else {
        await for (var entry in path.list()) {
          if (entry is Directory) {
            var result = await _checkSingleComic(entry);
            if (result != null) {
              imported[selectedFolder]!.add(result);
            }
          }
        }
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    return registerComics(imported, copyToLocal);
  }

  Future<bool> localDownloads() async {
    var localDir = LocalManager().directory;
    Map<String?, List<LocalComic>> imported = {null: []};
    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );
    try {
      if (!await localDir.exists()) {
        App.rootContext.showMessage(message: "Local path not found".tl);
        controller.close();
        return false;
      }
      await for (var entry in localDir.list()) {
        if (cancelled) {
          break;
        }
        if (entry is Directory) {
          var stat = await entry.stat();
          var result = await _checkSingleComic(
            entry,
            createTime: stat.modified,
            useRelativePath: true,
          );
          if (result != null) {
            imported[null]!.add(result);
          }
        }
      }
      if (!cancelled && imported[null]!.isEmpty) {
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, false);
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(
    Directory directory, {
    String? id,
    String? title,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
  }) async {
    if (!(await directory.exists())) return null;
    var name = title ?? directory.name;
    if (LocalManager().findByName(name) != null) {
      Log.info("Import Comic", "Comic already exists: $name");
      return null;
    }
    var fileList = <String>[];
    var chapterImages = <String, List<String>>{};
    await for (var entry in directory.list()) {
      if (entry is Directory) {
        var images = <String>[];
        chapterImages[entry.name] = images;
        await for (var file in entry.list()) {
          if (file is Directory) {
            Log.info(
              "Import Comic",
              "Invalid Chapter: ${entry.name}\nA directory is found in the chapter directory.",
            );
            return null;
          } else if (file is File && isSupportedComicImage(file)) {
            images.add(file.name);
          }
        }
      } else if (entry is File) {
        if (isSupportedComicImage(entry)) {
          fileList.add(entry.name);
        }
      }
    }

    final layout = resolveLocalComicDirectoryLayout(
      rootImages: fileList,
      chapterImages: chapterImages,
    );
    if (layout == null) {
      Log.info("Import Comic", "Invalid Comic: $name\nNo cover image found.");
      return null;
    }
    final chapters = layout.chapters;
    var directoryPath = useRelativePath ? directory.name : directory.path;
    return LocalComic(
      id: id ?? '0',
      title: name,
      subtitle: subtitle ?? '',
      tags: tags ?? [],
      directory: directoryPath,
      chapters: chapters.isNotEmpty
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: layout.coverPath,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime ?? DateTime.now(),
    );
  }

  static Future<Map<String, String>> _copyDirectories(
    Map<String, dynamic> data,
  ) async {
    return overrideIO(() async {
      var toBeCopied = data['toBeCopied'] as List<String>;
      var destination = data['destination'] as String;
      Map<String, String> result = {};
      for (var dir in toBeCopied) {
        var source = Directory(dir);
        var dest = Directory("$destination/${source.name}");
        if (dest.existsSync()) {
          // The destination directory already exists, and it is not managed by the app.
          // Rename the old directory to avoid conflicts.
          Log.info(
            "Import Comic",
            "Directory already exists: ${source.name}\nRenaming the old directory.",
          );
          dest.renameSync(
            findValidDirectoryName(dest.parent.path, "${dest.path}_old"),
          );
        }
        dest.createSync();
        await copyDirectory(source, dest);
        result[source.path] = dest.path;
      }
      return result;
    });
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
    Map<String?, List<LocalComic>> comics,
  ) async {
    var destPath = LocalManager().path;
    Map<String?, List<LocalComic>> result = {};
    for (var favoriteFolder in comics.keys) {
      result[favoriteFolder] = comics[favoriteFolder]!
          .where((c) => c.directory.startsWith(destPath))
          .toList();
      comics[favoriteFolder]!.removeWhere(
        (c) => c.directory.startsWith(destPath),
      );

      if (comics[favoriteFolder]!.isEmpty) {
        continue;
      }

      try {
        // copy the comics to the local directory
        var pathMap = await compute<Map<String, dynamic>, Map<String, String>>(
          _copyDirectories,
          {
            'toBeCopied': comics[favoriteFolder]!
                .map((e) => e.directory)
                .toList(),
            'destination': destPath,
          },
        );
        //Construct a new object since LocalComic.directory is a final String
        for (var c in comics[favoriteFolder]!) {
          result[favoriteFolder]!.add(
            LocalComic(
              id: c.id,
              title: c.title,
              subtitle: c.subtitle,
              tags: c.tags,
              directory: pathMap[c.directory]!,
              chapters: c.chapters,
              cover: c.cover,
              comicType: c.comicType,
              downloadedChapters: c.downloadedChapters,
              createdAt: c.createdAt,
            ),
          );
        }
      } catch (e, s) {
        App.rootContext.showMessage(message: "Failed to copy comics".tl);
        Log.error("Import Comic", e.toString(), s);
        return result;
      }
    }
    return result;
  }

  Future<bool> registerComics(
    Map<String?, List<LocalComic>> importedComics,
    bool copy, {
    Map<LocalComic, PendingComicArtifact>? pendingArtifacts,
  }) async {
    late final int importedCount;
    var artifactOwnershipTransferred = false;
    try {
      if (copy && pendingArtifacts?.isNotEmpty == true) {
        throw ArgumentError(
          'Provisional comic artifacts cannot be copied before registration',
        );
      }
      if (copy) {
        importedComics = await _copyComicsToLocalDir(importedComics);
      }
      final entries = <ComicRegistrationEntry<LocalComic>>[
        for (final folder in importedComics.keys)
          for (final comic in importedComics[folder]!)
            ComicRegistrationEntry(
              comic: comic,
              folder: folder,
              artifact: pendingArtifacts?[comic],
            ),
      ];
      final localManager = LocalManager();
      final favoritesManager = LocalFavoritesManager();
      artifactOwnershipTransferred = true;
      importedCount = await registerComicBatchTransactionally(
        entries: entries,
        runLocalTransaction: (operation) =>
            localManager.runInTransaction(operation),
        runFavoriteTransaction: (operation) =>
            favoritesManager.runInTransaction(operation),
        registerLocal: localManager.insertImportedNew,
        rollbackLocal: (comic, id) {
          localManager.removeImported(id, comic.comicType, comic.directory);
        },
        registerFavorite: (folder, comic, id) => favoritesManager.addComic(
          folder,
          _favoriteForImportedComic(comic, id),
        ),
        rollbackFavorite: (folder, comic, id) {
          _rollbackImportedFavorite(favoritesManager, folder, comic, id);
        },
      );
    } catch (e, s) {
      // Once the helper starts it exclusively owns rollback decisions. In
      // particular, it preserves a directory when exact DB compensation
      // fails, preventing a surviving row from pointing at deleted content.
      if (!artifactOwnershipTransferred && pendingArtifacts != null) {
        for (final artifact in pendingArtifacts.values.toSet()) {
          try {
            await artifact.rollback();
          } catch (rollbackError, rollbackStackTrace) {
            Log.error(
              "Import Comic",
              "Failed to remove provisional comic data: $rollbackError",
              rollbackStackTrace,
            );
          }
        }
      }
      App.rootContext.showMessage(message: "Failed to register comics".tl);
      Log.error("Import Comic", e.toString(), s);
      return false;
    }
    App.rootContext.showMessage(
      message: "Imported @a comics".tlParams({'a': importedCount}),
    );
    return true;
  }

  Future<bool> _registerPendingCbzImports(
    Map<String?, List<PendingCbzImport>> pendingImports,
  ) {
    final comics = <String?, List<LocalComic>>{};
    final artifacts = Map<LocalComic, PendingComicArtifact>.identity();
    for (final entry in pendingImports.entries) {
      comics[entry.key] = [
        for (final pendingImport in entry.value) pendingImport.comic,
      ];
      for (final pendingImport in entry.value) {
        artifacts[pendingImport.comic] = pendingImport;
      }
    }
    return registerComics(comics, false, pendingArtifacts: artifacts);
  }

  FavoriteItem _favoriteForImportedComic(LocalComic comic, String id) {
    return FavoriteItem(
      id: id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subtitle,
      type: comic.comicType,
      tags: comic.tags,
      favoriteTime: comic.createdAt,
    );
  }

  void _rollbackImportedFavorite(
    LocalFavoritesManager manager,
    String folder,
    LocalComic comic,
    String id,
  ) {
    if (!manager.comicExists(folder, id, comic.comicType)) return;
    final actual = manager.getComic(folder, id, comic.comicType);
    final expected = _favoriteForImportedComic(comic, id);
    if (actual.name != expected.name ||
        actual.author != expected.author ||
        actual.coverPath != expected.coverPath ||
        actual.time != expected.time) {
      throw StateError(
        'Favorite $id in "$folder" no longer belongs to this import',
      );
    }
    manager.deleteComicWithId(folder, id, comic.comicType);
  }
}
