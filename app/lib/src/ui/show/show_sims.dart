// Simulations as layers: pictures that carry state from frame to frame, so what
// they show grows out of what came before and is never drawn twice the same.
//
// A scene lists one as `{"sim": "fluid"}`. Each frame the stage hands the sim the
// show's frame and gets back an image to lay over the scene; the sim keeps its own
// textures (or its own arrays) between frames and is thrown away when the scene
// changes. Two so far:
//
//   fluid    Stam's stable fluids in five shader passes at a quarter of the working
//            size: velocity and dye carried along, the divergence relaxed out by a
//            few rounds of Jacobi, the pressure's gradient taken off. The kick
//            pushes the fluid from a point that walks round the room; the bass
//            swirls it; the dye is the palette; a breakdown lets it dissolve.
//   physarum Slime mould: thousands of agents on the CPU, each sensing a trail
//            map ahead of it and turning towards the strongest scent, laying trail
//            as it goes; the trail fades and spreads. Veins and networks form on
//            their own and reorganise when the rules move — which the record does:
//            the section sets how far they look, the energy how fast they go, the
//            kick how much they lay.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/show_state.dart';
import 'show_canvas.dart' show StagePrograms;

abstract class SimLayer {
  String get kind;

  /// One frame: the sim moved on by [dt] seconds for a scene drawn at [w]×[h], and
  /// its picture, which the caller draws scaled to the scene. Null while it has
  /// nothing yet.
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p);

  void dispose();

  static SimLayer? make(String kind) => switch (kind) {
        'fluid' => FluidSim(),
        'physarum' => PhysarumSim(),
        _ => null,
      };
}

/// A pass: [draw] into a [w]×[h] picture, kept as an image.
ui.Image _pass(int w, int h, void Function(Canvas c) draw) {
  final r = ui.PictureRecorder();
  draw(Canvas(r));
  final pic = r.endRecording();
  final img = pic.toImageSync(w, h);
  pic.dispose();
  return img;
}

ui.Image _flat(int w, int h, Color c) => _pass(w, h, (cv) => cv.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = c));

ui.Image _shaded(int w, int h, ui.FragmentShader s) =>
    _pass(w, h, (cv) => cv.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = s));

// ------------------------------------------------------------------ fluid
class FluidSim implements SimLayer {
  @override
  String get kind => 'fluid';

  ui.Image? _vel, _dye, _pressure;
  int _w = 0, _h = 0;
  ui.FragmentShader? _advect, _div, _jacobi, _project, _look;
  final _rng = math.Random(5);
  double _kickWas = 0;
  double _pushX = 0.5, _pushY = 0.5, _pushDX = 0, _pushDY = 0, _pushK = 0;
  double _walk = 0;
  static const _jacobiRounds = 7;

  void _shaders(StagePrograms p) {
    _advect ??= p.sims['fluid_advect']!.fragmentShader();
    _div ??= p.sims['fluid_div']!.fragmentShader();
    _jacobi ??= p.sims['fluid_jacobi']!.fragmentShader();
    _project ??= p.sims['fluid_project']!.fragmentShader();
    _look ??= p.sims['fluid_look']!.fragmentShader();
  }

  void _size(int w, int h) {
    final sw = math.max(64, w ~/ 4), sh = math.max(36, h ~/ 4);
    if (sw == _w && sh == _h && _vel != null) return;
    _vel?.dispose();
    _dye?.dispose();
    _pressure?.dispose();
    _w = sw;
    _h = sh;
    // Nought, packed: see pack.glsl. (0.5, 0.5) in twelve bits each; 0.5 in twenty-four.
    _vel = _flat(sw, sh, const Color(0xff7ff7ff));
    _dye = _flat(sw, sh, Colors.black);
    _pressure = _flat(sw, sh, const Color(0xff7fffff));
  }

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    if (!p.sims.containsKey('fluid_advect')) return null;
    _shaders(p);
    _size(w, h);
    dt = dt.clamp(1 / 120, 1 / 30);
    final f = st.flat;
    // The kick's hit (show_dynamics.dart), not the raw kick: a leap above the floor,
    // so a quiet record pushes as hard as a loud one.
    final kick = f['dyn.hit.kick'] ?? f['audio.kick'] ?? 0;
    final snare = f['dyn.hit.snare'] ?? 0;
    final energy = f['dyn.energy'] ?? f['master.energy'] ?? 0;
    final low = f['dyn.band.low'] ?? f['audio.low'] ?? 0;
    final breakdown = (f['master.breakdown'] ?? 0) > 0.5;
    final sw = _w.toDouble(), sh = _h.toDouble();
    const vmax = 220.0;
    final g = st.genome;
    final swirlGene = g.isEmpty ? 1.0 : g['fluid.swirl'];
    final fadeGene = g.isEmpty ? 0.975 : g['fluid.fade'];
    final pushGene = g.isEmpty ? 1.0 : g['fluid.push'];

    // The push: on each kick's rising edge, from a point walking round a ring,
    // towards the middle (a drop lands in the middle) or away (a build pushes out).
    _walk += dt * 0.15;
    if (kick > 0.4 && kick > _kickWas + 0.2) {
      // Each push from the next place in a pattern round the room — left, right,
      // top, bottom by the beat of the bar — so the pushes are a rhythm, not a mess.
      final inBar = st.master.beatInBar ?? 0;
      final a = inBar * math.pi * 0.5 + _walk * 0.6 + (_rng.nextDouble() - 0.5) * 0.4;
      final rad = 0.26 + 0.1 * _rng.nextDouble();
      _pushX = 0.5 + math.cos(a) * rad * (sh / sw);
      _pushY = 0.5 + math.sin(a) * rad;
      final out = (f['master.build.k'] ?? 0) > 0.3;
      final dirX = (0.5 - _pushX) * (out ? -1 : 1), dirY = (0.5 - _pushY) * (out ? -1 : 1);
      final len = math.sqrt(dirX * dirX + dirY * dirY) + 1e-6;
      final strength = vmax * (0.8 + 1.2 * kick) * (0.6 + 0.4 * energy) * pushGene * (breakdown ? 0.6 : 1.0);
      _pushDX = dirX / len * strength;
      _pushDY = dirY / len * strength;
      _pushK = 1.0;
    } else {
      _pushK *= math.pow(0.05, dt).toDouble();
    }
    _kickWas = kick;

    final primary = st.palette.primary.withSaturation(0.95).withLightness(0.45).toColor();
    final secondary = st.palette.secondary.withSaturation(0.9).withLightness(0.45).toColor();
    // The dye poured in alternates between the palette's colours per push.
    final ink = [primary, secondary][(_walk * 7).floor() % 2];

    // 1. velocity advected, pushed, swirled.
    _advect!
      ..setFloat(0, sw)
      ..setFloat(1, sh)
      ..setFloat(2, dt)
      ..setFloat(3, breakdown ? 0.97 : 0.995)
      ..setFloat(4, 0)
      ..setFloat(5, vmax)
      ..setFloat(6, _pushX)
      ..setFloat(7, _pushY)
      ..setFloat(8, _pushDX)
      ..setFloat(9, _pushDY)
      ..setFloat(10, 0.05 + 0.03 * energy)
      ..setFloat(11, _pushK)
      ..setFloat(12, (8.0 + 40.0 * low + 30.0 * snare) * swirlGene)
      ..setFloat(13, st.now.millisecondsSinceEpoch / 1000 % 10000)
      ..setFloat(14, 0)
      ..setFloat(15, 0)
      ..setFloat(16, 0)
      ..setImageSampler(0, _vel!)
      ..setImageSampler(1, _vel!);
    final vel1 = _shaded(_w, _h, _advect!);

    // 2. divergence.
    _div!
      ..setFloat(0, sw)
      ..setFloat(1, sh)
      ..setFloat(2, vmax)
      ..setImageSampler(0, vel1);
    final div = _shaded(_w, _h, _div!);

    // 3. pressure, relaxed.
    var pressure = _pressure!;
    for (var i = 0; i < _jacobiRounds; i++) {
      _jacobi!
        ..setFloat(0, sw)
        ..setFloat(1, sh)
        ..setImageSampler(0, pressure)
        ..setImageSampler(1, div);
      final next = _shaded(_w, _h, _jacobi!);
      if (!identical(pressure, _pressure)) pressure.dispose();
      pressure = next;
    }
    _pressure!.dispose();
    _pressure = pressure;
    div.dispose();

    // 4. the gradient taken off.
    _project!
      ..setFloat(0, sw)
      ..setFloat(1, sh)
      ..setFloat(2, vmax)
      ..setImageSampler(0, vel1)
      ..setImageSampler(1, _pressure!);
    final vel2 = _shaded(_w, _h, _project!);
    vel1.dispose();
    _vel!.dispose();
    _vel = vel2;

    // 5. the dye carried along, more poured in at the push.
    _advect!
      ..setFloat(0, sw)
      ..setFloat(1, sh)
      ..setFloat(2, dt)
      // A breakdown keeps its dye longer (the pushes are weaker there), so the
      // room is not empty between kicks.
      ..setFloat(3, breakdown ? math.min(0.992, fadeGene + 0.01) : fadeGene)
      ..setFloat(4, 1)
      ..setFloat(5, vmax)
      ..setFloat(6, _pushX)
      ..setFloat(7, _pushY)
      ..setFloat(8, 0)
      ..setFloat(9, 0)
      ..setFloat(10, 0.035 + 0.02 * energy)
      ..setFloat(11, _pushK * 0.7)
      ..setFloat(12, 0)
      ..setFloat(13, 0)
      ..setFloat(14, ink.r)
      ..setFloat(15, ink.g)
      ..setFloat(16, ink.b)
      ..setImageSampler(0, _vel!)
      ..setImageSampler(1, _dye!);
    final dye = _shaded(_w, _h, _advect!);
    _dye!.dispose();
    _dye = dye;

    // 6. as light.
    _look!
      ..setFloat(0, sw)
      ..setFloat(1, sh)
      ..setFloat(2, (0.55 + 0.35 * energy) * (f['dyn.exposure'] ?? 0.8) * 1.2)
      ..setFloat(3, vmax)
      ..setFloat(4, secondary.r)
      ..setFloat(5, secondary.g)
      ..setFloat(6, secondary.b)
      ..setImageSampler(0, _dye!)
      ..setImageSampler(1, _vel!);
    return _shaded(_w, _h, _look!);
  }

  @override
  void dispose() {
    _vel?.dispose();
    _dye?.dispose();
    _pressure?.dispose();
    _advect?.dispose();
    _div?.dispose();
    _jacobi?.dispose();
    _project?.dispose();
    _look?.dispose();
  }
}

// ------------------------------------------------------------------ physarum
class PhysarumSim implements SimLayer {
  @override
  String get kind => 'physarum';

  static const agents = 9000;
  int _gw = 0, _gh = 0;
  late Float32List _trail, _next;
  final _x = Float32List(agents), _y = Float32List(agents), _a = Float32List(agents);
  final _rng = math.Random(9);
  Uint8List? _rgba;
  ui.Image? _picture;
  bool _decoding = false;
  double _kickWas = 0;
  double _exposure = 0.5;

  void _size(int w, int h) {
    final gw = math.max(48, w ~/ 4), gh = math.max(27, h ~/ 4);
    if (gw == _gw && gh == _gh) return;
    _gw = gw;
    _gh = gh;
    _trail = Float32List(gw * gh);
    _next = Float32List(gw * gh);
    _rgba = Uint8List(gw * gh * 4);
    for (var i = 0; i < agents; i++) {
      // Born everywhere, heading anywhere: the network is theirs to find.
      _x[i] = _rng.nextDouble() * gw;
      _y[i] = _rng.nextDouble() * gh;
      _a[i] = _rng.nextDouble() * math.pi * 2;
    }
  }

  int _cell(double x, double y) {
    var ix = x.floor(), iy = y.floor();
    if (ix < 0) ix = 0;
    if (ix >= _gw) ix = _gw - 1;
    if (iy < 0) iy = 0;
    if (iy >= _gh) iy = _gh - 1;
    return iy * _gw + ix;
  }

  double _sense(double x, double y) {
    var ix = x.floor() % _gw, iy = y.floor() % _gh;
    if (ix < 0) ix += _gw;
    if (iy < 0) iy += _gh;
    return _trail[iy * _gw + ix];
  }

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    _watch.start();
    _size(w, h);
    final f = st.flat;
    final kick = f['audio.kick'] ?? 0;
    final energy = f['master.energy'] ?? 0;
    final breakdown = (f['master.breakdown'] ?? 0) > 0.5;
    final section = st.master.section;
    // The rules, from the record: how far ahead they look and how wide (the
    // section), how fast they go (the energy), how much they lay (the kick).
    final g = st.genome;
    final lookGene = g.isEmpty ? 7.0 : g['veins.look'];
    final look = lookGene * switch (section) { 'breakdown' || 'break' => 1.3, 'build' => 0.6, 'drop' => 0.85, _ => 1.0 };
    final wide = (g.isEmpty ? 0.4 : g['veins.wide']) * switch (section) { 'breakdown' || 'break' => 0.75, 'drop' => 1.5, _ => 1.0 };
    final turn = (g.isEmpty ? 0.3 : g['veins.turn']) + 0.25 * energy;
    final speed = (0.25 + 0.45 * energy) * (dt * 60).clamp(0.5, 2.0);
    final lay = 0.6 + 0.8 * kick;
    final hit = kick > 0.45 && kick > _kickWas + 0.2;
    _kickWas = kick;

    final gw = _gw, gh = _gh;
    for (var i = 0; i < agents; i++) {
      var x = _x[i], y = _y[i], a = _a[i];
      final c = _sense(x + math.cos(a) * look, y + math.sin(a) * look);
      final l = _sense(x + math.cos(a - wide) * look, y + math.sin(a - wide) * look);
      final r = _sense(x + math.cos(a + wide) * look, y + math.sin(a + wide) * look);
      if (c > l && c > r) {
        // straight on
      } else if (c < l && c < r) {
        a += (_rng.nextBool() ? turn : -turn);
      } else if (l > r) {
        a -= turn;
      } else if (r > l) {
        a += turn;
      }
      // A little waywardness every step, or they all fall into one line; a kick
      // scatters them more, and the network shivers and re-forms. On a cell already
      // thick with trail an agent turns hard away: a vein that is full is left for a
      // new one, which is what keeps a network a network and not one worm.
      // Float32 rounding can put a wrapped position exactly on the edge: clamped.
      final here = _trail[_cell(x, y)];
      a += (_rng.nextDouble() - 0.5) * (hit ? 1.4 : here > 1.2 ? 2.4 : 0.3);
      // And now and then one is born again somewhere else.
      if (_rng.nextDouble() < 0.0004) {
        x = _rng.nextDouble() * gw;
        y = _rng.nextDouble() * gh;
        a = _rng.nextDouble() * math.pi * 2;
      }
      x += math.cos(a) * speed;
      y += math.sin(a) * speed;
      if (x < 0) x += gw;
      if (x >= gw) x -= gw;
      if (y < 0) y += gh;
      if (y >= gh) y -= gh;
      _x[i] = x;
      _y[i] = y;
      _a[i] = a;
      final idx = _cell(x, y);
      _trail[idx] = math.min(_trail[idx] + lay * 0.15, 2.0);
    }

    // The trail fades and spreads: a 3×3 mean, then the decay — slower in a
    // breakdown, so the old network lingers as a ghost.
    final decayGene = g.isEmpty ? 0.86 : g['veins.decay'];
    final decay = breakdown ? decayGene + 0.05 : decayGene;
    for (var y = 0; y < gh; y++) {
      final up = ((y - 1 + gh) % gh) * gw, row = y * gw, down = ((y + 1) % gh) * gw;
      for (var x = 0; x < gw; x++) {
        final xl = (x - 1 + gw) % gw, xr = (x + 1) % gw;
        final sum = _trail[up + xl] + _trail[up + x] + _trail[up + xr]
            + _trail[row + xl] + _trail[row + x] + _trail[row + xr]
            + _trail[down + xl] + _trail[down + x] + _trail[down + xr];
        _next[row + x] = sum / 9 * decay;
      }
    }
    final t = _trail;
    _trail = _next;
    _next = t;

    // As a picture: the trail through the palette, thin veins in the primary, the
    // thick ones towards the accent.
    final primary = st.palette.primary.toColor();
    final accent = st.palette.accent.toColor();
    final rgba = _rgba!;
    // Exposed to the trail as it is now: the veins are read against the brightest
    // of them, not against a fixed scale that a thin network never reaches.
    var top = 0.0;
    for (var i = 0; i < gw * gh; i++) {
      if (_trail[i] > top) top = _trail[i];
    }
    _exposure = _exposure * 0.9 + math.max(top, 0.05) * 0.1;
    final scale = 1.0 / (_exposure * 0.7);
    for (var i = 0; i < gw * gh; i++) {
      final v = _trail[i] * scale;
      final k = v.clamp(0.0, 1.0);
      final kk = math.pow(k, 1.6).toDouble() * 0.9;
      final mixK = (v * 0.6).clamp(0.0, 1.0);
      rgba[i * 4] = ((primary.r * (1 - mixK) + accent.r * mixK) * 255 * kk).round().clamp(0, 255);
      rgba[i * 4 + 1] = ((primary.g * (1 - mixK) + accent.g * mixK) * 255 * kk).round().clamp(0, 255);
      rgba[i * 4 + 2] = ((primary.b * (1 - mixK) + accent.b * mixK) * 255 * kk).round().clamp(0, 255);
      rgba[i * 4 + 3] = 255;
    }
    if (!_decoding) {
      _decoding = true;
      ui.decodeImageFromPixels(Uint8List.fromList(rgba), gw, gh, ui.PixelFormat.rgba8888, (img) {
        _decoding = false;
        // The scene may have moved on while the picture was being made.
        if (_disposed) {
          img.dispose();
          return;
        }
        _picture?.dispose();
        _picture = img;
      });
    }
    _watch.stop();
    if (++_frames % 120 == 0) {
      // ignore: avoid_print
      print('VEINS ${(_watch.elapsedMicroseconds / 120 / 1000).toStringAsFixed(1)} ms a frame, $agents agents on ${gw}x$gh');
      _watch.reset();
    }
    return _picture;
  }

  final _watch = Stopwatch();
  int _frames = 0;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _picture?.dispose();
    _picture = null;
  }
}
