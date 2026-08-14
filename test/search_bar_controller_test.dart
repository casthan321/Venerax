import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() {
    AppTranslation.translations = const {'en_US': {}};
  });

  Widget sliverHost(SearchBarController controller) {
    return MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [SliverSearchBar(controller: controller)],
        ),
      ),
    );
  }

  Widget appBarHost(SearchBarController controller) {
    return MaterialApp(
      home: Scaffold(body: AppSearchBar(controller: controller)),
    );
  }

  testWidgets('sliver search bar rebinds and detaches controllers', (
    tester,
  ) async {
    final first = SearchBarController(currentText: 'first');
    final second = SearchBarController(currentText: 'second');

    await tester.pumpWidget(sliverHost(first));
    expect(find.text('first'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'typed');
    expect(first.text, 'typed');
    expect(first.currentText, 'typed');

    await tester.pumpWidget(sliverHost(second));
    expect(find.text('second'), findsOneWidget);

    first.text = 'detached';
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('detached'), findsNothing);

    second.text = 'updated';
    await tester.pump();
    expect(find.text('updated'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.selection.baseOffset, 'updated'.length);

    await tester.pumpWidget(const SizedBox.shrink());
    second.text = 'after dispose';
    expect(second.text, 'after dispose');
  });

  testWidgets('app search bar rebinds and detaches controllers', (
    tester,
  ) async {
    final first = SearchBarController(currentText: 'one');
    final second = SearchBarController(currentText: 'two');

    await tester.pumpWidget(appBarHost(first));
    await tester.enterText(find.byType(TextField), 'edited');
    expect(first.currentText, 'edited');

    await tester.pumpWidget(appBarHost(second));
    expect(find.text('two'), findsOneWidget);

    first.text = 'old controller';
    second.text = 'new controller';
    await tester.pump();
    expect(find.text('new controller'), findsOneWidget);
    expect(find.text('old controller'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    second.text = 'safe after dispose';
    expect(second.text, 'safe after dispose');
  });
}
