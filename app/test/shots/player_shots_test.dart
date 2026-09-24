// Pictures of the player, for looking at: `flutter test test/shots/player_shots_test.dart`
// with SHOTS=<dir> in the environment writes PNGs there. Without it, nothing is
// written and it only checks the screen builds at a phone's and a desk's size.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/ui/now_playing.dart';
import 'package:muse/src/ui/theme.dart';
import 'package:provider/provider.dart';
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

TrackTiming _timing(double bpm) {
  final beat = 60000 / bpm;
  final beats = [for (var t = 900.0; t < 244000; t += beat) t.round()];
  return TrackTiming(
    durationMs: 245000,
    bpm: bpm,
    beats: beats,
    downbeats: [for (var i = 0; i < beats.length; i += 4) beats[i]],
    camelot: '8A',
    key: 'A minor',
    cues: MixCues(firstDownbeatMs: beats.first, mixInMs: beats[64], mixOutMs: beats[beats.length * 4 ~/ 5], soundEndMs: 243000),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (c) async => null);
  final out = Platform.environment['SHOTS'];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    const f = 'assets/fonts';
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/.local/flutter';
    final m = '$flutter/bin/cache/artifacts/material_fonts';
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('BodoniModa', ['$f/BodoniModa.ttf', '$f/BodoniModa-Italic.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('PermanentMarker', ['$f/PermanentMarker.ttf']);
    await _font('MaterialIcons', ['$m/MaterialIcons-Regular.otf']);
    await _font('Roboto', ['$m/Roboto-Regular.ttf']);
  });

  for (final (name, w, h) in const [('phone', 390.0, 844.0), ('desk', 1440.0, 900.0)]) {
    for (final dark in [true, false]) {
      for (final playing in [true, false]) {
        final state = '${dark ? 'dark' : 'light'}-${playing ? 'playing' : 'paused'}';
        testWidgets('the player on a $name, $state', (tester) async {
          JustAudioPlatform.instance = FakeJustAudio();
          useThisClientInstead(MockClient((r) async => r.url.path.contains('stream-key')
              ? http.Response('{"key": "k", "expires_at": 99999999999}', 200)
              : http.Response('{}', 200)));
          SharedPreferences.setMockInitialValues({});
          final app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
          tester.view.physicalSize = Size(w, h);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            app.player = PlayerService(app.api);
            await app.player!.init();
            final queue = Queue.fromJson({
              'id': 1, 'name': 'Friday warm-up', 'cursor_index': 1, 'position_ms': 0, 'rev': 1,
              'items': [
                for (final (i, (t, a, c)) in const [
                  ('Blue (Da Ba Dee)', 'Eiffel 65', '#1f4f7a'),
                  ('Glamorous (Janis Euro Dance Edit)', 'Fergie', '#8a2a4a'),
                  ('Sandstorm', 'Darude', '#c0392b'),
                ].indexed)
                  {'id': 10 + i, 'title': t, 'artists': [a], 'duration_ms': 245000, 'state': 'ready',
                   'stream_url': '/tracks/${10 + i}/stream', 'pos': i, 'cover_color': c},
              ],
            });
            await app.player!.loadQueue(queue);
            for (var i = 0; i < 3; i++) {
              app.player!.timing.put(10 + i, _timing(128));
            }
            if (playing) await app.player!.playAt(1).timeout(const Duration(seconds: 10));
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
          await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: app,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: dark ? MuseTheme.dark() : MuseTheme.light(),
              home: const RepaintBoundary(key: ValueKey('shot'), child: NowPlayingScreen()),
            ),
          ));
          // Well into the record's arrival and the light's swing.
          for (var i = 0; i < 24; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          final err = tester.takeException();
          Future<void> shot(String suffix) => tester.runAsync(() async {
                final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
                final image = await boundary.toImage();
                final png = await image.toByteData(format: ui.ImageByteFormat.png);
                await File('$out/player-$name-$state$suffix.png').writeAsBytes(png!.buffer.asUint8List());
              });
          if (out != null) {
            await shot('');
            // A few more frames of the room, seconds apart: whether the light moves.
            if (name == 'phone' && dark && playing) {
              for (var f = 1; f <= 3; f++) {
                for (var i = 0; i < 25; i++) {
                  await tester.pump(const Duration(milliseconds: 100));
                }
                await shot('-f$f');
              }
            }
          }
          expect(err, isNull);
          await tester.runAsync(() async => app.player?.dispose());
          await tester.pumpWidget(const SizedBox());
        }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
      }
    }
  }
}
