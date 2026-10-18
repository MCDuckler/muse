// The rig and the look: round trips, the hands over a look, the words.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  const rig = ShowRig(
    ground: RigGround(kind: Ground.field, field: 'drift', dim: 0.5, knobs: {'m1': 0.3}),
    figure: RigFigure(kind: Figure.dancers, shade: Shade.chrome, dressing: Dressing.none, treatment: Treatment.ascii, camera: 'front', company: 'trio', knobs: {'m2': 1}),
    blend: RigBlend(ground: GroundMode.window, figure: FigureMode.same, strength: 0.7, auto: false),
    finish: RigFinish(trails: 0.3, bloom: 0.9, tone: 0, title: true, where: 'big', particles: ['sparks', 'dust']),
    locks: {RigSlot.ground, RigSlot.finish},
  );

  test('a rig comes back from its json whole', () {
    final back = ShowRig.fromJson(rig.toJson());
    expect(back, rig);
    expect(back.ground.knobs['m1'], 0.3);
    expect(back.figure.company, 'trio');
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

  test('the ways MilkDrop goes under a scene keep their numbers', () {
    expect(GroundModeMilk.ofMilkMix(ShowMacros.contrast), GroundMode.contrast);
    expect(GroundModeMilk.ofMilkMix(0), GroundMode.add);
    expect(GroundMode.contrast.milkMix, ShowMacros.contrast);
    expect(GroundMode.over.milkMix, -1);
    for (var i = 0; i < ShowMacros.milkMixes.length; i++) {
      expect(GroundModeMilk.ofMilkMix(i).name, ShowMacros.milkMixes[i].$1);
    }
  });

  test('the hands put MilkDrop under a look the way they asked, or take it away', () {
    const look = ShowRig(figure: RigFigure(kind: Figure.kinetic));
    final under = rigWithMacros(look, const ShowMacros(milkUnder: true, milkMix: 3));
    expect(under.ground.kind, Ground.milk);
    expect(under.blend.ground, GroundMode.window);
    final bare = rigWithMacros(look, const ShowMacros(milkUnder: false));
    expect(bare.ground.kind, Ground.black);
    // A look of MilkDrop itself is left alone.
    const milk = ShowRig(ground: RigGround.milk);
    expect(rigWithMacros(milk, const ShowMacros(milkUnder: false)).ground.kind, Ground.milk);
  });

  test('the words', () {
    expect(rig.word, 'field drift / dancers chrome none ascii · window');
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
    expect(back.rigFrom, isNull);
  });
}
