// The control window's glass, looked at rather than reasoned about.
//
// It was a dark plate with a lit rim, and every explanation for that was wrong until
// the pane was rendered over something with structure in it and the pixels counted.
// What it turned out to be: a BoxShadow is a filled shape drawn behind its box, so the
// pane's own shadow lay across the whole of the pane — and the pane's backdrop filter
// read that black as part of the room and blurred it in. Two shadows composing to
// nearly half a coat of black over everything the glass was meant to show.
//
// So this counts the light. A pane of glass may soften and bend what is behind it; it
// may not take half of it away.
@TestOn('linux')
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/glass.dart';

void main() {
  /// The mean brightness of [box] in a render of the scene, with or without the pane.
  Future<double> brightness(WidgetTester tester, {required bool pane, required Brightness look, required Rect box}) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: look, useMaterial3: true),
      home: RepaintBoundary(
        key: key,
        child: Stack(fit: StackFit.expand, children: [
          CustomPaint(painter: _Behind()),
          if (pane)
            Center(
              child: SizedBox(
                width: 620,
                height: 260,
                child: GlassSurface(
                  borderRadius: BorderRadius.circular(20),
                  topBorder: false,
                  opacity: 0.36,
                  blur: 42,
                  sheen: true,
                  padding: const EdgeInsets.all(16),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    var mean = 0.0;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      var sum = 0.0;
      var n = 0;
      for (var y = box.top.round(); y < box.bottom.round(); y++) {
        for (var x = box.left.round(); x < box.right.round(); x++) {
          final i = (y * image.width + x) * 4;
          sum += 0.2126 * bytes[i] + 0.7152 * bytes[i + 1] + 0.0722 * bytes[i + 2];
          n++;
        }
      }
      mean = sum / n;
      image.dispose();
    });
    return mean;
  }

  // The middle of the pane, well clear of the rim band where the lens and the sheen
  // do their work: this is about the body of the glass.
  const middle = Rect.fromLTRB(330, 250, 570, 350);

  for (final look in [Brightness.dark, Brightness.light]) {
    testWidgets('the glass does not take the light out of what is behind it (${look.name})',
        (tester) async {
      final without = await brightness(tester, pane: false, look: look, box: middle);
      final with_ = await brightness(tester, pane: true, look: look, box: middle);
      final change = (with_ - without) / without;
      final said = 'the pane changed what is behind it by '
          '${(change * 100).toStringAsFixed(0)}% '
          '(${without.toStringAsFixed(1)} without it, ${with_.toStringAsFixed(1)} with)';
      // Taking light away is the fault; adding a little is the design. With the lights
      // down the pane was more than half a coat of black — the shadow it cast on
      // itself — and with them up it is a frosted white, which is what glass over a
      // bright page looks like. So this is not symmetrical, and says why.
      expect(change, greaterThan(-0.12), reason: said);
      expect(change, lessThan(0.40), reason: said);
    });
  }
}

/// Stripes and discs: edges to bend and colour to carry, so a pane that is doing
/// nothing and a pane that is doing something do not look alike.
class _Behind extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(colors: [Color(0xFF10233A), Color(0xFF3A1030)])
              .createShader(Offset.zero & size));
    final p = Paint();
    for (var i = 0; i < 26; i++) {
      p.color = i.isEven ? const Color(0xFFFFD166) : const Color(0xFF06D6A0);
      canvas.drawRect(Rect.fromLTWH(i * 36.0, 0, 14, size.height), p);
    }
    p.color = const Color(0xFFEF476F);
    canvas.drawCircle(Offset(size.width * 0.32, size.height * 0.5), 90, p);
    p.color = const Color(0xFF118AB2);
    canvas.drawCircle(Offset(size.width * 0.72, size.height * 0.42), 70, p);
  }

  @override
  bool shouldRepaint(_Behind old) => false;
}
