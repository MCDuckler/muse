// The combination rules the plan replaced (2026-10-21 to 10-26), kept only to read
// them once into a plan (show_plan.dart) — a show.json, a snapshot kept here or on
// the server — and to say how close the plan came to them.
//
// A rule was a pattern (each of the five rows a few things, or any) and a weight; a
// rule of one row was a card, and the cards multiplied; a rule of more rows was an
// exception, and only the most particular one that matched counted. The rules the
// app came with were under the hands', and a hand rule of the same pattern took one's
// place.
import 'show_combos.dart';
import 'show_plan.dart';
import 'show_rig.dart' show Figure;

class LegacyRule {
  const LegacyRule({this.grounds, this.scenes, this.styles, this.masks, this.mixes, this.shots, this.weight = 1});
  final Set<String>? grounds, scenes, styles, masks, mixes, shots;
  final double weight;

  List<Set<String>?> get _rows => [grounds, scenes, styles, masks, mixes, shots];
  int get fields => _rows.where((r) => r != null).length;
  int get breadth => _rows.fold(1, (b, r) => b * (r?.length ?? 1));
  bool get card => fields == 1;
  bool get single => [grounds, scenes, styles, masks, mixes].every((r) => r?.length == 1);

  bool matches(Combo c) =>
      (grounds == null || grounds!.contains(c.ground)) &&
      (scenes == null || scenes!.contains(c.scene)) &&
      (styles == null || styles!.contains(c.style)) &&
      (masks == null || masks!.contains(c.mask.name)) &&
      (mixes == null || mixes!.contains(c.mix.name));

  String get pattern => [grounds, scenes, styles, masks, mixes, if (shots != null) shots].map((r) => r == null ? '*' : (r.toList()..sort()).join(',')).join('|');

  static LegacyRule? fromJson(Object? j) {
    if (j is! Map) return null;
    Set<String>? names(String k) {
      final v = j[k];
      final s = v is String ? {v} : (v is List ? {for (final x in v) if (x is String) x} : null);
      return s == null || s.isEmpty ? null : s;
    }

    final w = j['weight'];
    final r = LegacyRule(
      grounds: names('ground'),
      scenes: names('scene'),
      styles: names('style'),
      masks: names('mask'),
      mixes: names('mix'),
      shots: names('shot'),
      weight: w is num ? w.toDouble().clamp(0.0, 10.0) : 1,
    );
    return r.fields == 0 ? null : r;
  }

  @override
  String toString() => '$pattern ×$weight';
}

/// The rules the app came with.
const legacyShipped = [
  LegacyRule(grounds: {'milk'}, weight: 3),
  LegacyRule(grounds: {'white'}, weight: 0.8),
  LegacyRule(grounds: {'pulse.grid'}, weight: 0.5),
  LegacyRule(grounds: {'pulse.rays'}, weight: 0.5),
  LegacyRule(grounds: {'pulse.smoke'}, weight: 0.5),
  LegacyRule(grounds: {'pulse.stars'}, weight: 0.5),
  LegacyRule(grounds: {'field.drift'}, weight: 0.6),
  LegacyRule(grounds: {'cover'}, weight: 0.6),
  LegacyRule(masks: {'none'}, weight: 2),
  LegacyRule(masks: {'keyhole'}, weight: 0.6),
  LegacyRule(masks: {'inverted'}, weight: 0.6),
  LegacyRule(mixes: {'contrast'}, weight: 1.5),
  LegacyRule(mixes: {'screen'}, weight: 0.7),
  LegacyRule(styles: {'contour'}, weight: 0),
  LegacyRule(grounds: {'black'}, masks: {'keyhole'}, weight: 0),
  LegacyRule(grounds: {'black'}, masks: {'inverted'}, weight: 0),
  LegacyRule(grounds: {'black'}, mixes: {'add'}, weight: 0),
  LegacyRule(grounds: {'black'}, mixes: {'screen'}, weight: 0),
  LegacyRule(grounds: {'black'}, mixes: {'contrast'}, weight: 0),
  LegacyRule(grounds: {'white'}, mixes: {'add'}, weight: 0),
  LegacyRule(grounds: {'white'}, mixes: {'screen'}, weight: 0),
];

/// The hands' rules read from a list as it was kept (`combos`).
List<LegacyRule> legacyRules(Object? list) => list is List ? [for (final r in list) LegacyRule.fromJson(r)].whereType<LegacyRule>().toList() : const [];

/// [c]'s weight as the rules said it (the shipped ones under [hands]): the cards
/// multiplied, times the most particular exception.
double legacyWeight(Combo c, List<LegacyRule> hands) {
  final mine = {for (final r in hands) r.pattern};
  final rules = [for (final r in legacyShipped) if (!mine.contains(r.pattern)) r, ...hands];
  final cards = <String, double>{};
  LegacyRule? best;
  for (final r in rules) {
    if (r.shots != null || !r.matches(c)) continue;
    if (c.world && (r.grounds != null || r.masks != null || r.mixes != null)) continue;
    if (r.card) {
      cards[r.pattern] = r.weight;
    } else if (best == null || r.fields > best.fields || (r.fields == best.fields && r.breadth <= best.breadth)) {
      best = r;
    }
  }
  var w = 1.0;
  for (final x in cards.values) {
    w *= x;
  }
  return best == null ? w : w * best.weight;
}

/// The plan the hands' [rules] come to, the scenes' figures [kinds] known; and what
/// could not be said the same way, in words.
({ShowPlan plan, List<String> notes}) planFromRules(List<LegacyRule> rules, Map<String, Figure> kinds) {
  var plan = ShowPlan.shipped;
  final notes = <String>[];
  final scenes = kinds.keys.toList();
  List<String> stylesOf(String s) => stylesOfFigure(kinds[s] ?? Figure.none);

  for (final r in rules) {
    final w = r.weight;
    // The camera's: a framing's card is its level in every scene with that figure.
    if (r.shots != null) {
      if (r.fields != 1) {
        notes.add('a camera rule for some combinations only, left out: $r');
        continue;
      }
      for (final key in r.shots!) {
        final dot = key.indexOf('.');
        if (dot < 0) continue;
        final fig = key.substring(0, dot), shot = key.substring(dot + 1);
        for (final s in scenes) {
          if (kinds[s]?.name == fig || (fig == 'dancers' && kinds[s] == Figure.dancers) || (fig == 'birds' && kinds[s] == Figure.birds)) {
            plan = w <= 0 ? plan.withIn(s, PlanAxis.shot, shot, muted: true) : plan.withIn(s, PlanAxis.shot, shot, level: w, muted: false);
          }
        }
      }
      continue;
    }
    // A card.
    if (r.card) {
      if (r.scenes case final ss?) {
        for (final s in ss) {
          plan = w <= 0 ? plan.withScene(s, muted: true) : plan.withScene(s, level: w, muted: false);
        }
      } else if (r.styles case final st?) {
        for (final s in scenes) {
          for (final x in st.where(stylesOf(s).contains)) {
            plan = w <= 0 ? plan.withIn(s, PlanAxis.style, x, muted: true) : plan.withIn(s, PlanAxis.style, x, level: w, muted: false);
          }
        }
      } else {
        final (a, vs) = r.grounds != null ? (PlanAxis.ground, r.grounds!) : (r.masks != null ? (PlanAxis.mask, r.masks!) : (PlanAxis.mix, r.mixes!));
        for (final v in vs) {
          plan = w <= 0 ? plan.withShared(a, v, muted: true) : plan.withShared(a, v, level: w, muted: false);
        }
      }
      continue;
    }
    // A background with a mask or a blend, for every scene: what it takes.
    if (r.fields == 2 && r.scenes == null && r.styles == null && r.grounds != null && (r.masks ?? r.mixes) != null) {
      for (final g in r.grounds!) {
        for (final x in (r.masks ?? r.mixes)!) {
          plan = plan.withTakes(g, x, w > 0);
          if (w > 0 && w != 1) {
            for (final s in scenes) {
              plan = plan.withCell(s, cellKey(ground: g, mask: r.masks != null ? x : '*', mix: r.mixes != null ? x : '*'), w);
            }
          }
        }
      }
      continue;
    }
    // A scene in a style: the style's level in it.
    if (r.fields == 2 && r.scenes != null && r.styles != null) {
      for (final s in r.scenes!) {
        for (final x in r.styles!.where(stylesOf(s).contains)) {
          plan = w <= 0 ? plan.withIn(s, PlanAxis.style, x, muted: true) : plan.withIn(s, PlanAxis.style, x, level: w, muted: false);
          if (r.single && w > 0) plan = plan.withAllow(s, cellKey(style: x), true);
        }
      }
      continue;
    }
    // The rest: cells of each scene it is about.
    final about = r.scenes ?? {for (final s in scenes) if (r.styles == null || r.styles!.any(stylesOf(s).contains)) s};
    for (final s in about) {
      final kind = kinds[s] ?? Figure.none;
      final styles = r.styles == null ? ['*'] : [for (final x in r.styles!) if (stylesOf(s).contains(x)) x];
      final rowsNamed = r.grounds != null || r.masks != null || r.mixes != null;
      for (final st in styles) {
        // A world has no background, mask or blend: such a rule was never about it.
        if (rowsNamed && (worldScenes.contains(s) || kind == Figure.none || (st != '*' && isWorld(s, kind, st)))) continue;
        for (final g in r.grounds ?? {'*'}) {
          for (final m in r.masks ?? {'*'}) {
            for (final x in r.mixes ?? {'*'}) {
              final key = cellKey(style: st, ground: g, mask: m, mix: x);
              plan = plan.withCell(s, key, w);
              if (r.single && w > 0) plan = plan.withAllow(s, key, true);
            }
          }
        }
      }
    }
  }
  plan = tidyPlan(plan, kinds);
  return (plan: plan, notes: notes);
}

/// [plan] without the cells and allows that change nothing: about no look its scene
/// has, or about looks something else keeps off already.
ShowPlan tidyPlan(ShowPlan plan, Map<String, Figure> kinds) {
  var out = plan;
  for (final s in plan.scenes.keys) {
    final combos = combosOf(s, kinds[s] ?? Figure.none);
    for (final key in out.of(s).cells.keys.toList()) {
      final about = [for (final c in combos) if (cellMatches(key, c)) c];
      final without = out.withCell(s, key, null);
      if (about.isEmpty || about.every((c) => out.lookWeight(c) == without.lookWeight(c))) out = without;
    }
    for (final key in out.of(s).allow.toList()) {
      if (!combos.any((c) => cellMatches(key, c) && out.lookWeight(c) > 0)) {
        out = out.withSceneOf(s, (p) => p.copyWith(allow: {...p.allow}..remove(key)));
      }
    }
  }
  return out;
}
