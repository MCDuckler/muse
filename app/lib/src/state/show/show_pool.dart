// The pool: what the director may reach for, and what the hands have switched off
// or leaned on — one switch and one lean per value of every axis (a ground, a
// figure, a shade, a dressing, a treatment, a shot, a troupe, a flight, a dancer, a
// move, a look), by a dotted key like `treatment.contour` or `dancer.joe`; and the
// combo table, which says for a figure on a ground whether the two go together at
// all and how they blend. The table ships with a first cut (judged under MilkDrop
// in contrast, the way the show is watched) that the hands edit from the panel.
//
// Plan: ~/.claude/plans/wetowl-show-layers.md, §1 and §5.3.
import 'show_rig.dart';

/// What the pool says of a figure on a ground.
class ComboRule {
  const ComboRule({this.off = false, this.ground, this.figure});

  /// The two never go together (the director passes the pair by).
  final bool off;

  /// The blend for the pair, where the rule has one.
  final GroundMode? ground;
  final FigureMode? figure;

  static const never = ComboRule(off: true);
  static const contrast = ComboRule(ground: GroundMode.contrast);
  static const over = ComboRule(ground: GroundMode.over);

  RigBlend blend({RigBlend from = RigBlend.over}) =>
      from.copyWith(ground: ground ?? from.ground, figure: figure ?? from.figure, auto: true);

  Map<String, dynamic> toJson() => {
        if (off) 'off': true,
        if (ground != null) 'ground': ground!.name,
        if (figure != null) 'figure': figure!.name,
      };

  factory ComboRule.fromJson(Map<String, dynamic> j) => ComboRule(
        off: j['off'] == true,
        ground: j['ground'] is String ? GroundMode.values.where((g) => g.name == j['ground']).firstOrNull : null,
        figure: j['figure'] is String ? FigureMode.values.where((f) => f.name == j['figure']).firstOrNull : null,
      );

  @override
  bool operator ==(Object other) => other is ComboRule && other.off == off && other.ground == ground && other.figure == figure;
  @override
  int get hashCode => Object.hash(off, ground, figure);
}

class ShowPool {
  const ShowPool({
    this.off = const {},
    this.lean = const {},
    this.combos = const {},
    this.dancer,
    this.quantise = Quantise.bar,
    this.bias = 0,
    this.tier = 'auto',
    this.darkBeat = false,
  });

  /// The quality tier the stage draws at: `auto`, `low`, `mid` or `high` (what the
  /// flock's count, the dancers' company and the working size go by).
  final String tier;

  /// The beat before a drop goes black.
  final bool darkBeat;

  /// The keys switched off: `look.flash`, `dancer.joe`, `treatment.contour`,
  /// `shot.fisheye`, `troupe.crowd`, `flight.vee`, `move.long22`, `ground.camera`…
  final Set<String> off;

  /// How much the director leans on a key, 0..2 (1 is neutral); absent is 1.
  final Map<String, double> lean;

  /// The hands' rules over the shipped table, by [comboKey].
  final Map<String, ComboRule> combos;

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
  List<String> offOf(String axis) => [for (final k in off) if (k.startsWith('$axis.')) k.substring(axis.length + 1)];

  /// Of [all] (by [name]), the ones switched on in [axis] — all of them when every one
  /// is off, as the stage is never empty.
  List<T> on<T>(String axis, Iterable<T> all, String Function(T) name) {
    final on = [for (final v in all) if (isOn('$axis.${name(v)}')) v];
    return on.isEmpty ? all.toList() : on;
  }

  ShowPool copyWith(
          {Set<String>? off,
          Map<String, double>? lean,
          Map<String, ComboRule>? combos,
          String? dancer,
          bool clearDancer = false,
          Quantise? quantise,
          double? bias,
          String? tier,
          bool? darkBeat}) =>
      ShowPool(
        off: off ?? this.off,
        lean: lean ?? this.lean,
        combos: combos ?? this.combos,
        dancer: clearDancer ? null : dancer ?? this.dancer,
        quantise: quantise ?? this.quantise,
        bias: bias ?? this.bias,
        tier: tier ?? this.tier,
        darkBeat: darkBeat ?? this.darkBeat,
      );

  ShowPool withOff(String key, bool isOff) => copyWith(off: isOff ? {...off, key} : {for (final k in off) if (k != key) k});

  ShowPool withLean(String key, double v) => copyWith(lean: {...lean, key: v.clamp(0.0, 2.0)});

  /// [rule] for the pair, or the shipped table's again (null).
  ShowPool withCombo(String key, ComboRule? rule) => copyWith(
        combos: rule == null ? {for (final e in combos.entries) if (e.key != key) e.key: e.value} : {...combos, key: rule},
      );

  // ---------------------------------------------------------------- the table
  /// The keys a figure on a ground is looked up by, most particular first: its
  /// treatment, its shade, the figure alone.
  static List<String> comboKeys(RigFigure f, Ground g) => [
        if (f.treatment != Treatment.auto) 'figure.${f.kind.name}.treatment.${f.treatment.name}|ground.${g.name}',
        if (f.shade != Shade.auto) 'figure.${f.kind.name}.shade.${f.shade.name}|ground.${g.name}',
        'figure.${f.kind.name}|ground.${g.name}',
      ];

  static String comboKey(RigFigure f, Ground g) => comboKeys(f, g).first;

  /// The rule for [f] on [g]: the hands' first, then the shipped table's, the most
  /// particular key that has one; none is "together, as the figure asks".
  ComboRule? ruleFor(RigFigure f, Ground g) {
    for (final k in comboKeys(f, g)) {
      final r = combos[k];
      if (r != null) return r;
    }
    for (final k in comboKeys(f, g)) {
      final r = shipped[k];
      if (r != null) return r;
    }
    return null;
  }

  /// Whether [f] may go on [g] at all.
  bool together(RigFigure f, Ground g) => !(ruleFor(f, g)?.off ?? false) && isOn('figure.${f.kind.name}') && isOn('ground.${g.name}');

  /// The blend for [f] on [g], from [from]'s strength: the table's modes where it has
  /// them, else over.
  RigBlend blendFor(RigFigure f, Ground g, {RigBlend from = RigBlend.over}) {
    final r = ruleFor(f, g);
    if (r == null) return from.copyWith(ground: g == Ground.black ? GroundMode.over : from.ground, auto: true);
    return r.blend(from: from);
  }

  /// The first cut of the table (plan §5.3), judged under MilkDrop in contrast. The
  /// milk column is the strictest: big flat fills invert a preset.
  static const shipped = <String, ComboRule>{
    // MilkDrop under the dancers: their own colours over it (the plain look), the
    // rest in contrast; the silhouettes and the viewports not at all.
    'figure.dancers.shade.textured|ground.milk': ComboRule(ground: GroundMode.contrast, figure: FigureMode.over),
    'figure.dancers.treatment.raw|ground.milk': ComboRule(ground: GroundMode.contrast, figure: FigureMode.over),
    'figure.dancers.shade.silhouette|ground.milk': ComboRule.never,
    'figure.dancers.treatment.viewports|ground.milk': ComboRule.never,
    'figure.dancers.treatment.fluid|ground.milk': ComboRule(ground: GroundMode.screen),
    'figure.dancers|ground.milk': ComboRule.contrast,
    // The birds: a sky is a ground of its own.
    'figure.birds.treatment.radar|ground.milk': ComboRule.contrast,
    'figure.birds|ground.milk': ComboRule.contrast,
    'figure.kinetic|ground.milk': ComboRule.contrast,
    'figure.glide|ground.milk': ComboRule.contrast,
    'figure.flash|ground.milk': ComboRule.contrast,
    'figure.blocks|ground.milk': ComboRule.contrast,
    'figure.turntable|ground.milk': ComboRule(ground: GroundMode.add),
    'figure.fluid|ground.milk': ComboRule(ground: GroundMode.screen),
    'figure.veins|ground.milk': ComboRule(ground: GroundMode.screen),
    'figure.meme|ground.milk': ComboRule.never,
    // The words: the letters over the preset as drawn, the paper between them in
    // contrast (the sim's own finish sets which pixel is which); the room and the
    // cover dimmed under them; a field or the pulse added under the paper.
    'figure.words|ground.milk': ComboRule(ground: GroundMode.contrast, figure: FigureMode.over),
    'figure.words|ground.camera': ComboRule(ground: GroundMode.dim, figure: FigureMode.over),
    'figure.words|ground.cover': ComboRule(ground: GroundMode.dim, figure: FigureMode.over),
    'figure.words|ground.field': ComboRule(ground: GroundMode.add, figure: FigureMode.over),
    'figure.words|ground.pulse': ComboRule(ground: GroundMode.add, figure: FigureMode.over),
    'figure.words|ground.wash': ComboRule(ground: GroundMode.add, figure: FigureMode.over),
    // The room: bodies over it; two busy pictures never.
    'figure.kinetic|ground.camera': ComboRule.never,
    'figure.glide|ground.camera': ComboRule.never,
    'figure.flash|ground.camera': ComboRule.never,
    'figure.blocks|ground.camera': ComboRule.never,
    'figure.dancers|ground.camera': ComboRule.over,
    'figure.birds|ground.camera': ComboRule.over,
    // A field under a shader is two shaders.
    'figure.kinetic|ground.field': ComboRule.never,
    'figure.glide|ground.field': ComboRule.never,
    'figure.flash|ground.field': ComboRule.never,
    'figure.blocks|ground.field': ComboRule.never,
    'figure.kinetic|ground.cover': ComboRule.never,
    'figure.glide|ground.cover': ComboRule.never,
    'figure.flash|ground.cover': ComboRule.never,
    'figure.blocks|ground.cover': ComboRule.never,
    'figure.kinetic|ground.pulse': ComboRule(ground: GroundMode.add),
    'figure.glide|ground.pulse': ComboRule(ground: GroundMode.add),
    'figure.flash|ground.pulse': ComboRule(ground: GroundMode.add),
    'figure.blocks|ground.pulse': ComboRule(ground: GroundMode.add),
    'figure.kinetic|ground.wash': ComboRule(ground: GroundMode.add),
    'figure.glide|ground.wash': ComboRule(ground: GroundMode.add),
    'figure.flash|ground.wash': ComboRule(ground: GroundMode.add),
    'figure.blocks|ground.wash': ComboRule(ground: GroundMode.add),
  };

  /// The values switched off to start with: the topographic map read as terrain,
  /// not a dancer.
  static const shippedOff = {'treatment.contour'};

  // ---------------------------------------------------------------- json
  Map<String, dynamic> toJson() => {
        if (off.isNotEmpty) 'off': off.toList()..sort(),
        if (lean.isNotEmpty) 'lean': lean,
        if (combos.isNotEmpty) 'combos': {for (final e in combos.entries) e.key: e.value.toJson()},
        if (dancer != null) 'dancer': dancer,
        if (quantise != Quantise.bar) 'quantise': quantise.name,
        if (bias != 0) 'bias': bias,
        if (tier != 'auto') 'tier': tier,
        if (darkBeat) 'darkBeat': true,
      };

  factory ShowPool.fromJson(Map<String, dynamic> j) => ShowPool(
        off: {for (final k in (j['off'] as List? ?? const [])) '$k'},
        lean: j['lean'] is Map ? {for (final e in (j['lean'] as Map).entries) '${e.key}': (e.value as num).toDouble()} : const {},
        combos: j['combos'] is Map
            ? {for (final e in (j['combos'] as Map).entries) if (e.value is Map) '${e.key}': ComboRule.fromJson((e.value as Map).cast())}
            : const {},
        dancer: j['dancer'] as String?,
        quantise: Quantise.values.where((q) => q.name == j['quantise']).firstOrNull ?? Quantise.bar,
        bias: j['bias'] is num ? (j['bias'] as num).toDouble().clamp(-1.0, 1.0) : 0,
        tier: const ['auto', 'low', 'mid', 'high'].contains(j['tier']) ? '${j['tier']}' : 'auto',
        darkBeat: j['darkBeat'] == true,
      );

  /// From the preferences the show kept before it had a pool (one time, on the first
  /// start with none): the scenes and the dancers switched off, who dances.
  factory ShowPool.migrated({Iterable<String> scenesOff = const [], Iterable<String> dancersOff = const [], String? dancer}) => ShowPool(
        off: {
          ...shippedOff,
          for (final s in scenesOff) 'look.$s',
          for (final d in dancersOff) 'dancer.$d',
        },
        dancer: dancer == null || dancer == 'mix' ? null : dancer,
      );

  /// The looks switched off, by id (what ShowDirector.off reads).
  Set<String> get looksOff => offOf('look').toSet();

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
    favourites = {for (final e in pool.lean.entries) if (e.key.startsWith('move.') && e.value > 1.5) e.key.substring(5)};
  }
}

/// What the dancers' and the birds' clocks read of the pool: the styles (treatments,
/// looks) switched off, by name. Set by the engine as the pool changes.
class StylePool {
  const StylePool._();
  static Set<String> off = const {};

  static void from(ShowPool pool) => off = pool.offOf('treatment').toSet();
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
