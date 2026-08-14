import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() {
    AppTranslation.translations = const {'en_US': {}};
  });

  testWidgets('dependency changes do not duplicate download task listeners', (
    tester,
  ) async {
    final manager = LocalManager();
    final task = _ListenerCountingTask();
    manager.downloadingTasks
      ..clear()
      ..add(task);
    addTearDown(manager.downloadingTasks.clear);

    await tester.pumpWidget(
      const MaterialApp(themeMode: ThemeMode.light, home: DownloadingPage()),
    );
    final initialAdds = task.addCalls;
    expect(initialAdds, greaterThan(0));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        themeMode: ThemeMode.dark,
        home: const DownloadingPage(),
      ),
    );

    // The page and its tile retain one subscription each. Rebuilding inherited
    // dependencies must not append another subscription for the same task.
    expect(task.addCalls - task.removeCalls, initialAdds);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(task.addCalls, task.removeCalls);
  });

  testWidgets('an empty queue has an accessible empty state', (tester) async {
    final semantics = tester.ensureSemantics();
    final manager = LocalManager();
    manager.downloadingTasks.clear();

    await tester.pumpWidget(
      const MaterialApp(themeMode: ThemeMode.light, home: DownloadingPage()),
    );

    final emptyText = find.text('No active downloads');
    expect(emptyText, findsOneWidget);
    expect(
      tester.getSemantics(emptyText).label,
      contains('No active downloads'),
    );
    semantics.dispose();
  });
}

class _ListenerCountingTask extends DownloadTask {
  int addCalls = 0;
  int removeCalls = 0;

  @override
  void addListener(VoidCallback listener) {
    addCalls++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    removeCalls++;
    super.removeListener(listener);
  }

  @override
  void cancel() {}

  @override
  ComicType get comicType => ComicType(42);

  @override
  String? get cover => null;

  @override
  String get id => 'listener-test';

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
  String get title => 'Listener test';

  @override
  LocalComic toLocalComic() => throw UnsupportedError('Not used by test');

  @override
  Map<String, dynamic> toJson() => const {};
}
