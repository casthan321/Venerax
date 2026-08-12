import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/page_animation_guard.dart';

void main() {
  test('only one page animation can own the lock', () {
    final guard = PageAnimationGuard();
    final token = guard.start();

    expect(guard.isAnimating, isTrue);
    expect(guard.start, throwsStateError);

    expect(guard.finish(token), isTrue);
    expect(guard.isAnimating, isFalse);
  });

  test('a completion after a direct jump cannot change new state', () {
    final guard = PageAnimationGuard();
    final staleToken = guard.start();

    guard.cancel();
    final currentToken = guard.start();

    expect(guard.finish(staleToken), isFalse);
    expect(guard.isAnimating, isTrue);
    expect(guard.finish(currentToken), isTrue);
    expect(guard.isAnimating, isFalse);
  });

  test('a failed owned animation falls back to its target page', () {
    expect(
      failedPageAnimationFallbackTarget(
        animationFailed: true,
        tokenReleased: true,
        isDisposed: false,
        targetPage: 8,
      ),
      8,
    );
    expect(
      failedPageAnimationFallbackTarget(
        animationFailed: false,
        tokenReleased: true,
        isDisposed: false,
        targetPage: 8,
      ),
      isNull,
    );
    expect(
      failedPageAnimationFallbackTarget(
        animationFailed: true,
        tokenReleased: false,
        isDisposed: false,
        targetPage: 8,
      ),
      isNull,
    );
    expect(
      failedPageAnimationFallbackTarget(
        animationFailed: true,
        tokenReleased: true,
        isDisposed: true,
        targetPage: 8,
      ),
      isNull,
    );
  });
}
