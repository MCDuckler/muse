// The show's page as pictures, at two widths, written out as PNGs under SHOTS=<dir>;
// without SHOTS it only checks the page lays out without an overflow.
//
//   SHOTS=/tmp/shots flutter test test/shots/show_room_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/ui/show/show_room.dart';
import 'package:muse/src/ui/show/stage_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_audio.dart';

Future<void> _font(String family, List<String> files) async {
  final here = [for (final f in files) if (File(f).existsSync()) f];
  if (here.isEmpty) return;
  final l = FontLoader(family);
  for (final f in here) {
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}

class QuietMixer extends Mixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {}
  @override
  Future<void> setEq(Deck deck, EqSet eq) async {}
  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

void main() {
  final out = Platform.environment['SHOTS'];
  late Booth booth;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    const f = 'assets/fonts';
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/.local/flutter';
    final m = '$flutter/bin/cache/artifacts/material_fonts';
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('PermanentMarker', ['$f/PermanentMarker.ttf']);
    for (final (family, file) in const [
      ('BebasNeue', 'BebasNeue-Regular.ttf'),
      ('Orbitron', 'Orbitron.ttf'),
      ('Bungee', 'Bungee-Regular.ttf'),
      ('PressStart2P', 'PressStart2P-Regular.ttf'),
      ('Monoton', 'Monoton-Regular.ttf'),
      ('RubikMonoOne', 'RubikMonoOne-Regular.ttf'),
      ('Righteous', 'Righteous-Regular.ttf'),
      ('Syne', 'Syne.ttf'),
      ('InstrumentSerif', 'InstrumentSerif-Regular.ttf'),
    ]) {
      await _font(family, ['$f/$file']);
    }
    await _font('MaterialIcons', ['$m/MaterialIcons-Regular.otf']);
    await _font('Roboto', ['$m/Roboto-Regular.ttf']);
    await StageKit.load();
  });

  // The booth is made outside the test's fake clock (its init does real work).
  setUp(() async {
    JustAudioPlatform.instance = FakeJustAudio();
    booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: QuietMixer(), showStore: MemoryShowStore());
    await booth.init();
    await booth.show.ready();
  });

  tearDown(() => booth.dispose());

  for (final (w, h) in const [(1600.0, 900.0), (1280.0, 720.0), (1920.0, 1080.0)]) {
    testWidgets('the show page at ${w.round()}', (tester) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      FlutterErrorDetails? err;
      final was = FlutterError.onError;
      FlutterError.onError = (d) {
        // Said at once: a failing expect() under an override hides it otherwise.
        debugPrint('show page shot: ${d.exceptionAsString()}\n${d.stack}');
        err ??= d;
      };
      final show = booth.show;
      // A night's plan: a few scenes, three backgrounds, some looks judged.
      var plan = ShowPlan.shipped;
      for (final s in ['siebenschlaefer', 'fold', 'echo', 'lyrics', 'veins', 'fluid', 'drift', 'flash', 'flock', 'turntable']) {
        plan = plan.withScene(s, muted: true);
      }
      for (final g in comboGrounds) {
        if (!const {'black', 'white', 'milk'}.contains(g)) plan = plan.withShared(PlanAxis.ground, g, muted: true);
      }
      plan = plan
          .withScene('type3d', level: 0.75)
          .withScene('glide', level: 1 / 3)
          .withScene('kinetic', level: 1 / 3)
          .withScene('blocks', level: 1 / 3)
          .withCell('dance-art', cellKey(style: 'ascii', ground: 'white', mask: 'none'), 0)
          .withCell('dance-art', cellKey(style: 'dither', ground: 'white'), 0)
          .withCell('dance-art', cellKey(style: 'plain', ground: 'milk'), 2)
          .withCell('dance-art', cellKey(style: 'lines', ground: 'milk'), 0.5)
          .withIn('dance-art', PlanAxis.style, 'disco', muted: true)
          .withIn('dance-art', PlanAxis.style, 'viewports', muted: true);
      show.setPlan(plan);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        // The whole app in the shot, so a card (a dialog over the page) is in it too.
        builder: (context, child) => RepaintBoundary(key: const ValueKey('shot'), child: child),
        home: Scaffold(body: ShowRoom(booth: booth)),
      ));
      for (var i = 0; i < 20 && find.text('SCENES').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 300));
      Future<void> shot(String name) async {
        if (out == null) return;
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
        });
      }

      // The stills, read off the assets in real time.
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      Future<void> moment() async {
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      Future<void> tap(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f);
        await tester.pump();
      }

      final page = find.byKey(const ValueKey('scene page'));

      // What is on: the plain dancer on MilkDrop, held; then MilkDrop under and an
      // effect always on as well.
      show.play(const Combo(ground: 'milk', scene: 'dance-art', style: 'plain', mix: Mix.contrast));
      show.tick(DateTime.now());
      await settle();
      expect(find.text('NEVER THIS'), findsOneWidget);
      await shot('show-room-${w.round()}');
      show.holdGround('milk');
      show.holdFx(Fx.mosh);
      await tester.pump();
      await shot('show-room-${w.round()}-holds');
      show.letGoAll();
      await tester.pump();
      // The dancer's page: its styles, then its looks.
      await tap(find.byTooltip('Its page: Dancer'));
      await settle();
      await settle();
      await shot('show-room-${w.round()}-dancer');
      await tester.dragUntilVisible(find.text('ITS LOOKS'), page, const Offset(0, -300));
      await tester.drag(page, const Offset(0, -120));
      await settle();
      await settle();
      await shot('show-room-${w.round()}-looks');
      // A square's menu, and its masks and blends.
      final square = find.byKey(const ValueKey('look:ascii|white'));
      await tester.ensureVisible(square);
      await tester.tap(square, buttons: kSecondaryButton);
      await moment();
      await shot('show-room-${w.round()}-menu');
      await tester.tap(find.text('Each mask, blend and effect…'));
      await moment();
      await settle();
      await settle();
      await shot('show-room-${w.round()}-variants');
      await tester.tap(find.text('Done'));
      await moment();
      // Kinetic with its own backgrounds.
      show.setPlan(show.pool.plan.withOwn('kinetic', PlanAxis.ground, true));
      await tap(find.text('ROTATION').last);
      await tap(find.byTooltip('Its page: Kinetic'));
      await settle();
      await settle();
      await shot('show-room-${w.round()}-kinetic');
      // The 3D text's page, down to its words.
      await tap(find.text('ROTATION').last);
      await tap(find.byTooltip('Its page: 3D Text'));
      await tester.dragUntilVisible(find.text('LINES'), page, const Offset(0, -300));
      await settle();
      await shot('show-room-${w.round()}-text');
      await tap(find.text('ROTATION').last);
      // The rotation's lower part: what each background takes, the effects' knobs.
      // (Two lists side by side when wide, one when not: the one that holds it.)
      final rotation = find.byKey(const ValueKey('rotation shared'));
      await tester.dragUntilVisible(find.text('WHAT EACH BACKGROUND TAKES'), rotation, const Offset(0, -300));
      await tap(find.text('WHAT EACH BACKGROUND TAKES'));
      await tester.dragUntilVisible(find.text('THEIR KNOBS'), rotation, const Offset(0, -200));
      await tap(find.text('THEIR KNOBS'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.drag(rotation, const Offset(0, -260));
      await tester.pump(const Duration(milliseconds: 200));
      await shot('show-room-${w.round()}-rotation-more');
      // The settings, MilkDrop, the faves.
      await tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('THE FINISH'), findsOneWidget);
      await shot('show-room-${w.round()}-settings');
      await tap(find.text('MILKDROP'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 300));
      await shot('show-room-${w.round()}-milk');
      await tap(find.text('FAVES'));
      await tester.pump(const Duration(milliseconds: 300));
      await shot('show-room-${w.round()}-faves');
      FlutterError.onError = was;
      expect(err, isNull, reason: err?.exceptionAsString());
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
  }
}
