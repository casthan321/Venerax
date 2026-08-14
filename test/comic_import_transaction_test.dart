import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/comic_import_transaction.dart';

void main() {
  late Directory temporaryRoot;

  setUp(() {
    temporaryRoot = Directory.systemTemp.createTempSync(
      'venera_comic_registration_test_',
    );
  });

  tearDown(() {
    if (temporaryRoot.existsSync()) {
      temporaryRoot.deleteSync(recursive: true);
    }
  });

  test('commits a batch once and assigns distinct ids', () async {
    final store = _FakeRegistrationStore();
    final first = _Comic('same-input-id', 'first');
    final second = _Comic('same-input-id', 'second');
    final firstArtifact = _TestArtifact(temporaryRoot, 'first');
    final secondArtifact = _TestArtifact(temporaryRoot, 'second');

    final count = await store.register([
      ComicRegistrationEntry(
        comic: first,
        folder: 'library',
        artifact: firstArtifact,
      ),
      ComicRegistrationEntry(
        comic: second,
        folder: 'library',
        artifact: secondArtifact,
      ),
    ]);

    expect(count, 2);
    expect(store.assignedIds, ['1', '2']);
    expect(store.localRows.keys, {'1', '2'});
    expect(store.favoriteRows.keys, {'library/1', 'library/2'});
    for (final artifact in [firstArtifact, secondArtifact]) {
      expect(artifact.commitCount, 1);
      expect(artifact.rollbackCount, 0);
      expect(artifact.directory.existsSync(), isTrue);
    }
  });

  test('second favorite failure rolls back both databases and files', () async {
    final store = _FakeRegistrationStore(throwOnFavoriteAttempt: 2);
    final first = _Comic('same-input-id', 'first');
    final second = _Comic('same-input-id', 'second');
    final firstArtifact = _TestArtifact(temporaryRoot, 'first');
    final secondArtifact = _TestArtifact(temporaryRoot, 'second');

    await expectLater(
      store.register([
        ComicRegistrationEntry(
          comic: first,
          folder: 'library',
          artifact: firstArtifact,
        ),
        ComicRegistrationEntry(
          comic: second,
          folder: 'library',
          artifact: secondArtifact,
        ),
      ]),
      throwsStateError,
    );

    expect(store.localRows, isEmpty);
    expect(store.favoriteRows, isEmpty);
    // Compensation is keyed by the assigned receipt ids, not either input id.
    expect(store.localRollbackAttempts, ['2', '1']);
    expect(store.favoriteRollbackAttempts, ['1']);
    for (final artifact in [firstArtifact, secondArtifact]) {
      expect(artifact.commitCount, 0);
      expect(artifact.rollbackCount, 1);
      expect(artifact.directory.existsSync(), isFalse);
    }
  });

  test('existing favorite is preserved when add returns false', () async {
    final existing = _Comic('existing', 'existing');
    final store = _FakeRegistrationStore()
      ..favoriteRows['library/1'] = existing;
    final imported = _Comic('input', 'imported');
    final artifact = _TestArtifact(temporaryRoot, 'imported');

    await expectLater(
      store.register([
        ComicRegistrationEntry(
          comic: imported,
          folder: 'library',
          artifact: artifact,
        ),
      ]),
      throwsStateError,
    );

    expect(store.localRows, isEmpty);
    expect(store.favoriteRows.keys, {'library/1'});
    expect(identical(store.favoriteRows['library/1'], existing), isTrue);
    expect(store.favoriteRollbackAttempts, isEmpty);
    expect(artifact.directory.existsSync(), isFalse);
  });

  test('second local insert failure rolls back the first comic', () async {
    final store = _FakeRegistrationStore(throwOnLocalAttempt: 2);
    final firstArtifact = _TestArtifact(temporaryRoot, 'first');
    final secondArtifact = _TestArtifact(temporaryRoot, 'second');

    await expectLater(
      store.register([
        ComicRegistrationEntry(
          comic: _Comic('1', 'first'),
          folder: 'library',
          artifact: firstArtifact,
        ),
        ComicRegistrationEntry(
          comic: _Comic('2', 'second'),
          folder: 'library',
          artifact: secondArtifact,
        ),
      ]),
      throwsStateError,
    );

    expect(store.localRows, isEmpty);
    expect(store.favoriteRows, isEmpty);
    expect(firstArtifact.directory.existsSync(), isFalse);
    expect(secondArtifact.directory.existsSync(), isFalse);
  });

  test('preserves owned directory when exact DB compensation fails', () async {
    final store = _FakeRegistrationStore(
      failLocalRelease: true,
      failLocalCompensation: true,
    );
    final artifact = _TestArtifact(temporaryRoot, 'preserved');

    await expectLater(
      store.register([
        ComicRegistrationEntry(
          comic: _Comic('input', 'comic'),
          folder: 'library',
          artifact: artifact,
        ),
      ]),
      throwsA(isA<ComicRegistrationRollbackException>()),
    );

    expect(store.localRows.keys, {'1'});
    expect(store.favoriteRows, isEmpty);
    expect(artifact.rollbackCount, 0);
    expect(artifact.directory.existsSync(), isTrue);
  });
}

final class _Comic {
  const _Comic(this.inputId, this.name);

  final String inputId;
  final String name;
}

final class _TestArtifact implements PendingComicArtifact {
  _TestArtifact(Directory root, String name)
    : directory = Directory('${root.path}${Platform.pathSeparator}$name')
        ..createSync();

  final Directory directory;
  int commitCount = 0;
  int rollbackCount = 0;
  bool _committed = false;

  @override
  void commit() {
    if (_committed) throw StateError('artifact committed twice');
    _committed = true;
    commitCount++;
  }

  @override
  Future<void> rollback() async {
    if (_committed) throw StateError('committed artifact rolled back');
    rollbackCount++;
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

final class _FakeRegistrationStore {
  _FakeRegistrationStore({
    this.throwOnLocalAttempt,
    this.throwOnFavoriteAttempt,
    this.failLocalRelease = false,
    this.failLocalCompensation = false,
  });

  final int? throwOnLocalAttempt;
  final int? throwOnFavoriteAttempt;
  final bool failLocalRelease;
  final bool failLocalCompensation;

  Map<String, _Comic> localRows = {};
  Map<String, _Comic> favoriteRows = {};
  final List<String> assignedIds = [];
  final List<String> localRollbackAttempts = [];
  final List<String> favoriteRollbackAttempts = [];

  var _nextId = 1;
  var _localAttempts = 0;
  var _favoriteAttempts = 0;

  Future<int> register(List<ComicRegistrationEntry<_Comic>> entries) {
    return registerComicBatchTransactionally(
      entries: entries,
      runLocalTransaction: _runLocalTransaction,
      runFavoriteTransaction: _runFavoriteTransaction,
      registerLocal: _registerLocal,
      rollbackLocal: _rollbackLocal,
      registerFavorite: _registerFavorite,
      rollbackFavorite: _rollbackFavorite,
    );
  }

  void _runLocalTransaction(void Function() operation) {
    final rowsBefore = Map<String, _Comic>.of(localRows);
    final nextIdBefore = _nextId;
    try {
      operation();
      if (failLocalRelease) throw StateError('local release failed');
    } catch (_) {
      if (!failLocalRelease) {
        localRows = rowsBefore;
        _nextId = nextIdBefore;
      }
      rethrow;
    }
  }

  void _runFavoriteTransaction(void Function() operation) {
    final rowsBefore = Map<String, _Comic>.of(favoriteRows);
    try {
      operation();
    } catch (_) {
      favoriteRows = rowsBefore;
      rethrow;
    }
  }

  String _registerLocal(_Comic comic) {
    _localAttempts++;
    if (_localAttempts == throwOnLocalAttempt) {
      throw StateError('local insert failed');
    }
    final id = (_nextId++).toString();
    if (localRows.containsKey(id)) throw StateError('duplicate local id');
    localRows[id] = comic;
    assignedIds.add(id);
    return id;
  }

  void _rollbackLocal(_Comic comic, String id) {
    localRollbackAttempts.add(id);
    if (failLocalCompensation) {
      throw StateError('local compensation failed');
    }
    final existing = localRows[id];
    if (existing == null) return;
    if (!identical(existing, comic)) {
      throw StateError('local receipt no longer owns row $id');
    }
    localRows.remove(id);
  }

  bool _registerFavorite(String folder, _Comic comic, String id) {
    _favoriteAttempts++;
    if (_favoriteAttempts == throwOnFavoriteAttempt) {
      throw StateError('favorite insert failed');
    }
    final key = '$folder/$id';
    if (favoriteRows.containsKey(key)) return false;
    favoriteRows[key] = comic;
    return true;
  }

  void _rollbackFavorite(String folder, _Comic comic, String id) {
    favoriteRollbackAttempts.add(id);
    final key = '$folder/$id';
    final existing = favoriteRows[key];
    if (existing == null) return;
    if (!identical(existing, comic)) {
      throw StateError('favorite receipt no longer owns row $key');
    }
    favoriteRows.remove(key);
  }
}
