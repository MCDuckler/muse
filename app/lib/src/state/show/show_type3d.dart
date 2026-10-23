// The 3D type: words of the hands' own, set in a display face, extruded into solid
// letters and turned in space to the music (ui/show/show_type3d.dart draws them;
// shaders/show/sim/type3d.frag ray-marches them, on either stage).
//
// What the hands say of it (TypeSpec, kept in the pool, carried to the stage on the
// frame's macros):
//
//   lines    what it says — one line at a time, the next on the change (a bar, a
//            phrase of four, eight bars, never); `{title}` and `{artist}` are the
//            record's own;
//   font     the face (TypeFont: the words' faces and six display faces);
//   motions  how it turns — any of TypeMotion; a phrase picks one of them;
//   looks    what it is made of — any of TypeLook; a phrase picks one;
//   deforms  how the music bends it — any of TypeDeform; a phrase picks two;
//   turn     how one line becomes the next — a morph, a flip, a glitch;
//   colour   the record's palette, or a fixed one (TypeColour);
//   knobs    size, depth, bevel, speed, the beat's push, the glow.
import 'dart:convert';

/// How the letters move.
///
///   spin     turning round their upright, a turn every two bars;
///   tumble   turning about all three at once, slowly, each at its own rate;
///   swing    rocking side to side on the beat, a pendulum;
///   flip     still, then a half turn over on each bar's downbeat;
///   wave     a wave running through the letters, the whole a little turned;
///   twist    wrung about their length, back and forth over the bar;
///   orbit    circling the middle, always half facing;
///   zoom     flying in from far off over a phrase, through, and again;
///   bounce   hopping on the kick, landing squashed;
///   drift    close up, the letters filling the view and gliding past, cropped;
///   still    facing, only the beat's push.
enum TypeMotion { spin, tumble, swing, flip, wave, twist, orbit, zoom, bounce, drift, still }

/// What the letters are made of.
///
///   chrome      a polished metal mirroring a purple studio;
///   neon        dark letters, their edges tubes of light;
///   solid       painted faces, deeper sides, a highlight;
///   outline     their edges alone, drawn in light;
///   hologram    a see-through light, scanned, its colours split at the rim;
///   iridescent  a foil, a thin film's colours turning with the angle;
///   glass       clear glass bending what is behind it (MilkDrop through it);
///   aurora      a soft gradient of the three colours flowing through it;
///   pop         flat print colours, a black outline, halftone dots in the shade;
///   stripes     op art: bands sweeping through it on the beat;
///   mercury     liquid metal, its surface never still.
enum TypeLook { chrome, neon, solid, outline, hologram, iridescent, glass, aurora, pop, stripes, mercury }

/// How the music bends the letters, each by its own part of it.
///
///   inflate  puffed up on the kick, rounder;
///   ripple   rings running out from the middle on the beat, deeper with the bass;
///   melt     dripping down over the phrase, the more the quieter, re-formed on
///            the next;
///   slice    torn sideways in bands on the snare;
///   shatter  flown apart on the drop (and cracking open through a build), coming
///            back together;
///   wobble   a liquid wobble going through it with the hats;
///   squash   flattened and widened on the kick;
///   arc      curved along its length, rocking over the bar;
///   stack    echoes of it stacked behind, spreading on the kick;
///   repeat   rows of it above and below, scrolling, the view full of it.
enum TypeDeform { inflate, ripple, melt, slice, shatter, wobble, squash, arc, stack, repeat }

/// How one line becomes the next: its letters flowing into the next ones (morph),
/// turned over edge-on (flip), cut over in torn bands (glitch).
enum TypeTurn { morph, flip, glitch }

/// When the next line comes: every beat, bar, two bars, phrase (four bars), eight
/// bars, or never (the first line held).
enum TypeChange { beat, bar, twoBars, phrase, eightBars, never }

/// The colours: the record's palette, or one of a few fixed sets.
enum TypeColour { record, purple, sunset, ice, gold, mono }

/// The faces, by family (pubspec.yaml).
enum TypeFont {
  bebas('BebasNeue', 'Bebas'),
  orbitron('Orbitron', 'Orbitron'),
  bungee('Bungee', 'Bungee'),
  pixel('PressStart2P', 'Pixel'),
  monoton('Monoton', 'Monoton'),
  rubik('RubikMonoOne', 'Rubik Mono'),
  righteous('Righteous', 'Righteous'),
  syne('Syne', 'Syne'),
  archivo('Archivo', 'Archivo'),
  serif('InstrumentSerif', 'Serif'),
  marker('PermanentMarker', 'Marker'),
  courier('CourierPrime', 'Courier');

  const TypeFont(this.family, this.label);
  final String family, label;
}

class TypeSpec {
  const TypeSpec({
    this.lines = const ['WETOWL'],
    this.font = TypeFont.bebas,
    this.motions = const {TypeMotion.spin, TypeMotion.swing, TypeMotion.flip, TypeMotion.wave, TypeMotion.twist},
    this.looks = const {TypeLook.chrome, TypeLook.neon, TypeLook.iridescent, TypeLook.glass},
    this.deforms = const {TypeDeform.inflate, TypeDeform.ripple, TypeDeform.slice, TypeDeform.shatter},
    this.turn = TypeTurn.morph,
    this.colour = TypeColour.record,
    this.change = TypeChange.phrase,
    this.size = 1,
    this.depth = 1,
    this.bevel = 1,
    this.speed = 1,
    this.beat = 1,
    this.glow = 1,
    this.bend = 1,
  });

  final List<String> lines;
  final TypeFont font;
  final Set<TypeMotion> motions;
  final Set<TypeLook> looks;

  /// None is none: the letters as cut.
  final Set<TypeDeform> deforms;
  final TypeTurn turn;
  final TypeColour colour;
  final TypeChange change;

  /// Multipliers on the look as drawn (1 is it): how big, how deep, how rounded the
  /// edges, how fast it moves, how hard the beat pushes it, how much it glows, how far
  /// the music bends it.
  final double size, depth, bevel, speed, beat, glow, bend;

  static const standard = TypeSpec();

  /// Knobs and their reach, for the panel and for reading a document.
  static const knobRange = (0.0, 3.0);

  /// The line [n]th in turn, with the record's words in it.
  String lineAt(int n, {String? title, String? artist}) {
    final said = [for (final l in lines) if (l.trim().isNotEmpty) l.trim()];
    if (said.isEmpty) return 'WETOWL';
    final line = said[n % said.length];
    return line.replaceAll('{title}', title ?? '').replaceAll('{artist}', artist ?? '').trim().ifEmpty('WETOWL');
  }

  TypeSpec copyWith({
    List<String>? lines,
    TypeFont? font,
    Set<TypeMotion>? motions,
    Set<TypeLook>? looks,
    Set<TypeDeform>? deforms,
    TypeTurn? turn,
    TypeColour? colour,
    TypeChange? change,
    double? size,
    double? depth,
    double? bevel,
    double? speed,
    double? beat,
    double? glow,
    double? bend,
  }) =>
      TypeSpec(
        lines: lines ?? this.lines,
        font: font ?? this.font,
        motions: motions ?? this.motions,
        looks: looks ?? this.looks,
        deforms: deforms ?? this.deforms,
        turn: turn ?? this.turn,
        colour: colour ?? this.colour,
        change: change ?? this.change,
        size: size ?? this.size,
        depth: depth ?? this.depth,
        bevel: bevel ?? this.bevel,
        speed: speed ?? this.speed,
        beat: beat ?? this.beat,
        glow: glow ?? this.glow,
        bend: bend ?? this.bend,
      );

  Map<String, dynamic> toJson() => {
        'lines': lines,
        'font': font.name,
        'motions': [for (final m in TypeMotion.values) if (motions.contains(m)) m.name],
        'looks': [for (final l in TypeLook.values) if (looks.contains(l)) l.name],
        'deforms': [for (final d in TypeDeform.values) if (deforms.contains(d)) d.name],
        'turn': turn.name,
        'colour': colour.name,
        'change': change.name,
        'size': size,
        'depth': depth,
        'bevel': bevel,
        'speed': speed,
        'beat': beat,
        'glow': glow,
        'bend': bend,
      };

  factory TypeSpec.fromJson(Object? j) {
    if (j is! Map) return standard;
    const s = standard;
    double k(String key, double rest) {
      final v = j[key];
      return v is num ? v.toDouble().clamp(knobRange.$1, knobRange.$2) : rest;
    }

    Set<T> names<T extends Enum>(List<T> all, Object? v, Set<T> rest, {bool noneIsNone = false}) {
      if (v is! List) return rest;
      final got = {for (final x in all) if (v.contains(x.name)) x};
      return got.isEmpty && !noneIsNone ? rest : got;
    }

    T one<T extends Enum>(List<T> all, Object? v, T rest) => all.where((x) => x.name == v).firstOrNull ?? rest;
    return TypeSpec(
      lines: j['lines'] is List ? [for (final l in j['lines'] as List) if (l is String) l] : s.lines,
      font: one(TypeFont.values, j['font'], s.font),
      motions: names(TypeMotion.values, j['motions'], s.motions),
      looks: names(TypeLook.values, j['looks'], s.looks),
      deforms: names(TypeDeform.values, j['deforms'], s.deforms, noneIsNone: true),
      turn: one(TypeTurn.values, j['turn'], s.turn),
      colour: one(TypeColour.values, j['colour'], s.colour),
      change: one(TypeChange.values, j['change'], s.change),
      size: k('size', s.size),
      depth: k('depth', s.depth),
      bevel: k('bevel', s.bevel),
      speed: k('speed', s.speed),
      beat: k('beat', s.beat),
      glow: k('glow', s.glow),
      bend: k('bend', s.bend),
    );
  }

  @override
  bool operator ==(Object other) => other is TypeSpec && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
