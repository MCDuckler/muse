// The Siebenschläfer: a meme edit of real dormice, cut live to the record.
//
// What a phone editor's "edit" does to a clip, done to photographs of Glis glis — the
// edible dormouse, the Siebenschläfer, asleep seven months of the year — with the
// record's grid for a timeline. The record's form is the story:
//
//   sleep   a breakdown, a quiet intro or outro, a paused deck: a trail camera in an
//           attic at night (grey-green infrared, REC blinking on the beat, the date
//           the Siebenschläfertag) on a dormouse curled up asleep, breathing over
//           two bars, a Z rising on every beat, a cut every two bars, a fact typed
//           out now and then.
//   wake    the build, something coming: a hazard card, then a cut a bar, then a
//           beat, then a roll of eighths and sixteenths into the drop; the camera
//           creeps in on the eyes; a loading bar fills; the frame shakes harder,
//           reddens and closes in; the last seven beats count down SIEBEN … EINS.
//           Coming out of sleep, a "7 MONATE SPÄTER" card.
//   rage    the drop: an impact frame, a white flash, a storm of stickers; then a
//           cut every beat, a zoom punch and a squash on every kick, deep-fried and
//           bass-bulged, red laser eyes, speed lines, stickers and emoji thrown on
//           the snare, a glitch on the top end, Dutch angles, mirror flips, grids of
//           four and nine, letterbox bars, captions a word a beat; after eight bars
//           it breathes, a phrase of groove and a phrase of chaos by turns.
//   vibe    everything between: a cut a bar (two on a busy one), Ken Burns, a red
//           circle round the face now and then, a reaction sticker in a corner.
//
// Over that, by the phrase, the bits (show_meme_bits.dart): real footage locked to
// the beat, a sunburst dance, a crowd, "Nobody:", the expanding brain, a history
// lesson with the Romans' jars, a top seven, error boxes, stamps, speech bubbles, a
// cursor, a news bar, a reaction cam, a bouncing logo, a spectrum; "To Be Continued"
// or "WASTED" on the way into a breakdown; a "VS" screen while the DJ mixes.
//
// Every record is edited in one of five styles (show_meme_bank.dart: deep-fried,
// phonk, vaporwave, clean, 2009), picked from its id, so a set is not one edit.
// Every choice — which photo, which way round, which framing, which bit — is hashed
// from the record and the cut's number, so a record plays the same edit twice and a
// seek lands on the same frame. What reacts (punches, shakes, flashes, stickers)
// reads the dynamics, dyn.*: the kick's hit, the snare's, the bass against its own
// range.
//
// The photographs, the cut-outs, the clip and the captions are a bank in
// assets/show/<bank>/ (bank.json; who took the pictures, and under which licence,
// in CREDITS.md there). The picture is drawn at the stage's working size and
// finished by shaders/show/sim/meme_fx.frag; the words go over the whole stage at
// the screen's own size ([paintOver]), so they stay sharp.
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/show_state.dart';
import '../mag.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_meme_bank.dart';
import 'show_meme_bits.dart';
import 'show_meme_type.dart';
import 'show_sims.dart';

export 'show_meme_bank.dart';

/// How one cut goes to the next: a hard cut, a dissolve, a push across, a zoom
/// through. Outside a drop the edit mostly dissolves.
enum MemeTrans { cut, fade, push, zoom, iris, wipe }

/// One cut of the edit: the photograph and how it is shown.
class MemeCut {
  const MemeCut({
    required this.number,
    required this.photo,
    this.flip = false,
    this.tilt = 0,
    this.framing = 0,
    this.grid = 1,
    this.symmetry = false,
    this.invert = false,
    this.spin = 0,
    this.laser = false,
    this.circle = false,
    this.crunch = false,
    this.whip = 0,
    this.trans = MemeTrans.cut,
  });
  final int number;

  /// How it comes in from the cut before.
  final MemeTrans trans;
  final MemePhoto photo;
  final bool flip, symmetry, invert, laser, circle, crunch;

  /// Radians; a spin is ±1 (a quarter turn in from that side), a whip ±1 (a pan in).
  final double tilt, spin, whip;

  /// 0 the whole picture, 1 the face, 2 the eyes.
  final int framing;

  /// 1, 2 or 3: the picture tiled that many times each way.
  final int grid;
}

/// Where the edit is, read off a frame: pure, for a test.
class MemeClock {
  const MemeClock._();

  /// The mood of the record now. [sinceDrop] is the beats since the last drop
  /// landed (the edit keeps it: the deck forgets a drop two beats after).
  static MemeMood mood(ShowDeck m, {double? sinceDrop}) {
    if (!m.playing) return MemeMood.sleep;
    final away = m.dropBeatsAway;
    final s = m.section;
    if (sinceDrop != null && sinceDrop >= 0 && sinceDrop < 64) return MemeMood.rage;
    if (away != null && away > 0 && away <= 16) return MemeMood.wake;
    if (s == 'build' || m.buildK > 0.35) return MemeMood.wake;
    if (m.breakdown || s == 'breakdown' || s == 'break') return MemeMood.sleep;
    if (s == 'drop') return MemeMood.rage;
    if (m.energy < 0.3 && (s == null || s == 'intro' || s == 'outro')) return MemeMood.sleep;
    // A record the analysis found no drops in still gets its rage where it is loudest.
    if (away == null && sinceDrop == null && m.energy > 0.85 && (s == null || s == 'chorus')) return MemeMood.rage;
    return MemeMood.vibe;
  }

  /// How hot the rage is, 0..1: all of it for the first eight bars after the drop,
  /// then a phrase of groove and a phrase of chaos by turns, so a long drop breathes.
  static double heat(ShowDeck m, {double? sinceDrop}) {
    if (sinceDrop != null && sinceDrop >= 0 && sinceDrop < 32) return 1;
    final phrase = ((m.barIndex ?? 0) / 8).floor();
    return phrase.isEven ? 0.55 : 1.0;
  }

  /// How near the drop a build is, 0..1.
  static double wakeK(ShowDeck m) {
    final away = m.dropBeatsAway;
    if (away != null && away > 0) return (1 - away / 24).clamp(0.0, 1.0);
    return m.buildK.clamp(0.0, 1.0);
  }

  /// How a record's breakdowns look: 0 a trail camera at night, 1 a warm nest, 2
  /// moonlight. Half the records get the camera.
  static int sleepSkin(int salt) {
    final h = memeHash(salt, 5, 83);
    return h < 0.5 ? 0 : (h < 0.75 ? 1 : 2);
  }

  /// The style a record is edited in, from its id.
  static MemeStyle style(int salt) => MemeStyle.values[(memeHash(salt, 3, 71) * MemeStyle.values.length).floor() % MemeStyle.values.length];

  /// How long a cut is, in beats.
  static double cutBeats(MemeMood mood, ShowDeck m) {
    switch (mood) {
      case MemeMood.sleep:
        return 8;
      case MemeMood.vibe:
        return m.energy > 0.55 ? 2 : 4;
      case MemeMood.wake:
        final away = m.dropBeatsAway;
        if (away != null && away > 0) {
          if (away <= 2) return 0.25;
          if (away <= 4) return 0.5;
          if (away <= 8) return 1;
          if (away <= 16) return 2;
          return 4;
        }
        final k = m.buildK;
        return k > 0.9 ? 0.5 : (k > 0.7 ? 1 : (k > 0.45 ? 2 : 4));
      case MemeMood.rage:
        // The last beat of every fourth bar: a roll of eighths.
        final bar = m.barIndex ?? 0;
        return (m.beatInBar == 3 && bar % 4 == 3) ? 0.5 : 1;
    }
  }

  /// The cut numbered [n] of [len] beats in [mood], from [bank], for the record
  /// salted [salt]. Short cuts (a roll) flicker between two photographs a beat.
  static MemeCut cut(MemeBank bank, MemeMood mood, int n, double len, int salt, ShowDeck m, {double? sinceDrop}) {
    final hot = mood == MemeMood.rage ? heat(m, sinceDrop: sinceDrop) : 0.0;
    final pool = bank.pools[mood] ?? bank.photos;
    final lenCode = (len * 8).round();
    double r(int k) => memeHash(salt % 9973, n * 13 + k, lenCode + mood.index * 101);
    MemePhoto photoAt(int i) {
      final h = memeHash(salt % 9973 + 0.5, i, lenCode + mood.index * 101);
      return pool[(h * pool.length).floor() % pool.length];
    }

    MemePhoto photo;
    if (len < 1) {
      // A roll: two photographs, swapped every cut, a new pair each beat.
      final beat = (n * len).floor();
      final a = photoAt(beat * 2), b0 = photoAt(beat * 2 + 1);
      final b = identical(a, b0) ? pool[(pool.indexOf(a) + 1) % pool.length] : b0;
      photo = n.isEven ? a : b;
    } else {
      photo = photoAt(n);
      final prev = photoAt(n - 1);
      if (identical(photo, prev) && pool.length > 1) photo = pool[(pool.indexOf(photo) + 1) % pool.length];
    }

    final fresh = sinceDrop != null && sinceDrop >= 0 && sinceDrop < 4;
    switch (mood) {
      case MemeMood.sleep:
        return MemeCut(number: n, photo: photo, flip: r(1) < 0.3, framing: r(2) < 0.5 ? 0 : 1, trans: r(3) < 0.75 ? MemeTrans.fade : MemeTrans.iris);
      case MemeMood.wake:
        return MemeCut(
          number: n,
          photo: photo,
          flip: len < 1 ? n.isOdd : r(1) < 0.25,
          framing: 2,
          circle: len >= 2 && r(3) < 0.08,
          crunch: len >= 1 && r(4) < 0.08,
          trans: len >= 2 ? MemeTrans.fade : MemeTrans.cut,
        );
      case MemeMood.vibe:
        final f = r(2);
        final t = r(10);
        return MemeCut(
          number: n,
          photo: photo,
          flip: r(1) < 0.35,
          tilt: r(3) < 0.3 ? (r(4) - 0.5) * 0.08 : 0,
          framing: f < 0.4 ? 0 : (f < 0.85 ? 1 : 2),
          circle: r(5) < 0.1,
          grid: r(6) < 0.03 ? 2 : 1,
          laser: m.energy > 0.7 && r(7) < 0.05,
          whip: r(8) < 0.12 ? (r(9) < 0.5 ? -1 : 1) : 0,
          trans: t < 0.35
              ? MemeTrans.fade
              : (t < 0.5 ? MemeTrans.push : (t < 0.63 ? MemeTrans.zoom : (t < 0.76 ? MemeTrans.iris : (t < 0.88 ? MemeTrans.wipe : MemeTrans.cut)))),
        );
      case MemeMood.rage:
        final f = r(2);
        final g = r(6);
        return MemeCut(
          number: n,
          photo: photo,
          flip: r(1) < 0.5,
          tilt: r(3) < 0.45 * hot ? (r(4) < 0.5 ? -1 : 1) * (0.05 + 0.1 * r(5)) : 0,
          framing: f < 0.25 ? 0 : (f < 0.7 ? 1 : 2),
          grid: fresh ? 1 : (g < 0.05 * hot ? 2 : (g < 0.08 * hot ? 3 : 1)),
          symmetry: !fresh && r(7) < 0.06 * hot,
          spin: r(9) < 0.1 * hot ? (r(10) < 0.5 ? -1 : 1) : 0,
          laser: fresh || r(11) < 0.12 * hot,
          crunch: !fresh && r(12) < 0.06 * hot,
          trans: r(13) < 0.15 ? MemeTrans.zoom : MemeTrans.cut,
        );
    }
  }
}

class _Thrown {
  _Thrown(this.what, {required this.x, required this.y, required this.size, required this.born, required this.life, this.vx = 0, this.vy = 0, this.rot = 0, this.spin = 0});
  final Object what; // a MemeSticker, or an emoji's string
  double x, y, vx, vy, rot;
  final double size, born, life, spin;
}

class _Z {
  _Z(this.x, this.y, this.born);
  final double x, y, born;
}

/// A photograph as it sat on the frame: enough to draw it again, going out.
class _Placed {
  const _Placed(this.photo, this.zoom, this.focus, this.sx, this.sy, this.rot);
  final MemePhoto photo;
  final double zoom, sx, sy, rot;
  final Offset focus;
}

/// The edit, as a simulation layer (show_sims.dart): its state is the last cut,
/// the drop it remembers, the bits on, and what it has thrown on the screen.
class MemeEdit implements SimLayer, SimOverlay {
  MemeEdit(this.kind) : bank = MemeBank.of(kind) {
    // A style forced from outside, for a look at one: WETOWL_MEME_STYLE=phonk.
    try {
      final forced = Platform.environment['WETOWL_MEME_STYLE'];
      if (forced != null) _forcedStyle = MemeStyle.values.where((s) => s.name == forced).firstOrNull;
      _forcedBit = Platform.environment['WETOWL_MEME_BIT'];
      _forcedSkin = int.tryParse(Platform.environment['WETOWL_MEME_SLEEP'] ?? '');
    } catch (_) {}
  }

  @override
  final String kind;
  final MemeBank bank;
  final type = MemeType();
  MemeStyle? _forcedStyle;

  /// A bit forced on every phrase, for a look at it: WETOWL_MEME_BIT=history.
  String? _forcedBit;

  /// A sleep look forced from outside: WETOWL_MEME_SLEEP=0|1|2.
  int? _forcedSkin;
  int get _skin => _forcedSkin ?? MemeClock.sleepSkin(_salt);

  /// The last few looks, so the next is another.
  final _recent = <String>[];

  ui.FragmentShader? _fx;
  ui.Image? _out;
  final _rng = math.Random(27);
  double _t = 0;

  // The record, as last read.
  ShowState? _st;
  MemeMood _mood = MemeMood.sleep;
  MemeLook _look = MemeLook.of(MemeStyle.fried);
  double _beats = 0, _spb = 0.5;
  int _salt = 0;
  double? _dropAt, _awayWas;
  String? _sectionWas;
  double? get _since => _dropAt == null ? null : _beats - _dropAt!;

  // The cut on, and the photograph last drawn (held while the next decodes).
  MemeCut? _cut;
  (MemeMood, int, double)? _cutKey;
  MemePhoto? _shownPhoto;

  /// How the last frame placed its photograph, for the transition out of it.
  _Placed? _placed, _leaving;
  double _cutBegan = 0;
  Offset _faceOnScreen = const Offset(0.5, 0.4);

  // Reactions.
  double _snareWas = 0, _kickWas = 0, _night = 1, _invertUntil = 0, _glitch = 0;
  int _beatWas = -1, _shakeStep = -1, _snares = 0, _phraseWas = -1;
  double _jx = 0, _jy = 0, _jr = 0;
  Offset _shake = Offset.zero;
  final _stickers = <_Thrown>[];
  final _emoji = <_Thrown>[];
  final _zs = <_Z>[];
  double? _cardAt;
  String _cardText = '';
  MemeMood? _moodWas;
  double? _stormedFor;
  List<String> _ahead = const [];

  // The bits.
  MemeBit? _takeover;
  final _overlays = <MemeBit>[];
  MemeFrame? _frame;

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    bank.tick();
    if (!bank.ready) return null;
    final program = p.sims['meme_fx'];
    if (program == null) return null;
    final fx = _fx ??= program.fragmentShader();
    _t += dt;
    _st = st;
    final m = st.master;
    final f = st.flat;
    final playing = m.playing && m.beatIndex != null;
    final bpm = (m.bpm ?? 0) > 1 ? m.bpm! : 120.0;
    _spb = 60 / bpm;
    _beats = playing ? m.beatIndex! + m.beatPhase : _t / _spb;
    _salt = m.trackId ?? 0;
    _look = MemeLook.of(_forcedStyle ?? MemeClock.style(_salt));

    // The drop, remembered past the deck's two beats.
    final away = m.dropBeatsAway;
    if (playing) {
      final was = _awayWas;
      if (away != null && away <= 0 && away > -2.5 && (was == null || was > 0)) _dropAt = _beats + away;
      if (m.section == 'drop' && _sectionWas != 'drop' && (_dropAt == null || _beats - _dropAt! > 8)) _dropAt = _beats;
      final since = _since;
      if (since != null && (since < -1 || since > 64)) _dropAt = null;
    }
    _awayWas = away;
    _sectionWas = m.section;
    final since = _since;
    final mood = playing ? MemeClock.mood(m, sinceDrop: since) : MemeMood.sleep;
    _mood = mood;

    // Out of sleep, not into a drop: the card.
    if (_moodWas == MemeMood.sleep && (mood == MemeMood.wake || mood == MemeMood.vibe) && playing) {
      final last = _cardAt;
      if ((last == null || _beats - last > 32 || _beats < last) && memeHash(_salt, _beats.floor(), 19) < 0.55) {
        _cardAt = _beats;
        final cards = bank.lines('cards');
        _cardText = cards.isEmpty ? '7 monate später' : cards[(memeHash(_salt, _beats.floor(), 5) * cards.length).floor() % cards.length];
      }
    }

    // The cut.
    final len = MemeClock.cutBeats(mood, m);
    final n = (_beats / len).floor();
    final cutT = _beats / len - n;
    final cutSec = cutT * len * _spb;
    final key = (mood, n, len);
    if (_cutKey != key || _cut == null) {
      _cutKey = key;
      _leaving = _placed;
      _cutBegan = _t;
      _cut = MemeClock.cut(bank, mood, n, len, _salt, m, sinceDrop: since);
      _ahead = [for (var k = 1; k <= 3; k++) MemeClock.cut(bank, mood, n + k, len, _salt, m, sinceDrop: since).photo.file];
    }
    for (final file in _ahead) {
      bank.want(file);
    }
    if (mood == MemeMood.wake || mood == MemeMood.rage) {
      for (final st in bank.stickers) {
        if (st.set != 'sleep') bank.want(st.file);
      }
    }
    final cut = _cut!;

    // The dynamics.
    final kick = (f['dyn.hit.kick'] ?? 0).clamp(0.0, 1.0);
    final snare = (f['dyn.hit.snare'] ?? 0).clamp(0.0, 1.0);
    final top = (f['dyn.hit.top'] ?? 0).clamp(0.0, 1.0);
    final low = (f['dyn.band.low'] ?? 0).clamp(0.0, 1.0);
    final mid = (f['dyn.band.mid'] ?? 0).clamp(0.0, 1.0);
    final high = (f['dyn.band.high'] ?? 0).clamp(0.0, 1.0);
    final beatDecay = f['dyn.beat.decay'] ?? 0;
    final downbeat = f['dyn.downbeat'] ?? 0;
    final barSaw = f['dyn.bar.saw'] ?? 0;
    final wakeK = MemeClock.wakeK(m);
    final hot = mood == MemeMood.rage ? MemeClock.heat(m, sinceDrop: since) : 0.0;
    final busy = (f['dyn.energy'] ?? m.energy).clamp(0.0, 1.0);
    final snareEdge = snare > 0.45 && _snareWas < 0.25;
    final kickEdge = kick > 0.5 && _kickWas < 0.3;
    _snareWas = snare;
    _kickWas = kick;
    final beatNow = _beats.floor();
    final newBeat = beatNow != _beatWas;
    _beatWas = beatNow;

    // The shake: a new jolt thirty times a second, as a phone editor's.
    final step = (_t * 30).floor();
    if (step != _shakeStep) {
      _shakeStep = step;
      _jx = _rng.nextDouble() * 2 - 1;
      _jy = _rng.nextDouble() * 2 - 1;
      _jr = _rng.nextDouble() * 2 - 1;
    }
    final amp = switch (mood) {
      MemeMood.sleep => 0.0,
      MemeMood.wake => 0.002 + 0.022 * wakeK * wakeK + 0.01 * kick,
      MemeMood.vibe => (0.004 + 0.008 * busy) * kick,
      MemeMood.rage => 0.003 + (0.024 * kick * (0.4 + 0.6 * low) + 0.016 * snare) * (0.5 + 0.5 * hot),
    } * (_look.style == MemeStyle.phonk ? 1.5 : 1);
    _shake = Offset(_jx, _jy) * amp;

    // The photograph and how it sits.
    var img = bank.image(cut.photo.file);
    var photo = cut.photo;
    if (img == null && _shownPhoto != null) {
      img = bank.image(_shownPhoto!.file);
      photo = _shownPhoto!;
    }
    if (img != null) _shownPhoto = photo;

    final fw = w.toDouble(), fh = h.toDouble();
    double zoomFor(int framing) {
      final faceOnFrame = photo.faceR * photo.h * math.max(fw / photo.w, fh / photo.h) / fh;
      return switch (framing) {
        0 => 1.0,
        1 => (0.32 / faceOnFrame).clamp(1.0, 3.2),
        _ => (0.58 / faceOnFrame).clamp(1.4, 4.0),
      };
    }

    Offset focusFor(int framing) => switch (framing) {
          0 => Offset(0.5 + (photo.face.dx - 0.5) * 0.6, 0.5 + (photo.face.dy - 0.5) * 0.6),
          1 => photo.face,
          _ => photo.eyesMiddle,
        };

    var zoom = zoomFor(cut.framing);
    var focus = focusFor(cut.framing);
    var sx = cut.flip ? -1.0 : 1.0, sy = 1.0;
    var rot = cut.tilt;
    switch (mood) {
      case MemeMood.sleep:
        zoom *= (1 + 0.1 * cutT) * (1 + 0.022 * math.sin(2 * math.pi * _beats / 8));
      case MemeMood.wake:
        // The camera creeps in on the eyes as the drop nears.
        final from = zoomFor(1), to = zoomFor(2) * 1.15;
        zoom = (from + (to - from) * wakeK) * (1 + 0.04 * cutT) * (1 + 0.05 * beatDecay + 0.06 * kick);
        focus = Offset.lerp(photo.face, photo.eyesMiddle, wakeK)!;
      case MemeMood.vibe:
        zoom *= (1 + 0.06 * cutT) * (1 + (0.04 + 0.08 * busy) * kick);
      case MemeMood.rage:
        // The velocity edit: each cut snaps in and eases out; the kick punches.
        zoom *= (1 + 0.3 * math.exp(-cutSec * 9)) * (1 + (0.08 + 0.08 * hot) * kick);
        sx *= 1 + 0.08 * kick;
        sy *= 1 - 0.07 * kick;
    }
    final shakeRot = _jr * amp * 1.2;
    var spinRot = 0.0;
    if (cut.spin != 0) {
      final k = (cutSec / 0.18).clamp(0.0, 1.0);
      spinRot = cut.spin * (math.pi / 2) * math.pow(1 - k, 3).toDouble();
    }
    final whipShift = cut.whip == 0 ? 0.0 : cut.whip * fw * 0.35 * math.pow(1 - (cutSec / 0.14).clamp(0.0, 1.0), 2).toDouble();
    rot += shakeRot;

    // The picture's own box: the whole frame, or the 4:3 of 2009.
    final boxW = _look.pillarbox ? fh * 4 / 3 : fw;
    final boxX = (fw - boxW) / 2;

    MemeShot shotFor(double w, double h) => MemeShot(photo, w, h,
        zoom: zoom, focus: focus, rot: rot + spinRot, coverRot: rot, sx: sx, sy: sy, shift: Offset(_shake.dx * w + whipShift * (w / fw), _shake.dy * h));

    final full = shotFor(boxW, fh);
    if (cut.grid == 1) {
      final face = full.map(photo.face);
      _faceOnScreen = Offset(((face.dx + boxX) / fw).clamp(0.08, 0.92), (face.dy / fh).clamp(0.08, 0.92));
    } else {
      _faceOnScreen = const Offset(0.5, 0.45);
    }

    // What the bits are handed.
    final fr = _frame = MemeFrame(
      bank: bank,
      type: type,
      deck: m,
      beats: _beats,
      spb: _spb,
      t: _t,
      w: fw,
      h: fh,
      mood: mood,
      look: _look,
      kick: kick,
      snare: snare,
      top: top,
      low: low,
      mid: mid,
      high: high,
      beatDecay: beatDecay,
      downbeat: downbeat,
      barSaw: barSaw,
      busy: busy,
      hot: hot,
      hue: f['palette.primary.h'] ?? 0,
      salt: _salt,
      shake: _shake,
      face: _faceOnScreen,
      newBeat: newBeat,
      snareEdge: snareEdge,
      kickEdge: kickEdge,
    );
    _schedule(fr, m, mood, since, playing, wakeK);
    _moodWas = mood;
    final takeover = _takeover;

    // Spawns: what the beat and the hits throw on.
    if (mood == MemeMood.sleep && newBeat) {
      _zs.add(_Z(_faceOnScreen.dx + 0.04, _faceOnScreen.dy - 0.06, _t));
    }
    if (mood != MemeMood.sleep || takeover != null) _zs.clear();
    _zs.removeWhere((z) => _t - z.born > 2.6);
    if (since != null && since >= 0 && since < 0.5 && _stormedFor != _dropAt) {
      _stormedFor = _dropAt;
      _storm();
    }
    final emojiK = _look.emoji;
    if (mood == MemeMood.rage && snareEdge) {
      _snares++;
      if (_stickers.length < 3 && takeover == null && _rng.nextDouble() < 0.15 + 0.25 * hot) _throwSticker();
      if (_snares % 4 == 0 && _emoji.length < 3 * emojiK) _throwEmoji();
      if (_rng.nextDouble() < 0.08 * hot) _invertUntil = _t + 0.05;
    }
    if (mood == MemeMood.rage && newBeat && (m.beatInBar ?? 1) == 0 && ((m.barIndex ?? 0) % 8 == 0)) {
      for (var i = 0; i < 2 * emojiK; i++) {
        _throwEmoji();
      }
    }
    if (mood == MemeMood.vibe && newBeat && takeover == null && (m.beatInBar ?? 1) == 0 && (m.barIndex ?? 0) % 4 == 2 && _rng.nextDouble() < 0.5) {
      _throwSticker(corner: true);
    }
    if (mood == MemeMood.vibe && kickEdge && _rng.nextDouble() < 0.02 * emojiK && _emoji.length < 2) _throwEmoji();
    _stickers.removeWhere((s) => _t - s.born > s.life);
    _emoji.removeWhere((s) => _t - s.born > s.life);
    for (final s in _stickers) {
      if (s.vx != 0 || s.vy != 0) {
        s.x += s.vx * dt;
        s.y += s.vy * dt;
        s.vy += 0.5 * dt; // what is flung falls
      }
      s.rot += s.spin * dt;
    }

    // The picture.
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    c.drawRect(Rect.fromLTWH(0, 0, fw, fh), Paint()..color = Colors.black);
    // A look fades in over the cut and out again into it (a freeze frame is a
    // freeze: it cuts).
    var lookK = 1.0;
    if (takeover != null && takeover is! FreezeBit) {
      final inSec = takeover.beatsIn(fr) * _spb, outSec = (takeover.bars * 4 - takeover.beatsIn(fr)) * _spb;
      lookK = Curves.easeInOut.transform((math.min(inSec, outSec) / 0.45).clamp(0.0, 1.0));
    }
    if (takeover != null && lookK >= 1) {
      takeover.draw(c, fr);
    } else if (img != null) {
      c.save();
      if (_look.pillarbox) {
        c.clipRect(Rect.fromLTWH(boxX, 0, boxW, fh));
        c.translate(boxX, 0);
      }
      if (cut.grid > 1) {
        final g = cut.grid;
        final cw = boxW / g, ch = fh / g;
        for (var i = 0; i < g; i++) {
          for (var j = 0; j < g; j++) {
            c.save();
            c.clipRect(Rect.fromLTWH(i * cw, j * ch, cw, ch));
            c.translate(i * cw, j * ch);
            final flipCell = (i + j).isOdd;
            MemeShot(photo, cw, ch, zoom: zoom, focus: focus, rot: rot, coverRot: rot, sx: flipCell ? -sx : sx, sy: sy).draw(c, img);
            c.restore();
          }
        }
      } else if (cut.symmetry) {
        c.save();
        c.clipRect(Rect.fromLTWH(0, 0, boxW / 2, fh));
        full.draw(c, img);
        c.restore();
        c.save();
        c.translate(boxW, 0);
        c.scale(-1, 1);
        c.clipRect(Rect.fromLTWH(0, 0, boxW / 2, fh));
        full.draw(c, img);
        c.restore();
      } else {
        _drawWithTransition(c, cut, full, img, boxW, fh);
      }
      _placed = _Placed(photo, zoom, focus, sx, sy, rot + spinRot);
      if (cut.grid == 1 && !cut.symmetry) {
        if (cut.laser && (mood == MemeMood.rage || mood == MemeMood.vibe)) _lasers(c, full, 0.75 + 0.5 * kick);
        if (cut.circle) _circle(c, full, cutT * len, boxW, fh);
      }
      c.restore();
      if (takeover != null) {
        c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, lookK));
        takeover.draw(c, fr);
        c.restore();
      }
    } else if (takeover != null) {
      takeover.draw(c, fr);
    }
    if (mood == MemeMood.rage && takeover == null) {
      final drop = since != null && since >= 0 && since < 1;
      final k = drop ? 1.0 : (hot > 0.8 ? 0.6 * math.max(0.0, kick - 0.4) : 0.0);
      if (k > 0.08) _speedLines(c, fw, fh, k.clamp(0.0, 1.0), step);
    }
    if (mood == MemeMood.wake && takeover == null) _peeker(c, fw, fh, wakeK, kick);
    if (takeover == null || takeover is FreezeBit) _drawStickers(c, fw, fh, kick);
    if (mood == MemeMood.rage && takeover is! FreezeBit) {
      final k = since != null && since >= 0 ? (since * 4).clamp(0.0, 1.0) : 1.0;
      final bar = fh * 0.085 * Curves.easeOutBack.transform(k);
      c.drawRect(Rect.fromLTWH(0, 0, fw, bar), Paint()..color = Colors.black);
      c.drawRect(Rect.fromLTWH(0, fh - bar, fw, bar), Paint()..color = Colors.black);
    }
    final pic = r.endRecording();
    final base = pic.toImageSync(w, h);
    pic.dispose();

    // The finish.
    var fry = 0.0, split = 0.0, blur = 0.0, pixel = 0.0, impact = 0.0, flash = 0.0, tint = 0.0, vignette = 0.12, bulge = 0.0;
    var tintHue = _look.style == MemeStyle.vapor ? 0.85 : 0.0; // red, or the vaporwave's pink
    var nightTarget = 0.0;
    var glitchTarget = 0.0;
    var smear = Offset.zero;
    switch (mood) {
      case MemeMood.sleep:
        final skin = _skin;
        nightTarget = takeover == null && skin == 0 ? 1 : 0;
        vignette = 0.55;
        if (takeover == null && skin != 0) {
          // The nest is amber and close; moonlight blue and cool.
          tintHue = skin == 1 ? 0.08 : 0.62;
          tint = skin == 1 ? 0.32 : 0.42;
          vignette = 0.7;
        }
      case MemeMood.wake:
        fry = 0.04 + 0.22 * wakeK * wakeK;
        split = 0.001 + 0.005 * wakeK + 0.008 * snare;
        blur = len >= 1 ? 0.08 * math.exp(-cutSec * 14) : 0.0;
        tint = (0.04 + 0.26 * wakeK) * (0.55 + 0.45 * beatDecay);
        vignette = 0.25 + 0.4 * wakeK;
        bulge = 0.12 * kick * wakeK;
        if (away != null && away > 0 && away <= 4) flash = 0.25 * beatDecay;
      case MemeMood.vibe:
        fry = 0.03 + 0.05 * busy + 0.06 * kick;
        split = 0.001 + 0.006 * snare;
        blur = cut.trans == MemeTrans.cut ? 0.06 * math.exp(-cutSec * 14) : 0.0;
        vignette = 0.18;
        bulge = 0.08 * kick * busy;
      case MemeMood.rage:
        final fresh = since != null && since >= 0 && since < 16 ? 1.0 : 0.0;
        fry = 0.1 + 0.14 * hot + 0.2 * kick + 0.12 * fresh;
        split = 0.002 + 0.014 * snare + 0.005 * top;
        blur = 0.12 * math.exp(-cutSec * 12) + 0.03 * kick;
        bulge = 0.4 * kick * (0.5 + 0.5 * low);
        vignette = 0.2;
        flash = 0.25 * downbeat;
        glitchTarget = hot > 0.8 ? 0.5 * top + 0.15 * snare : 0.2 * top;
    }
    if (since != null && since >= 0 && since < 1) {
      if (since < 0.25) {
        impact = 1;
      } else {
        flash = math.max(flash, 1 - (since - 0.25) / 0.75);
      }
    }
    if (takeover != null && takeover is! FreezeBit && takeover is! ClipBit) {
      // A composed picture is not fried as hard, or its white goes orange.
      fry *= 0.35;
      bulge *= 0.4;
    }
    if (takeover is FreezeBit) {
      fry = 0;
      bulge = 0;
      split = 0;
      glitchTarget = 0;
    }
    if (cut.crunch && takeover == null) pixel = math.max(0.0, 30.0 * (1 - cutT * len * 3)) * (fw / 1280);
    if (cut.whip != 0 && takeover == null) smear = Offset(cut.whip * 0.09 * math.exp(-cutSec * 16), 0);
    if (nightTarget < _night && mood != MemeMood.sleep && since != null && since < 1) {
      _night = 0;
    } else {
      _night += (nightTarget - _night) * (1 - math.exp(-dt / 0.15));
    }
    _glitch = glitchTarget > _glitch ? glitchTarget : _glitch * math.exp(-dt / 0.08);
    final invert = (cut.invert || _t < _invertUntil) ? 1.0 : 0.0;
    flash = math.max(flash, st.macros.hit * 0.8);
    final splitAngle = _jr * math.pi;
    final blurAt = Offset(0.5 + _shake.dx, 0.5 + _shake.dy);
    // The style's grade: on the whole picture, off at night.
    final day = (1 - _night).clamp(0.0, 1.0);
    final look = _look;
    fry *= look.fry;
    final asleep = mood == MemeMood.sleep ? 0.3 : 1.0;
    final mono = look.mono * day * asleep * (takeover is FreezeBit ? 0 : 1);
    final pastel = look.pastel * day * asleep * (takeover is FreezeBit ? 0 : 1);
    final scan = look.scan * (mood == MemeMood.sleep ? 0.3 : 1) + (look.style == MemeStyle.phonk ? 0.3 * snare : 0);
    pixel = math.max(pixel, look.pixel * day * (fw / 1280));

    var i = 0;
    void set(double v) => fx.setFloat(i++, v);
    set(fw);
    set(fh);
    set(_t);
    set(fry.clamp(0.0, 1.0));
    set(split);
    set(splitAngle);
    set(blur);
    set(blurAt.dx);
    set(blurAt.dy);
    set(smear.dx);
    set(smear.dy);
    set(pixel);
    set(impact);
    set(invert);
    set(_night.clamp(0.0, 1.0));
    set(flash.clamp(0.0, 1.0));
    set(tintHue);
    set(tint.clamp(0.0, 1.0));
    set(vignette);
    set(bulge.clamp(0.0, 1.0));
    set(mono.clamp(0.0, 1.0));
    set(pastel.clamp(0.0, 1.0));
    set(scan.clamp(0.0, 1.0));
    set(_glitch.clamp(0.0, 1.0));
    fx.setImageSampler(0, base);
    final r2 = ui.PictureRecorder();
    Canvas(r2).drawRect(Rect.fromLTWH(0, 0, fw, fh), Paint()..shader = fx);
    final pic2 = r2.endRecording();
    final out = pic2.toImageSync(w, h);
    pic2.dispose();
    base.dispose();
    _out?.dispose();
    _out = out;
    return out;
  }

  /// The cut's photograph, with the one before going out under it for the first
  /// moments of the cut: a dissolve, a push, a zoom through, or nothing.
  void _drawWithTransition(Canvas c, MemeCut cut, MemeShot full, ui.Image img, double w, double h) {
    final leaving = _leaving;
    final secs = switch (_mood) {
      MemeMood.sleep => 1.2,
      MemeMood.vibe => 0.35,
      MemeMood.wake => 0.2,
      MemeMood.rage => 0.12,
    };
    final age = _t - _cutBegan;
    final k = (age / secs).clamp(0.0, 1.0);
    final prevImg = leaving == null || cut.trans == MemeTrans.cut || k >= 1 || identical(leaving.photo, cut.photo) ? null : bank.image(leaving.photo.file);
    if (prevImg == null) {
      full.draw(c, img);
      return;
    }
    final prev = MemeShot(leaving!.photo, w, h, zoom: leaving.zoom, focus: leaving.focus, rot: leaving.rot, coverRot: leaving.rot, sx: leaving.sx, sy: leaving.sy);
    final e = Curves.easeInOut.transform(k);
    switch (cut.trans) {
      case MemeTrans.fade:
        prev.draw(c, prevImg);
        c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, e));
        full.draw(c, img);
        c.restore();
      case MemeTrans.push:
        final dir = cut.number.isEven ? 1.0 : -1.0;
        c.save();
        c.translate(-dir * w * e, 0);
        prev.draw(c, prevImg);
        c.restore();
        c.save();
        c.translate(dir * w * (1 - e), 0);
        full.draw(c, img);
        c.restore();
      case MemeTrans.zoom:
        prev.draw(c, prevImg);
        c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, e));
        c.translate(w / 2, h / 2);
        c.scale(1 + 0.3 * (1 - e));
        c.translate(-w / 2, -h / 2);
        full.draw(c, img);
        c.restore();
      case MemeTrans.iris:
        // A circle opening from the new face.
        prev.draw(c, prevImg);
        final at = full.map(cut.photo.face);
        final far = math.sqrt(w * w + h * h);
        c.save();
        c.clipPath(Path()..addOval(Rect.fromCircle(center: at, radius: far * e)));
        full.draw(c, img);
        c.restore();
      case MemeTrans.wipe:
        // A soft-edged diagonal wipe, the way the cut alternates.
        prev.draw(c, prevImg);
        final dir = cut.number.isEven ? 1.0 : -1.0;
        final x = (dir > 0 ? -0.3 + 1.6 * e : 1.3 - 1.6 * e) * w;
        c.saveLayer(null, Paint());
        full.draw(c, img);
        c.drawRect(
            Rect.fromLTWH(0, 0, w, h),
            Paint()
              ..blendMode = BlendMode.dstIn
              ..shader = ui.Gradient.linear(Offset(x - dir * w * 0.15, 0), Offset(x + dir * w * 0.15, h * 0.4),
                  const [Color(0xFFFFFFFF), Color(0x00FFFFFF)]));
        c.restore();
      case MemeTrans.cut:
        full.draw(c, img);
    }
  }

  // ---------------------------------------------------------------- the bits

  /// What goes on this phrase: a takeover and an overlay or two, rolled on the
  /// phrase; a hazard card as a build starts; a freeze frame on the way out of a
  /// rage; everything swept off by a drop.
  void _schedule(MemeFrame fr, ShowDeck m, MemeMood mood, double? since, bool playing, double wakeK) {
    // Over, or out of place: gone.
    final t = _takeover;
    if (t != null && (t.over(fr) || (mood == MemeMood.wake && t is! FreezeBit) || (since != null && since >= 0 && since < 1))) {
      t.dispose();
      _takeover = null;
    }
    for (final o in _overlays.where((o) => o.over(fr) || (mood == MemeMood.wake && o is! WarningBit && wakeK > 0.5) || (since != null && since >= 0 && since < 1)).toList()) {
      o.dispose();
      _overlays.remove(o);
    }
    if (!playing) return;

    // A rage ending, not into a drop: the freeze frame, on the picture just drawn.
    final intoSleep = mood == MemeMood.sleep && (_moodWas == MemeMood.vibe || _moodWas == MemeMood.rage);
    final outOfRage = _moodWas == MemeMood.rage && mood == MemeMood.vibe;
    if ((intoSleep || outOfRage) && _out != null && _takeover == null && (_forcedBit == 'tbc' || memeHash(_salt, _beats.floor(), 61) < 0.75)) {
      final seed = (_salt + _beats.floor()) % 100003;
      final img = _out!;
      _out = null;
      _takeover = FreezeBit(_beats, 2, seed, img, wasted: _forcedBit == 'wasted' || memeHash(seed, 2, 2) < 0.4);
      return;
    }
    // A build starting with time to spare: the hazard card.
    if (_moodWas != MemeMood.wake && mood == MemeMood.wake && wakeK < 0.45 && _overlays.whereType<WarningBit>().isEmpty) {
      final card = _cardAt != null && _beats - _cardAt! >= 0 && _beats - _cardAt! < 4;
      if (memeHash(_salt, _beats.floor(), 23) < (_look.style == MemeStyle.y2k || _look.style == MemeStyle.fried ? 0.35 : 0.15)) {
        _overlays.add(WarningBit(card ? _cardAt! + 4 : _beats, 1, _salt));
      }
      return;
    }

    final bar = m.barIndex ?? 0;
    final phrase = (bar / 4).floor();
    if (!(fr.newBeat && (m.beatInBar ?? 1) == 0 && bar % 4 == 0) || phrase == _phraseWas) return;
    _phraseWas = phrase;
    if (mood == MemeMood.wake) return;
    if (since != null && since >= 0 && since < 12) return; // the drop's first bars are the drop's
    final seed = (_salt * 7 + phrase * 31) % 100003;
    final wantTakeover = _takeover == null &&
        memeHash(seed, 1, 1) <
            switch (mood) {
              MemeMood.vibe => 0.75,
              MemeMood.rage => 0.5,
              MemeMood.sleep => 0.45,
              _ => 0.0,
            };
    final wantOverlay = _overlays.length < (mood == MemeMood.sleep ? 1 : 2) && memeHash(seed, 2, 1) < (mood == MemeMood.sleep ? 0.15 : 0.35);
    if (!wantTakeover && !wantOverlay && _forcedBit == null) return;
    final forced = _forcedBit;
    final bit = forced != null && forced != 'tbc' && forced != 'wasted'
        ? (_takeover == null ? MemeBitPicker.make(forced, fr, _beats, seed) : null)
        : MemeBitPicker.pick(fr, _beats, seed, takeoverOk: wantTakeover, overlayOk: wantOverlay, notAgain: _recent.toSet());
    if (bit == null) return;
    bit.warm(bank);
    if (bit.takeover) {
      _takeover = bit;
    } else {
      _overlays.add(bit);
    }
    _recent.add(bit.kind);
    if (_recent.length > 4) _recent.removeAt(0);
  }

  // ---------------------------------------------------------------- spawns

  MemeSticker? _sticker({bool asleep = false}) {
    final list = [for (final s in bank.stickers) if ((s.set == 'sleep') == asleep) s];
    if (list.isEmpty) return null;
    return list[_rng.nextInt(list.length)];
  }

  void _throwSticker({bool corner = false}) {
    final s = _sticker();
    if (s == null) return;
    if (corner) {
      final left = _rng.nextBool();
      _stickers.add(_Thrown(s, x: left ? 0.14 : 0.86, y: 0.76, size: 0.34, born: _t, life: _spb * 8, rot: (left ? -1 : 1) * 0.12, spin: 0));
    } else {
      _stickers.add(_Thrown(s,
          x: 0.15 + 0.7 * _rng.nextDouble(),
          y: 0.18 + 0.55 * _rng.nextDouble(),
          size: 0.28 + 0.16 * _rng.nextDouble(),
          born: _t,
          life: _spb * 1.6,
          rot: (_rng.nextDouble() - 0.5) * 0.8,
          spin: (_rng.nextDouble() - 0.5) * 3));
    }
  }

  void _throwEmoji() {
    final list = bank.lines('emoji');
    if (list.isEmpty) return;
    _emoji.add(_Thrown(list[_rng.nextInt(list.length)],
        x: 0.08 + 0.84 * _rng.nextDouble(),
        y: 0.1 + 0.45 * _rng.nextDouble(),
        size: 0.15 + 0.1 * _rng.nextDouble(),
        born: _t,
        life: 0.8,
        rot: (_rng.nextDouble() - 0.5) * 0.7));
  }

  /// The drop: stickers flung out from the middle.
  void _storm() {
    for (var i = 0; i < 7; i++) {
      final s = _sticker();
      if (s == null) return;
      final a = i / 10 * 2 * math.pi + _rng.nextDouble() * 0.5;
      final v = 0.22 + 0.3 * _rng.nextDouble();
      _stickers.add(_Thrown(s,
          x: 0.5 + math.cos(a) * 0.08,
          y: 0.5 + math.sin(a) * 0.08,
          vx: math.cos(a) * v,
          vy: math.sin(a) * v * 0.7 - 0.25,
          size: 0.26 + 0.2 * _rng.nextDouble(),
          born: _t,
          life: 1.2 + 0.9 * _rng.nextDouble(),
          rot: (_rng.nextDouble() - 0.5) * 1.2,
          spin: (_rng.nextDouble() - 0.5) * 5));
    }
  }

  // ---------------------------------------------------------------- drawing

  void _drawStickers(Canvas c, double w, double h, double kick) {
    for (final s in _stickers) {
      final st = s.what as MemeSticker;
      final img = bank.image(st.file);
      if (img == null) continue;
      final age = _t - s.born;
      final pop = age < 0.14 ? Curves.easeOutBack.transform((age / 0.14).clamp(0.0, 1.0)) : 1.0;
      final out = (s.life - age) < 0.12 ? ((s.life - age) / 0.12).clamp(0.0, 1.0) : 1.0;
      final k = pop * out * (1 + 0.14 * kick);
      if (k <= 0.01) continue;
      drawSticker(c, img, st, Offset(s.x * w, s.y * h), s.size * h * k, rot: s.rot);
    }
  }

  /// The build's sticker: one dormouse rising from the bottom edge as the drop nears.
  void _peeker(Canvas c, double w, double h, double k, double kick) {
    var list = [for (final s in bank.stickers) if (s.peek) s];
    if (list.isEmpty) list = [for (final s in bank.stickers) if (s.set != 'sleep') s];
    if (list.isEmpty || k < 0.05) return;
    final st = list[(memeHash(_salt, (_beats / 16).floor(), 9) * list.length).floor() % list.length];
    final img = bank.image(st.file);
    if (img == null) return;
    final dh = h * 0.55 * (1 + 0.08 * kick);
    final y = h + dh * 0.05 - dh * 0.7 * Curves.easeOut.transform(k);
    drawSticker(c, img, st, Offset(w * 0.16, y + dh / 2), dh, rot: math.sin(_beats * math.pi) * 0.08, shadow: false);
  }

  /// Red laser eyes, the deep-fried way: a hot core, a red glow, a long flare.
  void _lasers(Canvas c, MemeShot shot, double k) {
    final r = shot.faceRadius * 0.42 * k;
    if (r < 2) return;
    final laser = _look.style == MemeStyle.vapor ? const Color(0xEE01CDFE) : const Color(0xEEFF2010);
    final flare = _look.style == MemeStyle.vapor ? const Color(0xAA40D0FF) : const Color(0xAAFF2A10);
    for (final e in shot.photo!.eyes) {
      final p = shot.map(e);
      final glow = Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(p, r, [const Color(0xFFFFFFFF), laser, laser.withValues(alpha: 0)], const [0.0, 0.22, 1.0]);
      c.drawCircle(p, r, glow);
      for (final (sxk, syk, a) in [(8.0, 0.1, 0.0), (3.2, 0.05, 0.62), (3.2, 0.05, -0.62)]) {
        c.save();
        c.translate(p.dx, p.dy);
        c.rotate(a + shot.rot);
        c.scale(sxk, syk);
        c.drawCircle(
            Offset.zero,
            r,
            Paint()
              ..blendMode = BlendMode.plus
              ..shader = ui.Gradient.radial(Offset.zero, r, [const Color(0xFFFFE0D0), flare, flare.withValues(alpha: 0)], const [0.0, 0.3, 1.0]));
        c.restore();
      }
    }
  }

  /// The red circle round the face and the arrow at it, drawn on over a third of a beat.
  void _circle(Canvas c, MemeShot shot, double beatsIn, double w, double h) {
    final k = (beatsIn / 0.33).clamp(0.0, 1.0);
    final centre = shot.map(shot.photo!.face);
    final rad = (shot.faceRadius * 1.25).clamp(h * 0.08, h * 0.45);
    final paint = Paint()
      ..color = const Color(0xFFFF1A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.012
      ..strokeCap = StrokeCap.round;
    final oval = Rect.fromCenter(center: centre, width: rad * 2.3, height: rad * 1.9);
    // A turn and a bit, the way a hand closes a circle: two arcs, since one past a
    // whole turn wraps round to a sliver.
    final path = Path()
      ..addArc(oval, -2.2, math.pi * 1.9)
      ..arcTo(oval, -2.2 + math.pi * 1.9, math.pi * 0.2, false);
    for (final metric in path.computeMetrics()) {
      c.drawPath(metric.extractPath(0, metric.length * k), paint);
    }
    if (k < 1) return;
    // The arrow, from the emptier side.
    final side = centre.dx < w / 2 ? 1.0 : -1.0;
    final tail = Offset(centre.dx + side * (rad * 1.15 + w * 0.17), centre.dy + h * 0.2);
    final tip = Offset(centre.dx + side * rad * 1.2, centre.dy + rad * 0.55);
    c.drawLine(tail, tip, paint);
    final a = math.atan2(tip.dy - tail.dy, tip.dx - tail.dx);
    final head = h * 0.04;
    c.drawLine(tip, tip - Offset(math.cos(a - 0.5), math.sin(a - 0.5)) * head, paint);
    c.drawLine(tip, tip - Offset(math.cos(a + 0.5), math.sin(a + 0.5)) * head, paint);
  }

  /// Manga speed lines: thin white wedges from the edge towards the middle.
  void _speedLines(Canvas c, double w, double h, double k, int seed) {
    final rnd = math.Random(seed);
    final cx = w / 2, cy = h / 2;
    final far = math.sqrt(w * w + h * h) * 0.6;
    final paint = Paint()..color = Colors.white.withValues(alpha: (0.8 * k).clamp(0.0, 1.0));
    final path = Path();
    for (var i = 0; i < 48; i++) {
      final a = rnd.nextDouble() * 2 * math.pi;
      final wa = 0.003 + 0.011 * rnd.nextDouble();
      final inner = far * (0.5 + 0.32 * rnd.nextDouble()) * (1.15 - 0.15 * k);
      path
        ..moveTo(cx + math.cos(a - wa) * far, cy + math.sin(a - wa) * far)
        ..lineTo(cx + math.cos(a + wa) * far, cy + math.sin(a + wa) * far)
        ..lineTo(cx + math.cos(a) * inner, cy + math.sin(a) * inner)
        ..close();
    }
    c.drawPath(path, paint);
  }

  // ---------------------------------------------------------------- the words

  @override
  void paintOver(Canvas canvas, Size size, ShowState st, double opacity) {
    final fr = _frame;
    if (_st == null || fr == null || !bank.ready || opacity <= 0.01) return;
    final m = st.master;
    final w = size.width, h = size.height;
    if (opacity < 0.99) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(255, 255, 255, opacity));
    final shake = Offset(_shake.dx * w, _shake.dy * h);
    final since = _since;
    final takeover = _takeover;

    // The trail camera's screen.
    if (_night > 0.03 && takeover == null) _trailCam(canvas, size, m);

    // Z, rising off the sleeper.
    for (final z in _zs) {
      final age = _t - z.born;
      final k = age / 2.6;
      final a = (k < 0.15 ? k / 0.15 : 1 - (k - 0.15) / 0.85).clamp(0.0, 1.0);
      final zs = (h * 0.075).roundToDouble();
      final p = type.text('z|$zs', () => TextSpan(text: 'Z', style: Mag.marker(zs, color: const Color(0xFFE8FFF0))));
      final ps = type.text(
          'zs|$zs',
          () => TextSpan(
              text: 'Z',
              style: Mag.marker(zs).copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = zs * 0.14
                    ..color = const Color(0xCC000000))));
      canvas.save();
      canvas.translate((z.x + 0.07 * k) * w, (z.y - 0.16 * k) * h);
      canvas.scale(1 + 1.1 * k);
      canvas.rotate(-0.2 + 0.25 * math.sin(age * 2));
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, a * 0.9));
      ps.paint(canvas, Offset(-p.width / 2, -p.height / 2));
      p.paint(canvas, Offset(-p.width / 2, -p.height / 2));
      canvas.restore();
      canvas.restore();
    }

    // The bits' own words and chrome.
    takeover?.paintOver(canvas, size, fr);
    for (final o in _overlays) {
      if (!o.early(fr)) o.paintOver(canvas, size, fr);
    }

    // The emoji thrown on.
    for (final e in _emoji) {
      final age = _t - e.born;
      final pop = age < 0.12 ? Curves.easeOutBack.transform((age / 0.12).clamp(0.0, 1.0)) : 1.0;
      final out = (e.life - age) < 0.15 ? ((e.life - age) / 0.15).clamp(0.0, 1.0) : 1.0;
      final s = (e.size * h).roundToDouble();
      final p = type.text('e|${e.what}|$s', () => TextSpan(text: e.what as String, style: TextStyle(fontSize: s)));
      canvas.save();
      canvas.translate(e.x * w + shake.dx, e.y * h + shake.dy);
      canvas.rotate(e.rot);
      canvas.scale(pop * out);
      p.paint(canvas, Offset(-p.width / 2, -p.height / 2));
      canvas.restore();
    }

    final away = m.dropBeatsAway;
    final playing = m.playing && m.beatIndex != null;
    final card = _cardAt != null && _beats - _cardAt! >= 0 && _beats - _cardAt! < 4;
    final counting = playing && away != null && away > 0 && away <= 7 && _mood == MemeMood.wake;
    final warned = _overlays.any((o) => o is WarningBit && !o.early(fr));
    final wakeK = MemeClock.wakeK(m);

    if (counting) {
      _countdown(canvas, size, away, shake);
    } else if (_mood == MemeMood.wake && !card && !warned && wakeK > 0.12 && memeHash(_salt, 4, 29) < 0.4) {
      _loading(canvas, size, wakeK, shake);
    } else if (!card && !warned && (takeover == null || (m.lyric != null && !takeover.quiet))) {
      // Words over the photographs; a look keeps the screen to itself (a line
      // being sung still shows over most).
      _wordsNow(canvas, size, m, shake, since);
    }
    if (_mood == MemeMood.sleep && takeover == null) _fact(canvas, size);

    // The mix: a "VS" screen while the DJ brings the next record in.
    if (st.mix.on && st.mix.k > 0.02 && st.mix.k < 0.98) _versus(canvas, size, st);

    // The watermark, which moves every eight bars, as theirs does.
    if (bank.handle.isNotEmpty) {
      final p = type.text('wm|${(h * 0.03).round()}', () {
        final s = (h * 0.03).roundToDouble();
        return TextSpan(
          text: '♪ ${bank.handle}',
          style: Mag.title(s, color: const Color(0x8CFFFFFF)).copyWith(shadows: const [Shadow(color: Color(0x66000000), blurRadius: 4)]),
        );
      });
      final corner = ((_beats / 32).floor()).isEven;
      final at = corner ? Offset(w * 0.035, h * (_mood == MemeMood.rage ? 0.1 : 0.04)) : Offset(w * 0.965 - p.width, h * (_mood == MemeMood.rage ? 0.86 : 0.91));
      p.paint(canvas, at);
    }

    if (card) _card(canvas, size, (_beats - _cardAt!) / 4);
    if (opacity < 0.99) canvas.restore();
  }

  /// The words on now: the line sung, or a caption from the bank.
  void _wordsNow(Canvas canvas, Size size, ShowDeck m, Offset shake, double? since) {
    final look = _look;
    final lyric = m.lyric;
    if (lyric != null && lyric.trim().isNotEmpty && m.lyricK < 0.999) {
      final words = lyric.trim().split(RegExp(r'\s+'));
      final pos = m.lyricK * words.length;
      final cur = pos.floor().clamp(0, words.length - 1);
      final age = (pos - pos.floor()) * (_spb * 4) / words.length.clamp(1, 99);
      type.captions(canvas, size, words, cur, 1 + 0.22 * math.exp(-age * 14), look.hi, shake, ink: look.ink, width: look.width);
      return;
    }
    if (since != null && since >= 0 && since < 1) return; // the impact has the screen
    final pool = bank.lines(_mood.name);
    if (pool.isEmpty) return;
    final slotBeats = switch (_mood) {
      MemeMood.rage || MemeMood.wake => 8.0,
      _ => 16.0,
    };
    final slot = (_beats / slotBeats).floor();
    final show = memeHash(_salt, slot, 31 + _mood.index) < (_mood == MemeMood.rage ? 0.5 : 0.35);
    if (!show) return;
    final line = pool[(memeHash(_salt, slot, 17 + _mood.index) * pool.length).floor() % pool.length];
    final words = line.split(RegExp(r'\s+'));
    final rate = _mood == MemeMood.sleep ? 0.5 : 1.0;
    final into = (_beats - slot * slotBeats) * rate;
    final cur = into.floor().clamp(0, words.length - 1);
    final age = (into - into.floor()) * _spb / rate;
    // A line said, and held to the end of its slot; gone for the last beat.
    if (_beats - slot * slotBeats > slotBeats - 1) return;
    type.captions(canvas, size, words, cur, 1 + 0.22 * math.exp(-age * 14), slot.isEven ? look.hi : look.hi2, shake, ink: look.ink, width: look.width, fontShare: 0.06);
  }

  void _countdown(Canvas canvas, Size size, double away, Offset shake) {
    final n = away.ceil().clamp(1, 7);
    final through = (n - away).clamp(0.0, 1.0);
    final pop = 1 + 0.6 * math.exp(-through * 7);
    final h = size.height;
    final number = type.bold('$n', h * 0.42, n == 1 ? const Color(0xFFFF2A1A) : Colors.white, width: 62);
    final rot = (n.isEven ? 1 : -1) * 0.07;
    type.paintBold(canvas, number, Offset(size.width / 2, h * 0.43) + shake * 2, scale: pop, rot: rot);
    final names = bank.lines('countdown');
    if (names.length >= 7) {
      final word = type.bold(names[7 - n].toUpperCase(), h * 0.085, _look.hi, width: 110);
      type.paintBold(canvas, word, Offset(size.width / 2, h * 0.76) + shake, scale: 1 + 0.2 * math.exp(-through * 9));
    }
  }

  /// The build's loading bar: "AUFWACHEN…" filling as the drop nears, the way a
  /// game's does, with the odd stall.
  void _loading(Canvas canvas, Size size, double k, Offset shake) {
    final w = size.width, h = size.height;
    final label = bank.line('loading', _salt, (_beats / 32).floor()) ?? 'aufwachen';
    // Stalls: the bar sticks a moment at a few points, then catches up.
    final shown = (k * 100 - 6 * math.max(0.0, math.sin(k * 23) - 0.6)).clamp(0.0, 99.0);
    final bw = w * 0.56, bh = h * 0.06;
    final x0 = (w - bw) / 2 + shake.dx, y0 = h * 0.8 + shake.dy;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x0, y0, bw, bh), Radius.circular(bh * 0.2)), Paint()..color = const Color(0xCC101010));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x0, y0, bw, bh), Radius.circular(bh * 0.2)),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.005);
    final fill = Rect.fromLTWH(x0 + bh * 0.15, y0 + bh * 0.15, (bw - bh * 0.3) * shown / 100, bh * 0.7);
    canvas.drawRRect(RRect.fromRectAndRadius(fill, Radius.circular(bh * 0.1)), Paint()..color = Color.lerp(_look.hi2, const Color(0xFFFF2A1A), k)!);
    // The stripes marching along the bar.
    canvas.save();
    canvas.clipRect(fill);
    final stripe = Paint()..color = Colors.white.withValues(alpha: 0.25);
    final step = bh * 0.9;
    for (var x = fill.left - step + (_t * bh * 2) % step; x < fill.right; x += step) {
      canvas.drawPath(
          Path()
            ..moveTo(x, fill.top)
            ..lineTo(x + step * 0.4, fill.top)
            ..lineTo(x + step * 0.4 - bh * 0.4, fill.bottom)
            ..lineTo(x - bh * 0.4, fill.bottom)
            ..close(),
          stripe);
    }
    canvas.restore();
    final s = (h * 0.05).roundToDouble();
    final text = type.bold('${label.toUpperCase()}… ${shown.round()}%', s, Colors.white, width: 90);
    type.paintBold(canvas, text, Offset(w / 2 + shake.dx, y0 - s * 0.9), scale: 1 + 0.04 * (_frame?.beatDecay ?? 0));
  }

  /// A fact typed out now and then while it sleeps: on the trail camera's screen,
  /// or softly in the nest and the moonlight.
  void _fact(Canvas canvas, Size size) {
    final facts = bank.lines('facts');
    if (facts.isEmpty) return;
    const slotBeats = 16.0;
    final slot = (_beats / slotBeats).floor();
    if (memeHash(_salt, slot, 41) > 0.7) return;
    final into = _beats - slot * slotBeats;
    if (into > 14) return;
    final line = 'FAKT: ${facts[(memeHash(_salt, slot, 43) * facts.length).floor() % facts.length]}';
    final s = (size.height * 0.034).roundToDouble();
    final cam = _skin == 0;
    final a = cam ? _night.clamp(0.0, 1.0) : (into < 13 ? 1.0 : (14 - into).clamp(0.0, 1.0));
    final ink = cam ? Color.fromRGBO(235, 255, 235, 0.9 * a) : Color.fromRGBO(255, 248, 235, 0.8 * a);
    type.typed(canvas, Offset(size.width * 0.07, size.height * (cam ? 0.13 : 0.08)), cam ? line : line.substring(6), into / 6, s, colour: ink, maxWidth: size.width * 0.8);
  }

  /// The mix as a fight card: the record playing against the one coming in, the
  /// line between them where the fader is.
  void _versus(Canvas canvas, Size size, ShowState st) {
    final w = size.width, h = size.height;
    final k = st.mix.k;
    final from = st.masterName == 'a' ? st.a : st.b, to = st.masterName == 'a' ? st.b : st.a;
    final awake = [for (final s in bank.stickers) if (s.set != 'sleep') s];
    if (awake.isEmpty) return;
    MemeSticker pickFor(int? id) => awake[(memeHash(id ?? 0, 9, 9) * awake.length).floor() % awake.length];
    final x = w * (0.15 + 0.7 * k);
    // The halves tinted, the split a slanted line.
    canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..lineTo(x + h * 0.08, 0)
          ..lineTo(x - h * 0.08, h)
          ..lineTo(0, h)
          ..close(),
        Paint()..color = const Color(0x33FF2A1A));
    canvas.drawPath(
        Path()
          ..moveTo(x + h * 0.08, 0)
          ..lineTo(w, 0)
          ..lineTo(w, h)
          ..lineTo(x - h * 0.08, h)
          ..close(),
        Paint()..color = const Color(0x332A7AFF));
    canvas.drawLine(Offset(x + h * 0.08, 0), Offset(x - h * 0.08, h),
        Paint()
          ..color = Colors.white
          ..strokeWidth = h * 0.012);
    final beat = _frame?.beatDecay ?? 0;
    for (final (sticker, cx, title) in [(pickFor(from.trackId), w * 0.17, from.title), (pickFor(to.trackId), w * 0.83, to.title)]) {
      final img = bank.image(sticker.file);
      if (img != null) drawSticker(canvas, img, sticker, Offset(cx, h * 0.42), h * 0.38 * (1 + 0.1 * beat), rot: (cx < w / 2 ? 1 : -1) * 0.08 * beat);
      if (title != null) {
        final s = (h * 0.04).roundToDouble();
        final p = type.text('vs|$title|$s', () => TextSpan(text: title.toUpperCase(), style: Mag.title(s, color: Colors.white)), maxWidth: w * 0.3);
        p.paint(canvas, Offset(cx - p.width / 2, h * 0.66));
      }
    }
    type.paintBold(canvas, type.bold('VS', h * 0.2, _look.hi, width: 62), Offset(x, h * 0.5), scale: 1 + 0.15 * beat, rot: -0.1);
  }

  /// "7 MONATE SPÄTER": the cartoon's card, a bar long, bubbles and wobbling letters.
  void _card(Canvas canvas, Size size, double k) {
    final w = size.width, h = size.height;
    final rect = Offset.zero & size;
    final a = k < 0.06 ? k / 0.06 : (k > 0.92 ? (1 - k) / 0.08 : 1.0);
    canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(255, 255, 255, a.clamp(0.0, 1.0)));
    canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(Offset(w * 0.5, h * 0.45), w * 0.75, const [Color(0xFF3FA9F5), Color(0xFF1456B8), Color(0xFF0A2A66)], const [0.0, 0.6, 1.0]));
    final bubbles = math.Random(11);
    final bubble = Paint()
      ..color = const Color(0x55FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.006;
    for (var i = 0; i < 26; i++) {
      final x = bubbles.nextDouble() * w;
      final speed = 0.15 + 0.35 * bubbles.nextDouble();
      final y = ((bubbles.nextDouble() - _t * speed * 0.5) % 1.0) * h * 1.1;
      final r = h * (0.01 + 0.04 * bubbles.nextDouble());
      canvas.drawCircle(Offset(x + math.sin(_t * 2 + i) * h * 0.01, y), r, bubble);
    }
    final text = _cardText.toUpperCase();
    final size0 = h * 0.12;
    final letters = [for (final ch in text.characters) ch == ' ' ? null : type.bold(ch, size0, const Color(0xFFFFD21A), width: 90)];
    final space = size0 * 0.3;
    // Two lines where it is long.
    final words = text.split(' ');
    final lines = <String>[];
    var cur = '';
    for (final word in words) {
      if (cur.isNotEmpty && (cur.length + word.length) > 12) {
        lines.add(cur);
        cur = word;
      } else {
        cur = cur.isEmpty ? word : '$cur $word';
      }
    }
    if (cur.isNotEmpty) lines.add(cur);
    var y = h * 0.5 - (lines.length - 1) * size0 * 0.55;
    var idx = 0;
    for (final line in lines) {
      final chars = line.characters.toList();
      var total = 0.0;
      final ws = <double>[];
      for (var i = 0; i < chars.length; i++) {
        final p = letters[idx + i];
        final cw = p == null ? space : p.$2.width;
        ws.add(cw);
        total += cw;
      }
      var x = (w - total) / 2;
      for (var i = 0; i < chars.length; i++) {
        final p = letters[idx + i];
        if (p != null) {
          final bob = math.sin(_t * 6 + (idx + i) * 0.9) * size0 * 0.06;
          final rot = math.sin(_t * 4 + (idx + i) * 1.7) * 0.09;
          type.paintBold(canvas, p, Offset(x + ws[i] / 2, y + bob), rot: rot, scale: 1 + 0.04 * math.sin(_t * 9 + i));
        }
        x += ws[i];
      }
      idx += chars.length + 1; // the space between the lines
      y += size0 * 1.1;
    }
    canvas.restore();
  }

  /// The trail camera's screen: REC, the camera, the infrared, the date and time.
  void _trailCam(Canvas canvas, Size size, ShowDeck m) {
    final w = size.width, h = size.height;
    final a = _night.clamp(0.0, 1.0);
    final s = (h * 0.034).roundToDouble();
    final ink = Color.fromRGBO(235, 255, 235, 0.85 * a);
    TextPainter t(String key, String text) => type.text('tc|$key|$text|$s|${(a * 20).round()}', () => TextSpan(text: text, style: Mag.typewriter(s, color: ink, bold: true)));
    final m0 = h * 0.06;
    // The corners of a viewfinder.
    final frame = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.004;
    final l = h * 0.06;
    for (final (x, y, dx, dy) in [(m0, m0, 1.0, 1.0), (w - m0, m0, -1.0, 1.0), (m0, h - m0, 1.0, -1.0), (w - m0, h - m0, -1.0, -1.0)]) {
      canvas.drawLine(Offset(x, y), Offset(x + dx * l, y), frame);
      canvas.drawLine(Offset(x, y), Offset(x, y + dy * l), frame);
    }
    final blink = (_beats * 2).floor().isEven;
    if (blink) canvas.drawCircle(Offset(m0 + s * 0.9, m0 + s * 1.2), s * 0.32, Paint()..color = Color.fromRGBO(255, 40, 40, a));
    t('rec', 'REC').paint(canvas, Offset(m0 + s * 1.6, m0 + s * 0.55));
    final cam = t('cam', 'CAM 07  IR ●');
    cam.paint(canvas, Offset(w - m0 - s * 0.5 - cam.width, m0 + s * 0.55));
    // 03:14 in the night of the Siebenschläfertag, running with the record.
    final secs = 3 * 3600 + 14 * 60 + m.position.inSeconds;
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = '27.06.  ${two(secs ~/ 3600 % 24)}:${two(secs ~/ 60 % 60)}:${two(secs % 60)}';
    final c = t('clock', clock);
    c.paint(canvas, Offset(w - m0 - s * 0.5 - c.width, h - m0 - s * 1.7));
    t('temp', '9°C  ☾').paint(canvas, Offset(m0 + s * 0.6, h - m0 - s * 1.7));
  }

  @override
  void dispose() {
    _out?.dispose();
    _out = null;
    _fx?.dispose();
    _takeover?.dispose();
    for (final o in _overlays) {
      o.dispose();
    }
    _overlays.clear();
    type.dispose();
  }
}
