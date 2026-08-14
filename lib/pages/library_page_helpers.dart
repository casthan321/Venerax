import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/network/download.dart';

/// Filters history in memory without changing its latest-read ordering.
///
/// Every whitespace-separated term must occur in at least one searchable
/// field. This makes searches such as "author chapter" useful while keeping
/// the implementation inexpensive for the already-loaded history list.
List<History> filterHistoryItems(Iterable<History> histories, String query) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) {
    return List<History>.of(histories);
  }

  return histories
      .where((history) {
        final searchableText = <String>[
          history.title,
          history.subtitle,
          history.id,
          history.sourceKey,
        ].join('\n').toLowerCase();
        return terms.every(searchableText.contains);
      })
      .toList(growable: false);
}

/// Uses the history row's stored type instead of reconstructing a type from
/// its source key. The latter is unsafe for removed or renamed sources.
List<ComicID> historyIdsForDeletion(Iterable<History> histories) {
  return histories
      .map((history) => ComicID(history.type, history.id))
      .toList(growable: false);
}

/// Cancelling queued tasks from the tail keeps the current head in place until
/// the final cancellation, avoiding needless start/stop churn in a serial
/// download queue.
List<DownloadTask> downloadTaskCancellationOrder(Iterable<DownloadTask> tasks) {
  return tasks.toList(growable: false).reversed.toList(growable: false);
}

bool containsIdenticalDownloadTask(
  Iterable<DownloadTask> tasks,
  DownloadTask target,
) {
  return tasks.any((task) => identical(task, target));
}

void pauseDownloadTaskSnapshot({
  required Iterable<DownloadTask> snapshot,
  required Iterable<DownloadTask> currentQueue,
  required void Function() persist,
}) {
  for (final task in snapshot) {
    if (containsIdenticalDownloadTask(currentQueue, task)) {
      task.pause();
    }
  }
  persist();
}

void resumeSerialDownloadQueue({
  required List<DownloadTask> currentQueue,
  required void Function() persist,
}) {
  if (currentQueue.isNotEmpty) {
    currentQueue.first.resume();
  }
  persist();
}

/// Detaches a confirmed snapshot before cancelling any task resources.
///
/// Some implementations complete [DownloadTask.cancel] asynchronously. If a
/// live queue head were cancelled first, it could resume the next task while
/// that task was also being cancelled. Removing the whole snapshot up front
/// preserves serial queue semantics even for mixed task implementations.
void cancelDownloadTaskSnapshot({
  required Iterable<DownloadTask> snapshot,
  required List<DownloadTask> currentQueue,
  required void Function(DownloadTask task) detach,
}) {
  final stillQueued = snapshot
      .where((task) => containsIdenticalDownloadTask(currentQueue, task))
      .toList(growable: false);
  for (final task in stillQueued) {
    task.pause();
    detach(task);
  }
  for (final task in downloadTaskCancellationOrder(stillQueued)) {
    task.cancel();
  }
}

double normalizedDownloadProgress(double progress) {
  if (!progress.isFinite) return 0;
  return progress.clamp(0.0, 1.0);
}
