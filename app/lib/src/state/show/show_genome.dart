// A record's genome: what makes its show its own.
//
// Every record gets a set of numbers drawn once from a random stream seeded by
// the record itself (its id, its key, its tempo, its cover's colour), so the same
// record looks like itself every time it is played and no two records look alike.
// The numbers say how the feedback folds and turns and drifts, how fast the fluid
// swirls and the dye fades, how the slime mould senses, which scenes the director
// leans towards, and how far the palette is turned. They travel in the frame
// (ShowState.genome) as `gene.*`, so a stage in another process reads them too.
import 'dart:math' as math;
import 'dart:ui' show Color;

class Genome {
  const Genome(this.genes);

  /// By dotted name, as the frame carries them: `feedback.zoom`, `fluid.swirl`…
  final Map<String, double> genes;

  static const none = Genome({});

  double operator [](String name) => genes[name] ?? 0;
  bool get isEmpty => genes.isEmpty;

  /// The genome of a record. [camelot] like `8A`, [bpm], [cover] its colour: what
  /// the record is made of goes into the seed, so a re-tagged record changes a
  /// little and a different record changes everything.
  static Genome of({required int trackId, String? camelot, double? bpm, Color? cover}) {
    var seed = trackId * 2654435761;
    if (camelot != null) seed ^= camelot.hashCode * 97;
    if (bpm != null) seed ^= (bpm * 10).round() * 31;
    if (cover != null) seed ^= cover.toARGB32() * 7;
    final r = math.Random(seed & 0x7fffffff);
    double range(double lo, double hi) => lo + (hi - lo) * r.nextDouble();
    double pick(List<double> of) => of[r.nextInt(of.length)];
    // A tempo's feel: slow records drift, fast ones fold and turn.
    final pace = ((bpm ?? 125) - 90) / 90;
    final g = <String, double>{
      // The feedback's recipe: how last frame comes back under this one.
      'feedback.zoom': range(0.985, 1.025),
      'feedback.rotate': range(-0.012, 0.012) * (0.5 + pace),
      'feedback.fold': pick([0, 0, 0, 2, 3, 4, 5, 6, 8]),
      'feedback.warp': range(0.0, 0.5) * range(0.0, 1.0),
      'feedback.hueTurn': range(-0.02, 0.02),
      'feedback.shiftX': range(-0.004, 0.004),
      'feedback.shiftY': range(-0.004, 0.004),
      'feedback.decay': range(0.3, 0.75),
      // The fluid's temper.
      'fluid.swirl': range(0.3, 1.6),
      'fluid.fade': range(0.95, 0.985),
      'fluid.push': range(0.6, 1.4),
      // The slime mould's senses.
      'veins.look': range(5.0, 14.0),
      'veins.wide': range(0.25, 0.7),
      'veins.turn': range(0.2, 0.6),
      'veins.decay': range(0.86, 0.95),
      // The palette: turned a little, more or less saturated.
      'palette.turn': range(-0.06, 0.06),
      'palette.apart': pick([35.0, 60.0, 120.0, 150.0, 180.0, 210.0]),
      // The room fed back (the camera scenes): how big a step in, how much of a
      // turn, how fast the hue walks, how many wedges the fold has.
      'camera.zoom': range(0.1, 0.9),
      'camera.turn': range(0.0, 1.0),
      'camera.hue': range(0.1, 0.9),
      'camera.fold': pick([0.0, 0.0, 0.15, 0.4, 0.6, 0.85]),
      // The blocks' salt: every roll of theirs is this record's own.
      'blocks.salt': range(0.0, 1.0),
      'kinetic.salt': range(0.0, 1.0),
      'palette.sat': range(0.85, 1.1),
      // How much the director leans towards each scene (1 is neutral).
      for (final scene in const ['drift', 'build', 'tunnel', 'kaleido', 'type', 'grid', 'fluid', 'veins', 'toon', 'flash', 'echo', 'fold', 'blocks', 'kinetic'])
        'scene.$scene': pick([0.4, 0.7, 1.0, 1.0, 1.3, 1.8]),
    };
    return Genome(g);
  }

  void flatInto(Map<String, double> m) {
    for (final e in genes.entries) {
      m['gene.${e.key}'] = e.value;
    }
  }

  Map<String, dynamic> toJson() => genes;

  factory Genome.fromJson(Map<String, dynamic> j) =>
      Genome({for (final e in j.entries) e.key: (e.value as num).toDouble()});
}
