// The show's colours, from the record: the cover's colour, turned a little towards
// the key's place on the wheel, answered by a second colour that depends on where
// the record is — opposite it in a drop, beside it in a breakdown — and an accent
// for the hits. The engine eases between palettes over a couple of seconds.
import 'package:flutter/painting.dart' show Color, HSLColor;

import 'show_state.dart';

/// The palette for a record at [coverColor] in a key at [keyHue], in a section
/// called [section], with the performer's [colourTurn] (0..1 round) on it.
ShowPalette paletteFor({
  Color? coverColor,
  double? keyHue,
  String? section,
  double colourTurn = 0,
  double? apart,
}) {
  var base = coverColor == null ? ShowPalette.house.primary : HSLColor.fromColor(coverColor);
  // A grey cover has no hue worth keeping: the key's then.
  if (base.saturation < 0.15 && keyHue != null) base = base.withHue(keyHue * 360);
  var hue = base.hue;
  if (keyHue != null) hue = _towards(hue, keyHue * 360, 0.3);
  hue = (hue + colourTurn * 360) % 360;
  // Lit enough to show on black, coloured enough to be a colour.
  final primary = HSLColor.fromAHSL(1, hue, base.saturation.clamp(0.55, 0.95), 0.55);
  // The secondary sits a fixed way round the wheel from the primary — the record's
  // own (its genome), not the section's: a palette that swung with the section
  // swept every colour between on every drop. The section only lifts or dims it.
  final sat = switch (section) { 'drop' || 'chorus' => 0.9, 'breakdown' || 'break' => 0.6, _ => 0.8 };
  final secondary = HSLColor.fromAHSL(1, (hue + (apart ?? 150.0)) % 360, sat, 0.52);
  final accent = HSLColor.fromAHSL(1, (hue + 30) % 360, 0.9, 0.78);
  return ShowPalette(primary: primary, secondary: secondary, accent: accent);
}

/// [a] turned [k] of the way to [b] round the wheel, the short way.
double _towards(double a, double b, double k) {
  var d = (b - a) % 360;
  if (d > 180) d -= 360;
  return (a + d * k) % 360;
}
