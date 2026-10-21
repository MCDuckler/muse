// The pool: what the director may reach for, and what the hands have switched off
// or leaned on — one switch and one lean per value of every axis (a ground, a
// figure, a shade, a dressing, a treatment, a shot, a troupe, a flight, a dancer, a
// move, a look), by a dotted key like `treatment.contour` or `dancer.joe`; and the
// combo table, which says for a figure on a ground whether the two go together at
// all and how they blend. The table ships with a first cut (judged under MilkDrop
// in contrast, the way the show is watched) that the hands edit from the panel.
//
// Plan: ~/.claude/plans/wetowl-show-layers.md, §1 and §5.3.
import 'show_characters.dart';
import 'show_rig.dart';

export 'show_characters.dart';

class ShowPool {
  const ShowPool({
    this.off = const {},
    this.lean = const {},
    this.combos = const {},
    this.characters = const {},
    this.rules = const {},
    this.dancer,
    this.quantise = Quantise.bar,
    this.bias = 0,
    this.tier = 'auto',
    this.darkBeat = false,
    this.tune = const {},
    this.treat = const {},
    this.mixes = const {},
  });

  /// What is in each look's mix of treatments, by the look's id: the treatments'
  /// names (`raw` for the look as drawn). A look with none of its own has the shipped
  /// mix (show_tune.dart's mixOf: every one but those switched off as `treatment.*`).
  final Map<String, List<String>> mixes;

  /// The treatments' knobs, by `treatment.knob` (show_tune.dart): `lines.weight`.
  final Map<String, double> tune;

  /// What treatment a look goes through, by the look's id: one by name (`blocks` →
  /// `ascii`), `raw` for none, `mix` or absent for the conductor's mix (show_tune.dart's
  /// treatMix, of the `treatment.*` switched on).
  final Map<String, String> treat;

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

  /// The hands' exceptions: one thing on one background, by [comboKey].
  final Map<String, ComboRule> combos;

  /// The hands' characters for things (`figure.<kind>`, `figure.<kind>.style.<name>`,
  /// by Character's name) and backgrounds (`ground.<kind>`, by Backdrop's name).
  final Map<String, String> characters;

  /// The hands' rules for a character on a background's (`lights|busy`…).
  final Map<String, ComboRule> rules;

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

  /// Of [all] (by [name]), the ones switched on in [axis] — all of them when every one
  /// is off, as the stage is never empty.
  List<T> on<T>(String axis, Iterable<T> all, String Function(T) name) {
    final on = [
      for (final v in all)
        if (isOn('$axis.${name(v)}')) v
    ];
    return on.isEmpty ? all.toList() : on;
  }

  ShowPool copyWith(
          {Set<String>? off,
          Map<String, double>? lean,
          Map<String, ComboRule>? combos,
          Map<String, String>? characters,
          Map<String, ComboRule>? rules,
          String? dancer,
          bool clearDancer = false,
          Quantise? quantise,
          double? bias,
          String? tier,
          bool? darkBeat,
          Map<String, double>? tune,
          Map<String, String>? treat,
          Map<String, List<String>>? mixes}) =>
      ShowPool(
        off: off ?? this.off,
        lean: lean ?? this.lean,
        combos: combos ?? this.combos,
        characters: characters ?? this.characters,
        rules: rules ?? this.rules,
        dancer: clearDancer ? null : dancer ?? this.dancer,
        quantise: quantise ?? this.quantise,
        bias: bias ?? this.bias,
        tier: tier ?? this.tier,
        darkBeat: darkBeat ?? this.darkBeat,
        tune: tune ?? this.tune,
        treat: treat ?? this.treat,
        mixes: mixes ?? this.mixes,
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

  /// [look] put through [treatment] (`raw`: none), or back to the mix (null).
  ShowPool withTreat(String look, String? treatment) =>
      copyWith(treat: treatment == null ? {for (final e in treat.entries) if (e.key != look) e.key: e.value} : {...treat, look: treatment});

  /// [look]'s own mix of treatments, by name.
  ShowPool withMix(String look, List<String> names) => copyWith(mixes: {...mixes, look: names});

  ShowPool withLean(String key, double v) => copyWith(lean: {...lean, key: v.clamp(0.0, 2.0)});

  /// [rule] for one thing on one background (an exception), or none again (null).
  ShowPool withCombo(String key, ComboRule? rule) => copyWith(
        combos: rule == null
            ? {
                for (final e in combos.entries)
                  if (e.key != key) e.key: e.value
              }
            : {...combos, key: rule},
      );

  // ---------------------------------------------------------------- the table
  /// The keys a figure on a ground is looked up by, most particular first: its
  /// named style (any figure's: a flock's `ink`, a dancer's `ascii`), its
  /// treatment, its shade, the figure alone. A dancer's style stands in for the
  /// axes it means where they are auto: `plain` is the textured shade, `mono` the
  /// silhouette, and `ascii`, `dither`, `chrono`… are treatments.
  static List<String> comboKeys(RigFigure f, Ground g) {
    final t = f.treatment != Treatment.auto ? f.treatment : (f.kind == Figure.dancers || f.kind == Figure.birds ? treatmentOfStyle(f.style) : null);
    final sh = f.shade != Shade.auto ? f.shade : (f.kind == Figure.dancers ? shadeOfStyle(f.style) : null);
    // A dancer's shade or treatment set without a style means the style of that name.
    final style = f.style ?? (f.kind == Figure.dancers ? styleOfShade(f.shade) ?? (f.treatment != Treatment.auto ? f.treatment.name : null) : null);
    return [
      if (style != null) 'figure.${f.kind.name}.style.$style|ground.${g.name}',
      if (t != null) 'figure.${f.kind.name}.treatment.${t.name}|ground.${g.name}',
      // A word for the treatment on any scene: under one for this scene in it,
      // over one for the scene as it is.
      if (t != null && anyTreatments.contains(t)) treatmentKey(t, g),
      if (sh != null) 'figure.${f.kind.name}.shade.${sh.name}|ground.${g.name}',
      'figure.${f.kind.name}|ground.${g.name}',
    ];
  }

  /// The shade a dancer's style means: `plain` is the scans textured, `mono` a
  /// silhouette; none for the rest.
  static Shade? shadeOfStyle(String? style) => switch (style) { 'plain' => Shade.textured, 'mono' => Shade.silhouette, _ => null };

  /// The dancer style a shade means, the other way.
  static String? styleOfShade(Shade s) => switch (s) { Shade.textured => 'plain', Shade.silhouette => 'mono', _ => null };

  /// Whether a figure's clock may pick [style] (a dancer's art, a flock's look):
  /// switched on for that figure (`style.<figure>.<name>`), and by the older
  /// switch for every figure (`treatment.<name>`).
  bool styleOn(Figure kind, String style) => isOn('style.${kind.name}.$style') && isOn('treatment.$style');

  /// [style] switched on or off for [kind]'s clock (on clears the older switch too).
  ShowPool withStyle(Figure kind, String style, bool on) {
    final p = withOff('style.${kind.name}.$style', !on);
    return on ? p.withOff('treatment.$style', false) : p;
  }

  /// The treatment a style means, where its name is one.
  static Treatment? treatmentOfStyle(String? style) => style == null ? null : Treatment.values.where((t) => t != Treatment.auto && t.name == style).firstOrNull;

  /// [f] as the table looks it up: with the figure's own style of the moment
  /// (StylePool.now, what its clock chose) where the hands hold none, so a rule for
  /// the plain or the silhouette dancers, or the flock's ink, applies when it is on.
  static RigFigure lookupFigure(RigFigure f) {
    if (f.style != null) return f;
    final now = StylePool.now[f.kind];
    return now == null ? f : f.copyWith(style: now);
  }

  /// The way a pair with no rule blends: plainly on black, else the difference (the
  /// booth's way under MilkDrop, and safe on any ground: nothing is hidden).
  static const defaultMode = GroundMode.contrast;

  /// How a figure's own pixels go where its rule does not say: the plain dancers'
  /// skin and the words' letters over the ground as drawn, every other figure
  /// blended like its backdrop.
  static FigureMode figureModeFor(RigFigure f) =>
      f.kind == Figure.words || (f.kind == Figure.dancers && (f.style == 'plain' || f.shade == Shade.textured)) ? FigureMode.over : FigureMode.same;

  static String comboKey(RigFigure f, Ground g) => comboKeys(f, g).first;

  /// The treatments a word may hold for any scene (the image treatments: any scene
  /// can go through one, and the dancers and the flock have them as styles).
  static const anyTreatments = {Treatment.ascii, Treatment.dither, Treatment.halftone, Treatment.thermal, Treatment.lines, Treatment.contour};

  /// The key of a word for any scene through [t] on [g]: `treatment.<name>|ground.<g>`.
  static String treatmentKey(Treatment t, Ground g) => 'treatment.${t.name}|ground.${g.name}';

  // ---------------------------------------------------------------- characters and rules
  /// What [f] is like (its style's character, else its figure's), the hands' over
  /// the shipped; lights in the dark where nothing says.
  Character characterOf(RigFigure f) {
    final keys = [
      for (final k in comboKeys(f, Ground.black))
        if (k.contains('.style.')) k.split('|').first,
      figureKey(f.kind),
    ];
    for (final k in keys) {
      final mine = Character.values.where((c) => c.name == characters[k]).firstOrNull;
      if (mine != null) return mine;
      final shipped = shippedCharacters[k];
      if (shipped != null) return shipped;
    }
    return Character.lights;
  }

  /// The character a thing has by its key, and whether it is its own (not its
  /// figure's): for a card.
  (Character, bool own) characterOfKey(String key) {
    final mine = Character.values.where((c) => c.name == characters[key]).firstOrNull;
    if (mine != null) return (mine, true);
    final shipped = shippedCharacters[key];
    if (shipped != null) return (shipped, true);
    final parts = key.split('.');
    if (parts.length > 2) return (characterOfKey('${parts[0]}.${parts[1]}').$1, false);
    return (Character.lights, false);
  }

  /// What a background is like, the hands' over the shipped; none for black.
  Backdrop? backdropOf(Ground g) {
    if (g == Ground.black) return null;
    return Backdrop.values.where((b) => b.name == characters[groundKey(g)]).firstOrNull ?? shippedBackdrops[g] ?? Backdrop.busy;
  }

  /// The rule for [c] on [b], the hands' over the shipped, and whose.
  (ComboRule, bool mine) ruleOf(Character c, Backdrop b) {
    final k = ruleKey(c, b);
    final mine = rules[k];
    return mine != null ? (mine, true) : (shippedRules[k] ?? ComboRule.contrast, false);
  }

  /// What holds for [f] on [g], and why: on black, as drawn; else the hands'
  /// exception for the pair, the shipped exception, the hands' rule for the two
  /// characters, the shipped rule — the first that says.
  RuleAnswer answer(RigFigure f, Ground g) {
    final c = characterOf(f);
    final b = backdropOf(g);
    if (b == null) return RuleAnswer(rule: ComboRule.over, from: RuleFrom.black, character: c);
    final keys = comboKeys(f, g);
    var follow = false;
    for (final k in keys) {
      final mine = combos[k];
      if (mine == null) continue;
      if (mine.follow) {
        follow = true;
        break;
      }
      // A treatment's way for any scene: the way, where the scene goes on the
      // background at all (its never stands; the treatment's own never is never).
      if (!mine.off && k.startsWith('treatment.')) {
        final rest = withCombo(k, null).answer(f, g);
        if (rest.never) return rest;
      }
      return RuleAnswer(rule: mine, from: RuleFrom.yourException, character: c, backdrop: b, key: k);
    }
    if (!follow) {
      for (final k in keys) {
        final shipped = shippedExceptions[k];
        if (shipped != null) return RuleAnswer(rule: shipped, from: RuleFrom.exception, character: c, backdrop: b, key: k);
      }
    }
    final (rule, mine) = ruleOf(c, b);
    return RuleAnswer(rule: rule, from: mine ? RuleFrom.yourRule : RuleFrom.rule, character: c, backdrop: b, key: ruleKey(c, b));
  }

  /// The rule for [f] on [g] (see [answer]).
  ComboRule? ruleFor(RigFigure f, Ground g) => answer(f, g).rule;

  /// Whether [f] may go on [g] at all.
  bool together(RigFigure f, Ground g) => !answer(f, g).never && isOn('figure.${f.kind.name}') && isOn('ground.${g.name}');

  /// The blend for [f] on [g], with [from]'s strength: the answer's way (as drawn on
  /// black), and its figures' way or the figure's own ([figureModeFor]).
  RigBlend blendFor(RigFigure f, Ground g, {RigBlend from = RigBlend.over, int seed = 0}) {
    final a = answer(f, g);
    final r = a.rule;
    // A shipped rule has a few ways; the seed takes one (the pair's, the record's) of
    // those switched on. A way switched off is never used: the next that is on.
    final ways = a.from == RuleFrom.rule ? shippedWays[a.key]?.where(blendOn).toList() : null;
    final want = ways != null && ways.isNotEmpty ? ways[seed.abs() % ways.length] : (r.ground ?? defaultMode);
    final way = blendOn(want) ? want : anyWay.firstWhere(blendOn);
    return from.copyWith(
      ground: g == Ground.black || r.off ? GroundMode.over : way,
      figure: r.figure ?? figureModeFor(f),
      auto: true,
    );
  }

  /// Whether a way of blending may be used at all (the hands' switch, `blend.<mode>`):
  /// switched off it is gone everywhere — the rules, the cells, OTHER BLEND. As drawn
  /// is always on (a scene on black is drawn so).
  bool blendOn(GroundMode m) => m == GroundMode.over || isOn('blend.${m.name}');

  /// The ways tried, in turn, where the one asked for is switched off.
  static const anyWay = [GroundMode.contrast, GroundMode.screen, GroundMode.add, GroundMode.dim, GroundMode.window, GroundMode.mask, GroundMode.over];

  /// What holds for [f] on [g] without the hands' own word on the pair.
  RuleAnswer asShipped(RigFigure f, Ground g) => copyWith(combos: const {}).answer(f, g);

  /// [f] on [g] together or never, as the hands say: back to what holds without a
  /// word on this pair where that is what they ask (the shipped rules, or a word on
  /// the whole figure), else a word of their own — together the shipped way where the
  /// rules have one for it, as drawn for a page or a world, else the difference.
  ShowPool withTogether(RigFigure f, Ground g, bool together) {
    final key = comboKey(f, g);
    final base = withCombo(key, null).answer(f, g);
    if (base.never != together) return withCombo(key, null);
    if (!together) return withCombo(key, ComboRule.never);
    final shipped = asShipped(f, g);
    if (!shipped.never) {
      return withCombo(key, ComboRule(ground: shippedWays[shipped.key]?.first ?? shipped.rule.ground ?? defaultMode, figure: shipped.rule.figure));
    }
    final c = base.character;
    return withCombo(key, ComboRule(ground: c == Character.paper || c == Character.world ? GroundMode.over : GroundMode.contrast));
  }

  /// A figure and every one of its [styles] on [g], set whole (a branch of the rules'
  /// grid): never — one word on the figure, the styles' own words gone; together —
  /// those gone, and a word of its own for the figure and each style the rules would
  /// still keep off (the others keep their own ways).
  ShowPool withBranch(Figure kind, List<String> styles, Ground g, bool together) {
    final fig = RigFigure(kind: kind);
    var p = withCombo(comboKey(fig, g), null);
    for (final s in styles) {
      p = p.withCombo(comboKey(RigFigure(kind: kind, style: s), g), null);
    }
    if (!together) return p.withCombo(comboKey(fig, g), ComboRule.never);
    if (p.answer(fig, g).never) p = p.withTogether(fig, g, true);
    for (final s in styles) {
      final f = RigFigure(kind: kind, style: s);
      if (p.answer(f, g).never) p = p.withTogether(f, g, true);
    }
    return p;
  }

  /// The blends to step through for [f] on [g] (OTHER BLEND): the rule's own ways,
  /// then the others that suit any pair.
  List<GroundMode> blendsFor(RigFigure f, Ground g) {
    final a = asShipped(f, g);
    final cut = f.kind == Figure.dancers || f.kind == Figure.words;
    return <GroundMode>{
      ...?shippedWays[a.key],
      GroundMode.contrast,
      GroundMode.screen,
      GroundMode.add,
      GroundMode.dim,
      GroundMode.window,
      GroundMode.mask,
      if (cut) GroundMode.keyhole,
      GroundMode.over,
    }.where(blendOn).toList();
  }

  /// [f] on [g] blended as [m], the hands' (its figures as they go now).
  ShowPool withBlend(RigFigure f, Ground g, GroundMode m) {
    final now = answer(f, g).rule;
    return withCombo(comboKey(f, g), ComboRule(ground: m, figure: now.off ? null : now.figure));
  }

  /// [c] for the thing kept by [key] (a figure, a style, a background), or the
  /// shipped one again (null).
  ShowPool withCharacter(String key, String? c) => copyWith(
        characters: c == null ? {for (final e in characters.entries) if (e.key != key) e.key: e.value} : {...characters, key: c},
      );

  /// [rule] for a character on a background's, or the shipped one again (null).
  ShowPool withRule(Character c, Backdrop b, ComboRule? rule) {
    final k = ruleKey(c, b);
    return copyWith(rules: rule == null ? {for (final e in rules.entries) if (e.key != k) e.key: e.value} : {...rules, k: rule});
  }

  // ---------------------------------------------------------------- how often
  /// How often a thing comes on by itself, by its key: a scene's `look.<id>`, a
  /// style's `style.<figure>.<name>`, a background's `ground.<kind>`.
  Often oftenOf(String key) => !isOn(key) || (key.startsWith('style.') && !isOn('treatment.${key.split('.').last}')) ? Often.never : Often.ofLean(leanOf(key));

  ShowPool withOften(String key, Often o) {
    var p = withOff(key, o == Often.never);
    if (key.startsWith('style.') && o != Often.never) p = p.withOff('treatment.${key.split('.').last}', false);
    if (o == Often.never) return p;
    return o == Often.normal ? p.copyWith(lean: {for (final e in p.lean.entries) if (e.key != key) e.key: e.value}) : p.withLean(key, o.lean);
  }

  /// One of [items] by [d] (0..1), each as likely as its weight (none at 0).
  static T? pickWeighted<T>(List<T> items, double d, double Function(T) weight) {
    var total = 0.0;
    for (final i in items) {
      total += weight(i);
    }
    if (total <= 0) return items.isEmpty ? null : items[(d * items.length).floor() % items.length];
    var x = d * total;
    for (final i in items) {
      x -= weight(i);
      if (x < 0) return i;
    }
    return items.last;
  }

  /// The values switched off to start with: the topographic map read as terrain,
  /// not a dancer.
  static const shippedOff = {'treatment.contour'};

  // ---------------------------------------------------------------- json
  Map<String, dynamic> toJson() => {
        if (off.isNotEmpty) 'off': off.toList()..sort(),
        if (lean.isNotEmpty) 'lean': lean,
        if (combos.isNotEmpty) 'combos': {for (final e in combos.entries) e.key: e.value.toJson()},
        if (characters.isNotEmpty) 'characters': characters,
        if (rules.isNotEmpty) 'rules': {for (final e in rules.entries) e.key: e.value.toJson()},
        if (dancer != null) 'dancer': dancer,
        if (quantise != Quantise.bar) 'quantise': quantise.name,
        if (bias != 0) 'bias': bias,
        if (tier != 'auto') 'tier': tier,
        if (darkBeat) 'darkBeat': true,
        if (tune.isNotEmpty) 'tune': tune,
        if (treat.isNotEmpty) 'treat': treat,
        if (mixes.isNotEmpty) 'mixes': mixes,
      };

  factory ShowPool.fromJson(Map<String, dynamic> j) => ShowPool(
        off: {for (final k in (j['off'] as List? ?? const [])) '$k'},
        lean: j['lean'] is Map
            ? {
                for (final e in (j['lean'] as Map).entries)
                  if (e.value is num) '${e.key}': (e.value as num).toDouble()
              }
            : const {},
        combos: j['combos'] is Map
            ? {
                for (final e in (j['combos'] as Map).entries)
                  if (e.value is Map) '${e.key}': ComboRule.fromJson((e.value as Map).cast())
              }
            : const {},
        characters: j['characters'] is Map
            ? {
                for (final e in (j['characters'] as Map).entries)
                  if (e.value is String) '${e.key}': e.value as String
              }
            : const {},
        rules: j['rules'] is Map
            ? {
                for (final e in (j['rules'] as Map).entries)
                  if (e.value is Map) '${e.key}': ComboRule.fromJson((e.value as Map).cast())
              }
            : const {},
        dancer: j['dancer'] as String?,
        quantise: Quantise.values.where((q) => q.name == j['quantise']).firstOrNull ?? Quantise.bar,
        bias: j['bias'] is num ? (j['bias'] as num).toDouble().clamp(-1.0, 1.0) : 0,
        tier: const ['auto', 'low', 'mid', 'high'].contains(j['tier']) ? '${j['tier']}' : 'auto',
        darkBeat: j['darkBeat'] == true,
        tune: j['tune'] is Map ? {for (final e in (j['tune'] as Map).entries) if (e.value is num) '${e.key}': (e.value as num).toDouble()} : const {},
        treat: j['treat'] is Map ? {for (final e in (j['treat'] as Map).entries) if (e.value is String) '${e.key}': e.value as String} : const {},
        mixes: j['mixes'] is Map
            ? {for (final e in (j['mixes'] as Map).entries) if (e.value is List) '${e.key}': [for (final v in e.value as List) '$v']}
            : const {},
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
    favourites = {
      for (final e in pool.lean.entries)
        if (e.key.startsWith('move.') && e.value > 1.5) e.key.substring(5)
    };
  }
}

/// What the dancers' and the birds' clocks read of the pool: the styles (treatments,
/// looks) switched off, by name, and whether the rules let a style stand on the
/// ground on now ([allows]). Set by the engine as the pool and the ground change. And
/// the way back: a figure's clock says which style it has on ([now]), so the table's
/// rules for one look of theirs apply (ShowPool.lookupFigure).
class StylePool {
  const StylePool._();
  static Set<String> off = const {};

  /// The ground under the figure on now (the engine's, each frame).
  static Ground ground = Ground.black;

  /// The rules the clocks ask ([allows]); the engine's pool.
  static ShowPool pool = ShowPool.none;

  /// Each figure's style of the moment, by name (`plain`, `mono`, `ascii`, `ink`…),
  /// as its clock chose it; absent where none is known.
  static final Map<Figure, String> now = {};

  static void from(ShowPool p) {
    off = p.offOf('treatment').toSet();
    pool = p;
  }

  /// Whether a figure's clock may put [style] on now: not switched off, and not a
  /// pair the rules call never with the ground on.
  static bool allows(Figure kind, String style) => pool.styleOn(kind, style) && !off.contains(style);

  /// How much a figure's clock leans on [style]: how often (rarely, normal, often),
  /// and less where the rules keep it off the ground on now (it is still picked now
  /// and then — then the stage puts it on another background).
  static double weight(Figure kind, String style) =>
      pool.leanOf('style.${kind.name}.$style') * (pool.answer(RigFigure(kind: kind, style: style), ground).never ? 0.3 : 1);
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
