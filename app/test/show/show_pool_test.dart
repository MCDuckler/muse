// The pool: switches, leans, the combo table and what the old preferences become.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_tune.dart';

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

  test('any figure\'s style keys a rule: the flock\'s paper looks stay off MilkDrop, and its clock leans away', () {
    const p = ShowPool.none;
    expect(ShowPool.comboKey(const RigFigure(kind: Figure.birds, style: 'ink'), Ground.milk), 'figure.birds.style.ink|ground.milk');
    expect(p.together(const RigFigure(kind: Figure.birds, style: 'ink'), Ground.milk), isFalse);
    expect(p.together(const RigFigure(kind: Figure.birds, style: 'ink'), Ground.wash), isTrue);
    expect(p.together(const RigFigure(kind: Figure.birds, style: 'embers'), Ground.milk), isTrue);
    // The clocks ask the rules for the ground on now: a style kept off it is picked
    // less (not never: then the stage puts it on another background).
    StylePool.from(p);
    StylePool.ground = Ground.milk;
    expect(StylePool.allows(Figure.birds, 'ink'), isTrue);
    expect(StylePool.weight(Figure.birds, 'ink'), closeTo(0.3, 1e-9));
    expect(StylePool.weight(Figure.birds, 'embers'), 1);
    expect(StylePool.weight(Figure.dancers, 'viewports'), closeTo(0.3, 1e-9));
    StylePool.ground = Ground.wash;
    expect(StylePool.weight(Figure.birds, 'ink'), 1);
    StylePool.from(p.withOff('treatment.embers', true));
    expect(StylePool.allows(Figure.birds, 'embers'), isFalse, reason: 'switched off');
    StylePool.from(ShowPool.none);
    StylePool.ground = Ground.black;
  });

  test('together or never in a tap: back to the default where that is what is asked', () {
    const p = ShowPool.none;
    const plain = RigFigure(kind: Figure.dancers, style: 'plain');
    const kinetic = RigFigure(kind: Figure.kinetic);
    expect(p.together(plain, Ground.milk), isFalse, reason: 'paper on a busy ground');
    // Together by hand: a word of the hands' (the page as drawn).
    final a = p.withTogether(plain, Ground.milk, true);
    expect(a.together(plain, Ground.milk), isTrue);
    expect(a.combos[ShowPool.comboKey(plain, Ground.milk)], ComboRule.over);
    // Never again: the default, so no word kept.
    expect(a.withTogether(plain, Ground.milk, false).combos, isEmpty);
    // A pair together by default, never by hand, together again: nothing kept.
    final b = p.withTogether(kinetic, Ground.wash, false);
    expect(b.together(kinetic, Ground.wash), isFalse);
    expect(b.withTogether(kinetic, Ground.wash, true).combos, isEmpty);
    // A shipped exception switched off and on: the exception back.
    const mono = RigFigure(kind: Figure.dancers, style: 'mono');
    final c = p.withTogether(mono, Ground.milk, false).withTogether(mono, Ground.milk, true);
    expect(c.answer(mono, Ground.milk).from, RuleFrom.exception);
    expect(c.blendFor(mono, Ground.milk).ground, GroundMode.keyhole);
  });

  test('a shipped rule blends one of its ways by the seed; a word of the hands\' has its one', () {
    const p = ShowPool.none;
    const kinetic = RigFigure(kind: Figure.kinetic);
    final seen = {for (var i = 0; i < 12; i++) p.blendFor(kinetic, Ground.milk, seed: i).ground};
    expect(seen, shippedWays['full|busy']!.toSet());
    expect(p.blendFor(kinetic, Ground.milk, seed: 5).ground, p.blendFor(kinetic, Ground.milk, seed: 5).ground, reason: 'the same seed, the same way');
    final mine = p.withBlend(kinetic, Ground.milk, GroundMode.mask);
    expect({for (var i = 0; i < 6; i++) mine.blendFor(kinetic, Ground.milk, seed: i).ground}, {GroundMode.mask});
    // OTHER BLEND steps through the rule's ways first, then the rest; keyhole only
    // where there is a figure to cut it.
    final ways = p.blendsFor(kinetic, Ground.milk);
    expect(ways.take(3), shippedWays['full|busy']);
    expect(ways, isNot(contains(GroundMode.keyhole)));
    expect(p.blendsFor(const RigFigure(kind: Figure.dancers), Ground.milk), contains(GroundMode.keyhole));
    // Never, and black: as drawn, whatever the seed.
    expect(p.blendFor(const RigFigure(kind: Figure.dancers, style: 'plain'), Ground.milk, seed: 3).ground, GroundMode.over);
    expect(p.blendFor(kinetic, Ground.black, seed: 3).ground, GroundMode.over);
  });

  test('a part switched off is gone: a way of blending, a treatment', () {
    const kinetic = RigFigure(kind: Figure.kinetic);
    final p = ShowPool.none.withOff('blend.contrast', true).withOff('blend.screen', true);
    expect(p.blendOn(GroundMode.contrast), isFalse);
    expect(p.blendOn(GroundMode.over), isTrue, reason: 'as drawn is always there');
    // full|busy's ways are contrast, screen, dim: only dim is left.
    expect({for (var i = 0; i < 6; i++) p.blendFor(kinetic, Ground.milk, seed: i).ground}, {GroundMode.dim});
    // A rule of the hands' in a way switched off: the next way that is on.
    final mine = p.withBlend(kinetic, Ground.wash, GroundMode.contrast);
    expect(mine.blendFor(kinetic, Ground.wash).ground, GroundMode.add);
    expect(p.blendsFor(kinetic, Ground.milk), isNot(contains(GroundMode.contrast)));
    // A treatment off: out of every scene's mix, even one the hands made.
    final t = ShowPool.none.withMix('kinetic', ['raw', 'ascii', 'dither']).withOff('treatment.ascii', true);
    expect([for (final (x, _) in treatMix(t, 'kinetic')) x.name], ['raw', 'dither']);
  });

  test('a branch set whole: every style never, then every style together', () {
    const styles = ['plain', 'mono', 'trails', 'viewports'];
    bool all(ShowPool p, Ground g, bool together) =>
        styles.every((s) => p.answer(RigFigure(kind: Figure.dancers, style: s), g).never != together) && p.answer(const RigFigure(kind: Figure.dancers), g).never != together;
    final never = ShowPool.none.withBranch(Figure.dancers, styles, Ground.wash, false);
    expect(all(never, Ground.wash, false), isTrue);
    expect(never.combos.length, 1, reason: 'one word on the figure');
    final together = never.withBranch(Figure.dancers, styles, Ground.wash, true);
    expect(all(together, Ground.wash, true), isTrue);
    // The viewports (a world of their own) needed a word of their own; the rest kept theirs.
    expect(together.combos.keys, ['figure.dancers.style.viewports|ground.wash']);
    // A style's word over a branch's never: just that style together.
    final one = never.withTogether(const RigFigure(kind: Figure.dancers, style: 'trails'), Ground.wash, true);
    expect(one.answer(const RigFigure(kind: Figure.dancers, style: 'trails'), Ground.wash).never, isFalse);
    expect(one.answer(const RigFigure(kind: Figure.dancers, style: 'plain'), Ground.wash).never, isTrue);
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
