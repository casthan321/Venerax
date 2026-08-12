import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/favorites/favorite_navigation.dart';

void main() {
  testWidgets('favorite reader route is pushed above the main shell', (
    tester,
  ) async {
    final contentNavigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Column(
            children: [
              const Text('Main navigation shell'),
              Expanded(
                child: Navigator(
                  key: contentNavigatorKey,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => Center(
                      child: FilledButton(
                        onPressed: () {
                          pushFavoriteReader(
                            () => const Scaffold(body: Text('Reader page')),
                          );
                        },
                        child: const Text('Read'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();

    expect(find.text('Reader page'), findsOneWidget);
    expect(find.text('Main navigation shell'), findsNothing);
    expect(App.rootNavigatorKey.currentState!.canPop(), isTrue);
    expect(contentNavigatorKey.currentState!.canPop(), isFalse);
  });
}
