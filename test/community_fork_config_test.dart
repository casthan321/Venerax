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
    expect(workflow['name'], 'Android');
    expect(workflow['on'], isA<YamlMap>());
    final jobs = workflow['jobs'] as YamlMap;
    expect(jobs.keys, containsAll(<String>['test', 'build-release']));
    expect(source, contains('ANDROID_SIGNING_CERT_SHA256'));
    expect(source, contains('venera-community-r8-mapping.zip'));
    expect(
      source,
      contains(
        "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')",
      ),
    );
    expect(source, isNot(contains('release:\n    types: [published]')));
  });
}
