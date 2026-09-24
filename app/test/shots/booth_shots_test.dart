// Pictures of the booth, for looking at: `flutter test test/shots/booth_shots_test.dart`
// with SHOTS=<dir> in the environment writes PNGs there. Without it, nothing is written
// and it only checks the room builds at a desk's size without overflowing.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/planner.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/ui/booth/desk/set_planner_page.dart';
import 'package:muse/src/ui/booth_page.dart';
import 'package:muse/src/ui/theme.dart';
import 'package:muse/src/worker/parts_jobs.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_audio.dart';

/// Loaded where the files are; left out where they are not — on a build machine whose
/// Flutter lives somewhere else, the room is still built and checked for overflow, in
/// the test font.
Future<void> _font(String family, List<String> files) async {
  final here = [for (final f in files) if (File(f).existsSync()) f];
  if (here.isEmpty) return;
  final l = FontLoader(family);
  for (final f in here) {
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}

Track _song(int id, String title, String artist, String colour) => Track.fromJson({
      'id': id,
      'title': title,
      'artists': [artist],
      'duration_ms': 245000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
      'cover_color': colour,
    });

TrackTiming _timing(double bpm, String camelot, int seed) {
  final beat = 60000 / bpm;
  final beats = [for (var t = 900.0; t < 244000; t += beat) t.round()];
  final r = math.Random(seed);
  return TrackTiming(
    durationMs: 245000,
    bpm: bpm,
    beats: beats,
    downbeats: [for (var i = 0; i < beats.length; i += 4) beats[i]],
    camelot: camelot,
    key: camelot == '8A' ? 'A minor' : 'D major',
    energy: [for (var i = 0; i < 120; i++) 80 + r.nextInt(170)],
    phrases: [for (var i = 0; i < beats.length; i += 64) beats[i]],
    drops: [beats[128], beats[beats.length * 3 ~/ 4]],
    cues: MixCues(firstDownbeatMs: beats.first, mixInMs: beats[64], mixOutMs: beats[beats.length * 4 ~/ 5], soundEndMs: 243000),
  );
}

({List<int> low, List<int> mid, List<int> high}) _bands(int seed) {
  final r = math.Random(seed);
  List<int> one(double scale) => [
        for (var i = 0; i < 1600; i++)
          ((0.35 + 0.65 * (math.sin(i / 90) * 0.5 + 0.5)) * (60 + r.nextInt(195)) * scale)
              .clamp(0, 255)
              .round(),
      ];
  return (low: one(1), mid: one(0.8), high: one(0.55));
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

  for (final (w, h) in const [(1600.0, 1000.0), (1280.0, 760.0), (1920.0, 1080.0)]) {
  for (final dark in [true]) {
    for (final state in ['empty', 'playing', if (w == 1600) 'mixing', if (w != 1920) 'parts', if (w != 1280) 'crate', 'plan', 'set', 'planner']) {
      testWidgets('the booth at ${w.round()}x${h.round()}, $state', (tester) async {
        JustAudioPlatform.instance = FakeJustAudio();
        useThisClientInstead(MockClient((r) async => r.url.path.contains('stream-key')
            ? http.Response('{"key": "k", "expires_at": 99999999999}', 200)
            : http.Response('{}', 200)));
        // The crate wide and the log folded, as a DJ leaves them.
        SharedPreferences.setMockInitialValues(state == 'crate'
            ? {'muse.booth.crateWide': true, 'muse.booth.logFolded': true}
            : state == 'plan'
                ? {'muse.booth.view': 'plan'}
                : state == 'set'
                    ? {'muse.booth.view': 'set'}
                    : {});
        final app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
        if (state == 'crate') {
          app.playlists = [
            for (final (i, n) in ['Favourites', 'Friday warm-up', 'Hardtekk crate', 'Eurodance', 'Peak time'].indexed)
              Playlist(id: 50 + i, name: n, kind: i == 0 ? 'favourites' : 'local', itemCount: 12 + i * 7, autoSplit: i == 2),
          ];
        }
        tester.view.physicalSize = Size(w, h);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // Made in the real zone: players made under the test's fake clock never hear
        // back from the engine while real work runs.
        late final b = app.booth;
        if (state != 'empty') await tester.runAsync(() async => b);
        if (state != 'empty') {
          // A queue for the crate: six records, their tempos and keys known.
          const names = [
            ('Hide and Seek (Laserleo Remix)', 'Imogen Heap', 149.9, '10A'),
            ('Let Me Live That Fantasy', 'Baron von Trax', 103.5, '6B'),
            ('Go Solo', 'Tekk', 84.5, '10B'),
            ('Blue (Da Ba Dee)', 'Eiffel 65', 128.0, '7A'),
            ('Better Off Alone', 'Alice Deejay', 137.0, '8A'),
            ('Sandstorm', 'Darude', 136.0, '9A'),
          ];
          await tester.runAsync(() async {
            app.player = PlayerService(app.api);
            await app.player!.init();
            final queue = Queue.fromJson({
              'id': 1, 'name': 'Tonight', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
              'items': [
                for (final (i, (t, a, _, _)) in names.indexed)
                  {'id': 10 + i, 'title': t, 'artists': [a], 'duration_ms': 245000, 'state': 'ready',
                   'stream_url': '/tracks/${10 + i}/stream', 'pos': i},
              ],
            });
            await app.player!.loadQueue(queue);
          });
          for (final (i, (_, _, bpm, key)) in names.indexed) {
            b.timing.put(10 + i, _timing(bpm, key, 10 + i));
          }
          final one = _song(1, 'Glamorous (Janis Euro Dance Edit)', 'Fergie', '#8a2a4a');
          final two = _song(2, 'Euro Dance (Arweenn Nostalgic Mix)', 'DJ Mangoo', '#1f4f7a');
          await tester.runAsync(() async {
            b.timing.put(1, _timing(147, '8A', 1));
            b.timing.put(2, _timing(149.5, '9A', 2));
            b.bands[1] = _bands(1);
            b.bands[2] = _bands(2);
            await (b.load(b.a, one, at: const Duration(seconds: 96))).timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('stuck: b.load(b.a, one, at: const Dur'));
            await (b.load(b.b, two, at: const Duration(seconds: 12))).timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('stuck: b.load(b.b, two, at: const Dur'));
            await (b.a.play()).timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('stuck: b.a.play()'));
            await (b.setCrossfader(0.35)).timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('stuck: b.setCrossfader(0.35)'));
            await (b.sync(b.b)).timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('stuck: b.sync(b.b)'));
            if (state == 'mixing') {
              b.note(BoothEventKind.auto, 'Auto DJ on · 7 records, normal');
              b.note(BoothEventKind.next, 'Next: Euro Dance (Arweenn Nostalgic Mix)', deck: b.b);
              b.note(BoothEventKind.plan, 'blend, 16 bars, from 3:12 · cued at 0:12', deck: b.b);
              b.note(BoothEventKind.mix, 'A into B · blend, 16 bars', deck: b.b);
              b.mixing = (kind: Transition.blend, from: 'A', to: 'B', bars: 16, k: 0.4);
            }
            if (state == 'set' || state == 'planner') {
              // The Auto DJ with the whole queue ahead of it: the set as a strip, and
              // the planner over the same records.
              for (final t in app.player!.items) {
                b.timing.put(t.id, _timing(t.id % 2 == 0 ? 128 : 130, t.id % 3 == 0 ? '8A' : '9A', t.id));
              }
              await b.auto.start([one, ...app.player!.items]).timeout(const Duration(seconds: 10));
              b.auto.setLocked(app.player!.items[2].id, true);
            }
            if (state == 'plan') {
              // The Auto DJ between the two, both in stems, the words known: its plan
              // laid out as it would lay it out.
              await b.auto.start([one, two]).timeout(const Duration(seconds: 10));
              b.a.stemmed = true;
              b.b.stemmed = true;
              final from = b.master, to = b.other(from);
              VocalMap voice(TrackTiming t, bool Function(int) sung, {List<int> hook = const []}) => VocalMap(
                    bars: [for (var i = 0; i < t.downbeats.length; i++) sung(i) ? 200 : 20],
                    timed: hook.isNotEmpty,
                    hook: hook.isEmpty ? null : (text: 'Euro dance, euro dance', at: hook),
                    lyrics: 'lrclib',
                  );
              b.auto.fromVoice = voice(from.timing!, (i) => i > 8 && i < 44 || i > 52 && i < 64);
              b.auto.toVoice = voice(to.timing!, (i) => i >= 16 && i < 40,
                  hook: [to.timing!.downbeats[16], to.timing!.downbeats[32]]);
              b.auto.options = Planner.options(
                from: MixSide(timing: from.timing!, vocals: b.auto.fromVoice, stems: true),
                to: MixSide(timing: to.timing!, vocals: b.auto.toVoice, stems: true),
                random: math.Random(3),
              );
              final chosen = b.auto.options.firstWhere((o) => o.kind == Transition.stemBlend,
                  orElse: () => b.auto.options.first);
              b.auto.planned = chosen;
              b.auto.plan = (kind: chosen.kind, bars: chosen.bars);
              b.auto.goesAt = Duration(milliseconds: from.timing!.downbeats[56]);
              b.auto.comesInAt = Duration(milliseconds: to.timing!.downbeats[4]);
            }
            if (state == 'parts') {
              // Deck A's record being taken apart, two of the queue waiting behind it,
              // one done a minute ago and one that could not be.
              final ready = partsJobs.add(12, track: app.player!.items[2]);
              partsJobs.stage(12, PartsStage.separating);
              ready.started = DateTime.now().subtract(const Duration(seconds: 158));
              partsJobs.stage(12, PartsStage.ready);
              partsJobs.add(13, track: app.player!.items[3]);
              partsJobs.stage(13, PartsStage.separating);
              partsJobs.stage(13, PartsStage.failed, error: 'ffmpeg could not read it');
              partsJobs.add(1, track: one, parts: ['instrumental', 'drums', 'music', 'vocals']);
              partsJobs.stage(1, PartsStage.separating);
              partsJobs.of(1)!.stageStarted = DateTime.now().subtract(const Duration(seconds: 40));
              partsJobs.progress(1, 0.42);
              for (final id in [10, 11]) {
                partsJobs.add(id, track: app.player!.items[id - 10], stage: PartsStage.waiting);
              }
            }
          });
        }
        await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? MuseTheme.dark() : MuseTheme.light(),
            home: RepaintBoundary(
                key: const ValueKey('shot'),
                child: state == 'planner' ? SetPlannerPage(booth: app.booth) : const BoothPage()),
          ),
        ));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (state == 'parts') {
          // The bar's light opens the list.
          await tester.tap(find.text('42%'));
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.text('NOW'), findsOneWidget);
          expect(find.text('WAITING · 2'), findsOneWidget);
        }
        if (state == 'crate') {
          // Typing in the search is typing: Q is a letter, not SYNC on deck A.
          await tester.tap(find.byIcon(Icons.search).first);
          await tester.pump(const Duration(milliseconds: 100));
          final syncedBefore = app.booth.a.synced;
          await tester.tap(find.byType(TextField));
          await tester.pump();
          for (final k in [LogicalKeyboardKey.keyQ, LogicalKeyboardKey.space, LogicalKeyboardKey.digit1]) {
            await tester.sendKeyEvent(k);
          }
          await tester.pump(const Duration(milliseconds: 100));
          expect(app.booth.a.synced, syncedBefore, reason: 'Q typed into the search, not pressed');
          expect(app.booth.busy, isFalse, reason: 'space typed, not MIX');
          await tester.tap(find.byIcon(Icons.library_music_outlined));
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.text('Hardtekk crate'), findsOneWidget);
        }
        final err = tester.takeException();
        // The picture first, even of a room that overflowed: it shows where.
        if (out != null) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
            final image = await boundary.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$out/booth-${w.round()}-$state.png')
                .writeAsBytes(png!.buffer.asUint8List());
          });
        }
        expect(err, isNull);
        await tester.runAsync(() async {
          await b.stopAll();
          await app.player?.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        partsJobs.forget();
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }
  }
  }
}
