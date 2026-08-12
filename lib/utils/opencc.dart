import 'dart:convert';

import 'package:flutter/services.dart';

abstract class OpenCC {
  static late final Map<int, int> _s2t;
  static late final Map<int, int> _t2s;

  static Future<void> init() async {
    var data = await rootBundle.load("assets/opencc.txt");
    var txt = utf8.decode(data.buffer.asUint8List());
    _s2t = <int, int>{};
    _t2s = <int, int>{};
    for (var line in txt.split('\n')) {
      final mapping = line.trim();
      final runes = mapping.runes.toList(growable: false);
      if (mapping.isEmpty || mapping.startsWith('#') || runes.length != 2) {
        continue;
      }
      var s = runes[0];
      var t = runes[1];
      _s2t[s] = t;
      _t2s[t] = s;
    }
  }

  static bool hasChineseSimplified(String text) {
    for (var rune in text.runes) {
      if (_s2t.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  static bool hasChineseTraditional(String text) {
    for (var rune in text.runes) {
      if (_t2s.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  static String simplifiedToTraditional(String text) {
    var sb = StringBuffer();
    for (var rune in text.runes) {
      if (_s2t.containsKey(rune)) {
        sb.write(String.fromCharCodes([_s2t[rune]!]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }

  static String traditionalToSimplified(String text) {
    var sb = StringBuffer();
    for (var rune in text.runes) {
      if (_t2s.containsKey(rune)) {
        sb.write(String.fromCharCodes([_t2s[rune]!]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }
}
