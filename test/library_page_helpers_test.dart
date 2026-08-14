import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/library_page_helpers.dart';

void main() {
  group('history page helpers', () {
    final histories = [
      _history(
        id: 'alpha-id',
        title: 'Alpha Adventure',
        subtitle: 'Artist One',
        type: ComicType(11),
      ),
      _history(
        id: 'beta-id',
        title: 'Beta Story',
        subtitle: 'Artist Two',
        type: ComicType(22),
      ),
    ];

    test('blank searches preserve latest-read ordering', () {
      expect(filterHistoryItems(histories, '   '), histories);
    });

    test('search is case insensitive and all terms must match', () {
      expect(filterHistoryItems(histories, 'ALPHA artist'), [histories.first]);
      expect(filterHistoryItems(histories, 'alpha two'), isEmpty);
    });

    test('search includes stable ids', () {
      expect(filterHistoryItems(histories, 'beta-id'), [histories.last]);
    });

    test('deletion identities retain the stored comic type', () {
      final ids = historyIdsForDeletion(histories);
      expect(ids, [
        ComicID(ComicType(11), 'alpha-id'),
        ComicID(ComicType(22), 'beta-id'),
      ]);
    });
  });

  group('download page helpers', () {
    test('cancellation order is tail first and does not mutate the input', () {
      final tasks = [_FakeDownloadTask('a'), _FakeDownloadTask('b')];
      final ordered = downloadTaskCancellationOrder(tasks);

      expect(ordered.map((task) => task.id), ['b', 'a']);
      expect(tasks.map((task) => task.id), ['a', 'b']);
    });

    test('progress is finite and constrained to indicator bounds', () {
      expect(normalizedDownloadProgress(-1), 0);
      expect(normalizedDownloadProgress(0.4), 0.4);
      expect(normalizedDownloadProgress(2), 1);
      expect(normalizedDownloadProgress(double.nan), 0);
    });

    test('pause only affects tasks still present by identity', () {
      final retained = _FakeDownloadTask('same-id');
      final equalReplacement = _FakeDownloadTask('same-id');
      var persisted = 0;

      pauseDownloadTaskSnapshot(
        snapshot: [retained, equalReplacement],
        currentQueue: [retained],
        persist: () => persisted++,
      );

      expect(retained.pauseCalls, 1);
      expect(equalReplacement.pauseCalls, 0);
      expect(persisted, 1);
    });

    test('resume preserves serial queue semantics', () {
      final first = _FakeDownloadTask('first');
      final second = _FakeDownloadTask('second');
      var persisted = 0;

      resumeSerialDownloadQueue(
        currentQueue: [first, second],
        persist: () => persisted++,
      );

      expect(first.resumeCalls, 1);
      expect(second.resumeCalls, 0);
      expect(persisted, 1);
    });

    test(
      'bulk cancellation detaches all tasks before reverse cancellation',
      () {
        final events = <String>[];
        final first = _FakeDownloadTask('first', events);
        final second = _FakeDownloadTask('second', events);
        final unrelated = _FakeDownloadTask('unrelated', events);
        final queue = <DownloadTask>[first, second];

        cancelDownloadTaskSnapshot(
          snapshot: [first, unrelated, second],
          currentQueue: queue,
          detach: (task) {
            events.add('detach:${task.id}');
            queue.removeWhere((candidate) => identical(candidate, task));
          },
        );

        expect(queue, isEmpty);
        expect(events, [
          'pause:first',
          'detach:first',
          'pause:second',
          'detach:second',
          'cancel:second',
          'cancel:first',
        ]);
      },
    );
  });
}

History _history({
  required String id,
  required String title,
  required String subtitle,
  required ComicType type,
}) {
  return History.fromMap({
    'type': type.value,
    'time': 1,
    'title': title,
    'subtitle': subtitle,
    'cover': '',
    'ep': 1,
    'page': 1,
    'id': id,
    'readEpisode': <String>[],
    'max_page': 1,
  });
}

class _FakeDownloadTask extends DownloadTask {
  _FakeDownloadTask(this.id, [this.events]);

  final List<String>? events;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  final String id;

  @override
  void cancel() => events?.add('cancel:$id');

  @override
  ComicType get comicType => ComicType(1);

  @override
  String? get cover => null;

  @override
  bool get isError => false;

  @override
  bool get isPaused => true;

  @override
  String get message => '';

  @override
  void pause() {
    pauseCalls++;
    events?.add('pause:$id');
  }

  @override
  double get progress => 0;

  @override
  void resume() {
    resumeCalls++;
    events?.add('resume:$id');
  }

  @override
  int get speed => 0;

  @override
  String get title => id;

  @override
  LocalComic toLocalComic() => throw UnsupportedError('Not used');

  @override
  Map<String, dynamic> toJson() => const {};
}
