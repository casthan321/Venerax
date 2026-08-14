import 'dart:convert';
import 'dart:io';

typedef AsyncFileRenamer = Future<File> Function(File source, String path);

/// Writes [contents] beside [destination], flushes it, then atomically replaces
/// the destination with the completed file.
///
/// Keeping the temporary file on the same volume is important: a rename on the
/// same file system cannot expose a partially written JSON document. A stale
/// temporary file from an interrupted process is safely overwritten next time.
Future<void> writeStringAtomically(
  File destination,
  String contents, {
  Encoding encoding = utf8,
}) async {
  final temporary = File('${destination.path}.tmp');
  try {
    await temporary.writeAsString(contents, encoding: encoding, flush: true);
    await temporary.rename(destination.path);
  } finally {
    try {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    } catch (_) {
      // The destination has already been committed. A best-effort cleanup must
      // not turn a successful settings save into an application error.
    }
  }
}

/// Commits an already completed [staging] file without risking the previous
/// [destination].
///
/// Windows does not allow renaming over an existing file. Move the previous
/// destination aside first, but keep it until the staging rename succeeds. If
/// the second rename fails (disk full, antivirus lock, permission change), the
/// original file is restored instead of being deleted permanently.
Future<void> replaceFileWithStaging(
  File staging,
  File destination, {
  AsyncFileRenamer? rename,
}) async {
  final renameFile = rename ?? (source, path) => source.rename(path);
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final backup = File('${destination.path}.before-replace-$suffix');
  var destinationMoved = false;
  var committed = false;

  try {
    if (await destination.exists()) {
      await renameFile(destination, backup.path);
      destinationMoved = true;
    }
    await renameFile(staging, destination.path);
    committed = true;
  } catch (_) {
    if (destinationMoved) {
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
        if (await backup.exists()) {
          await renameFile(backup, destination.path);
          destinationMoved = false;
        }
      } catch (_) {
        // Preserve the backup for manual recovery if rollback itself fails.
      }
    }
    rethrow;
  } finally {
    if (committed && await backup.exists()) {
      await backup.delete();
    }
  }
}
