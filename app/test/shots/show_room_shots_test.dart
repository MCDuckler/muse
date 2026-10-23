// The show's page as pictures, at two widths, written out as PNGs under SHOTS=<dir>;
// without SHOTS it only checks the page lays out without an overflow.
//
//   SHOTS=/tmp/shots flutter test test/shots/show_room_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_combos.dart';
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/ui/show/show_dance.dart' show DanceAssets;
import 'package:muse/src/ui/show/show_moves.dart';
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

  for (final (w, h) in const [(1600.0, 900.0), (1280.0, 720.0)]) {
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
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        // The whole app in the shot, so a card (a dialog over the page) is in it too.
        builder: (context, child) => RepaintBoundary(key: const ValueKey('shot'), child: child),
        home: Scaffold(body: ShowRoom(booth: booth)),
      ));
      for (var i = 0; i < 20 && find.text('BACKGROUND').evaluate().isEmpty; i++) {
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

      // The selector, following the stage; the rules tab it opens on.
      expect(find.text('RULES'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(find.text('HOLD'), findsOneWidget);
      // The stills, read off the assets in real time.
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      // One whole combination picked: the plain dancers on MilkDrop.
      Future<void> pick(String word) async {
        final f = find.text(word).last;
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f);
        await tester.pump();
      }

      await pick('Dancer');
      await settle();
      for (final w in ['plain', 'MilkDrop', 'No mask', 'Normal']) {
        await pick(w);
      }
      await settle();
      expect(find.text('PLAY IT'), findsOneWidget);
      await shot('show-room-${w.round()}');
      // The same on white.
      await pick('White');
      await settle();
      await shot('show-room-${w.round()}-white');
      // Silhouettes through the keyhole on MilkDrop, and a shape in contrast on white.
      for (final w in ['mono', 'MilkDrop', 'Keyhole']) {
        await pick(w);
      }
      await settle();
      await shot('show-room-${w.round()}-keyhole');
      for (final w in ['Kinetic', 'As drawn', 'White', 'No mask', 'Contrast']) {
        await pick(w);
      }
      await settle();
      await shot('show-room-${w.round()}-contrast');
      // Snapshots: two kept here, one changed since.
      booth.show.snapshots.saveAs('Calm night');
      booth.show.setPool(booth.show.pool.withRule(const ComboRule(grounds: {'milk'}), 4));
      booth.show.snapshots.saveAs('Club, MilkDrop heavy');
      booth.show.setPool(booth.show.pool.withRule(const ComboRule(scenes: {'flash'}), 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Club, MilkDrop heavy •'), findsOneWidget);
      await shot('show-room-${w.round()}-snapshots');
      // A batch: the turntable, any style, any background, the keyhole, added or
      // screened — one rule, switched off; and the map of the rotation.
      for (final w in ['Turntable', 'Keyhole', 'Add']) {
        await pick(w);
      }
      for (final i in [1, 2]) {
        final any = find.text('ANY').at(i);
        await tester.ensureVisible(any);
        await tester.pump();
        await tester.tap(any);
        await tester.pump();
      }
      await tester.ensureVisible(find.text('Screen').last);
      await tester.pump();
      await tester.longPress(find.text('Screen').last);
      await tester.pump();
      await settle();
      expect(find.textContaining('Turntable × any style × any background × Keyhole × Add, Screen'), findsWidgets);
      await shot('show-room-${w.round()}-batch');
      await tester.tap(find.text('MAP'));
      await tester.pump(const Duration(milliseconds: 300));
      await shot('show-room-${w.round()}-map');
      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(booth.show.pool.rules.last.pattern, '*|turntable|*|keyhole|add,screen');
      await shot('show-room-${w.round()}-map-off');
      // The camera: the dancers in ascii, never through the fisheyes; the map with the
      // camera across.
      for (final w in ['Dancer', 'ascii', 'Fisheye']) {
        await pick(w);
      }
      await tester.ensureVisible(find.text('Fisheye floor').last);
      await tester.pump();
      await tester.longPress(find.text('Fisheye floor').last);
      await tester.pump();
      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('CAMERA').at(1));
      await tester.pump(const Duration(milliseconds: 300));
      await settle();
      await shot('show-room-${w.round()}-camera');
      await tester.tap(find.text('RULES'));
      await tester.pump(const Duration(milliseconds: 300));
      // A rule with ANY: every plain-dancer combination on MilkDrop at twice the weight.
      booth.show.setPool(booth.show.pool
          .withRule(const ComboRule(grounds: {'milk'}, scenes: {'dance-art'}, styles: {'plain'}), 2)
          .withRule(const ComboRule(grounds: {'black'}, masks: {Mask.keyhole}), 1));
      await tester.pump();
      expect(find.text('YOURS'), findsOneWidget);
      await shot('show-room-${w.round()}-rules');
      // The 3D text's tab.
      await tester.tap(find.text('TEXT'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('LINES'), findsOneWidget);
      await shot('show-room-${w.round()}-text');
      // The settings: the finish, the director, the stage's numbers.
      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('THE FINISH'), findsOneWidget);
      await shot('show-room-${w.round()}-settings');
      // MilkDrop, in the page: the panel with no helper (a test has none).
      await tester.tap(find.text('MILKDROP'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('New preset'), findsOneWidget);
      await shot('show-room-${w.round()}-milk');
      // The dancers' tab, with the moves browser (the bank read in this zone).
      await tester.runAsync(() => DanceAssets.of('chris').loaded);
      await tester.tap(find.text('DANCERS'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (find.byType(MoveStrip).evaluate().isNotEmpty) {
        await tester.tap(find.byType(MoveStrip).first);
        await tester.pump(const Duration(milliseconds: 200));
      }
      await shot('show-room-${w.round()}-dancers');
      FlutterError.onError = was;
      expect(err, isNull, reason: err?.exceptionAsString());
      await tester.pumpWidget(const SizedBox());
    });
  }
}
