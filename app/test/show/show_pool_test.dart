// The pool: the plan in it (show_plan.dart, its own tests), the switches and leans of
// the rest, the set it keeps, and what the old preferences and the old document become.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/ui/show/show_dance.dart' show DanceArt, DanceShot;
import 'package:muse/src/ui/show/show_flock.dart' show FlockLook, FlockShot;
import 'package:muse/src/ui/show/show_words.dart' show WordsStyle;

const _plainOnMilk = Combo(ground: 'milk', scene: 'dance-art', style: 'plain');

void main() {
  test('a switch off, and a lean kept between nought and two', () {
    final p = ShowPool.none.withOff('dancer.joe', true).withLean('move.long22', 5);
    expect(p.isOn('dancer.joe'), isFalse);
    expect(p.isOn('dancer.chris'), isTrue);
    expect(p.leanOf('move.long22'), 2);
    expect(p.leanOf('move.short1'), 1);
  });

  test('a world has one combination: its own background, unmasked, as drawn', () {
    final disco = combosOf('dance-art', Figure.dancers, fxs: const [Fx.none]).where((c) => c.style == 'disco').toList();
    expect(disco, [const Combo(ground: ownGround, scene: 'dance-art', style: 'disco')]);
    expect(combosOf('milk', Figure.none, fxs: const [Fx.none]), [const Combo(ground: ownGround, scene: 'milk', style: 'raw')]);
    // Under each effect too.
    expect(combosOf('milk', Figure.none).map((c) => c.fx), Fx.values);
    // Every other style: every background, mask, blend and effect.
    final plain = combosOf('dance-art', Figure.dancers).where((c) => c.style == 'plain');
    expect(plain, hasLength(comboGrounds.length * Mask.values.length * Mix.values.length * Fx.values.length));
    // A key with an effect, both ways; one from before the effects reads as none.
    const moshed = Combo(ground: 'milk', scene: 'kinetic', style: 'raw', fx: Fx.mosh);
    expect(Combo.fromKey(moshed.key), moshed);
    expect(Combo.fromKey('milk|kinetic|raw|none|normal'), const Combo(ground: 'milk', scene: 'kinetic', style: 'raw'));
    // The backgrounds narrowed to the ones here.
    expect(combosOf('kinetic', Figure.kinetic, grounds: ['milk']).map((c) => c.ground).toSet(), {'milk'});
  });

  test('the style lists are the figures\' own', () {
    expect(stylesOfFigure(Figure.dancers).toSet(), {for (final a in DanceArt.values) a.name});
    expect(stylesOfFigure(Figure.birds).toSet(), {for (final l in FlockLook.values) l.name});
    expect(stylesOfFigure(Figure.words).toSet(), {for (final w in WordsStyle.values) w.name});
    expect(stylesOfFigure(Figure.kinetic).first, 'raw');
  });

  test('a combination\'s key both ways; a background\'s key both ways', () {
    final c = _plainOnMilk.copyWith(mask: Mask.inverted, mix: Mix.screen);
    expect(Combo.fromKey(c.key), c);
    expect(Combo.fromKey('nonsense'), isNull);
    for (final g in comboGrounds) {
      expect(keyOfGround(groundOfKey(g)), g);
    }
    expect(groundOfKey('white').kind, Ground.white);
  });

  test('a look in a combination: the background, the style or the treatment, the mask and the blend', () {
    const dancer = Look(id: 'dance-art', name: 'Dancer', rig: ShowRig(figure: RigFigure(kind: Figure.dancers)));
    final r = dancer.inCombo(_plainOnMilk.copyWith(mask: Mask.keyhole, mix: Mix.contrast));
    expect(r.ground.kind, Ground.milk);
    expect(r.figure.style, 'plain');
    expect(r.blend, const RigBlend(mask: Mask.keyhole, mix: Mix.contrast));
    const kinetic = Look(id: 'kinetic', name: 'Kinetic', rig: ShowRig(figure: RigFigure(kind: Figure.kinetic)));
    final k = kinetic.inCombo(const Combo(ground: 'white', scene: 'kinetic', style: 'ascii'));
    expect(k.figure.treatment, Treatment.ascii);
    expect(k.ground.kind, Ground.white);
    // Another look's combination: the look as it is.
    expect(kinetic.inCombo(_plainOnMilk), kinetic.rig);
    const milk = Look(id: 'milk', name: 'MilkDrop', rig: ShowRig(ground: RigGround.milk));
    expect(milk.inCombo(const Combo(ground: ownGround, scene: 'milk', style: 'raw')).ground.kind, Ground.milk);
  });

  test('a weighted pick goes by the weights, and never to a weight of nought', () {
    final items = [('a', 0.0), ('b', 1.0), ('c', 3.0)];
    expect(pickByWeight(items, 0), 'b');
    expect(pickByWeight(items, 0.3), 'c');
    expect(pickByWeight(items, 0.999), 'c');
    expect(pickByWeight([('a', 0.0)], 0.5), isNull);
  });

  test('the tier and the dark beat are kept, and reach the statics', () {
    final p = ShowPool.none.copyWith(tier: 'low', darkBeat: true);
    final back = ShowPool.fromJson(p.toJson());
    expect(back.tier, 'low');
    expect(back.darkBeat, isTrue);
    expect(ShowPool.fromJson(const {'tier': 'ultra'}).tier, 'auto');
    QualityPool.from(back);
    expect(QualityPool.flockK, 0.45);
    expect(QualityPool.bigTroupes, isFalse);
    expect(QualityPool.workScale, 0.6);
    QualityPool.from(ShowPool.none);
    expect(QualityPool.workScale, 1);
  });

  test('the camera\'s framings are the figures\' own, and the clocks read their levels in the figure\'s scene', () {
    expect(shotsOfFigure(Figure.dancers).toSet(), {for (final s in DanceShot.values) if (s != DanceShot.full) 'dancers.${s.name}'});
    expect(shotsOfFigure(Figure.birds).toSet(), {for (final s in FlockShot.values) 'birds.${s.name}'});
    expect(shotsOfFigure(Figure.kinetic), isEmpty);
    StylePool.from(ShowPool.none.withPlan(ShowPlan.shipped.withIn('dance-art', PlanAxis.shot, 'fisheye', level: 0.5).withIn('flock', PlanAxis.shot, 'fish', muted: true)));
    expect(StylePool.shot(Figure.dancers, 'fisheye'), 0.5);
    expect(StylePool.shot(Figure.dancers, 'front'), 1);
    expect(StylePool.shot(Figure.birds, 'fish'), 0);
    StylePool.from(ShowPool.none);
  });

  test('json both ways; the old document\'s switches are not carried; the old rules wait to be read', () {
    final p = ShowPool.none
        .withOff('dancer.joe', true)
        .withLean('move.long22', 1.5)
        .withPlan(ShowPlan.shipped.withScene('glide', level: 1 / 3).withCell('dance-art', cellKey(style: 'ascii', ground: 'white'), 0))
        .copyWith(dancer: 'joe', quantise: Quantise.phrase, bias: 0.5, strength: 0.7, finish: const RigFinish(trails: 0.4));
    final back = ShowPool.fromJson(p.toJson());
    expect(back.off, {'dancer.joe'});
    expect(back.leanOf('move.long22'), 1.5);
    expect(back.plan, p.plan);
    expect(back.dancer, 'joe');
    expect(back.quantise, Quantise.phrase);
    expect(back.bias, 0.5);
    expect(back.strength, 0.7);
    expect(back.finish, const RigFinish(trails: 0.4));
    expect(back.legacy, isNull);
    expect(ShowPool.fromJson(const {}).quantise, Quantise.bar);
    final old = ShowPool.fromJson(const {
      'off': ['look.flash', 'ground.milk', 'treatment.contour', 'dancer.joe'],
      'lean': {'look.flock': 2, 'move.x': 2},
      'combos': {'figure.birds|ground.milk': {'off': true}},
    });
    expect(old.off, {'dancer.joe'});
    expect(old.lean.keys, ['move.x']);
    expect(old.legacy, isNull, reason: 'the map of the exceptions before the rules is not carried');
    final rules = ShowPool.fromJson(const {
      'combos': [
        {'scene': 'flash', 'weight': 0}
      ]
    });
    expect(rules.legacy, hasLength(1));
    expect(rules.plan, ShowPlan.shipped);
    expect(ShowPool.fromJson(rules.toJson()).legacy, hasLength(1), reason: 'kept until read');
  });

  test('a set: the plan, the effects, the temper, the knobs, the finish — not the machine\'s', () {
    final p = ShowPool.none.copyWith(
      plan: ShowPlan.shipped.withScene('flash', muted: true),
      mosh: 0.9,
      bias: -0.5,
      tune: const {'lines.weight': 1.3},
      tier: 'low',
      strength: 0.5,
      transform: TransformSet.standard.copyWith(count: 4, grain: 0.3),
    );
    final s = p.setup;
    expect(ShowSetup.fromJson(s.toJson()), s);
    final q = ShowPool.none.copyWith(tier: 'high').withSetup(s);
    expect(q.plan, p.plan);
    expect(q.mosh, 0.9);
    expect(q.transform.grain, 0.3);
    expect(q.tier, 'high', reason: 'the quality is the machine\'s');
    expect(q.setup, s);
    expect(ShowPool.none.setup, ShowSetup.shipped);
  });

  test('the old preferences become a scene off and dancers off', () {
    final p = ShowPool.migrated(scenesOff: ['flash', 'veins'], dancersOff: ['joe'], dancer: 'mix');
    expect(p.plan.sceneLevel('flash'), 0);
    expect(p.plan.sceneLevel('kinetic'), 1);
    expect(p.dancersOff, ['joe']);
    expect(p.dancer, isNull);
    expect(ShowPool.migrated(dancer: 'chris').dancer, 'chris');
  });

  test('the clocks read a style\'s level in the figure\'s scene', () {
    StylePool.from(ShowPool.none.withPlan(ShowPlan.shipped.withIn('flock', PlanAxis.style, 'ink', muted: true)));
    expect(StylePool.allows(Figure.birds, 'ink'), isFalse);
    expect(StylePool.weight(Figure.birds, 'neon'), 1);
    expect(StylePool.allows(Figure.dancers, 'contour'), isFalse, reason: 'as shipped');
    StylePool.from(ShowPool.none);
  });

  test('the transformation mode of before the effect row: held is that effect alone, the director\'s as shipped', () {
    ShowPlan read(Map<String, dynamic> t) => ShowPool.fromJson({'transform': t}).plan;
    final slit = read({'mode': 'slit', 'often': 0.15});
    expect(slit.levelIn('kinetic', PlanAxis.fx, 'slit'), greaterThan(0));
    for (final f in ['none', 'kaleidoscope', 'both', 'mosh']) {
      expect(slit.levelIn('kinetic', PlanAxis.fx, f), 0, reason: f);
    }
    final both = read({'mode': 'both'});
    expect(both.levelIn('kinetic', PlanAxis.fx, 'both'), 1, reason: 'shipped at 0: held, at 1');
    expect(read({'mode': 'none'}).levelIn('kinetic', PlanAxis.fx, 'mosh'), 0);
    expect(read({'mode': 'auto', 'often': 0.15}), ShowPlan.shipped);
    expect(read({'mode': 'auto', 'often': 0}).levelIn('kinetic', PlanAxis.fx, 'kaleidoscope'), 0);
    // Once: a plan with an effect row of its own is as it says.
    final mine = ShowPool.fromJson({
      'plan': ShowPlan.shipped.withShared(PlanAxis.fx, 'mosh', level: 2).toJson(),
      'transform': {'mode': 'slit'},
    }).plan;
    expect(mine.levelIn('kinetic', PlanAxis.fx, 'mosh'), 2);
    expect(mine.levelIn('kinetic', PlanAxis.fx, 'none'), 4);
  });
}
