import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() {
    AppTranslation.translations = const {'en_US': {}};
  });

  Future<void> pumpSettings(WidgetTester tester, {int initialPage = -1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(initialPage: initialPage)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wide settings opens the first detail page by default', (
    tester,
  ) async {
    await pumpSettings(tester);

    expect(find.byKey(const ValueKey('settings-detail-0')), findsOneWidget);
    expect(find.text('Display mode of comic tile'), findsOneWidget);
  });

  testWidgets('wide settings replaces the detail navigator on selection', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.text('Reading').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-detail-0')), findsNothing);
    expect(find.byKey(const ValueKey('settings-detail-1')), findsOneWidget);
    expect(find.text('Tap to turn Pages'), findsOneWidget);
  });

  testWidgets('wide settings honors a valid initial page', (tester) async {
    await pumpSettings(tester, initialPage: 5);

    expect(find.byKey(const ValueKey('settings-detail-5')), findsOneWidget);
    expect(find.text('Proxy'), findsWidgets);
  });
}
