// The show's sound as the room hears it: measured off the booth's own engine
// (native/engine/src/tap.h) rather than modelled from the house's pulse.
//
// The pulse (show_deck.dart's audioThrough) is the record as mastered, pushed
// through a model of the mixer: it knows the EQ's gains and the filter's sweep
// roughly, and nothing of the echo's tail, the gate, a loop's stutter, a brake, a
// scratch. The engine measures each deck's output and the master's as they are
// played, stamped with when they are heard. So where a deck plays on the engine,
// its bands, kick and onsets come from here; the stems' levels (drums, rest,
// vocals), which a mix of sound cannot tell apart, stay the pulse's.
//
// Read at the engine's clock plus its output latency: the rows for sound rendered
// but not yet out of the speaker are already there, and taking them is what lets the
// picture, which reaches the eye a frame or two after it is drawn, keep up with the ear.
import 'dart:typed_data';

import '../../audio/engine.dart';
import 'show_state.dart';

class ShowHeard {
  ShowHeard(this.engine);
  final Engine engine;
  double? _last;

  /// How far ahead of the ear to read, at most: the engine's own latency, and never
  /// more than this.
  static const maxLead = 0.04;

  /// One frame's reading: the master, and each of [decks] (engine deck indices) that
  /// has a row. Null while the engine has measured nothing yet (it starts on the first
  /// ask).
  ({ShowAudio master, Map<int, ShowAudio> decks, Float32List? spectrum})? read(Iterable<int> decks) {
    final to = engine.now() + (engine.latency < maxLead ? engine.latency : maxLead);
    var from = _last ?? to - 1 / 60;
    // The clock went back (a restarted engine): from a frame ago.
    if (from > to) from = to - 1 / 60;
    _last = to;
    final m = engine.heard(Engine.master, from, to);
    if (m == null) return null;
    return (
      master: audioOf(m),
      decks: {
        for (final d in decks)
          if (engine.heard(d, from, to) case final h?) d: audioOf(h),
      },
      spectrum: m.spectrum,
    );
  }

  /// What the engine heard, as the show's sound: no stems.
  static ShowAudio audioOf(HeardSound h) => ShowAudio(
        sub: h.sub,
        low: h.low,
        mid: h.mid,
        high: h.high,
        air: h.air,
        kick: h.kick,
        snare: h.snare,
        hat: h.hat,
        onset: h.onset,
      );

  /// [heard] with the stems' levels of [modelled] (the pulse's): the sound the
  /// engine measured, the parts the house knows.
  static ShowAudio over(ShowAudio heard, ShowAudio modelled) => ShowAudio(
        sub: heard.sub,
        low: heard.low,
        mid: heard.mid,
        high: heard.high,
        air: heard.air,
        kick: heard.kick,
        snare: heard.snare,
        hat: heard.hat,
        onset: heard.onset,
        drums: modelled.drums,
        rest: modelled.rest,
        vocals: modelled.vocals,
      );
}
