import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  Future<void> pumpNavigation(
    WidgetTester tester, {
    required double width,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          paneItems: [
            PaneItemEntry(
              label: 'Favorites',
              icon: Icons.local_activity_outlined,
              activeIcon: Icons.local_activity,
            ),
          ],
          paneActions: [
            PaneActionEntry(label: 'Search', icon: Icons.search, onTap: () {}),
          ],
          pageBuilder: (_) => const SizedBox.expand(),
          observer: NaviObserver(),
          navigatorKey: GlobalKey<NavigatorState>(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('folded side navigation keeps the current page title visible', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpNavigation(tester, width: 1280);

    expect(find.text('Favorites'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.local_activity), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('side-navigation-Favorites')),
        matching: find.byTooltip('Favorites'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Search'), findsOneWidget);
    final favoritesSemantics = find.semantics.byPredicate(
      (node) =>
          node.getSemanticsData().identifier == 'side-navigation-Favorites',
    );
    expect(favoritesSemantics, findsOne);
    expect(
      favoritesSemantics.evaluate().single,
      isSemantics(
        label: 'Favorites',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    final searchSemantics = find.semantics.byPredicate(
      (node) => node.getSemanticsData().identifier == 'pane-action-Search',
    );
    expect(searchSemantics, findsOne);
    expect(
      searchSemantics.evaluate().single,
      isSemantics(label: 'Search', isButton: true, hasTapAction: true),
    );
    semantics.dispose();
  });

  testWidgets('expanded side navigation does not duplicate the page title', (
    tester,
  ) async {
    await pumpNavigation(tester, width: 1400);

    expect(find.text('Favorites'), findsOneWidget);
    expect(find.byIcon(Icons.local_activity), findsOneWidget);
  });

  testWidgets('bottom navigation exposes tooltip and selected semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpNavigation(tester, width: 400);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bottom-navigation-Favorites')),
        matching: find.byTooltip('Favorites'),
      ),
      findsOneWidget,
    );
    final favoritesSemantics = find.semantics.byPredicate(
      (node) =>
          node.getSemanticsData().identifier == 'bottom-navigation-Favorites',
    );
    expect(favoritesSemantics, findsOne);
    expect(
      favoritesSemantics.evaluate().single,
      isSemantics(
        label: 'Favorites',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });
}
