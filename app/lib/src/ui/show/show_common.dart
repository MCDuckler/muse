// The common block every scene shader reads (shaders/show/common.glsl), from the
// frame: the one list both stages hand their shaders — the Flutter stage
// (show_canvas.dart) and the native one (native_stage.dart).
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';
import 'scene.dart';

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
