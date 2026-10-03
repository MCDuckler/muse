// The desk's keys for the board: the function keys across the top, the number pad.
//
// F1–F8 are the shown bank's first two rows, ⇧F1–F8 its last two; the number pad's
// 1–9 are its first nine pads as the pad is laid out, 0 stops everything; `,` and
// `.` turn to the bank before and after. Nothing a deck key already means (see
// BoothPage.keys), and nothing that is a text key but the two bank keys — which are
// not read while something is being typed.
import 'package:flutter/services.dart';

abstract final class BoardKeys {
  static const _f = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
  ];

  static const _numpad = [
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];

  /// Which pad (0..15) [key] is, or null.
  static int? padFor(LogicalKeyboardKey key, {required bool shift}) {
    final f = _f.indexOf(key);
    if (f >= 0) return shift ? f + 8 : f;
    final n = _numpad.indexOf(key);
    if (n >= 0) return n;
    return null;
  }

  /// Whether [key] is a pad key at all, shifted or not.
  static bool isPadKey(LogicalKeyboardKey key) => _f.contains(key) || _numpad.contains(key);

  static bool isStop(LogicalKeyboardKey key) => key == LogicalKeyboardKey.numpad0;

  /// −1, +1, or 0: the bank keys.
  static int bankStep(LogicalKeyboardKey key) => key == LogicalKeyboardKey.comma
      ? -1
      : key == LogicalKeyboardKey.period
          ? 1
          : 0;

  /// The cap a pad shows: F3, or S·F3 for shift and F3. (No arrow glyph: the
  /// typewriter face has none, and a cap that reads F3 on two pads is a lie.)
  static String capFor(int pad) => pad < 8 ? 'F${pad + 1}' : 'S·F${pad - 7}';

  /// The one line the bank row shows.
  static const caption = 'F1–F8 · SHIFT F1–F8 · KP 1–9 · , .';

  /// The rows a keys sheet lists.
  static const sheet = <(String, String)>[
    ('F1–F8', 'The board: pads 1–8 of the bank on show'),
    ('⇧ F1–F8', 'The board: pads 9–16'),
    ('KP 1–9 · KP 0', 'The board: pads 1–9 · stop every pad'),
    (', .', 'The board: the bank before, after'),
  ];
}
