import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/atomic_file.dart';

void main() {
  test('atomic string writes replace an existing destination', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-atomic-string-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/setting.txt');
    await destination.writeAsString('old');

    await writeStringAtomically(destination, 'new');

    expect(await destination.readAsString(), 'new');
    expect(await File('${destination.path}.tmp').exists(), isFalse);
  });

  test('failed staging commit restores the previous destination', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-atomic-file-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/comic.zip');
    final staging = File('${destination.path}.part');
    await destination.writeAsString('known-good');
    await staging.writeAsString('replacement');

    var calls = 0;
    Future<File> failingSecondRename(File source, String path) async {
      calls++;
      if (calls == 2) {
        throw const FileSystemException('simulated commit failure');
      }
      return source.rename(path);
    }

    await expectLater(
      replaceFileWithStaging(staging, destination, rename: failingSecondRename),
      throwsA(isA<FileSystemException>()),
    );

    expect(await destination.readAsString(), 'known-good');
    expect(await staging.readAsString(), 'replacement');
    expect(
      directory.listSync().where(
        (entry) => entry.path.contains('before-replace'),
      ),
      isEmpty,
    );
  });
}
