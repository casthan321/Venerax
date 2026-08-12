import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/fullscreen_transition.dart';

void main() {
  test(
    'macOS toggles fullscreen without hiding or showing the window',
    () async {
      final actions = <String>[];

      await runFullscreenTransition(
        isMacOS: true,
        targetFullscreen: true,
        hideWindow: () async => actions.add('hide'),
        setFullScreen: (fullscreen) async {
          actions.add('fullscreen:$fullscreen');
        },
        showWindow: () async => actions.add('show'),
      );

      expect(actions, ['fullscreen:true']);
    },
  );

  test('other desktop platforms retain the visibility refresh', () async {
    final actions = <String>[];

    await runFullscreenTransition(
      isMacOS: false,
      targetFullscreen: false,
      hideWindow: () async => actions.add('hide'),
      setFullScreen: (fullscreen) async {
        actions.add('fullscreen:$fullscreen');
      },
      showWindow: () async => actions.add('show'),
    );

    expect(actions, ['hide', 'fullscreen:false', 'show']);
  });

  test(
    'other desktop platforms restore visibility after a toggle error',
    () async {
      final actions = <String>[];

      await expectLater(
        runFullscreenTransition(
          isMacOS: false,
          targetFullscreen: true,
          hideWindow: () async => actions.add('hide'),
          setFullScreen: (fullscreen) async {
            actions.add('fullscreen:$fullscreen');
            throw StateError('toggle failed');
          },
          showWindow: () async => actions.add('show'),
        ),
        throwsStateError,
      );

      expect(actions, ['hide', 'fullscreen:true', 'show']);
    },
  );
}
