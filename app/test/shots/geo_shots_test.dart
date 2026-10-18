// The geometric scenes — kinetic and blocks — at several moments of the made-up
// record, so every composition the phrase can pick shows up, and within the beat
// (a step's start, its middle, its rest). PNGs under SHOTS=<dir>; without it only
// that every moment draws without an error.
//
//   SHOTS=/tmp/shots flutter test test/shots/geo_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/ui/show/show_canvas.dart';
import 'package:muse/src/ui/show/stage_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['SHOTS'];
  late StageKit kit;
  late ui.Image cover;

  setUpAll(() async {
    kit = await StageKit.load();
    final bytes = await File('assets/brand/ball.webp').readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    cover = (await codec.getNextFrame()).image;
  });

  // A phrase is four bars of 128 BPM: 7.5 s. Moments a phrase apart, each a little
  // into a beat (the step under way), and a few at a beat's rest.
  final moments = <Duration>[
    for (var ph = 3; ph < 11; ph++) Duration(milliseconds: ph * 7500 + 1900 + 120),
    for (var ph = 3; ph < 7; ph++) Duration(milliseconds: ph * 7500 + 3800 + 380),
  ];

  for (final scene in const ['kinetic', 'blocks']) {
    for (final at in moments) {
      testWidgets('$scene at ${at.inMilliseconds} ms', (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final feed = DemoShowFeed(scenes: kit.book.metas);
        addTearDown(feed.dispose);
        final t0 = DateTime(2026, 1, 1);
        for (var i = 0; i < 8; i++) {
          feed.tick(t0.add(Duration(milliseconds: 16 * i)), elapsed: at - const Duration(milliseconds: 3000) + Duration(milliseconds: 16 * i));
        }
        feed.director.choose(scene);
        feed.director.locked = true;
        for (var i = 1; i <= 8; i++) {
          feed.tick(t0.add(Duration(milliseconds: 200 + 300 * i)), elapsed: at - const Duration(milliseconds: 2800) + Duration(milliseconds: 300 * i));
        }
        expect(feed.state.scene, scene);

        Object? err;
        final was = FlutterError.onError;
        FlutterError.onError = (d) => err ??= d.exception;
        addTearDown(() => FlutterError.onError = was);
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(
            key: const ValueKey('shot'),
            child: ColoredBox(
              color: Colors.black,
              child: ShowCanvas(feed: feed, book: kit.book, programs: kit.programs, scale: 0.5, covers: {1: cover}),
            ),
          ),
        ));
        for (var i = 0; i < 3; i++) {
          feed.tick(t0.add(Duration(milliseconds: 2600 + 16 * i)), elapsed: at + Duration(milliseconds: 16 * i));
          await tester.pump(const Duration(milliseconds: 16));
        }
        if (out != null) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
            final image = await boundary.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$out/$scene-${at.inMilliseconds.toString().padLeft(6, '0')}.png').writeAsBytes(png!.buffer.asUint8List());
          });
        }
        expect(err, isNull);
      });
    }
  }
}
