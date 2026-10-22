// The pool: the combinations' rules (cards multiply, the most particular exception
// says the rest), the switches and leans of the rest, and what the old preferences
// and the old document become.
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

  test('nothing said: every combination at 1', () {
    expect(comboWeight(_plainOnMilk, const []), 1);
    expect(comboWeight(_plainOnMilk.copyWith(mask: Mask.keyhole, mix: Mix.contrast), const []), 1);
  });

  test('cards multiply; the most particular exception says the rest; a tie, the later', () {
    const rules = [
      ComboRule(grounds: {'milk'}, weight: 3),
      ComboRule(mixes: {Mix.contrast}, weight: 2),
      ComboRule(scenes: {'dance-art'}, grounds: {'milk'}, weight: 0.5),
      ComboRule(scenes: {'dance-art'}, grounds: {'milk'}, styles: {'plain'}, weight: 4),
    ];
    // Normal on MilkDrop: MilkDrop's card 3 × the most particular exception 4.
    expect(comboWeight(_plainOnMilk, rules), 12);
    // Contrast: × 2 more.
    expect(comboWeight(_plainOnMilk.copyWith(mix: Mix.contrast), rules), 24);
    // Another style: the less particular exception.
    expect(comboWeight(_plainOnMilk.copyWith(style: 'mono'), rules), 1.5);
    // Two exceptions as particular as each other: the later one.
    const tie = [ComboRule(scenes: {'dance-art'}, grounds: {'milk'}, weight: 0), ComboRule(scenes: {'dance-art'}, styles: {'plain'}, weight: 2)];
    expect(comboWeight(_plainOnMilk, tie), 2);
    final why = explainWeight(_plainOnMilk, rules);
    expect(why.cards, [rules[0]]);
    expect(why.exception, rules[3]);
  });

  test('an exception may bring one combination back from a less particular one, never from a card at 0', () {
    const rules = [ComboRule(grounds: {'white'}, mixes: {Mix.add}, weight: 0), ComboRule(grounds: {'white'}, mixes: {Mix.add}, styles: {'plain'}, weight: 1)];
    const add = Combo(ground: 'white', scene: 'dance-art', style: 'plain', mix: Mix.add);
    expect(comboWeight(add, rules), 1);
    expect(comboWeight(add.copyWith(style: 'mono'), rules), 0);
    expect(comboWeight(add, [...rules, const ComboRule(scenes: {'dance-art'}, weight: 0)]), 0);
  });

  test('a batch: a few things of a row in one rule, the narrower of two exceptions the more particular', () {
    const batch = ComboRule(scenes: {'turntable'}, masks: {Mask.keyhole}, mixes: {Mix.add, Mix.screen}, weight: 0);
    const tt = Combo(ground: 'milk', scene: 'turntable', style: 'raw', mask: Mask.keyhole, mix: Mix.add);
    expect(batch.matches(tt), isTrue);
    expect(batch.matches(tt.copyWith(mix: Mix.screen)), isTrue);
    expect(batch.matches(tt.copyWith(mix: Mix.contrast)), isFalse);
    expect(batch.matches(tt.copyWith(mask: Mask.inverted)), isFalse);
    expect(batch.pattern, '*|turntable|*|keyhole|add,screen');
    expect(batch.breadth, 2);
    expect(comboWeight(tt, const [batch]), 0);
    expect(comboWeight(tt.copyWith(mix: Mix.contrast), const [batch]), 1);
    // As many things said, the narrower wins whatever the order.
    const one = ComboRule(scenes: {'turntable'}, masks: {Mask.keyhole}, mixes: {Mix.add}, weight: 2);
    expect(comboWeight(tt, const [one, batch]), 2);
    expect(comboWeight(tt, const [batch, one]), 2);
    expect(comboWeight(tt.copyWith(mix: Mix.screen), const [one, batch]), 0);
    // A few cards of a row: each of them carries the weight.
    final p = ShowPool.none.withRule(const ComboRule(mixes: {Mix.add, Mix.screen}), 0.5);
    expect(p.cardWeight(ComboAxis.mix, 'add'), 0.5);
    expect(p.cardWeight(ComboAxis.mix, 'screen'), 0.7 * 0.5);
    expect(p.cardWeight(ComboAxis.mix, 'normal'), 1);
    // A row said again; none is any.
    expect(batch.withOn(ComboAxis.mix, {'contrast'}).mixes, {Mix.contrast});
    expect(batch.withOn(ComboAxis.mix, {}).mixes, isNull);
    expect(batch.withOn(ComboAxis.ground, {'milk', 'white'}).on(ComboAxis.ground), {'milk', 'white'});
    // Json: one thing a word, a few a list.
    expect(batch.toJson(), {'scene': 'turntable', 'mask': 'keyhole', 'mix': ['add', 'screen'], 'weight': 0.0});
    expect(ComboRule.fromJson(batch.toJson()), batch);
    expect(ComboRule.fromJson(const {'mix': <String>[], 'weight': 1}), isNull);
  });

  test('as shipped: plain dancers on white and on MilkDrop are both in the rotation; nothing masked on black; nothing added onto white', () {
    const p = ShowPool.none;
    expect(p.weightOf(_plainOnMilk), greaterThan(0));
    expect(p.weightOf(_plainOnMilk.copyWith(ground: 'white')), greaterThan(0));
    expect(p.weightOf(_plainOnMilk.copyWith(ground: 'black', mask: Mask.keyhole)), 0);
    expect(p.weightOf(_plainOnMilk.copyWith(ground: 'black', mix: Mix.contrast)), 0);
    expect(p.weightOf(_plainOnMilk.copyWith(ground: 'white', mix: Mix.add)), 0);
    // MilkDrop the background most often.
    expect(p.weightOf(_plainOnMilk), greaterThan(p.weightOf(_plainOnMilk.copyWith(ground: 'wash'))));
    expect(p.weightOf(_plainOnMilk.copyWith(style: 'contour')), 0);
  });

  test('a rule of the hands\' takes the place of the shipped one for the same pattern, and goes again', () {
    const milk = ComboRule(grounds: {'milk'});
    var p = ShowPool.none.withRule(milk, 1);
    expect(p.cardOf(milk), 1);
    expect(p.allRules.where((r) => r.pattern == milk.pattern), hasLength(1));
    p = p.withRule(milk, 0);
    expect(p.rules, hasLength(1));
    expect(p.milkOn, isFalse);
    expect(p.weightOf(_plainOnMilk), 0);
    p = p.withRule(milk, null);
    expect(p.cardOf(milk), 3);
    expect(p.withMilk(false).withMilk(true).rules, isEmpty);
    expect(p.withScene('flash', false).sceneOn('flash'), isFalse);
  });

  test('a world has one combination: its own background, unmasked, as drawn', () {
    final disco = combosOf('dance-art', Figure.dancers).where((c) => c.style == 'disco').toList();
    expect(disco, [const Combo(ground: ownGround, scene: 'dance-art', style: 'disco')]);
    expect(combosOf('milk', Figure.none), [const Combo(ground: ownGround, scene: 'milk', style: 'raw')]);
    // Every other style: every background, mask and blend.
    final plain = combosOf('dance-art', Figure.dancers).where((c) => c.style == 'plain');
    expect(plain, hasLength(comboGrounds.length * Mask.values.length * Mix.values.length));
    // The backgrounds narrowed to the ones here.
    expect(combosOf('kinetic', Figure.kinetic, grounds: ['milk']).map((c) => c.ground).toSet(), {'milk'});
  });

  test('the camera: its rules lean the framings, never how often a combination comes', () {
    expect(shotsOfFigure(Figure.dancers).toSet(), {for (final s in DanceShot.values) if (s != DanceShot.full) 'dancers.${s.name}'});
    expect(shotsOfFigure(Figure.birds).toSet(), {for (final s in FlockShot.values) 'birds.${s.name}'});
    expect(shotsOfFigure(Figure.kinetic), isEmpty);
    const ascii = Combo(ground: 'milk', scene: 'dance-art', style: 'ascii');
    const rules = [
      ComboRule(shots: {'dancers.fisheye', 'dancers.fisheyeLow'}, weight: 0.5),
      ComboRule(styles: {'ascii'}, shots: {'dancers.fisheye', 'dancers.fisheyeLow'}, weight: 0),
      ComboRule(scenes: {'dance-art'}, shots: {'dancers.close'}, weight: 2),
    ];
    // Not a combination's weight.
    expect(comboWeight(ascii, rules), 1);
    // The cards multiply, the exception says the rest.
    expect(shotWeight(ascii, 'dancers.fisheye', rules), 0);
    expect(shotWeight(ascii.copyWith(style: 'plain'), 'dancers.fisheye', rules), 0.5);
    expect(shotWeight(ascii, 'dancers.close', rules), 2);
    expect(shotWeight(ascii, 'dancers.front', rules), 1);
    // Nothing on: the cards alone.
    expect(shotWeight(null, 'dancers.fisheye', rules), 0.5);
    expect(shotWeight(null, 'dancers.close', rules), 1);
    // The pattern and json say the camera after the five.
    expect(rules[1].pattern, '*|*|ascii|*|*|dancers.fisheye,dancers.fisheyeLow');
    expect(rules[0].card, isTrue);
    expect(ComboRule.fromJson(rules[1].toJson()), rules[1]);
    expect(rules[1].toJson()['shot'], ['dancers.fisheye', 'dancers.fisheyeLow']);
    // The clocks' reading: by the combination on.
    StylePool.from(ShowPool.none.copyWith(rules: rules));
    StylePool.combo = ascii;
    expect(StylePool.shot(Figure.dancers, 'fisheye'), 0);
    StylePool.combo = null;
    expect(StylePool.shot(Figure.dancers, 'fisheye'), 0.5);
    StylePool.from(ShowPool.none);
  });

  test('a world is weighed by its scene and its style alone', () {
    const milk = Combo(ground: ownGround, scene: 'milk', style: 'raw');
    expect(ShowPool.none.weightOf(milk), 1, reason: 'not "no mask ×2"');
    expect(ShowPool.none.withRule(const ComboRule(scenes: {'milk'}), 0).weightOf(milk), 0);
    expect(ShowPool.none.withRule(const ComboRule(masks: {Mask.none}, mixes: {Mix.normal}), 0).weightOf(milk), 1);
    // The background MilkDrop is another thing than the scene.
    final asGround = ShowPool.none.withRule(const ComboRule(scenes: {'milk'}), 0);
    expect(asGround.weightOf(const Combo(ground: 'milk', scene: 'dance-art', style: 'plain')), greaterThan(0));
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

  test('json both ways; the old document\'s switches are not carried', () {
    final p = ShowPool.none
        .withOff('dancer.joe', true)
        .withLean('move.long22', 1.5)
        .withRule(const ComboRule(grounds: {'milk'}, styles: {'plain'}, masks: {Mask.keyhole}), 2.5)
        .copyWith(dancer: 'joe', quantise: Quantise.phrase, bias: 0.5);
    final back = ShowPool.fromJson(p.toJson());
    expect(back.off, {'dancer.joe'});
    expect(back.leanOf('move.long22'), 1.5);
    expect(back.rules, p.rules);
    expect(back.dancer, 'joe');
    expect(back.quantise, Quantise.phrase);
    expect(back.bias, 0.5);
    expect(ShowPool.fromJson(const {}).quantise, Quantise.bar);
    final old = ShowPool.fromJson(const {
      'off': ['look.flash', 'ground.milk', 'treatment.contour', 'dancer.joe'],
      'lean': {'look.flock': 2, 'move.x': 2},
      'combos': {'figure.birds|ground.milk': {'off': true}},
    });
    expect(old.off, {'dancer.joe'});
    expect(old.lean.keys, ['move.x']);
    expect(old.rules, isEmpty);
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

  test('the old preferences become a scene\'s card off and dancers off', () {
    final p = ShowPool.migrated(scenesOff: ['flash', 'veins'], dancersOff: ['joe'], dancer: 'mix');
    expect(p.sceneOn('flash'), isFalse);
    expect(p.sceneOn('kinetic'), isTrue);
    expect(p.dancersOff, ['joe']);
    expect(p.dancer, isNull);
    expect(ShowPool.migrated(dancer: 'chris').dancer, 'chris');
  });

  test('the clocks read a style\'s card', () {
    StylePool.from(ShowPool.none.withRule(const ComboRule(styles: {'ink'}), 0));
    expect(StylePool.allows(Figure.birds, 'ink'), isFalse);
    expect(StylePool.weight(Figure.birds, 'neon'), 1);
    expect(StylePool.allows(Figure.dancers, 'contour'), isFalse);
    StylePool.from(ShowPool.none);
  });
}
