// What a screen that shows the board needs from it — and all it needs.
//
// The board on the desk's own screen is the Soundboard itself; the board on a phone
// linked to a desk, or in a window of its own, is a copy fed over a wire. Both draw
// through this, so there is one BoardRoom and not two.
import 'package:flutter/foundation.dart';

import 'pad_spec.dart';
import 'soundboard.dart' show PadState;

abstract class BoardFace implements Listenable {
  BoardDoc get doc;

  /// Which bank is on show.
  int get bank;

  PadSpec? pad(int bank, int pad);
  PadState stateOf(int bank, int pad);
  bool get anySounding;
  PadSpec? get lastFired;

  Future<void> press(int bank, int pad);
  Future<void> release(int bank, int pad);
  Future<void> stopAll();
  Future<void> showBank(int i);
  Future<void> setLevel(double v);

  /// Whether this face can change the board (a phone playing a desk's board cannot,
  /// for now).
  bool get editable;

  /// The shape of a sample's sound, 128 bins 0..1, for the pad's face — or null while
  /// it is not known.
  Float32List? peaksOf(int sampleId);
}
