/// Applies the platform-specific native window sequence for reader fullscreen.
///
/// On macOS, `setFullScreen` already delegates to AppKit's asynchronous
/// `toggleFullScreen`. Hiding and showing the window around that transition can
/// enqueue conflicting native window operations, so macOS must toggle directly.
Future<void> runFullscreenTransition({
  required bool isMacOS,
  required bool targetFullscreen,
  required Future<void> Function() hideWindow,
  required Future<void> Function(bool fullscreen) setFullScreen,
  required Future<void> Function() showWindow,
}) async {
  if (isMacOS) {
    await setFullScreen(targetFullscreen);
    return;
  }

  await hideWindow();
  try {
    await setFullScreen(targetFullscreen);
  } finally {
    await showWindow();
  }
}
