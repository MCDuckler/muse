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
//   blend       normal (the figure over the background), add, screen, contrast;
//   effect      none, or what is done to the scene over time or space (Fx): the
//               kaleidoscope, the slit-scan, both, the datamosh held on and on.
//
// And the camera, for the scenes that have one (the dancers, the flock): not a part of
// a combination — the camera cuts many times while one is on — but each framing has a
// level in the plan, and the figure's clock weighs its next framing by them at every
// cut. It never says how often a combination comes.
//
// How often each comes is the plan's say (show_plan.dart): every level that applies to
// it, multiplied.
//
// A scene or a style that is a world of its own (MilkDrop alone, the dormouse, the disco
// floor, the viewports, the sky) has one combination: on its own background, unmasked,
// as drawn — weighed by its scene and its style only.
//
// Plans: ~/.claude/plans/wetowl-show-combos.md, wetowl-show-ui-rework.md.
import 'show_rig.dart';

enum Mask { none, keyhole, inverted }

enum Mix { normal, add, screen, contrast }

/// The effect a combination has on (the transformation layer, show_rig.dart's
/// RigTransform): none; the kaleidoscope; the slit-scan; the slit-scan then the
/// kaleidoscope of it; the datamosh held over the whole picture (mosh_clock.dart).
enum Fx { none, kaleidoscope, slit, both, mosh }

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
const treatmentStyles = ['ascii', 'dither', 'halftone', 'thermal', 'lines', 'contour', 'crt', 'slit'];

/// The styles of a figure, by name: its own where it has them (kept in step with
/// show_dance.dart's DanceArt, show_flock.dart's FlockLook, show_words.dart's
/// WordsStyle — a test says so), else the scene as drawn and the treatments.
List<String> stylesOfFigure(Figure f) => switch (f) {
      Figure.dancers => const ['plain', 'mono', 'trails', 'ascii', 'dither', 'chrono', 'contour', 'halftone', 'thermal', 'lines', 'fluid', 'viewports', 'disco', 'crt', 'slit', 'dust'],
      Figure.birds => const ['ink', 'sky', 'embers', 'neon', 'wire', 'chrono', 'ascii', 'dither', 'contour', 'halftone', 'thermal', 'lines', 'radar', 'crt'],
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
  const Combo({required this.ground, required this.scene, required this.style, this.mask = Mask.none, this.mix = Mix.normal, this.fx = Fx.none});

  final String ground, scene, style;
  final Mask mask;
  final Mix mix;
  final Fx fx;

  bool get world => ground == ownGround;

  /// `ground|scene|style|mask|mix`, and `|fx` where it has one (a key from before
  /// the effects reads as none).
  String get key => '$ground|$scene|$style|${mask.name}|${mix.name}${fx == Fx.none ? '' : '|${fx.name}'}';

  static Combo? fromKey(String key) {
    final p = key.split('|');
    if (p.length != 5 && p.length != 6) return null;
    final mask = Mask.values.asNameMap()[p[3]], mix = Mix.values.asNameMap()[p[4]];
    final fx = p.length == 6 ? Fx.values.asNameMap()[p[5]] : Fx.none;
    if (mask == null || mix == null || fx == null) return null;
    return Combo(ground: p[0], scene: p[1], style: p[2], mask: mask, mix: mix, fx: fx);
  }

  Combo copyWith({String? ground, String? scene, String? style, Mask? mask, Mix? mix, Fx? fx}) => Combo(
      ground: ground ?? this.ground,
      scene: scene ?? this.scene,
      style: style ?? this.style,
      mask: mask ?? this.mask,
      mix: mix ?? this.mix,
      fx: fx ?? this.fx);

  @override
  bool operator ==(Object other) => other is Combo && other.key == key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => key;
}

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

/// The combinations of one scene ([kind] its figure): every background, style, mask,
/// blend and effect — or, for a world, its style under each effect. [grounds] narrows
/// the backgrounds (to the ones here now), [fxs] the effects.
List<Combo> combosOf(String scene, Figure kind, {Iterable<String> grounds = comboGrounds, Iterable<Fx> fxs = Fx.values}) {
  final out = <Combo>[];
  for (final style in stylesOfFigure(kind)) {
    if (isWorld(scene, kind, style)) {
      for (final f in fxs) {
        out.add(Combo(ground: ownGround, scene: scene, style: style, fx: f));
      }
      continue;
    }
    for (final g in grounds) {
      for (final m in Mask.values) {
        for (final x in Mix.values) {
          for (final f in fxs) {
            out.add(Combo(ground: g, scene: scene, style: style, mask: m, mix: x, fx: f));
          }
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
