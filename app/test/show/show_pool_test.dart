// The pool: switches, leans, the combo table and what the old preferences become.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';

void main() {
  test('a switch off, and all of them off is none off', () {
    var p = ShowPool.none.withOff('treatment.contour', true);
    expect(p.isOn('treatment.contour'), isFalse);
    expect(p.isOn('treatment.ascii'), isTrue);
    expect(p.on('treatment', Treatment.values, (t) => t.name), isNot(contains(Treatment.contour)));
    for (final t in Treatment.values) {
      p = p.withOff('treatment.${t.name}', true);
    }
    expect(p.on('treatment', Treatment.values, (t) => t.name), Treatment.values);
    expect(p.withOff('treatment.contour', false).isOn('treatment.contour'), isTrue);
  });

  test('a lean is kept between nought and two', () {
    final p = ShowPool.none.withLean('figure.birds', 5);
    expect(p.leanOf('figure.birds'), 2);
    expect(p.leanOf('figure.dancers'), 1);
  });

  test('as shipped: the plain dancers are ink on paper, never on MilkDrop; the glyphs light it; the silhouettes a keyhole by exception', () {
    const p = ShowPool.none;
    const plain = RigFigure(kind: Figure.dancers, shade: Shade.textured);
    expect(p.characterOf(plain), Character.paper);
    expect(p.together(plain, Ground.milk), isFalse);
    expect(p.answer(plain, Ground.milk).from, RuleFrom.rule);
    expect(p.together(plain, Ground.wash), isTrue, reason: 'the page covers a glow: as drawn');
    const ascii = RigFigure(kind: Figure.dancers, shade: Shade.chrome, treatment: Treatment.ascii);
    expect(p.characterOf(ascii), Character.lights);
    expect(p.blendFor(ascii, Ground.milk).ground, GroundMode.contrast);
    expect(p.blendFor(ascii, Ground.milk).figure, FigureMode.over);
    const mono = RigFigure(kind: Figure.dancers, shade: Shade.silhouette);
    expect(p.together(mono, Ground.milk), isTrue);
    expect(p.blendFor(mono, Ground.milk).ground, GroundMode.keyhole);
    expect(p.answer(mono, Ground.milk).from, RuleFrom.exception);
    expect(p.answer(mono, Ground.milk).why, isNotNull);
    // On black everything is as drawn.
    expect(p.blendFor(ascii, Ground.black).ground, GroundMode.over);
    expect(p.answer(plain, Ground.black).from, RuleFrom.black);
    expect(p.together(plain, Ground.black), isTrue);
  });

  test('an answer comes from your exception, the shipped exception, your rule, the shipped rule — in that order', () {
    const mono = RigFigure(kind: Figure.dancers, style: 'mono');
    var p = ShowPool.none;
    expect(p.answer(mono, Ground.milk).from, RuleFrom.exception);
    // Your rule for ink on paper on busy does not reach past the exception…
    p = p.withRule(Character.paper, Backdrop.busy, const ComboRule(ground: GroundMode.dim));
    expect(p.answer(mono, Ground.milk).rule.ground, GroundMode.keyhole);
    expect(p.answer(mono, Ground.field).from, RuleFrom.yourRule, reason: 'no exception on the field: your rule');
    expect(p.answer(mono, Ground.field).rule.ground, GroundMode.dim);
    // …until the exception is switched off: then the rule holds.
    p = p.withCombo(ShowPool.comboKey(mono, Ground.milk), ComboRule.asTheRule);
    expect(p.answer(mono, Ground.milk).from, RuleFrom.yourRule);
    expect(p.answer(mono, Ground.milk).rule.ground, GroundMode.dim);
    // Your own exception wins over everything.
    p = p.withCombo(ShowPool.comboKey(mono, Ground.milk), const ComboRule(ground: GroundMode.window));
    expect(p.answer(mono, Ground.milk).from, RuleFrom.yourException);
    expect(p.answer(mono, Ground.milk).rule.ground, GroundMode.window);
    // And gone again: the shipped exception is back.
    p = p.withCombo(ShowPool.comboKey(mono, Ground.milk), null).withRule(Character.paper, Backdrop.busy, null);
    expect(p.answer(mono, Ground.milk).from, RuleFrom.exception);
  });

  test('a thing\'s character: a style\'s own, else its figure\'s; changed by hand, every pairing follows', () {
    var p = ShowPool.none;
    const disco = RigFigure(kind: Figure.dancers, style: 'disco');
    const trails = RigFigure(kind: Figure.dancers, style: 'trails');
    expect(p.characterOf(disco), Character.full);
    expect(p.characterOf(trails), Character.lights, reason: 'no character of its own: the dancers\'');
    expect(p.characterOfKey(figureKey(Figure.dancers, 'trails')), (Character.lights, false));
    expect(p.characterOfKey(figureKey(Figure.dancers, 'disco')), (Character.full, true));
    expect(p.blendFor(disco, Ground.milk).ground, GroundMode.contrast);
    // The disco made a world of its own: never with a background, on any.
    p = p.withCharacter(figureKey(Figure.dancers, 'disco'), Character.world.name);
    expect(p.together(disco, Ground.milk), isFalse);
    expect(p.together(disco, Ground.wash), isFalse);
    // The dancers as a whole made ink on paper: their styles without one of their own follow.
    p = p.withCharacter(figureKey(Figure.dancers), Character.paper.name);
    expect(p.characterOf(trails), Character.paper);
    expect(p.characterOf(const RigFigure(kind: Figure.dancers, style: 'mono')), Character.paper);
    // As shipped again.
    p = p.withCharacter(figureKey(Figure.dancers), null).withCharacter(figureKey(Figure.dancers, 'disco'), null);
    expect(p.characterOf(trails), Character.lights);
    expect(p.characters, isEmpty);
  });

  test('a background\'s character decides the rule column; black has none', () {
    var p = ShowPool.none;
    expect(p.backdropOf(Ground.black), isNull);
    expect(p.backdropOf(Ground.milk), Backdrop.busy);
    expect(p.backdropOf(Ground.field), Backdrop.busy);
    const kinetic = RigFigure(kind: Figure.kinetic);
    expect(p.blendFor(kinetic, Ground.field).ground, GroundMode.contrast);
    p = p.withCharacter(groundKey(Ground.field), Backdrop.glow.name);
    expect(p.backdropOf(Ground.field), Backdrop.glow);
    expect(p.blendFor(kinetic, Ground.field).ground, GroundMode.add);
    expect(p.together(kinetic, Ground.camera), isFalse, reason: 'a full frame on a picture: never');
  });

  test('how often: never is off, rarely and often lean, normal is neither', () {
    var p = ShowPool.none;
    expect(p.oftenOf('look.flash'), Often.normal);
    p = p.withOften('look.flash', Often.often);
    expect(p.oftenOf('look.flash'), Often.often);
    expect(p.leanOf('look.flash'), 2);
    p = p.withOften('look.flash', Often.never);
    expect(p.isOn('look.flash'), isFalse);
    expect(p.oftenOf('look.flash'), Often.never);
    p = p.withOften('look.flash', Often.rarely);
    expect(p.isOn('look.flash'), isTrue);
    expect(p.oftenOf('look.flash'), Often.rarely);
    p = p.withOften('look.flash', Often.normal);
    expect(p.lean.containsKey('look.flash'), isFalse);
    // A style switched off the old way is never; on again clears that too.
    p = p.withOff('treatment.ascii', true);
    expect(p.oftenOf('style.dancers.ascii'), Often.never);
    p = p.withOften('style.dancers.ascii', Often.often);
    expect(p.styleOn(Figure.dancers, 'ascii'), isTrue);
  });

  test('a weighted pick goes by the weights, and never to a weight of nought', () {
    final seen = <String, int>{};
    for (var i = 0; i < 1000; i++) {
      final v = ShowPool.pickWeighted(['a', 'b', 'c'], i / 1000, (x) => switch (x) { 'a' => 2.0, 'b' => 1.0, _ => 0.0 })!;
      seen[v] = (seen[v] ?? 0) + 1;
    }
    expect(seen['c'], isNull);
    expect(seen['a']! / seen['b']!, closeTo(2, 0.05));
  });

  test('the characters and your rules are kept', () {
    final p = ShowPool.none
        .withCharacter(figureKey(Figure.dancers, 'disco'), Character.world.name)
        .withCharacter(groundKey(Ground.field), Backdrop.glow.name)
        .withRule(Character.lights, Backdrop.busy, const ComboRule(ground: GroundMode.screen, figure: FigureMode.over))
        .withCombo('figure.dancers.style.mono|ground.milk', ComboRule.asTheRule);
    final back = ShowPool.fromJson(p.toJson());
    expect(back.characters, p.characters);
    expect(back.rules, p.rules);
    expect(back.combos['figure.dancers.style.mono|ground.milk']!.follow, isTrue);
    // Its exception switched off: ink on paper's shipped rule answers (never).
    expect(back.answer(const RigFigure(kind: Figure.dancers, style: 'mono'), Ground.milk).from, RuleFrom.rule);
    expect(back.answer(const RigFigure(kind: Figure.dancers, style: 'ascii'), Ground.milk).from, RuleFrom.yourRule);
  });

  test('the hands\' rule comes before the shipped one, and goes again', () {
    const mono = RigFigure(kind: Figure.dancers, shade: Shade.silhouette);
    final key = ShowPool.comboKey(mono, Ground.milk);
    // A shade set without a style means the style of that name: the rule is the style's.
    expect(key, 'figure.dancers.style.mono|ground.milk');
    final p = ShowPool.none.withCombo(key, const ComboRule(ground: GroundMode.window));
    expect(p.together(mono, Ground.milk), isTrue);
    expect(p.blendFor(mono, Ground.milk).ground, GroundMode.window);
    expect(p.withCombo(key, null).blendFor(mono, Ground.milk).ground, GroundMode.keyhole, reason: 'the shipped rule again');
    expect(p.withCombo(key, ComboRule.never).together(mono, Ground.milk), isFalse);
    // A figure switched off is never together with anything.
    expect(p.withOff('figure.dancers', true).together(mono, Ground.milk), isFalse);
  });

  test('a dancer\'s style stands in for the axes it means, and the clock\'s art reaches the lookup', () {
    // The style's own key first, then the axes it means.
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, style: 'mono'), Ground.milk), ['figure.dancers.style.mono|ground.milk', 'figure.dancers.shade.silhouette|ground.milk', 'figure.dancers|ground.milk']);
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, style: 'plain'), Ground.milk)[1], 'figure.dancers.shade.textured|ground.milk');
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, style: 'ascii'), Ground.milk)[1], 'figure.dancers.treatment.ascii|ground.milk');
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, style: 'trails'), Ground.wash)[1], 'figure.dancers.treatment.trails|ground.wash');
    // A style the axes do not know: its own key, then the figure alone.
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, style: 'nothing-of-the-sort'), Ground.milk).last, 'figure.dancers|ground.milk');
    // The axes set by hand come before what the style means.
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, shade: Shade.chrome, style: 'mono'), Ground.milk), contains('figure.dancers.shade.chrome|ground.milk'));
    expect(ShowPool.comboKeys(const RigFigure(kind: Figure.dancers, shade: Shade.chrome, style: 'mono'), Ground.milk), isNot(contains('figure.dancers.shade.silhouette|ground.milk')));
    const p = ShowPool.none;
    expect(p.blendFor(const RigFigure(kind: Figure.dancers, style: 'mono'), Ground.milk).ground, GroundMode.keyhole);
    expect(p.blendFor(const RigFigure(kind: Figure.dancers, style: 'plain'), Ground.milk).figure, FigureMode.over);
    // The figure's clock's style, where the hands hold none.
    StylePool.now[Figure.dancers] = 'mono';
    expect(ShowPool.lookupFigure(const RigFigure(kind: Figure.dancers)).style, 'mono');
    expect(ShowPool.lookupFigure(const RigFigure(kind: Figure.dancers, style: 'ascii')).style, 'ascii');
    expect(ShowPool.lookupFigure(const RigFigure(kind: Figure.birds)).style, isNull);
    StylePool.now.remove(Figure.dancers);
    expect(ShowPool.lookupFigure(const RigFigure(kind: Figure.dancers)).style, isNull);
  });

  test('any figure\'s style keys a rule: the flock\'s paper looks stay off MilkDrop, and its clock is told', () {
    const p = ShowPool.none;
    expect(ShowPool.comboKey(const RigFigure(kind: Figure.birds, style: 'ink'), Ground.milk), 'figure.birds.style.ink|ground.milk');
    expect(p.together(const RigFigure(kind: Figure.birds, style: 'ink'), Ground.milk), isFalse);
    expect(p.together(const RigFigure(kind: Figure.birds, style: 'ink'), Ground.wash), isTrue);
    expect(p.together(const RigFigure(kind: Figure.birds, style: 'embers'), Ground.milk), isTrue);
    // The clocks ask the rules for the ground on now.
    StylePool.from(p);
    StylePool.ground = Ground.milk;
    expect(StylePool.allows(Figure.birds, 'ink'), isFalse);
    expect(StylePool.allows(Figure.birds, 'embers'), isTrue);
    expect(StylePool.allows(Figure.dancers, 'viewports'), isFalse);
    StylePool.ground = Ground.wash;
    expect(StylePool.allows(Figure.birds, 'ink'), isTrue);
    StylePool.from(p.withOff('treatment.embers', true));
    expect(StylePool.allows(Figure.birds, 'embers'), isFalse, reason: 'switched off');
    StylePool.from(ShowPool.none);
    StylePool.ground = Ground.black;
  });

  test('json both ways', () {
    final p = ShowPool.none
        .withOff('look.flash', true)
        .withLean('figure.birds', 1.5)
        .withCombo('figure.birds|ground.milk', ComboRule.never)
        .copyWith(dancer: 'joe', quantise: Quantise.phrase, bias: 0.5);
    final back = ShowPool.fromJson(p.toJson());
    expect(back.off, {'look.flash'});
    expect(back.leanOf('figure.birds'), 1.5);
    expect(back.combos['figure.birds|ground.milk'], ComboRule.never);
    expect(back.dancer, 'joe');
    expect(back.quantise, Quantise.phrase);
    expect(back.bias, 0.5);
    expect(ShowPool.fromJson(const {}).quantise, Quantise.bar);
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

  test('the old preferences become switches', () {
    final p = ShowPool.migrated(scenesOff: ['flash', 'veins'], dancersOff: ['joe'], dancer: 'mix');
    expect(p.looksOff, {'flash', 'veins'});
    expect(p.dancersOff, ['joe']);
    expect(p.dancer, isNull);
    expect(p.isOn('treatment.contour'), isFalse);
    expect(ShowPool.migrated(dancer: 'chris').dancer, 'chris');
  });
}
