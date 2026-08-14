import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/library_page_helpers.dart';
import 'package:venera/utils/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late List<History> _allComics;
  late List<History> comics;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _allComics = HistoryManager().getAll();
    comics = filterHistoryItems(_allComics, '');
    HistoryManager().addListener(onUpdate);
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    _searchController.dispose();
    super.dispose();
  }

  void onUpdate() {
    if (!mounted) return;
    setState(() {
      _allComics = HistoryManager().getAll();
      comics = filterHistoryItems(_allComics, _searchController.text);
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !_allComics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var controller = FlyoutController();

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  void _updateSearch(String query) {
    setState(() {
      comics = filterHistoryItems(_allComics, query);
      // Hidden selections are surprising and unsafe when deleting, so search
      // always constrains multi-selection to the visible result set.
      selectedComics.removeWhere((comic, _) => !comics.contains(comic));
      if (multiSelectMode && selectedComics.isEmpty) {
        multiSelectMode = false;
      }
    });
  }

  void _removeHistory(History comic) {
    HistoryManager().remove(comic.id, comic.type);
  }

  void _refreshHistory(History comic) async {
    var result = await HistoryManager().refreshHistoryInfo(comic);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Refreshing Histories".tl,
    );

    int success = 0;
    int failed = 0;
    int skipped = 0;

    Object? refreshError;
    try {
      await for (var progress in HistoryManager().refreshAllHistoriesStream()) {
        // The route can also be dismissed by the dialog's close affordance.
        if (isCanceled || loadingController.closed) {
          isCanceled = true;
          break;
        }
        if (progress.total > 0) {
          loadingController.setProgress(progress.current / progress.total);
        }
        success = progress.success;
        failed = progress.failed;
        skipped = progress.skipped;
      }
    } catch (error) {
      refreshError = error;
    } finally {
      loadingController.close();
    }

    if (!mounted || isCanceled) return;
    if (refreshError != null) {
      App.rootContext.showMessage(message: "Refresh Failed".tl);
    } else {
      App.rootContext.showMessage(
        message:
            "Refresh Completed: Success @success, Failed @failed, Skipped @skipped"
                .tlParams({
                  'success': success,
                  'failed': failed,
                  'skipped': skipped,
                }),
      );
    }
  }

  void _confirmDeleteSelected() {
    final histories = List<History>.of(selectedComics.keys);
    if (histories.isEmpty) return;
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete @count selected history entries?".tlParams({
        "count": histories.length,
      }),
      confirmText: "Delete",
      btnColor: context.colorScheme.error,
      onConfirm: () {
        HistoryManager().batchDeleteHistories(historyIdsForDeletion(histories));
        if (!mounted) return;
        setState(() {
          multiSelectMode = false;
          selectedComics.clear();
        });
      },
    );
  }

  Widget _buildSearchBar() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Semantics(
            textField: true,
            label: "Search History".tl,
            child: TextField(
              controller: _searchController,
              onChanged: _updateSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: "Search History".tl,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ListenableBuilder(
                  listenable: _searchController,
                  builder: (context, child) {
                    if (_searchController.text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return IconButton(
                      tooltip: "Clear".tl,
                      onPressed: () {
                        _searchController.clear();
                        _updateSearch('');
                      },
                      icon: const Icon(Icons.clear),
                    );
                  },
                ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final searching = _searchController.text.trim().isNotEmpty;
    final message = searching ? "No search results found" : "No history yet";
    return Semantics(
      liveRegion: true,
      label: message.tl,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                searching ? Icons.search_off : Icons.history_toggle_off,
                size: 48,
                color: context.colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                message.tl,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (searching) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    _searchController.clear();
                    _updateSearch('');
                  },
                  icon: const Icon(Icons.clear),
                  label: Text("Clear Search History".tl),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty ? null : _confirmDeleteSelected,
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text('History'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            SliverToBoxAdapter(child: _buildSearchBar()),
            if (comics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildEmptyState(),
              )
            else
              SliverGridComics(
                comics: comics,
                selections: selectedComics,
                onLongPressed: null,
                onTap: multiSelectMode
                    ? (c, heroID) {
                        setState(() {
                          if (selectedComics.containsKey(c as History)) {
                            selectedComics.remove(c);
                          } else {
                            selectedComics[c] = true;
                          }
                          if (selectedComics.isEmpty) {
                            multiSelectMode = false;
                          }
                        });
                      }
                    : null,
                badgeBuilder: (c) {
                  return ComicSource.find(c.sourceKey)?.name;
                },
                menuBuilder: (c) {
                  return [
                    MenuEntry(
                      icon: Icons.refresh,
                      text: 'Refresh Info'.tl,
                      onClick: () {
                        _refreshHistory(c as History);
                      },
                    ),
                    MenuEntry(
                      icon: Icons.remove,
                      text: 'Remove'.tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        _removeHistory(c as History);
                      },
                    ),
                  ];
                },
              ),
          ],
        ),
      ),
    );
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": h.ep});
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": h.page});
    }
    return res;
  }
}
