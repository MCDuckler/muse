// The common block every scene shader reads (shaders/show/common.glsl), from the
// frame: the one list both stages hand their shaders — the Flutter stage
// (show_canvas.dart) and the native one (native_stage.dart).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Color, Colors, HSLColor;

import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';
import '../../state/show/show_tune.dart';
import 'scene.dart';
import 'show_meme_bank.dart' show memeHash;

/// The finish for [scene] in [st]: the frame's rig's (the look's, with the hands'
/// where locked), or the scene file's own while the frame carries no rig (a feed
/// that knows no looks, a test).
RigFinish finishOf(Scene scene, ShowState st) => st.rig == ShowRig.none ? scene.rig.finish : st.rig.finish;

/// uTime .. uBarIndex (the block after uResolution), for [layer] of a scene at
/// [time] seconds of the stage's own clock.
List<double> commonBlock(ShowState st, SceneLayer layer, double time) {
  final f = st.flat;
  const master = 'master';
  return [
    time,
    f['$master.beat.phase'] ?? 0,
    f['$master.bar.phase'] ?? 0,
    f['$master.phrase.phase'] ?? 0,
    f['$master.energy'] ?? 0,
    f['intensity'] ?? 0,
    f['audio.kick'] ?? 0,
    f['audio.low'] ?? 0,
    f['audio.mid'] ?? 0,
    f['audio.high'] ?? 0,
    f['audio.air'] ?? 0,
    f['audio.onset'] ?? 0,
    f['palette.primary.h'] ?? 0,
    f['palette.secondary.h'] ?? 0,
    f['$master.drop.near'] ?? 0,
    f['$master.build.k'] ?? 0,
    f['show.hit'] ?? 0,
    f['$master.vocal'] ?? 0,
    for (var k = 1; k <= 4; k++) layerKnob(layer, k, st),
    // The dynamics.
    f['dyn.hit.kick'] ?? 0,
    f['dyn.hit.snare'] ?? 0,
    f['dyn.hit.top'] ?? 0,
    f['dyn.beat.decay'] ?? 0,
    f['dyn.bar.decay'] ?? 0,
    f['dyn.bar.saw'] ?? 0,
    f['dyn.phrase.saw'] ?? 0,
    f['dyn.downbeat'] ?? 0,
    f['dyn.exposure'] ?? 0.7,
    f['dyn.band.low'] ?? 0,
    f['dyn.band.mid'] ?? 0,
    f['dyn.band.high'] ?? 0,
    f['$master.bar.index'] ?? 0,
  ];
}

/// A layer's knob: the record's genome where the scene reads one, else the file's.
double layerKnob(SceneLayer layer, int k, ShowState st) {
  final g = st.genome;
  if (!g.isEmpty) {
    if (layer.shader == 'echo' && k <= 3) return [g['camera.zoom'], g['camera.turn'], g['camera.hue']][k - 1];
    if (layer.shader == 'fold' && k == 1) return g['camera.fold'];
    if (layer.shader == 'blocks' && k == 1) return g['blocks.salt'];
    if (layer.shader == 'kinetic' && k == 1) return g['kinetic.salt'];
    if (layer.shader == 'glide' && k == 1) return g['glide.salt'];
  }
  return layer.knob(k);
}

/// The trails' recipe (shaders/show/feedback.frag) for [scene]: decay, zoom, rotate,
/// tint, the tint's RGB, fold, warp, hue turn, drift x and y — the record's genome,
/// as much of it as the scene takes (its post.recipe).
List<double> trailRecipe(Scene scene, ShowState st) {
  final fin = finishOf(scene, st);
  final k = fin.recipe;
  final g = st.genome;
  double gene(String name, double or) => g.isEmpty ? or : or + (g[name] - or) * k;
  final secondary = st.palette.secondary.toColor();
  return [
    gene('feedback.decay', fin.trails),
    gene('feedback.zoom', 1.0 + 0.010 * (st.flat['master.energy'] ?? 0)),
    gene('feedback.rotate', 0.003),
    0.12,
    secondary.r,
    secondary.g,
    secondary.b,
    k >= 0.5 && !g.isEmpty ? g['feedback.fold'] : 0,
    gene('feedback.warp', 0),
    gene('feedback.hueTurn', 0),
    gene('feedback.shiftX', 0),
    gene('feedback.shiftY', 0),
  ];
}

/// White over the stage: the strobe (on every other sixteenth while held) and the
/// hands' hit, as the finish takes it.
double stageWhite(ShowState st) {
  final beat = st.flat['master.beat.phase'] ?? 0;
  final strobe = st.macros.strobe > 0 && ((beat * 4).floor() % 2 == 0) ? st.macros.strobe : 0.0;
  return strobe > st.macros.hit * 0.7 ? strobe : st.macros.hit * 0.7;
}

/// The treatment knobs (uWeight, uSpacing, uHeight, uGain, uSize) of dance_fx.frag
/// and flock_fx.frag, from [st]'s tune for [treatment], into [s] from float [at].
/// No treatment (a lens) sets them to 0: the shader's own look.
void setFxKnobs(ui.FragmentShader s, int at, ShowState st, String? treatment) {
  final k = treatment == null ? null : fxKnobs(st.macros.tune, treatment);
  s
    ..setFloat(at, k?.weight ?? 0)
    ..setFloat(at + 1, k?.spacing ?? 0)
    ..setFloat(at + 2, k?.height ?? 0)
    ..setFloat(at + 3, k?.gain ?? 0)
    ..setFloat(at + 4, k?.size ?? 0);
}

/// A treatment's cell (an ascii's letter height, a dither's dot, the ridgelines'
/// gap…) of [cell] as drawn, through [st]'s knobs; and its tint, where it has one.
({double cell, double tint}) tunedCell(ShowState st, String treatment, double cell, double tint) {
  final tune = st.macros.tune;
  return (
    cell: cell * fxKnobs(tune, treatment).cell,
    tint: (treatmentTunes[treatment]?.any((s) => s.knob == TuneKnob.tint) ?? false) ? (tune[tuneKey(treatment, TuneKnob.tint)] ?? tint) : tint,
  );
}

/// The treatment [rig] puts its figure through, as dance_fx.frag draws it over a
/// picture [h] high — its mode, its colours from [st]'s palette, its cell and tint
/// through the knobs — for either stage (show_canvas.dart's pass, the native stage's
/// ws_treat); null where there is none for a stage to draw: none asked for, or the
/// figure draws it itself as its own style (the dancers', the birds').
/// The slit-scan's shape and which way it runs (fx.h's Slit: the cell and the tint
/// carry them), another every four phrases of the record: the style's and the layer's.
({double shape, double flip}) slitShapeOf(ShowState st) {
  final n = ((st.master.barIndex ?? 0) / 16).floor();
  final salt = (st.master.trackId ?? 0) % 9973;
  return (shape: (memeHash(salt, n, 41) * 6).floorToDouble().clamp(0.0, 5.0), flip: memeHash(salt, n, 43) < 0.3 ? 1.0 : 0.0);
}

({Treatment t, int mode, Color ink, Color paper, double cell, double tint})? treatOf(ShowRig rig, ShowState st, int h) {
  final fig = rig.figure;
  // The dancers' slit-scan is the stage's pass over what they draw (they cannot draw
  // their own past), where every other style of theirs is their own.
  final t = fig.style == 'slit' ? Treatment.slit : fig.treatment;
  if (fig.kind == Figure.none || !imageTreatments.contains(t) || (fig.style == t.name && t != Treatment.slit)) return null;
  if (t == Treatment.slit) {
    final s = slitShapeOf(st);
    return (t: t, mode: 9, ink: Colors.white, paper: Colors.black, cell: s.shape, tint: s.flip);
  }
  final pal = st.palette;
  final dark = HSLColor.fromAHSL(1, pal.primary.hue, 0.45, 0.035).toColor();
  // The looks as the dancers' finish draws them.
  final (ink, paper, cell, tint) = switch (t) {
    Treatment.dither => (const Color(0xffeee7d6), HSLColor.fromAHSL(1, pal.primary.hue, 0.4, 0.07).toColor(), math.max(2.0, h / 220), 0.0),
    Treatment.contour => (pal.accent.withSaturation(0.85).withLightness(0.62).toColor(), dark, 0.0, 0.0),
    Treatment.halftone => (pal.primary.withSaturation(0.9).withLightness(0.55).toColor(), const Color(0xff050506), math.max(4.0, h / 110), 0.0),
    Treatment.thermal => (Colors.white, Colors.black, 0.0, 0.0),
    Treatment.crt => (crtInk, crtPaper, math.max(3.0, h / 135), 0.2),
    Treatment.lines => (pal.accent.withSaturation(0.35).withLightness(0.85).toColor(), const Color(0xff030303), math.max(5.0, h / 72), 0.0),
    _ => (pal.accent.withSaturation(0.55).withLightness(0.78).toColor(), const Color(0xff040404), h / 44, 0.2),
  };
  final tuned = tunedCell(st, t.name, cell, tint);
  return (t: t, mode: treatmentFxMode[t.name] ?? 1, ink: ink, paper: paper, cell: tuned.cell, tint: tuned.tint);
}

/// The crt's lavender white and its near-black (dance_fx.frag's ramp ends).
const crtInk = Color(0xfff6dcff), crtPaper = Color(0xff07020f);
