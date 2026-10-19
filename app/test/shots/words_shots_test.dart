// The words, face by face, as pictures: the made-up record (show_demo.dart) singing
// in every section, each face forced, drawn at 1280×720 and written out as PNGs
// under SHOTS=<dir>; and nothing where nothing is sung. Without SHOTS it checks that
// every face draws, with the shader, and is not a black frame.
//
//   SHOTS=/tmp/shots flutter test test/shots/words_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/ui/show/scene.dart';
import 'package:muse/src/ui/show/show_canvas.dart';
import 'package:muse/src/ui/show/show_words.dart';
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

  setUpAll(() async {
    const f = 'assets/fonts';
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('PermanentMarker', ['$f/PermanentMarker.ttf']);
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('BebasNeue', ['$f/BebasNeue-Regular.ttf']);
    await _font('InstrumentSerif', ['$f/InstrumentSerif-Regular.ttf', '$f/InstrumentSerif-Italic.ttf']);
    await _font('Syne', ['$f/Syne.ttf']);
    kit = await StageKit.load();
    DemoShowFeed.singAll = true;
  });

  tearDownAll(() => DemoShowFeed.singAll = false);
  tearDown(() => WordsSim.forceStyle = null);

  test('the lyrics scene is there, with its finish', () {
    final s = kit.book['lyrics']!;
    expect(s.layers.single.sim, 'words');
    expect(s.meta.needs, ['words']);
    expect(kit.programs.sims.containsKey('words_fx'), isTrue);
    expect(s.text.lyrics, isFalse, reason: 'the figure draws the words itself');
    expect(s.text.title, isFalse, reason: 'nothing but the lyrics');
  });

  // The demo sings in every section but the intro (singAll); the build starts at
  // bar 8 — 15 s in at 128 bpm — the first drop at bar 16, 30 s. Nothing in the intro.
  for (final (style, at) in [
    (WordsStyle.poster, const Duration(seconds: 33)),
    (WordsStyle.serif, const Duration(seconds: 17)),
    (WordsStyle.grotesk, const Duration(seconds: 35)),
    (WordsStyle.wide, const Duration(seconds: 37)),
    (WordsStyle.mono, const Duration(seconds: 19)),
    (WordsStyle.marker, const Duration(seconds: 21)),
    (WordsStyle.light, const Duration(seconds: 23)),
    (null, const Duration(seconds: 5)),
  ]) {
    testWidgets('the words: ${style?.name ?? 'nothing'}', timeout: const Timeout(Duration(minutes: 4)), (tester) async {
      WordsSim.forceStyle = style ?? WordsStyle.poster;
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final feed = DemoShowFeed(scenes: kit.book.metas, looks: kit.book.looks);
      addTearDown(feed.dispose);
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 16 * i)), elapsed: at + Duration(milliseconds: 16 * i));
      }
      feed.director.choose('lyrics');
      feed.director.locked = true;
      for (var i = 0; i <= 8; i++) {
        feed.tick(t0.add(Duration(milliseconds: 200 + 300 * i)), elapsed: at + Duration(milliseconds: 200 + 300 * i));
      }
      expect(feed.state.scene, 'lyrics');

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
            child: ShowCanvas(feed: feed, book: kit.book, programs: kit.programs, scale: 0.5),
          ),
        ),
      ));
      // A moment of the record under it: a line is sung. (Forty frames: the shader
      // runs on the CPU here, a frame takes a tenth of a second of the sim's own
      // clock, and a line left for ten seconds of it is stale and fades.)
      final began = DateTime.now();
      for (var i = 0; i < 40; i++) {
        feed.tick(t0.add(Duration(milliseconds: 2600 + 16 * i)), elapsed: at + Duration(milliseconds: 2600 + 16 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      var lit = 0;
      // ignore: avoid_print
      print('WORDS SHOT ${style?.name ?? 'nothing'}: ${DateTime.now().difference(began).inMilliseconds} ms for 40 frames');
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
        final image = await boundary.toImage();
        final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        for (var i = 0; i < raw.lengthInBytes; i += 4 * 97) {
          if (raw.getUint8(i) + raw.getUint8(i + 1) + raw.getUint8(i + 2) > 90) lit++;
        }
        if (out != null) {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/words-${style?.name ?? 'nothing'}.png').writeAsBytes(png!.buffer.asUint8List());
        }
      });
      FlutterError.onError = was;
      if (err != null) {
        // ignore: avoid_print
        print('WORDS SHOT ${style?.name ?? 'nothing'} threw: $err');
      }
      expect(err, isNull);
      if (style == null) {
        expect(lit, lessThan(20), reason: 'nothing sung, nothing set');
      } else {
        expect(lit, greaterThan(20), reason: 'a black frame');
      }
    });
  }
}
