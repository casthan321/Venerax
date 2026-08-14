import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/explore_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() {
    AppTranslation.translations = const {'en_US': {}};
  });

  Future<void> pumpExplore(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          initialPage: 2,
          paneItems: List.generate(
            4,
            (index) => PaneItemEntry(
              label: 'Page $index',
              icon: Icons.circle_outlined,
              activeIcon: Icons.circle,
            ),
          ),
          paneActions: const [],
          pageBuilder: (_) => const ExplorePage(),
          observer: NaviObserver(),
          navigatorKey: GlobalKey<NavigatorState>(),
        ),
      ),
    );
    // Advance the navigation layout animation without waiting for a pending
    // explore request's progress indicator to settle.
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('multi-part explore ignores stale loads and does not duplicate', (
    tester,
  ) async {
    final originalPages = List<String>.from(appdata.settings['explore_pages']);
    final loads = <Completer<Res<List<ExplorePagePart>>>>[];
    final page = ExplorePageData(
      'Test Explore',
      ExplorePageType.singlePageWithMultiPart,
      null,
      null,
      () {
        final result = Completer<Res<List<ExplorePagePart>>>();
        loads.add(result);
        return result.future;
      },
      null,
    );
    final source = _sourceWithExplorePage(page);
    ComicSourceManager().add(source);
    appdata.settings['explore_pages'] = ['Test Explore'];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ComicSourceManager().remove(source.key);
      appdata.settings['explore_pages'] = originalPages;
    });

    await pumpExplore(tester);
    expect(loads, hasLength(1));

    // An unrelated rebuild while the first request is pending must not start a
    // second copy of the same request.
    await tester.pump(const Duration(milliseconds: 16));
    expect(loads, hasLength(1));

    await tester.tap(find.byKey(const Key('FAB')));
    await tester.pump();
    expect(loads, hasLength(2));

    loads[1].complete(const Res([ExplorePagePart('Newest result', [], null)]));
    await tester.pump();
    expect(find.text('Newest result'), findsOneWidget);

    loads[0].complete(const Res([ExplorePagePart('Stale result', [], null)]));
    await tester.pump();
    expect(find.text('Newest result'), findsOneWidget);
    expect(find.text('Stale result'), findsNothing);
  });

  testWidgets('empty explore pages tolerate repeated navigation taps', (
    tester,
  ) async {
    final originalPages = List<String>.from(appdata.settings['explore_pages']);
    appdata.settings['explore_pages'] = <String>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      appdata.settings['explore_pages'] = originalPages;
    });

    await pumpExplore(tester);
    await tester.tap(find.byKey(const ValueKey('side-navigation-Page 2')));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

ComicSource _sourceWithExplorePage(ExplorePageData page) {
  return ComicSource(
    'UI test source',
    'ui_test_source',
    null,
    null,
    null,
    null,
    [page],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '',
    '',
    '1',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
