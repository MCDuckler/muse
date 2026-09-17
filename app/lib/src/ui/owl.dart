import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The picture a song gets when it has no cover: a wet owl, and never quite the same
/// one twice.
///
/// The old placeholder was a grey gradient with a music note in the middle, which is
/// the visual equivalent of a shrug — and in a library where thousands of songs are
/// still waiting for artwork, it is the same shrug several hundred times down one
/// screen. This is the app's own bird, in the app's own colours, with its face worked
/// out from the song's id: the eyes look somewhere, the brows do something, it is
/// damper on some songs than others. A list of them reads as a list of *different*
/// songs, which is the whole job.
///
/// Drawn rather than drawn *from*: a picture file would need a dozen of them to avoid
/// repeating, and none of them would follow the palette.
class GoofyOwl extends StatelessWidget {
  const GoofyOwl({super.key, required this.seed, this.size = 44});

  /// What makes this owl this owl. The track's id, so a song looks the same every
  /// time you see it — the point is that songs differ from each other, not that one
  /// song is a new animal on every scroll.
  final int seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: Size.square(size),
      painter: _Owl(seed: seed, scheme: scheme),
      isComplex: false,
    );
  }
}

class _Owl extends CustomPainter {
  _Owl({required this.seed, required this.scheme});

  final int seed;
  final ColorScheme scheme;

  /// A stable stream of small numbers from one id.
  ///
  /// Not Random(seed): that is a new object and a warmed-up generator for every one of
  /// several hundred birds on a screen. This is the same trick a hash is, done by hand
  /// so that "nth decision for this owl" is a multiply and a remainder.
  double _n(int which, [double from = 0, double to = 1]) {
    var x = (seed * 2654435761 + which * 40503) & 0x7fffffff;
    x = (x ^ (x >> 13)) * 1274126177 & 0x7fffffff;
    return from + (x % 1000) / 1000 * (to - from);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final r = Rect.fromLTWH(0, 0, size.width, size.height);

    // The background is the app's own colour, turned a little for this song, so a
    // screenful of them is a gradient of the palette rather than a grid of grey.
    final tint = HSLColor.fromColor(scheme.primary);
    final hue = (tint.hue + _n(1, -46, 46)) % 360;
    final back = HSLColor.fromAHSL(
        1, hue, (tint.saturation * 0.55).clamp(0.12, 0.5),
        scheme.brightness == Brightness.dark ? _n(2, 0.17, 0.26) : _n(2, 0.74, 0.86));
    final backTo = HSLColor.fromAHSL(
        1, (hue + _n(3, 10, 40)) % 360, back.saturation,
        (back.lightness + (scheme.brightness == Brightness.dark ? 0.06 : -0.08))
            .clamp(0.06, 0.94));
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [back.toColor(), backTo.toColor()],
        ).createShader(r),
    );

    final ink = HSLColor.fromAHSL(
            1, hue, (tint.saturation * 0.7).clamp(0.2, 0.6),
            scheme.brightness == Brightness.dark ? 0.72 : 0.26)
        .toColor();
    final body = Paint()..color = ink.withValues(alpha: 0.92);
    final pale = Paint()
      ..color = (scheme.brightness == Brightness.dark
              ? const Color(0xFFF3EDE6)
              : const Color(0xFFFFFDF9))
          .withValues(alpha: 0.95);

    // The bird sits low and large: at forty-four pixels a whole owl with feet is a
    // smudge, so what is drawn is a head and a shoulder, filling the square.
    final cx = size.width / 2;
    final headR = s * 0.34;
    final cy = size.height * 0.52;

    // Shoulders, mostly to give the head something to sit on.
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(cx, cy + headR * 1.25), width: s * 0.92, height: s * 0.8),
        body);

    // Ear tufts, at an angle of their own.
    final tuft = Path();
    final lean = _n(4, -0.5, 0.5);
    for (final side in [-1.0, 1.0]) {
      final base = Offset(cx + side * headR * 0.62, cy - headR * 0.72);
      tuft
        ..moveTo(base.dx - side * headR * 0.22, base.dy + headR * 0.22)
        ..lineTo(base.dx + side * headR * (0.34 + lean * side * 0.3),
            base.dy - headR * (0.62 + _n(5, 0, 0.35)))
        ..lineTo(base.dx + side * headR * 0.3, base.dy + headR * 0.18)
        ..close();
    }
    canvas.drawPath(tuft, body);

    canvas.drawCircle(Offset(cx, cy), headR, body);

    // Eyes: big, close together, and looking wherever this owl looks. The whites are
    // drawn as one shape with the pupils on top, because two discs and two dots at
    // forty-four pixels is four things that have to line up.
    final eyeR = headR * _n(6, 0.4, 0.48);
    // Far enough apart not to run into each other: two eyes that overlap is one eye
    // with a dent in it, which reads as a mistake rather than as a face.
    final gap = math.max(headR * _n(7, 0.46, 0.6), eyeR * 1.06);
    final eyeY = cy - headR * 0.08;
    for (final side in [-1.0, 1.0]) {
      canvas.drawCircle(Offset(cx + side * gap, eyeY), eyeR, pale);
    }

    final lookX = _n(8, -0.42, 0.42);
    final lookY = _n(9, -0.3, 0.34);
    // One eye slightly lazier than the other. It is the single thing that makes these
    // read as goofy rather than as a logo.
    final wonk = _n(10, 0.0, 1.0) < 0.35 ? _n(11, -0.3, 0.3) : 0.0;
    final pupil = Paint()..color = const Color(0xFF241D18);
    for (final side in [-1.0, 1.0]) {
      final centre = Offset(
        cx + side * gap + eyeR * (lookX + (side < 0 ? wonk : 0)),
        eyeY + eyeR * lookY,
      );
      canvas.drawCircle(centre, eyeR * _n(12, 0.4, 0.52), pupil);
      // A catchlight, which is the difference between an eye and a hole.
      canvas.drawCircle(
          centre.translate(-eyeR * 0.14, -eyeR * 0.16),
          eyeR * 0.13,
          Paint()..color = Colors.white.withValues(alpha: 0.85));
    }

    // Brows, which is where the expression lives: level, cross, or halfway up.
    //
    // Drawn in the background's colour rather than the bird's: a dark line on a dark
    // head is a line nobody can see, and the expression was invisible at any size.
    final browLift = _n(13, -0.02, 0.3);
    final browTilt = _n(14, -0.5, 0.55);
    final brow = Paint()
      ..color = HSLColor.fromAHSL(1, hue, back.saturation,
              (back.lightness + (scheme.brightness == Brightness.dark ? 0.24 : -0.1))
                  .clamp(0.0, 1.0))
          .toColor()
      ..strokeWidth = s * 0.038
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final side in [-1.0, 1.0]) {
      // A gap in the middle: two brows, not a shelf across the whole head.
      final inner = Offset(cx + side * gap * 0.62,
          eyeY - eyeR * (1.12 + browLift) + side * browTilt * eyeR * 0.4);
      final outer = Offset(cx + side * (gap + eyeR * 0.72),
          eyeY - eyeR * (1.08 + browLift) - side * browTilt * eyeR * 0.4);
      canvas.drawLine(inner, outer, brow);
    }

    // Beak: a small triangle between the eyes, sometimes open, sometimes not.
    final beakTop = eyeY + eyeR * 0.55;
    final beakW = headR * _n(15, 0.16, 0.24);
    final beakH = headR * _n(16, 0.3, 0.46);
    final beak = Paint()..color = const Color(0xFFE9A33C);
    canvas.drawPath(
        Path()
          ..moveTo(cx - beakW, beakTop)
          ..lineTo(cx + beakW, beakTop)
          ..lineTo(cx, beakTop + beakH)
          ..close(),
        beak);
    if (_n(17, 0, 1) < 0.4) {
      // Mouth open — a second, smaller triangle under the first.
      canvas.drawPath(
          Path()
            ..moveTo(cx - beakW * 0.7, beakTop + beakH * 0.75)
            ..lineTo(cx + beakW * 0.7, beakTop + beakH * 0.75)
            ..lineTo(cx, beakTop + beakH * 1.5)
            ..close(),
          Paint()..color = const Color(0xFFC2702A));
    }

    // And the wet part: a drip or two off the tufts, because the app is called WetOwl
    // and this bird has clearly been out in it.
    final drops = Paint()..color = pale.color.withValues(alpha: 0.5);
    final count = (_n(18, 0, 3)).round();
    for (var i = 0; i < count; i++) {
      final x = cx + _n(20 + i, -1, 1) * headR * 1.15;
      final y = cy - headR * _n(30 + i, 0.2, 1.1);
      final drop = s * _n(40 + i, 0.03, 0.055);
      canvas.drawPath(
          Path()
            ..moveTo(x, y - drop * 1.6)
            ..quadraticBezierTo(x + drop, y + drop * 0.2, x, y + drop)
            ..quadraticBezierTo(x - drop, y + drop * 0.2, x, y - drop * 1.6)
            ..close(),
          drops);
    }
  }

  @override
  bool shouldRepaint(_Owl old) => old.seed != seed || old.scheme != scheme;
}

/// A seed for a song that has no id to give — a search hit, a remote row. The text is
/// what there is, and the same text gives the same bird.
int owlSeed(String? text) {
  if (text == null || text.isEmpty) return 7;
  var hash = 0;
  for (final unit in text.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash;
}
