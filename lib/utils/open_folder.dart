enum FolderOpenRoute {
  windowsExplorer,
  macFinder,
  linuxFileManager,
  androidDocuments,
  mobileUrlLauncher,
}

/// Selects the platform integration used to reveal a local comic directory.
///
/// Keeping this decision independent from `dart:io` makes it possible to test
/// that Android never falls through to the `file://` URL-launcher path.
FolderOpenRoute resolveFolderOpenRoute({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
  required bool isAndroid,
}) {
  if (isWindows) return FolderOpenRoute.windowsExplorer;
  if (isMacOS) return FolderOpenRoute.macFinder;
  if (isLinux) return FolderOpenRoute.linuxFileManager;
  if (isAndroid) return FolderOpenRoute.androidDocuments;
  return FolderOpenRoute.mobileUrlLauncher;
}
