// How every combination looks, measured: the combination audit's table
// (tools/show-audit/audit.py, from the stage's own layers) — for each scene in each
// style, under each background, mask and blend, how good it looks (the figure legible,
// nothing blown out, no mud, no noise, something there) and how intense it is
// (contrast, detail, motion, light, colour, ranked across them all).
//
// The director weighs by both: the ugly ones never come by themselves (the hands may
// let one come: an allow of the plan's), and the intensity is matched to where the
// record is — dark and spare in an intro, climbing through a build, the hardest on the
// drop (show_director.dart).
import 'dart:convert';

import 'package:flutter/services.dart';

import 'show_combos.dart';
import 'show_plan.dart';

class ComboScores {
  ComboScores._(this._grounds, this._masks, this._mixes, this._figures);

  /// The table the app came with, once loaded (StageKit); null before, or without one.
  static ComboScores? shipped;

  static const asset = 'assets/show/combo_scores.json';

  /// [shipped] read from the app's assets, once (and the presets', [MilkScores]);
  /// none where it has no table.
  static Future<void> load(AssetBundle bundle) async {
    if (shipped == null) {
      try {
        shipped = parse(await bundle.loadString(asset));
      } catch (_) {}
    }
    if (MilkScores.shipped == null) {
      try {
        MilkScores.shipped = MilkScores.parse(await bundle.loadString(MilkScores.asset));
      } catch (_) {}
    }
  }

  final Map<String, int> _grounds, _masks, _mixes;
  final Map<String, ({String q, String i})> _figures;

  static ComboScores? parse(String text) {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      Map<String, int> ix(String k) => {for (final (i, v) in (j[k] as List).indexed) '$v': i};
      final figs = <String, ({String q, String i})>{};
      for (final e in (j['figures'] as Map<String, dynamic>).entries) {
        final v = e.value as Map<String, dynamic>;
        figs[e.key] = (q: v['q'] as String, i: v['i'] as String);
      }
      return ComboScores._(ix('grounds'), ix('masks'), ix('mixes'), figs);
    } catch (_) {
      return null;
    }
  }

  static const _digits = '0123456789abcdefghijklmnopqrstuvwxyz';

  double? _at(Combo c, bool quality) {
    final f = _figures['${c.scene}.${c.style}'];
    if (f == null) return null;
    final s = quality ? f.q : f.i;
    if (s.length == 1) return _value(s);
    final g = _grounds[c.ground], m = _masks[c.mask.name], x = _mixes[c.mix.name];
    if (g == null || m == null || x == null) return null;
    final k = (g * _masks.length + m) * _mixes.length + x;
    return k < s.length ? _value(s[k]) : null;
  }

  static double? _value(String ch) {
    final i = _digits.indexOf(ch);
    return i < 0 ? null : i / 35;
  }

  /// How good [c] looks, 0..1; null where it was never measured.
  double? quality(Combo c) => _at(c, true);

  /// How intense [c] is, 0 (dark, still, spare) to 1 (bright, busy, hard).
  double? intensity(Combo c) => _at(c, false);

  /// Below this a combination does not come by itself.
  static const floor = 0.3;

  /// [c]'s weight within its scene by [plan] and how it looks ([scores]; the shipped
  /// table where none is given): less as it looks worse, none under [floor] — but a
  /// look the hands let come (an allow of the plan's) comes as the levels say.
  static double weigh(Combo c, ShowPlan plan, {ComboScores? scores}) {
    final w = plan.lookWeight(c);
    if (w <= 0 || plan.allowed(c)) return w;
    return w * lean((scores ?? shipped)?.quality(c));
  }

  /// What [quality] does to a combination's weight: nothing for a good one, less and
  /// less towards [floor], nothing at all under it.
  static double lean(double? q) {
    if (q == null) return 1;
    if (q < floor) return 0;
    final t = ((q - floor) / (0.7 - floor)).clamp(0.0, 1.0);
    return 0.15 + 0.85 * t * t * (3 - 2 * t);
  }
}

/// How every MilkDrop preset the app came with looks, measured (tools/show-audit/milk.py):
/// on its own, as a background under a figure, and how intense it is — by the
/// preset's full name. The MilkDrop director picks by them (milk_director.dart).
class MilkScores {
  MilkScores._(this._presets);

  static MilkScores? shipped;

  static const asset = 'assets/show/milk_scores.json';

  final Map<String, String> _presets;

  static MilkScores? parse(String text) {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      return MilkScores._({for (final e in (j['presets'] as Map<String, dynamic>).entries) e.key: '${e.value}'});
    } catch (_) {
      return null;
    }
  }

  double? _at(String name, int i) {
    final s = _presets[name];
    return s == null || s.length <= i ? null : ComboScores._value(s[i]);
  }

  /// How good [name] looks on its own, 0..1; null: never measured (one of the hands').
  double? alone(String name) => _at(name, 0);

  /// How good it is under a figure (a dancer not lost in it), 0..1.
  double? ground(String name) => _at(name, 1);

  /// How intense, 0 (calm, dark, slow) to 1.
  double? intensity(String name) => _at(name, 2);

  /// How much it moves with the music by itself (its light and its motion on the
  /// kick, on real records), 0 (deaf to it) to 1; null: not measured.
  double? react(String name) => _at(name, 3);
}
