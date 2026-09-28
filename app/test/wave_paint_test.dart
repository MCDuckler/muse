// What the strip actually puts on the screen, read back off it.
//
// A record made for the purpose: bass and nothing else for its first half, air and
// nothing else for its second. If the drawing is right the left of the picture is the
// bass ink and the right is the top's — and if the colour has been lost anywhere
// between the house's three numbers and the screen, that is where it shows.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/booth/wave_strip.dart';

const _slices = 200;
const _ms = 20000;

({List<int> low, List<int> mid, List<int> high}) get _halfAndHalf => (
      low: [for (var i = 0; i < _slices; i++) i < _slices ~/ 2 ? 230 : 0],
      mid: [for (var i = 0; i < _slices; i++) 0],
      high: [for (var i = 0; i < _slices; i++) i < _slices ~/ 2 ? 0 : 230],
    );

TrackTiming get _timing => TrackTiming(
      durationMs: _ms,
      bpm: 120,
      beats: [for (var i = 0; i < 40; i++) i * 500],
    );

Future<ByteData> _shoot(WidgetTester tester, WaveInks inks) async {
  tester.view.physicalSize = const Size(200, 80);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: RepaintBoundary(
      key: const ValueKey('lane'),
      child: Container(
        color: const Color(0xFF000000),
        child: WaveStrip(
          position: ValueNotifier(const Duration(milliseconds: _ms ~/ 2)),
          timing: _timing,
          bands: _halfAndHalf,
          duration: const Duration(milliseconds: _ms),
          playing: false,
          // The whole record across the strip, so half the picture is each half of it.
          window: const Duration(milliseconds: _ms),
          height: 80,
          inks: inks,
        ),
      ),
    ),
  ));
  await tester.pump();
  late ByteData data;
  await tester.runAsync(() async {
    final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('lane')));
    final image = await b.toImage();
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  return data;
}

/// The average colour of a strip of the picture, the black background left out.
Color _average(ByteData px, int w, int h, int x0, int x1) {
  var r = 0, g = 0, b = 0, n = 0;
  for (var y = h ~/ 4; y < h * 3 ~/ 4; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * w + x) * 4;
      final cr = px.getUint8(i), cg = px.getUint8(i + 1), cb = px.getUint8(i + 2);
      if (cr + cg + cb < 40) continue;
      r += cr;
      g += cg;
      b += cb;
      n++;
    }
  }
  if (n == 0) return const Color(0xFF000000);
  return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}

void main() {
  testWidgets('bass prints in the bass ink and air in the top\'s', (tester) async {
    final px = await _shoot(tester, WaveInks.press);
    // Clear of the strip's own edge fades, which are the panel's colour and not the
    // record's.
    final left = _average(px, 200, 80, 22, 80);
    final right = _average(px, 200, 80, 120, 178);
    expect(left.r, greaterThan(left.b + 0.3),
        reason: 'the bass half came out $left, which is not the bass ink');
    expect(right.b, greaterThan(right.r + 0.3),
        reason: 'the air half came out $right, which is not the top ink');
  });

  testWidgets('a stacked palette stands its bands on each other', (tester) async {
    // rekordbox's way: the bass at the middle, the top at the outside. Reading down one
    // column of the bass half, the middle of it must be the bass ink — which is the
    // thing a mixed palette cannot do and this one exists for.
    final px = await _shoot(tester, WaveInks.threeBand);
    final band = _average(px, 200, 80, 22, 60);
    expect(band.b, greaterThan(band.r + 0.2),
        reason: 'the bass of a three-band record should be its blue, not $band');
  });

  testWidgets('the strip draws nothing where the record is silent', (tester) async {
    // A record with nothing in it at all: the strip must come back empty rather than
    // full-height, because the colour is taken up to full brightness whatever the
    // loudness and silence would otherwise print as a solid bar.
    tester.view.physicalSize = const Size(200, 80);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: const ValueKey('lane'),
        child: Container(
          color: const Color(0xFF000000),
          child: WaveStrip(
            position: ValueNotifier(const Duration(milliseconds: _ms ~/ 2)),
            timing: _timing,
            bands: (
              low: List.filled(_slices, 0),
              mid: List.filled(_slices, 0),
              high: List.filled(_slices, 0)
            ),
            duration: const Duration(milliseconds: _ms),
            playing: false,
            window: const Duration(milliseconds: _ms),
            height: 80,
          ),
        ),
      ),
    ));
    await tester.pump();
    late ByteData data;
    await tester.runAsync(() async {
      final b =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('lane')));
      final image = await b.toImage();
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    // Nothing tall anywhere: the grid and the ground line are allowed, a filled bar
    // is not.
    var lit = 0;
    for (var x = 22; x < 178; x++) {
      final i = ((8 * 200) + x) * 4;
      if (data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2) > 120) lit++;
    }
    expect(lit, lessThan(10), reason: 'silence drew $lit lit pixels near the top');
  });
}
