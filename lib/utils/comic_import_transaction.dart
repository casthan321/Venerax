/// A filesystem artifact that remains provisional until its comic metadata has
/// been registered successfully.
abstract interface class PendingComicArtifact {
  /// Relinquishes rollback ownership after durable registration. This method
  /// must not throw; cleanup that cannot be completed should be best-effort.
  void commit();

  Future<void> rollback();
}

class ComicRegistrationEntry<T> {
  const ComicRegistrationEntry({
    required this.comic,
    this.folder,
    this.artifact,
  });

  final T comic;
  final String? folder;
  final PendingComicArtifact? artifact;
}

class ComicRegistrationRollbackException implements Exception {
  const ComicRegistrationRollbackException(
    this.registrationError,
    this.rollbackErrors,
  );

  final Object registrationError;
  final List<Object> rollbackErrors;

  @override
  String toString() =>
      'Comic registration failed ($registrationError), and rollback also '
      'failed (${rollbackErrors.join('; ')})';
}

typedef ComicRegistrationTransaction = void Function(void Function() operation);
typedef LocalComicRegistrar<T> = String Function(T comic);
typedef LocalComicRollback<T> = void Function(T comic, String id);
typedef FavoriteComicRegistrar<T> =
    bool Function(String folder, T comic, String id);
typedef FavoriteComicRollback<T> =
    void Function(String folder, T comic, String id);

/// Registers one batch and compensates every completed side effect on failure.
///
/// Registration callbacks are synchronous deliberately: allocating an id and
/// inserting the corresponding local/favorite rows must run without an async
/// interleave. Filesystem artifacts are committed only after every row exists.
Future<int> registerComicBatchTransactionally<T>({
  required Iterable<ComicRegistrationEntry<T>> entries,
  required ComicRegistrationTransaction runLocalTransaction,
  required ComicRegistrationTransaction runFavoriteTransaction,
  required LocalComicRegistrar<T> registerLocal,
  required LocalComicRollback<T> rollbackLocal,
  required FavoriteComicRegistrar<T> registerFavorite,
  required FavoriteComicRollback<T> rollbackFavorite,
}) async {
  final batch = entries.toList(growable: false);
  final applied = <_AppliedComicRegistration<T>>[];

  try {
    // The local transaction is outermost. If favorite registration fails, its
    // savepoint rolls back first and the local savepoint then rolls back every
    // assigned id. Exact compensation below also covers the narrower case
    // where the favorites database commits but releasing the local savepoint
    // fails (two SQLite databases cannot share one atomic transaction).
    runLocalTransaction(() {
      runFavoriteTransaction(() {
        for (final entry in batch) {
          final id = registerLocal(entry.comic);
          final registration = _AppliedComicRegistration(entry, id);
          applied.add(registration);

          final folder = entry.folder;
          if (folder != null) {
            final added = registerFavorite(folder, entry.comic, id);
            if (!added) {
              throw StateError(
                'Comic $id is already registered in favorite folder '
                '"$folder"',
              );
            }
            registration.favoriteAdded = true;
          }
        }
      });
    });

    // Keeping commit synchronous and non-throwing prevents a successful batch
    // from ending in a partially released artifact-ownership state.
    for (final entry in batch) {
      entry.artifact?.commit();
    }
    return batch.length;
  } catch (error, stackTrace) {
    final rollbackErrors = <Object>[];
    final artifactsToPreserve = <PendingComicArtifact>{};

    // Always run exact compensation, even when a savepoint reported a clean
    // rollback. This is deliberate: a RELEASE/ROLLBACK failure can leave the
    // actual database state uncertain. Rollback callbacks must be receipt
    // based and become a no-op when their exact row is already absent.
    for (final registration in applied.reversed) {
      final entry = registration.entry;
      final folder = entry.folder;
      if (registration.favoriteAdded && folder != null) {
        try {
          rollbackFavorite(folder, entry.comic, registration.id);
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
          final artifact = entry.artifact;
          if (artifact != null) artifactsToPreserve.add(artifact);
        }
      }
      try {
        rollbackLocal(entry.comic, registration.id);
      } catch (rollbackError) {
        rollbackErrors.add(rollbackError);
        final artifact = entry.artifact;
        if (artifact != null) artifactsToPreserve.add(artifact);
      }
    }

    // Roll back every provisional artifact, including entries that were never
    // reached. Preserve an artifact when its database compensation failed so a
    // surviving row never points at a directory that this rollback deleted.
    for (final entry in batch.reversed) {
      final artifact = entry.artifact;
      if (artifact == null || artifactsToPreserve.contains(artifact)) continue;
      try {
        await artifact.rollback();
      } catch (rollbackError) {
        rollbackErrors.add(rollbackError);
      }
    }

    if (rollbackErrors.isNotEmpty) {
      Error.throwWithStackTrace(
        ComicRegistrationRollbackException(error, rollbackErrors),
        stackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

class _AppliedComicRegistration<T> {
  _AppliedComicRegistration(this.entry, this.id);

  final ComicRegistrationEntry<T> entry;
  final String id;
  bool favoriteAdded = false;
}
