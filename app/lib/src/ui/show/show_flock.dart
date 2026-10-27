// The murmuration: a flock of birds, simulated live and drawn on the record's grid —
// starlings at dusk, near a thousand of them, turning as one.
//
// Each bird is a boid (Reynolds): it keeps clear of the birds nearest it, flies the
// way they fly and toward where they are, and from those three rules alone a flock
// forms, splits and turns in waves. Over them the record steers:
//
//   the kick      every hit pulls the flock in on itself — a breath in on the beat,
//                 out between — and pulls the wingbeats into step for a moment;
//   the snare     a startle: one side of the flock jolts and the ripple runs through;
//   the downbeat  a new place to fly to, so the whole flock swings on the bar;
//   the drop      the flock bursts apart and gathers again over two bars;
//   the phrase    where the flock is going (its flight) is chosen four bars at a time.
//
// The flights (Flight), chosen by the mood (show_meme.dart's moods) and hashed from
// the record, so a record flies the same way twice:
//
//   murmur   free: the flock follows a slow waypoint and does what a flock does;
//   vortex   a column of birds circling, a wave running round it;
//   ribbon   a stream of birds strung along a looping path, one loop a phrase, so a
//            seek lands at the same place;
//   vee      skeins: a few hundred birds in V lines gliding across the sky (asleep);
//   sphere   the flock settles on a globe that turns and breathes with the beat;
//   sheet    a curtain of birds, a wave crossing it once a bar;
//   twin     two flocks orbiting each other, passing through each other on the bar.
//
// The looks (FlockLook), one a section, as the stylised dancer's renderings:
//
//   ink      flat silhouettes, light on black (the white background makes the page);
//   sky      a dusk sky, a low sun that flares on the kick, the birds black against it;
//   embers   points of light, ribbons of their last moments behind them;
//   neon     each bird a neon chevron;
//   wire     a plexus: dots joined to their neighbours where they are close — the
//            net knits on the kick, when the flock pulls in;
//   chrono   a chronophotograph: the flock stamped every half beat, the older dim;
//   ascii, dither, contour, halftone, thermal, lines
//            the flock's light finished by flock_fx.frag, as the dancer's;
//   radar    a radar's sweep, one turn a bar, lighting the birds as it passes.
//
// The birds are a pigeon: a scan of a museum study skin with wings modelled onto it
// (show_flock_bird.dart), moved, flapped, projected and lit on the CPU and drawn in one
// draw per level of detail — textured near, in the scan's colours farther off, as
// silhouettes, chrome or lit as the look asks, the way the dancer is drawn. Until the
// scan is in, the birds are chevrons.
//
// The camera is still, in front, and cuts (never glides) to another framing after a
// while, on a drop and on a new section. Everything is drawn on a plain canvas, which
// Impeller takes in its stride; the cost is the CPU's, a few milliseconds for the
// flock's rules and the birds' vertices.
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/show_state.dart';
import '../../state/show/show_tune.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_common.dart' show crtInk, crtPaper, setFxKnobs, styleIsStage, tunedCell;
import 'show_dance.dart' show DanceHandoff;
import 'show_dance_draw.dart' show DanceCam, V3;
import 'show_flock_bird.dart';
import 'show_flock_surface.dart';
import 'show_meme.dart' show MemeClock;
import 'show_meme_bank.dart' show MemeMood, memeHash;
import 'show_particles.dart' show particleSprite;
import '../../state/show/show_pool.dart' show QualityPool, StylePool, pickByWeight;
import '../../state/show/show_rig.dart' show Figure;
import 'show_sims.dart';
import 'stage_camera.dart';

/// Where the flock is going, four bars at a time.
enum Flight { murmur, vortex, ribbon, vee, sphere, sheet, twin }

/// How the flock is rendered, a section at a time.
enum FlockLook { ink, sky, embers, neon, wire, chrono, ascii, dither, contour, halftone, thermal, lines, radar, crt }

/// Where the camera is: still, in front, framed wide or close, low (looking up at
/// the sky) or high (looking down on the flock) — or a fisheye inside the flock
/// (fish), or on the floor under it looking straight up through it (fishLow): a
/// 160° lens, the birds looming past.
enum FlockShot { wide, front, low, high, fish, fishLow }

/// The looks finished by flock_fx.frag, and its mode for each.
const flockFxMode = {
  FlockLook.ascii: 1,
  FlockLook.dither: 2,
  FlockLook.contour: 3,
  FlockLook.halftone: 4,
  FlockLook.thermal: 5,
  FlockLook.lines: 6,
  FlockLook.radar: 7,
  FlockLook.sky: 8,
  // Not flock_fx's: dance_fx.frag's crt, the one every scene goes through.
  FlockLook.crt: 8,
};

/// The flock's arithmetic, apart from any drawing.
class FlockClock {
  const FlockClock._();

  /// Track beats a flight is kept: four bars.
  static const flightBeats = 16;

  /// The flight for the [n]th slot in [mood]: the calm ones asleep, the big ones in
  /// a drop; never [not] again.
  static Flight flight(MemeMood mood, int salt, int n, {Flight? not}) {
    final pool = switch (mood) {
      MemeMood.sleep => [Flight.vee, Flight.murmur, Flight.ribbon, Flight.sheet, Flight.vee, Flight.murmur],
      MemeMood.wake => [Flight.murmur, Flight.vortex, Flight.ribbon, Flight.sphere, Flight.murmur],
      MemeMood.rage => [Flight.vortex, Flight.sphere, Flight.twin, Flight.murmur, Flight.sheet, Flight.vortex],
      MemeMood.vibe => [Flight.murmur, Flight.ribbon, Flight.vortex, Flight.twin, Flight.sheet, Flight.murmur],
    };
    return _pick(pool, memeHash(salt % 9973, n, 113), not);
  }

  /// The look for the [n]th section in [mood]: the quiet ones asleep, the ones that
  /// move in a drop, any between; never [not] again.
  static FlockLook look(MemeMood mood, int salt, int n, {FlockLook? not}) {
    final all = switch (mood) {
      MemeMood.sleep => [FlockLook.ink, FlockLook.sky, FlockLook.contour, FlockLook.lines, FlockLook.wire, FlockLook.dither, FlockLook.embers, FlockLook.sky],
      MemeMood.wake => [FlockLook.ascii, FlockLook.dither, FlockLook.wire, FlockLook.embers, FlockLook.neon, FlockLook.thermal, FlockLook.radar, FlockLook.sky],
      MemeMood.rage => [FlockLook.embers, FlockLook.neon, FlockLook.chrono, FlockLook.thermal, FlockLook.halftone, FlockLook.radar, FlockLook.ink, FlockLook.wire],
      MemeMood.vibe => FlockLook.values,
    };
    // The image treatments are the conductor's (the frame's rig's treatment), as
    // for every scene: this clock picks the flock's own — those switched on, and
    // that the rules let stand on the ground on now (the white paper and the sky off
    // MilkDrop).
    final pool = [for (final l in all) if (!treatmentFxMode.containsKey(l.name) && StylePool.allows(Figure.birds, l.name)) l];
    if (pool.isEmpty) return not ?? FlockLook.ink;
    // As likely as the hands want each (how often).
    final d = memeHash(salt % 9973, n, 127);
    var l = StylePool.pick(pool, d, (x) => StylePool.weight(Figure.birds, x.name))!;
    if (l == not && pool.length > 1) l = pool[(pool.indexOf(l) + 1) % pool.length];
    return l;
  }

  static T _pick<T>(List<T> pool, double d, T? not) {
    var a = pool[(d * pool.length).floor() % pool.length];
    if (a == not && pool.any((x) => x != not)) {
      var i = pool.indexOf(a);
      do {
        i = (i + 1) % pool.length;
      } while (pool[i] == not);
      a = pool[i];
    }
    return a;
  }

  /// The camera for cut [cut] in [mood] on [look]: the sky from below or wide, the
  /// radar from above (a plan), the rest in front, wide or closer. [weight] leans
  /// each framing (the camera's rules, StylePool.shot); where it has every one the
  /// look and the mood allow at nought, any other it has not, else wide.
  static FlockShot shot(MemeMood mood, int salt, int cut, FlockLook look, {double Function(FlockShot)? weight}) {
    final d = memeHash(salt % 9973, cut, 131);
    double w(FlockShot s) => weight == null ? 1 : weight(s);
    final pick = switch (look) {
      FlockLook.sky => [FlockShot.low, FlockShot.wide, FlockShot.low, FlockShot.front],
      FlockLook.radar => [FlockShot.high, FlockShot.high, FlockShot.wide],
      FlockLook.chrono => [FlockShot.wide, FlockShot.front],
      _ => switch (mood) {
          MemeMood.sleep => [FlockShot.wide, FlockShot.front, FlockShot.low],
          MemeMood.rage => [FlockShot.front, FlockShot.wide, FlockShot.fish, FlockShot.front, FlockShot.high, FlockShot.fishLow],
          _ => [FlockShot.wide, FlockShot.front, FlockShot.wide, FlockShot.low, FlockShot.fish, FlockShot.high],
        },
    };
    return pickByWeight([for (final s in pick) (s, w(s))], d) ?? pickByWeight([for (final s in FlockShot.values) (s, w(s))], d) ?? FlockShot.wide;
  }

  /// How many beats a camera holds: long, and shorter in the drop.
  static int hold(MemeMood mood) => switch (mood) {
        MemeMood.rage => 16,
        MemeMood.sleep => 64,
        _ => 32,
      };

  /// How fast the birds fly, in metres a second: a glide asleep, a rush in the drop,
  /// warming through a build ([wakeK] 0..1 toward the drop).
  static double speed(MemeMood mood, {double wakeK = 0, double energy = 0.5}) => switch (mood) {
        MemeMood.sleep => 1.4,
        MemeMood.wake => 2.3 + 1.3 * wakeK,
        MemeMood.rage => 3.6 + 0.6 * energy,
        MemeMood.vibe => 2.1 + 0.8 * energy,
      };

  /// The pace along the path at [phase] of the beat (0..1), as a share of the
  /// flock's speed: a push on the beat that eases off to a drift before the next,
  /// one on average so the flock goes no further than it would. The wings keep
  /// their own time; only the way through the air is on the beat.
  static double surge(MemeMood mood, double phase) {
    final k = switch (mood) {
      MemeMood.sleep => 0.15,
      MemeMood.wake => 0.32,
      MemeMood.vibe => 0.38,
      MemeMood.rage => 0.5,
    };
    // e^-4ph over its own mean over the beat ((1 - e^-4) / 4).
    final push = math.exp(-4 * phase.clamp(0.0, 1.0)) / 0.24542;
    return 1 + k * (push - 1);
  }

  /// Wingbeats a track beat: one; two in the drop; a flap every fourth beat asleep,
  /// gliding between.
  static double flapsPerBeat(MemeMood mood) => switch (mood) {
        MemeMood.sleep => 0.25,
        MemeMood.rage => 2,
        _ => 1,
      };

  /// How many birds fly [flight] in [mood] under [look]: skeins are a few hundred, a
  /// stream several, the rest the whole flock; fewer when it is quiet, and fewer
  /// where every bird is drawn as itself (ink, a chevron, a dot) than where they
  /// are a cloud of light.
  static int count(Flight flight, MemeMood mood, double energy, {FlockLook? look}) {
    final base = switch (flight) {
      Flight.vee => 270,
      Flight.ribbon => 720,
      Flight.sheet => 800,
      _ => FlockModel.most,
    };
    // (The pigeons cost by the vertex: the looks that draw them keep to a few hundred.)
    final drawn = switch (look) {
      FlockLook.ink || FlockLook.sky => 0.42,
      FlockLook.neon || FlockLook.wire || FlockLook.chrono || FlockLook.embers => 0.42,
      FlockLook.ascii || FlockLook.dither || FlockLook.halftone => 0.42,
      FlockLook.radar => 0.8,
      _ => 1.0,
    };
    final k = (mood == MemeMood.sleep ? 0.6 : 0.75 + 0.25 * energy.clamp(0.0, 1.0)) * drawn * QualityPool.flockK;
    return (base * k).round().clamp(120, FlockModel.most);
  }

  /// How hard the kick pulls the flock in, by mood.
  static double kickPull(MemeMood mood, {double wakeK = 0}) => switch (mood) {
        MemeMood.sleep => 0.0,
        MemeMood.wake => 0.22 + 0.25 * wakeK,
        MemeMood.rage => 0.6,
        MemeMood.vibe => 0.38,
      };
}

/// A camera placed: round the flock by [yaw] (0 straight in front), at [height],
/// [dist] from the flock's middle, looking at [aim] high, [fov] wide.
class FlockFrame {
  const FlockFrame(this.yaw, this.height, this.dist, this.aim, this.fov, [this.fisheye = 0, this.roll = 0]);
  final double yaw, height, dist, aim, fov;

  /// A fisheye lens (DanceCam.fisheye), 0..1.
  final double fisheye;

  static FlockFrame of(FlockShot s) => switch (s) {
        FlockShot.wide => const FlockFrame(0.0, 3.2, 13.0, 3.3, 0.62),
        FlockShot.front => const FlockFrame(0.0, 3.4, 10.5, 3.4, 0.60),
        FlockShot.low => const FlockFrame(0.0, 0.5, 8.5, 4.0, 0.74),
        FlockShot.high => const FlockFrame(0.06, 8.0, 11.0, 2.4, 0.64),
        // Inside the flock, a 160° lens: the birds loom past the glass.
        FlockShot.fish => const FlockFrame(0.3, 3.0, 2.4, 3.3, 2.8, 1),
        // On the floor under it, looking straight up through it.
        FlockShot.fishLow => const FlockFrame(0.0, 0.3, 0.9, 5.0, 2.9, 1),
      };

  /// Where [s] has taken this framing (CameraSweep): never below the ground.
  FlockFrame swept(SweepMove s) => s == CameraSweep.none
      ? this
      : FlockFrame(yaw + s.yaw, math.max(0.2, height + s.rise * dist), dist * s.dist, aim, fov, fisheye, s.roll);

  /// The horizon tipped (radians).
  final double roll;

  DanceCam cam(Size size) {
    const c = FlockModel.centre;
    final eye = V3(c.x + math.sin(yaw) * dist, c.y - math.cos(yaw) * dist, height);
    return DanceCam(eye: eye, target: V3(c.x, c.y, aim), size: size, fov: fov, fisheye: fisheye, roll: roll);
  }
}

/// What one step of the flock is told: the time, the grid, the mood's numbers and
/// the moments (a kick's edge, a snare's, the drop's burst).
class FlockSteer {
  FlockSteer({
    required this.dt,
    required this.beats,
    required this.beatsPerSecond,
    required this.speed,
    required this.want,
    required this.flight,
    this.flightWas,
    this.flightK = 1,
    this.barSaw = 0,
    this.phraseSaw = 0,
    this.beatDecay = 0,
    this.kick = 0,
    this.snare = 0,
    this.burst = 0,
    this.cohesion = 1,
    this.spin = 1,
    this.flapsPerBeat = 1,
    this.flapAmp = 0.75,
    this.glide = false,
    this.linkR = 1.0,
    this.waySalt = 0,
    this.roomK = 1,
    this.surge = 1,
  });

  final double dt, beats, beatsPerSecond, speed;

  /// How far along their way the birds go this step, as a share of their velocity:
  /// the beat's push (FlockClock.surge). Not their wingbeats.
  final double surge;

  /// How many birds should be flying.
  final int want;

  /// The flight, and the one before while they blend ([flightK] 0..1 toward the new).
  final Flight flight;
  final Flight? flightWas;
  final double flightK;
  final double barSaw, phraseSaw, beatDecay;

  /// A kick's hit this frame (its rising edge, 0..1), a snare's, the drop's burst.
  final double kick, snare, burst;

  /// How much the flock holds together (1 normal; more while it gathers after a burst).
  final double cohesion;

  /// Which way a vortex turns.
  final double spin;
  final double flapsPerBeat, flapAmp;

  /// Asleep: half the birds glide instead of flapping.
  final bool glide;

  /// How close two birds must be to be joined by the wire look, metres.
  final double linkR;

  /// The record, for the waypoints' hashes.
  final int waySalt;

  /// How much the room holds the birds (its edges, the pull to its middle), 0..1:
  /// none while they are still the dancer's shape.
  final double roomK;
}

/// The flock's rules and numbers: the birds' places, speeds and wingbeats, moved on
/// a frame at a time. Nothing drawn.
class FlockModel {
  // Its own seed: not the fluid's (5), so the two never move in step.
  FlockModel({int seed = 23}) : _rng = math.Random(seed) {
    for (var i = 0; i < most; i++) {
      seedOf[i] = _rng.nextDouble();
      size[i] = 0.8 + 0.4 * _rng.nextDouble();
      group[i] = i & 1;
      _born(i, centre.x, centre.y, centre.z, 2.4, 1.6, 0.3, 0.1);
      alpha[i] = i < 700 ? 1 : 0;
    }
  }

  static const most = 960;
  static const centre = V3(0, 1, 3.2);
  static const _xlo = -5.6, _xhi = 5.6, _ylo = -2.0, _yhi = 3.8, _zlo = 0.6, _zhi = 6.2;
  static const _cell = 1.1;
  static const _gx = 13, _gy = 8, _gz = 8;

  /// How far a bird senses the others, how close is too close, how many it heeds.
  static const sense = 1.3, personal = 0.8;

  /// How many neighbours a bird heeds at most (the nearest cells' first).
  static int heed = 22;

  /// The cells round a bird's own, in pairs that mirror each other, the nearest
  /// first: the scan stops once it has heeded enough, and only between pairs, so
  /// the birds it heeds are never all from below or in front — which pushed the
  /// whole flock up and back.
  static const _around = [
    0, 0, 0, //
    1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, //
    1, 1, 0, -1, -1, 0, 1, -1, 0, -1, 1, 0, //
    1, 0, 1, -1, 0, -1, 1, 0, -1, -1, 0, 1, //
    0, 1, 1, 0, -1, -1, 0, 1, -1, 0, -1, 1, //
    1, 1, 1, -1, -1, -1, 1, 1, -1, -1, -1, 1, 1, -1, 1, -1, 1, -1, 1, -1, -1, -1, 1, 1, //
  ];

  /// How hard the rules pull: toward the neighbours' middle, along their way, apart.
  /// (Tuned on a run of 800: a spread of two to three metres, pulsing; a kick's pull
  /// of 0.6 draws it in by a fifth.)
  static const cohesionW = 0.32, alignW = 2.4, apartW = 2.6;

  final math.Random _rng;
  final px = Float32List(most), py = Float32List(most), pz = Float32List(most);
  final vx = Float32List(most), vy = Float32List(most), vz = Float32List(most);
  final _ax = Float32List(most), _ay = Float32List(most), _az = Float32List(most);
  final _sp = Float32List(most);

  /// Each bird's wingbeat offset (turns), its own number, its size (0.8..1.2), and
  /// how far in it is (0 not flying, 1 flying).
  final flapOff = Float32List(most), seedOf = Float32List(most), size = Float32List(most), alpha = Float32List(most);
  final group = Uint8List(most);

  /// The three nearest neighbours of each bird within FlockSteer.linkR (-1 for none),
  /// and how far, for the wire look.
  final link = Int32List(most * 3);
  final linkD = Float32List(most * 3);

  final _head = Int32List(_gx * _gy * _gz), _next = Int32List(most);
  final _f1 = Float64List(3), _f2 = Float64List(3), _t1 = Float64List(3), _t2 = Float64List(3);

  /// The flock's middle (the mean of the birds flying), and how many fly.
  double cx = centre.x, cy = centre.y, cz = centre.z;
  int flying = 0;

  /// Each half's middle (the twin flight's two flocks).
  final gcx = Float64List(2), gcy = Float64List(2), gcz = Float64List(2);
  final _gn = Int32List(2);

  /// The murmuration's waypoint, and where it is easing to.
  double _wx = centre.x, _wy = centre.y, _wz = centre.z;
  double _twx = centre.x, _twy = centre.y, _twz = centre.z;
  int _wayBar = -1;
  double _windX = 0, _windY = 0, _windZ = 0;
  int _snares = 0;

  void _born(int i, double x, double y, double z, double spread, double mvx, double mvy, double mvz) {
    px[i] = x + (_rng.nextDouble() - 0.5) * spread;
    py[i] = y + (_rng.nextDouble() - 0.5) * spread * 0.6;
    pz[i] = z + (_rng.nextDouble() - 0.5) * spread * 0.7;
    vx[i] = mvx + (_rng.nextDouble() - 0.5) * 0.8;
    vy[i] = mvy + (_rng.nextDouble() - 0.5) * 0.8;
    vz[i] = mvz + (_rng.nextDouble() - 0.5) * 0.4;
    flapOff[i] = _rng.nextDouble();
  }

  /// The birds put along [segments] ([count] of them, x0 y0 z0 x1 y1 z1 each) — the
  /// dancers' bones — a little off them, barely moving: a dancer made of birds.
  void seedAlong(Float32List segments, int count, int want) {
    if (count <= 0) return;
    for (var i = 0; i < most; i++) {
      final sgi = (i * 7919 + 13) % count;
      final o = sgi * 6;
      final t = _rng.nextDouble();
      // off the bone: a body's thickness
      final jx = (_rng.nextDouble() - 0.5) * 0.16, jy = (_rng.nextDouble() - 0.5) * 0.16, jz = (_rng.nextDouble() - 0.5) * 0.12;
      px[i] = segments[o] + (segments[o + 3] - segments[o]) * t + jx;
      py[i] = segments[o + 1] + (segments[o + 4] - segments[o + 1]) * t + jy;
      pz[i] = segments[o + 2] + (segments[o + 5] - segments[o + 2]) * t + jz;
      vx[i] = (_rng.nextDouble() - 0.5) * 0.2;
      vy[i] = (_rng.nextDouble() - 0.5) * 0.2;
      vz[i] = 0.1 + _rng.nextDouble() * 0.2;
      alpha[i] = i < want ? 1 : 0;
    }
    cx = centre.x;
    cy = centre.y;
    cz = centre.z;
  }

  int _cellOf(double x, double y, double z) {
    var ix = ((x - _xlo) / _cell).floor() + 1, iy = ((y - _ylo) / _cell).floor() + 1, iz = ((z - _zlo) / _cell).floor() + 1;
    if (ix < 0) ix = 0;
    if (ix >= _gx) ix = _gx - 1;
    if (iy < 0) iy = 0;
    if (iy >= _gy) iy = _gy - 1;
    if (iz < 0) iz = 0;
    if (iz >= _gz) iz = _gz - 1;
    return (iz * _gy + iy) * _gx + ix;
  }

  /// The wing's angle of bird [i] at [beats]: down a little, up with the beat — its
  /// own beat: every bird flaps at its own rate near the record's (a quarter either
  /// way) from its own start, so a flock never beats its wings as one.
  double wing(int i, double beats, double flapsPerBeat, double amp, bool glide) {
    final a = glide && seedOf[i] > 0.45 ? amp * 0.12 : amp;
    final rate = flapsPerBeat * (0.78 + 0.44 * seedOf[i]);
    return -0.3 + a * math.sin((beats * rate + flapOff[i]) * math.pi * 2);
  }

  /// One frame.
  void step(FlockSteer s) {
    final dt = s.dt;
    // ---- who flies: the birds past `want` fade out; new ones come in at the middle.
    var mvx = 0.0, mvy = 0.0, mvz = 0.0, mn = 0;
    for (var i = 0; i < most; i++) {
      if (alpha[i] > 0) {
        mvx += vx[i];
        mvy += vy[i];
        mvz += vz[i];
        mn++;
      }
    }
    if (mn > 0) {
      mvx /= mn;
      mvy /= mn;
      mvz /= mn;
    }
    for (var i = 0; i < most; i++) {
      if (i < s.want) {
        if (alpha[i] <= 0) _born(i, cx, cy, cz, 1.2, mvx, mvy, mvz);
        alpha[i] = math.min(1, alpha[i] + dt * 1.2);
      } else if (alpha[i] > 0) {
        alpha[i] = math.max(0, alpha[i] - dt * 0.7);
      }
    }
    if (dt <= 0) return;

    // ---- the waypoint and the wind: a new place every bar, eased to.
    final bar = (s.beats / 4).floor();
    if (bar != _wayBar) {
      _wayBar = bar;
      final h = s.waySalt % 9973;
      _twx = centre.x + (memeHash(h, bar, 151) * 2 - 1) * 2.6;
      _twy = centre.y + (memeHash(h, bar, 157) * 2 - 1) * 1.6;
      _twz = centre.z + (memeHash(h, bar, 163) * 2 - 1) * 1.1;
    }
    final ease = math.min(1.0, 1.4 * dt);
    _wx += (_twx - _wx) * ease;
    _wy += (_twy - _wy) * ease;
    _wz += (_twz - _wz) * ease;
    final phrase = (s.beats / 16).floor();
    final wtx = (memeHash(s.waySalt % 9973, phrase, 173) - 0.5) * 1.2, wty = (memeHash(s.waySalt % 9973, phrase, 179) - 0.5) * 0.8;
    _windX += (wtx - _windX) * math.min(1.0, 0.5 * dt);
    _windY += (wty - _windY) * math.min(1.0, 0.5 * dt);
    _windZ *= 0.99;

    // ---- the grid, rebuilt.
    _head.fillRange(0, _head.length, -1);
    for (var i = 0; i < most; i++) {
      if (alpha[i] <= 0) continue;
      final c = _cellOf(px[i], py[i], pz[i]);
      _next[i] = _head[c];
      _head[c] = i;
    }

    // ---- the rules.
    const sense2 = sense * sense, personal2 = personal * personal;
    final link2 = s.linkR * s.linkR;
    final wCoh = cohesionW * s.cohesion + 0.9 * s.beatDecay * (s.speed > 2.0 ? 1 : 0.3);
    final wAli = alignW, wSep = apartW;
    final fieldW = _fieldWeight(s.flight), fieldWasW = s.flightWas == null ? fieldW : _fieldWeight(s.flightWas!);
    final formed = _formed(s.flight) ? 1.0 : 0.0, formedWas = s.flightWas == null ? formed : (_formed(s.flightWas!) ? 1.0 : 0.0);
    final k = s.flightK.clamp(0.0, 1.0);
    final blending = s.flightWas != null && k < 1;
    final twinRules = s.flight == Flight.twin;
    final aMax = 9.0 + 4.0 * s.speed;
    var sx = 0.0, sy = 0.0, sz = 0.0, sn = 0;
    gcx.fillRange(0, 2, 0);
    gcy.fillRange(0, 2, 0);
    gcz.fillRange(0, 2, 0);
    _gn.fillRange(0, 2, 0);
    for (var i = 0; i < most; i++) {
      if (alpha[i] <= 0) continue;
      final x = px[i], y = py[i], z = pz[i];
      final g = group[i];
      gcx[g] += x;
      gcy[g] += y;
      gcz[g] += z;
      _gn[g]++;
      var ccx = 0.0, ccy = 0.0, ccz = 0.0, avx = 0.0, avy = 0.0, avz = 0.0, spx = 0.0, spy = 0.0, spz = 0.0;
      var n = 0, nl = 0;
      link[i * 3] = link[i * 3 + 1] = link[i * 3 + 2] = -1;
      final c0 = _cellOf(x, y, z);
      final ix = c0 % _gx, iy = (c0 ~/ _gx) % _gy, iz = c0 ~/ (_gx * _gy);
      for (var q = 0; q < 27; q++) {
        // Enough heeded, and a pair complete (the first cell is its own pair).
        if (n >= heed && q.isOdd) break;
        final jx = ix + _around[q * 3], jy = iy + _around[q * 3 + 1], jz = iz + _around[q * 3 + 2];
        if (jx < 0 || jx >= _gx || jy < 0 || jy >= _gy || jz < 0 || jz >= _gz) continue;
        var j = _head[(jz * _gy + jy) * _gx + jx];
        while (j >= 0) {
          if (j != i) {
            final ddx = px[j] - x, ddy = py[j] - y, ddz = pz[j] - z;
            final d2 = ddx * ddx + ddy * ddy + ddz * ddz;
            if (d2 < sense2 && (!twinRules || group[j] == g)) {
              n++;
              ccx += px[j];
              ccy += py[j];
              ccz += pz[j];
              avx += vx[j];
              avy += vy[j];
              avz += vz[j];
              if (d2 < personal2) {
                final w = 1 / (d2 + 0.02);
                spx -= ddx * w;
                spy -= ddy * w;
                spz -= ddz * w;
              }
              if (nl < 3 && d2 < link2) {
                link[i * 3 + nl] = j;
                linkD[i * 3 + nl] = math.sqrt(d2);
                nl++;
              }
            }
          }
          j = _next[j];
        }
      }
      var ax = 0.0, ay = 0.0, az = 0.0;
      if (n > 0) {
        final inv = 1 / n;
        ax += (ccx * inv - x) * wCoh + (avx * inv - vx[i]) * wAli;
        ay += (ccy * inv - y) * wCoh + (avy * inv - vy[i]) * wAli;
        az += (ccz * inv - z) * wCoh + (avz * inv - vz[i]) * wAli;
      }
      ax += spx * wSep;
      ay += spy * wSep;
      az += spz * wSep;

      // The flight's own pull: a velocity the bird would like, and (for a formation)
      // the speed of it.
      _field(s.flight, i, s, _f1, _t1);
      var fx = _f1[0], fy = _f1[1], fz = _f1[2], fw = fieldW, fm = formed;
      if (blending) {
        _field(s.flightWas!, i, s, _f2, _t2);
        fx = _f2[0] + (fx - _f2[0]) * k;
        fy = _f2[1] + (fy - _f2[1]) * k;
        fz = _f2[2] + (fz - _f2[2]) * k;
        fw = fieldWasW + (fw - fieldWasW) * k;
        fm = formedWas + (fm - formedWas) * k;
      }
      ax += (fx - vx[i]) * fw;
      ay += (fy - vy[i]) * fw;
      az += (fz - vz[i]) * fw;
      final fl = math.sqrt(fx * fx + fy * fy + fz * fz);
      _sp[i] = s.speed + (fl.clamp(0.5, s.speed * 1.35) - s.speed) * fm;

      // The room's edges, soft.
      const m = 1.2;
      final rk = s.roomK;
      if (x < _xlo + m) ax += (_xlo + m - x) * 8 * rk;
      if (x > _xhi - m) ax += (_xhi - m - x) * 8 * rk;
      if (y < _ylo + m) ay += (_ylo + m - y) * 8 * rk;
      if (y > _yhi - m) ay += (_yhi - m - y) * 8 * rk;
      if (z < _zlo + m) az += (_zlo + m - z) * 10 * rk;
      if (z > _zhi - m) az += (_zhi - m - z) * 9 * rk;

      // Home: a faint pull to the middle of the room, so the flock stays in the frame.
      ax += (centre.x - x) * 0.1 * rk;
      ay += (centre.y - y) * 0.1 * rk;
      az += (centre.z - z) * 0.12 * rk;

      // A little of its own mind.
      final sd = seedOf[i] * 97;
      final t = s.beats * 0.7;
      ax += math.sin(t * 1.7 + sd) * 0.7;
      ay += math.sin(t * 1.3 + sd * 1.3) * 0.7;
      az += math.sin(t * 1.1 + sd * 1.7) * 0.45;

      final al = math.sqrt(ax * ax + ay * ay + az * az);
      if (al > aMax) {
        final q = aMax / al;
        ax *= q;
        ay *= q;
        az *= q;
      }
      _ax[i] = ax;
      _ay[i] = ay;
      _az[i] = az;
      sx += x;
      sy += y;
      sz += z;
      sn++;
    }
    flying = sn;
    if (sn > 0) {
      cx = sx / sn;
      cy = sy / sn;
      cz = sz / sn;
    }
    for (var g = 0; g < 2; g++) {
      if (_gn[g] > 0) {
        gcx[g] /= _gn[g];
        gcy[g] /= _gn[g];
        gcz[g] /= _gn[g];
      } else {
        gcx[g] = cx;
        gcy[g] = cy;
        gcz[g] = cz;
      }
    }
    // The twins keep to their own: the kick pulls each half to its own middle.
    final twins = s.flight == Flight.twin || s.flightWas == Flight.twin;

    // ---- the moments: the kick's breath in, the snare's startle, the drop's burst.
    final kick = s.kick, snare = s.snare, burst = s.burst;
    double jx = 0, jy = 0, jz = 0, ox = 0, oy = 0, oz = 0;
    if (snare > 0.01) {
      _snares++;
      final h = memeHash(s.waySalt % 9973, _snares, 191) * math.pi * 2;
      final h2 = memeHash(s.waySalt % 9973, _snares, 193) * math.pi * 2;
      ox = cx + math.cos(h) * 3.2;
      oy = cy + math.sin(h) * 1.8;
      oz = cz + (memeHash(s.waySalt % 9973, _snares, 197) - 0.5) * 2;
      jx = math.cos(h2) * 1.7 * snare;
      jy = math.sin(h2) * 1.0 * snare;
      jz = (memeHash(s.waySalt % 9973, _snares, 199) - 0.5) * 1.6 * snare;
    }
    for (var i = 0; i < most; i++) {
      if (alpha[i] <= 0) continue;
      var x = px[i], y = py[i], z = pz[i];
      var ux = vx[i] + _ax[i] * dt, uy = vy[i] + _ay[i] * dt, uz = vz[i] + _az[i] * dt;
      if (kick > 0.01) {
        final g = group[i];
        final kx = twins ? gcx[g] : cx, ky = twins ? gcy[g] : cy, kz = twins ? gcz[g] : cz;
        ux += (kx - x) * kick;
        uy += (ky - y) * kick;
        uz += (kz - z) * kick;
        // The wingbeats nudged toward the beat — a nudge, not a lock.
        var off = flapOff[i];
        off -= off.round();
        flapOff[i] = off * (1 - 0.08 * kick);
      }
      if (snare > 0.01) {
        final ddx = x - ox, ddy = y - oy, ddz = z - oz;
        final w = math.exp(-(ddx * ddx + ddy * ddy + ddz * ddz) / 5.0);
        ux += jx * w;
        uy += jy * w;
        uz += jz * w;
      }
      if (burst > 0.01) {
        final ddx = x - cx, ddy = y - cy, ddz = z - cz;
        final d = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz) + 0.3;
        final q = burst * (2.4 + 1.2 * seedOf[i]) / d;
        ux += ddx * q;
        uy += ddy * q;
        uz += ddz * q;
      }
      // Birds fly at a speed: toward the one the mood (or the formation) wants.
      final sp = math.sqrt(ux * ux + uy * uy + uz * uz);
      if (sp > 1e-4) {
        final want = _sp[i];
        final sp2 = sp + (want - sp) * math.min(1.0, 3.5 * dt);
        final q = sp2 / sp;
        ux *= q;
        uy *= q;
        uz *= q;
      }
      vx[i] = ux;
      vy[i] = uy;
      vz[i] = uz;
      x += ux * dt * s.surge;
      y += uy * dt * s.surge;
      z += uz * dt * s.surge;
      // Never far through the floor, never out of the room (the room's pull does the
      // rest, softly — birds born at a dancer's feet rise, they do not jump).
      if (z < -0.3) z = -0.3;
      if (z > _zhi + 1) z = _zhi + 1;
      if (x < _xlo - 1) x = _xlo - 1;
      if (x > _xhi + 1) x = _xhi + 1;
      if (y < _ylo - 1) y = _ylo - 1;
      if (y > _yhi + 1) y = _yhi + 1;
      px[i] = x;
      py[i] = y;
      pz[i] = z;
      // The wingbeats drift apart again, each its own way.
      flapOff[i] += (seedOf[i] - 0.5) * 0.12 * dt;
    }
  }

  static double _fieldWeight(Flight f) => switch (f) {
        Flight.murmur => 0.55,
        Flight.vortex => 1.5,
        Flight.ribbon => 2.4,
        Flight.vee => 3.2,
        Flight.sphere => 2.6,
        Flight.sheet => 2.2,
        Flight.twin => 2.4,
      };

  /// Whether the birds take their speed from the flight (a formation) rather than
  /// the mood.
  static bool _formed(Flight f) => f == Flight.ribbon || f == Flight.vee || f == Flight.sphere || f == Flight.sheet;

  /// The velocity bird [i] would like under [f], into [out] ([tmp] scratch).
  void _field(Flight f, int i, FlockSteer s, Float64List out, Float64List tmp) {
    final x = px[i], y = py[i], z = pz[i];
    switch (f) {
      case Flight.murmur:
        var dx = _wx - x, dy = _wy - y, dz = _wz - z;
        final d = math.sqrt(dx * dx + dy * dy + dz * dz) + 1e-6;
        final q = s.speed * 0.9 / d;
        out[0] = dx * q + _windX;
        out[1] = dy * q + _windY;
        out[2] = dz * q + _windZ;
      case Flight.vortex:
        _vortex(x, y, z, centre.x, centre.y, 2.7, s.spin, s, out, wave: true);
      case Flight.twin:
        final g = group[i];
        final a = s.beats * math.pi / 4 + (g == 0 ? 0 : math.pi);
        final ccx = centre.x + math.cos(a) * 2.7, ccy = centre.y + math.sin(a) * 1.3;
        _vortex(x, y, z, ccx, ccy, 1.3, g == 0 ? s.spin : -s.spin, s, out, wave: false, zMid: centre.z + 0.7 * math.sin(a));
      case Flight.ribbon:
      case Flight.vee:
      case Flight.sphere:
      case Flight.sheet:
        // A place to be at this beat, and where that place is going.
        _target(f, i, s.beats, s, out);
        _target(f, i, s.beats + 0.05, s, tmp);
        final vx0 = (tmp[0] - out[0]) / 0.05 * s.beatsPerSecond;
        final vy0 = (tmp[1] - out[1]) / 0.05 * s.beatsPerSecond;
        final vz0 = (tmp[2] - out[2]) / 0.05 * s.beatsPerSecond;
        final gain = f == Flight.vee ? 2.8 : 2.2;
        out[0] = (out[0] - x) * gain + vx0;
        out[1] = (out[1] - y) * gain + vy0;
        out[2] = (out[2] - z) * gain + vz0;
    }
  }

  /// Round a column at [ax],[ay] of radius [r0], [spin] way round; a wave of height
  /// running round it ([wave]), or a level at [zMid].
  void _vortex(double x, double y, double z, double ax, double ay, double r0, double spin, FlockSteer s, Float64List out, {required bool wave, double? zMid}) {
    final dx = x - ax, dy = y - ay;
    final r = math.sqrt(dx * dx + dy * dy) + 1e-6;
    final tx = -dy / r * spin, ty = dx / r * spin;
    final radial = (r0 - r) * 0.9;
    final ang = math.atan2(dy, dx);
    final zt = (zMid ?? centre.z) + (wave ? 1.3 * math.sin(s.beats * math.pi / 4 + ang * 2 * spin) : 0.4 * math.sin(ang * 3 + s.beats * 0.5));
    out[0] = tx * s.speed + dx / r * radial;
    out[1] = ty * s.speed * 0.8 + dy / r * radial;
    out[2] = (zt - z) * 0.9;
  }

  /// Where bird [i] belongs at [beats] in formation [f], into [out].
  void _target(Flight f, int i, double beats, FlockSteer s, Float64List out) {
    final want = math.max(1, s.want);
    switch (f) {
      case Flight.ribbon:
        // Strung along a looping path, a loop a phrase; each bird a little behind the one before.
        final u = beats * math.pi * 2 / 16 - (i % want) / want * 1.6 - seedOf[i] * 0.05;
        out[0] = centre.x + 5.0 * math.sin(u);
        out[1] = centre.y + 2.2 * math.sin(2 * u + 0.6);
        out[2] = centre.z + 1.7 * math.cos(3 * u) * 0.8 + 0.3;
      case Flight.vee:
        // Nine skeins, each behind a leader flying a slow ellipse; the ranks step back
        // and out from it, left and right by turns.
        const leaders = 9;
        final l = i % leaders, rank = i ~/ leaders;
        final side = rank.isOdd ? 1.0 : -1.0, depth = (rank ~/ 2) + 1.0;
        final th = beats * 0.028 * (0.8 + 0.4 * memeHash(l, 1, 211)) + l * 0.7;
        final zl = 1.6 + 3.6 * memeHash(l, 2, 211);
        final yl = centre.y + (memeHash(l, 3, 211) - 0.5) * 4.5;
        final qx = centre.x + 5.6 * math.cos(th), qy = yl + 1.4 * math.sin(th);
        final qz = zl + 0.35 * math.sin(2 * th + l);
        // forward = d/dθ
        var fx = -math.sin(th), fy = 0.25 * math.cos(th);
        final fl = math.sqrt(fx * fx + fy * fy) + 1e-6;
        fx /= fl;
        fy /= fl;
        final rx = fy, ry = -fx;
        out[0] = qx - fx * depth * 0.4 + rx * side * depth * 0.34;
        out[1] = qy - fy * depth * 0.4 + ry * side * depth * 0.34;
        out[2] = qz - depth * 0.015 + side * 0.03;
      case Flight.sphere:
        // A fibonacci lattice on a globe, turning slowly, tilted; breathing with the
        // beat; the bursts of the drop swell it.
        final kk = (i % want) / want;
        final zz = 1 - 2 * kk;
        final rr = math.sqrt(math.max(0.0, 1 - zz * zz));
        final ph = i * 2.39996323 + beats * 0.22;
        final r = (2.5 + 0.22 * s.beatDecay) * (1 + 0.08 * math.sin(beats * math.pi / 8));
        final x0 = rr * math.cos(ph) * r, y0 = rr * math.sin(ph) * r, z0 = zz * r;
        // tilted: round x by half a radian
        const ct = 0.8776, st = 0.4794;
        final y1 = y0 * ct - z0 * st, z1 = y0 * st + z0 * ct;
        out[0] = centre.x + x0;
        out[1] = centre.y + y1 * 0.7;
        out[2] = centre.z + 0.2 + z1;
      case Flight.sheet:
        // A curtain: columns across, rows into the depth; a wave crossing it once a
        // bar, a slower one down it once a phrase.
        const cols = 40;
        final rows = math.max(1, want ~/ cols);
        final col = i % cols, row = (i ~/ cols) % rows;
        final u = (col + 0.5) / cols, v = (row + 0.5) / rows;
        out[0] = centre.x - 5.6 + 11.2 * u;
        out[1] = centre.y - 1.6 + 3.4 * v;
        out[2] = centre.z + 1.15 * math.sin((u * 1.5 - beats / 4) * math.pi * 2) + 0.55 * math.sin((v - beats / 16) * math.pi * 2);
      default:
        out[0] = centre.x;
        out[1] = centre.y;
        out[2] = centre.z;
    }
  }
}

/// A frame of the record, as the looks read it.
class _Cue {
  _Cue(this.st, Map<String, double> f, this.mood, this.beats, this.since, this.heat, this.wakeK, this.kick, this.snare)
      : beat = f['dyn.beat.decay'] ?? 0,
        barSaw = f['dyn.bar.saw'] ?? 0,
        t = st.now.millisecondsSinceEpoch / 1000 % 10000;
  final ShowState st;
  final MemeMood mood;
  final double beats, heat, wakeK, kick, snare, beat, barSaw, t;
  final double? since;
  bool get rage => mood == MemeMood.rage;
  bool get sleep => mood == MemeMood.sleep;
}

class FlockSim implements SimLayer {
  FlockSim(this.kind) : birds = BirdAssets.of('pigeon') {
    // A look, a flight or a camera forced from outside, for a look at one:
    // WETOWL_FLOCK_LOOK=wire WETOWL_FLOCK_FLIGHT=sphere WETOWL_FLOCK_SHOT=low.
    try {
      final look = Platform.environment['WETOWL_FLOCK_LOOK'];
      if (look != null) _forcedLook = FlockLook.values.where((a) => a.name == look).firstOrNull;
      final flight = Platform.environment['WETOWL_FLOCK_FLIGHT'];
      if (flight != null) _forcedFlight = Flight.values.where((a) => a.name == flight).firstOrNull;
      final shot = Platform.environment['WETOWL_FLOCK_SHOT'];
      if (shot != null) _forcedShot = FlockShot.values.where((a) => a.name == shot).firstOrNull;
    } catch (_) {}
    _forcedLook ??= forceLook;
    _forcedFlight ??= forceFlight;
    _forcedShot ??= forceShot;
  }

  /// Forced by a test, for every sim made after.
  @visibleForTesting
  static FlockLook? forceLook;
  @visibleForTesting
  static Flight? forceFlight;
  @visibleForTesting
  static FlockShot? forceShot;

  @override
  final String kind;

  final model = FlockModel();

  /// The pigeon's mesh and skin (read once per process), and the batch that draws them.
  final BirdAssets birds;
  final _batch = BirdBatch();
  FlockSteer? _steer;
  final _byDepth = <int>[], _bySize = <int>[];
  final _rank = Int32List(FlockModel.most);
  FlockLook? _forcedLook;
  Flight? _forcedFlight;
  FlockShot? _forcedShot;

  double _t = 0;
  double? _dropAt, _awayWas;
  String? _sectionWas;
  int _flightSlot = -999, _sectionSlot = -1, _cut = -999;

  /// The framing the hands held at the last cut (StylePool.heldShot): a new one cuts.
  String? _heldWas;
  Flight _flight = Flight.murmur;
  Flight? _flightWas;
  double _flightAt = -99;
  FlockLook? _look;
  FlockShot _shot = FlockShot.wide;

  /// The shot's travel in a loud part.
  final _sweep = CameraSweep();
  double _kickWas = 0, _snareWas = 0;
  double _gather = 0;
  double _spin = 1;
  int _want = 700;

  /// The dancer's handoff: her camera held, the birds her shape, until [_handUntil]
  /// beats; released (let fly) at [_releaseAt]; drawn small and growing by [_sizeK].
  bool _seeded = false, _released = false;
  double _handUntil = -1, _releaseAt = -1, _sizeK = 1;
  DanceCam? _handCam;
  int _spinBar = -1;

  /// The last picture, kept so the stage can show it while a frame is skipped.
  ui.Image? _out;
  ui.FragmentShader? _fx, _crtFx;
  static ui.Image? _glyphs;

  /// The look the frame asked for last (RigFigure.style), to see it let go.
  String? _styledWas;
  static const _ramp = ' .:-=+*#%@';

  // The birds on the picture: where, how deep, how big (pixels a metre), and their
  // wings as two triangles each.
  final _sx = Float32List(FlockModel.most), _sy = Float32List(FlockModel.most), _sd = Float32List(FlockModel.most), _sc = Float32List(FlockModel.most);
  final _on = Uint8List(FlockModel.most);
  final _tri = Float32List(FlockModel.most * 12);
  final _triBird = Int32List(FlockModel.most);
  final _triCol = Int32List(FlockModel.most * 6);
  int _triN = 0;

  // Where each bird was on the picture over the last frames, for the ribbons.
  static const _histLen = 12;
  final _hist = Float32List(FlockModel.most * _histLen * 2);
  int _histAt = 0, _histN = 0;
  final _ribbonPos = Float32List(FlockModel.most * (_histLen - 1) * 12);
  final _ribbonCol = Int32List(FlockModel.most * (_histLen - 1) * 6);

  // The chronophotograph's stamps: the flock's shapes, with the beat they were taken.
  final _stamps = <(double, BirdStamp)>[];
  double _stampLast = -99;

  Offset _mid = const Offset(0.5, 0.5);
  Size? _sizeWas;

  /// For the finish: where its interest is (the flock's middle; the sky's sun), and
  /// the sky's horizon as a share of the height and its sun's radius in pixels.
  Offset _popAt = const Offset(0.5, 0.5);
  double _horizonK = 0.78, _sunPx = 40;
  Color _skyTop = Colors.black, _skyHorizon = Colors.black;

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    _watch.start();
    final (cam, cue, look) = _step(st, dt, w, h);
    final rec = ui.PictureRecorder();
    _draw(CanvasFlockSurface(Canvas(rec)), Size(w.toDouble(), h.toDouble()), cam, cue, look);
    final pic = rec.endRecording();
    var img = pic.toImageSync(w, h);
    pic.dispose();
    if (_ownFinish(st, look)) img = _post(img, w, h, p, cue, look);
    _out?.dispose();
    _out = img;
    _watch.stop();
    _cost(look);
    return img;
  }

  /// The native stage's frame: the same moved on by [dt], as [s]'s commands — the
  /// finish the stage's too (dance.h's kPostFx, the same shaders).
  Float32List record(ShowState st, double dt, int w, int h, NativeFlockSurface s) {
    _watch.start();
    final (cam, cue, look) = _step(st, dt, w, h);
    s.d.camera(cam);
    _draw(s, Size(w.toDouble(), h.toDouble()), cam, cue, look);
    if (_ownFinish(st, look)) _postNative(s, h, cue, look);
    _watch.stop();
    _cost(look);
    return s.d.finish();
  }

  /// Whether the look's finish is the flock's to draw: under a transformation an
  /// image style's pass is the stage's, over what that made (show_common.dart
  /// styleIsStage); the flock's own scope and sky stay its own.
  bool _ownFinish(ShowState st, FlockLook look) =>
      flockFxMode.containsKey(look) && !(styleIsStage(st.rig) && look.name == st.rig.figure.style);

  void _cost(FlockLook look) {
    if (++_frames % 300 == 0) {
      // ignore: avoid_print
      print('FLOCK ${(_watch.elapsedMicroseconds / 300 / 1000).toStringAsFixed(1)} ms a frame, ${model.flying} birds, ${_batch.vertsDrawn} vertices, ${look.name} / ${_flight.name}');
      _watch.reset();
    }
  }

  /// The flock moved on by [dt] for a picture [w]×[h]: the flight, the look, the
  /// camera, the birds' rules and their places on the picture.
  (DanceCam, _Cue, FlockLook) _step(ShowState st, double dt, int w, int h) {
    _t += dt;
    final m = st.master;
    final f = st.flat;
    final playing = m.playing && m.beatIndex != null;
    final bpm = (m.bpm ?? 0) > 1 ? m.bpm! : 120.0;
    final beats = !playing
        ? _t * bpm / 60
        : (m.barIndex != null && m.beatInBar != null ? m.barIndex! * 4 + m.beatInBar! + m.beatPhase : m.beatIndex! + m.beatPhase);
    final salt = m.trackId ?? 0;

    // The drop, remembered past the deck's two beats (as the dancer does).
    final away = m.dropBeatsAway;
    if (playing) {
      final was = _awayWas;
      if (away != null && away <= 0 && away > -2.5 && (was == null || was > 0)) _dropAt = beats + away;
      if (m.section == 'drop' && _sectionWas != 'drop' && (_dropAt == null || beats - _dropAt! > 8)) _dropAt = beats;
      final d = _dropAt;
      if (d != null && (beats - d < -1 || beats - d > 64)) _dropAt = null;
    }
    final sectionTurned = playing && _sectionWas != null && m.section != _sectionWas;
    _awayWas = away;
    _sectionWas = m.section;
    final since = _dropAt == null ? null : beats - _dropAt!;
    final mood = playing ? MemeClock.mood(m, sinceDrop: since) : MemeMood.sleep;
    final heat = mood == MemeMood.rage ? MemeClock.heat(m, sinceDrop: since) : 0.0;
    final wakeK = mood == MemeMood.wake ? MemeClock.wakeK(m) : 0.0;
    final kick = f['dyn.hit.kick'] ?? 0, snare = f['dyn.hit.snare'] ?? 0;
    final energy = f['dyn.energy'] ?? m.energy;
    final cue = _Cue(st, f, mood, beats, since, heat, wakeK, kick, snare);

    // ---- the flight: a slot every four bars; a drop or a new section a slot of its own.
    final n = (beats / FlockClock.flightBeats).floor();
    final dropNow = since != null && since >= 0 && since < 0.5 && _dropAt != _dropSeen;
    if (dropNow) _dropSeen = _dropAt;
    final sectionNow = sectionTurned && _sectionSlot != n;
    if (n != _flightSlot || dropNow || sectionNow) {
      if (sectionNow) _sectionSlot = n;
      final next = _forcedFlight ?? FlockClock.flight(dropNow ? MemeMood.rage : mood, salt, n, not: _flight);
      if (next != _flight || _flightSlot == -999) {
        _flightWas = _flightSlot == -999 ? null : _flight;
        _flight = next;
        _flightAt = beats;
      }
      // How many fly: decided with the flight, so the edge of the flock does not
      // flicker with the energy frame by frame.
      _want = FlockClock.count(_flight, dropNow ? MemeMood.rage : mood, energy, look: _look);
      _flightSlot = n;
    }
    // Blended over a bar (none on a drop: the cut is the point).
    final flightK = dropNow ? 1.0 : ((beats - _flightAt) / 4).clamp(0.0, 1.0);
    if (flightK >= 1) _flightWas = null;

    // ---- the look: a section at a time — and at once when a look from the frame
    // (the hands', the conductor's treatment) is let go, so it does not linger. By
    // the slot, as the dancers': the same on every stage, and after a seek.
    final styled = st.rig.figure.style;
    final letGo = styled == null && _styledWas != null;
    _styledWas = styled;
    if (_look == null || dropNow || sectionNow || letGo) {
      _look = _forcedLook ?? FlockClock.look(mood, salt ^ st.macros.seed, n, not: letGo ? null : _look);
      if (letGo) _want = FlockClock.count(_flight, mood, energy, look: _look);
    }
    // The hands' own look, from the frame (the show's rig): on at once.
    if (styled != null) {
      final want = FlockLook.values.where((a) => a.name == styled).firstOrNull;
      if (want != null) _look = want;
      _want = FlockClock.count(_flight, dropNow ? MemeMood.rage : mood, energy, look: _look);
    }
    // Told back, so the rules for one look of the flock apply (show_pool.dart).
    if (_look != null) StylePool.now[Figure.birds] = _look!.name;
    final look = _look!;

    // ---- the dancer's handoff: on the first frame after her, the birds take her
    // shape and her camera; a beat later they are let go, small and growing; after a
    // bar the room takes them and the camera cuts to the flock's own.
    final size = Size(w.toDouble(), h.toDouble());
    if (!_seeded) {
      _seeded = true;
      if (DanceHandoff.fresh) {
        model.seedAlong(DanceHandoff.segments, DanceHandoff.count, _want);
        _handCam = DanceCam(eye: DanceHandoff.eye, target: DanceHandoff.target, size: size, fov: DanceHandoff.fov, roll: DanceHandoff.roll);
        _releaseAt = beats + 1.0;
        _handUntil = beats + 5.0;
        _sizeK = 0.3;
      }
    }
    final handing = beats < _handUntil;
    final frozen = beats < _releaseAt;
    final releaseNow = !frozen && !_released && _handCam != null;
    if (releaseNow) _released = true;
    if (_handCam != null && !frozen) _sizeK = 0.3 + 0.7 * ((beats - _releaseAt) / 2.5).clamp(0.0, 1.0);
    final roomK = _handCam == null ? 1.0 : (handing ? 0.0 : ((beats - _handUntil) / 4).clamp(0.0, 1.0));

    // ---- the camera: cut after a while, on a drop, on a new section — faster the more
    // intense the record (StageCamera.drive). Still in a quiet part; in a loud one each
    // shot travels (CameraSweep): round the flock, in at it, up past it, into it.
    final drive = m.playing ? StageCamera.drive(m) : 0.0;
    final hold = cutHold(FlockClock.hold(mood), drive);
    final cutN = hold * 100000 + (beats / hold).floor();
    var cut = false;
    final held = StylePool.held(Figure.birds);
    if (cutN != _cut || dropNow || sectionNow || size != _sizeWas || held != _heldWas) {
      _cut = cutN;
      _heldWas = held;
      final shot = _forcedShot ??
          FlockShot.values.where((x) => x.name == held).firstOrNull ??
          FlockClock.shot(mood, salt, cutN, look, weight: (x) => StylePool.shot(Figure.birds, x.name));
      cut = shot != _shot || size != _sizeWas;
      _shot = shot;
      final inside = shot == FlockShot.fish || shot == FlockShot.fishLow;
      _sweep.cut(beats, hold, drive, memeHash(salt % 9973, cutN, 337), close: inside, over: !inside && shot != FlockShot.low, drop: dropNow);
      StylePool.shotNow[Figure.birds] = shot.name;
      _sizeWas = size;
    }
    if (_handCam != null && !handing) {
      // Her camera let go of: the flock's own, as a cut.
      _handCam = null;
      cut = true;
    }
    if (cut) {
      _histN = 0;
      _stamps.clear();
    }
    final hc = _handCam;
    final cam = hc != null
        ? DanceCam(eye: hc.eye, target: hc.target, size: size, fov: hc.fov, roll: hc.roll)
        : FlockFrame.of(_shot).swept(_sweep.at(beats, drive, dt)).cam(size);

    // ---- the moments, as edges.
    final kickEdge = kick > 0.4 && kick > _kickWas + 0.2 ? kick : 0.0;
    final snareEdge = snare > 0.45 && snare > _snareWas + 0.25 ? snare : 0.0;
    _kickWas = kick;
    _snareWas = snare;
    final burst = dropNow ? 1.0 : 0.0;
    if (dropNow) _gather = beats + 8;
    final gathering = beats < _gather;
    // The vortex turns the other way every other bar in the drop's heat.
    final bar = (beats / 4).floor();
    if (bar != _spinBar) {
      _spinBar = bar;
      if (cue.rage && heat > 0.6 && bar.isEven) _spin = -_spin;
    }

    final steer = FlockSteer(
      // Frozen while the birds are still the dancer's shape.
      dt: frozen ? 0.0 : dt.clamp(0.0, 1 / 30),
      beats: beats,
      beatsPerSecond: bpm / 60,
      // The beat surges the flock: faster on it, easing off between.
      speed: FlockClock.speed(mood, wakeK: wakeK, energy: energy) * (1 + (cue.sleep ? 0.12 : 0.4) * cue.beat),
      want: _want,
      flight: _flight,
      flightWas: _flightWas,
      flightK: flightK,
      barSaw: cue.barSaw,
      phraseSaw: f['dyn.phrase.saw'] ?? 0,
      beatDecay: cue.sleep ? 0 : cue.beat,
      kick: kickEdge * FlockClock.kickPull(mood, wakeK: wakeK),
      snare: cue.sleep ? 0 : snareEdge,
      burst: releaseNow ? 0.45 : burst,
      cohesion: gathering ? 2.2 : 1.0,
      roomK: roomK,
      spin: _spin,
      flapsPerBeat: FlockClock.flapsPerBeat(mood),
      flapAmp: cue.sleep ? 0.45 : 0.78,
      glide: cue.sleep,
      linkR: 0.95 + 0.55 * cue.beat,
      waySalt: salt,
      // Along the path on the beat: pushed on it, drifting before the next.
      surge: playing ? FlockClock.surge(mood, beats - beats.floorToDouble()) : 1,
    );
    _steer = steer;
    model.step(steer);

    // ---- onto the picture.
    _project(cam, steer);
    _popAt = _mid;
    return (cam, cue, look);
  }

  final _watch = Stopwatch();
  int _frames = 0;

  double? _dropSeen;

  /// Every flying bird onto the picture: its place, depth and scale, and its wings.
  void _project(DanceCam cam, FlockSteer s) {
    final m = model;
    var k = 0;
    var mx = 0.0, my = 0.0, mn = 0;
    for (var i = 0; i < FlockModel.most; i++) {
      if (m.alpha[i] <= 0) {
        _on[i] = 0;
        continue;
      }
      final x = m.px[i], y = m.py[i], z = m.pz[i];
      final (sx, sy, d) = cam.project(V3(x, y, z));
      if (d < DanceCam.near + 0.5) {
        _on[i] = 0;
        continue;
      }
      _on[i] = 1;
      _sx[i] = sx;
      _sy[i] = sy;
      _sd[i] = d;
      _sc[i] = cam.scaleAt(d);
      mx += sx;
      my += sy;
      mn++;
      // The wings: forward along the flight, right across it, up between.
      var fx = m.vx[i], fy = m.vy[i], fz = m.vz[i];
      final fl = math.sqrt(fx * fx + fy * fy + fz * fz) + 1e-6;
      fx /= fl;
      fy /= fl;
      fz /= fl;
      var rx = fy, ry = -fx;
      final rl = math.sqrt(rx * rx + ry * ry) + 1e-6;
      rx /= rl;
      ry /= rl;
      final ux = ry * fz, uy = -rx * fz, uz = rx * fy - ry * fx;
      final wng = m.wing(i, s.beats, s.flapsPerBeat, s.flapAmp, s.glide);
      final cw = math.cos(wng), sw = math.sin(wng);
      final span = 0.42 * m.size[i];
      final half = span * 0.5;
      final nx = x + fx * span * 0.26, ny = y + fy * span * 0.26, nz = z + fz * span * 0.26;
      final tx = x - fx * span * 0.3, ty = y - fy * span * 0.3, tz = z - fz * span * 0.3;
      final bx = x - fx * span * 0.04, by = y - fy * span * 0.04, bz = z - fz * span * 0.04;
      final lx = bx - rx * half * cw + ux * half * sw, ly = by - ry * half * cw + uy * half * sw, lz = bz + uz * half * sw;
      final qx = bx + rx * half * cw + ux * half * sw, qy = by + ry * half * cw + uy * half * sw, qz = bz + uz * half * sw;
      final (nsx, nsy, _) = cam.project(V3(nx, ny, nz));
      final (tsx, tsy, _) = cam.project(V3(tx, ty, tz));
      final (lsx, lsy, _) = cam.project(V3(lx, ly, lz));
      final (qsx, qsy, _) = cam.project(V3(qx, qy, qz));
      final o = k * 12;
      _tri[o] = nsx;
      _tri[o + 1] = nsy;
      _tri[o + 2] = lsx;
      _tri[o + 3] = lsy;
      _tri[o + 4] = tsx;
      _tri[o + 5] = tsy;
      _tri[o + 6] = nsx;
      _tri[o + 7] = nsy;
      _tri[o + 8] = tsx;
      _tri[o + 9] = tsy;
      _tri[o + 10] = qsx;
      _tri[o + 11] = qsy;
      _triBird[k] = i;
      k++;
    }
    _triN = k;
    if (mn > 0) _mid = Offset(mx / mn / cam.size.width, my / mn / cam.size.height);
    // The history, for the ribbons.
    if (s.dt > 0) {
      _histAt = (_histAt + 1) % _histLen;
      if (_histN < _histLen) _histN++;
      for (var i = 0; i < FlockModel.most; i++) {
        final o = (i * _histLen + _histAt) * 2;
        if (_on[i] == 0) {
          _hist[o] = -1e9;
          continue;
        }
        _hist[o] = _sx[i];
        _hist[o + 1] = _sy[i];
      }
    }
  }

  // ------------------------------------------------------------------ the looks

  void _draw(FlockSurface c, Size s, DanceCam cam, _Cue l, FlockLook look) {
    final pal = l.st.palette;
    switch (look) {
      case FlockLook.ink:
        // Light on black: the page is the background's (white, and the difference
        // turns them to ink on it; on MilkDrop a keyhole makes them windows).
        const paper = Color(0xff000000);
        const ink = Color(0xfff3f2ee);
        c.fill(Offset.zero & s, paper);
        // Each bird a little see-through: where the flock is thick it is solid, at its
        // edges the single birds show, and the waves of density run through it.
        _pigeons(c, cam, BirdShade.flat, BirdLight(flat: ink), alphaK: 0.8);
      case FlockLook.sky:
        _sky(c, s, cam, l);
      case FlockLook.embers:
        final deep = HSLColor.fromAHSL(1, pal.primary.hue, 0.45, 0.03).toColor();
        c.fill(Offset.zero & s, deep);
        final a = pal.primary.withSaturation(0.9).withLightness(0.62).toColor();
        final b = pal.accent.withSaturation(0.95).withLightness(0.66).toColor();
        _ribbons(c, s, l, a, b, width: 0.03, glow: 0.32 + 0.28 * l.beat, len: 9);
        _sprites(c, s, (i) => Color.lerp(Color.lerp(a, b, model.seedOf[i])!, Colors.white, 0.22)!, sizeK: 0.16, flapGlow: 0.7, alphaK: 0.3);
        // The birds in chrome, the room's warmth in their surface, the accent at their edges.
        _pigeons(c, cam, BirdShade.chrome, BirdLight(tint: Color.lerp(Colors.white, pal.secondary.withSaturation(0.6).withLightness(0.75).toColor(), 0.18)!, rim: b, rimK: 0.3 + 0.25 * l.beat));
      case FlockLook.neon:
        c.fill(Offset.zero & s, const Color(0xff040208));
        final a = pal.accent.withSaturation(1).withLightness(0.6).toColor();
        final b = pal.secondary.withSaturation(1).withLightness(0.62).toColor();
        // Each bird black with its edges lit in neon; a soft glow of its colour behind.
        _sprites(c, s, (i) => model.group[i] == 0 ? a : b, sizeK: 0.3, flapGlow: 0.3, alphaK: 0.22);
        _pigeons(c, cam, BirdShade.lit, BirdLight(tint: const Color(0xff050308), ambient: 1, keyK: 0, rim: a, rimK: 1.6 + 0.6 * l.kick), textured: false,
            rimBy: (i) => model.group[i] == 0 ? a : b);
      case FlockLook.wire:
        final deep = HSLColor.fromAHSL(1, pal.secondary.hue, 0.35, 0.035).toColor();
        c.fill(Offset.zero & s, deep);
        _wire(c, s, l, pal.primary.withSaturation(0.8).withLightness(0.62).toColor(), pal.accent.withSaturation(0.9).withLightness(0.7).toColor());
        _pigeons(c, cam, BirdShade.lit, BirdLight(tint: pal.accent.withSaturation(0.4).withLightness(0.88).toColor(), ambient: 0.5, keyK: 0.7), textured: false);
      case FlockLook.chrono:
        c.fill(Offset.zero & s, const Color(0xff060606));
        _chrono(c, cam, l, pal.primary.withSaturation(0.35).withLightness(0.62).toColor());
        _pigeons(c, cam, BirdShade.chrome, BirdLight(tint: Colors.white, rim: pal.accent.withLightness(0.75).toColor(), rimK: 0.3));
      case FlockLook.contour:
      case FlockLook.thermal:
        // The flock as a cloud of light: each bird a wide soft glow, so where they are
        // thick it is bright — the finish draws the heights of it.
        c.fill(Offset.zero & s, Colors.black);
        _sprites(c, s, (i) => Colors.white, sizeK: 0.5, flapGlow: 0.0, alphaK: look == FlockLook.thermal ? 0.09 : 0.14);
      case FlockLook.ascii:
      case FlockLook.dither:
      case FlockLook.halftone:
      case FlockLook.crt:
        c.fill(Offset.zero & s, Colors.black);
        // The birds bright on black; the finish draws them its own way (it reads only
        // their light, so plain lit white, which is cheaper than chrome).
        _pigeons(c, cam, BirdShade.lit, const BirdLight(tint: Colors.white, ambient: 0.45, keyK: 0.75, rim: Colors.white, rimK: 0.5), textured: false);
      case FlockLook.lines:
        // The ridgelines want smooth heights: each bird a soft point of light.
        c.fill(Offset.zero & s, Colors.black);
        _sprites(c, s, (i) => Colors.white, sizeK: 0.3, flapGlow: 0.4, alphaK: 0.5);
      case FlockLook.radar:
        c.fill(Offset.zero & s, Colors.black);
        _ribbons(c, s, l, Colors.white, Colors.white, width: 0.02, glow: 0.5, len: 6);
        _sprites(c, s, (i) => Colors.white, sizeK: 0.12, flapGlow: 0.0, alphaK: 1);
    }
  }

  /// The wings as ink: every flying bird's two triangles, coloured by [colour] and
  /// its own alpha.
  void _wings(FlockSurface c, Color Function(int i) colour, {double alphaK = 1, BlendMode blend = BlendMode.srcOver}) {
    if (_triN == 0) return;
    for (var k = 0; k < _triN; k++) {
      final i = _triBird[k];
      final a = (model.alpha[i] * alphaK).clamp(0.0, 1.0);
      final col = _argb(colour(i).withValues(alpha: a));
      final o = k * 6;
      _triCol[o] = _triCol[o + 1] = _triCol[o + 2] = _triCol[o + 3] = _triCol[o + 4] = _triCol[o + 5] = col;
    }
    c.vertices(Float32List.sublistView(_tri, 0, _triN * 12), Int32List.sublistView(_triCol, 0, _triN * 6), blend: blend);
  }

  /// Every flying bird as a soft point of light, [sizeK] metres across (scaled by its
  /// depth), brighter as its wings beat ([flapGlow]), added.
  void _sprites(FlockSurface c, Size s, Color Function(int i) colour, {required double sizeK, required double flapGlow, required double alphaK}) {
    final transforms = <RSTransform>[];
    final rects = <Rect>[];
    final colors = <Color>[];
    const src = Rect.fromLTWH(0, 0, 48, 48);
    final m = model;
    for (var k = 0; k < _triN; k++) {
      final i = _triBird[k];
      final a = m.alpha[i] * alphaK;
      if (a <= 0.01) continue;
      // The wing's lift, read off its triangles: the tips' height over the body.
      final o = k * 12;
      final lift = ((_tri[o + 5] - _tri[o + 3]) + (_tri[o + 9] - _tri[o + 11])).abs() / (2 * _sc[i] * 0.42 + 1e-6);
      final glow = 1 + flapGlow * lift.clamp(0.0, 1.0);
      final size = sizeK * _sc[i] * m.size[i] * glow;
      if (size < 1.5) continue;
      transforms.add(RSTransform.fromComponents(rotation: 0, scale: size / 48 * 2, anchorX: 24, anchorY: 24, translateX: _sx[i], translateY: _sy[i]));
      rects.add(src);
      colors.add(colour(i).withValues(alpha: a.clamp(0.0, 1.0)));
    }
    if (transforms.isEmpty) return;
    c.sprites(particleSprite, transforms, rects, colors);
  }

  /// Ribbons: where each bird was over the last frames, thinning and fading into the
  /// past, in a colour of its own between [a] and [b], added.
  void _ribbons(FlockSurface c, Size s, _Cue l, Color a, Color b, {required double width, required double glow, int? len}) {
    final n = math.min(len ?? _histLen, _histN);
    if (n < 2) return;
    final m = model;
    var q = 0;
    for (var k = 0; k < _triN; k++) {
      final i = _triBird[k];
      final al = m.alpha[i];
      if (al <= 0.01) continue;
      final col = Color.lerp(a, b, m.seedOf[i])!;
      final w0 = width * _sc[i] * m.size[i] * (1 + 0.4 * l.kick);
      var px0 = _sx[i], py0 = _sy[i];
      for (var h = 1; h < n; h++) {
        final at = (_histAt - h + _histLen * 2) % _histLen;
        final o = (i * _histLen + at) * 2;
        final hx = _hist[o], hy = _hist[o + 1];
        if (hx < -1e8) break;
        final t0 = (h - 1) / n, t1 = h / n;
        final dx = hx - px0, dy = hy - py0;
        final dl = math.sqrt(dx * dx + dy * dy) + 1e-6;
        // too long a stride is a cut or a jump: the ribbon ends
        if (dl > s.height * 0.12) break;
        final nx = -dy / dl, ny = dx / dl;
        final ww0 = w0 * math.pow(1 - t0, 0.7), ww1 = w0 * math.pow(1 - t1, 0.7);
        final c0 = _argb(col.withValues(alpha: (al * glow * math.pow(1 - t0, 1.6)).clamp(0.0, 1.0)));
        final c1 = _argb(col.withValues(alpha: (al * glow * math.pow(1 - t1, 1.6)).clamp(0.0, 1.0)));
        final p = q * 12;
        _ribbonPos[p] = px0 + nx * ww0;
        _ribbonPos[p + 1] = py0 + ny * ww0;
        _ribbonPos[p + 2] = px0 - nx * ww0;
        _ribbonPos[p + 3] = py0 - ny * ww0;
        _ribbonPos[p + 4] = hx - nx * ww1;
        _ribbonPos[p + 5] = hy - ny * ww1;
        _ribbonPos[p + 6] = px0 + nx * ww0;
        _ribbonPos[p + 7] = py0 + ny * ww0;
        _ribbonPos[p + 8] = hx - nx * ww1;
        _ribbonPos[p + 9] = hy - ny * ww1;
        _ribbonPos[p + 10] = hx + nx * ww1;
        _ribbonPos[p + 11] = hy + ny * ww1;
        final cc = q * 6;
        _ribbonCol[cc] = c0;
        _ribbonCol[cc + 1] = c0;
        _ribbonCol[cc + 2] = c1;
        _ribbonCol[cc + 3] = c0;
        _ribbonCol[cc + 4] = c1;
        _ribbonCol[cc + 5] = c1;
        q++;
        px0 = hx;
        py0 = hy;
      }
    }
    if (q == 0) return;
    c.vertices(Float32List.sublistView(_ribbonPos, 0, q * 12), Int32List.sublistView(_ribbonCol, 0, q * 6), blend: BlendMode.plus);
  }

  /// A plexus: every bird a dot, lines to its nearest neighbours where they are
  /// close, the closer the brighter, in three strengths.
  void _wire(FlockSurface c, Size s, _Cue l, Color line, Color dot) {
    if (_triN == 0) return;
    final m = model;
    final strong = <double>[], mid = <double>[], faint = <double>[], dots = <double>[];
    for (var k = 0; k < _triN; k++) {
      final i = _triBird[k];
      if (m.alpha[i] < 0.3) continue;
      dots
        ..add(_sx[i])
        ..add(_sy[i]);
      for (var q = 0; q < 3; q++) {
        final j = m.link[i * 3 + q];
        if (j < 0) break;
        if (j < i || _on[j] == 0 || m.alpha[j] < 0.3) continue;
        final d = m.linkD[i * 3 + q] / math.max(0.1, 0.95 + 0.55 * l.beat);
        final into = d < 0.4 ? strong : (d < 0.7 ? mid : faint);
        into.addAll([_sx[i], _sy[i], _sx[j], _sy[j]]);
      }
    }
    final glow = 0.75 + 0.25 * l.beat;
    for (final (pts, alpha) in [(faint, 0.28), (mid, 0.6), (strong, 1.0)]) {
      if (pts.isEmpty) continue;
      c.lines(Float32List.fromList(pts), (s.height * 0.0018).clamp(1.0, 2.5), line.withValues(alpha: alpha * glow), blend: BlendMode.plus);
    }
    // The birds themselves are the net's knots; a dot only while the scan is not in.
    if (dots.isNotEmpty && !birds.ready) {
      c.dots(Float32List.fromList(dots), (s.height * 0.0045).clamp(2.0, 6.0), dot);
    }
  }

  /// The chronophotograph's stamps: the flock's shapes every half beat (a quarter in
  /// a drop), added, the older dimmer — the roughest level of detail, a silhouette.
  void _chrono(FlockSurface c, DanceCam cam, _Cue l, Color tint) {
    final step = l.rage ? 0.25 : 0.5;
    final count = l.rage ? 8 : 6;
    final last = (l.beats / step).floor() * step;
    final mesh = birds.mesh, steer = _steer;
    if (last > _stampLast && mesh != null && steer != null) {
      _stampLast = last;
      _batch.beginStamp();
      final m = model;
      for (var i = 0; i < FlockModel.most; i++) {
        if (_on[i] == 0 || m.alpha[i] <= 0.3) continue;
        var fx = m.vx[i], fy = m.vy[i], fz = m.vz[i];
        final fl = math.sqrt(fx * fx + fy * fy + fz * fz) + 1e-6;
        _batch.bird(c, mesh, mesh.far, cam, m.px[i], m.py[i], m.pz[i], fx / fl, fy / fl, fz / fl, m.size[i],
            m.wing(i, steer.beats, steer.flapsPerBeat, steer.flapAmp, steer.glide), BirdShade.flat, const BirdLight());
      }
      _stamps.add((last, _batch.endStamp(c)));
      while (_stamps.length > count) {
        _stamps.removeAt(0);
      }
    }
    for (final (at, stamp) in _stamps) {
      final age = ((l.beats - at) / (step * count)).clamp(0.0, 1.0);
      final a = 0.16 * math.pow(1 - age, 1.6);
      if (a < 0.02) continue;
      stamp.draw(c, Color.lerp(tint, Colors.white, 0.25)!.withValues(alpha: a.toDouble()));
    }
  }

  /// A dusk: the birds black against a sky the finish paints (flock_fx.frag's sky:
  /// a wash from a deep top to a warm horizon, dithered so it does not band, and a
  /// low sun that flares on the kick), the far ones paler in the haze. Drawn on
  /// nothing, so the finish lays them over its sky.
  void _sky(FlockSurface c, Size s, DanceCam cam, _Cue l) {
    final pal = l.st.palette;
    _skyTop = HSLColor.fromAHSL(1, pal.primary.hue, 0.5, 0.09).toColor();
    _skyHorizon = HSLColor.fromAHSL(1, pal.accent.hue, 0.7, 0.5 * (0.85 + 0.15 * l.beat)).toColor();
    final mid = HSLColor.fromAHSL(1, pal.primary.hue, 0.45, 0.3).toColor();
    // The horizon on the picture: the floor's far edge, from this camera.
    final (_, hy, hd) = cam.project(const V3(0, 60, 0));
    final hz = hd > DanceCam.near ? hy.clamp(s.height * 0.35, s.height * 0.95) : s.height * 0.78;
    _horizonK = hz / s.height;
    _sunPx = s.height * 0.075;
    _popAt = Offset(0.5 + 0.22 * math.sin((l.st.master.trackId ?? 1) * 1.0), (hz - s.height * 0.02) / s.height);
    // Against the light: dark, the sun's warmth at their edges, the key from where the
    // sun is (low, ahead).
    final sunX = (_popAt.dx - 0.5) * 2;
    _pigeons(
        c,
        cam,
        BirdShade.lit,
        BirdLight(
          keyX: sunX,
          keyY: 1,
          keyZ: 0.15,
          keyK: 0.5,
          ambient: 0.18,
          tint: Color.lerp(const Color(0xffffffff), mid, 0.5)!,
          rim: Color.lerp(_skyHorizon, Colors.white, 0.3)!,
          rimK: 0.9 + 0.4 * l.kick,
        ));
  }

  /// The flock as pigeons: every flying bird on the picture, far to near, the nearest
  /// at full detail, in [shade] under [light]. Until the scan is in, chevrons in the
  /// light's flat colour (or tint).
  void _pigeons(FlockSurface c, DanceCam cam, BirdShade shade, BirdLight light,
      {bool textured = true, double alphaK = 1, BlendMode blend = BlendMode.srcOver, Color Function(int i)? rimBy}) {
    final mesh = birds.mesh, skin = birds.skin, steer = _steer;
    if (mesh == null || skin == null || steer == null) {
      _wings(c, (i) => shade == BirdShade.flat ? light.flat : light.tint, alphaK: alphaK * (shade == BirdShade.flat ? 1 : 0.9));
      return;
    }
    final m = model;
    _byDepth.clear();
    _bySize.clear();
    for (var i = 0; i < FlockModel.most; i++) {
      if (_on[i] == 0 || m.alpha[i] <= 0.02) continue;
      _byDepth.add(i);
      _bySize.add(i);
    }
    if (_byDepth.isEmpty) return;
    _byDepth.sort((a, b) => _sd[b].compareTo(_sd[a]));
    _bySize.sort((a, b) => (_sc[b] * m.size[b]).compareTo(_sc[a] * m.size[a]));
    for (var r = 0; r < _bySize.length; r++) {
      _rank[_bySize[r]] = r;
    }
    _batch
      ..setSkin(skin)
      ..begin();
    for (final i in _byDepth) {
      var fx = m.vx[i], fy = m.vy[i], fz = m.vz[i];
      final fl = math.sqrt(fx * fx + fy * fy + fz * fz) + 1e-6;
      fx /= fl;
      fy /= fl;
      fz /= fl;
      final px = _sc[i] * mesh.wingspan * m.size[i] * _sizeK;
      final lod = mesh.pick(px, _rank[i]);
      final flap = m.wing(i, steer.beats, steer.flapsPerBeat, steer.flapAmp, steer.glide);
      final lt = rimBy == null ? light : BirdLight(keyX: light.keyX, keyY: light.keyY, keyZ: light.keyZ, keyK: light.keyK, ambient: light.ambient, tint: light.tint, rim: rimBy(i), rimK: light.rimK, flat: light.flat);
      _batch.bird(c, mesh, lod, cam, m.px[i], m.py[i], m.pz[i], fx, fy, fz, m.size[i] * _sizeK, flap, shade, lt,
          textured: textured, blend: blend, alpha: (m.alpha[i] * alphaK * light.alpha).clamp(0.0, 1.0));
    }
    _batch.flush(c);
  }

  // ------------------------------------------------------------------ the finish

  /// The ascii, dither, contour, halftone, thermal, ridgeline or radar finish over
  /// the flock's light (flock_fx.frag).
  ui.Image _post(ui.Image img, int w, int h, StagePrograms p, _Cue l, FlockLook look) {
    final crt = look == FlockLook.crt;
    final program = p.sims[crt ? 'dance_fx' : 'flock_fx'];
    if (program == null) return img;
    final fx = crt ? (_crtFx ??= program.fragmentShader()) : (_fx ??= program.fragmentShader());
    final glyphs = _glyphs ??= _makeGlyphs();
    final (:mode, :ink, :paper, :cell, :tint) = _postParams(l, look, h);
    fx
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, mode.toDouble())
      ..setFloat(3, cell)
      ..setFloat(4, ink.r)
      ..setFloat(5, ink.g)
      ..setFloat(6, ink.b)
      ..setFloat(7, paper.r)
      ..setFloat(8, paper.g)
      ..setFloat(9, paper.b)
      ..setFloat(10, tint)
      ..setFloat(11, _ramp.length.toDouble())
      ..setFloat(12, l.kick.clamp(0.0, 1.0))
      ..setFloat(13, _popAt.dx)
      ..setFloat(14, _popAt.dy)
      ..setFloat(15, _t)
      // dance_fx's 16 is its alpha out (0: whole, as a canvas keeps it).
      ..setFloat(16, crt ? 0 : l.barSaw)
      ..setImageSampler(0, img)
      ..setImageSampler(1, glyphs);
    setFxKnobs(fx, 17, l.st, treatmentTunes.containsKey(look.name) ? look.name : null);
    final r = ui.PictureRecorder();
    Canvas(r).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx);
    final pic = r.endRecording();
    final out = pic.toImageSync(w, h);
    pic.dispose();
    img.dispose();
    return out;
  }

  /// The same finish on the native stage, over what the list drew so far.
  void _postNative(NativeFlockSurface s, int h, _Cue l, FlockLook look) {
    final crt = look == FlockLook.crt;
    final glyphs = s.texture(_glyphs ??= _makeGlyphs());
    if (glyphs == null) return;
    final (:mode, :ink, :paper, :cell, :tint) = _postParams(l, look, h);
    final name = treatmentTunes.containsKey(look.name) ? look.name : null;
    final k = name == null ? null : fxKnobs(l.st.macros.tune, name);
    s.d.postFx(
      program: crt ? 0 : 1,
      atlas: glyphs,
      // dance_fx's alpha out: whole, as a canvas keeps it.
      coverageOut: 0,
      sweep: crt ? 0 : l.barSaw,
      mode: mode,
      cell: cell,
      ink: ink,
      paper: paper,
      tint: tint,
      glyphs: _ramp.length,
      pop: l.kick.clamp(0.0, 1.0),
      popAt: _popAt,
      time: _t,
      knobs: k == null ? const [] : [k.weight, k.spacing, k.height, k.gain, k.size],
    );
  }

  /// The finish's colours and cell for [look] on a picture [h] high.
  ({int mode, Color ink, Color paper, double cell, double tint}) _postParams(_Cue l, FlockLook look, int h) {
    final q = _postDrawn(l, look, h);
    if (!treatmentTunes.containsKey(look.name)) return q;
    // Through the hands' knobs for the treatment (state/show/show_tune.dart).
    final t = tunedCell(l.st, look.name, q.cell, q.tint);
    return (mode: q.mode, ink: q.ink, paper: q.paper, cell: t.cell, tint: t.tint);
  }

  /// The finish's colours and cell as the look draws them, before the knobs.
  ({int mode, Color ink, Color paper, double cell, double tint}) _postDrawn(_Cue l, FlockLook look, int h) {
    final pal = l.st.palette;
    final mode = flockFxMode[look] ?? 1;
    final dark = HSLColor.fromAHSL(1, pal.primary.hue, 0.45, 0.035).toColor();
    return switch (look) {
      FlockLook.dither => (mode: mode, ink: const Color(0xffeee7d6), paper: HSLColor.fromAHSL(1, pal.primary.hue, 0.4, 0.07).toColor(), cell: math.max(2.0, h / 220), tint: 0.0),
      FlockLook.contour => (mode: mode, ink: pal.accent.withSaturation(0.85).withLightness(0.62).toColor(), paper: dark, cell: 0.0, tint: 0.0),
      FlockLook.halftone => (mode: mode, ink: pal.primary.withSaturation(0.9).withLightness(0.55).toColor(), paper: const Color(0xff050506), cell: math.max(4.0, h / (l.rage ? 90 : 120)), tint: 0.0),
      FlockLook.thermal => (mode: mode, ink: Colors.white, paper: Colors.black, cell: 0.0, tint: 0.0),
      FlockLook.lines => (mode: mode, ink: pal.accent.withSaturation(0.35).withLightness(0.85).toColor(), paper: const Color(0xff030303), cell: math.max(5.0, h / 64), tint: 0.0),
      FlockLook.radar => (
          mode: mode,
          ink: HSLColor.fromAHSL(1, pal.accent.hue, 0.85, 0.62).toColor(),
          paper: HSLColor.fromAHSL(1, pal.accent.hue, 0.5, 0.035).toColor(),
          cell: 0.0,
          tint: 0.0
        ),
      FlockLook.sky => (mode: mode, ink: _skyHorizon, paper: _skyTop, cell: _sunPx, tint: _horizonK),
      FlockLook.crt => (mode: mode, ink: crtInk, paper: crtPaper, cell: math.max(3.0, h / (l.rage ? 110 : 135)), tint: 0.2),
      _ => (mode: mode, ink: pal.accent.withSaturation(0.55).withLightness(0.78).toColor(), paper: const Color(0xff040404), cell: h / (l.rage ? 56 : 44), tint: 0.25),
    };
  }

  /// The glyph ramp, light to dense, white on clear, side by side.
  static ui.Image _makeGlyphs() {
    const gw = 24.0, gh = 40.0;
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    for (var i = 0; i < _ramp.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
            text: _ramp[i],
            style: const TextStyle(fontFamily: 'CourierPrime', fontFamilyFallback: ['monospace'], fontSize: 34, height: 1, color: Colors.white, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(i * gw + (gw - tp.width) / 2, (gh - tp.height) / 2));
      tp.dispose();
    }
    final pic = r.endRecording();
    final img = pic.toImageSync((gw * _ramp.length).round(), gh.round());
    pic.dispose();
    return img;
  }

  @override
  void dispose() {
    _fx?.dispose();
    _crtFx?.dispose();
    _fx = null;
    _out?.dispose();
    _out = null;
  }
}

int _argb(Color c) => ((c.a * 255).round() << 24) | ((c.r * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.b * 255).round();
