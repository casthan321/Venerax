import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

void main() {
  test('download queue restore isolates bad entries and keeps valid tasks', () {
    final restored = decodeDownloadingTaskQueue<String>(
      jsonEncode([
        {'id': 'first', 'source': 'available'},
        {'id': 'missing-source'},
        {'id': 'unsupported', 'source': 'available'},
        42,
        {'id': 'last', 'source': 'available'},
      ]),
      (json) {
        if (json['source'] == null) {
          throw StateError('Source is unavailable');
        }
        if (json['id'] == 'unsupported') return null;
        return json['id'] as String;
      },
    );

    expect(restored.requiresFileQuarantine, isFalse);
    expect(restored.tasks, ['first', 'last']);
    expect(restored.failures.map((failure) => failure.index), [1, 2, 3]);
  });

  test('download queue restore quarantines only invalid documents', () {
    for (final contents in ['{', '{}']) {
      final restored = decodeDownloadingTaskQueue<String>(
        contents,
        (json) => json['id'] as String,
      );

      expect(restored.requiresFileQuarantine, isTrue);
      expect(restored.tasks, isEmpty);
      expect(restored.failures, isEmpty);
    }
  });

  test(
    'download queue coalesces rapid snapshots and commits valid JSON',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-download-queue-',
      );
      addTearDown(() => directory.delete(recursive: true));
      App.dataPath = directory.path;
      final manager = LocalManager();
      final task = _FakeDownloadTask();
      manager.downloadingTasks
        ..clear()
        ..add(task);
      addTearDown(manager.downloadingTasks.clear);

      task.revision = 1;
      final firstSave = manager.saveCurrentDownloadingTasks();
      task.revision = 2;
      final secondSave = manager.saveCurrentDownloadingTasks();
      await Future.wait([firstSave, secondSave]);

      final destination = File(
        '${directory.path}${Platform.pathSeparator}downloading_tasks.json',
      );
      final decoded = jsonDecode(await destination.readAsString()) as List;
      expect(decoded.single['revision'], 2);
      expect(await File('${destination.path}.tmp').exists(), isFalse);
    },
  );
}

class _FakeDownloadTask extends DownloadTask {
  int revision = 0;

  @override
  void cancel() {}

  @override
  ComicType get comicType => ComicType(42);

  @override
  String? get cover => null;

  @override
  String get id => 'fake';

  @override
  bool get isError => false;

  @override
  bool get isPaused => true;

  @override
  String get message => '';

  @override
  void pause() {}

  @override
  double get progress => 0;

  @override
  void resume() {}

  @override
  int get speed => 0;

  @override
  String get title => 'Fake';

  @override
  LocalComic toLocalComic() => throw UnsupportedError('Not used by test');

  @override
  Map<String, dynamic> toJson() => {'type': 'fake', 'revision': revision};
}
