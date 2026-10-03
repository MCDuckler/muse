// What a screen that shows the board needs from it — and all it needs.
//
// The board on the desk's own screen is the Soundboard itself; the board on a phone
// linked to a desk, or in a window of its own, is a copy fed over a wire. Both draw
// through this, so there is one BoardRoom and not two.
import 'package:flutter/foundation.dart';

import 'pad_spec.dart';
import 'samples.dart';
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

  /// Whether this face can change the board: the desk's own always; a phone or the
  /// board's own window when the desk it follows takes changes over the wire.
  bool get editable;

  /// The shape of a sample's sound, 128 bins 0..1, for the pad's face — or null while
  /// it is not known.
  Float32List? peaksOf(int sampleId);

  // ------------------------------------------------------------------ changing it
  // Asked only of a face that is [editable]. On the desk each is the change itself;
  // on a screen that follows a desk it is said to the desk, which makes it and says
  // the board back.

  /// The pad at [bank], [pad] made [spec] — or cleared with null.
  Future<void> setPad(int bank, int pad, PadSpec? spec);

  /// Two pads swapped, across banks or not.
  Future<void> swap((int, int) from, (int, int) to);

  Future<void> renameBank(int i, String name);

  /// A row of one bank pinned under the desk's decks, or none.
  Future<void> setStrip(StripSpec? strip);

  /// The pad heard on its own, from its trim-in (the settings' listen) — and quiet again.
  Future<void> listen(int bank, int pad);
  Future<void> quiet(int bank, int pad);

  // ------------------------------------------------------------------ the sounds
  /// The sounds there are to put on a pad: the kit, the house's shelf, the user's own.
  SampleLibrary get library;

  /// Whether new sounds can be kept from this screen (a server to keep them on).
  bool get hasServer;

  Future<void> refreshLibrary();

  /// A sound heard before it is on any pad — on the desk, wherever the screen is.
  Future<void> audition(Sample sample);

  Future<Sample> importBytes(String filename, List<int> bytes, {String? name});
  Future<void> renameSample(Sample s, String name);
  Future<void> forgetSample(Sample s);
}
