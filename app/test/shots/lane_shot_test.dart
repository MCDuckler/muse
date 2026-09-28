// One deck's lane, with a real record's numbers in it, drawn to a PNG for looking at.
//
//   JARGON=/path/to/jargon.json SHOTS=/path/to/dir flutter test test/shots/lane_shot_test.dart
//
// Without those it does nothing. It exists because "the rule is two beats from the
// drop" cannot be argued about from a photograph of a screen, and the numbers on their
// own say the two agree — so the only thing left is to draw it and look.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/booth/wave_strip.dart';

void main() {
  testWidgets('a lane, drawn', (tester) async {
    final src = Platform.environment['JARGON'];
    final out = Platform.environment['SHOTS'];
    if (src == null || out == null) return;
    final j = jsonDecode(File(src).readAsStringSync()) as Map<String, dynamic>;
    final timing = TrackTiming.fromJson(j['timing'] as Map<String, dynamic>);
    final b = j['bands'] as Map<String, dynamic>;
    List<int> band(String k) => [for (final v in b[k] as List) (v as num).toInt()];
    final bands = (low: band('low'), mid: band('mid'), high: band('high'));

    // Around the drop the report is about, at the console's own window.
    const at = Duration(milliseconds: 58256);
    for (final inks in WaveInks.all) {
    final pos = ValueNotifier(at);
    tester.view.physicalSize = const Size(1600, 260);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: const ValueKey('lane'),
        child: Container(
          color: const Color(0xFF17141A),
          padding: const EdgeInsets.all(8),
          child: WaveStrip(
            position: pos,
            timing: timing,
            bands: bands,
            duration: Duration(milliseconds: timing.durationMs),
            playing: true,
            window: const Duration(seconds: 16),
            height: 240,
            accent: const Color(0xFFFF4A3D),
            inks: inks,
          ),
        ),
      ),
    ));
    await tester.pump();

    // Inside runAsync: toImage is a real asynchronous call into the engine and never
    // completes under the fake clock a widget test runs on.
    await tester.runAsync(() async {
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('lane')));
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/lane-${inks.name}.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
    }
  });
}
