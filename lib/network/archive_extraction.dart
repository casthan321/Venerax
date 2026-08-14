import 'dart:io';

typedef ArchiveExtractor =
    Future<void> Function(String archivePath, String destinationPath);
typedef DirectoryCopier =
    Future<void> Function(Directory source, Directory destination);
typedef AsyncDirectoryRenamer =
    Future<Directory> Function(Directory source, String path);
typedef ArchiveCancellationCheck = bool Function();
typedef ArchiveBeforeCommit = void Function(Directory destination);

class ArchiveExtractionCancelled implements Exception {
  const ArchiveExtractionCancelled();

  @override
  String toString() => 'Archive extraction was cancelled';
}

class ArchivePublishRollbackException implements Exception {
  const ArchivePublishRollbackException(this.publishError, this.rollbackError);

  final Object publishError;
  final Object rollbackError;

  @override
  String toString() =>
      'Archive publish failed ($publishError) and rollback also failed '
      '($rollbackError)';
}

void _throwIfCancelled(ArchiveCancellationCheck? isCancelled) {
  if (isCancelled?.call() == true) {
    throw const ArchiveExtractionCancelled();
  }
}

/// Extracts into a unique staging directory and publishes the result only after
/// the archive has been fully unpacked.
///
/// SAF destinations cannot be written by the native ZIP implementation. For
/// those, extraction first happens in [scratchRoot], then the complete tree is
/// copied into a unique SAF staging directory. The final swap retains the old
/// output as a rollback backup until the new directory is in place.
Future<void> extractArchiveTransactionally({
  required String archivePath,
  required String outputPath,
  required String scratchRoot,
  required bool requiresSafBridge,
  required ArchiveExtractor extract,
  required DirectoryCopier copy,
  Future<void> Function(Directory staging)? validate,
  ArchiveCancellationCheck? isCancelled,
  ArchiveBeforeCommit? beforeCommit,
  String? operationId,
}) async {
  final id =
      operationId ??
      '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  final outputStaging = Directory('$outputPath.venera-extract-$id');
  final scratch = Directory(
    '$scratchRoot${Platform.pathSeparator}archive-extract-$id',
  );

  try {
    _throwIfCancelled(isCancelled);
    await _deleteDirectoryIfExists(outputStaging);
    if (requiresSafBridge) {
      await _deleteDirectoryIfExists(scratch);
      await scratch.create(recursive: true);
      _throwIfCancelled(isCancelled);
      await extract(archivePath, scratch.path);
      _throwIfCancelled(isCancelled);
      await outputStaging.create(recursive: true);
      await copy(scratch, outputStaging);
    } else {
      await outputStaging.create(recursive: true);
      await extract(archivePath, outputStaging.path);
    }

    _throwIfCancelled(isCancelled);
    await validate?.call(outputStaging);
    _throwIfCancelled(isCancelled);

    await replaceDirectoryWithStaging(
      outputStaging,
      Directory(outputPath),
      operationId: id,
      isCancelled: isCancelled,
      beforeCommit: beforeCommit,
    );
  } finally {
    await _deleteDirectoryIfExists(outputStaging);
    await _deleteDirectoryIfExists(scratch);
  }
}

/// Replaces [destination] with [staging], restoring the previous directory if
/// publishing fails. The backup is deliberately retained when rollback itself
/// fails so users still have a recoverable copy.
Future<void> replaceDirectoryWithStaging(
  Directory staging,
  Directory destination, {
  String? operationId,
  AsyncDirectoryRenamer? rename,
  ArchiveCancellationCheck? isCancelled,
  ArchiveBeforeCommit? beforeCommit,
}) async {
  final id = operationId ?? DateTime.now().microsecondsSinceEpoch.toString();
  final backup = Directory('${destination.path}.before-extract-$id');
  final renameDirectory = rename ?? (source, path) => source.rename(path);
  var destinationOriginallyExisted = false;
  var destinationMoved = false;
  var stagingInstallAttempted = false;
  var stagingInstalled = false;
  var committed = false;

  try {
    _throwIfCancelled(isCancelled);
    destinationOriginallyExisted = await destination.exists();
    if (destinationOriginallyExisted) {
      await _deleteDirectoryIfExists(backup);
      _throwIfCancelled(isCancelled);
      await renameDirectory(destination, backup.path);
      destinationMoved = true;
      _throwIfCancelled(isCancelled);
    }
    stagingInstallAttempted = true;
    await renameDirectory(staging, destination.path);
    stagingInstalled = true;
    _throwIfCancelled(isCancelled);
    beforeCommit?.call(destination);
    committed = true;
  } catch (error, stackTrace) {
    Object? rollbackError;
    try {
      var destinationExists = await destination.exists();
      if ((stagingInstalled || stagingInstallAttempted) &&
          destinationExists &&
          (destinationMoved || !destinationOriginallyExisted)) {
        try {
          await destination.delete(recursive: true);
          stagingInstalled = false;
        } catch (cleanupFailure) {
          // Some providers report an error after completing an operation. Do
          // not give up on restoring the backup until the final state has been
          // checked below.
          rollbackError = cleanupFailure;
        }
        destinationExists = await destination.exists();
      }

      final previousDirectoryNeedsRestore =
          destinationMoved ||
          (destinationOriginallyExisted && !destinationExists);
      if (previousDirectoryNeedsRestore) {
        if (destinationExists) {
          rollbackError ??= StateError(
            'Replacement directory could not be removed before rollback',
          );
        } else if (!await backup.exists()) {
          rollbackError = StateError(
            'Previous comic backup is missing during rollback',
          );
        } else {
          try {
            await renameDirectory(backup, destination.path);
          } catch (restoreFailure) {
            // Treat a provider error-after-success as restored only when the
            // destination is present and the backup has actually moved away.
            if (!await destination.exists() || await backup.exists()) {
              rollbackError = restoreFailure;
            }
          }
          if (await destination.exists() && !await backup.exists()) {
            destinationMoved = false;
            rollbackError = null;
          } else {
            rollbackError ??= StateError(
              'Previous comic directory was not restored',
            );
          }
        }
      } else if (destinationOriginallyExisted) {
        // The first rename failed before moving anything; the original
        // destination is already the desired rollback state.
        rollbackError = null;
      } else if (!destinationExists) {
        // There was no previous comic and the partial replacement is gone.
        rollbackError = null;
      } else {
        rollbackError ??= StateError(
          'Partial replacement directory could not be removed',
        );
      }
    } catch (rollbackFailure) {
      // Keep the backup in place whenever possible so the previous comic is
      // still manually recoverable even if the provider rejects restoration.
      rollbackError ??= rollbackFailure;
    }
    if (rollbackError != null) {
      throw ArchivePublishRollbackException(error, rollbackError);
    }
    Error.throwWithStackTrace(error, stackTrace);
  } finally {
    if (committed) await _deleteDirectoryIfExists(backup);
  }
}

Future<void> _deleteDirectoryIfExists(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } catch (_) {
    // Cleanup is best effort. The primary extraction/rollback error remains
    // more useful than a secondary stale-staging deletion failure.
  }
}
