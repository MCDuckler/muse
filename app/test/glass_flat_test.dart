// Whether the glass is *even*, not just whether it is bright.
//
// The other glass test counts the light over the whole pane, which a pane can pass
// while still having a visible plate inside it: an edge a few tens of pixels in, where
// something is drawn over part of the glass and not the rest. That is what was left
// after the shadow was taken out, and an average cannot see it. This walks a line
// across the pane and looks for a step.
@TestOn('linux')
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/glass.dart';

void main() {
  for (final sheen in [false, true]) {
  testWidgets('the glass has no plate inside it (sheen: $sheen)', (tester) async {
    const w = 900.0, h = 400.0;
    tester.view.physicalSize = const Size(w, h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: RepaintBoundary(
        key: key,
        child: Stack(fit: StackFit.expand, children: [
          // Flat, so anything that varies across the pane is the pane's doing.
          Container(color: const Color(0xFF7A7A7A)),
          Center(
            child: SizedBox(
              width: 700,
              height: 240,
              child: GlassSurface(
                borderRadius: BorderRadius.circular(20),
                opacity: 0.36,
                blur: 42,
                sheen: sheen,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ]),
      ),
    ));
    await tester.pump();
    late ByteData px;
    await tester.runAsync(() async {
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage();
      px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    final out = Platform.environment['SHOTS'];
    if (out != null) {
      await tester.runAsync(() async {
        final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await b.toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$out/glass-flat-$sheen.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // A line straight through the middle of the pane, starting four pixels in from its
    // own edge — past the rim threads, which are meant to be a line, and *through* the
    // lit band, which is not.
    //
    // This used to start twenty pixels in and so walked straight past the thing it was
    // meant to catch: the band is sixteen pixels wide, and for three goes at this the
    // test passed while the panel on the screen plainly had a plate in it.
    const y = h ~/ 2;
    const left = (w - 700) / 2;
    final lum = <double>[];
    for (var x = left.toInt() + 4; x < w - left.toInt() - 4; x++) {
      final i = ((y * w.toInt()) + x) * 4;
      lum.add(0.2126 * px.getUint8(i) + 0.7152 * px.getUint8(i + 1) + 0.0722 * px.getUint8(i + 2));
    }
    // The biggest step between neighbours, and the spread across the line.
    var step = 0.0;
    var at = 0;
    for (var i = 1; i < lum.length; i++) {
      final d = (lum[i] - lum[i - 1]).abs();
      if (d > step) {
        step = d;
        at = i + left.toInt() + 4;
      }
    }
    final lo = lum.reduce((a, b) => a < b ? a : b);
    final hi = lum.reduce((a, b) => a > b ? a : b);
    // ignore: avoid_print
    print('sheen $sheen — across the pane: $lo..$hi, biggest step $step at x=$at');
    // A pane may be brighter at its rim than in its middle — that is its thickness —
    // but it may not get there in one pixel. What a plate looks like is a step.
    expect(step, lessThan(6.0),
        reason: 'a step of $step at x=$at is an edge inside the glass, not a rim');
  });
  }
}
