/// Loads a stored history cover and refreshes its URL at most once if needed.
///
/// Some comic sources return cover URLs that expire. A history entry keeps the
/// old URL, so a failed load should refresh the comic info before giving up.
Future<T> loadHistoryCoverWithRefresh<T>({
  required String initialCover,
  required bool refreshBeforeLoad,
  required Future<T> Function(String cover) loadCover,
  required Future<String> Function() refreshCover,
}) async {
  var cover = initialCover;
  var refreshed = false;

  if (refreshBeforeLoad) {
    cover = await refreshCover();
    refreshed = true;
  }

  try {
    return await loadCover(cover);
  } catch (error, stackTrace) {
    if (refreshed) {
      Error.throwWithStackTrace(error, stackTrace);
    }

    try {
      cover = await refreshCover();
    } catch (_) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    return loadCover(cover);
  }
}

bool shouldUpdateHistoryCover(String storedCover, String loadedCover) {
  return loadedCover.isNotEmpty && storedCover != loadedCover;
}
