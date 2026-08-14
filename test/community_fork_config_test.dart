import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Android community fork has a distinct install identity', () {
    const applicationId = 'io.github.casthan321.venera';
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/io/github/casthan321/venera/MainActivity.kt',
    );

    expect(gradle, contains('namespace = "$applicationId"'));
    expect(gradle, contains('applicationId = "$applicationId"'));
    expect(activity.existsSync(), isTrue);
    expect(activity.readAsStringSync(), startsWith('package $applicationId'));
    expect(manifest, contains('@mipmap/ic_launcher_community'));
    expect(manifest, contains('@string/app_name'));
    expect(manifest, isNot(contains('com.github.wgh136.venera')));

    for (final conflictingHost in <String>[
      'nhentai.net',
      'e-hentai.org',
      'exhentai.org',
    ]) {
      expect(manifest, isNot(contains(conflictingHost)));
    }
  });

  test('Android release workflow is valid YAML with test and build jobs', () {
    final source = File('.github/workflows/android.yml').readAsStringSync();
    final document = loadYaml(source);

    expect(document, isA<YamlMap>());
    final workflow = document as YamlMap;
    expect(workflow['name'], 'Android and Windows');
    expect(workflow['on'], isA<YamlMap>());
    final jobs = workflow['jobs'] as YamlMap;
    expect(
      jobs.keys,
      containsAll(<String>[
        'test',
        'build-release',
        'build-windows',
        'publish-release',
      ]),
    );
    expect(source, contains('ANDROID_SIGNING_CERT_SHA256'));
    expect(source, contains('venera-community-r8-mapping.zip'));
    expect(source, contains('SHA256SUMS-windows'));
    expect(
      source,
      contains("body_path: doc/releases/\${{ github.ref_name }}.md"),
    );
    expect(
      source,
      contains("prerelease: \${{ contains(github.ref_name, '-') }}"),
    );
    expect(source, contains('name: Venera Community \${{ github.ref_name }}'));
    expect(source, contains('test "\$app_version" = "\$project_version"'));
    expect(
      source,
      contains(
        "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')",
      ),
    );
    expect(source, isNot(contains('release:\n    types: [published]')));
  });

  test('community project links use the canonical repository name', () {
    const canonicalRepository = 'casthan321/Venera-Community';
    const previousRepository = 'casthan321/Venerax';
    final projectLinks = <String>[
      File('README.md').readAsStringSync(),
      File('doc/android_release.md').readAsStringSync(),
      File('lib/pages/settings/about.dart').readAsStringSync(),
      File('pubspec.yaml').readAsStringSync(),
    ];

    expect(projectLinks, everyElement(contains(canonicalRepository)));
    expect(projectLinks, everyElement(isNot(contains(previousRepository))));
  });

  test('Release version metadata and release notes stay in sync', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final fullVersion = pubspec['version'] as String;
    final versionName = fullVersion.split('+').first;
    final appSource = File('lib/foundation/app.dart').readAsStringSync();

    expect(fullVersion, '1.8.0-beta.1+180');
    expect(versionName, '1.8.0-beta.1');
    expect(appSource, contains('final version = "$versionName"'));
    expect(File('doc/releases/v$versionName.md').lengthSync(), greaterThan(0));
  });

  test('workflows do not depend on the previous checkout directory', () {
    final workflow = File('.github/workflows/main.yml').readAsStringSync();

    expect(workflow, isNot(contains('/Users/runner/work/venera/venera')));
    expect(workflow, contains('mkdir -p build/ios/iphoneos/Payload'));
  });
}
