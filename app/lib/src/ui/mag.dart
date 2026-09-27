import 'package:flutter/material.dart';

/// The magazine's type.
///
/// Five faces, each with one job, the way a music paper was set:
///
/// - **Archivo** for anything that is a headline: extra condensed and black for titles
///   and cover lines, expanded for kickers and section flags. One variable font, so the
///   two widths are the same letters stretched rather than two families to load.
/// - **Bodoni Moda** for the big numbers — chart positions, play counts, a time — and,
///   in italic, for pull quotes.
/// - **Courier Prime** for captions, credits and fact files: the typewriter a sub-editor
///   used.
/// - **Permanent Marker** for the one handwritten note on a screen, and no more than one.
/// - **Manrope**, as before, for everything that is read in a list or pressed. That is
///   not in here: it is the theme's body text.
///
/// Weights and widths go through [FontVariation] because these are variable fonts; a
/// plain FontWeight would pick the file's default instance and nothing else.
class Mag {
  const Mag._();

  static const _display = 'Archivo';
  static const _typewriter = 'CourierPrime';
  static const _marker = 'PermanentMarker';

  /// A headline: black, extra condensed, set tight. Uppercase is the caller's to
  /// decide — a song title keeps its own case, a cover line does not.
  static TextStyle headline(double size, {Color? color, double width = 62}) => TextStyle(
        fontFamily: _display,
        fontSize: size,
        fontWeight: FontWeight.w900,
        fontVariations: [const FontVariation('wght', 900), FontVariation('wdth', width)],
        height: 0.95,
        letterSpacing: -size * 0.005,
        color: color,
      );

  /// A title a step down from a headline: heavy, a little condensed, easier to read
  /// at the size a sheet's heading is.
  static TextStyle title(double size, {Color? color}) => TextStyle(
        fontFamily: _display,
        fontSize: size,
        fontWeight: FontWeight.w800,
        fontVariations: const [FontVariation('wght', 800), FontVariation('wdth', 78)],
        height: 1.05,
        color: color,
      );

  /// A kicker or section flag: expanded, black, spaced out. Set in capitals.
  static TextStyle flag(double size, {Color? color}) => TextStyle(
        fontFamily: _display,
        fontSize: size,
        fontWeight: FontWeight.w900,
        fontVariations: const [FontVariation('wght', 900), FontVariation('wdth', 125)],
        letterSpacing: size * 0.10,
        height: 1.1,
        color: color,
      );

  /// A number to be looked at: a chart position, a count, a time.
  ///
  /// Set in the display face, not the serif. Bodoni is a Didone — the thick strokes
  /// are very thick and the thin ones are hairlines — and a hairline on the booth's
  /// near-black panel is a grey line a pixel wide that the eye loses. A 147.0 that has
  /// to be read off a deck in a moment is not a page number. Archivo's strokes are one
  /// weight all the way round, so the number holds at any size and on any colour.
  ///
  /// Tabular figures because these numbers change while they are being looked at: a
  /// BPM counting up should not shuffle sideways every time a 1 turns into an 8.
  static TextStyle numerals(double size, {Color? color}) => TextStyle(
        fontFamily: _display,
        fontSize: size,
        fontWeight: FontWeight.w800,
        fontVariations: const [FontVariation('wght', 800)],
        fontFeatures: const [
          FontFeature.liningFigures(),
          FontFeature.tabularFigures(),
        ],
        height: 1.0,
        color: color,
      );

  /// A pull quote.
  ///
  /// Also the display face now, and the Didone is gone from the app with it. Bodoni
  /// is a beautiful thing on paper and a poor one on a lit screen: the strokes run
  /// from very thick to a hairline, and a hairline is a grey line a pixel wide that
  /// thins out, shimmers as it scrolls and disappears at small sizes and low
  /// brightness. Set light and open instead, which is how a magazine sets a pull
  /// quote when it cannot count on the paper.
  static TextStyle quote(double size, {Color? color}) => TextStyle(
        fontFamily: _display,
        fontSize: size,
        fontWeight: FontWeight.w300,
        fontVariations: const [FontVariation('wght', 300), FontVariation('wdth', 100)],
        letterSpacing: -size * 0.012,
        height: 1.28,
        color: color,
      );

  /// A caption, a credit, a line of a fact file.
  static TextStyle typewriter(double size, {Color? color, bool bold = false}) => TextStyle(
        fontFamily: _typewriter,
        fontSize: size,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        height: 1.3,
        color: color,
      );

  /// The one handwritten note.
  static TextStyle marker(double size, {Color? color}) => TextStyle(
        fontFamily: _marker,
        fontSize: size,
        height: 1.1,
        color: color,
      );
}
