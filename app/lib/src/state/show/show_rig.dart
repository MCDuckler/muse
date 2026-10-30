// The rig: what the stage draws, as layers — the ground under everything, the
// figure in the middle with its own ways of being rendered, how the figure sits on
// the ground (the blend), and the finish over both. A scene used to be one thing; a
// rig is these four put together, so the same figure goes over any ground in any
// blend, and a look is a rig written down with a name.
//
// Plan: ~/.claude/plans/wetowl-show-layers.md, §1. This is the model only: what a
// frame carries (ShowState.rig), what a look file says, what the panel edits. The
// stages read it (the Flutter one in ui/show/show_canvas.dart, the native one
// through ui/show/native_stage.dart); nothing here draws.
import 'show_combos.dart';
import 'show_director.dart' show SceneMeta;

export 'show_combos.dart' show Mask, Mix;

/// What lies under the figure.
enum Ground {
  /// Nothing: black.
  black,

  /// A slow two-colour gradient from the record's palette.
  wash,

  /// MilkDrop, its preset director's.
  milk,

  /// The room's camera, through a treatment of its own (RigGround.treatment).
  camera,

  /// A shader or a simulation as a quiet backdrop (RigGround.field says which).
  field,

  /// The record's cover, blurred, with a slow parallax.
  cover,

  /// A dark, structured, band-driven field: the quiet one (RigGround.field says
  /// which of its variants).
  pulse,

  /// White: the page the plain dancers and the silhouettes stand on.
  white,
}

/// What stands in the middle. [none] is a look that is its own whole picture
/// (MilkDrop alone); [field] a shader drawn whole (drift), [room] the camera through
/// a shader (echo, fold) — both blended with the ground like any figure.
enum Figure { none, dancers, birds, kinetic, blocks, flash, glide, turntable, fluid, veins, meme, words, field, room, type3d }

/// How a 3D figure's surface is shaded. [auto] is the figure's own clock choosing
/// from the pool, as it does today.
enum Shade { auto, textured, chrome, silhouette, flat, toon }

/// What the figure stands in: the dancers' stage dressings, the birds' sky.
enum Dressing { auto, none, disco, neon, shadow, studio, sky }

/// An image-space rendering of the figure, any figure.
enum Treatment { auto, raw, ascii, dither, halftone, thermal, lines, contour, chrono, trails, fluid, viewports, radar, crt, slit }

/// When a change the hands ask for lands.
enum Quantise { now, beat, bar, phrase }

T _enumOf<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

double _d(Object? v, double or) => v is num ? v.toDouble() : or;

Map<String, double> _knobs(Object? j) => j is Map
    ? {
        for (final e in j.entries)
          if (e.value is num) '${e.key}': (e.value as num).toDouble()
      }
    : const {};

/// The pulse field's variants (shaders/show/pulse.frag, by uM1), by name.
const pulseVariants = ['grid', 'rays', 'smoke', 'stars'];
int pulseVariant(String? name) {
  final i = pulseVariants.indexOf(name ?? 'grid');
  return i < 0 ? 0 : i;
}

class RigGround {
  const RigGround({this.kind = Ground.black, this.field, this.dim = 1, this.knobs = const {}});

  final Ground kind;

  /// For [Ground.field]: the shader or simulation drawn (`drift`, `glide`, `fluid`,
  /// `veins`…); for [Ground.pulse]: its variant (`grid`, `rays`, `smoke`, `stars`).
  final String? field;

  /// How much of it, 0..1.
  final double dim;

  /// uM1..uM4 for a field's shader.
  final Map<String, double> knobs;

  static const black = RigGround();
  static const milk = RigGround(kind: Ground.milk);

  /// A word for a chip or a line: `milk`, `field drift`, `camera echo`.
  String get label => switch (kind) {
        Ground.field => 'field ${field ?? '?'}',
        Ground.pulse => 'pulse ${field ?? 'grid'}',
        _ => kind.name,
      };

  RigGround copyWith({Ground? kind, String? field, double? dim, Map<String, double>? knobs}) => RigGround(
        kind: kind ?? this.kind,
        field: field ?? this.field,
        dim: dim ?? this.dim,
        knobs: knobs ?? this.knobs,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (field != null) 'field': field,
        if (dim != 1) 'dim': dim,
        if (knobs.isNotEmpty) 'knobs': knobs,
      };

  factory RigGround.fromJson(Map<String, dynamic> j) => RigGround(
        kind: _enumOf(Ground.values, j['kind'], Ground.black),
        field: j['field'] as String?,
        dim: _d(j['dim'], 1).clamp(0.0, 1.0),
        knobs: _knobs(j['knobs']),
      );

  @override
  bool operator ==(Object other) => other is RigGround && other.kind == kind && other.field == field && other.dim == dim && _sameKnobs(other.knobs, knobs);
  @override
  int get hashCode => Object.hash(kind, field, dim, knobs.length);
}

bool _sameKnobs(Map<String, double> a, Map<String, double> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

class RigFigure {
  const RigFigure({
    this.kind = Figure.none,
    this.shade = Shade.auto,
    this.dressing = Dressing.auto,
    this.treatment = Treatment.auto,
    this.style,
    this.knobs = const {},
  });

  final Figure kind;
  final Shade shade;
  final Dressing dressing;
  final Treatment treatment;

  /// The figure's own named look, where it has more than the axes say — a dancer's
  /// art (`ascii`, `chrono`, `plain`…), a flock's look (`embers`, `radar`…) — held by
  /// the hands; null is the figure's own clock choosing.
  final String? style;

  /// uM1..uM4 for a shader figure.
  final Map<String, double> knobs;

  static const none = RigFigure();

  /// Bodies in a space: a shade and a camera mean something.
  bool get is3d => kind == Figure.dancers || kind == Figure.birds || kind == Figure.turntable;

  /// One shader drawing the whole picture (shaders/show/`<kind>`.frag).
  bool get isShader => kind == Figure.kinetic || kind == Figure.blocks || kind == Figure.flash || kind == Figure.glide;

  /// A simulation (ui/show/show_sims.dart's kinds): the picture it keeps between frames.
  bool get isSim =>
      kind == Figure.dancers ||
      kind == Figure.birds ||
      kind == Figure.turntable ||
      kind == Figure.fluid ||
      kind == Figure.veins ||
      kind == Figure.meme ||
      kind == Figure.words ||
      kind == Figure.type3d;

  /// A word for a chip or a line: `dancers`, `dancers chrome ascii`, `kinetic`.
  String get label => [
        kind.name,
        if (style != null) style!,
        if (shade != Shade.auto) shade.name,
        if (dressing != Dressing.auto) dressing.name,
        if (treatment != Treatment.auto) treatment.name,
      ].join(' ');

  RigFigure copyWith(
          {Figure? kind, Shade? shade, Dressing? dressing, Treatment? treatment, String? style, bool clearStyle = false, Map<String, double>? knobs}) =>
      RigFigure(
        kind: kind ?? this.kind,
        shade: shade ?? this.shade,
        dressing: dressing ?? this.dressing,
        treatment: treatment ?? this.treatment,
        style: clearStyle ? null : style ?? this.style,
        knobs: knobs ?? this.knobs,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (shade != Shade.auto) 'shade': shade.name,
        if (dressing != Dressing.auto) 'dressing': dressing.name,
        if (treatment != Treatment.auto) 'treatment': treatment.name,
        if (style != null) 'style': style,
        if (knobs.isNotEmpty) 'knobs': knobs,
      };

  factory RigFigure.fromJson(Map<String, dynamic> j) => RigFigure(
        kind: _enumOf(Figure.values, j['kind'], Figure.none),
        shade: _enumOf(Shade.values, j['shade'], Shade.auto),
        dressing: _enumOf(Dressing.values, j['dressing'], Dressing.auto),
        treatment: _enumOf(Treatment.values, j['treatment'], Treatment.auto),
        style: j['style'] as String?,
        knobs: _knobs(j['knobs']),
      );

  @override
  bool operator ==(Object other) =>
      other is RigFigure &&
      other.kind == kind &&
      other.shade == shade &&
      other.dressing == dressing &&
      other.treatment == treatment &&
      other.style == style &&
      _sameKnobs(other.knobs, knobs);
  @override
  int get hashCode => Object.hash(kind, shade, dressing, treatment, style, knobs.length);
}

/// How the figure goes onto the ground (show_combos.dart; shaders/show/under.frag):
/// the mask (where the ground shows) and the blend (how the two meet).
class RigBlend {
  const RigBlend({this.mask = Mask.none, this.mix = Mix.normal, this.strength = 1});

  final Mask mask;
  final Mix mix;

  /// How much of the blend, 0..1 (0 is the figure layer as drawn).
  final double strength;

  static const normal = RigBlend();

  /// Nothing of a black ground would change the figure: drawn as it is.
  bool get plain => mask == Mask.none && mix == Mix.normal;

  String get label => [if (mask != Mask.none) mask.name, mix.name].join(' · ');

  RigBlend copyWith({Mask? mask, Mix? mix, double? strength}) => RigBlend(mask: mask ?? this.mask, mix: mix ?? this.mix, strength: strength ?? this.strength);

  Map<String, dynamic> toJson() => {
        'mask': mask.name,
        'mix': mix.name,
        if (strength != 1) 'strength': strength,
      };

  factory RigBlend.fromJson(Map<String, dynamic> j) => RigBlend(
        mask: _enumOf(Mask.values, j['mask'], Mask.none),
        mix: _enumOf(Mix.values, j['mix'], Mix.normal),
        strength: _d(j['strength'], 1).clamp(0.0, 1.0),
      );

  @override
  bool operator ==(Object other) => other is RigBlend && other.mask == mask && other.mix == mix && other.strength == strength;
  @override
  int get hashCode => Object.hash(mask, mix, strength);
}

/// The transformation, between the figure as it draws itself and its style (the
/// style goes over what it makes): what is on this frame.
///
///  * the slit-scan ([slit]): each part of the picture from a frame further back
///    (the native stage's, native/stage/src/fx.h; its knobs the `slit` treatment's);
///  * then the kaleidoscope: [count] mirrors through the middle (0: none) cutting the
///    stage into twice as many wedges, the one the figure lights most reflected into
///    all the others and cut off at their edges, as big as the original — under the
///    original, which stays whole on top wherever it draws anything (shaders/show/
///    ghosts.frag). [turn] turns the mirrors (0..1: up to half a turn; 2 mirrors at 0
///    are one horizontal and one vertical), [line] how much of their edges is drawn,
///    [differ] how far the reflections' light and colour are from the original's;
///  * or the datamosh held ([mosh]), over the whole picture as finished (fx.h, driven
///    by mosh_clock.dart): [grain] how blocky (a melt .. a codec's grain), [melt] how
///    long its smears hold, [keys] how often the picture is let through again.
class RigTransform {
  const RigTransform(
      {this.count = 0,
      this.differ = 0.5,
      this.slit = false,
      this.turn = 0,
      this.line = 0,
      this.blend = Mix.normal,
      this.amount = 1,
      this.mosh = false,
      this.grain = 0.7,
      this.melt = 0.5,
      this.keys = 0.5});

  final int count;
  final double differ, turn, line;
  final bool slit, mosh;
  final double grain, melt, keys;

  /// How the reflections meet the original (normal: the original whole on top; add,
  /// screen, contrast as the combinations' blends), and how much of them.
  final Mix blend;
  final double amount;

  static const none = RigTransform();

  /// The most mirrors there may be.
  static const most = 6;

  /// The kaleidoscope on.
  bool get on => count >= 1;

  /// Anything of it on.
  bool get any => on || slit || mosh;

  /// What of it goes between the figure and its style (the kaleidoscope, the
  /// slit-scan); the datamosh goes over the whole picture, after everything.
  bool get beforeStyle => on || slit;

  /// The mirrors' turn, in radians (up to half a turn).
  double get turnRadians => turn * 3.14159265;

  RigTransform copyWith(
          {int? count, double? differ, bool? slit, double? turn, double? line, Mix? blend, double? amount, bool? mosh, double? grain, double? melt, double? keys}) =>
      RigTransform(
          count: count ?? this.count,
          differ: differ ?? this.differ,
          slit: slit ?? this.slit,
          turn: turn ?? this.turn,
          line: line ?? this.line,
          blend: blend ?? this.blend,
          amount: amount ?? this.amount,
          mosh: mosh ?? this.mosh,
          grain: grain ?? this.grain,
          melt: melt ?? this.melt,
          keys: keys ?? this.keys);

  Map<String, dynamic> toJson() => {
        'count': count,
        'differ': differ,
        if (slit) 'slit': true,
        if (turn != 0) 'turn': turn,
        if (line != 0) 'line': line,
        if (blend != Mix.normal) 'blend': blend.name,
        if (amount != 1) 'amount': amount,
        if (mosh) 'mosh': true,
        if (grain != 0.7) 'grain': grain,
        if (melt != 0.5) 'melt': melt,
        if (keys != 0.5) 'keys': keys,
      };

  factory RigTransform.fromJson(Object? j) => j is Map
      ? RigTransform(
          count: (j['count'] is num ? (j['count'] as num).round() : 0).clamp(0, most),
          differ: _d(j['differ'], 0.5).clamp(0.0, 1.0),
          slit: j['slit'] == true,
          turn: _d(j['turn'], 0).clamp(0.0, 1.0),
          line: _d(j['line'], 0).clamp(0.0, 1.0),
          blend: _enumOf(Mix.values, j['blend'], Mix.normal),
          amount: _d(j['amount'], 1).clamp(0.0, 1.0),
          mosh: j['mosh'] == true,
          grain: _d(j['grain'], 0.7).clamp(0.0, 1.0),
          melt: _d(j['melt'], 0.5).clamp(0.0, 1.0),
          keys: _d(j['keys'], 0.5).clamp(0.0, 1.0),
        )
      : none;

  @override
  bool operator ==(Object other) =>
      other is RigTransform &&
      other.count == count &&
      other.differ == differ &&
      other.slit == slit &&
      other.turn == turn &&
      other.line == line &&
      other.blend == blend &&
      other.amount == amount &&
      other.mosh == mosh &&
      other.grain == grain &&
      other.melt == melt &&
      other.keys == keys;
  @override
  int get hashCode => Object.hash(count, differ, slit, turn, line, blend, amount, mosh, grain, melt, keys);
}

/// The hands' settings of the effects (ShowPool.transform, kept in show.json): the
/// kaleidoscope's mirrors (how many wedges, their turn, how much of their edges shows,
/// how far the reflections differ, how they meet the original and how much of them),
/// and the datamosh's grain, melt and key frames. Which effect comes, and how often,
/// is the plan's (show_plan.dart's effect row: Fx).
class TransformSet {
  const TransformSet(
      {this.count = 2,
      this.differ = 0.3,
      this.turn = 0,
      this.line = 0.3,
      this.blend = Mix.screen,
      this.amount = 0.85,
      this.grain = 0.7,
      this.melt = 0.5,
      this.keys = 0.5});

  final int count;
  final double differ, turn, line, amount;
  final Mix blend;
  final double grain, melt, keys;

  static const standard = TransformSet();

  /// What the effect [f] puts on, with these settings.
  RigTransform of(Fx f) => RigTransform(
        count: f == Fx.kaleidoscope || f == Fx.both ? count : 0,
        differ: differ,
        slit: f == Fx.slit || f == Fx.both,
        turn: turn,
        line: line,
        blend: blend,
        amount: amount,
        mosh: f == Fx.mosh,
        grain: grain,
        melt: melt,
        keys: keys,
      );

  TransformSet copyWith({int? count, double? differ, double? turn, double? line, Mix? blend, double? amount, double? grain, double? melt, double? keys}) =>
      TransformSet(
          count: count ?? this.count,
          differ: differ ?? this.differ,
          turn: turn ?? this.turn,
          line: line ?? this.line,
          blend: blend ?? this.blend,
          amount: amount ?? this.amount,
          grain: grain ?? this.grain,
          melt: melt ?? this.melt,
          keys: keys ?? this.keys);

  Map<String, dynamic> toJson() => {
        'count': count,
        'differ': differ,
        'turn': turn,
        'line': line,
        'blend': blend.name,
        'amount': amount,
        'grain': grain,
        'melt': melt,
        'keys': keys,
      };

  factory TransformSet.fromJson(Object? j) => j is Map
      ? TransformSet(
          count: (j['count'] is num ? (j['count'] as num).round() : 2).clamp(1, RigTransform.most),
          differ: _d(j['differ'], 0.3).clamp(0.0, 1.0),
          turn: _d(j['turn'], 0).clamp(0.0, 1.0),
          line: _d(j['line'], 0.3).clamp(0.0, 1.0),
          blend: _enumOf(Mix.values, j['blend'], Mix.screen),
          amount: _d(j['amount'], 0.85).clamp(0.0, 1.0),
          grain: _d(j['grain'], 0.7).clamp(0.0, 1.0),
          melt: _d(j['melt'], 0.5).clamp(0.0, 1.0),
          keys: _d(j['keys'], 0.5).clamp(0.0, 1.0),
        )
      : standard;

  @override
  bool operator ==(Object other) =>
      other is TransformSet &&
      other.count == count &&
      other.differ == differ &&
      other.turn == turn &&
      other.line == line &&
      other.blend == blend &&
      other.amount == amount &&
      other.grain == grain &&
      other.melt == melt &&
      other.keys == keys;
  @override
  int get hashCode => Object.hash(count, differ, turn, line, blend, amount, grain, melt, keys);
}

/// The finish over everything (a scene file's `post`, `text` and `particles`).
class RigFinish {
  const RigFinish({
    this.trails = 0,
    this.bloom = 0.5,
    this.tone = 1,
    this.fringe = 0.008,
    this.vignette = 0.6,
    this.grain = 0.5,
    this.recipe = 0,
    this.title = false,
    this.lyrics = false,
    this.where = 'low',
    this.jitter = false,
    this.particles = const [],
  });

  final double trails, bloom, tone, fringe, vignette, grain, recipe;
  final bool title, lyrics, jitter;
  final String where;
  final List<String> particles;

  static const plain = RigFinish();

  RigFinish copyWith({
    double? trails,
    double? bloom,
    double? tone,
    double? fringe,
    double? vignette,
    double? grain,
    double? recipe,
    bool? title,
    bool? lyrics,
    String? where,
    bool? jitter,
    List<String>? particles,
  }) =>
      RigFinish(
        trails: trails ?? this.trails,
        bloom: bloom ?? this.bloom,
        tone: tone ?? this.tone,
        fringe: fringe ?? this.fringe,
        vignette: vignette ?? this.vignette,
        grain: grain ?? this.grain,
        recipe: recipe ?? this.recipe,
        title: title ?? this.title,
        lyrics: lyrics ?? this.lyrics,
        where: where ?? this.where,
        jitter: jitter ?? this.jitter,
        particles: particles ?? this.particles,
      );

  Map<String, dynamic> toJson() => {
        'trails': trails,
        'bloom': bloom,
        'tone': tone,
        'fringe': fringe,
        'vignette': vignette,
        'grain': grain,
        'recipe': recipe,
        if (title) 'title': true,
        if (lyrics) 'lyrics': true,
        if (where != 'low') 'where': where,
        if (jitter) 'jitter': true,
        if (particles.isNotEmpty) 'particles': particles,
      };

  factory RigFinish.fromJson(Map<String, dynamic> j) => RigFinish(
        trails: _d(j['trails'], 0).clamp(0.0, 0.92),
        bloom: _d(j['bloom'], 0.5),
        tone: _d(j['tone'], 1).clamp(0.0, 1.0),
        fringe: _d(j['fringe'], 0.008),
        vignette: _d(j['vignette'], 0.6),
        grain: _d(j['grain'], 0.5),
        recipe: _d(j['recipe'], 0).clamp(0.0, 1.0),
        title: j['title'] == true,
        lyrics: j['lyrics'] == true,
        where: '${j['where'] ?? 'low'}',
        jitter: j['jitter'] == true,
        particles: [for (final p in (j['particles'] as List? ?? const [])) '$p'],
      );

  @override
  bool operator ==(Object other) =>
      other is RigFinish &&
      other.trails == trails &&
      other.bloom == bloom &&
      other.tone == tone &&
      other.fringe == fringe &&
      other.vignette == vignette &&
      other.grain == grain &&
      other.recipe == recipe &&
      other.title == title &&
      other.lyrics == lyrics &&
      other.where == where &&
      other.jitter == jitter &&
      other.particles.join(',') == particles.join(',');
  @override
  int get hashCode => Object.hash(trails, bloom, tone, fringe, vignette, grain, recipe, title, lyrics, where, jitter, particles.length);
}

/// What the stage draws: the layers — the ground, the figure (transformed, then its
/// style), how it meets the ground, and the finish.
class ShowRig {
  const ShowRig({
    this.ground = RigGround.black,
    this.figure = RigFigure.none,
    this.blend = RigBlend.normal,
    this.finish = RigFinish.plain,
    this.transform = RigTransform.none,
  });

  final RigGround ground;
  final RigFigure figure;
  final RigBlend blend;
  final RigFinish finish;
  final RigTransform transform;

  static const none = ShowRig();

  /// A line for the status: `milk / dancers plain · keyhole · contrast`.
  String get word => '${ground.label} / ${figure.label} · ${blend.label}';

  ShowRig copyWith({RigGround? ground, RigFigure? figure, RigBlend? blend, RigFinish? finish, RigTransform? transform}) => ShowRig(
        ground: ground ?? this.ground,
        figure: figure ?? this.figure,
        blend: blend ?? this.blend,
        finish: finish ?? this.finish,
        transform: transform ?? this.transform,
      );

  /// The numbers a shader or a light can bind to, by dotted name.
  void flatInto(Map<String, double> m) {
    m['rig.ground'] = ground.kind.index.toDouble();
    m['rig.ground.dim'] = ground.dim;
    m['rig.figure'] = figure.kind.index.toDouble();
    m['rig.shade'] = figure.shade.index.toDouble();
    m['rig.dressing'] = figure.dressing.index.toDouble();
    m['rig.treatment'] = figure.treatment.index.toDouble();
    m['rig.blend.mask'] = blend.mask.index.toDouble();
    m['rig.blend.mix'] = blend.mix.index.toDouble();
    m['rig.blend.strength'] = blend.strength;
    m['rig.finish.trails'] = finish.trails;
    m['rig.finish.bloom'] = finish.bloom;
  }

  Map<String, dynamic> toJson() => {
        'ground': ground.toJson(),
        'figure': figure.toJson(),
        'blend': blend.toJson(),
        'finish': finish.toJson(),
        if (transform.any) 'transform': transform.toJson(),
      };

  factory ShowRig.fromJson(Map<String, dynamic> j) => ShowRig(
        transform: RigTransform.fromJson(j['transform']),
        ground: j['ground'] is Map ? RigGround.fromJson((j['ground'] as Map).cast()) : RigGround.black,
        figure: j['figure'] is Map ? RigFigure.fromJson((j['figure'] as Map).cast()) : RigFigure.none,
        blend: j['blend'] is Map ? RigBlend.fromJson((j['blend'] as Map).cast()) : RigBlend.normal,
        finish: j['finish'] is Map ? RigFinish.fromJson((j['finish'] as Map).cast()) : RigFinish.plain,
      );

  @override
  bool operator ==(Object other) =>
      other is ShowRig &&
      other.ground == ground &&
      other.figure == figure &&
      other.blend == blend &&
      other.finish == finish &&
      other.transform == transform;
  @override
  int get hashCode => Object.hash(ground, figure, blend, finish, transform);
}

/// A rig with a name: shipped (one for every scene file there was), or the user's own.
class Look {
  const Look({
    required this.id,
    required this.name,
    required this.rig,
    this.meta = const SceneMeta(id: ''),
    this.shipped = false,
    this.hero = false,
    this.thumb,
  });

  final String id, name;
  final ShowRig rig;

  /// What the director reads: where it fits (as a scene file's).
  final SceneMeta meta;

  /// Came with the app (a scene file), not saved by the hands.
  final bool shipped;

  /// The director may put the whole look on, as one (a user look it may use).
  final bool hero;

  /// A picture of it, by path (the user's looks keep the frame they were saved at).
  final String? thumb;

  Look copyWith({String? name, ShowRig? rig, bool? hero, String? thumb}) =>
      Look(id: id, name: name ?? this.name, rig: rig ?? this.rig, meta: meta, shipped: shipped, hero: hero ?? this.hero, thumb: thumb ?? this.thumb);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rig': rig.toJson(),
        'energy': [meta.energy.$1, meta.energy.$2],
        if (meta.sections.isNotEmpty) 'sections': meta.sections,
        if (meta.needs.isNotEmpty) 'needs': meta.needs,
        if (meta.priority != 0) 'priority': meta.priority,
        if (!meta.instant) 'instant': false,
        if (hero) 'hero': true,
        if (thumb != null) 'thumb': thumb,
      };

  factory Look.fromJson(Map<String, dynamic> j, {bool shipped = false}) => Look(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        rig: j['rig'] is Map ? ShowRig.fromJson((j['rig'] as Map).cast()) : ShowRig.none,
        meta: SceneMeta.fromJson(j),
        shipped: shipped,
        hero: j['hero'] == true,
        thumb: j['thumb'] as String?,
      );
}

extension LookInCombo on Look {
  /// This look's rig in combination [c] (show_combos.dart): the background (a world
  /// keeps its own), the style — the figure's own drawing, or a treatment over the
  /// frame — and the mask and the blend. Not this look's combination: as it is.
  ShowRig inCombo(Combo? c) {
    if (c == null || c.scene != id) return rig;
    var figure = rig.figure;
    if (ownStyle(figure.kind)) {
      figure = figure.copyWith(style: c.style);
    } else if (c.style != 'raw') {
      final t = Treatment.values.asNameMap()[c.style];
      if (t != null) figure = figure.copyWith(treatment: t);
    }
    if (c.world) return rig.copyWith(figure: figure, blend: RigBlend.normal);
    final ground = groundOfKey(c.ground);
    // The bloom goes over the blend: on a white page it would bloom the whole frame.
    final finish = ground.kind == Ground.white ? rig.finish.copyWith(bloom: rig.finish.bloom * 0.25) : rig.finish;
    return rig.copyWith(ground: ground, figure: figure, blend: RigBlend(mask: c.mask, mix: c.mix), finish: finish);
  }
}
