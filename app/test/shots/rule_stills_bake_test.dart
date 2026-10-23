// The combination selector's stills (ui/show/show_room_kart.dart): one picture of
// every figure, and of every style of the dancers, the flock and the words, each on
// its own — the figure's layer as it goes into the blend (on a background, so with no
// setting of its own), coverage marks and all — at the moment of the made-up record
// (show_demo.dart) the stage shots use. The selector blends each with the background
// picked on the spot, with the stage's own blend.
//
//   BAKE_STILLS=1 flutter test test/shots/rule_stills_bake_test.dart
//
// writes assets/show/stills/<figure>.png and <figure>.<style>.png. Without
// BAKE_STILLS it is skipped (it takes minutes).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/camera_feed.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_combos.dart';
import 'package:muse/src/ui/show/scene.dart' show SceneBookLooks;
import 'package:muse/src/ui/show/show_canvas.dart';
import 'package:muse/src/ui/show/show_dance.dart' show DanceArt, DanceAssets;
import 'package:muse/src/ui/show/show_flock.dart' show FlockLook;
import 'package:muse/src/ui/show/show_meme.dart';
import 'package:muse/src/ui/show/show_turntable.dart';
import 'package:muse/src/ui/show/show_words.dart' show WordsStyle;
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

/// The size the stills are drawn at: the stage's working picture, so the marks are
/// the stage's own (a still scaled down would blur them).
const _w = 256, _h = 144;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bake = Platform.environment['BAKE_STILLS'] != null;
  const out = 'assets/show/stills';
  late StageKit kit;
  late ui.Image cover;

  setUpAll(() async {
    if (!bake) return;
    const f = 'assets/fonts';
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('PermanentMarker', ['$f/PermanentMarker.ttf']);
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('BebasNeue', ['$f/BebasNeue-Regular.ttf']);
    await _font('InstrumentSerif', ['$f/InstrumentSerif-Regular.ttf', '$f/InstrumentSerif-Italic.ttf']);
    await _font('Syne', ['$f/Syne.ttf']);
    await _font('Orbitron', ['$f/Orbitron.ttf']);
    kit = await StageKit.load();
    await MemeBank.of('siebenschlaefer').decodeAll();
    await TurntableBank.shared.warm();
    final codec = await ui.instantiateImageCodec(await File('assets/brand/ball.webp').readAsBytes());
    cover = (await codec.getNextFrame()).image;
    // A camera's picture for the room (Echo, Fold) to fold.
    final cam = await ui.instantiateImageCodec(await File('assets/show/siebenschlaefer/photos/03.webp').readAsBytes());
    CameraFeed.shared.frame = (await cam.getNextFrame()).image;
    CameraFeed.shared.prev = CameraFeed.shared.frame;
    Directory(out).createSync(recursive: true);
    // The stills at the size asked for, however slow the test's frames.
    stageSizeHeld = true;
    // The words sing in every section, so there is a line to draw.
    DemoShowFeed.singAll = true;
  });

  // Every figure by the first of its scenes — the styles of the three that have
  // them, the figure as drawn for the rest; MilkDrop alone (no figure) is its own
  // picture.
  const figures = {
    Figure.dancers: 'dance-art',
    Figure.birds: 'flock',
    Figure.words: 'lyrics',
    Figure.turntable: 'turntable',
    Figure.flash: 'flash',
    Figure.kinetic: 'kinetic',
    Figure.blocks: 'blocks',
    Figure.glide: 'glide',
    Figure.fluid: 'fluid',
    Figure.veins: 'veins',
    Figure.field: 'drift',
    Figure.room: 'echo',
    Figure.meme: 'siebenschlaefer',
    Figure.type3d: 'type3d',
  };
  // The dancers' fluid and their viewports are the native stage's alone: no still
  // (the grid says so).
  final styles = {
    Figure.dancers: [for (final a in DanceArt.values) if (a != DanceArt.fluid && a != DanceArt.viewports) a.name],
    Figure.birds: [for (final l in FlockLook.values) l.name],
    Figure.words: [for (final w in WordsStyle.values) w.name],
  };
  final jobs = [
    for (final e in figures.entries)
      if (styles[e.key] case final own?) ...[for (final s in own) (e.key, e.value, s as String?)] else (e.key, e.value, null as String?),
  ];

  for (final (kind, scene, style) in jobs) {
    final name = style == null ? kind.name : '${kind.name}.$style';
    testWidgets('a still: $name', skip: !bake, (tester) async {
      tester.view.physicalSize = Size(_w * 2.0, _h * 2.0);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (kind == Figure.dancers) await tester.runAsync(() => DanceAssets.of('chris').loaded);
      final feed = DemoShowFeed(scenes: kit.book.metas, looks: kit.book.looks);
      addTearDown(feed.dispose);
      // Into the first drop of the record, the scene held on.
      const at = Duration(seconds: 40);
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 16 * i)), elapsed: at + Duration(milliseconds: 16 * i));
      }
      // On white (a background: the figure without a setting of its own), as drawn.
      final st = style ?? 'raw';
      feed.director.play(Combo(ground: isWorld(scene, kind, st) ? ownGround : 'white', scene: scene, style: st));
      for (var i = 1; i <= 9; i++) {
        feed.tick(t0.add(Duration(milliseconds: 300 * i)), elapsed: at + Duration(milliseconds: 300 * i));
      }
      expect(feed.state.scene, scene);
      ui.Image? last;
      stageFigureTap = (s, st, img) {
        if (s.id != scene) return;
        last?.dispose();
        last = img.clone();
      };
      addTearDown(() {
        stageFigureTap = null;
        last?.dispose();
      });
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: Colors.black,
          child: ShowCanvas(feed: feed, book: kit.book, programs: kit.programs, scale: 0.5, covers: {1: cover}),
        ),
      ));
      // A simulation needs frames to become anything; the slime mould the most.
      final frames = kind == Figure.veins ? 480 : (kit.book[scene]!.layers.any((l) => l.sim != null) ? 120 : 4);
      for (var i = 0; i < frames; i++) {
        feed.tick(t0.add(Duration(milliseconds: 3000 + 16 * i)), elapsed: at + Duration(milliseconds: 3000 + 16 * i));
        await tester.pump(const Duration(milliseconds: 16));
        // The slime mould's picture is decoded off the frame: real time for it.
        if (kind == Figure.veins && i % 20 == 19) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        // The 3D type's field is set off the frame.
        if (kind == Figure.type3d && i % 15 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      }
      final img = last;
      expect(img, isNotNull, reason: 'the stage drew $scene');
      expect((img!.width, img.height), (_w, _h));
      await tester.runAsync(() async {
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
