import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';

/// Opens a reader above the main navigation shell so its side and bottom bars
/// cannot remain visible around the reader.
Future<T?> pushFavoriteReader<T>(Widget Function() readerBuilder) {
  return App.rootContext.to<T>(readerBuilder);
}
