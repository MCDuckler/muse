// The plan: every level that applies to a look multiplied (a 0 anywhere is never),
// the shared rows or a scene's own, the cells, the allows, a scene made like
// another; json both ways; and the combination rules of before read into a plan —
// a night's rules as they were kept (fixtures/rules_2026-10-26.json) coming out the
// same, but for the one place the old "most particular wins" let a veto go.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/combo_scores.dart';
import 'package:muse/src/state/show/show_plan_legacy.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/ui/show/scene.dart';

const _plainOnMilk = Combo(ground: 'milk', scene: 'dance-art', style: 'plain');

/// The shipped scenes' figures, as the app reads them.
Map<String, Figure> _kinds() {
  final files = Directory('assets/show/scenes').listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
  final book = SceneBook.fromStrings([for (final f in files) f.readAsStringSync()]);
  return {for (final l in book.looks.values) l.id: l.rig.figure.kind};
}

void main() {
  test('as shipped: every level that applies, multiplied', () {
    const p = ShowPlan.shipped;
    // MilkDrop ×3 · no mask ×2 · normal ×1 · no effect ×4.
    expect(p.lookWeight(_plainOnMilk), 24);
    expect(p.lookWeight(_plainOnMilk.copyWith(mix: Mix.contrast)), 36);
    expect(p.lookWeight(_plainOnMilk.copyWith(ground: 'black')), 8);
    // An effect now and then: the kaleidoscope, the slit-scan, the datamosh a quarter
    // each; the two together never.
    expect(p.lookWeight(_plainOnMilk.copyWith(fx: Fx.mosh)), 1.5);
    expect(p.lookWeight(_plainOnMilk.copyWith(fx: Fx.both)), 0);
    // Black takes no mask and no blend but the normal one; white no add, no screen.
    expect(p.lookWeight(_plainOnMilk.copyWith(ground: 'black', mask: Mask.keyhole)), 0);
    expect(p.lookWeight(_plainOnMilk.copyWith(ground: 'black', mix: Mix.add)), 0);
    expect(p.lookWeight(_plainOnMilk.copyWith(ground: 'white', mix: Mix.screen)), 0);
    expect(p.lookWeight(_plainOnMilk.copyWith(ground: 'white', mix: Mix.contrast)), closeTo(0.8 * 2 * 1.5 * 4, 1e-9));
    // The topographic map never.
    expect(p.lookWeight(_plainOnMilk.copyWith(style: 'contour')), 0);
    // A world: its style and its effect alone, not "no mask ×2".
    expect(p.lookWeight(const Combo(ground: ownGround, scene: 'milk', style: 'raw')), 4);
    expect(p.lookWeight(const Combo(ground: ownGround, scene: 'milk', style: 'raw', fx: Fx.kaleidoscope)), 0.25);
    expect(p.sceneLevel('flash'), 1);
  });

  test('a level, a mute that keeps it, and nothing else moved', () {
    var p = ShowPlan.shipped.withShared(PlanAxis.ground, 'milk', level: 1.5);
    expect(p.lookWeight(_plainOnMilk), 12);
    p = p.withShared(PlanAxis.ground, 'milk', muted: true);
    expect(p.lookWeight(_plainOnMilk), 0);
    expect(p.sharedFader(PlanAxis.ground, 'milk'), 1.5, reason: 'the level kept');
    expect(p.withShared(PlanAxis.ground, 'milk', muted: false).lookWeight(_plainOnMilk), 12);
    // A scene's level is its share against the others, never its looks' weight.
    final q = ShowPlan.shipped.withScene('dance-art', level: 1 / 3);
    expect(q.sceneLevel('dance-art'), closeTo(1 / 3, 1e-9));
    expect(q.lookWeight(_plainOnMilk), 24);
    expect(q.withScene('dance-art', muted: true).sceneLevel('dance-art'), 0);
    expect(q.withScene('dance-art', muted: true).isOn(_plainOnMilk), isFalse);
    // Back to the shipped level: nothing kept of it.
    expect(ShowPlan.shipped.withShared(PlanAxis.ground, 'milk', level: 3).levels, isEmpty);
  });

  test('a scene with its own row: the shared one copied, then its own alone', () {
    var p = ShowPlan.shipped.withShared(PlanAxis.ground, 'wash', muted: true).withOwn('kinetic', PlanAxis.ground, true);
    expect(p.owns('kinetic', PlanAxis.ground), isTrue);
    expect(p.levelIn('kinetic', PlanAxis.ground, 'milk'), 3, reason: 'copied');
    expect(p.mutedIn('kinetic', PlanAxis.ground, 'wash'), isTrue, reason: 'the mute copied too');
    p = p.withIn('kinetic', PlanAxis.ground, 'milk', level: 0.5).withIn('kinetic', PlanAxis.ground, 'wash', muted: false);
    expect(p.levelIn('kinetic', PlanAxis.ground, 'milk'), 0.5);
    expect(p.levelIn('kinetic', PlanAxis.ground, 'wash'), 1);
    expect(p.levelIn('dance-art', PlanAxis.ground, 'milk'), 3, reason: 'the others share the row still');
    expect(p.levelIn('dance-art', PlanAxis.ground, 'wash'), 0);
    // The shared row changed: not the owner's.
    p = p.withShared(PlanAxis.ground, 'milk', level: 4);
    expect(p.levelIn('kinetic', PlanAxis.ground, 'milk'), 0.5);
    // Sharing again.
    p = p.withOwn('kinetic', PlanAxis.ground, false);
    expect(p.levelIn('kinetic', PlanAxis.ground, 'milk'), 4);
    expect(p.of('kinetic'), ScenePlan.none);
  });

  test('cells multiply in; a wider never is cut round what is let out of it', () {
    final white = cellKey(ground: 'white');
    var p = ShowPlan.shipped.withCell('dance-art', white, 0);
    final asciiWhite = _plainOnMilk.copyWith(ground: 'white', style: 'ascii');
    expect(p.lookWeight(asciiWhite), 0);
    expect(p.lookWeight(_plainOnMilk), 24, reason: 'another background');
    expect(p.lookWeight(_plainOnMilk.copyWith(scene: 'kinetic', style: 'raw', ground: 'white')), greaterThan(0), reason: 'another scene');
    p = p.withUnvetoed('dance-art', cellKey(style: 'ascii', ground: 'white'), stylesOfFigure(Figure.dancers));
    expect(p.lookWeight(asciiWhite), greaterThan(0));
    expect(p.lookWeight(_plainOnMilk.copyWith(ground: 'white')), 0, reason: 'the rest of the never stays');
    // Less, less, more, more: back to none.
    final k = cellOf(_plainOnMilk);
    var q = ShowPlan.shipped.scaleCell('dance-art', k, 0.5).scaleCell('dance-art', k, 0.5);
    expect(q.lookWeight(_plainOnMilk), 6);
    q = q.scaleCell('dance-art', k, 2).scaleCell('dance-art', k, 2);
    expect(q.of('dance-art').cells, isEmpty);
    // Every cell about a look counts.
    final r = ShowPlan.shipped.withCell('dance-art', cellKey(style: 'plain'), 2).withCell('dance-art', k, 0.5);
    expect(r.lookWeight(_plainOnMilk), 24);
    expect(r.factors(_plainOnMilk).map((f) => f.what), containsAll(['cell plain|*|*|*', 'cell $k']));
  });

  test('an allow lets a look come however it measured', () {
    final scores = ComboScores.parse(jsonEncode({
      'grounds': comboGrounds,
      'masks': [for (final m in Mask.values) m.name],
      'mixes': [for (final m in Mix.values) m.name],
      'figures': {
        'dance-art.plain': {'q': '0', 'i': 'h'}
      },
    }))!;
    expect(ComboScores.weigh(_plainOnMilk, ShowPlan.shipped, scores: scores), 0);
    final p = ShowPlan.shipped.withAllow('dance-art', cellKey(style: 'plain', ground: 'milk'), true);
    expect(p.allowed(_plainOnMilk), isTrue);
    expect(ComboScores.weigh(_plainOnMilk, p, scores: scores), 24);
    expect(p.withAllow('dance-art', cellKey(style: 'plain'), false).allowed(_plainOnMilk), isFalse, reason: 'a wider one takes the narrower away');
  });

  test('a scene made like another: its styles, its own rows, its cells for the styles it has', () {
    final p = ShowPlan.shipped
        .withIn('dance-art', PlanAxis.style, 'ascii', level: 0.5)
        .withIn('dance-art', PlanAxis.style, 'mono', muted: true)
        .withOwn('dance-art', PlanAxis.mix, true)
        .withCell('dance-art', cellKey(style: 'ascii', ground: 'white'), 0)
        .withCell('dance-art', cellKey(style: 'mono', ground: 'milk'), 0)
        .withScene('dance-art', level: 2)
        .copyScene('dance-art', 'kinetic', stylesOfFigure(Figure.kinetic));
    final k = p.of('kinetic');
    expect(k.styles, {'ascii': 0.5});
    expect(k.off, isNot(contains('style.mono')), reason: 'kinetic has no mono');
    expect(k.own.keys, [PlanAxis.mix]);
    expect(k.cells.keys, [cellKey(style: 'ascii', ground: 'white')]);
    expect(k.level, 1, reason: 'how often it comes is its own');
  });

  test('the effects: a row like the others — its own in a scene, a cell of one effect, a cell of before about any', () {
    const mosh = Combo(ground: 'milk', scene: 'kinetic', style: 'raw', fx: Fx.mosh);
    const plain = Combo(ground: 'milk', scene: 'kinetic', style: 'raw');
    // The kinetic shapes moshed most of the time, nothing else changed.
    var p = ShowPlan.shipped.withOwn('kinetic', PlanAxis.fx, true).withIn('kinetic', PlanAxis.fx, 'mosh', level: 4).withIn('kinetic', PlanAxis.fx, 'none', level: 1);
    expect(p.lookWeight(mosh), greaterThan(p.lookWeight(plain)));
    expect(p.levelIn('flash', PlanAxis.fx, 'mosh'), 0.25);
    // Never moshed on MilkDrop: a cell of that effect alone.
    p = p.withCell('kinetic', cellKey(ground: 'milk', fx: 'mosh'), 0);
    expect(p.lookWeight(mosh), 0);
    expect(p.lookWeight(plain), greaterThan(0));
    expect(cellOf(mosh), 'raw|milk|none|normal|mosh');
    // A cell from before the effects (four rows) is about every effect.
    expect(cellMatches('raw|milk|none|normal', mosh), isTrue);
    expect(cellMatches('raw|milk|none|normal|none', mosh), isFalse);
    expect(cellCovers('raw|milk|*|*', 'raw|milk|none|normal|mosh'), isTrue);
    // Let out of a wider never: cut round the one effect.
    final q = ShowPlan.shipped.withCell('kinetic', cellKey(style: 'raw', ground: 'milk'), 0).withUnvetoed('kinetic', cellOf(mosh), stylesOfFigure(Figure.kinetic));
    expect(q.lookWeight(mosh), greaterThan(0));
    expect(q.lookWeight(plain), 0);
    expect(ShowPlan.fromJson(jsonDecode(jsonEncode(q.toJson()))), q);
  });

  test('json both ways; as shipped is nothing', () {
    expect(ShowPlan.shipped.toJson(), isEmpty);
    final p = ShowPlan.shipped
        .withScene('glide', level: 1 / 3)
        .withScene('flock', muted: true)
        .withShared(PlanAxis.ground, 'wash', muted: true)
        .withShared(PlanAxis.mix, 'add', level: 2)
        .withOwn('kinetic', PlanAxis.ground, true)
        .withIn('dance-art', PlanAxis.shot, 'fisheye', level: 0.25)
        .withCell('dance-art', cellKey(style: 'ascii', ground: 'white'), 0)
        .withAllow('type3d', cellKey(style: 'raw', ground: 'milk', mask: 'none', mix: 'contrast'), true)
        .withTakes('white', 'add', true);
    final back = ShowPlan.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect(back, p);
    expect(back.takes('white', 'add'), isTrue);
    expect(back.takes('white', 'screen'), isFalse);
    expect(ShowPlan.fromJson(null), ShowPlan.shipped);
  });

  test('a level in words', () {
    expect(levelWord(0), 'off');
    expect(levelWord(1 / 3), '×1/3');
    expect(levelWord(0.3333), '×1/3');
    expect(levelWord(0.25), '×1/4');
    expect(levelWord(1.5), '×1.5');
    expect(levelWord(2), '×2');
  });

  group('the rules of before', () {
    final kinds = _kinds();

    test('cards, batches, a background with a blend, exceptions, worlds, the camera', () {
      final r = planFromRules(
          legacyRules(const [
            {'scene': 'glide', 'weight': 0.3333},
            {
              'scene': ['flash', 'turntable'],
              'weight': 0
            },
            {'ground': 'wash', 'weight': 0},
            {'ground': 'milk', 'weight': 4},
            {'style': 'viewports', 'weight': 0},
            {'ground': 'white', 'mix': 'contrast', 'weight': 0},
            {
              'ground': 'white',
              'scene': 'dance-art',
              'style': ['ascii', 'dither'],
              'mask': 'none',
              'weight': 0
            },
            {'ground': 'milk', 'scene': 'type3d', 'style': 'raw', 'mask': 'none', 'mix': 'contrast', 'weight': 4},
            {'ground': 'own', 'scene': 'milk', 'mask': 'none', 'mix': 'normal', 'weight': 0},
            {'scene': 'dance-art', 'style': 'disco', 'weight': 0},
            {
              'shot': ['dancers.fisheye'],
              'weight': 0.5
            },
          ]),
          kinds);
      final p = r.plan;
      expect(p.sceneLevel('glide'), closeTo(1 / 3, 1e-3));
      expect(p.sceneLevel('flash'), 0);
      expect(p.sceneLevel('turntable'), 0);
      expect(p.sharedMuted(PlanAxis.ground, 'wash'), isTrue);
      expect(p.shared(PlanAxis.ground, 'milk'), 4);
      expect(p.mutedIn('dance-art', PlanAxis.style, 'viewports'), isTrue);
      expect(p.takes('white', 'contrast'), isFalse);
      expect(p.lookWeight(const Combo(ground: 'white', scene: 'dance-art', style: 'dither')), 0);
      expect(p.lookWeight(const Combo(ground: 'white', scene: 'dance-art', style: 'plain')), greaterThan(0));
      const type = Combo(ground: 'milk', scene: 'type3d', style: 'raw', mask: Mask.none, mix: Mix.contrast);
      expect(p.lookWeight(type), 4 * 2 * 1.5 * 4 * 4);
      expect(p.allowed(type), isTrue, reason: 'one look named alone came however it measured');
      expect(p.of('milk'), ScenePlan.none, reason: 'a rule naming a world\'s background was never about it');
      expect(p.mutedIn('dance-art', PlanAxis.style, 'disco'), isTrue);
      expect(p.shotLevel('dance-art', 'fisheye'), 0.5);
      expect(r.notes, isEmpty);
    });

    test('a night\'s rules as kept: every look on or off as before, but where the old way let a veto go', () {
      final raw = jsonDecode(File('test/show/fixtures/rules_2026-10-26.json').readAsStringSync());
      final rules = legacyRules(raw);
      expect(rules, hasLength(49));
      final plan = planFromRules(rules, kinds).plan;
      final flips = <Combo>[];
      for (final e in kinds.entries) {
        // The rules of before knew no effects: their looks are the ones with none.
        for (final c in combosOf(e.key, e.value, fxs: const [Fx.none])) {
          if ((legacyWeight(c, rules) > 0) != plan.isOn(c)) flips.add(c);
        }
      }
      // "Plain dancers on black, every mask and blend ×2" said more than "black takes no
      // keyhole" and so won: masks and blends on black that show black or the same
      // picture twice came back. Now both count.
      expect(flips.every((c) => c.scene == 'dance-art' && c.style == 'plain' && c.ground == 'black'), isTrue, reason: '$flips');
      expect(flips, hasLength(11));
      expect(plan.isOn(const Combo(ground: 'black', scene: 'dance-art', style: 'plain')), isTrue);
      // Tidy: no cell that changes nothing.
      expect(tidyPlan(plan, kinds), plan);
      // An exception under a wider one at nought said nothing; the scenes switched off
      // keep theirs, for when they are back on.
      expect(plan.of('dance-art').cells.keys, isNot(contains(cellKey(style: 'ascii', ground: 'white', mask: 'none', mix: 'normal'))));
      expect(plan.of('turntable').cells, isNotEmpty);
    });
  });
}
