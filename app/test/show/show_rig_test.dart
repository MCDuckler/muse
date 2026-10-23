// The rig and the look: round trips, the hands over a look, the words.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  const rig = ShowRig(
    ground: RigGround(kind: Ground.field, field: 'drift', dim: 0.5, knobs: {'m1': 0.3}),
    figure: RigFigure(kind: Figure.dancers, shade: Shade.chrome, dressing: Dressing.none, treatment: Treatment.ascii, style: 'ascii', knobs: {'m2': 1}),
    blend: RigBlend(mask: Mask.keyhole, mix: Mix.screen, strength: 0.7),
    finish: RigFinish(trails: 0.3, bloom: 0.9, tone: 0, title: true, where: 'big', particles: ['sparks', 'dust']),
  );

  test('a rig comes back from its json whole', () {
    final back = ShowRig.fromJson(rig.toJson());
    expect(back, rig);
    expect(back.ground.knobs['m1'], 0.3);
    expect(back.figure.style, 'ascii');
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

  test('the masks and the blends keep their numbers (under.frag\'s uMask and uMix, ws_blend)', () {
    expect(Mask.values.map((m) => m.index), [0, 1, 2]);
    expect(Mix.normal.index, 0);
    expect(Mix.add.index, 1);
    expect(Mix.screen.index, 2);
    expect(Mix.contrast.index, 3);
    expect(Mix.values.length, 4, reason: 'a new blend goes at the end, and into under.frag and stage.cpp\'s clamp');
    expect(Ground.white.index, 7, reason: 'stage.cpp\'s ground kind 7');
  });

  test('the words', () {
    expect(rig.word, 'field drift / dancers ascii chrome none ascii · keyhole · screen');
    expect(const ShowRig(ground: RigGround.milk, figure: RigFigure(kind: Figure.birds)).word, 'milk / birds · normal');
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
    expect(st['rig.blend.mask'], Mask.keyhole.index);
    expect(st['rig.blend.mix'], Mix.screen.index);
    final back = ShowState.fromJson(st.toJson());
    expect(back.rig, rig);
  });
  test("the ghosts come back from their json, go out with the frame, and are none under two", () {
    const rig = ShowRig(figure: RigFigure(kind: Figure.blocks), ghosts: RigGhosts(count: 6, differ: 0.3));
    expect(ShowRig.fromJson(rig.toJson()), rig);
    expect(ShowRig.fromJson(const ShowRig().toJson()).ghosts, RigGhosts.none);
    expect(const RigGhosts(count: 1).on, isFalse);
    expect(RigGhosts.fromJson({'count': 40, 'differ': 3}), const RigGhosts(count: RigGhosts.most, differ: 1));
    // The working size's switch rides with the frame too (a stage in a window of its own).
    expect(ShowMacros.fromJson(const ShowMacros(adapt: false).toJson()).adapt, isFalse);
    expect(ShowMacros.fromJson(const ShowMacros().toJson()).adapt, isTrue);
  });
}
