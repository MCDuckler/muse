// The pool: what the director may reach for. The combinations (show_combos.dart):
// the rules that came with the app and the hands' own — a card's weight, an
// exception's — over every background, scene, style, mask and blend. And the
// switches and leans of the rest, by a dotted key (`dancer.joe`, `move.long22`).
//
// Plan: ~/.claude/plans/wetowl-show-combos.md.
import 'show_combos.dart';
import 'show_rig.dart';

export 'show_combos.dart';

class ShowPool {
  const ShowPool({
    this.off = const {},
    this.lean = const {},
    this.rules = const [],
    this.dancer,
    this.quantise = Quantise.bar,
    this.bias = 0,
    this.tier = 'auto',
    this.darkBeat = false,
    this.tune = const {},
  });

  /// The treatments' knobs, by `treatment.knob` (show_tune.dart): `lines.weight`.
  final Map<String, double> tune;

  /// The quality tier the stage draws at: `auto`, `low`, `mid` or `high` (what the
  /// flock's count, the dancers' company and the working size go by).
  final String tier;

  /// The beat before a drop goes black.
  final bool darkBeat;

  /// The keys switched off: `dancer.joe`, `move.long22`, `shot.fisheye`…
  final Set<String> off;

  /// How much the director leans on a key, 0..2 (1 is neutral); absent is 1.
  final Map<String, double> lean;

  /// The hands' rules for the combinations, in the order they were made (each
  /// pattern once).
  final List<ComboRule> rules;

  /// Who leads the dancers: a model's id, or null for each record its own (a mix).
  final String? dancer;

  /// When a change the hands ask for lands.
  final Quantise quantise;

  /// The director's bias, calm (-1) to busy (+1).
  final double bias;

  static const none = ShowPool();

  bool isOn(String key) => !off.contains(key);
  double leanOf(String key) => lean[key] ?? 1;

  /// The keys of [axis] that are switched off, as their values.
  List<String> offOf(String axis) => [
        for (final k in off)
          if (k.startsWith('$axis.')) k.substring(axis.length + 1)
      ];

  ShowPool copyWith(
          {Set<String>? off,
          Map<String, double>? lean,
          List<ComboRule>? rules,
          String? dancer,
          bool clearDancer = false,
          Quantise? quantise,
          double? bias,
          String? tier,
          bool? darkBeat,
          Map<String, double>? tune}) =>
      ShowPool(
        off: off ?? this.off,
        lean: lean ?? this.lean,
        rules: rules ?? this.rules,
        dancer: clearDancer ? null : dancer ?? this.dancer,
        quantise: quantise ?? this.quantise,
        bias: bias ?? this.bias,
        tier: tier ?? this.tier,
        darkBeat: darkBeat ?? this.darkBeat,
        tune: tune ?? this.tune,
      );

  ShowPool withOff(String key, bool isOff) => copyWith(
      off: isOff
          ? {...off, key}
          : {
              for (final k in off)
                if (k != key) k
            });

  /// A treatment's knob set, or back to its rest (null).
  ShowPool withTune(String key, double? v) =>
      copyWith(tune: v == null ? {for (final e in tune.entries) if (e.key != key) e.key: e.value} : {...tune, key: v});

  ShowPool withLean(String key, double v) => copyWith(lean: {...lean, key: v.clamp(0.0, 2.0)});

  // ---------------------------------------------------------------- the combinations
  /// Every rule in force: the shipped ones, but those the hands made their own
  /// pattern of, then the hands'.
  List<ComboRule> get allRules {
    final mine = {for (final r in rules) r.pattern};
    return [
      for (final r in shippedComboRules)
        if (!mine.contains(r.pattern)) r,
      ...rules,
    ];
  }

  double weightOf(Combo c) => comboWeight(c, allRules);

  ({double weight, List<ComboRule> cards, ComboRule? exception}) explain(Combo c) => explainWeight(c, allRules);

  /// The hands' rule for [pattern]'s pattern, at [weight]; null takes it away (back
  /// to the shipped one, where there is one).
  ShowPool withRule(ComboRule pattern, double? weight) {
    final p = pattern.pattern;
    final i = rules.indexWhere((r) => r.pattern == p);
    final next = [...rules];
    if (weight == null) {
      if (i >= 0) next.removeAt(i);
    } else if (i >= 0) {
      next[i] = pattern.withWeight(weight);
    } else {
      next.add(pattern.withWeight(weight));
    }
    return copyWith(rules: next);
  }

  /// The rule for exactly [pattern] in force, the hands' or the shipped; null where
  /// there is none.
  ComboRule? ruleFor(ComboRule pattern) {
    final p = pattern.pattern;
    for (final r in rules) {
      if (r.pattern == p) return r;
    }
    for (final r in shippedComboRules) {
      if (r.pattern == p) return r;
    }
    return null;
  }

  /// The hands' rule for exactly [pattern], where they made one.
  ComboRule? mineFor(ComboRule pattern) {
    final p = pattern.pattern;
    for (final r in rules) {
      if (r.pattern == p) return r;
    }
    return null;
  }

  /// A card's weight (a background, a scene, a style, a mask, a blend alone).
  double cardOf(ComboRule card) => ruleFor(card)?.weight ?? 1;

  /// What the cards make of one thing of a row ([value] by name: a mask's, a
  /// blend's): every card that names it, its own and a few-of-the-row's, multiplied.
  double cardWeight(ComboAxis a, String value) {
    var w = 1.0;
    for (final r in allRules) {
      if (r.card && (r.on(a)?.contains(value) ?? false)) w *= r.weight;
    }
    return w;
  }

  /// How much the camera leans on [shot] (a key: `dancers.fisheye`) while [c] is on.
  double shotWeightOf(Combo? c, String shot) => shotWeight(c, shot, allRules);

  /// MilkDrop as a background at all (its cards not at 0).
  bool get milkOn => cardWeight(ComboAxis.ground, 'milk') > 0;

  /// MilkDrop's card off, or back to the shipped weight.
  ShowPool withMilk(bool on) => withRule(const ComboRule(grounds: {'milk'}), on ? null : 0);

  /// A scene's card off, or back.
  bool sceneOn(String id) => cardWeight(ComboAxis.scene, id) > 0;
  ShowPool withScene(String id, bool on) => withRule(ComboRule(scenes: {id}), on ? null : 0);

  // ---------------------------------------------------------------- json
  Map<String, dynamic> toJson() => {
        if (off.isNotEmpty) 'off': off.toList()..sort(),
        if (lean.isNotEmpty) 'lean': lean,
        if (rules.isNotEmpty) 'combos': [for (final r in rules) r.toJson()],
        if (dancer != null) 'dancer': dancer,
        if (quantise != Quantise.bar) 'quantise': quantise.name,
        if (bias != 0) 'bias': bias,
        if (tier != 'auto') 'tier': tier,
        if (darkBeat) 'darkBeat': true,
        if (tune.isNotEmpty) 'tune': tune,
      };

  factory ShowPool.fromJson(Map<String, dynamic> j) => ShowPool(
        // The switches of the rules before the combinations (a look, a ground, a style,
        // a treatment, a blend off) are not carried: the combinations start afresh.
        off: {
          for (final k in (j['off'] as List? ?? const []))
            if (!_oldAxes.any((a) => '$k'.startsWith(a))) '$k'
        },
        lean: j['lean'] is Map
            ? {
                for (final e in (j['lean'] as Map).entries)
                  if (e.value is num && !_oldAxes.any((a) => '${e.key}'.startsWith(a))) '${e.key}': (e.value as num).toDouble()
              }
            : const {},
        // `combos` was a map of the old exceptions; the combinations' rules are a list.
        rules: j['combos'] is List ? [for (final r in j['combos'] as List) ComboRule.fromJson(r)].whereType<ComboRule>().toList() : const [],
        dancer: j['dancer'] as String?,
        quantise: Quantise.values.where((q) => q.name == j['quantise']).firstOrNull ?? Quantise.bar,
        bias: j['bias'] is num ? (j['bias'] as num).toDouble().clamp(-1.0, 1.0) : 0,
        tier: const ['auto', 'low', 'mid', 'high'].contains(j['tier']) ? '${j['tier']}' : 'auto',
        darkBeat: j['darkBeat'] == true,
        tune: j['tune'] is Map ? {for (final e in (j['tune'] as Map).entries) if (e.value is num) '${e.key}': (e.value as num).toDouble()} : const {},
      );

  static const _oldAxes = ['look.', 'ground.', 'style.', 'treatment.', 'blend.', 'figure.'];

  /// From the preferences the show kept before it had a pool (one time, on the first
  /// start with none): the scenes and the dancers switched off, who dances.
  factory ShowPool.migrated({Iterable<String> scenesOff = const [], Iterable<String> dancersOff = const [], String? dancer}) => ShowPool(
        off: {for (final d in dancersOff) 'dancer.$d'},
        rules: [for (final s in scenesOff) ComboRule(scenes: {s}, weight: 0)],
        dancer: dancer == null || dancer == 'mix' ? null : dancer,
      );

  /// The dancers switched off, by id (what ShowMacros.dancersOff carries).
  List<String> get dancersOff => offOf('dancer')..sort();
}

/// What the dancers' choreography reads of the pool, where it runs (a stage, a
/// window of its own): the moves switched off, the favourites, and one move asked
/// for by hand, danced by the lead at the next slot (then forgotten). Set by the
/// engine as the pool changes.
class MovePool {
  const MovePool._();
  static Set<String> off = const {};
  static Set<String> favourites = const {};
  static String? audition;

  static void from(ShowPool pool) {
    off = pool.offOf('move').toSet();
    favourites = {
      for (final e in pool.lean.entries)
        if (e.key.startsWith('move.') && e.value > 1.5) e.key.substring(5)
    };
  }
}

/// What the dancers' and the birds' clocks read of the pool, where no style comes
/// with the frame (a stage window fed by a demo): the styles' card weights. And the
/// way back: a figure's clock says which style it has on ([now]).
class StylePool {
  const StylePool._();

  /// The engine's pool.
  static ShowPool pool = ShowPool.none;

  /// Each figure's style of the moment, by name, as its clock chose it.
  static final Map<Figure, String> now = {};

  /// Each figure's framing of the moment, by name, as its clock cut to it.
  static final Map<Figure, String> shotNow = {};

  static void from(ShowPool p) => pool = p;

  static bool allows(Figure kind, String style) => weight(kind, style) > 0;

  /// How much a figure's clock leans on [style]: its card's weight.
  static double weight(Figure kind, String style) => pool.cardWeight(ComboAxis.style, style);

  /// The combination on (the engine's, each frame): what the camera's exceptions are
  /// matched against.
  static Combo? combo;

  /// How much a figure's clock leans on its framing [shot] (by its own name: `fisheye`)
  /// with the combination on: the camera's rules (show_combos.dart's shotWeight).
  static double shot(Figure kind, String shot) => pool.shotWeightOf(combo, '${kind.name}.$shot');

  /// One of [items] by [d] (0..1), each as likely as its weight (any, where none
  /// weighs).
  static T? pick<T>(List<T> items, double d, double Function(T) weight) =>
      pickByWeight([for (final i in items) (i, weight(i))], d) ?? (items.isEmpty ? null : items[(d * items.length).floor() % items.length]);
}

/// What the stages and the simulations read of the quality tier (show_pool.dart's
/// `tier`): how many birds, whether the big companies dance, how big the working
/// picture is. Set by the engine as the pool changes.
class QualityPool {
  const QualityPool._();
  static String tier = 'auto';
  static const tiers = ['auto', 'low', 'mid', 'high'];

  static void from(ShowPool pool) => tier = pool.tier;

  /// The flock's count, as a share of what the look asks.
  static double get flockK => switch (tier) { 'low' => 0.45, 'mid' => 0.75, _ => 1.0 };

  /// The big companies (a grid, an army, a ring of dancers).
  static bool get bigTroupes => tier != 'low';

  /// The working picture's size, as a share of the screen's (the stages still scale
  /// down on their own when frames run late).
  static double get workScale => switch (tier) { 'low' => 0.6, 'mid' => 0.8, _ => 1.0 };
}
