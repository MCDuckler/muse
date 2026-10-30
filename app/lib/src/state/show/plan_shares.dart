// How much of a night each thing gets by the plan (show_plan.dart), for the SHOW
// page to say in place of levels: a scene's share of the night is its level against
// the other scenes' on (the director shares the time so, over a night — the music
// says when); a look's share of its scene is its weight against the scene's other
// looks', as the director draws them (how they measured counted); a look's share of
// the night, the two multiplied. "About": the music leans every pick, these are what
// the plan alone would give.
import 'combo_scores.dart';
import 'show_combos.dart';
import 'show_plan.dart';
import 'show_rig.dart' show Figure;

class PlanShares {
  PlanShares._(this.plan, this._kinds, this._grounds, this._scores);

  final ShowPlan plan;
  final Map<String, Figure> _kinds;
  final Set<String> _grounds;
  final ComboScores? _scores;

  static PlanShares? _last;

  /// The shares by [plan] for the scenes [kinds] (their figures, by id), with the
  /// backgrounds [grounds] here; the last one asked for again where nothing changed.
  static PlanShares of(ShowPlan plan, Map<String, Figure> kinds, Set<String> grounds, {ComboScores? scores}) {
    final last = _last;
    final s = scores ?? ComboScores.shipped;
    if (last != null &&
        identical(last.plan, plan) &&
        identical(last._kinds, kinds) &&
        identical(last._scores, s) &&
        last._grounds.length == grounds.length &&
        last._grounds.containsAll(grounds)) {
      return last;
    }
    return _last = PlanShares._(plan, kinds, grounds, s);
  }

  final _looks = <String, Map<Combo, double>>{};

  /// Each look of [scene] with its share of the scene's time (0 for the ones never on).
  Map<Combo, double> looksOf(String scene) => _looks.putIfAbsent(scene, () {
        final kind = _kinds[scene] ?? Figure.none;
        final all = [
          for (final c in combosOf(scene, kind, grounds: comboGrounds.where(_grounds.contains))) (c, ComboScores.weigh(c, plan, scores: _scores)),
        ];
        final total = all.fold(0.0, (a, o) => a + o.$2);
        return {for (final (c, w) in all) c: total <= 0 ? 0.0 : w / total};
      });

  /// Whether any look of [scene] can come (with the backgrounds here).
  bool anyOn(String scene) => looksOf(scene).values.any((v) => v > 0);

  /// Each scene's share of the night.
  late final Map<String, double> scenes = () {
    final levels = {for (final s in _kinds.keys) s: anyOn(s) ? plan.sceneLevel(s) : 0.0};
    final total = levels.values.fold(0.0, (a, b) => a + b);
    return {for (final e in levels.entries) e.key: total <= 0 ? 0.0 : e.value / total};
  }();

  /// [c]'s share of the night.
  double ofNight(Combo c) => (scenes[c.scene] ?? 0) * (looksOf(c.scene)[c] ?? 0);

  /// The share of [scene]'s time with [value] on row [a] (a style, a background…).
  double within(String scene, PlanAxis a, String value) {
    var t = 0.0;
    for (final e in looksOf(scene).entries) {
      if (planValue(e.key, a) == value) t += e.value;
    }
    return t;
  }

  /// The share of [scene]'s time in [style] on [ground] (every mask and blend).
  double cell(String scene, String style, String ground) {
    var t = 0.0;
    for (final e in looksOf(scene).entries) {
      if (e.key.style == style && e.key.ground == ground) t += e.value;
    }
    return t;
  }

  final _night = <PlanAxis, Map<String, double>>{};

  /// The share of the night with [value] on row [a], every scene's looks counted.
  double ofNightBy(PlanAxis a, String value) => _night.putIfAbsent(a, () {
        final out = <String, double>{};
        for (final s in _kinds.keys) {
          final k = scenes[s] ?? 0;
          if (k <= 0) continue;
          for (final e in looksOf(s).entries) {
            final v = planValue(e.key, a);
            out[v] = (out[v] ?? 0) + k * e.value;
          }
        }
        return out;
      })[value] ?? 0;
}

/// A share in words: `12 %`, `0.4 %`, `<0.1 %`, `—` for none.
String shareWord(double share) {
  final p = share * 100;
  if (p <= 0) return '—';
  if (p < 0.1) return '<0.1 %';
  return '${p.toStringAsFixed(p < 10 ? 1 : 0)} %';
}
