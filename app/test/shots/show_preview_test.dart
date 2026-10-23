// Combinations drawn whole on the Flutter stage, full size, written out as PNGs: a
// look at a scene, a style, a background, a mask and a blend without the app.
//
//   PREVIEW='dance-art|crt|milk|none|normal;flock|crt|black|none|normal' \
//   PREVIEW_OUT=/tmp/preview [PREVIEW_SIZE=1280x720] [PREVIEW_AT=40] \
//   [PREVIEW_TYPE3D='{"looks":["chrome"],"motions":["spin"]}'] \
//   flutter test test/shots/show_preview_test.dart
//
// Without PREVIEW it is skipped. A frame is taken a few seconds into the scene, at
// PREVIEW_AT seconds into the demo record (40: its first drop).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_combos.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/state/show/show_type3d.dart';
import 'package:muse/src/ui/show/scene.dart' show SceneBookLooks;
import 'package:muse/src/ui/show/show_canvas.dart';
import 'package:muse/src/ui/show/show_dance.dart' show DanceAssets;
import 'package:muse/src/ui/show/stage_kit.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final want = Platform.environment['PREVIEW'];
  final out = Platform.environment['PREVIEW_OUT'] ?? '/tmp/preview';
  final size = (Platform.environment['PREVIEW_SIZE'] ?? '1280x720').split('x').map(int.parse).toList();
  final at = Duration(seconds: int.parse(Platform.environment['PREVIEW_AT'] ?? '40'));
  late StageKit kit;

  setUpAll(() async {
    if (want == null) return;
    const f = 'assets/fonts';
    for (final (family, files) in const [
      ('Archivo', ['$f/Archivo.ttf']),
      ('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']),
      ('PermanentMarker', ['$f/PermanentMarker.ttf']),
      ('Manrope', ['$f/Manrope.ttf']),
      ('BebasNeue', ['$f/BebasNeue-Regular.ttf']),
      ('InstrumentSerif', ['$f/InstrumentSerif-Regular.ttf', '$f/InstrumentSerif-Italic.ttf']),
      ('Syne', ['$f/Syne.ttf']),
      ('Orbitron', ['$f/Orbitron.ttf']),
      ('Bungee', ['$f/Bungee-Regular.ttf']),
      ('PressStart2P', ['$f/PressStart2P-Regular.ttf']),
      ('Monoton', ['$f/Monoton-Regular.ttf']),
      ('RubikMonoOne', ['$f/RubikMonoOne-Regular.ttf']),
      ('Righteous', ['$f/Righteous-Regular.ttf']),
    ]) {
      await _font(family, files);
    }
    kit = await StageKit.load();
    Directory(out).createSync(recursive: true);
    stageSizeHeld = true;
    DemoShowFeed.singAll = true;
  });

  for (final spec in (want ?? '').split(';').where((s) => s.isNotEmpty)) {
    final p = spec.split('|');
    testWidgets('a preview: $spec', (tester) async {
      tester.view.physicalSize = Size(size[0].toDouble(), size[1].toDouble());
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (p[0].startsWith('dance')) await tester.runAsync(() => DanceAssets.of('chris').loaded);
      final feed = DemoShowFeed(scenes: kit.book.metas, looks: kit.book.looks);
      addTearDown(feed.dispose);
      final type3d = Platform.environment['PREVIEW_TYPE3D'];
      if (type3d != null) feed.macros = feed.macros.copyWith(type3d: TypeSpec.fromJson(jsonDecode(type3d)));
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 16 * i)), elapsed: at + Duration(milliseconds: 16 * i));
      }
      feed.director.play(Combo(
        ground: p.length > 2 ? p[2] : 'black',
        scene: p[0],
        style: p.length > 1 ? p[1] : 'raw',
        mask: p.length > 3 ? Mask.values.byName(p[3]) : Mask.none,
        mix: p.length > 4 ? Mix.values.byName(p[4]) : Mix.normal,
      ));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: const ValueKey('stage'),
          child: ColoredBox(color: Colors.black, child: ShowCanvas(feed: feed, book: kit.book, programs: kit.programs, scale: 1)),
        ),
      ));
      for (var i = 0; i < 150; i++) {
        feed.tick(t0.add(Duration(milliseconds: 1000 + 16 * i)), elapsed: at + Duration(milliseconds: 1000 + 16 * i));
        await tester.pump(const Duration(milliseconds: 16));
        // What a scene makes off the frame (the 3D type's field, its image) in real time.
        if (i % 15 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      }
      await tester.runAsync(() async {
        final img = await tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('stage'))).toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/${spec.replaceAll('|', '_')}.png').writeAsBytes(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
    }, skip: want == null);
  }
}
