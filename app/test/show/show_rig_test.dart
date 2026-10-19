// The rig and the look: round trips, the hands over a look, the words.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  const rig = ShowRig(
    ground: RigGround(kind: Ground.field, field: 'drift', dim: 0.5, knobs: {'m1': 0.3}),
    figure: RigFigure(kind: Figure.dancers, shade: Shade.chrome, dressing: Dressing.none, treatment: Treatment.ascii, style: 'ascii', knobs: {'m2': 1}),
    blend: RigBlend(ground: GroundMode.window, figure: FigureMode.same, strength: 0.7, auto: false),
    finish: RigFinish(trails: 0.3, bloom: 0.9, tone: 0, title: true, where: 'big', particles: ['sparks', 'dust']),
    locks: {RigSlot.ground, RigSlot.finish},
  );

  test('a rig comes back from its json whole', () {
    final back = ShowRig.fromJson(rig.toJson());
    expect(back, rig);
    expect(back.ground.knobs['m1'], 0.3);
    expect(back.figure.style, 'ascii');
    expect(back.locks, {RigSlot.ground, RigSlot.finish});
    expect(back.finish.particles, ['sparks', 'dust']);
  });

  test('a name it does not know falls back, not over', () {
    final j = rig.toJson();
    (j['figure'] as Map)['treatment'] = 'holographic';
    (j['ground'] as Map)['kind'] = 'moon';
    final back = ShowRig.fromJson(j);
    expect(back.figure.treatment, Treatment.auto);
    expect(back.ground.kind, Ground.black);
  });

  test('the blend modes keep their numbers (under.frag\'s uMode, ws_blend)', () {
    expect(GroundMode.through.index, 0);
    expect(GroundMode.over.index, 1);
    expect(GroundMode.add.index, 2);
    expect(GroundMode.contrast.index, 11);
    expect(GroundMode.keyhole.index, 12);
    expect(GroundMode.values.length, 13, reason: 'a new mode goes at the end, and into under.frag and stage.cpp\'s clamp');
  });

  test('the blend comes from the answer: as drawn on black, the rule\'s way and its figures elsewhere', () {
    const p = ShowPool.none;
    const turntable = RigFigure(kind: Figure.turntable); // lights in the dark
    expect(p.blendFor(turntable, Ground.black).ground, GroundMode.over);
    expect(p.blendFor(turntable, Ground.cover).ground, GroundMode.dim, reason: 'lights on a picture: the picture dimmed');
    expect(p.blendFor(turntable, Ground.cover).figure, FigureMode.over);
    expect(p.blendFor(const RigFigure(kind: Figure.kinetic), Ground.wash).figure, FigureMode.same, reason: 'a full frame\'s rule says nothing of figures: its own way');
    // The strength the look had stays.
    expect(p.blendFor(turntable, Ground.cover, from: const RigBlend(strength: 0.4)).strength, 0.4);
  });

  test('the words', () {
    expect(rig.word, 'field drift / dancers ascii chrome none ascii · window');
    expect(const ShowRig(ground: RigGround.milk, figure: RigFigure(kind: Figure.birds)).word, 'milk / birds');
    expect(rig.withLock(RigSlot.ground, false).locks, {RigSlot.finish});
  });

  test('a look keeps its meta and its rig', () {
    final look = Look.fromJson({
      'id': 'mine',
      'name': 'Mine',
      'rig': rig.toJson(),
      'energy': [0.4, 1.0],
      'sections': ['drop'],
      'priority': 2,
      'instant': false,
      'hero': true,
    });
    expect(look.rig, rig);
    expect(look.meta.energy, (0.4, 1.0));
    expect(look.meta.instant, isFalse);
    expect(look.hero, isTrue);
    final back = Look.fromJson(look.toJson());
    expect(back.meta.sections, ['drop']);
    expect(back.meta.priority, 2);
  });

  test('the frame carries the rig, by name and as numbers', () {
    final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'), rig: rig);
    expect(st['rig.figure'], Figure.dancers.index);
    expect(st['rig.blend.ground'], GroundMode.window.index);
    final back = ShowState.fromJson(st.toJson());
    expect(back.rig, rig);
  });
}
