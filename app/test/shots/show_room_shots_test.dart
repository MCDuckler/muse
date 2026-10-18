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
      FlutterError.onError = (d) => err ??= d;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: ShowRoom(booth: booth))),
      ));
      for (var i = 0; i < 20 && find.text('GROUND').evaluate().isEmpty; i++) {
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
      await shot('show-room-${w.round()}');
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
