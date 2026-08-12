import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/open_folder.dart';

void main() {
  test('Android uses the DocumentsProvider route', () {
    expect(
      resolveFolderOpenRoute(
        isWindows: false,
        isMacOS: false,
        isLinux: false,
        isAndroid: true,
      ),
      FolderOpenRoute.androidDocuments,
    );
  });

  test('desktop platforms keep their native file-manager routes', () {
    expect(
      resolveFolderOpenRoute(
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        isAndroid: false,
      ),
      FolderOpenRoute.windowsExplorer,
    );
    expect(
      resolveFolderOpenRoute(
        isWindows: false,
        isMacOS: true,
        isLinux: false,
        isAndroid: false,
      ),
      FolderOpenRoute.macFinder,
    );
    expect(
      resolveFolderOpenRoute(
        isWindows: false,
        isMacOS: false,
        isLinux: true,
        isAndroid: false,
      ),
      FolderOpenRoute.linuxFileManager,
    );
  });

  test('other mobile platforms retain the URL-launcher route', () {
    expect(
      resolveFolderOpenRoute(
        isWindows: false,
        isMacOS: false,
        isLinux: false,
        isAndroid: false,
      ),
      FolderOpenRoute.mobileUrlLauncher,
    );
  });
}
