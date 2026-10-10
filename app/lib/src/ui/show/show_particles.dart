// Particles over a scene: a few hundred soft points of light, moved on the CPU
// and stamped in one drawAtlas, added to the scene's light before the trails and
// the bloom — so they leave trails and glow like everything else.
//
// Four kinds, each a few rules: sparks burst from the middle on the kick and fall
// away; dust drifts up slowly and twinkles, always there; rise is streaks climbing
// faster as a build rises; rain falls with the top end. Everything is in the
// working picture's pixels, so a system is told the size each frame.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/show_state.dart';

class _P {
  double x = 0, y = 0, vx = 0, vy = 0, life = 0, age = 0, size = 1, seed = 0;
  bool get alive => age < life;
}

/// The one sprite: a soft disc, made once.
ui.Image _sprite() {
  const n = 48.0;
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  c.drawCircle(
    const Offset(n / 2, n / 2),
    n / 2,
    Paint()
      ..shader = ui.Gradient.radial(const Offset(n / 2, n / 2), n / 2, [
        Colors.white,
        Colors.white.withValues(alpha: 0.55),
        Colors.white.withValues(alpha: 0.0),
      ], [0.0, 0.25, 1.0]),
  );
  final pic = r.endRecording();
  final img = pic.toImageSync(n.toInt(), n.toInt());
  pic.dispose();
  return img;
}

ui.Image? _shared;
ui.Image get particleSprite => _shared ??= _sprite();
const _spriteSize = 48.0;

class ParticleSystem {
  ParticleSystem(this.kind, {int seed = 11}) : _rng = math.Random(seed);

  final String kind;
  final math.Random _rng;
  final _ps = <_P>[];
  double _kickWas = 0;
  double _dustDebt = 0;

  int get count => _ps.length;
  static const most = 600;

  /// One frame: moved on by [dt] seconds in a [w]×[h] picture, by the frame [st].
  void step(ShowState st, double dt, int w, int h) {
    if (dt <= 0 || dt > 0.25) {
      dt = 1 / 60;
    }
    final f = st.flat;
    final kick = f['audio.kick'] ?? 0;
    final energy = f['master.energy'] ?? 0;
    switch (kind) {
      case 'sparks':
        // A burst on each kick's rising edge, bigger for a bigger kick.
        if (kick > 0.45 && kick > _kickWas + 0.2) {
          final n = (14 + 50 * kick * (0.5 + 0.5 * energy)).round();
          for (var i = 0; i < n && _ps.length < most; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final sp = (0.12 + 0.5 * _rng.nextDouble()) * h * (0.6 + kick);
            _ps.add(_P()
              ..x = w / 2 + (_rng.nextDouble() - 0.5) * h * 0.04
              ..y = h / 2 + (_rng.nextDouble() - 0.5) * h * 0.04
              ..vx = math.cos(a) * sp
              ..vy = math.sin(a) * sp
              ..life = 0.5 + _rng.nextDouble() * 0.9
              ..size = (0.5 + _rng.nextDouble()) * h * 0.012
              ..seed = _rng.nextDouble());
          }
        }
        _kickWas = kick;
      case 'dust':
        // A steady population, drifting up and sideways, slowly.
        final want = 90 + (60 * energy).round();
        _dustDebt += (want - _ps.length).clamp(0, 40) * dt * 2;
        while (_dustDebt >= 1 && _ps.length < most) {
          _dustDebt -= 1;
          _ps.add(_P()
            ..x = _rng.nextDouble() * w
            ..y = _rng.nextDouble() * h
            ..vx = (_rng.nextDouble() - 0.5) * h * 0.02
            ..vy = -(0.01 + 0.03 * _rng.nextDouble()) * h
            ..life = 6 + _rng.nextDouble() * 8
            ..size = (0.2 + 0.8 * _rng.nextDouble()) * h * 0.005
            ..seed = _rng.nextDouble());
        }
      case 'rise':
        final up = math.max(f['master.build.k'] ?? 0, f['master.drop.near'] ?? 0);
        final rate = 10 + 160 * up * up;
        _dustDebt += rate * dt;
        while (_dustDebt >= 1 && _ps.length < most) {
          _dustDebt -= 1;
          _ps.add(_P()
            ..x = _rng.nextDouble() * w
            ..y = h + 10
            ..vx = 0
            ..vy = -(0.25 + 0.9 * up + 0.5 * _rng.nextDouble()) * h
            ..life = 1.2 + _rng.nextDouble()
            ..size = (0.3 + 0.5 * _rng.nextDouble()) * h * 0.008
            ..seed = _rng.nextDouble());
        }
      case 'rain':
        final top = f['audio.high'] ?? 0;
        _dustDebt += (5 + 120 * top) * dt;
        while (_dustDebt >= 1 && _ps.length < most) {
          _dustDebt -= 1;
          _ps.add(_P()
            ..x = _rng.nextDouble() * w
            ..y = -10
            ..vx = (_rng.nextDouble() - 0.5) * h * 0.05
            ..vy = (0.4 + 0.6 * _rng.nextDouble()) * h
            ..life = 1.5 + _rng.nextDouble()
            ..size = (0.2 + 0.3 * _rng.nextDouble()) * h * 0.006
            ..seed = _rng.nextDouble());
        }
    }
    // Everyone moves; sparks fall and slow, dust wanders.
    for (final p in _ps) {
      p.age += dt;
      switch (kind) {
        case 'sparks':
          p.vx *= math.pow(0.35, dt).toDouble();
          p.vy = p.vy * math.pow(0.35, dt).toDouble() + h * 0.25 * dt;
        case 'dust':
          p.vx += math.sin(p.age * 0.7 + p.seed * 9) * h * 0.004 * dt;
        default:
          break;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
    }
    _ps.removeWhere((p) => !p.alive || p.y < -40 || p.y > h + 40 || p.x < -40 || p.x > w + 40);
  }

  /// Stamped onto [canvas], added as light, in [primary]/[accent].
  void draw(Canvas canvas, Color primary, Color accent, double t) {
    if (_ps.isEmpty) return;
    final transforms = <RSTransform>[];
    final rects = <Rect>[];
    final colors = <Color>[];
    const src = Rect.fromLTWH(0, 0, _spriteSize, _spriteSize);
    for (final p in _ps) {
      final k = p.age / p.life;
      double alpha;
      double size = p.size;
      switch (kind) {
        case 'sparks':
          alpha = (1 - k) * (1 - k);
          size *= 1 + k * 0.5;
        case 'dust':
          alpha = math.sin(k * math.pi) * (0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * (1 + p.seed * 2) + p.seed * 20)));
        case 'rise':
          alpha = math.sin(k * math.pi);
          size *= 2.2;
        default:
          alpha = math.sin(k * math.pi) * 0.8;
      }
      if (alpha <= 0.01) continue;
      final colour = Color.lerp(primary, accent, p.seed)!.withValues(alpha: alpha.clamp(0.0, 1.0));
      final scale = size * 2 / _spriteSize;
      transforms.add(RSTransform.fromComponents(
        rotation: 0,
        scale: scale,
        anchorX: _spriteSize / 2,
        anchorY: _spriteSize / 2,
        translateX: p.x,
        translateY: p.y,
      ));
      rects.add(src);
      colors.add(colour);
    }
    if (transforms.isEmpty) return;
    canvas.drawAtlas(particleSprite, transforms, rects, colors, BlendMode.modulate, null,
        Paint()..blendMode = BlendMode.plus);
  }
}
