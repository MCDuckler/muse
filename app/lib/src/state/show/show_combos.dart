// What the show puts on, as a combination of five: a background, a scene, the
// scene's style, a mask and a blend — picked like a kart, a body and wheels.
//
//   background  black, white, MilkDrop, the wash, the pulse's four, the drift field,
//               the cover, the camera;
//   scene       a look (the dancers, the birds, the shapes…), by its id;
//   style       the scene's own styles (a dancer's art, a flock's look, a face of the
//               words), else the scene as drawn (`raw`) or through a treatment;
//   mask        none; a keyhole (the background only inside the figure); or the
//               keyhole inverted (the background only round it, the figure cut out);
//   blend       normal (the figure over the background), add, screen, contrast.
//
// And a sixth, the camera, for the scenes that have one (the dancers, the flock):
// not a part of a combination — the camera cuts many times while one is on — but a
// rule may name some of its framings (`shots`), and the figure's clock weighs its
// next framing by them at every cut (shotWeight). A camera rule never says how often
// a combination comes; it says how the dancers or the birds are shot while it is on.
//
// Every combination is in the rotation, at weight 1, unless a rule says otherwise. A
// rule is a pattern — any of the five set, the rest "any" — and a weight (0 is off). A
// rule with one thing set is that thing's card weight (how often MilkDrop, how often
// the keyhole): all the cards a combination is made of multiply. A rule with two or
// more set is an exception: the most particular one that matches says the rest of the
// weight (the one that says the most; of those, the narrowest; a tie, the later). A
// pattern may name a few things of one row ("add or screen"): a batch, one rule. The rules that came with the app come first; the hands'
// after them, and one of theirs for the same pattern takes its place.
//
// A scene or a style that is a world of its own (MilkDrop alone, the dormouse, the disco
// floor, the viewports, the sky) has one combination: on its own background, unmasked,
// as drawn — weighed by its scene and its style only (a rule naming a background, a
// mask or a blend is not about it).
//
// Plan: ~/.claude/plans/wetowl-show-combos.md.
import 'show_rig.dart';

enum Mask { none, keyhole, inverted }

enum Mix { normal, add, screen, contrast }

/// The backgrounds, by key: a ground's kind, and its variant after a dot.
const comboGrounds = ['black', 'white', 'milk', 'wash', 'pulse.grid', 'pulse.rays', 'pulse.smoke', 'pulse.stars', 'field.drift', 'cover', 'camera'];

/// The background of a world: its own.
const ownGround = 'own';

/// The ground a background's key means (with the dim it has always had).
RigGround groundOfKey(String key) {
  final dot = key.indexOf('.');
  final kind = dot < 0 ? key : key.substring(0, dot);
  final field = dot < 0 ? null : key.substring(dot + 1);
  return switch (kind) {
    'white' => const RigGround(kind: Ground.white),
    'milk' => RigGround.milk,
    'wash' => const RigGround(kind: Ground.wash),
    'pulse' => RigGround(kind: Ground.pulse, field: field ?? 'grid'),
    'field' => RigGround(kind: Ground.field, field: field ?? 'drift', dim: 0.6),
    'cover' => const RigGround(kind: Ground.cover, dim: 0.6),
    'camera' => const RigGround(kind: Ground.camera, dim: 0.8),
    _ => RigGround.black,
  };
}

/// A ground's key, the other way.
String keyOfGround(RigGround g) => switch (g.kind) {
      Ground.pulse => 'pulse.${g.field ?? 'grid'}',
      Ground.field => 'field.${g.field ?? 'drift'}',
      _ => g.kind.name,
    };

/// The image treatments any scene may go through (dance_fx.frag's), as styles.
const treatmentStyles = ['ascii', 'dither', 'halftone', 'thermal', 'lines', 'contour'];

/// The styles of a figure, by name: its own where it has them (kept in step with
/// show_dance.dart's DanceArt, show_flock.dart's FlockLook, show_words.dart's
/// WordsStyle — a test says so), else the scene as drawn and the treatments.
List<String> stylesOfFigure(Figure f) => switch (f) {
      Figure.dancers => const ['plain', 'mono', 'trails', 'ascii', 'dither', 'chrono', 'contour', 'halftone', 'thermal', 'lines', 'fluid', 'viewports', 'disco'],
      Figure.birds => const ['ink', 'sky', 'embers', 'neon', 'wire', 'chrono', 'ascii', 'dither', 'contour', 'halftone', 'thermal', 'lines', 'radar'],
      Figure.words => const ['poster', 'serif', 'grotesk', 'wide', 'mono', 'marker', 'light'],
      Figure.none || Figure.meme => const ['raw'],
      _ => const ['raw', ...treatmentStyles],
    };

/// Whether a figure's style is its own drawing (the figure lit and drawn for it), not
/// a treatment over the frame.
bool ownStyle(Figure f) => f == Figure.dancers || f == Figure.birds || f == Figure.words;

/// The scenes that are a world of their own, whatever the style.
const worldScenes = {'milk', 'siebenschlaefer'};

/// The styles that are a world of their own, by `figure.style`.
const worldStyles = {'dancers.disco', 'dancers.viewports', 'birds.sky'};

bool isWorld(String scene, Figure kind, String style) => worldScenes.contains(scene) || kind == Figure.none || worldStyles.contains('${kind.name}.$style');

/// One combination.
class Combo {
  const Combo({required this.ground, required this.scene, required this.style, this.mask = Mask.none, this.mix = Mix.normal});

  final String ground, scene, style;
  final Mask mask;
  final Mix mix;

  bool get world => ground == ownGround;

  String get key => '$ground|$scene|$style|${mask.name}|${mix.name}';

  static Combo? fromKey(String key) {
    final p = key.split('|');
    if (p.length != 5) return null;
    final mask = Mask.values.asNameMap()[p[3]], mix = Mix.values.asNameMap()[p[4]];
    if (mask == null || mix == null) return null;
    return Combo(ground: p[0], scene: p[1], style: p[2], mask: mask, mix: mix);
  }

  Combo copyWith({String? ground, String? scene, String? style, Mask? mask, Mix? mix}) =>
      Combo(ground: ground ?? this.ground, scene: scene ?? this.scene, style: style ?? this.style, mask: mask ?? this.mask, mix: mix ?? this.mix);

  @override
  bool operator ==(Object other) => other is Combo && other.key == key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => key;
}

/// The five things a combination is made of, as the rows of the selector; and the
/// camera (not a combination's: its clock's, cut by cut).
enum ComboAxis { scene, style, ground, mask, mix, shot }

/// A combination's value on [a], by name (a mask's, a blend's); a combination has no
/// camera of its own (an empty name).
String comboValue(Combo c, ComboAxis a) => switch (a) {
      ComboAxis.ground => c.ground,
      ComboAxis.scene => c.scene,
      ComboAxis.style => c.style,
      ComboAxis.mask => c.mask.name,
      ComboAxis.mix => c.mix.name,
      ComboAxis.shot => '',
    };

/// The framings of a figure's camera, by key (`dancers.fisheye`, `birds.fish`): kept
/// in step with show_dance.dart's DanceShot (but `full`, drawn as `front` on the
/// stylised stage) and show_flock.dart's FlockShot — a test says so.
List<String> shotsOfFigure(Figure f) => switch (f) {
      Figure.dancers => const [
          'dancers.front',
          'dancers.medium',
          'dancers.close',
          'dancers.wide',
          'dancers.extremeLow',
          'dancers.extremeHigh',
          'dancers.extremeFront',
          'dancers.fisheye',
          'dancers.fisheyeLow',
        ],
      Figure.birds => const ['birds.wide', 'birds.front', 'birds.low', 'birds.high', 'birds.fish', 'birds.fishLow'],
      _ => const [],
    };

/// Every framing there is.
final allShots = [...shotsOfFigure(Figure.dancers), ...shotsOfFigure(Figure.birds)];

/// A pattern and its weight: each of the five one or more things (any of them), or
/// any at all (null) — "the turntable, any style, any background, the keyhole, added
/// or screened".
class ComboRule {
  const ComboRule({this.grounds, this.scenes, this.styles, this.masks, this.mixes, this.shots, this.weight = 1});

  final Set<String>? grounds, scenes, styles;

  /// The camera's framings it is about, by key; null: not a camera rule.
  final Set<String>? shots;
  final Set<Mask>? masks;
  final Set<Mix>? mixes;

  /// How likely, against 1; 0 is never.
  final double weight;

  bool get off => weight <= 0;

  /// A rule of the camera's: how a figure is shot, not how often a combination comes.
  bool get camera => shots != null;

  /// What it says of [a], by name; null is any.
  Set<String>? on(ComboAxis a) => switch (a) {
        ComboAxis.ground => grounds,
        ComboAxis.scene => scenes,
        ComboAxis.style => styles,
        ComboAxis.mask => masks?.map((m) => m.name).toSet(),
        ComboAxis.mix => mixes?.map((m) => m.name).toSet(),
        ComboAxis.shot => shots,
      };

  /// [a] said again: [names] (a mask's, a blend's by name), none or null for any.
  ComboRule withOn(ComboAxis a, Set<String>? names) {
    final n = names == null || names.isEmpty ? null : names;
    Set<T>? enums<T extends Enum>(List<T> all) {
      if (n == null) return null;
      final s = {for (final v in all) if (n.contains(v.name)) v};
      return s.isEmpty ? null : s;
    }

    return ComboRule(
      grounds: a == ComboAxis.ground ? n : grounds,
      scenes: a == ComboAxis.scene ? n : scenes,
      styles: a == ComboAxis.style ? n : styles,
      masks: a == ComboAxis.mask ? enums(Mask.values) : masks,
      mixes: a == ComboAxis.mix ? enums(Mix.values) : mixes,
      shots: a == ComboAxis.shot ? n : shots,
      weight: weight,
    );
  }

  /// How many of the six it says.
  int get fields => ComboAxis.values.where((a) => on(a) != null).length;

  /// How many ways it may be within what it says (one thing each: 1): of two
  /// exceptions that say as much, the narrower is the more particular.
  int get breadth {
    var b = 1;
    for (final a in ComboAxis.values) {
      b *= on(a)?.length ?? 1;
    }
    return b;
  }

  /// One thing alone (or a few of one row): its card's weight.
  bool get card => fields == 1;

  /// Every one of the five a single thing: one combination's own rule (the camera
  /// aside).
  bool get single => ComboAxis.values.where((a) => a != ComboAxis.shot).every((a) => on(a)?.length == 1);

  bool matches(Combo c) =>
      (grounds == null || grounds!.contains(c.ground)) &&
      (scenes == null || scenes!.contains(c.scene)) &&
      (styles == null || styles!.contains(c.style)) &&
      (masks == null || masks!.contains(c.mask)) &&
      (mixes == null || mixes!.contains(c.mix));

  /// The pattern alone, `*` for any and the things of a row in their order (the
  /// camera's after, where it says some): what a rule of the hands' replaces.
  String get pattern => [
        ComboAxis.ground,
        ComboAxis.scene,
        ComboAxis.style,
        ComboAxis.mask,
        ComboAxis.mix,
        if (shots != null) ComboAxis.shot,
      ].map((a) => _names(a)?.join(',') ?? '*').join('|');

  /// What it says of [a] in order (a mask's and a blend's as they come, the rest by
  /// name).
  List<String>? _names(ComboAxis a) => switch (a) {
        ComboAxis.mask => masks == null ? null : [for (final m in Mask.values) if (masks!.contains(m)) m.name],
        ComboAxis.mix => mixes == null ? null : [for (final m in Mix.values) if (mixes!.contains(m)) m.name],
        _ => on(a)?.toList()?..sort(),
      };

  ComboRule withWeight(double w) => ComboRule(grounds: grounds, scenes: scenes, styles: styles, masks: masks, mixes: mixes, shots: shots, weight: w);

  static const _keys = {
    ComboAxis.ground: 'ground',
    ComboAxis.scene: 'scene',
    ComboAxis.style: 'style',
    ComboAxis.mask: 'mask',
    ComboAxis.mix: 'mix',
    ComboAxis.shot: 'shot',
  };

  /// One thing as a word, a few as a list.
  Map<String, dynamic> toJson() => {
        for (final e in _keys.entries)
          if (_names(e.key) case final n?) e.value: n.length == 1 ? n.first : n,
        'weight': weight,
      };

  static ComboRule? fromJson(Object? j) {
    if (j is! Map) return null;
    final w = j['weight'];
    var r = ComboRule(weight: w is num ? w.toDouble().clamp(0.0, 10.0) : 1);
    for (final e in _keys.entries) {
      final v = j[e.value];
      final names = v is String ? {v} : (v is List ? {for (final x in v) if (x is String) x} : null);
      r = r.withOn(e.key, names);
    }
    return r.fields == 0 ? null : r;
  }

  @override
  bool operator ==(Object other) => other is ComboRule && other.pattern == pattern && other.weight == weight;
  @override
  int get hashCode => Object.hash(pattern, weight);
  @override
  String toString() => '$pattern ×$weight';
}

/// The rules that came with the app: the cards' weights (MilkDrop most of the time —
/// the booth's way — the difference as the blend it reaches for first, a mask now and
/// then), and the combinations that would show nothing or the same picture twice.
const shippedComboRules = <ComboRule>[
  // The backgrounds.
  ComboRule(grounds: {'milk'}, weight: 3),
  ComboRule(grounds: {'white'}, weight: 0.8),
  ComboRule(grounds: {'pulse.grid'}, weight: 0.5),
  ComboRule(grounds: {'pulse.rays'}, weight: 0.5),
  ComboRule(grounds: {'pulse.smoke'}, weight: 0.5),
  ComboRule(grounds: {'pulse.stars'}, weight: 0.5),
  ComboRule(grounds: {'field.drift'}, weight: 0.6),
  ComboRule(grounds: {'cover'}, weight: 0.6),
  // The masks and the blends.
  ComboRule(masks: {Mask.none}, weight: 2),
  ComboRule(masks: {Mask.keyhole}, weight: 0.6),
  ComboRule(masks: {Mask.inverted}, weight: 0.6),
  ComboRule(mixes: {Mix.contrast}, weight: 1.5),
  ComboRule(mixes: {Mix.screen}, weight: 0.7),
  // The topographic map reads as terrain, not as the scene.
  ComboRule(styles: {'contour'}, weight: 0),
  // On black a mask leaves nothing, and every blend is the normal one.
  ComboRule(grounds: {'black'}, masks: {Mask.keyhole}, weight: 0),
  ComboRule(grounds: {'black'}, masks: {Mask.inverted}, weight: 0),
  ComboRule(grounds: {'black'}, mixes: {Mix.add}, weight: 0),
  ComboRule(grounds: {'black'}, mixes: {Mix.screen}, weight: 0),
  ComboRule(grounds: {'black'}, mixes: {Mix.contrast}, weight: 0),
  // Added or screened onto white, everything is white.
  ComboRule(grounds: {'white'}, mixes: {Mix.add}, weight: 0),
  ComboRule(grounds: {'white'}, mixes: {Mix.screen}, weight: 0),
];

/// The weight of [c] by [rules] (the shipped ones first, the hands' after): the
/// cards it is made of multiplied, times the most particular exception that matches.
double comboWeight(Combo c, List<ComboRule> rules) => explainWeight(c, rules).weight;

/// [comboWeight], and which rules made it: the cards that matched and the exception.
({double weight, List<ComboRule> cards, ComboRule? exception}) explainWeight(Combo c, List<ComboRule> rules) {
  final cards = <String, ComboRule>{};
  ComboRule? best;
  for (final r in rules) {
    if (r.camera || !r.matches(c)) continue;
    // A world has no background, mask or blend to weigh: "no mask ×2" is not for it.
    if (c.world && (r.grounds != null || r.masks != null || r.mixes != null)) continue;
    if (r.card) {
      cards[r.pattern] = r;
    } else if (best == null || r.fields > best.fields || (r.fields == best.fields && r.breadth <= best.breadth)) {
      best = r;
    }
  }
  var w = 1.0;
  for (final r in cards.values) {
    w *= r.weight;
  }
  if (best != null) w *= best.weight;
  return (weight: w, cards: cards.values.toList(), exception: best);
}

/// How much a figure's clock leans on the framing [shot] while [c] is on (null: on
/// whatever is on — the camera's cards alone): the camera cards that name it
/// multiplied, times the most particular camera exception that matches [c] and names
/// it. 1 where nothing says.
double shotWeight(Combo? c, String shot, List<ComboRule> rules) {
  final cards = <String, double>{};
  ComboRule? best;
  for (final r in rules) {
    final s = r.shots;
    if (s == null || !s.contains(shot)) continue;
    if (r.card) {
      cards[r.pattern] = r.weight;
      continue;
    }
    if (c == null || !r.matches(c)) continue;
    if (c.world && (r.grounds != null || r.masks != null || r.mixes != null)) continue;
    if (best == null || r.fields > best.fields || (r.fields == best.fields && r.breadth <= best.breadth)) best = r;
  }
  var w = 1.0;
  for (final x in cards.values) {
    w *= x;
  }
  return best == null ? w : w * best.weight;
}

/// The combinations of one scene ([kind] its figure): every background, style, mask
/// and blend — or, for a world, one per style. [grounds] narrows the backgrounds (to
/// the ones here now).
List<Combo> combosOf(String scene, Figure kind, {Iterable<String> grounds = comboGrounds}) {
  final out = <Combo>[];
  for (final style in stylesOfFigure(kind)) {
    if (isWorld(scene, kind, style)) {
      out.add(Combo(ground: ownGround, scene: scene, style: style));
      continue;
    }
    for (final g in grounds) {
      for (final m in Mask.values) {
        for (final x in Mix.values) {
          out.add(Combo(ground: g, scene: scene, style: style, mask: m, mix: x));
        }
      }
    }
  }
  return out;
}

/// One of [items] by [d] (0..1), each as likely as its weight; null where none weighs.
T? pickByWeight<T>(List<(T, double)> items, double d) {
  var total = 0.0;
  for (final (_, w) in items) {
    if (w > 0) total += w;
  }
  if (total <= 0) return null;
  var x = d * total;
  for (final (i, w) in items) {
    if (w <= 0) continue;
    x -= w;
    if (x < 0) return i;
  }
  return items.lastWhere((i) => i.$2 > 0).$1;
}
