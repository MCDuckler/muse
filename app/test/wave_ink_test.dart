// The colour a record's shape is printed in.
//
// Three properties make a coloured waveform worth having, and all three are easy to
// lose: the colour has to say what the record is made of, it has to say the same thing
// whether that passage is loud or quiet, and a mixture has to print as a mixture rather
// than as white. What is drawn on top of them — the height, the grid, the rules — is
// tested where it is drawn; this is the rule itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/booth/wave_strip.dart';

Color inkOf(WaveInks w, double l, double m, double h) => Color(waveInk(w, l, m, h));

/// How far apart two colours are, ignoring how bright they are: what the eye calls a
/// different colour rather than a darker one.
double hueApart(Color a, Color b) {
  final x = HSVColor.fromColor(a).hue, y = HSVColor.fromColor(b).hue;
  final d = (x - y).abs();
  return d > 180 ? 360 - d : d;
}

void main() {
  for (final inks in WaveInks.all) {
    group(inks.name, () {
      test('a band on its own prints in its own ink', () {
        if (inks == WaveInks.xray || inks.stacked) return;
        expect(hueApart(inkOf(inks, 1, 0, 0), inks.low), lessThan(20),
            reason: 'bass alone');
        expect(hueApart(inkOf(inks, 0, 1, 0), inks.mid), lessThan(20),
            reason: 'middle alone');
        expect(hueApart(inkOf(inks, 0, 0, 1), inks.high), lessThan(20),
            reason: 'top alone');
      });

      test('how loud it is does not change what colour it is', () {
        if (inks.stacked) return; // the stack says it with height, not with colour
        // The property the whole construction exists for. A breakdown at a whisper has
        // to read as a breakdown, not as a dark smudge — the height is what says how
        // loud, and the colour must not spend itself saying it again. Mixxx normalises
        // to the brightest channel for exactly this; so does this.
        for (final (l, m, h) in [(1.0, 0.4, 0.1), (0.2, 0.9, 0.3), (0.1, 0.1, 1.0)]) {
          final loud = inkOf(inks, l, m, h);
          final quiet = inkOf(inks, l / 20, m / 20, h / 20);
          expect(hueApart(loud, quiet), lessThan(1.0),
              reason: 'a twentieth as loud, and the same balance');
          expect(HSVColor.fromColor(quiet).value, greaterThan(0.9),
              reason: 'and still printed at full');
        }
      });

      test('the brightest of the three channels is always full', () {
        final c = inkOf(inks, 0.3, 0.2, 0.05);
        expect([c.r, c.g, c.b].reduce((a, b) => a > b ? a : b), closeTo(1.0, 0.01));
      });
    });
  }

  test('a mixture prints between the inks it is a mixture of, not white', () {
    // What the first two goes at this got wrong. Inks that share a channel drift to
    // white when they are mixed, and a waveform that is white everywhere has thrown
    // away the only thing it was drawn in colour to say.
    final both = inkOf(WaveInks.press, 1, 0, 1);
    final c = HSVColor.fromColor(both);
    expect(c.saturation, greaterThan(0.5),
        reason: 'bass and air together came out washed: ${both.toARGB32().toRadixString(16)}');
    expect(hueApart(both, WaveInks.press.low), greaterThan(10));
    expect(hueApart(both, WaveInks.press.high), greaterThan(10));
  });

  test('silence is not asked what colour it is', () {
    // Nothing in any band: the mix is all zero and normalising it would be a division
    // by nothing. It must come back as a colour rather than as a crash or a NaN.
    final c = inkOf(WaveInks.press, 0, 0, 0);
    expect(c.a, 1.0);
    expect(c.r.isNaN || c.g.isNaN || c.b.isNaN, isFalse);
  });

  test('the inks the house offers each own a channel of their own', () {
    // Not a style rule — the condition of the picture meaning anything. Two inks that
    // share a channel cannot be told apart in a mixture, and the band that is quieter
    // disappears into the band that is louder. Two palettes were lost to this before
    // it was written down.
    for (final inks in WaveInks.all) {
      // Stacked palettes are exempt by construction: they do not mix, so their inks
      // may share a channel. That is the whole reason the stacked mode exists.
      if (inks == WaveInks.xray || inks.stacked) continue;
      final owners = <int>{};
      for (final c in [inks.low, inks.mid, inks.high]) {
        final v = [c.r, c.g, c.b];
        owners.add(v.indexOf(v.reduce((a, b) => a > b ? a : b)));
      }
      expect(owners.length, 3,
          reason: '${inks.name}: two of its three inks are strongest in the same '
              'channel, so a record\'s bands will not stay apart');
    }
  });
}
