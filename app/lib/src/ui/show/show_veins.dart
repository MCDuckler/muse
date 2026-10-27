// The veins on the native stage: a slime mould's network (native/stage/src/fx.h's
// Slime — agents on the GPU, their trail spreading and fading), its rules a frame as
// floats in SlimeAt's order (ws_words), worked out from the record here as the
// Flutter stage's PhysarumSim (show_sims.dart) works them out for its own agents:
//
//   how far ahead they look and how wide (the record's genome, the section), how fast
//   they go (the energy), how much they lay (the kick); the trail slower to fade in a
//   breakdown, so the old network lingers; the kick lighting it and the snare
//   scattering it; the palette's primary for the thin veins, the accent for the thick.
//
// The native map is 540 high where the CPU's was a sixth of that: distances and
// speeds are in its pixels.
import 'dart:typed_data';

import '../../state/show/show_pool.dart' show QualityPool;
import '../../state/show/show_state.dart';

class VeinsParams {
  VeinsParams._();

  /// SlimeAt's count of floats (kSlCount).
  static const count = 66;

  // SlimeAt's places (fx.h).
  static const _side = 0, _speed = 1, _angle = 2, _dist = 3, _turn = 4, _jitter = 5, _deposit = 6, _decay = 7, _diffuse = 8;
  static const _species = 9, _repel = 10, _seed = 11, _shape = 12, _share = 13;
  static const _look = 18, _exposure = 19, _time = 20, _kick = 21, _scatter = 22, _colour0 = 23, _food = 32, _scale = 65;

  static final _clock = Stopwatch()..start();

  /// The frame's floats for [st].
  static Float32List native(ShowState st) {
    final q = Float32List(count);
    final f = st.flat;
    final g = st.genome;
    final kick = f['audio.kick'] ?? 0;
    final energy = f['master.energy'] ?? 0;
    final breakdown = (f['master.breakdown'] ?? 0) > 0.5;
    final section = st.master.section;
    final lookGene = g.isEmpty ? 7.0 : g['veins.look'];
    final look = lookGene * switch (section) { 'breakdown' || 'break' => 1.3, 'build' => 0.6, 'drop' => 0.85, _ => 1.0 };
    final wide = (g.isEmpty ? 0.4 : g['veins.wide']) * switch (section) { 'breakdown' || 'break' => 0.75, 'drop' => 1.5, _ => 1.0 };
    final turn = (g.isEmpty ? 0.3 : g['veins.turn']) + 0.25 * energy;
    final decayGene = g.isEmpty ? 0.86 : g['veins.decay'];
    // A sixth of the map's height was the CPU's grid: three times its cells here.
    q[_side] = switch (QualityPool.tier) { 'low' => 192, 'mid' => 256, _ => 320 };
    q[_speed] = (0.25 + 0.45 * energy) * 3;
    q[_angle] = wide;
    q[_dist] = look * 3;
    q[_turn] = turn;
    q[_jitter] = 0.15;
    q[_deposit] = (0.6 + 0.8 * kick) * 0.15;
    q[_decay] = breakdown ? decayGene + 0.05 : decayGene;
    q[_diffuse] = 0.5;
    q[_species] = 1;
    q[_repel] = 0;
    // Born again for each record, anywhere, all of them.
    q[_seed] = ((st.master.trackId ?? 0) % 9973).toDouble();
    q[_shape] = 0;
    q[_share] = 1;
    q[_look] = 0;
    q[_exposure] = 0.3;
    q[_time] = _clock.elapsedMicroseconds / 1e6;
    q[_kick] = (f['dyn.hit.kick'] ?? 0).clamp(0.0, 1.0);
    q[_scatter] = (f['dyn.hit.snare'] ?? 0).clamp(0.0, 1.0);
    final pal = st.palette;
    final colours = [pal.primary.toColor(), pal.accent.toColor(), pal.secondary.toColor()];
    for (var k = 0; k < 3; k++) {
      q[_colour0 + k * 3] = colours[k].r;
      q[_colour0 + k * 3 + 1] = colours[k].g;
      q[_colour0 + k * 3 + 2] = colours[k].b;
    }
    q[_food] = 0;
    q[_scale] = 0.5;
    return q;
  }
}
