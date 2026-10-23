// MilkDrop's accents: what the booth adds to whatever preset is on, so the shipped
// presets — which know nothing of the beat grid, only the levels — move with the
// record. Sent as wo_fx_* and put on by the projectM patch (WetOwlVariables::Accent):
// the preset's own motion made bigger (a turning one turns harder, a zooming one
// zooms harder), a little of the booth's own on top, its light raised a little.
// Small numbers: MilkDrop feeds each frame into the next, so a push or a flash on
// every kick adds up.
//
// Never the same move all night: each phrase deals a way to land (on the kick, the
// snare, off the beat, the bar's first beat, every other bar) and one or two moves
// (in, out, a turn one way then the other, a warp, a flash), by the record and the
// phrase. As hard as the music (ShowDirector.drive): a quiet part gets none, a
// chorus a little on the bar, a drop the kick. A preset that already moves with the
// music by itself (MilkScores.react) gets less; the most reactive, none.
//
// And the record's shape, whatever the phrase dealt: through a build, in — faster as
// it climbs; on the drop, one burst — in, a flash and a whip round, settling.
import 'dart:math' as math;

import 'show_director.dart';
import 'show_state.dart';

/// When an accent lands.
enum MilkLand { kick, snare, off, bar, twoBars }

/// What it does.
enum MilkMove { push, pull, turn, warp, flash }

class MilkAccent {
  /// The accents all off: the preset as its author made it.
  static const none = {'wo_fx_amp': 0.0, 'wo_fx_zoom': 0.0, 'wo_fx_rot': 0.0, 'wo_fx_warp': 0.0, 'wo_fx_decay': 0.0, 'wo_fx_flash': 0.0};

  /// How much a preset nobody measured moves with the music by itself.
  static const unknownReact = 0.4;

  int _phrase = -1;
  MilkLand land = MilkLand.bar;
  Set<MilkMove> moves = const {MilkMove.push};

  double _w = 0, _push = 0;
  double? _dropAt, _awayWas;

  /// The accents for this frame of [m], by name: [react] how much the preset on
  /// moves with the music by itself (null: not known), [salt] the record's.
  Map<String, double> frame(ShowDeck m, double dt, {double? react, int salt = 0}) {
    final playing = m.playing && m.beatIndex != null;
    final drive = playing ? ShowDirector.drive(m) : 0.0;
    final r = (react ?? unknownReact).clamp(0.0, 1.0);
    // Eased, so a section's turn is not a jolt in the picture.
    _w += (drive * (1 - 0.9 * r) - _w) * math.min(1.0, dt * 1.5);
    if (!playing) {
      _dropAt = null;
      _push = 0;
      return _w < 0.005 ? none : _scaled(0, 0, 0);
    }
    final beats = m.beatIndex! + m.beatPhase;

    // A phrase: a way to land and a move or two, by the record and the phrase; the
    // harder the music, the more often on the kick.
    final phrase = (beats / 16).floor();
    if (phrase != _phrase) {
      _phrase = phrase;
      final d1 = _hash(salt, phrase, 7), d2 = _hash(salt, phrase, 11), d3 = _hash(salt, phrase, 13);
      land = _pick({
        MilkLand.kick: 0.3 + 3 * drive * drive,
        MilkLand.off: 0.2 + 1.2 * drive,
        MilkLand.snare: 0.5 + 1.0 * drive,
        MilkLand.bar: 2.5 - 1.5 * drive,
        MilkLand.twoBars: 1.6 - 1.2 * drive,
      }, d1);
      const w = {MilkMove.push: 1.0, MilkMove.pull: 0.6, MilkMove.turn: 1.0, MilkMove.warp: 0.8, MilkMove.flash: 0.5};
      final first = _pick(w, d2);
      final second = _pick({for (final e in w.entries) if (e.key != first) e.key: e.value}, d3);
      moves = drive > 0.6 && d3 > 0.35 ? {first, second} : {first};
    }

    // The landing: how much is left of it, and which way it turns.
    final ph = m.beatPhase;
    final inBar = (m.beatInBar ?? (m.beatIndex! % 4)) + ph;
    final bar = m.barIndex ?? (m.beatIndex! ~/ 4);
    final (e, side) = switch (land) {
      MilkLand.kick => (math.exp(-ph * 7), m.beatIndex!.isEven ? 1.0 : -1.0),
      MilkLand.off => (math.exp(-((ph + 0.5) % 1) * 7), m.beatIndex!.isEven ? 1.0 : -1.0),
      MilkLand.snare => ((m.beatInBar ?? m.beatIndex!) % 2 == 1 ? math.exp(-ph * 6) : 0.0, (m.beatIndex! ~/ 2).isEven ? 1.0 : -1.0),
      MilkLand.bar => (math.exp(-inBar * 2.2), bar.isEven ? 1.0 : -1.0),
      MilkLand.twoBars => (bar.isEven ? math.exp(-inBar * 1.2) : math.exp(-(inBar + 4) * 1.2), (bar ~/ 2).isEven ? 1.0 : -1.0),
    };

    // The build: in, faster as it climbs; let go of on the drop.
    final away = m.dropBeatsAway;
    if (away != null && away <= 0 && away > -2.5 && (_awayWas == null || _awayWas! > 0)) _dropAt = beats + away;
    _awayWas = away;
    if (_dropAt != null && (beats - _dropAt! > 16 || beats < _dropAt! - 1)) _dropAt = null;
    final burst = _dropAt == null ? 0.0 : math.exp(-(beats - _dropAt!) / 1.5);
    final building = !m.breakdown && (m.section == 'build' || (away != null && away > 0 && away < 32));
    final want = building ? math.pow(m.buildK.clamp(0.0, 1.0), 1.5).toDouble() : 0.0;
    _push = burst > 0.3 ? 0 : _push + (want - _push) * math.min(1.0, dt * (want > _push ? 1.0 : 4));
    final shape = 1 - 0.5 * r;

    final w = _w;
    var zoom = 0.0, rot = 0.0, warp = 0.0, flash = 0.0;
    for (final mv in moves) {
      switch (mv) {
        case MilkMove.push:
          zoom += 0.03 * w * e;
        case MilkMove.pull:
          zoom -= 0.025 * w * e;
        case MilkMove.turn:
          rot += 0.05 * side * w * e;
        case MilkMove.warp:
          warp += 1.6 * w * e;
        case MilkMove.flash:
          flash += 0.25 * w * e;
      }
    }
    zoom += shape * (0.02 * _push + 0.08 * burst);
    flash += shape * 0.35 * burst;
    rot += shape * 0.25 * burst * (_phrase.isEven ? 1 : -1);
    final amp = w * (0.3 + 0.9 * e) + shape * (0.4 * _push + 0.6 * burst);
    // Never longer trails: in MilkDrop's feedback they build up to a white screen
    // (the bench: a drop's worth of them washed a preset out in a few bars).
    return _scaled(amp, zoom, rot, warp: warp, flash: flash);
  }

  static Map<String, double> _scaled(double amp, double zoom, double rot, {double warp = 0, double flash = 0, double decay = 0}) => {
        'wo_fx_amp': amp,
        'wo_fx_zoom': zoom,
        'wo_fx_rot': rot,
        'wo_fx_warp': warp,
        'wo_fx_decay': decay,
        'wo_fx_flash': flash,
      };

  static T _pick<T>(Map<T, double> w, double d) {
    var at = d * w.values.fold(0.0, (s, x) => s + math.max(0.0, x));
    for (final e in w.entries) {
      final x = math.max(0.0, e.value);
      if (at < x) return e.key;
      at -= x;
    }
    return w.keys.last;
  }

  /// 0..1 from three numbers, the same every time.
  static double _hash(int a, int b, int c) {
    var h = 0x811c9dc5;
    for (final x in [a, b, c]) {
      h = ((h ^ (x & 0xffffffff)) * 0x01000193) & 0xffffffff;
      h ^= h >> 13;
    }
    return (h & 0xffffff) / 0x1000000;
  }
}
