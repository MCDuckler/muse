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
import 'show_director.dart' show SceneMeta;

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
}

/// What stands in the middle. [none] is a look that is its own whole picture
/// (MilkDrop alone); [field] a shader drawn whole (drift), [room] the camera through
/// a shader (echo, fold) — both blended with the ground like any figure.
enum Figure { none, dancers, birds, kinetic, blocks, flash, glide, turntable, fluid, veins, meme, words, field, room }

/// How a 3D figure's surface is shaded. [auto] is the figure's own clock choosing
/// from the pool, as it does today.
enum Shade { auto, textured, chrome, silhouette, flat, toon }

/// What the figure stands in: the dancers' stage dressings, the birds' sky.
enum Dressing { auto, none, disco, neon, shadow, studio, sky }

/// An image-space rendering of the figure, any figure.
enum Treatment { auto, raw, ascii, dither, halftone, thermal, lines, contour, chrono, trails, fluid, viewports, radar }

/// How the figure layer's own backdrop pixels (its paper, floor, wash) sit on the
/// ground: dropped so the ground shows ([through]), replacing it ([over]), one of
/// the ways MilkDrop has gone under a scene (shaders/show/under.frag, in its order),
/// or [keyhole]: the figure itself a window onto the ground, everything else black.
enum GroundMode { through, over, add, screen, dim, window, mask, frame, bands, flip, outline, contrast, keyhole }

/// How the figure's own pixels sit on the ground: over it, or blended the same way
/// as its backdrop.
enum FigureMode { over, same }

/// The four layers, for a lock.
enum RigSlot { ground, figure, blend, finish }

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
      kind == Figure.words;

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

class RigBlend {
  const RigBlend({this.ground = GroundMode.over, this.figure = FigureMode.over, this.strength = 1, this.auto = true});

  final GroundMode ground;
  final FigureMode figure;

  /// How much of the blend, 0..1 (0 is the figure over the ground, plainly).
  final double strength;

  /// The pool's table decides the modes for this figure on this ground; the modes
  /// here are what it decided (or the hands', when false).
  final bool auto;

  static const over = RigBlend();

  String get label => '${ground.name}${figure == FigureMode.same ? ' (figures too)' : ''}';

  RigBlend copyWith({GroundMode? ground, FigureMode? figure, double? strength, bool? auto}) =>
      RigBlend(ground: ground ?? this.ground, figure: figure ?? this.figure, strength: strength ?? this.strength, auto: auto ?? this.auto);

  Map<String, dynamic> toJson() => {
        'ground': ground.name,
        'figure': figure.name,
        if (strength != 1) 'strength': strength,
        if (!auto) 'auto': false,
      };

  factory RigBlend.fromJson(Map<String, dynamic> j) => RigBlend(
        ground: _enumOf(GroundMode.values, j['ground'], GroundMode.over),
        figure: _enumOf(FigureMode.values, j['figure'], FigureMode.over),
        strength: _d(j['strength'], 1).clamp(0.0, 1.0),
        auto: j['auto'] != false,
      );

  @override
  bool operator ==(Object other) => other is RigBlend && other.ground == ground && other.figure == figure && other.strength == strength && other.auto == auto;
  @override
  int get hashCode => Object.hash(ground, figure, strength, auto);
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

/// What the stage draws: the four layers, and which of them the hands have locked
/// (the director leaves a locked layer alone).
class ShowRig {
  const ShowRig({
    this.ground = RigGround.black,
    this.figure = RigFigure.none,
    this.blend = RigBlend.over,
    this.finish = RigFinish.plain,
    this.locks = const {},
  });

  final RigGround ground;
  final RigFigure figure;
  final RigBlend blend;
  final RigFinish finish;
  final Set<RigSlot> locks;

  static const none = ShowRig();

  bool locked(RigSlot slot) => locks.contains(slot);

  /// A line for the status: `milk / dancers chrome ascii · contrast`.
  String get word => '${ground.label} / ${figure.label}${blend.ground == GroundMode.over ? '' : ' · ${blend.ground.name}'}';

  ShowRig copyWith({RigGround? ground, RigFigure? figure, RigBlend? blend, RigFinish? finish, Set<RigSlot>? locks}) => ShowRig(
        ground: ground ?? this.ground,
        figure: figure ?? this.figure,
        blend: blend ?? this.blend,
        finish: finish ?? this.finish,
        locks: locks ?? this.locks,
      );

  ShowRig withLock(RigSlot slot, bool on) => copyWith(
      locks: on
          ? {...locks, slot}
          : {
              for (final l in locks)
                if (l != slot) l
            });

  /// The numbers a shader or a light can bind to, by dotted name.
  void flatInto(Map<String, double> m) {
    m['rig.ground'] = ground.kind.index.toDouble();
    m['rig.ground.dim'] = ground.dim;
    m['rig.figure'] = figure.kind.index.toDouble();
    m['rig.shade'] = figure.shade.index.toDouble();
    m['rig.dressing'] = figure.dressing.index.toDouble();
    m['rig.treatment'] = figure.treatment.index.toDouble();
    m['rig.blend.ground'] = blend.ground.index.toDouble();
    m['rig.blend.figure'] = blend.figure.index.toDouble();
    m['rig.blend.strength'] = blend.strength;
    m['rig.finish.trails'] = finish.trails;
    m['rig.finish.bloom'] = finish.bloom;
  }

  Map<String, dynamic> toJson() => {
        'ground': ground.toJson(),
        'figure': figure.toJson(),
        'blend': blend.toJson(),
        'finish': finish.toJson(),
        if (locks.isNotEmpty) 'locks': [for (final l in locks) l.name],
      };

  factory ShowRig.fromJson(Map<String, dynamic> j) => ShowRig(
        ground: j['ground'] is Map ? RigGround.fromJson((j['ground'] as Map).cast()) : RigGround.black,
        figure: j['figure'] is Map ? RigFigure.fromJson((j['figure'] as Map).cast()) : RigFigure.none,
        blend: j['blend'] is Map ? RigBlend.fromJson((j['blend'] as Map).cast()) : RigBlend.over,
        finish: j['finish'] is Map ? RigFinish.fromJson((j['finish'] as Map).cast()) : RigFinish.plain,
        locks: {
          for (final l in (j['locks'] as List? ?? const []))
            if (RigSlot.values.any((s) => s.name == l)) _enumOf(RigSlot.values, l, RigSlot.ground)
        },
      );

  @override
  bool operator ==(Object other) =>
      other is ShowRig &&
      other.ground == ground &&
      other.figure == figure &&
      other.blend == blend &&
      other.finish == finish &&
      other.locks.length == locks.length &&
      other.locks.containsAll(locks);
  @override
  int get hashCode => Object.hash(ground, figure, blend, finish, locks.length);
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
