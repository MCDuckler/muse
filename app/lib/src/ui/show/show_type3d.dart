// The 3D type, drawn: the hands' words (state/show/show_type3d.dart's TypeSpec) set in
// their face, turned into a distance field once a line (off the frame's isolate), and
// ray-marched every frame by shaders/show/sim/type3d.frag — the native stage's sim
// (its floats by ws_words, the fields up as the textures "type3d.sdf" and
// "type3d.sdfb") or the Flutter stage's, from the same numbers.
//
// Two lines are held, one in each of the shader's slots: the one on, and the next,
// set ahead of its moment (the line after the one on is always being made), so the
// change lands on the beat it was asked for. It turns into the next the hands' way —
// its letters flowing into the next ones, turned over edge-on, or cut over in bands.
//
// The music moves it: a phrase picks one of the hands' motions (the calm ones in a
// quiet part, the ones that move a lot the harder the music, one of those at once on
// a drop), one of their looks and two of their bends (crossfaded in); the motions run
// faster the harder it is; the kick pushes the letters out, at the camera and lights
// them, the snare whitens their rim and ticks the horizon, the low end breathes their
// depth; in a loud part the letters jolt round on every beat, and whip once round on
// the drop, and the camera travels through each shot — round them, in at them, up
// over them (CameraSweep); each bend has its own part of the music (TypeDeform).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../state/show/show_state.dart';
import '../../state/show/show_pool.dart' show StylePool;
import '../../state/show/show_type3d.dart';
import 'show_meme_bank.dart' show memeHash;
import 'show_sims.dart';
import 'show_words.dart' show WordsUpload;
import 'show_canvas.dart' show StagePrograms;
import 'stage_camera.dart' show CameraSweep, StageCamera, cutHold;

/// The shader's floats (type3d.frag), in the order the file declares them, each with
/// its count: the one list both stages take.
class Type3dParams {
  const Type3dParams._();

  static const uniforms = <(String, int)>[
    ('uResolution', 2),
    ('uTime', 1),
    ('uRotX', 3),
    ('uRotY', 3),
    ('uRotZ', 3),
    ('uPos', 3),
    ('uHalf', 2),
    ('uHalfB', 2),
    ('uRange', 1),
    ('uRangeB', 1),
    ('uMix', 1),
    ('uMixMode', 1),
    ('uSeed', 1),
    ('uDepth', 1),
    ('uBevel', 1),
    ('uWave', 1),
    ('uWavePhase', 1),
    ('uTwist', 1),
    ('uDeformA', 4),
    ('uDeformB', 4),
    ('uDeformC', 4),
    ('uLook', 1),
    ('uInk', 3),
    ('uInk2', 3),
    ('uRim', 3),
    ('uGlow', 1),
    ('uKick', 1),
    ('uFlash', 1),
    ('uFov', 1),
    ('uMirror', 2),
    ('uGroundOn', 1),
    ('uPremul', 1),
  ];

  static final Map<String, int> at = () {
    final m = <String, int>{};
    var i = 0;
    for (final (name, n) in uniforms) {
      m[name] = i;
      i += n;
    }
    return m;
  }();

  static final int length = uniforms.fold(0, (a, u) => a + u.$2);
}

/// A line's distance field: its picture (RGBA, the distance in sixteen bits: red the
/// high byte, green the low), its
/// size, and what it measures in the object's units (a line of type is 1 high).
class TypeField {
  TypeField(this.text, this.font, this.w, this.h, this.rgba, this.halfX, this.halfY, this.range);
  final String text;
  final TypeFont font;
  final int w, h;
  final Uint8List rgba;
  final double halfX, halfY, range;
  ui.Image? image;

  /// Which of the native stage's two slots holds it (-1: neither).
  int uploadedTo = -1;

  String get key => '${font.name}|$text';

  void dispose() {
    image?.dispose();
    image = null;
  }

  /// The type's height in pixels as it is set, and how far the field reaches.
  static const fontPx = 150.0, rangePx = 20.0;

  /// [text] in [font] as a distance field. The type is set and read here; the field
  /// is worked out on an isolate of its own.
  static Future<TypeField> bake(String text, TypeFont font) async {
    var size = fontPx;
    TextPainter set(double px) => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontFamily: font.family, fontSize: px, height: 1.05, color: const Color(0xffffffff), letterSpacing: px * 0.03),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
    var tp = set(size);
    // A long line set smaller, the field no wider than a texture should be.
    const maxW = 2000.0;
    if (tp.width > maxW - 2 * (rangePx + 4)) {
      size = size * (maxW - 2 * (rangePx + 4)) / tp.width;
      tp.dispose();
      tp = set(size);
    }
    const pad = rangePx + 4;
    final w = (tp.width + 2 * pad).ceil(), h = (tp.height + 2 * pad).ceil();
    // Set larger than the field and measured there, then averaged down: a field from
    // a mask a pixel sharp is a staircase along every slant.
    final ss = w * h * 9 <= 4000000 ? 3 : 2;
    final r = ui.PictureRecorder();
    final c = Canvas(r)
      ..scale(ss.toDouble())
      ..translate(pad, pad);
    tp.paint(c, Offset.zero);
    final lineH = tp.height;
    tp.dispose();
    final pic = r.endRecording();
    final img = await pic.toImage(w * ss, h * ss);
    pic.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    final alpha = Uint8List(w * h * ss * ss);
    final px = data!.buffer.asUint8List();
    for (var i = 0; i < alpha.length; i++) {
      alpha[i] = px[i * 4 + 3];
    }
    final rgba = await compute(_field, (alpha, w, h, ss, rangePx * size / fontPx));
    return TypeField(text, font, w, h, rgba, w / 2 / lineH, h / 2 / lineH, rangePx * size / fontPx / lineH);
  }

  /// The signed distance (out positive) of every pixel to the type's edge, a pixel
  /// [range] every 0.5, in RGBA: Felzenszwalb's squared distances, each way, on the
  /// mask [ss] times larger (the edge's pixels placed by their coverage), averaged
  /// down to [w]×[h].
  static Uint8List _field((Uint8List, int, int, int, double) job) {
    final (alpha, w0, h0, ss, range) = job;
    final w = w0 * ss, h = h0 * ss;
    const inf = 1e20;
    Float64List squared(bool inside) {
      final g = Float64List(w * h);
      for (var i = 0; i < g.length; i++) {
        final on = alpha[i] >= 128;
        g[i] = on == inside ? 0 : inf;
      }
      final n = math.max(w, h);
      final f = Float64List(n), d = Float64List(n), z = Float64List(n + 1);
      final v = Int32List(n);
      void pass(int len) {
        var k = 0;
        v[0] = 0;
        z[0] = -inf;
        z[1] = inf;
        for (var q = 1; q < len; q++) {
          var s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
          while (s <= z[k]) {
            k--;
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
          }
          k++;
          v[k] = q;
          z[k] = s;
          z[k + 1] = inf;
        }
        k = 0;
        for (var q = 0; q < len; q++) {
          while (z[k + 1] < q) {
            k++;
          }
          d[q] = (q - v[k]) * (q - v[k]) + f[v[k]];
        }
      }

      for (var x = 0; x < w; x++) {
        for (var y = 0; y < h; y++) {
          f[y] = g[y * w + x];
        }
        pass(h);
        for (var y = 0; y < h; y++) {
          g[y * w + x] = d[y];
        }
      }
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          f[x] = g[y * w + x];
        }
        pass(w);
        for (var x = 0; x < w; x++) {
          g[y * w + x] = d[x];
        }
      }
      return g;
    }

    final out = squared(true), inn = squared(false);
    // Averaged down to the field's own size.
    var sdf = Float64List(w0 * h0);
    for (var y0 = 0; y0 < h0; y0++) {
      for (var x0 = 0; x0 < w0; x0++) {
        var sum = 0.0;
        for (var dy = 0; dy < ss; dy++) {
          for (var dx = 0; dx < ss; dx++) {
            final i = (y0 * ss + dy) * w + x0 * ss + dx;
            // Out: the distance to the nearest inside pixel; in: to the nearest
            // outside one; the edge itself half a pixel either way, by its coverage.
            var sd = math.sqrt(out[i]) - math.sqrt(inn[i]);
            if (alpha[i] > 0 && alpha[i] < 255) sd += 0.5 - alpha[i] / 255;
            sum += sd;
          }
        }
        sdf[y0 * w0 + x0] = sum / (ss * ss) / ss;
      }
    }
    // Softened a little, twice each way: a distance to pixels ripples along a slant,
    // and a normal taken off it ripples the more.
    for (var pass = 0; pass < 2; pass++) {
      for (final across in const [true, false]) {
        final next = Float64List(w0 * h0);
        for (var y = 0; y < h0; y++) {
          for (var x = 0; x < w0; x++) {
            var acc = 0.0;
            for (var k = -2; k <= 2; k++) {
              final xx = across ? (x + k).clamp(0, w0 - 1) : x, yy = across ? y : (y + k).clamp(0, h0 - 1);
              acc += sdf[yy * w0 + xx] * const [1, 4, 6, 4, 1][k + 2];
            }
            next[y * w0 + x] = acc / 16;
          }
        }
        sdf = next;
      }
    }
    final rgba = Uint8List(w0 * h0 * 4);
    for (var i = 0; i < w0 * h0; i++) {
      // Sixteen bits, high in red, low in green: eight would ripple every slant once
      // a normal is taken off it (a texture filtered is linear, so the two halves
      // filter as the whole would).
      final v = ((0.5 + sdf[i] / (2 * range)).clamp(0.0, 1.0) * 65535).round();
      rgba[i * 4] = v >> 8;
      rgba[i * 4 + 1] = v & 255;
      rgba[i * 4 + 3] = 255;
    }
    return rgba;
  }
}

/// Where a motion has the letters at a moment: turned (yaw about the upright, pitch
/// about the across, roll about the view), moved, bent and wrung.
class _Pose {
  const _Pose({this.yaw = 0, this.pitch = 0, this.roll = 0, this.x = 0, this.y = 0, this.z = 0, this.wave = 0, this.twist = 0});
  final double yaw, pitch, roll, x, y, z, wave, twist;

  _Pose lerp(_Pose o, double k) => _Pose(
        yaw: yaw + (o.yaw - yaw) * k,
        pitch: pitch + (o.pitch - pitch) * k,
        roll: roll + (o.roll - roll) * k,
        x: x + (o.x - x) * k,
        y: y + (o.y - y) * k,
        z: z + (o.z - z) * k,
        wave: wave + (o.wave - wave) * k,
        twist: twist + (o.twist - twist) * k,
      );
}

/// The close drift's way in: the camera this much nearer than the line's distance.
const _driftZ = 1.6;

double _ease(double t) {
  t = t.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// The motions that move a lot (picked the harder the music), and the ones on the
/// beat (their clock the record's beats, never sped up).
const _hardMotions = {TypeMotion.spin, TypeMotion.tumble, TypeMotion.flip, TypeMotion.twist, TypeMotion.zoom, TypeMotion.bounce};
const _beatMotions = {TypeMotion.bounce, TypeMotion.flip, TypeMotion.swing, TypeMotion.zoom};

/// One of [from] by the dice [d]: the hard ones the harder the music ([drive]), the
/// calm ones the calmer.
TypeMotion _pickMotion(List<TypeMotion> from, double drive, double d) {
  final w = [for (final x in from) 0.15 + 3 * (_hardMotions.contains(x) ? drive : 1 - drive)];
  var left = d * w.fold(0.0, (a, b) => a + b);
  for (var i = 0; i < from.length; i++) {
    left -= w[i];
    if (left <= 0) return from[i];
  }
  return from.last;
}

/// The motions, by beats [b] (the speed taken in) into the record.
_Pose _motion(TypeMotion m, double b) {
  const tau = math.pi * 2;
  final inBar = b % 4;
  return switch (m) {
    TypeMotion.spin => _Pose(yaw: tau * b / 8, pitch: 0.12 * math.sin(tau * b / 16)),
    TypeMotion.tumble => _Pose(yaw: tau * b / 11, pitch: tau * b / 17, roll: tau * b / 23),
    TypeMotion.swing => _Pose(yaw: 0.6 * math.cos(math.pi * b), roll: 0.06 * math.sin(math.pi * b)),
    // A whole turn over, in the bar's first beat and a half, then still.
    TypeMotion.flip => _Pose(pitch: tau * _ease(inBar / 1.5)),
    TypeMotion.wave => _Pose(yaw: 0.28 * math.sin(tau * b / 16), wave: 0.07, pitch: 0.1 * math.sin(tau * b / 8)),
    TypeMotion.twist => _Pose(twist: 0.55 * math.sin(tau * b / 4), yaw: 0.2 * math.sin(tau * b / 16)),
    TypeMotion.orbit => _Pose(
        x: 0.55 * math.sin(tau * b / 16),
        z: 0.6 * math.cos(tau * b / 16),
        yaw: -0.45 * math.sin(tau * b / 16),
        pitch: 0.12 * math.sin(tau * b / 8),
      ),
    // In from far off over the phrase, held its last bar.
    TypeMotion.zoom => _Pose(z: -9 * (1 - _ease((b % 16) / 12)), yaw: 0.35 * math.sin(tau * b / 16)),
    TypeMotion.bounce => _Pose(y: 0.22 * math.pow(math.sin(math.pi * (b % 1)), 0.8).toDouble(), pitch: -0.1 * math.cos(math.pi * 2 * (b % 1))),
    // Close: the camera nearly at the letters, sliding along them over two bars.
    TypeMotion.drift => _Pose(z: _driftZ, x: -1.3 * math.sin(tau * b / 32), yaw: 0.35 * math.sin(tau * b / 16), roll: 0.08 * math.sin(tau * b / 12)),
    TypeMotion.still => const _Pose(),
  };
}

/// The colours: face, side, rim.
(Color, Color, Color) _colours(TypeColour c, ShowPalette pal) => switch (c) {
      TypeColour.record => (
          pal.accent.withSaturation(0.75).withLightness(0.78).toColor(),
          pal.primary.withSaturation(0.8).withLightness(0.42).toColor(),
          pal.secondary.withSaturation(1).withLightness(0.62).toColor(),
        ),
      TypeColour.purple => (const Color(0xffe9b8ff), const Color(0xff5b1fa8), const Color(0xffff4fd8)),
      TypeColour.sunset => (const Color(0xffffd27a), const Color(0xffe0405a), const Color(0xffff7a3d)),
      TypeColour.ice => (const Color(0xffcff6ff), const Color(0xff3a7bd5), const Color(0xff7af0ff)),
      TypeColour.gold => (const Color(0xffffe6a0), const Color(0xffa8741a), const Color(0xffffc94a)),
      TypeColour.mono => (const Color(0xffffffff), const Color(0xff8a8a8a), const Color(0xffffffff)),
    };

/// The textures of the two slots on the native stage (the shader's uSdf, uSdfB).
const _slotNames = ['type3d.sdf', 'type3d.sdfb'];

class Type3dSim implements SimLayer {
  Type3dSim({this.upload});

  /// Where the fields go on the native stage; null on the Flutter one.
  final WordsUpload? upload;

  @override
  String get kind => 'type3d';

  final _v = Float32List(Type3dParams.length);
  double _t = 0, _fade = 0;

  /// The lines made, by face and text (the one on, the next, a few before).
  final _made = <String, TypeField>{};
  final _making = <String, Future<void>>{};

  /// The two slots, and which one is on; the turn to the other, 0..1, under way.
  final _slots = List<TypeField?>.filled(2, null);
  int _on = 0;
  double _turn = -1;
  TypeTurn _turnHow = TypeTurn.morph;

  int _phraseWas = -1;
  TypeMotion? _motionNow, _motionWas;
  TypeLook _look = TypeLook.chrome;
  Set<TypeDeform> _bends = const {}, _deformsWas = const {};
  double _blend = 1;

  /// Each bend's strength as it is (eased toward what the music asks).
  final _bend = List<double>.filled(TypeDeform.values.length, 0);
  double? _dropAt, _awayWas;
  double _hat = 0;

  /// The continuous motions' clock, in beats (run faster the harder the music), and
  /// the beat it was last read at; the turned-on-the-beat jolts, aimed and as far as
  /// they have got; the drop's distance as last said.
  double _phase = 0, _beatsWas = -1, _stepAim = 0, _stepYaw = 0;
  final _sweep = CameraSweep();
  int _sweepN = -1;
  double? _awayPick;
  int _beatWas = -1;

  ui.FragmentShader? _fx;
  ui.Image? _out, _black;

  @visibleForTesting
  TypeField? get field => _slots[_on];

  @visibleForTesting
  bool get turning => _turn >= 0;

  @visibleForTesting
  Set<TypeDeform> get bends => _bends;

  void _set(String name, double v) => _v[Type3dParams.at[name]!] = v;
  void _set2(String name, double a, double b) {
    final i = Type3dParams.at[name]!;
    _v[i] = a;
    _v[i + 1] = b;
  }

  void _set3(String name, double a, double b, double c) {
    final i = Type3dParams.at[name]!;
    _v[i] = a;
    _v[i + 1] = b;
    _v[i + 2] = c;
  }

  void _set4(String name, double a, double b, double c, double d) {
    final i = Type3dParams.at[name]!;
    _v[i] = a;
    _v[i + 1] = b;
    _v[i + 2] = c;
    _v[i + 3] = d;
  }

  void _setColour(String name, Color c) => _set3(name, c.r, c.g, c.b);

  /// [text] in [font] set, where it is not (or being).
  void _want(String text, TypeFont font) {
    final key = '${font.name}|$text';
    if (_made.containsKey(key) || _making.containsKey(key)) return;
    _making[key] = TypeField.bake(text, font).then((f) {
      _making.remove(key);
      _made[key] = f;
      _make(f);
      _forget();
    }).catchError((Object e) {
      _making.remove(key);
      debugPrint('type3d: could not set "$text": $e');
    });
  }

  /// The lines made long ago let go: a handful kept, never one in a slot.
  void _forget() {
    while (_made.length > 6) {
      final old = _made.entries.firstWhere((e) => !_slots.any((s) => identical(s, e.value)), orElse: () => _made.entries.first);
      if (_slots.any((s) => identical(s, old.value))) break;
      _made.remove(old.key);
      old.value.dispose();
    }
  }

  /// [f] into slot [i]; on the native stage, its field up into that slot's texture.
  void _place(int i, TypeField f) {
    _slots[i] = f;
    final up = upload;
    if (up != null && f.uploadedTo != i) {
      up(_slotNames[i], f.w, f.h, f.rgba);
      // Another field that was in that slot is not there any more.
      for (final o in _made.values) {
        if (!identical(o, f) && o.uploadedTo == i) o.uploadedTo = -1;
      }
      f.uploadedTo = i;
    }
  }

  /// One frame's numbers; the fields made (and on the native stage sent) as needed.
  Float32List tick(ShowState st, double dt, int w, int h) {
    _t += dt;
    final m = st.master;
    final f = st.flat;
    final spec = st.macros.type3d;
    final playing = m.playing && m.beatIndex != null;
    final bpm = (m.bpm ?? 0) > 1 ? m.bpm! : 120.0;
    final beats = !playing
        ? _t * bpm / 60
        : (m.barIndex != null && m.beatInBar != null ? m.barIndex! * 4 + m.beatInBar! + m.beatPhase : m.beatIndex! + m.beatPhase);
    final salt = (m.trackId ?? 0) ^ st.macros.seed;
    final beatsPer = beat1 / bpm;
    // How hard the music is now (StageCamera.drive): the motion picked by it, its
    // speed, the beat's accents. A drop landing: a hard motion at once.
    final drive = playing ? StageCamera.drive(m) : 0.0;
    final awayNow = m.dropBeatsAway;
    final dropLanded = playing && awayNow != null && awayNow <= 0 && awayNow > -2.5 && (_awayPick == null || _awayPick! > 0);
    _awayPick = awayNow;

    // The line: the change's count; the one now and the one after it set ahead.
    final every = switch (spec.change) {
      TypeChange.beat => 1.0,
      TypeChange.bar => 4.0,
      TypeChange.twoBars => 8.0,
      TypeChange.phrase => 16.0,
      TypeChange.eightBars => 32.0,
      TypeChange.never => 0.0,
    };
    final n = every == 0 ? 0 : (beats / every).floor();
    final text = spec.lineAt(n, title: m.title, artist: m.artist);
    _want(text, spec.font);
    if (every > 0) _want(spec.lineAt(n + 1, title: m.title, artist: m.artist), spec.font);
    final wanted = _made['${spec.font.name}|$text'];

    // The line wanted ready and not the one on: on at once where none is, else turned to.
    if (wanted != null && _ready(wanted) && !identical(_slots[_on], wanted) && _turn < 0) {
      if (_slots[_on] == null) {
        _place(_on, wanted);
      } else {
        _place(1 - _on, wanted);
        _turn = 0;
        _turnHow = spec.turn;
      }
    }
    // The turn: a beat or so, less where the lines come every beat.
    final turnBeats = switch (spec.change) {
      TypeChange.beat => 0.45,
      TypeChange.bar => 1.0,
      TypeChange.twoBars => 1.5,
      _ => 2.0,
    };
    var swapAngle = 0.0;
    var mix = _on.toDouble();
    if (_turn >= 0) {
      _turn += dt / (turnBeats * beatsPer);
      final k = _turn.clamp(0.0, 1.0);
      final to = 1 - _on;
      if (_turnHow == TypeTurn.flip) {
        // Away edge-on, the next in from the other edge.
        swapAngle = (k < 0.5 ? k : k - 1) * math.pi;
        mix = (k < 0.5 ? _on : to).toDouble();
      } else {
        final e = _ease(k);
        mix = _on == 0 ? e : 1 - e;
      }
      if (_turn >= 1) {
        _on = to;
        _turn = -1;
        mix = _on.toDouble();
      }
    }

    // A phrase: a motion, a look and two bends of the hands', crossfaded in.
    final phrase = (beats / 16).floor();
    // (And at once where the hands' sets leave out what is on: a favourite put on,
    // its motion, look and bends the only ones.)
    if (phrase != _phraseWas ||
        (dropLanded && !_hardMotions.contains(_motionNow)) ||
        _motionNow == null ||
        !spec.motions.contains(_motionNow) ||
        !spec.looks.contains(_look) ||
        !setEquals(spec.deforms, _deformsWas)) {
      final motions = [for (final x in TypeMotion.values) if (spec.motions.contains(x)) x];
      final looks = [for (final x in TypeLook.values) if (spec.looks.contains(x)) x];
      final hard = [for (final x in motions) if (_hardMotions.contains(x)) x];
      final pick = motions.isEmpty
          ? TypeMotion.still
          : dropLanded && hard.isNotEmpty
              ? hard[(memeHash(salt % 9973, phrase, 319) * hard.length).floor() % hard.length]
              : _pickMotion(motions, drive, memeHash(salt % 9973, phrase, 311));
      if (pick != _motionNow) {
        _motionWas = _motionNow;
        _motionNow = pick;
        _blend = _motionWas == null ? 1 : 0;
      }
      if (looks.isNotEmpty) _look = looks[(memeHash(salt % 9973, phrase, 313) * looks.length).floor() % looks.length];
      final bends = [for (final x in TypeDeform.values) if (spec.deforms.contains(x)) x];
      final chosen = <TypeDeform>{};
      for (var i = 0; i < 2 && chosen.length < bends.length; i++) {
        var j = (memeHash(salt % 9973, phrase * 3 + i, 317) * bends.length).floor() % bends.length;
        while (chosen.contains(bends[j])) {
          j = (j + 1) % bends.length;
        }
        chosen.add(bends[j]);
      }
      // The drop's shatter whenever it is one of the hands'.
      if (spec.deforms.contains(TypeDeform.shatter)) chosen.add(TypeDeform.shatter);
      _bends = chosen;
      _deformsWas = spec.deforms;
      _phraseWas = phrase;
      StylePool.typeNow = (motion: _motionNow!, look: _look, bends: _bends);
    }
    if (!spec.deforms.containsAll(_bends)) _bends = _bends.intersection(spec.deforms);
    _blend = math.min(1.0, _blend + dt / beatsPer);
    // The continuous motions run faster the harder the music; the ones on the beat
    // (a bounce, a flip, a swing, a zoom over the phrase) stay on it.
    final step = _beatsWas < 0 || (beats - _beatsWas).abs() > 4 ? 0.0 : beats - _beatsWas;
    if (_beatsWas < 0) _phase = beats * spec.speed;
    _beatsWas = beats;
    _phase += step * spec.speed * (0.7 + 0.8 * drive);
    double clock(TypeMotion x) => _beatMotions.contains(x) ? beats * spec.speed : _phase;
    var pose = _motion(_motionNow!, clock(_motionNow!));
    if (_blend < 1 && _motionWas != null) pose = _motion(_motionWas!, clock(_motionWas!)).lerp(pose, _ease(_blend));

    final kick = (f['kick'] ?? 0).clamp(0.0, 1.0) * spec.beat;
    final snare = (f['snare'] ?? 0).clamp(0.0, 1.0) * spec.beat;
    final low = (f['low'] ?? 0).clamp(0.0, 1.0);
    _hat += ((f['hat'] ?? f['high'] ?? 0).clamp(0.0, 1.0) - _hat) * math.min(1.0, dt * 8);
    final energy = (f['dyn.energy'] ?? m.energy).clamp(0.0, 1.0);
    final ready = _slots[_on] != null;
    _fade = ready ? math.min(1.0, _fade + dt * 3) : 0;

    // The drop, remembered past the deck's two beats; a build, by the drop coming.
    final away = m.dropBeatsAway;
    if (playing && away != null && away <= 0 && away > -2.5 && (_awayWas == null || _awayWas! > 0)) _dropAt = beats + away;
    if (playing && m.section == 'drop' && _dropAt == null) _dropAt = beats;
    if (_dropAt != null && (beats - _dropAt! > 16 || beats < _dropAt! - 1)) _dropAt = null;
    _awayWas = away;
    final build = m.section == 'build' ? m.sectionK : (away != null && away > 0 && away < 16 ? 1 - away / 16 : 0.0);
    final burst = _dropAt == null ? 0.0 : math.exp(-(beats - _dropAt!) / 2.5);
    final phraseIn = beats % 16;

    // Each bend by its own part of the music, eased toward it (the slices not: torn
    // is torn at once).
    double target(TypeDeform d) {
      if (!_bends.contains(d)) return 0;
      return switch (d) {
        TypeDeform.inflate => 0.15 + 0.85 * kick,
        TypeDeform.ripple => 0.35 + 0.65 * low,
        TypeDeform.melt => _ease(phraseIn / 14) * (0.35 + 0.65 * (1 - energy)) * (m.breakdown ? 1.3 : 1),
        TypeDeform.slice => snare,
        TypeDeform.shatter => math.max(burst, math.max(0.35 * build, 0.3 * math.exp(-phraseIn * 1.2))),
        TypeDeform.wobble => 0.3 + 1.2 * _hat,
        TypeDeform.squash => 0.8 * kick,
        TypeDeform.arc => 0.35 * math.sin(math.pi * 2 * (beats % 4) / 4),
        TypeDeform.stack => 1,
        TypeDeform.repeat => 1,
      };
    }

    for (final d in TypeDeform.values) {
      final want = target(d) * spec.bend;
      final rate = d == TypeDeform.slice || d == TypeDeform.inflate || d == TypeDeform.squash ? 30.0 : 6.0;
      _bend[d.index] += (want - _bend[d.index]) * math.min(1.0, dt * rate);
    }
    double bent(TypeDeform d) => _bend[d.index].abs() < 1e-3 ? 0 : _bend[d.index];

    // The beat's accents, as hard as the music: a jolt round on every beat in a loud
    // part (aimed on the beat, got to in its first quarter), the horizon ticked on the
    // snare one way then the other, a whip once round on the drop.
    final beatNow = beats.floor();
    if (beatNow != _beatWas) {
      if (_beatWas >= 0 && drive > 0.5) _stepAim += 0.24 * (drive - 0.5) * 2;
      _beatWas = beatNow;
    }
    _stepYaw += (_stepAim - _stepYaw) * math.min(1.0, dt * 16);
    final whip = _dropAt == null ? 0.0 : math.pi * 2 * (1 - math.pow(burst, 0.6).toDouble());
    final tick = 0.08 * snare * drive * (beatNow.isEven ? 1 : -1);
    // Turned: yaw, then pitch, then roll (object to world); the shader wants the rows
    // of the way back, which are the columns of this.
    // The camera's travel through the shot in a loud part (CameraSweep), a new one every
    // few bars (every bar in a drop): round the letters, in at them, up over them.
    final sweepN = (beats / cutHold(16, drive)).floor();
    if (sweepN != _sweepN || dropLanded) {
      _sweepN = sweepN;
      _sweep.cut(beats, cutHold(16, drive), drive, memeHash(salt % 9973, sweepN, 323));
    }
    final sw = _sweep.at(beats, drive, dt);
    final yaw = pose.yaw + _stepYaw + whip - sw.yaw,
        pitch = pose.pitch + swapAngle + 1.4 * sw.rise,
        roll = pose.roll + tick + sw.roll;
    final cy = math.cos(yaw), sy = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch), cr = math.cos(roll), sr = math.sin(roll);
    // R = Ry · Rx · Rz
    final r00 = cy * cr + sy * sp * sr, r01 = -cy * sr + sy * sp * cr, r02 = sy * cp;
    final r10 = cp * sr, r11 = cp * cr, r12 = -sp;
    final r20 = -sy * cr + cy * sp * sr, r21 = sy * sr + cy * sp * cr, r22 = cy * cp;
    // world → object: the transpose
    _set3('uRotX', r00, r10, r20);
    _set3('uRotY', r01, r11, r21);
    _set3('uRotZ', r02, r12, r22);

    final a = _slots[0], bb = _slots[1];
    final shown = _slots[_on];
    final size = spec.size * (1 + 0.09 * kick) * _fade;
    final s = math.max(size, 1e-3);
    // The camera far enough that the wider of the two lines fills about four fifths
    // of the width.
    const fov = 1.7;
    final aspect = w / math.max(1, h);
    final widest = math.max(a?.halfX ?? 0, bb?.halfX ?? 0);
    final textHalfW = ((widest > 0 ? widest : (shown?.halfX ?? 1)) - TypeField.rangePx / TypeField.fontPx) * spec.size;
    final dist = math.max(2.2, math.max(textHalfW * fov / (0.8 * aspect * 0.5), 0.6 * spec.size * fov / 0.7));
    _set('uTime', _t);
    // The kick: the letters thrown at the camera a little, as hard as the music.
    final pos = (pose.x * dist * 0.5, pose.y * spec.size, (-dist + pose.z) * sw.dist + 0.16 * kick * drive * dist);
    _set3('uPos', pos.$1, pos.$2, pos.$3);
    _set2('uHalf', (a?.halfX ?? 1) * s, (a?.halfY ?? 0.5) * s);
    _set2('uHalfB', (bb?.halfX ?? 1) * s, (bb?.halfY ?? 0.5) * s);
    _set('uRange', (a?.range ?? 0.1) * s);
    _set('uRangeB', (bb?.range ?? 0.1) * s);
    _set('uMix', mix);
    _set('uMixMode', _turnHow == TypeTurn.glitch ? 1 : 0);
    _set('uSeed', (salt % 997).toDouble() * 0.37 + phrase * 1.3);
    _set('uDepth', 0.11 * spec.depth * size * (1 + 0.25 * low));
    _set('uBevel', math.min(0.02 * spec.bevel, 0.05) * size);
    _set('uWave', pose.wave * size);
    _set('uWavePhase', beats * math.pi);
    _set('uTwist', pose.twist / math.max((shown?.halfX ?? 1) * s, 0.2));
    _set4('uDeformA', bent(TypeDeform.inflate) * s, bent(TypeDeform.ripple), beats * math.pi * 2, bent(TypeDeform.melt) * s);
    _set4('uDeformB', bent(TypeDeform.slice) * s, bent(TypeDeform.shatter), bent(TypeDeform.wobble), bent(TypeDeform.squash).clamp(0.0, 1.5));
    // Repeated: the rows a line and a half apart.
    final repeat = bent(TypeDeform.repeat) > 0.5 ? (shown?.halfY ?? 0.5) * s * 2.2 : 0.0;
    _set4('uDeformC', bent(TypeDeform.arc) / s, bent(TypeDeform.stack).clamp(0.0, 1.0), (0.09 + 0.12 * kick) * s, repeat);
    _set('uLook', _look.index.toDouble());
    final (ink, ink2, rim) = _colours(spec.colour, st.palette);
    _setColour('uInk', ink);
    _setColour('uInk2', ink2);
    _setColour('uRim', rim);
    _set('uGlow', 0.6 * spec.glow * _fade);
    _set('uKick', kick);
    _set('uFlash', snare);
    _set('uFov', fov);
    // Seen from behind, or upside down: the letters turned back to be read (they
    // pass edge-on as it changes). The camera at the origin, in the object's space.
    final behind = -(r02 * pos.$1 + r12 * pos.$2 + r22 * pos.$3) < 0;
    final down = r11 < 0;
    _set2('uMirror', behind != down ? -1 : 1, down ? -1 : 1);
    // The ground: the native stage says (it binds its picture); the Flutter one has none.
    _set('uGroundOn', 0);
    _set('uPremul', upload == null ? 1 : 0);
    _v[0] = w.toDouble();
    _v[1] = h.toDouble();
    return _v;
  }

  /// A beat's seconds at a tempo of one.
  static const beat1 = 60.0;

  /// Ready to be drawn: on the native stage at once (it goes up as it comes on), here
  /// once its image is made.
  bool _ready(TypeField f) => upload != null || f.image != null;

  /// The field's image, for the Flutter stage (the native one takes the bytes).
  void _make(TypeField f) {
    if (upload != null) return;
    ui.decodeImageFromPixels(f.rgba, f.w, f.h, ui.PixelFormat.rgba8888, (img) {
      if (_made[f.key] == f) {
        f.image = img;
      } else {
        img.dispose();
      }
    });
  }

  /// The frame for the native stage: its numbers; the fields go up by [upload].
  Float32List native(ShowState st, double dt, int w, int h) => tick(st, dt, w, h);

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    final v = tick(st, dt, w, h);
    final program = p.sims['type3d'];
    final a = _slots[0]?.image, b = _slots[1]?.image;
    _out?.dispose();
    _out = null;
    if (program == null || (a == null && b == null)) return _out = _pass(w, h, (_) {});
    final fx = _fx ??= program.fragmentShader();
    for (var i = 0; i < v.length; i++) {
      fx.setFloat(i, v[i]);
    }
    // Bilinear: the field read between its texels, or every slant is a staircase.
    fx.setImageSampler(0, a ?? b!, filterQuality: FilterQuality.low);
    fx.setImageSampler(1, b ?? a!, filterQuality: FilterQuality.low);
    fx.setImageSampler(2, black);
    return _out = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx));
  }

  ui.Image get black => _black ??= _pass(2, 2, (_) {});

  ui.Image _pass(int w, int h, void Function(Canvas c) draw) {
    final r = ui.PictureRecorder();
    draw(Canvas(r));
    final pic = r.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  /// Waits for the lines being set (tests, the stills).
  @visibleForTesting
  Future<void> settled() async {
    while (_making.isNotEmpty) {
      await Future.wait(_making.values.toList());
    }
  }

  @override
  void dispose() {
    for (final f in _made.values) {
      f.dispose();
    }
    _made.clear();
    _slots.fillRange(0, 2, null);
    _out?.dispose();
    _out = null;
    _black?.dispose();
    _black = null;
    _fx?.dispose();
    _fx = null;
  }
}
