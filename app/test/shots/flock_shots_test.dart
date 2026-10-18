// The murmuration, look by look, as pictures: the made-up record (show_demo.dart) at
// a moment of its form, the scene held on and each look and flight forced in turn,
// drawn at 1280×720 and written out under SHOTS=<dir> as flock-<look>-<flight>.png.
// With FLOCK_CLIP=<look> a run of frames of that look is written too
// (flock-clip-<look>-<nnn>.png), for a film of it. Without SHOTS it only checks
// that every look draws without an error.
//
//   SHOTS=/tmp/shots flutter test test/shots/flock_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/ui/show/show_canvas.dart';
import 'package:muse/src/ui/show/show_flock.dart';
import 'package:muse/src/ui/show/show_flock_bird.dart';
import 'package:muse/src/ui/show/stage_kit.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File(f);
    if (!file.existsSync()) continue;
    loader.addFont(file.readAsBytes().then((b) => b.buffer.asByteData()));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['SHOTS'];
  final clip = Platform.environment['FLOCK_CLIP'];
  late StageKit kit;

  setUpAll(() async {
    const f = 'assets/fonts';
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    kit = await StageKit.load();
    // The pigeon, read here where the clock is real.
    await BirdAssets.of('pigeon').loaded;
    expect(BirdAssets.of('pigeon').ready, isTrue, reason: 'the pigeon asset reads');
  });

  tearDown(() {
    FlockSim.forceLook = null;
    FlockSim.forceFlight = null;
    FlockSim.forceShot = null;
  });

  // Each look at a moment that suits it, with a flight that shows it.
  // The demo's form at 128 BPM: intro to 15 s, build to 30, drop to 60, breakdown to
  // 75, build to 90, drop to 120. Each shot ends about ten seconds after `at`.
  const shots = [
    (FlockLook.ink, Flight.murmur, FlockShot.front, Duration(seconds: 16)),
    (FlockLook.sky, Flight.vee, FlockShot.low, Duration(seconds: 61)),
    (FlockLook.embers, Flight.vortex, FlockShot.front, Duration(seconds: 34)),
    (FlockLook.neon, Flight.twin, FlockShot.front, Duration(seconds: 40)),
    (FlockLook.wire, Flight.murmur, FlockShot.front, Duration(seconds: 18)),
    (FlockLook.chrono, Flight.murmur, FlockShot.wide, Duration(seconds: 44)),
    (FlockLook.ascii, Flight.ribbon, FlockShot.front, Duration(seconds: 76)),
    (FlockLook.dither, Flight.sheet, FlockShot.wide, Duration(seconds: 78)),
    (FlockLook.contour, Flight.murmur, FlockShot.front, Duration(seconds: 62)),
    (FlockLook.halftone, Flight.sphere, FlockShot.front, Duration(seconds: 46)),
    (FlockLook.thermal, Flight.twin, FlockShot.wide, Duration(seconds: 48)),
    (FlockLook.lines, Flight.sheet, FlockShot.front, Duration(seconds: 64)),
    (FlockLook.radar, Flight.murmur, FlockShot.high, Duration(seconds: 36)),
    (FlockLook.embers, Flight.vortex, FlockShot.fish, Duration(seconds: 50)),
    (FlockLook.ink, Flight.sphere, FlockShot.fishLow, Duration(seconds: 52)),
  ];

  for (final (look, flight, shot, at) in shots) {
    testWidgets('the murmuration: ${look.name} / ${flight.name} / ${shot.name}', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      FlockSim.forceLook = look;
      FlockSim.forceFlight = flight;
      FlockSim.forceShot = shot;
      final feed = DemoShowFeed(scenes: kit.book.metas);
      addTearDown(feed.dispose);
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 16 * i)), elapsed: at + Duration(milliseconds: 16 * i));
      }
      feed.director.choose('flock');
      // Held: a section turning would let the director choose again.
      feed.director.locked = true;
      feed.tick(t0.add(const Duration(milliseconds: 200)), elapsed: at + const Duration(milliseconds: 200));
      for (var i = 1; i <= 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 200 + 300 * i)), elapsed: at + Duration(milliseconds: 200 + 300 * i));
      }
      expect(feed.state.scene, 'flock');

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
            child: ShowCanvas(feed: feed, book: kit.book, programs: kit.programs, scale: 0.75),
          ),
        ),
      ));
      // The flock needs frames to become anything: four seconds of the record.
      Future<void> frames(int n, {int from = 0, void Function(int)? each}) async {
        for (var i = 0; i < n; i++) {
          feed.tick(t0.add(Duration(milliseconds: 2600 + 16 * (from + i))), elapsed: at + Duration(milliseconds: 2600 + 16 * (from + i)));
          await tester.pump(const Duration(milliseconds: 16));
          each?.call(i);
        }
      }

      // Four seconds of the record for a picture; a second for the check alone (the
      // pigeons on a software canvas are slow, and CI has a day's work to do).
      await frames(out == null ? 60 : 240);
      if (out != null) {
        Future<void> shoot(String name) => tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
              final image = await boundary.toImage();
              final png = await image.toByteData(format: ui.ImageByteFormat.png);
              await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
            });
        await shoot('flock-${look.name}-${flight.name}-${shot.name}');
        if (clip == look.name) {
          // Every other frame for four seconds: a film at thirty.
          for (var i = 0; i < 240; i++) {
            feed.tick(t0.add(Duration(milliseconds: 2600 + 16 * (240 + i))), elapsed: at + Duration(milliseconds: 2600 + 16 * (240 + i)));
            await tester.pump(const Duration(milliseconds: 16));
            if (i.isEven) await shoot('flock-clip-${look.name}-${(i ~/ 2).toString().padLeft(3, '0')}');
          }
        }
      }
      expect(err, isNull);
    });
  }
}
