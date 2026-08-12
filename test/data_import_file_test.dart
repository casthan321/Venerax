import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data.dart';

void main() {
  test('stages imported files beside destination before replacement', () async {
    final root = await Directory.systemTemp.createTemp('venera-import-test-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final sourceDirectory = await Directory(
      '${root.path}${Platform.pathSeparator}source',
    ).create();
    final destinationDirectory = await Directory(
      '${root.path}${Platform.pathSeparator}destination',
    ).create();
    final source = File(
      '${sourceDirectory.path}${Platform.pathSeparator}history.db',
    );
    final destination = File(
      '${destinationDirectory.path}${Platform.pathSeparator}history.db',
    );
    await source.writeAsString('new database bytes');
    await destination.writeAsString('old database bytes');

    await replaceImportedFile(source, destination.path);

    expect(await destination.readAsString(), 'new database bytes');
    // The extracted source remains available until the import transaction is
    // complete; this proves the replacement does not use a cross-drive rename.
    expect(await source.readAsString(), 'new database bytes');
    expect(
      destinationDirectory.listSync().where(
        (entry) => entry.path.contains('.before-import-'),
      ),
      isEmpty,
    );
    expect(
      destinationDirectory.listSync().where(
        (entry) => entry.path.contains('.importing-'),
      ),
      isEmpty,
    );
  });
}
