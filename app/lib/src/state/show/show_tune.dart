// The treatments' knobs: how big an ascii's letters are and how much room is
// between them, how far apart a ridgeline's lines run, how thick they are and how
// high the light lifts them, how fat a halftone's dots… One set per treatment, the
// hands' (ShowPool.tune, kept in show.json), carried to every stage on the frame
// (ShowMacros.tune), and read wherever that treatment is drawn: the dancers', the
// birds', and the pass any other scene goes through (ui/show/show_canvas.dart).
//
// Every knob is a multiplier on the look as it was drawn before there were knobs:
// 1 is that look. The shaders take 0 as 1, so a stage that sets none draws as ever.
import 'show_pool.dart';
import 'show_rig.dart';

enum TuneKnob { size, spacing, weight, height, gain, tint }

class TuneSpec {
  const TuneSpec(this.knob, this.label, this.tip, {this.min = 0.25, this.max = 3, this.rest = 1});
  final TuneKnob knob;
  final String label, tip;
  final double min, max, rest;
}

/// The treatments a picture can be put through whatever drew it: a pass over the
/// figure's frame (dance_fx.frag's modes), so any scene can go as text, as one bit,
/// as a print, as heat, as ridgelines or as a map.
const imageTreatments = [Treatment.ascii, Treatment.dither, Treatment.halftone, Treatment.thermal, Treatment.lines, Treatment.contour];

/// dance_fx.frag's mode for a treatment, by name (the dancers' and birds' styles
/// share the names).
const treatmentFxMode = {'ascii': 1, 'dither': 2, 'contour': 3, 'halftone': 4, 'thermal': 5, 'lines': 6};

/// The knobs each treatment has, in the order the panel shows them.
const treatmentTunes = <String, List<TuneSpec>>{
  'ascii': [
    TuneSpec(TuneKnob.size, 'SIZE', 'How big the letters are'),
    TuneSpec(TuneKnob.spacing, 'SPACING', 'Room between the letters and the lines', min: 0.6, max: 2.5),
    TuneSpec(TuneKnob.tint, 'COLOUR', 'The ink, or the picture\'s own colour', min: 0, max: 1, rest: 0.2),
    TuneSpec(TuneKnob.gain, 'GAIN', 'How bright the picture is read: more letters, denser'),
  ],
  'dither': [
    TuneSpec(TuneKnob.size, 'SIZE', 'How big a dot is'),
    TuneSpec(TuneKnob.gain, 'GAIN', 'How bright the picture is read: more ink'),
  ],
  'halftone': [
    TuneSpec(TuneKnob.size, 'SCREEN', 'How far apart the dots are'),
    TuneSpec(TuneKnob.weight, 'DOTS', 'How big the dots grow in the light', max: 2),
    TuneSpec(TuneKnob.gain, 'GAIN', 'How bright the picture is read'),
  ],
  'thermal': [
    TuneSpec(TuneKnob.size, 'HALO', 'How far the heat glows round things'),
    TuneSpec(TuneKnob.gain, 'GAIN', 'How hot the picture reads'),
  ],
  'lines': [
    TuneSpec(TuneKnob.spacing, 'SPACING', 'How far apart the lines run'),
    TuneSpec(TuneKnob.weight, 'WEIGHT', 'How thick a line is'),
    TuneSpec(TuneKnob.height, 'HEIGHT', 'How high the light lifts a line', max: 2.5),
    TuneSpec(TuneKnob.gain, 'GAIN', 'How bright the picture is read'),
  ],
  'contour': [
    TuneSpec(TuneKnob.spacing, 'SPACING', 'How far apart the lines of equal light are'),
    TuneSpec(TuneKnob.weight, 'WEIGHT', 'How thick a line is'),
    TuneSpec(TuneKnob.gain, 'GAIN', 'How bright the picture is read'),
  ],
};

/// The key a knob is kept under: `lines.weight`.
String tuneKey(String treatment, TuneKnob k) => '$treatment.${k.name}';

/// The knob [k] of [treatment] in [tune], or its rest.
double tuneOf(Map<String, double> tune, String treatment, TuneKnob k) {
  final v = tune[tuneKey(treatment, k)];
  if (v != null) return v;
  for (final s in treatmentTunes[treatment] ?? const <TuneSpec>[]) {
    if (s.knob == k) return s.rest;
  }
  return 1;
}

/// The shader's knobs for [treatment] (uWeight, uSpacing, uHeight, uGain, uSize), from
/// [tune]; and the cell multiplier the caller puts on its own cell size.
({double weight, double spacing, double height, double gain, double size, double cell}) fxKnobs(Map<String, double> tune, String treatment) {
  double k(TuneKnob x) => tuneOf(tune, treatment, x);
  return (
    weight: k(TuneKnob.weight),
    spacing: k(TuneKnob.spacing),
    height: k(TuneKnob.height),
    gain: k(TuneKnob.gain),
    size: k(TuneKnob.size),
    // The ridgelines' cell is their gap: the spacing knob sets it; the rest, the size.
    cell: treatment == 'lines' ? k(TuneKnob.spacing) : k(TuneKnob.size),
  );
}

/// What is in [look]'s mix of treatments, by name (`raw` is the look as drawn): its
/// own (ShowPool.mixes), or the shipped one — every image treatment and the look as
/// drawn but those switched off as `treatment.*` (the contour, to start with).
List<String> mixOf(ShowPool pool, String look) =>
    pool.mixes[look] ?? [for (final t in [Treatment.raw, ...imageTreatments]) if (pool.isOn('treatment.${t.name}')) t.name];

/// [look]'s mix with [name] put in it or taken out.
ShowPool withInMix(ShowPool pool, String look, String name, bool on) {
  final now = mixOf(pool, look);
  return pool.withMix(look, [
    for (final t in [Treatment.raw, ...imageTreatments])
      if (t.name == name ? on : now.contains(t.name)) t.name,
  ]);
}

/// What the conductor may pick for [look], with how much: what is in its mix, the look
/// as drawn twice over (a scene is itself more often than not), each leaned as the
/// pool leans `treatment.<name>`.
List<(Treatment, double)> treatMix(ShowPool pool, String look) {
  final on = mixOf(pool, look);
  return [
    for (final t in [Treatment.raw, ...imageTreatments])
      if (on.contains(t.name)) (t, (t == Treatment.raw ? 2.0 : 1.0) * pool.leanOf('treatment.${t.name}')),
  ];
}
