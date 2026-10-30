// The datamosh held (the effect Fx.mosh: native/stage/src/fx.h's held mosh) played
// by the music. A datamosh is a codec that lost its key frames: the picture as it was
// dragged on and on by whatever moves now, until a key frame comes and it is whole
// again. Here the record says when the key frames come, how much of the picture is
// let through between them, how far it is dragged and how blocky:
//
//   on each bar     a few patches of the picture let through (so it never goes to
//                   mud), more on a phrase;
//   an intro, an outro, a breakdown
//                   a slow, smooth melt: little grain, long smears, a key frame every
//                   eight bars;
//   a build         the smear growing as it climbs, the key frames closer — every two
//                   bars, then each bar, then each beat of the last — the grain rising;
//   the drop        the picture whole on the drop, then four bars of the hardest,
//                   blockiest mosh on the kicks, then easing;
//   a snare         a burst of the codec's grain;
//   the kick        the native stage's own push and its blocks thrown too far.
//
// The effect's knobs (TransformSet: grain, melt, keys) move all of it. Where a
// record has no grid, bars by the clock. Pure: a frame in, the stage's numbers out —
// the booth's stage and a stage in a window of its own play it alike.
import 'dart:math' as math;

import 'show_rig.dart';
import 'show_state.dart';

/// What the stage is told this frame (ws_mosh_hold): on, how healed (0 all smear ..
/// 1 the picture whole), how far dragged (0..2), how blocky (0..1), the key frames
/// asked for so far (a count).
typedef MoshDrive = ({bool on, double heal, double strength, double grain, int keys});

class MoshClock {
  int _keys = 0;
  bool _on = false;
  int? _bar, _beat;
  String? _section;
  double _sinceKey = 0, _sinceDrop = 1e9, _pulse = 0, _pulseAmp = 0, _snare = 0, _barClock = 0;
  int _barsSinceKey = 0;

  /// How long a pulse of let-through takes to fade, seconds.
  static const pulseFade = 0.22;

  /// The longest a mosh goes without a key frame, whatever the record says.
  static const longest = 30.0;

  static const _calm = {'intro', 'outro', 'breakdown', 'break'};

  /// One frame, [t] the effect on (its knobs; off where it is not the datamosh).
  MoshDrive frame(ShowState st, RigTransform t) {
    if (!t.mosh) {
      _on = false;
      return (on: false, heal: 0, strength: 0, grain: 0, keys: _keys);
    }
    final m = st.master;
    final dt = st.dt.clamp(0.0, 0.25);
    if (!_on) {
      // Taken up from the picture as it is: no key frame wanted.
      _on = true;
      _sinceKey = 0;
      _barsSinceKey = 0;
      _bar = m.barIndex;
      _beat = m.beatIndex;
      _section = m.breakdown ? 'breakdown' : m.section;
    }
    final section = m.breakdown ? 'breakdown' : m.section;
    final calm = _calm.contains(section);
    final build = section == 'build' || (section == null && m.buildK > 0.05);

    // The moments: a bar (by the grid, else by the clock), a phrase, a beat, the
    // section turning, the drop.
    var bar = false, phrase = false, beat = false;
    if (m.barIndex != null) {
      if (m.barIndex != _bar) {
        bar = _bar != null;
        _bar = m.barIndex;
        phrase = bar && (m.phraseBar == 0);
      }
    } else {
      _barClock += dt;
      final barSeconds = 240 / (m.bpm ?? 120);
      if (_barClock >= barSeconds) {
        _barClock -= barSeconds;
        bar = true;
        if (_barsSinceKey % 8 == 7) phrase = true;
      }
    }
    if (m.beatIndex != null && m.beatIndex != _beat) {
      beat = _beat != null;
      _beat = m.beatIndex;
    }
    final turned = section != _section;
    final drop = turned && section == 'drop';
    if (turned) _section = section;
    if (drop) _sinceDrop = 0;
    _sinceDrop += dt;
    _sinceKey += dt;
    if (bar) _barsSinceKey++;

    // The knobs: melt holds the smears longer, keys lets the picture through more
    // often, grain is how blocky.
    final melt = t.melt.clamp(0.0, 1.0), keysK = t.keys.clamp(0.0, 1.0), grainK = t.grain.clamp(0.0, 1.0);
    final barSeconds = 240 / (m.bpm ?? 120);
    final heavy = _sinceDrop < 4 * barSeconds;

    // Where the record is: how healed between the pulses, how big a bar's pulse and a
    // phrase's, every how many bars a key frame, how far dragged, how blocky.
    final double base, barAmp, phraseAmp, strength;
    double grain;
    int keyBars;
    if (heavy) {
      base = 0.1;
      barAmp = 0.3;
      phraseAmp = 0.45;
      keyBars = 8;
      strength = 1.8;
      grain = 0.9;
    } else if (calm) {
      base = 0.2;
      barAmp = 0.12;
      phraseAmp = 0.42;
      keyBars = 8;
      strength = 0.7;
      grain = 0.25;
    } else if (build) {
      final k = m.buildK.clamp(0.0, 1.0);
      base = 0.2 - 0.1 * k;
      barAmp = 0.4 - 0.12 * k;
      phraseAmp = 0.4;
      keyBars = k < 0.5 ? 2 : 1;
      strength = 0.9 + 0.8 * k;
      grain = 0.45 + 0.45 * k;
    } else {
      base = 0.2;
      barAmp = 0.4;
      phraseAmp = 0.45;
      keyBars = 8;
      strength = m.section == 'drop' || m.section == 'chorus' ? 1.3 : 1.1;
      grain = m.section == 'drop' ? 0.75 : 0.6;
    }
    keyBars = math.max(1, (keyBars * (1.5 - keysK)).round());

    // A key frame: the drop, a breakdown coming (the melt starts whole), every so
    // many bars, each beat of a build's last bar, or too long without one.
    final lastBar = build && (m.dropBeatsAway ?? 99) <= 4;
    final key = drop ||
        (turned && calm) ||
        (bar && _barsSinceKey >= keyBars) ||
        (beat && lastBar) ||
        _sinceKey > longest;
    if (key) {
      _keys++;
      _sinceKey = 0;
      _barsSinceKey = 0;
      _pulse = 0;
    } else if (phrase) {
      _pulse = 1;
      _pulseAmp = phraseAmp;
    } else if (bar) {
      _pulse = 1;
      _pulseAmp = barAmp;
    }
    _pulse *= math.exp(-dt / pulseFade);
    final amp = _pulseAmp * (0.6 + 0.8 * keysK);
    final heal = (base * (1.6 - 1.2 * melt) + amp * _pulse).clamp(0.0, 0.9);

    // The snare: a burst of grain, fading.
    _snare = math.max(_snare * math.exp(-dt / 0.2), st['dyn.hit.snare'].clamp(0.0, 1.0));
    grain = (grain * (grainK / 0.7) + 0.25 * _snare).clamp(0.0, 1.0);
    return (on: true, heal: heal, strength: strength.clamp(0.0, 2.0), grain: grain, keys: _keys);
  }
}
