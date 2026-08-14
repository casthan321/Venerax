import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows installers use a distinct community identity', () {
    final x64 = File('windows/build.iss').readAsStringSync();
    final arm64 = File('windows/build_arm64.iss').readAsStringSync();

    for (final script in [x64, arm64]) {
      expect(script, contains('#define MyAppName "Venera Community"'));
      expect(
        script,
        contains('https://github.com/casthan321/Venera-Community'),
      );
      expect(script, contains('AppId={{B5A1BB17-D82D-410F-BF3E-24EA3878B2DA}'));
      expect(script, contains('PrivilegesRequired=lowest'));
      expect(script, contains('recursesubdirs createallsubdirs'));
      expect(script, isNot(contains('1A39CB64-0A5B-478E-9590-978614C804A8')));
      expect(script, isNot(contains('DelTree(')));
      expect(script, isNot(contains(r'C:\Program Files (x86)\Venera')));
    }

    expect(x64, contains(r'\x64\runner\Release\*'));
    expect(arm64, contains(r'\arm64\runner\Release\*'));
  });

  test(
    'Windows build scripts fail fast and never mutate installer templates',
    () {
      final shared = File('windows/build_windows.py').readAsStringSync();
      final x64 = File('windows/build.py').readAsStringSync();
      final arm64 = File('windows/build_arm64.py').readAsStringSync();

      expect(shared, contains('check=True'));
      expect(shared, contains('Path(executable).suffix.lower()'));
      expect(shared, contains('Incomplete Flutter Windows output'));
      expect(shared, contains('_require_supported_host(architecture)'));
      expect(shared, contains('native ARM64 Windows host'));
      expect(shared, contains('cross-compile Windows'));
      expect(shared, isNot(contains('"--target-platform"')));
      expect(
        shared,
        contains('_remove_previous_packages(architecture, version)'),
      );
      expect(shared, contains('package.unlink(missing_ok=True)'));
      expect(shared, contains('Unsafe Windows package path'));
      expect(shared, contains('_remove_previous_flutter_output(architecture)'));
      expect(shared, contains('shutil.rmtree(release_dir)'));
      expect(shared, contains('st_mtime_ns'));
      expect(shared, contains('was not freshly built'));
      expect(shared, contains('was not freshly generated'));
      expect(shared, isNot(contains('archive_base.with_suffix')));
      expect(shared, contains('installer-{architecture}.iss'));
      expect(shared, isNot(contains('shell=True')));
      expect(shared, isNot(contains('@latest')));
      expect(shared, contains('TRANSLATION_SHA256'));
      expect(shared, contains('hashlib.sha256(content).hexdigest()'));
      expect(x64, contains('build("x64")'));
      expect(arm64, contains('build("arm64")'));
      expect(arm64, contains('rejects cross-packaging on x64 Windows'));
      expect(arm64, contains('ARM64 packaging refused'));
      expect(arm64, contains('from None'));
      expect(arm64, isNot(contains('windows/x64/runner/Release')));
    },
  );

  test('Windows runner opts into safe modern platform behavior', () {
    final manifest = File(
      'windows/runner/runner.exe.manifest',
    ).readAsStringSync();
    final runner = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final window = File('windows/runner/win32_window.cpp').readAsStringSync();

    expect(manifest, contains('PerMonitorV2'));
    expect(manifest, contains('<longPathAware'));
    expect(runner, isNot(contains('heartBeat')));
    expect(runner, isNot(contains('std::exit')));
    expect(runner, contains('message == WM_XBUTTONDOWN'));
    expect(runner, contains('The system owns the bitmap'));
    expect(window, contains('SetWindowPos(hwnd, HWND_TOP'));
  });

  test('Windows build remains compatible with current MSVC coroutines', () {
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();

    expect(
      cmake,
      contains('_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'),
    );
  });
}
