import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/library_page_helpers.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  DownloadTask? firstTask;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentFirstTask = LocalManager().downloadingTasks.firstOrNull;
    if (!identical(currentFirstTask, firstTask)) {
      firstTask?.removeListener(update);
      firstTask = currentFirstTask;
      firstTask?.addListener(update);
    }
  }

  @override
  void initState() {
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    firstTask?.removeListener(update);
    super.dispose();
  }

  void update() {
    var currentFirstTask = LocalManager().downloadingTasks.firstOrNull;
    if (!identical(currentFirstTask, firstTask)) {
      firstTask?.removeListener(update);
      firstTask = currentFirstTask;
      firstTask?.addListener(update);
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = List<DownloadTask>.of(LocalManager().downloadingTasks);
    return PopUpWidgetScaffold(
      title: "Downloading".tl,
      tailing: tasks.isEmpty
          ? null
          : [
              Semantics(
                label: "Download queue actions".tl,
                button: true,
                child: MenuButton(entries: _buildQueueActions(tasks)),
              ),
            ],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: SizedBox.expand(
            child: tasks.isEmpty
                ? const _EmptyDownloadQueue()
                : ListView.builder(
                    itemCount: tasks.length + 1,
                    itemBuilder: (BuildContext context, int i) {
                      if (i == 0) {
                        return buildTop(tasks);
                      }
                      final task = tasks[i - 1];
                      return _DownloadTaskTile(key: ValueKey(task), task: task);
                    },
                  ),
          ),
        ),
      ),
    );
  }

  List<MenuEntry> _buildQueueActions(List<DownloadTask> snapshot) {
    return [
      MenuEntry(
        icon: Icons.pause,
        text: "Pause All".tl,
        onClick: () => _pauseQueue(snapshot),
      ),
      MenuEntry(
        icon: Icons.play_arrow,
        text: "Resume All".tl,
        onClick: _resumeQueue,
      ),
      MenuEntry(
        icon: Icons.cancel_outlined,
        text: "Cancel All".tl,
        color: context.colorScheme.error,
        onClick: () => _confirmCancelTasks(snapshot),
      ),
    ];
  }

  void _pauseQueue(List<DownloadTask> snapshot) {
    pauseDownloadTaskSnapshot(
      snapshot: snapshot,
      currentQueue: LocalManager().downloadingTasks,
      persist: LocalManager().scheduleCurrentDownloadingTasksSave,
    );
  }

  void _resumeQueue() {
    // The queue is intentionally serial. Resuming every task here would turn
    // one download queue into concurrent full-comic downloads.
    resumeSerialDownloadQueue(
      currentQueue: LocalManager().downloadingTasks,
      persist: LocalManager().scheduleCurrentDownloadingTasksSave,
    );
  }

  void _confirmCancelTasks(List<DownloadTask> snapshot) {
    if (snapshot.isEmpty) return;
    showConfirmDialog(
      context: context,
      title: "Cancel Downloads".tl,
      content: "Cancel @count download tasks?".tlParams({
        "count": snapshot.length,
      }),
      confirmText: "Cancel",
      btnColor: context.colorScheme.error,
      onConfirm: () {
        cancelDownloadTaskSnapshot(
          snapshot: snapshot,
          currentQueue: LocalManager().downloadingTasks,
          detach: LocalManager().removeTask,
        );
      },
    );
  }

  Widget buildTop(List<DownloadTask> tasks) {
    final first = tasks.first;
    final speed = first.speed;
    final status = first.isPaused
        ? "Paused".tl
        : first.isError
        ? "Error".tl
        : "${bytesToReadableString(speed)}/s";
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Semantics(
            liveRegion: true,
            label: "Download queue status".tl,
            value: status,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, style: ts.s18.bold),
                Text(
                  "@count tasks".tlParams({"count": tasks.length}),
                  style: ts.s12,
                ),
              ],
            ),
          ),
          const Spacer(),
          if (first.isPaused || first.isError)
            OutlinedButton(
              child: Row(
                children: [
                  const Icon(Icons.play_arrow, size: 18),
                  const SizedBox(width: 4),
                  Text("Start".tl),
                ],
              ),
              onPressed: () {
                first.resume();
              },
            )
          else
            OutlinedButton(
              child: Row(
                children: [
                  const Icon(Icons.pause, size: 18),
                  const SizedBox(width: 4),
                  Text("Pause".tl),
                ],
              ),
              onPressed: () {
                first.pause();
              },
            ),
        ],
      ).paddingHorizontal(16),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.task, widget.task)) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = normalizedDownloadProgress(task.progress);
    final status = task.isError
        ? "Error".tl
        : task.isPaused
        ? "Paused".tl
        : task.message;
    return Container(
      height: 136,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Semantics(
        container: true,
        label: task.title,
        value: "$status, ${(progress * 100).round()}%",
        child: Row(
          children: [
            Container(
              width: 82,
              height: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: context.colorScheme.primaryContainer,
              ),
              clipBehavior: Clip.antiAlias,
              child: task.cover == null
                  ? null
                  : Image(
                      image: CachedImageProvider(task.cover!),
                      filterQuality: FilterQuality.medium,
                      fit: BoxFit.cover,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.title,
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 2,
                        ),
                      ),
                      Semantics(
                        label: "Actions for @title".tlParams({
                          "title": task.title,
                        }),
                        button: true,
                        child: MenuButton(
                          entries: [
                            MenuEntry(
                              icon: Icons.close,
                              text: "Cancel".tl,
                              onClick: () {
                                final queued = LocalManager().downloadingTasks;
                                if (!containsIdenticalDownloadTask(
                                  queued,
                                  task,
                                )) {
                                  return;
                                }
                                showConfirmDialog(
                                  context: context,
                                  title: "Cancel Download".tl,
                                  content: "Cancel the download for @title?"
                                      .tlParams({"title": task.title}),
                                  confirmText: "Cancel",
                                  btnColor: context.colorScheme.error,
                                  onConfirm: () {
                                    if (containsIdenticalDownloadTask(
                                      LocalManager().downloadingTasks,
                                      task,
                                    )) {
                                      task.cancel();
                                    }
                                  },
                                );
                              },
                            ),
                            MenuEntry(
                              icon: Icons.vertical_align_top,
                              text: "Move To First".tl,
                              onClick: () {
                                if (containsIdenticalDownloadTask(
                                  LocalManager().downloadingTasks,
                                  task,
                                )) {
                                  LocalManager().moveToFirst(task);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (!task.isPaused || task.isError)
                    Text(task.message, style: ts.s12, maxLines: 3),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: progress,
                    semanticsLabel: task.title,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDownloadQueue extends StatelessWidget {
  const _EmptyDownloadQueue();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: "No active downloads".tl,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.download_done_outlined,
                size: 48,
                color: context.colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                "No active downloads".tl,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
