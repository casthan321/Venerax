import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/history_cover_fallback.dart';

void main() {
  group('loadHistoryCoverWithRefresh', () {
    test('uses a working stored cover without refreshing', () async {
      var refreshes = 0;

      final result = await loadHistoryCoverWithRefresh(
        initialCover: 'stored',
        refreshBeforeLoad: false,
        loadCover: (cover) async => 'loaded:$cover',
        refreshCover: () async {
          refreshes++;
          return 'fresh';
        },
      );

      expect(result, 'loaded:stored');
      expect(refreshes, 0);
    });

    test('refreshes and retries once after a stored cover fails', () async {
      final loadedCovers = <String>[];
      var refreshes = 0;

      final result = await loadHistoryCoverWithRefresh(
        initialCover: 'expired',
        refreshBeforeLoad: false,
        loadCover: (cover) async {
          loadedCovers.add(cover);
          if (cover == 'expired') {
            throw StateError('expired');
          }
          return 'image';
        },
        refreshCover: () async {
          refreshes++;
          return 'fresh';
        },
      );

      expect(result, 'image');
      expect(loadedCovers, ['expired', 'fresh']);
      expect(refreshes, 1);
    });

    test('refreshes an opaque cover before the first load', () async {
      final loadedCovers = <String>[];
      var refreshes = 0;

      final result = await loadHistoryCoverWithRefresh(
        initialCover: 'cover.token',
        refreshBeforeLoad: true,
        loadCover: (cover) async {
          loadedCovers.add(cover);
          return 'image';
        },
        refreshCover: () async {
          refreshes++;
          return 'resolved';
        },
      );

      expect(result, 'image');
      expect(loadedCovers, ['resolved']);
      expect(refreshes, 1);
    });

    test('does not refresh twice after a refreshed cover fails', () async {
      var refreshes = 0;

      await expectLater(
        loadHistoryCoverWithRefresh<void>(
          initialCover: 'cover.token',
          refreshBeforeLoad: true,
          loadCover: (_) async => throw StateError('failed'),
          refreshCover: () async {
            refreshes++;
            return 'resolved';
          },
        ),
        throwsStateError,
      );
      expect(refreshes, 1);
    });

    test('preserves the original load error when refresh fails', () async {
      final originalError = StateError('expired');

      await expectLater(
        loadHistoryCoverWithRefresh<void>(
          initialCover: 'expired',
          refreshBeforeLoad: false,
          loadCover: (_) async => throw originalError,
          refreshCover: () async => throw StateError('refresh failed'),
        ),
        throwsA(same(originalError)),
      );
    });
  });

  group('shouldUpdateHistoryCover', () {
    test('updates only to a different non-empty loaded cover', () {
      expect(shouldUpdateHistoryCover('old', 'new'), isTrue);
      expect(shouldUpdateHistoryCover('same', 'same'), isFalse);
      expect(shouldUpdateHistoryCover('old', ''), isFalse);
    });
  });
}
