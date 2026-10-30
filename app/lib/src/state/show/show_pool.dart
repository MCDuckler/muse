// The pool: what the director may reach for and how the hands left the show. The
// plan (show_plan.dart): how often every scene comes, and every look of it. And the
// rest the hands set and keep: the effects, the director's temper, the knobs, the
// finish, the 3D text, the quality, who dances, the switches and leans of the moves
// (`dancer.joe`, `move.long22`).
//
// Plans: ~/.claude/plans/wetowl-show-combos.md, wetowl-show-ui-rework.md.
import 'show_combos.dart';
import 'show_plan.dart';
import 'show_rig.dart';
import 'show_type3d.dart';

export 'show_combos.dart';
export 'show_plan.dart';
export 'show_type3d.dart';

class ShowPool {
  const ShowPool({
    this.off = const {},
    this.lean = const {},
    this.plan = ShowPlan.shipped,
    this.legacy,
    this.before,
    this.dancer,
    this.quantise = Quantise.bar,
    this.bias = 0,
    this.tier = 'auto',
    this.darkBeat = false,
    this.mosh = defaultMosh,
    this.tune = const {},
    this.type3d = TypeSpec.standard,
    this.transform = TransformSet.standard,
    this.adapt = true,
    this.finish,
    this.strength = 1,
  });

  /// How often everything comes (show_plan.dart).
  final ShowPlan plan;

  /// The combination rules of before the plan, as kept, still to be read into it
  /// (that wants the scenes' figures: ShowEngine.looks); null once read.
  final List<dynamic>? legacy;

  /// The same, kept as they were after they were read (for one version, to go back).
  final List<dynamic>? before;

  /// The treatments' knobs, by `treatment.knob` (show_tune.dart): `lines.weight`.
  final Map<String, double> tune;

  /// The transformation's settings: the director's pick or the hands', the
  /// kaleidoscope's copies, how often (show_rig.dart).
  final TransformSet transform;

  /// The stages lower their working size while frames come late, and raise it back
  /// (the frames over the picture); off, they keep the tier's size whatever.
  final bool adapt;

  /// The 3D type's words, face, motions and knobs (show_type3d.dart).
  final TypeSpec type3d;

  /// The quality tier the stage draws at: `auto`, `low`, `mid` or `high` (what the
  /// flock's count, the dancers' company and the working size go by).
  final String tier;

  /// The beat before a drop goes black.
  final bool darkBeat;

  /// How many of the changes are datamoshed, 0..1 (show_director.dart's
  /// SceneChange.mosh).
  final double mosh;
  static const defaultMosh = 0.35;

  /// The hands' finish over every scene (the trails, the bloom…); null: each look's own.
  final RigFinish? finish;

  /// How strong the blend is, 0..1 (1: all of it).
  final double strength;

  /// The keys switched off: `dancer.joe`, `move.long22`…
  final Set<String> off;

  /// How much the director leans on a key, 0..2 (1 is neutral); absent is 1.
  final Map<String, double> lean;

  /// Who leads the dancers: a model's id, or null for each record its own (a mix).
  final String? dancer;

  /// When a change the hands ask for lands (a combination or a favourite put on).
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
          ShowPlan? plan,
          List<dynamic>? legacy,
          bool clearLegacy = false,
          List<dynamic>? before,
          String? dancer,
          bool clearDancer = false,
          Quantise? quantise,
          double? bias,
          String? tier,
          bool? darkBeat,
          double? mosh,
          Map<String, double>? tune,
          TypeSpec? type3d,
          TransformSet? transform,
          bool? adapt,
          RigFinish? finish,
          bool clearFinish = false,
          double? strength}) =>
      ShowPool(
        off: off ?? this.off,
        lean: lean ?? this.lean,
        plan: plan ?? this.plan,
        legacy: clearLegacy ? null : legacy ?? this.legacy,
        before: before ?? this.before,
        dancer: clearDancer ? null : dancer ?? this.dancer,
        quantise: quantise ?? this.quantise,
        bias: bias ?? this.bias,
        tier: tier ?? this.tier,
        darkBeat: darkBeat ?? this.darkBeat,
        mosh: mosh ?? this.mosh,
        tune: tune ?? this.tune,
        type3d: type3d ?? this.type3d,
        transform: transform ?? this.transform,
        adapt: adapt ?? this.adapt,
        finish: clearFinish ? null : finish ?? this.finish,
        strength: strength ?? this.strength,
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

  ShowPool withPlan(ShowPlan p) => copyWith(plan: p);

  // ---------------------------------------------------------------- the set
  /// What a set (a snapshot) keeps: the plan, the effects, the director's temper,
  /// the knobs, the finish.
  ShowSetup get setup => ShowSetup(plan: plan, transform: transform, bias: bias, mosh: mosh, darkBeat: darkBeat, tune: tune, finish: finish, strength: strength);

  /// [s] in force, the rest as it is.
  ShowPool withSetup(ShowSetup s) => copyWith(
        plan: s.plan,
        transform: s.transform,
        bias: s.bias,
        mosh: s.mosh,
        darkBeat: s.darkBeat,
        tune: s.tune,
        finish: s.finish,
        clearFinish: s.finish == null,
        strength: s.strength,
      );

  // ---------------------------------------------------------------- json
  Map<String, dynamic> toJson() => {
        if (off.isNotEmpty) 'off': off.toList()..sort(),
        if (lean.isNotEmpty) 'lean': lean,
        if (plan != ShowPlan.shipped) 'plan': plan.toJson(),
        if (legacy != null) 'combos': legacy,
        if (before != null) 'combosBefore': before,
        if (dancer != null) 'dancer': dancer,
        if (quantise != Quantise.bar) 'quantise': quantise.name,
        if (bias != 0) 'bias': bias,
        if (tier != 'auto') 'tier': tier,
        if (darkBeat) 'darkBeat': true,
        if (mosh != defaultMosh) 'mosh': mosh,
        if (tune.isNotEmpty) 'tune': tune,
        if (type3d != TypeSpec.standard) 'type3d': type3d.toJson(),
        if (transform != TransformSet.standard) 'transform': transform.toJson(),
        if (!adapt) 'adapt': false,
        if (finish != null) 'finish': finish!.toJson(),
        if (strength != 1) 'strength': strength,
      };

  factory ShowPool.fromJson(Map<String, dynamic> j) => ShowPool(
        // The switches of the rules before the combinations (a look, a ground, a style,
        // a treatment, a blend off) are not carried.
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
        plan: _effectsOfOld(ShowPlan.fromJson(j['plan']), j['transform']),
        // The combination rules (a list; before them a map of the old exceptions,
        // which is not carried): read into the plan once the scenes are known.
        legacy: j['plan'] == null && j['combos'] is List && (j['combos'] as List).isNotEmpty ? j['combos'] as List : null,
        before: j['combosBefore'] is List ? j['combosBefore'] as List : null,
        dancer: j['dancer'] as String?,
        quantise: Quantise.values.where((q) => q.name == j['quantise']).firstOrNull ?? Quantise.bar,
        bias: j['bias'] is num ? (j['bias'] as num).toDouble().clamp(-1.0, 1.0) : 0,
        tier: const ['auto', 'low', 'mid', 'high'].contains(j['tier']) ? '${j['tier']}' : 'auto',
        darkBeat: j['darkBeat'] == true,
        mosh: j['mosh'] is num ? (j['mosh'] as num).toDouble().clamp(0.0, 1.0) : defaultMosh,
        tune: j['tune'] is Map ? {for (final e in (j['tune'] as Map).entries) if (e.value is num) '${e.key}': (e.value as num).toDouble()} : const {},
        type3d: TypeSpec.fromJson(j['type3d']),
        transform: TransformSet.fromJson(j['transform']),
        adapt: j['adapt'] != false,
        finish: j['finish'] is Map ? RigFinish.fromJson((j['finish'] as Map).cast()) : null,
        strength: j['strength'] is num ? (j['strength'] as num).toDouble().clamp(0.0, 1.0) : 1,
      );

  static const _oldAxes = ['look.', 'ground.', 'style.', 'treatment.', 'blend.', 'figure.'];

  /// The effects as the transformation's settings said them before the plan had an
  /// effect row (a mode the hands held, or the director's now and then): one held is
  /// that effect alone; none, none; the director's never (often 0), none — the rest as
  /// shipped. Once: a plan with an effect row of its own is as it says.
  static ShowPlan _effectsOfOld(ShowPlan plan, Object? transform) {
    if (transform is! Map || transform['mode'] is! String) return plan;
    if (plan.levels.containsKey(PlanAxis.fx) || plan.off.any((k) => k.startsWith('fx.'))) return plan;
    final mode = transform['mode'] as String;
    final only = switch (mode) {
      'kaleidoscope' || 'slit' || 'both' => mode,
      'none' => 'none',
      _ => transform['often'] == 0 ? 'none' : null,
    };
    if (only == null) return plan;
    var p = plan;
    for (final f in Fx.values) {
      p = p.withShared(PlanAxis.fx, f.name, muted: f.name != only);
    }
    // Held on its own, at a level it can be heard at (the shipped 0 for both).
    if (p.sharedFader(PlanAxis.fx, only) <= 0) p = p.withShared(PlanAxis.fx, only, level: 1);
    return p;
  }

  /// From the preferences the show kept before it had a pool (one time, on the first
  /// start with none): the scenes and the dancers switched off, who dances.
  factory ShowPool.migrated({Iterable<String> scenesOff = const [], Iterable<String> dancersOff = const [], String? dancer}) {
    var plan = ShowPlan.shipped;
    for (final s in scenesOff) {
      plan = plan.withScene(s, muted: true);
    }
    return ShowPool(
      off: {for (final d in dancersOff) 'dancer.$d'},
      plan: plan,
      dancer: dancer == null || dancer == 'mix' ? null : dancer,
    );
  }

  /// The dancers switched off, by id (what ShowMacros.dancersOff carries).
  List<String> get dancersOff => offOf('dancer')..sort();
}

/// What a set keeps of the pool: how often everything comes, the effects, the
/// director's temper, the knobs, the finish — not this machine's (the quality), nor
/// what a scene says (the 3D text's words, who dances).
class ShowSetup {
  const ShowSetup({
    this.plan = ShowPlan.shipped,
    this.transform = TransformSet.standard,
    this.bias = 0,
    this.mosh = ShowPool.defaultMosh,
    this.darkBeat = false,
    this.tune = const {},
    this.finish,
    this.strength = 1,
  });

  final ShowPlan plan;
  final TransformSet transform;
  final double bias, mosh, strength;
  final bool darkBeat;
  final Map<String, double> tune;
  final RigFinish? finish;

  /// As the app comes.
  static const shipped = ShowSetup();

  Map<String, dynamic> toJson() => {
        if (plan != ShowPlan.shipped) 'plan': plan.toJson(),
        if (transform != TransformSet.standard) 'transform': transform.toJson(),
        if (bias != 0) 'bias': bias,
        if (mosh != ShowPool.defaultMosh) 'mosh': mosh,
        if (darkBeat) 'darkBeat': true,
        if (tune.isNotEmpty) 'tune': tune,
        if (finish != null) 'finish': finish!.toJson(),
        if (strength != 1) 'strength': strength,
      };

  static ShowSetup fromJson(Object? j) {
    if (j is! Map) return shipped;
    final p = ShowPool.fromJson(j.cast<String, dynamic>());
    return p.setup;
  }

  @override
  bool operator ==(Object other) =>
      other is ShowSetup &&
      other.plan == plan &&
      other.transform == transform &&
      other.bias == bias &&
      other.mosh == mosh &&
      other.darkBeat == darkBeat &&
      other.strength == strength &&
      other.finish == finish &&
      other.tune.length == tune.length &&
      other.tune.entries.every((e) => tune[e.key] == e.value);
  @override
  int get hashCode => Object.hash(plan, transform, bias, mosh, darkBeat, strength, finish, tune.length);
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

/// What the dancers' and the birds' clocks read of the plan, where no style comes
/// with the frame (a stage window fed by a demo): the styles' levels in their scene;
/// and their framings' at every cut. And the way back: a figure's clock says which
/// style and framing it has on ([now], [shotNow]).
class StylePool {
  const StylePool._();

  /// The engine's plan (or, in a window of its own, the one the wire brought).
  static ShowPlan plan = ShowPlan.shipped;

  /// The scene each figure stands in (the plan's levels are a scene's).
  static Map<Figure, String> sceneOf = const {Figure.dancers: 'dance-art', Figure.birds: 'flock', Figure.words: 'lyrics', Figure.type3d: 'type3d'};

  /// Each figure's style of the moment, by name, as its clock chose it.
  static final Map<Figure, String> now = {};

  /// Each figure's framing of the moment, by name, as its clock cut to it.
  static final Map<Figure, String> shotNow = {};

  /// A framing held by the hands (a favourite put on), as `figure.shot`: its figure's
  /// clock cuts to it at once and keeps it until it is let go. Null: the plan's.
  static String? heldShot;

  /// [heldShot], where it is [kind]'s: the framing's own name.
  static String? held(Figure kind) {
    final h = heldShot, p = '${kind.name}.';
    return h != null && h.startsWith(p) ? h.substring(p.length) : null;
  }

  /// The 3D text's motion, look and bends of the moment, as its sim picked them (or,
  /// with the stage in a window of its own, as that window says).
  static ({TypeMotion motion, TypeLook look, Set<TypeDeform> bends})? typeNow;

  static void from(ShowPool p) => plan = p.plan;

  static bool allows(Figure kind, String style) => weight(kind, style) > 0;

  /// How much a figure's clock leans on [style]: its level in the figure's scene.
  static double weight(Figure kind, String style) {
    final scene = sceneOf[kind];
    return scene == null ? 1 : plan.levelIn(scene, PlanAxis.style, style);
  }

  /// The combination on (the engine's, each frame).
  static Combo? combo;

  /// How much a figure's clock leans on its framing [shot] (by its own name: `fisheye`):
  /// its level in the figure's scene.
  static double shot(Figure kind, String shot) {
    final scene = sceneOf[kind];
    return scene == null ? 1 : plan.shotLevel(scene, shot);
  }

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
