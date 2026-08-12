import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera/utils/local_comic_layout.dart';

void main() {
  test(
    'chapter-only comic keeps one parent comic and uses a chapter cover',
    () {
      final layout = resolveLocalComicDirectoryLayout(
        rootImages: const [],
        chapterImages: const {
          'Vol_02': ['002.jpg'],
          'Vol_01': ['002.jpg', '001.jpg'],
        },
      );

      expect(layout, isNotNull);
      expect(layout!.chapters, ['Vol_01', 'Vol_02']);
      expect(layout.coverPath, path.join('Vol_01', '001.jpg'));
    },
  );

  test('root cover remains preferred when chapters also exist', () {
    final layout = resolveLocalComicDirectoryLayout(
      rootImages: const ['002.jpg', 'cover.png'],
      chapterImages: const {
        'Vol_01': ['001.jpg'],
      },
    );

    expect(layout, isNotNull);
    expect(layout!.coverPath, 'cover.png');
    expect(layout.chapters, ['Vol_01']);
  });

  test('directories without any comic image stay invalid', () {
    final layout = resolveLocalComicDirectoryLayout(
      rootImages: const [],
      chapterImages: const {'Vol_01': [], 'Vol_02': []},
    );

    expect(layout, isNull);
  });
}
