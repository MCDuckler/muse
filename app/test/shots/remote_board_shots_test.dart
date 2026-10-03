// Pictures of a desk's board on another screen, being changed there:
// `flutter test test/shots/remote_board_shots_test.dart` with SHOTS=<dir> in the
// environment writes PNGs there. Without it, it checks the page builds — the pads,
// the picked pad's settings and the library — at an iPad's and a phone's size.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/remote_board.dart';
import 'package:muse/src/ui/booth/board/board_pad.dart';
import 'package:muse/src/ui/booth/board/remote_board_page.dart';
import 'package:muse/src/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['SHOTS'];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    const f = 'assets/fonts';
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/.local/flutter';
    final m = '$flutter/bin/cache/artifacts/material_fonts';
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('MaterialIcons', ['$m/MaterialIcons-Regular.otf']);
    await _font('Roboto', ['$m/Roboto-Regular.ttf']);
  });

  for (final (w, h) in const [(1180.0, 820.0), (390.0, 844.0)]) {
    final phone = w < 700;
    testWidgets('a desk\'s board at ${w.round()}x${h.round()}, changed from here', (tester) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final wire = _Wire();
      final remote = RemoteBoard.over(const DeviceInfo(id: 7, name: 'The desk', live: true), wire);
      final app = AppState()..api = ApiClient(baseUrl: 'http://example.invalid');
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: MuseTheme.dark(),
          builder: (context, child) => RepaintBoundary(key: const ValueKey('shot'), child: child ?? const SizedBox()),
          home: RemoteBoardPage(remote: remote),
        ),
      ));
      // The desk says its board (and that it takes changes), then — asked — its library.
      wire.down.add(jsonEncode(_board()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(wire.sent.any((l) => l.contains('library?')), isTrue, reason: 'no server here: the desk is asked');
      wire.down.add(jsonEncode(_library()));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(remote.editable, isTrue);
      // A pad picked for its settings.
      final pad = find.byType(BoardPad).at(1);
      if (phone) {
        await tester.longPress(pad);
      } else {
        await tester.tap(pad, buttons: kSecondaryButton);
      }
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('PAD 2 · BANK A'), findsOneWidget);
      if (!phone) expect(find.text('HOUSE'), findsOneWidget, reason: 'the library beside the pads');
      if (out != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/remote-board-${w.round()}.png').writeAsBytes(png!.buffer.asUint8List());
        });
      }
      // The page lets the board go with itself.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
}

Map<String, dynamic> _board() {
  final pads = <PadSpec?>[
    const PadSpec(sampleId: 501, name: 'AIR HORN', colour: PadColour.orange),
    const PadSpec(sampleId: 502, name: 'VINE BOOM', colour: PadColour.violet),
    const PadSpec(sampleId: 503, name: 'YEAH!', colour: PadColour.accent),
    const PadSpec(sampleId: 504, name: 'REWIND', colour: PadColour.a, choke: 1),
    const PadSpec(sampleId: 505, name: 'SIREN', colour: PadColour.orange, mode: PadMode.hold),
  ];
  final doc = BoardDoc.empty();
  for (final (i, p) in pads.indexed) {
    doc.banks[0].pads[i] = p;
  }
  String shape(int seed) => base64Encode([for (var i = 0; i < 128; i++) (60 + 190 * ((i * (seed + 5)) % 13) / 12).round()]);
  return {
    't': 'board',
    'edits': 1,
    'doc': doc.toJson(),
    'bank': 0,
    'light': false,
    'peaks': {for (final p in pads) '${p!.sampleId}': shape(p.sampleId)},
    'pads': [],
  };
}

Map<String, dynamic> _library() {
  var id = 500;
  Map<String, dynamic> s(String group, String name, int ms) =>
      {'id': ++id, 'name': name, 'duration_ms': ms, 'group': group};
  return {
    't': 'library',
    'own': [],
    'house': [
      s('Horns & sirens', 'Air horn (canned, single blast)', 1610),
      s('Meme classics', 'Vine boom', 1170),
      s('Hype drops', 'Lil Jon — YEAH!', 1570),
      s('DJ tools', 'DJ rewind', 2640),
      s('Horns & sirens', 'Police siren (wail)', 12900),
      s('Meme classics', 'Bruh', 600),
    ],
  };
}

/// A wire held in the hand: what the desk would say, put down it; what the screen
/// says, kept.
class _Wire extends RemoteLink {
  final down = StreamController<String>.broadcast();
  final sent = <String>[];

  @override
  Stream<String> get lines => down.stream;

  @override
  void send(String line) => sent.add(line);

  @override
  Future<void> close() => down.close();

  @override
  String get kind => 'LAN';
}

Future<void> _font(String family, List<String> files) async {
  final here = [for (final f in files) if (File(f).existsSync()) f];
  if (here.isEmpty) return;
  final l = FontLoader(family);
  for (final f in here) {
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}
