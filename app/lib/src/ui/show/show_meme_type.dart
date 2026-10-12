// The meme edit's type and trimmings: the words as a phone editor sets them, and
// the bits of chrome every gag reuses — a stamp, a speech bubble, a dialog box, a
// lower third. One [MemeType] per edit keeps the laid-out text, since laying a word
// out is the dear part and the same words come round every beat.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../mag.dart';

/// A heavy word with its outline: the stroke under the face.
typedef BoldWord = (TextPainter stroke, TextPainter face);

class MemeType {
  var _painters = <String, TextPainter>{};

  /// The painters let go of at the last clear-out, disposed at the next: one handed
  /// out just before a clear-out is still being painted with (a bold word's stroke,
  /// when its face was the one that filled the cache), and disposing it there threw
  /// "text geometry was not yet calculated" mid-frame.
  var _retired = <String, TextPainter>{};

  TextPainter text(String key, TextSpan Function() span, {TextAlign align = TextAlign.center, double? maxWidth}) {
    final k = maxWidth == null ? key : '$key|${maxWidth.round()}';
    final hit = _painters[k];
    if (hit != null) return hit;
    if (_painters.length > 500) {
      for (final p in _retired.values) {
        p.dispose();
      }
      _retired = _painters;
      _painters = {};
    }
    return _painters[k] = TextPainter(text: span(), textDirection: TextDirection.ltr, textAlign: align)..layout(maxWidth: maxWidth ?? double.infinity);
  }

  /// A word as a phone editor sets it: heavy, [fill], a fat black outline.
  BoldWord bold(String word, double size, Color fill, {double width = 100, Color outline = Colors.black}) {
    final s = size.roundToDouble();
    final stroke = text('s|$word|$s|$width|${outline.toARGB32()}', () {
      return TextSpan(
          text: word,
          style: Mag.headline(s, width: width).copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s * 0.17
              ..strokeJoin = StrokeJoin.round
              ..color = outline,
            shadows: [Shadow(color: const Color(0x99000000), blurRadius: s * 0.12, offset: Offset(0, s * 0.06))],
          ));
    });
    final face = text('f|$word|$s|$width|${fill.toARGB32()}', () => TextSpan(text: word, style: Mag.headline(s, width: width, color: fill)));
    return (stroke, face);
  }

  void paintBold(Canvas canvas, BoldWord w, Offset centre, {double scale = 1, double rot = 0, double opacity = 1}) {
    final (stroke, face) = w;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    if (rot != 0) canvas.rotate(rot);
    if (scale != 1) canvas.scale(scale);
    if (opacity < 1) canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)));
    final at = Offset(-face.width / 2, -face.height / 2);
    stroke.paint(canvas, at);
    face.paint(canvas, at);
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  /// Words a chunk at a time, TikTok's way: up to three on screen, the one being
  /// said in [hi] and popped by [pop]; the rest in [ink]. [y] is the line's middle.
  void captions(Canvas canvas, Size size, List<String> words, int current, double pop, Color hi, Offset shake,
      {Color ink = Colors.white, double y = 0.7, double fontShare = 0.072, double width = 100}) {
    if (words.isEmpty || current < 0) return;
    final chunk = current ~/ 3;
    final shown = words.sublist(chunk * 3, math.min(words.length, chunk * 3 + 3));
    final upto = current - chunk * 3;
    final fs = size.height * fontShare;
    final maxW = size.width * 0.86;
    final gap = fs * 0.3;
    final pieces = [for (var i = 0; i <= upto && i < shown.length; i++) bold(shown[i].toUpperCase(), fs, i == upto ? hi : ink, width: width)];
    double wide(int i) => pieces[i].$2.width * (i == upto ? pop : 1);
    final lines = <List<int>>[[]];
    var lineW = 0.0;
    for (var i = 0; i < pieces.length; i++) {
      final pw = wide(i);
      if (lines.last.isNotEmpty && lineW + gap + pw > maxW) {
        lines.add([]);
        lineW = 0;
      }
      lineW += (lines.last.isEmpty ? 0 : gap) + pw;
      lines.last.add(i);
    }
    final lh = fs * 1.05;
    var yy = size.height * y - (lines.length - 1) * lh / 2 + shake.dy;
    for (final line in lines) {
      var total = 0.0;
      for (final i in line) {
        total += wide(i);
      }
      total += gap * (line.length - 1);
      var x = (size.width - total) / 2 + shake.dx;
      for (final i in line) {
        final pw = wide(i);
        paintBold(canvas, pieces[i], Offset(x + pw / 2, yy), scale: i == upto ? pop : 1);
        x += pw + gap;
      }
      yy += lh;
    }
  }

  /// A rubber stamp slammed on: a word in a box, at an angle, inked unevenly.
  void stamp(Canvas canvas, Offset centre, String word, double h, {Color colour = const Color(0xFFE0141E), double rot = -0.18, double scale = 1, double opacity = 0.92}) {
    final s = (h * 0.13).roundToDouble();
    final p = text('st|$word|$s', () => TextSpan(text: word.toUpperCase(), style: Mag.headline(s, width: 90, color: colour)));
    final padX = s * 0.3, padY = s * 0.08;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(rot);
    canvas.scale(scale);
    canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, opacity));
    final box = Rect.fromCenter(center: Offset.zero, width: p.width + 2 * padX, height: p.height + 2 * padY);
    canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(s * 0.12)),
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.09);
    p.paint(canvas, Offset(-p.width / 2, -p.height / 2));
    // The ink that did not take: speckles knocked out.
    final rnd = math.Random(word.hashCode);
    final knock = Paint()..blendMode = BlendMode.dstOut;
    for (var i = 0; i < 40; i++) {
      canvas.drawCircle(Offset((rnd.nextDouble() - 0.5) * box.width, (rnd.nextDouble() - 0.5) * box.height), s * (0.01 + 0.04 * rnd.nextDouble()), knock);
    }
    canvas.restore();
    canvas.restore();
  }

  /// A comic's speech bubble, its tail at [tail], its words in the middle.
  void bubble(Canvas canvas, Offset at, Offset tail, String line, double h, {double scale = 1}) {
    final s = (h * 0.045).roundToDouble();
    final p = text('bb|$line|$s', () => TextSpan(text: line, style: Mag.marker(s, color: Colors.black)), maxWidth: h * 0.6);
    final box = Rect.fromCenter(center: at, width: p.width + s * 1.2, height: p.height + s * 0.8);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);
    canvas.translate(-at.dx, -at.dy);
    final path = Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(s * 0.8)));
    // The tail: a wedge from the box's nearest edge to the mouth.
    final dir = (tail - at);
    final base = at + dir * 0.25;
    final side = Offset(-dir.dy, dir.dx) / dir.distance * s * 0.5;
    path
      ..moveTo(base.dx + side.dx, base.dy + side.dy)
      ..lineTo(tail.dx, tail.dy)
      ..lineTo(base.dx - side.dx, base.dy - side.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.black);
    canvas.drawPath(path.shift(Offset.zero), Paint()..color = Colors.black);
    canvas.save();
    canvas.translate(0, 0);
    final inner = Path()..addRRect(RRect.fromRectAndRadius(box.deflate(s * 0.12), Radius.circular(s * 0.7)));
    final tail2 = Path()
      ..moveTo(base.dx + side.dx * 0.7, base.dy + side.dy * 0.7)
      ..lineTo(at.dx + dir.dx * 0.9, at.dy + dir.dy * 0.9)
      ..lineTo(base.dx - side.dx * 0.7, base.dy - side.dy * 0.7)
      ..close();
    canvas.drawPath(inner, Paint()..color = Colors.white);
    canvas.drawPath(tail2, Paint()..color = Colors.white);
    canvas.restore();
    p.paint(canvas, Offset(box.center.dx - p.width / 2, box.center.dy - p.height / 2));
    canvas.restore();
  }

  /// An old desktop's error box: a title bar, an icon, a line, two buttons.
  void dialog(Canvas canvas, Offset topLeft, double h, String title, String body, {double scale = 1, bool lit = false}) {
    final s = (h * 0.028).roundToDouble();
    final w = s * 15, bh = s * 6.2;
    canvas.save();
    canvas.translate(topLeft.dx, topLeft.dy);
    canvas.scale(scale);
    final box = Rect.fromLTWH(0, 0, w, bh);
    canvas.drawRect(box.shift(Offset(s * 0.2, s * 0.2)), Paint()..color = const Color(0x66000000));
    canvas.drawRect(box, Paint()..color = const Color(0xFFECE9D8));
    canvas.drawRect(
        box,
        Paint()
          ..color = const Color(0xFF0A246A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.08);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, s * 1.25),
        Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(w, 0), const [Color(0xFF0A246A), Color(0xFFA6CAF0)]));
    text('dt|$title|$s', () => TextSpan(text: title, style: Mag.typewriter(s * 0.85, color: Colors.white, bold: true)), align: TextAlign.left)
        .paint(canvas, Offset(s * 0.3, s * 0.12));
    // The close box.
    final x = Rect.fromLTWH(w - s * 1.1, s * 0.15, s * 0.95, s * 0.95);
    canvas.drawRect(x, Paint()..color = const Color(0xFFECE9D8));
    text('dx|$s', () => TextSpan(text: '×', style: Mag.typewriter(s * 0.9, color: Colors.black, bold: true))).paint(canvas, Offset(x.left + s * 0.2, x.top - s * 0.1));
    // The icon: a red circle with a white X.
    final ic = Offset(s * 1.3, s * 3.0);
    canvas.drawCircle(ic, s * 0.75, Paint()..color = const Color(0xFFD42020));
    final cross = Paint()
      ..color = Colors.white
      ..strokeWidth = s * 0.18;
    canvas.drawLine(ic + Offset(-s * 0.35, -s * 0.35), ic + Offset(s * 0.35, s * 0.35), cross);
    canvas.drawLine(ic + Offset(s * 0.35, -s * 0.35), ic + Offset(-s * 0.35, s * 0.35), cross);
    text('db|$body|$s', () => TextSpan(text: body, style: Mag.typewriter(s * 0.78, color: Colors.black)), align: TextAlign.left, maxWidth: w - s * 3.2)
        .paint(canvas, Offset(s * 2.6, s * 1.9));
    for (final (i, label) in ['OK', 'Abbrechen'].indexed) {
      final b = Rect.fromLTWH(w - s * (i == 0 ? 8.6 : 4.4), bh - s * 1.7, s * 3.9, s * 1.2);
      canvas.drawRect(b, Paint()..color = lit && i == 0 ? const Color(0xFFC0C0C0) : const Color(0xFFECE9D8));
      canvas.drawRect(
          b,
          Paint()
            ..color = Colors.black
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.06);
      final p = text('dbt|$label|$s', () => TextSpan(text: label, style: Mag.typewriter(s * 0.75, color: Colors.black)));
      p.paint(canvas, Offset(b.center.dx - p.width / 2, b.center.dy - p.height / 2));
    }
    canvas.restore();
  }

  /// A news channel's lower third: the red tag, the white bar, the ticker under it.
  void lowerThird(Canvas canvas, Size size, String tag, String headline, String ticker, double tickerK, {double slide = 1}) {
    final w = size.width, h = size.height;
    final s = (h * 0.05).roundToDouble();
    final y0 = h * 0.74;
    canvas.save();
    canvas.translate(-w * (1 - slide), 0);
    // The headline bar.
    canvas.drawRect(Rect.fromLTWH(0, y0, w, s * 1.5), Paint()..color = Colors.white);
    canvas.drawRect(Rect.fromLTWH(0, y0 - s * 0.9, s * 7.5, s * 0.9), Paint()..color = const Color(0xFFD4121A));
    text('lt|$tag|$s', () => TextSpan(text: tag.toUpperCase(), style: Mag.flag(s * 0.55, color: Colors.white))).paint(canvas, Offset(s * 0.5, y0 - s * 0.78));
    text('lh|$headline|$s', () => TextSpan(text: headline.toUpperCase(), style: Mag.headline(s * 1.0, width: 80, color: Colors.black)), align: TextAlign.left, maxWidth: w * 0.95)
        .paint(canvas, Offset(s * 0.5, y0 + s * 0.22));
    canvas.restore();
    // The ticker, scrolling.
    canvas.drawRect(Rect.fromLTWH(0, y0 + s * 1.5, w, s * 0.9), Paint()..color = const Color(0xFF14161A));
    final tp = text('tk|$ticker|$s', () => TextSpan(text: '$ticker   +++   $ticker   +++   ', style: Mag.typewriter(s * 0.6, color: Colors.white, bold: true)));
    final span = tp.width / 2;
    final x = -(tickerK * span) % span;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, y0 + s * 1.5, w, s * 0.9));
    for (var xx = x - span; xx < w; xx += span) {
      tp.paint(canvas, Offset(xx, y0 + s * 1.58));
    }
    canvas.restore();
    canvas.drawRect(Rect.fromLTWH(0, y0 + s * 1.5, s * 2.4, s * 0.9), Paint()..color = const Color(0xFFD4121A));
    text('lv|$s', () => TextSpan(text: 'LIVE', style: Mag.flag(s * 0.5, color: Colors.white))).paint(canvas, Offset(s * 0.35, y0 + s * 1.62));
  }

  /// A typewriter line, letter by letter, with a cursor.
  void typed(Canvas canvas, Offset at, String line, double k, double s, {Color colour = Colors.white, double maxWidth = double.infinity}) {
    final n = (line.length * k.clamp(0.0, 1.0)).floor();
    final shown = line.substring(0, n) + (k < 1 && (DateTime.now().millisecond ~/ 400).isEven ? '▌' : '');
    text('ty|$shown|$s|${colour.toARGB32()}', () => TextSpan(text: shown, style: Mag.typewriter(s, color: colour, bold: true)), align: TextAlign.left, maxWidth: maxWidth)
        .paint(canvas, at);
  }

  void dispose() {
    for (final p in [..._painters.values, ..._retired.values]) {
      p.dispose();
    }
    _painters.clear();
    _retired.clear();
  }
}

/// Colour filters the gags lean on.
class MemeFilters {
  const MemeFilters._();

  static const sepia = ColorFilter.matrix([
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  static const grey = ColorFilter.matrix([
    0.3, 0.59, 0.11, 0, 0, //
    0.3, 0.59, 0.11, 0, 0, //
    0.3, 0.59, 0.11, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  /// Saturation [k] (1 is as it is, 3 is deep-fried) and contrast [c].
  static ColorFilter punch(double k, double c) {
    const lr = 0.3, lg = 0.59, lb = 0.11;
    final ik = 1 - k;
    final off = 0.5 * (1 - c) * 255;
    return ColorFilter.matrix([
      (lr * ik + k) * c, lg * ik * c, lb * ik * c, 0, off, //
      lr * ik * c, (lg * ik + k) * c, lb * ik * c, 0, off, //
      lr * ik * c, lg * ik * c, (lb * ik + k) * c, 0, off, //
      0, 0, 0, 1, 0,
    ]);
  }
}
