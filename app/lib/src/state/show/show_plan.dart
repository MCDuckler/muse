// The plan: how often everything the show puts on comes (it replaces the combination
// rules). Two questions, answered apart.
//
// Which scene: its level against the other scenes' — the director weighs the music's
// fit too and tires a scene the faster the lower its level, so over a night the scenes
// share the time by their levels (show_director.dart). Nothing inside a scene moves
// how often the scene itself comes.
//
// Which look of that scene: a combination (show_combos.dart) — a style, a background,
// a mask, a blend, an effect — as likely as every level that applies to it,
// multiplied:
//
//   style × background × mask × blend × effect × cells × (the background takes that
//   mask and blend) × (how it measured, combo_scores.dart)
//
// No rule beats another: a 0 anywhere is never, everything else counts. The style is
// the scene's own level for it. The background, the mask, the blend and the effect
// (none most of the time; the kaleidoscope, the slit-scan, the datamosh now and then)
// are the levels every scene shares, or the scene's own where it has its own of that
// row (then the whole row is its own). A cell is the hands' word on looks of one scene — one look
// ("ascii on white, no mask, added: never") or a few (`*` for any of a row): never,
// less, more; they multiply in too. An "allow" lets looks of a scene come however they
// measured. Which masks and blends a background takes is one small table for all.
//
// The camera (the dancers', the flock's) is the scene's too: a level per framing,
// weighing the figure's next framing at every cut — never how often a look comes.
//
// A world of its own (MilkDrop alone, the dormouse, the disco floor, the viewports,
// the sky) has no background, mask or blend to weigh: its style's level, its effect's
// and its cells say all.
//
// Plan: ~/.claude/plans/wetowl-show-ui-rework.md.
import 'dart:convert';

import 'show_combos.dart';
import 'show_rig.dart' show Figure;

/// The rows a look is made of, as the plan weighs them; and the camera, which weighs
/// framings, not looks.
enum PlanAxis { style, ground, mask, mix, fx, shot }

/// The rows every scene shares unless it has its own.
const sharedAxes = [PlanAxis.ground, PlanAxis.mask, PlanAxis.mix, PlanAxis.fx];

/// The levels a fader stops at: off, then a quarter to four.
const levelSteps = <double>[0, 0.25, 1 / 3, 0.5, 0.75, 1, 1.5, 2, 3, 4];

/// The most a level may be.
const levelMost = 4.0;

/// A level in words: `off`, `×1/3`, `×1.5`.
String levelWord(double v) {
  if (v <= 0) return 'off';
  // Plain digits: the booth's label face has no fraction glyphs.
  for (final (x, w) in const [(0.25, '1/4'), (1 / 3, '1/3'), (0.5, '1/2'), (2 / 3, '2/3'), (0.75, '3/4')]) {
    if ((v - x).abs() < 0.004) return '×$w';
  }
  var t = v.toStringAsFixed(2);
  while (t.contains('.') && (t.endsWith('0') || t.endsWith('.'))) {
    t = t.substring(0, t.length - 1);
  }
  return '×$t';
}

/// The levels the app comes with, by row: MilkDrop most of the time (the booth's
/// way), the plainer backgrounds less; no mask the most, the difference the blend it
/// reaches for first; the topographic map never (it reads as terrain, not as the
/// scene).
const shippedLevels = <PlanAxis, Map<String, double>>{
  PlanAxis.ground: {
    'milk': 3,
    'white': 0.8,
    'pulse.grid': 0.5,
    'pulse.rays': 0.5,
    'pulse.smoke': 0.5,
    'pulse.stars': 0.5,
    'field.drift': 0.6,
    'cover': 0.6,
  },
  PlanAxis.mask: {'none': 2, 'keyhole': 0.6, 'inverted': 0.6},
  PlanAxis.mix: {'screen': 0.7, 'contrast': 1.5},
  // No effect most of the time: a sixth of the looks with one, as many of each.
  PlanAxis.fx: {'none': 4, 'kaleidoscope': 0.25, 'slit': 0.25, 'both': 0, 'mosh': 0.25},
  PlanAxis.style: {'contour': 0},
};

/// The masks and blends a background does not take, as shipped: on black a mask
/// leaves nothing and every blend is the normal one; added or screened onto white,
/// everything is white.
const shippedNotWith = <String, Set<String>>{
  'black': {'keyhole', 'inverted', 'add', 'screen', 'contrast'},
  'white': {'add', 'screen'},
};

/// A row's values, by name (a style's are the scene's own: see stylesOfFigure).
List<String> axisValues(PlanAxis a) => switch (a) {
      PlanAxis.ground => comboGrounds,
      PlanAxis.mask => [for (final m in Mask.values) m.name],
      PlanAxis.mix => [for (final m in Mix.values) m.name],
      PlanAxis.fx => [for (final f in Fx.values) f.name],
      PlanAxis.style || PlanAxis.shot => const [],
    };

/// A combination's value on a row (a framing is not a combination's).
String planValue(Combo c, PlanAxis a) => switch (a) {
      PlanAxis.style => c.style,
      PlanAxis.ground => c.ground,
      PlanAxis.mask => c.mask.name,
      PlanAxis.mix => c.mix.name,
      PlanAxis.fx => c.fx.name,
      PlanAxis.shot => '',
    };

// ------------------------------------------------------------------ cells
/// A cell's key: `style|ground|mask|mix|fx`, `*` for any of a row (the effect left
/// off where it is any: a key from before the effects).
String cellKey({String style = '*', String ground = '*', String mask = '*', String mix = '*', String fx = '*'}) =>
    '$style|$ground|$mask|$mix${fx == '*' ? '' : '|$fx'}';

/// The key of exactly [c].
String cellOf(Combo c) => cellKey(style: c.style, ground: c.ground, mask: c.mask.name, mix: c.mix.name, fx: c.fx.name);

/// A cell key's five rows (a key of four: the effect any); null where it is none.
List<String>? cellParts(String key) {
  final p = key.split('|');
  if (p.length == 4) return [...p, '*'];
  return p.length == 5 ? p : null;
}

/// Whether [key] is a cell key.
bool isCellKey(String key) => cellParts(key) != null;

/// Whether the cell [key] is about [c].
bool cellMatches(String key, Combo c) {
  final p = cellParts(key);
  if (p == null) return false;
  bool at(int i, String v) => p[i] == '*' || p[i] == v;
  return at(0, c.style) && at(1, c.ground) && at(2, c.mask.name) && at(3, c.mix.name) && at(4, c.fx.name);
}

/// Whether every look the cell [inner] is about, [outer] is about too.
bool cellCovers(String outer, String inner) {
  final o = cellParts(outer), i = cellParts(inner);
  if (o == null || i == null) return false;
  for (var k = 0; k < 5; k++) {
    if (o[k] != '*' && o[k] != i[k]) return false;
  }
  return true;
}

/// Whether the cells [a] and [b] are about a look in common.
bool cellsMeet(String a, String b) {
  final x = cellParts(a), y = cellParts(b);
  if (x == null || y == null) return false;
  for (var k = 0; k < 5; k++) {
    if (x[k] != '*' && y[k] != '*' && x[k] != y[k]) return false;
  }
  return true;
}

/// One scene's part of the plan.
class ScenePlan {
  const ScenePlan({
    this.level = 1,
    this.muted = false,
    this.styles = const {},
    this.shots = const {},
    this.own = const {},
    this.off = const {},
    this.cells = const {},
    this.allow = const {},
  });

  /// How often it comes against the other scenes (1 as shipped); muted, never,
  /// the level kept for when it is back.
  final double level;
  final bool muted;

  /// Its styles' levels, by name (absent: as shipped, 1 but the map's 0).
  final Map<String, double> styles;

  /// Its camera's framings' levels, by name (`fisheye`; absent: 1).
  final Map<String, double> shots;

  /// The rows it has its own of (the backgrounds, the masks, the blends): the whole
  /// row's levels, in place of the shared ones.
  final Map<PlanAxis, Map<String, double>> own;

  /// What of its own is muted: `style.ascii`, `shot.fisheye`, and of a row it owns
  /// `ground.white`, `mask.keyhole`, `mix.add`.
  final Set<String> off;

  /// The hands' word on some of its looks, by cell key: multiplied in (0 never).
  final Map<String, double> cells;

  /// The cells whose looks come however they measured.
  final Set<String> allow;

  static const none = ScenePlan();

  bool get isEmpty => toJson().isEmpty;

  /// The level as it counts (0 muted).
  double get weight => muted ? 0 : level;

  ScenePlan copyWith({
    double? level,
    bool? muted,
    Map<String, double>? styles,
    Map<String, double>? shots,
    Map<PlanAxis, Map<String, double>>? own,
    Set<String>? off,
    Map<String, double>? cells,
    Set<String>? allow,
  }) =>
      ScenePlan(
        level: level ?? this.level,
        muted: muted ?? this.muted,
        styles: styles ?? this.styles,
        shots: shots ?? this.shots,
        own: own ?? this.own,
        off: off ?? this.off,
        cells: cells ?? this.cells,
        allow: allow ?? this.allow,
      );

  Map<String, dynamic> toJson() => {
        if (level != 1) 'level': level,
        if (muted) 'muted': true,
        if (styles.isNotEmpty) 'styles': styles,
        if (shots.isNotEmpty) 'shots': shots,
        if (own.isNotEmpty) 'own': {for (final e in own.entries) e.key.name: e.value},
        if (off.isNotEmpty) 'off': off.toList()..sort(),
        if (cells.isNotEmpty) 'cells': cells,
        if (allow.isNotEmpty) 'allow': allow.toList()..sort(),
      };

  static ScenePlan fromJson(Object? j) {
    if (j is! Map) return none;
    final own = <PlanAxis, Map<String, double>>{};
    if (j['own'] is Map) {
      for (final e in (j['own'] as Map).entries) {
        final a = PlanAxis.values.asNameMap()['${e.key}'];
        if (a != null && sharedAxes.contains(a)) own[a] = _levels(e.value);
      }
    }
    return ScenePlan(
      level: j['level'] is num ? (j['level'] as num).toDouble().clamp(0.0, levelMost) : 1,
      muted: j['muted'] == true,
      styles: _levels(j['styles']),
      shots: _levels(j['shots']),
      own: own,
      off: _names(j['off']),
      cells: {
        if (j['cells'] is Map)
          for (final e in (j['cells'] as Map).entries)
            if (e.value is num && isCellKey('${e.key}')) '${e.key}': (e.value as num).toDouble().clamp(0.0, 16.0),
      },
      allow: {for (final k in _names(j['allow'])) if (isCellKey(k)) k},
    );
  }

  @override
  bool operator ==(Object other) => other is ScenePlan && _canon(other.toJson()) == _canon(toJson());
  @override
  int get hashCode => _canon(toJson()).hashCode;
}

Map<String, double> _levels(Object? j) => {
      if (j is Map)
        for (final e in j.entries)
          if (e.value is num) '${e.key}': (e.value as num).toDouble().clamp(0.0, levelMost),
    };

Set<String> _names(Object? j) => {if (j is List) for (final x in j) if (x is String) x};

/// A JSON value written the same way whatever order its maps were made in.
String _canon(Object? j) {
  Object? sorted(Object? v) => switch (v) {
        Map m => {for (final k in (m.keys.map((k) => '$k').toList()..sort())) k: sorted(m[k])},
        List l => [for (final x in l) sorted(x)],
        _ => v,
      };
  return jsonEncode(sorted(j));
}

/// The whole plan: each scene's part, and the rows every scene shares.
class ShowPlan {
  const ShowPlan({this.scenes = const {}, this.levels = const {}, this.off = const {}, this.notWith = shippedNotWith});

  /// Each scene's part, by its id (absent: as shipped).
  final Map<String, ScenePlan> scenes;

  /// The shared rows' levels the hands set (the backgrounds, the masks, the blends),
  /// over the shipped ones.
  final Map<PlanAxis, Map<String, double>> levels;

  /// What of the shared rows is muted: `ground.wash`, `mix.add`.
  final Set<String> off;

  /// The masks and blends each background does not take, by its key.
  final Map<String, Set<String>> notWith;

  static const shipped = ShowPlan();

  ScenePlan of(String scene) => scenes[scene] ?? ScenePlan.none;

  // ---------------------------------------------------------------- levels
  /// A scene's level as it counts (0: muted or off).
  double sceneLevel(String scene) => of(scene).weight;

  /// A shared row's level, as the hands left it (muted: 0).
  double shared(PlanAxis a, String v) {
    if (off.contains('${a.name}.$v')) return 0;
    return levels[a]?[v] ?? shippedLevels[a]?[v] ?? 1;
  }

  /// A shared row's level before its mute (what a fader shows).
  double sharedFader(PlanAxis a, String v) => levels[a]?[v] ?? shippedLevels[a]?[v] ?? 1;

  bool sharedMuted(PlanAxis a, String v) => off.contains('${a.name}.$v');

  /// Whether [scene] has its own of row [a].
  bool owns(String scene, PlanAxis a) => of(scene).own.containsKey(a);

  /// [v]'s level on row [a] in [scene]: its own style or framing, its own row where
  /// it has one, else the shared row's.
  double levelIn(String scene, PlanAxis a, String v) => mutedIn(scene, a, v) ? 0 : faderIn(scene, a, v);

  /// [levelIn] before its mute (what a fader shows); a shared row's mute counts where
  /// the scene shares it.
  double faderIn(String scene, PlanAxis a, String v, {ScenePlan? sp}) {
    final p = sp ?? of(scene);
    final mine = p.own[a];
    return switch (a) {
      PlanAxis.style => p.styles[v] ?? shippedLevels[PlanAxis.style]?[v] ?? 1,
      PlanAxis.shot => p.shots[v] ?? 1,
      _ when mine != null => mine[v] ?? shippedLevels[a]?[v] ?? 1,
      _ => sharedFader(a, v),
    };
  }

  /// Whether [v] of row [a] is muted in [scene] (its own mute, or the shared row's
  /// where it shares it).
  bool mutedIn(String scene, PlanAxis a, String v) {
    final sp = of(scene);
    if (sp.off.contains('${a.name}.$v')) return true;
    return sharedAxes.contains(a) && !sp.own.containsKey(a) && sharedMuted(a, v);
  }

  /// Whether the background [ground] takes the mask or blend [maskOrMix].
  bool takes(String ground, String maskOrMix) => !(notWith[ground]?.contains(maskOrMix) ?? false);

  /// The cells of [c]'s scene about it, multiplied.
  double cellsFor(Combo c) {
    var w = 1.0;
    for (final e in of(c.scene).cells.entries) {
      if (cellMatches(e.key, c)) w *= e.value;
    }
    return w;
  }

  /// Whether [c] comes however it measured (an allow of its scene is about it).
  bool allowed(Combo c) => of(c.scene).allow.any((k) => cellMatches(k, c));

  /// How likely [c] is within its scene, before how it measured: every level that
  /// applies, multiplied (0 where any of them is). A world: its style and its cells.
  double lookWeight(Combo c) {
    final w = baseWeight(c);
    return w <= 0 ? 0 : w * cellsFor(c);
  }

  /// [lookWeight] before the cells: the levels alone (and what the background takes).
  double baseWeight(Combo c) {
    final s = c.scene;
    final w = levelIn(s, PlanAxis.style, c.style) * levelIn(s, PlanAxis.fx, c.fx.name);
    if (w <= 0 || c.world) return w;
    if (!takes(c.ground, c.mask.name) || !takes(c.ground, c.mix.name)) return 0;
    return w * levelIn(s, PlanAxis.ground, c.ground) * levelIn(s, PlanAxis.mask, c.mask.name) * levelIn(s, PlanAxis.mix, c.mix.name);
  }

  /// Whether [c] is in the rotation at all (its scene on, and it weighs anything —
  /// how it measured aside).
  bool isOn(Combo c) => sceneLevel(c.scene) > 0 && lookWeight(c) > 0;

  /// [lookWeight] as the factors it is made of, in words and numbers: the style, the
  /// background, the mask, the blend (each the scene's own or the shared one), the
  /// background not taking it, the cells about it.
  List<({String what, double level})> factors(Combo c) {
    final s = c.scene;
    final out = <({String what, double level})>[
      (what: 'style ${c.style}', level: levelIn(s, PlanAxis.style, c.style)),
      (what: '${owns(s, PlanAxis.fx) ? 'its own ' : ''}effect ${c.fx.name}', level: levelIn(s, PlanAxis.fx, c.fx.name)),
    ];
    if (!c.world) {
      for (final (a, v) in [(PlanAxis.ground, c.ground), (PlanAxis.mask, c.mask.name), (PlanAxis.mix, c.mix.name)]) {
        out.add((what: '${owns(s, a) ? 'its own ' : ''}${a.name} $v', level: levelIn(s, a, v)));
      }
      if (!takes(c.ground, c.mask.name)) out.add((what: '${c.ground} takes no ${c.mask.name}', level: 0));
      if (!takes(c.ground, c.mix.name)) out.add((what: '${c.ground} takes no ${c.mix.name}', level: 0));
    }
    for (final e in of(s).cells.entries) {
      if (cellMatches(e.key, c)) out.add((what: 'cell ${e.key}', level: e.value));
    }
    return out;
  }

  /// A framing's level in [scene] (`fisheye`).
  double shotLevel(String scene, String shot) => levelIn(scene, PlanAxis.shot, shot);

  // ---------------------------------------------------------------- changes
  ShowPlan copyWith({Map<String, ScenePlan>? scenes, Map<PlanAxis, Map<String, double>>? levels, Set<String>? off, Map<String, Set<String>>? notWith}) =>
      ShowPlan(scenes: scenes ?? this.scenes, levels: levels ?? this.levels, off: off ?? this.off, notWith: notWith ?? this.notWith);

  /// [scene]'s part changed by [f] (back to none where it comes to nothing).
  ShowPlan withSceneOf(String scene, ScenePlan Function(ScenePlan) f) {
    final next = f(of(scene));
    final out = {...scenes}..remove(scene);
    if (!next.isEmpty) out[scene] = next;
    return copyWith(scenes: out);
  }

  /// A scene's level, or its mute.
  ShowPlan withScene(String scene, {double? level, bool? muted}) => withSceneOf(scene, (p) => p.copyWith(level: level, muted: muted));

  /// A shared row's level (null: as shipped), or its mute.
  ShowPlan withShared(PlanAxis a, String v, {double? level, bool clear = false, bool? muted}) {
    var next = this;
    if (level != null || clear) {
      final row = {...?levels[a]}..remove(v);
      if (level != null && level != (shippedLevels[a]?[v] ?? 1)) row[v] = level;
      final all = {...levels}..remove(a);
      if (row.isNotEmpty) all[a] = row;
      next = next.copyWith(levels: all);
    }
    if (muted != null) next = next.copyWith(off: _toggled(next.off, '${a.name}.$v', muted));
    return next;
  }

  /// [v]'s level on row [a] in [scene] — its style, its framing, or (where it has
  /// its own of the row) its own background, mask or blend; or its mute. On a shared
  /// row the scene does not own, the shared row's.
  ShowPlan withIn(String scene, PlanAxis a, String v, {double? level, bool? muted}) {
    if (sharedAxes.contains(a) && !owns(scene, a)) return withShared(a, v, level: level, muted: muted);
    return withSceneOf(scene, (p) {
      var q = p;
      if (level != null) {
        switch (a) {
          case PlanAxis.style:
            final m = {...p.styles}..remove(v);
            if (level != (shippedLevels[PlanAxis.style]?[v] ?? 1)) m[v] = level;
            q = q.copyWith(styles: m);
          case PlanAxis.shot:
            final m = {...p.shots}..remove(v);
            if (level != 1) m[v] = level;
            q = q.copyWith(shots: m);
          default:
            q = q.copyWith(own: {...p.own, a: {...?p.own[a], v: level}});
        }
      }
      if (muted != null) q = q.copyWith(off: _toggled(q.off, '${a.name}.$v', muted));
      return q;
    });
  }

  /// [scene] with its own row [a] (the shared one's levels and mutes copied, to be
  /// changed for it alone), or sharing it again.
  ShowPlan withOwn(String scene, PlanAxis a, bool own) => withSceneOf(scene, (p) {
        if (own == p.own.containsKey(a)) return p;
        final prefix = '${a.name}.';
        if (!own) {
          return p.copyWith(own: {...p.own}..remove(a), off: {for (final k in p.off) if (!k.startsWith(prefix)) k});
        }
        return p.copyWith(
          own: {...p.own, a: {for (final v in axisValues(a)) v: sharedFader(a, v)}},
          off: {...p.off, for (final v in axisValues(a)) if (sharedMuted(a, v)) '$prefix$v'},
        );
      });

  /// Whether [ground] takes the mask or blend [maskOrMix].
  ShowPlan withTakes(String ground, String maskOrMix, bool takes) {
    final now = {...?notWith[ground]};
    if (takes) {
      now.remove(maskOrMix);
    } else {
      now.add(maskOrMix);
    }
    final next = {...notWith}..remove(ground);
    if (now.isNotEmpty) next[ground] = now;
    return copyWith(notWith: next);
  }

  /// One cell of [scene] at [v] (null or 1: none).
  ShowPlan withCell(String scene, String key, double? v) => withSceneOf(scene, (p) {
        final m = {...p.cells}..remove(key);
        if (v != null && v != 1) m[key] = v.clamp(0.0, 16.0);
        return p.copyWith(cells: m);
      });

  /// One cell of [scene] times [k] (less, more), kept within a sixteenth to sixteen.
  ShowPlan scaleCell(String scene, String key, double k) {
    final was = of(scene).cells[key] ?? 1;
    final next = (was * k).clamp(1 / 16, 16.0);
    return withCell(scene, key, (next - 1).abs() < 1e-6 ? null : next);
  }

  /// The looks of [scene] the cell [key] is about let come however they measured
  /// (or measured again).
  ShowPlan withAllow(String scene, String key, bool allow) => withSceneOf(scene, (p) {
        final a = {for (final k in p.allow) if (!(allow ? false : cellCovers(key, k))) k};
        if (allow) a.add(key);
        return p.copyWith(allow: a);
      });

  /// The looks of [scene] the cell [target] is about let out of every cell at 0 that
  /// keeps them out: a cell about nothing else taken away; a wider one cut round
  /// them (the rest of it stays at 0). [styles]: the scene's styles, to cut a `*`
  /// style by.
  ShowPlan withUnvetoed(String scene, String target, List<String> styles) => withSceneOf(scene, (p) {
        final values = [styles, [...comboGrounds, ownGround], axisValues(PlanAxis.mask), axisValues(PlanAxis.mix), axisValues(PlanAxis.fx)];
        final t = cellParts(target)!;
        final out = <String, double>{};
        for (final e in p.cells.entries) {
          if (e.value > 0 || !cellsMeet(e.key, target)) {
            out[e.key] = e.value;
            continue;
          }
          // Cut round the target: field by field where the cell says any and the
          // target one thing, the cell's other things kept at 0.
          var rest = cellParts(e.key)!;
          for (var k = 0; k < 5; k++) {
            if (rest[k] != '*' || t[k] == '*') continue;
            for (final v in values[k]) {
              if (v == t[k]) continue;
              final piece = [...rest]..[k] = v;
              out[_keyOf(piece)] = 0;
            }
            rest = [...rest]..[k] = t[k];
          }
          // What is left of the cell lies within the target: let go.
        }
        return p.copyWith(cells: out);
      });

  /// [to] made like [from]: its styles' levels and mutes where it has them, its own
  /// rows, and the cells (and allows) about styles it has or any style.
  ShowPlan copyScene(String from, String to, List<String> toStyles) {
    final f = of(from);
    final has = toStyles.toSet();
    bool styleOk(String key) {
      final st = cellParts(key)?.first ?? '';
      return st == '*' || has.contains(st);
    }

    return withSceneOf(
      to,
      (p) => p.copyWith(
        styles: {for (final e in f.styles.entries) if (has.contains(e.key)) e.key: e.value},
        own: f.own,
        off: {
          for (final k in p.off)
            if (k.startsWith('shot.')) k,
          for (final k in f.off)
            if (!k.startsWith('shot.') && (!k.startsWith('style.') || has.contains(k.substring(6)))) k,
        },
        cells: {for (final e in f.cells.entries) if (styleOk(e.key)) e.key: e.value},
        allow: {for (final k in f.allow) if (styleOk(k)) k},
      ),
    );
  }

  static Set<String> _toggled(Set<String> s, String k, bool on) => on ? {...s, k} : {for (final x in s) if (x != k) x};

  static String _keyOf(List<String> p) => cellKey(style: p[0], ground: p[1], mask: p[2], mix: p[3], fx: p[4]);

  // ---------------------------------------------------------------- json
  bool get _notWithShipped => _canon(_notWithJson(notWith)) == _canon(_notWithJson(shippedNotWith));

  static Map<String, dynamic> _notWithJson(Map<String, Set<String>> m) => {for (final e in m.entries) e.key: e.value.toList()..sort()};

  Map<String, dynamic> toJson() => {
        if (scenes.isNotEmpty) 'scenes': {for (final e in scenes.entries) e.key: e.value.toJson()},
        if (levels.isNotEmpty) 'levels': {for (final e in levels.entries) e.key.name: e.value},
        if (off.isNotEmpty) 'off': off.toList()..sort(),
        if (!_notWithShipped) 'notWith': _notWithJson(notWith),
      };

  static ShowPlan fromJson(Object? j) {
    if (j is! Map) return shipped;
    final levels = <PlanAxis, Map<String, double>>{};
    if (j['levels'] is Map) {
      for (final e in (j['levels'] as Map).entries) {
        final a = PlanAxis.values.asNameMap()['${e.key}'];
        if (a != null && sharedAxes.contains(a)) levels[a] = _levels(e.value);
      }
    }
    return ShowPlan(
      scenes: {
        if (j['scenes'] is Map)
          for (final e in (j['scenes'] as Map).entries)
            if (ScenePlan.fromJson(e.value) case final p when !p.isEmpty) '${e.key}': p,
      },
      levels: levels,
      off: _names(j['off']),
      notWith: j['notWith'] is Map ? {for (final e in (j['notWith'] as Map).entries) '${e.key}': _names(e.value)} : shippedNotWith,
    );
  }

  @override
  bool operator ==(Object other) => other is ShowPlan && (identical(other, this) || _canon(other.toJson()) == _canon(toJson()));
  @override
  int get hashCode => _canon(toJson()).hashCode;
}

/// A scene's looks, each with how likely it is within the scene (before how it
/// measured), the backgrounds [grounds] only.
List<(Combo, double)> lookWeights(ShowPlan plan, String scene, Figure kind, {Iterable<String> grounds = comboGrounds}) => [
      for (final c in combosOf(scene, kind, grounds: grounds)) (c, plan.lookWeight(c)),
    ];
