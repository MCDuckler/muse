import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mag.dart';

/// A sleeve for a song that has none.
///
/// Most of this library has no artwork yet — eighteen thousand of its songs are a name
/// and a place to fetch them from — so what a missing cover looks like is what most of
/// a list looks like. A grey square with a note in it is a shrug repeated down the
/// screen. This prints a sleeve instead, the way a small label with no budget for
/// photography did: a colour field from a short run of inks, the title set big in the
/// magazine's condensed face, and one of eight layouts.
///
/// Everything is chosen from the song, so the same song always gets the same sleeve,
/// and a list of them reads as a list of different records. Too small to read a title
/// — a row in a list — it keeps the colour and the layout's shape and sets the first
/// letter instead.
class PrintedSleeve extends StatelessWidget {
  const PrintedSleeve({
    super.key,
    required this.seed,
    this.title = '',
    this.size = 44,
  });

  /// Which sleeve. From the track's id where there is one; see [PrintedSleeve.seedOf]
  /// for a song that has only a name.
  final int seed;
  final String title;
  final double size;

  /// A seed for something with only text to go on: the same text, the same sleeve.
  static int seedOf(String? text) {
    var h = 0x811c9dc5;
    for (final c in (text ?? '').codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: SleevePainter(seed: seed, title: title),
      );
}

/// The inks: a ground and the one colour printed on it. A short run, the way a cheap
/// sleeve was printed — two colours at most, and these eight pairs are the whole shop.
const sleeveInks = <(Color, Color)>[
  (Color(0xFFE83328), Color(0xFFFBFAF6)), // masthead red, paper
  (Color(0xFFFFE14D), Color(0xFF141210)), // highlighter, ink
  (Color(0xFF141210), Color(0xFFFBFAF6)), // ink, paper
  (Color(0xFF00A0DC), Color(0xFF141210)), // process cyan, ink
  (Color(0xFFE5007E), Color(0xFFFFE14D)), // magenta, highlighter
  (Color(0xFFFBFAF6), Color(0xFFE83328)), // paper, masthead red
  (Color(0xFF2F6B4F), Color(0xFFFFE14D)), // bottle green, highlighter
  (Color(0xFFC9CCD2), Color(0xFF141210)), // silver, ink
];

/// Which of the eight layouts a seed prints.
enum SleeveLayout { stacked, numeral, grooves, band, halftone, initials, stripes, split }

class SleevePainter extends CustomPainter {
  SleevePainter({required this.seed, required this.title});

  final int seed;
  final String title;

  /// A little mixing, so neighbouring ids do not walk through the inks in order.
  int get _mixed {
    var x = seed & 0xFFFFFFFF;
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xFFFFFFFF;
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xFFFFFFFF;
    return x ^ (x >> 16);
  }

  (Color, Color) get inks => sleeveInks[_mixed % sleeveInks.length];
  SleeveLayout get layout =>
      SleeveLayout.values[(_mixed >> 5) % SleeveLayout.values.length];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final (ground, ink) = inks;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    // A pale sleeve on a paper page has no edge of its own, and a cut-out without an
    // edge is a hole in the page. A hairline of the ink gives it one.
    if (ground.computeLuminance() > 0.7) {
      canvas.drawRect(
        (Offset.zero & size).deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF141210).withValues(alpha: 0.16),
      );
    }

    final words = title.trim().toUpperCase();
    // Below this a title cannot be read, so it is not set: a row in a list gets the
    // sleeve's colour and shape and one big letter.
    final small = s < 76;

    switch (layout) {
      case SleeveLayout.stacked:
        if (small) return _initial(canvas, s, words, ink, const Alignment(-0.6, 0.55));
        _fit(canvas, words.split(RegExp(r'\s+')).join('\n'), ink,
            box: Rect.fromLTWH(s * 0.08, s * 0.10, s * 0.84, s * 0.83),
            anchorBottom: true);
      case SleeveLayout.numeral:
        final n = '${words.length % 9 + 1}';
        _text(canvas, n, Mag.headline(s * 1.05, color: ink),
            Offset(s * 0.42, s * 0.02), maxWidth: s);
        if (!small && words.isNotEmpty) {
          _text(canvas, words, Mag.typewriter(s * 0.075, color: ink, bold: true),
              Offset(s * 0.08, s * 0.08), maxWidth: s * 0.84, maxLines: 2);
        }
      case SleeveLayout.grooves:
        final rings = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, s * 0.012)
          ..color = ink.withValues(alpha: 0.38);
        for (var r = s * 0.06; r < s * 0.75; r += s * 0.05) {
          canvas.drawCircle(Offset(s / 2, s / 2), r, rings);
        }
        if (small) return _initial(canvas, s, words, ink, Alignment.center, backing: ground);
        _banner(canvas, s, words, ground, ink, top: s * 0.40);
      case SleeveLayout.band:
        canvas.save();
        canvas.translate(s / 2, s / 2);
        canvas.rotate(-0.42);
        canvas.drawRect(
            Rect.fromCenter(center: Offset(0, s * 0.02), width: s * 1.8, height: s * 0.28),
            Paint()..color = ink);
        canvas.restore();
        if (small) return _initial(canvas, s, words, ink, const Alignment(-0.55, -0.55));
        _fit(canvas, words, ink,
            box: Rect.fromLTWH(s * 0.08, s * 0.07, s * 0.84, s * 0.34));
      case SleeveLayout.halftone:
        final dot = Paint()..color = ink;
        final step = s * 0.065;
        for (var y = step / 2; y < s; y += step) {
          final r = step * 0.46 * (y / s);
          if (r < 0.4) continue;
          for (var x = step / 2; x < s; x += step) {
            canvas.drawCircle(Offset(x, y), r, dot);
          }
        }
        if (small) return _initial(canvas, s, words, ink, const Alignment(-0.5, -0.5));
        _fit(canvas, words, ink,
            box: Rect.fromLTWH(s * 0.08, s * 0.07, s * 0.84, s * 0.42));
      case SleeveLayout.initials:
        final two = words.replaceAll(RegExp(r'[^A-Z0-9ÄÖÜ]'), '');
        _text(canvas, two.isEmpty ? '?' : two.substring(0, math.min(2, two.length)),
            Mag.headline(s * 0.98, color: ink), Offset(-s * 0.05, -s * 0.12),
            maxWidth: s * 2);
        if (!small && words.isNotEmpty) {
          _label(canvas, s, words, ground, ink);
        }
      case SleeveLayout.stripes:
        final stripe = Paint()..color = ink;
        for (var y = 0.0; y < s; y += s * 0.10) {
          canvas.drawRect(Rect.fromLTWH(0, y, s, s * 0.035), stripe);
        }
        if (small) return _initial(canvas, s, words, ink, Alignment.center, backing: ground);
        _fit(canvas, words, ground,
            box: Rect.fromLTWH(s * 0.08, s * 0.55, s * 0.84, s * 0.37),
            anchorBottom: true,
            backing: ink);
      case SleeveLayout.split:
        canvas.drawRect(Rect.fromLTWH(0, s * 0.48, s, s * 0.52), Paint()..color = ink);
        if (small) return _initial(canvas, s, words, ground, const Alignment(-0.5, 0.55));
        _fit(canvas, words, ground,
            box: Rect.fromLTWH(s * 0.08, s * 0.53, s * 0.84, s * 0.40),
            anchorBottom: true);
        _text(canvas, 'SIDE A', Mag.typewriter(s * 0.07, color: ink, bold: true),
            Offset(s * 0.08, s * 0.08), maxWidth: s * 0.84);
    }
    canvas.restore();
  }

  /// One big letter, for a sleeve too small to carry a title.
  void _initial(Canvas canvas, double s, String words, Color colour, Alignment where,
      {Color? backing}) {
    final letter = words.replaceAll(RegExp(r'[^A-Z0-9ÄÖÜ]'), '');
    if (letter.isEmpty) {
      canvas.restore();
      return;
    }
    final tp = TextPainter(
      text: TextSpan(text: letter[0], style: Mag.headline(s * 0.74, color: colour)),
      textDirection: TextDirection.ltr,
    )..layout();
    final at = where.withinRect(Rect.fromLTWH(
        0, 0, s - tp.width, s - tp.height));
    if (backing != null) {
      canvas.drawRect(
          Rect.fromLTWH(at.dx - s * 0.04, at.dy, tp.width + s * 0.08, tp.height),
          Paint()..color = backing);
    }
    tp.paint(canvas, at);
    canvas.restore();
  }

  /// A title set as big as will fit the box: the longest word across its width, and
  /// no more lines than the box is tall.
  void _fit(Canvas canvas, String words, Color colour,
      {required Rect box, bool anchorBottom = false, Color? backing}) {
    if (words.isEmpty) return;
    var size = box.width * 0.34;
    late TextPainter tp;
    for (var i = 0; i < 14; i++) {
      tp = TextPainter(
        text: TextSpan(text: words, style: Mag.headline(size, color: colour)),
        textDirection: TextDirection.ltr,
        maxLines: 5,
        ellipsis: '…',
      )..layout(maxWidth: box.width);
      final longest = _longestWord(words, size);
      if (tp.height <= box.height && !tp.didExceedMaxLines && longest <= box.width) break;
      size *= 0.88;
    }
    final at = Offset(box.left, anchorBottom ? box.bottom - tp.height : box.top);
    if (backing != null) {
      canvas.drawRect(
          Rect.fromLTWH(at.dx - box.width * 0.03, at.dy - size * 0.08,
              tp.width + box.width * 0.06, tp.height + size * 0.12),
          Paint()..color = backing);
    }
    tp.paint(canvas, at);
  }

  double _longestWord(String words, double size) {
    var widest = 0.0;
    for (final w in words.split(RegExp(r'\s+'))) {
      final tp = TextPainter(
        text: TextSpan(text: w, style: Mag.headline(size)),
        textDirection: TextDirection.ltr,
      )..layout();
      widest = math.max(widest, tp.width);
    }
    return widest;
  }

  /// A band across the middle, in the ground colour, with the title on it.
  void _banner(Canvas canvas, double s, String words, Color ground, Color ink,
      {required double top}) {
    if (words.isEmpty) return;
    final box = Rect.fromLTWH(s * 0.06, top, s * 0.88, s * 0.22);
    canvas.drawRect(Rect.fromLTWH(0, top - s * 0.02, s, s * 0.26), Paint()..color = ground);
    final tp = TextPainter(
      text: TextSpan(text: words, style: Mag.headline(s * 0.16, color: ink)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 2,
      ellipsis: '…',
    )..layout(minWidth: box.width, maxWidth: box.width);
    tp.paint(canvas, Offset(box.left, top + (s * 0.22 - tp.height) / 2));
  }

  /// A small typewritten label, printed on a block of the ink.
  void _label(Canvas canvas, double s, String words, Color ground, Color ink) {
    final tp = TextPainter(
      text: TextSpan(text: words, style: Mag.typewriter(s * 0.07, color: ground, bold: true)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: s * 0.80);
    final at = Offset(s * 0.08, s * 0.90 - tp.height);
    canvas.drawRect(
        Rect.fromLTWH(at.dx - s * 0.02, at.dy - s * 0.01, tp.width + s * 0.04,
            tp.height + s * 0.02),
        Paint()..color = ink);
    tp.paint(canvas, at);
  }

  void _text(Canvas canvas, String text, TextStyle style, Offset at,
      {required double maxWidth, int? maxLines}) {
    TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )
      ..layout(maxWidth: maxWidth)
      ..paint(canvas, at);
  }

  @override
  bool shouldRepaint(SleevePainter old) => old.seed != seed || old.title != title;
}
