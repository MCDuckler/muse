// The stage, scene by scene, as pictures: the made-up record (show_demo.dart) at a
// few moments in its form, each scene held on by hand, drawn at 1280×720 and
// written out as PNGs under SHOTS=<dir>. Without SHOTS it only checks that every
// scene draws without an error, which is the thing a test can judge.
//
//   SHOTS=/tmp/shots flutter test test/shots/show_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/ui/show/show_canvas.dart';
import 'package:muse/src/ui/show/show_meme.dart';
import 'package:muse/src/ui/show/show_turntable.dart';
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
  late StageKit kit;
  late ui.Image cover;

  setUpAll(() async {
    const f = 'assets/fonts';
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf']);
    kit = await StageKit.load();
    // The meme edit's pictures, decoded here where the clock is real.
    await MemeBank.of('siebenschlaefer').decodeAll();
    // And the turntable's models off the web.
    await TurntableBank.shared.warm();
    // The demo record's cover, decoded here: the stage cannot wait for a fetch.
    final bytes = await File('assets/brand/ball.webp').readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    cover = (await codec.getNextFrame()).image;
  });

  test('every scene file loads, with its shader', () {
    expect(kit.book.scenes.keys, containsAll(['drift', 'fluid', 'veins', 'toon', 'flash', 'echo', 'fold', 'blocks', 'kinetic', 'siebenschlaefer', 'turntable', 'dance-disco', 'dance-neon', 'dance-shadow', 'dance-art']));
    for (final s in kit.book.scenes.values) {
      for (final sh in s.shaders) {
        expect(kit.programs.scenes.containsKey(sh), isTrue, reason: '${s.id} wants $sh');
      }
    }
  });

  test('the turntable builds its shapes and reads its .glb and .obj models', () {
    final names = [for (final m in TurntableBank.shared.models) m.name];
    expect(names, containsAll(['knot', 'shell', 'klein', 'gear', 'cars/taxi', 'pets/animal-giraffe', 'misc/pipe']));
    for (final m in TurntableBank.shared.models) {
      expect(m.hi.triangles, greaterThan(10), reason: m.name);
      expect(m.lo.triangles, lessThanOrEqualTo(m.hi.triangles), reason: m.name);
      // Every corner a number, and the shape fitted: two units at its longest.
      expect(m.hi.pos.every((x) => x.isFinite && x.abs() <= 1.0001), isTrue, reason: m.name);
    }
  });

  for (final (scene, at) in const [
    ('drift', Duration(seconds: 5)),
    ('fluid', Duration(seconds: 34)),
    ('veins', Duration(seconds: 66)),
    ('toon', Duration(seconds: 50)),
    ('flash', Duration(seconds: 40)),
    ('echo', Duration(seconds: 42)),
    ('fold', Duration(seconds: 44)),
    ('blocks', Duration(seconds: 40)),
    ('kinetic', Duration(seconds: 36)),
    ('siebenschlaefer', Duration(seconds: 40)),
    ('turntable', Duration(seconds: 40)),
  ]) {
    testWidgets('the stage: $scene', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final feed = DemoShowFeed(scenes: kit.book.metas);
      addTearDown(feed.dispose);
      // A few frames of the record, by hand, so the director has something to go
      // on; then the scene held on.
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 16 * i)), elapsed: at + Duration(milliseconds: 16 * i));
      }
      feed.director.choose(scene);
      feed.tick(t0.add(const Duration(milliseconds: 200)), elapsed: at + const Duration(milliseconds: 200));
      // Past the dissolve into it.
      for (var i = 1; i <= 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 200 + 300 * i)), elapsed: at + Duration(milliseconds: 200 + 300 * i));
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
      // A simulation needs frames to become anything: the record moves on under it.
      final frames = kit.book[scene]!.layers.any((l) => l.sim != null) ? 90 : 4;
      for (var i = 0; i < frames; i++) {
        feed.tick(t0.add(Duration(milliseconds: 2600 + 16 * i)), elapsed: at + Duration(milliseconds: 2600 + 16 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (out != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/show-$scene.png').writeAsBytes(png!.buffer.asUint8List());
        });
      }
      expect(err, isNull);
    });
  }
}
