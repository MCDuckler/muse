// The player, on a phone and beside a page, to be looked at.
//
// `flutter build web -t dev/player_gallery.dart -o build/player_gallery`; open with
// `?where=phone` or `?where=desk`, and `&theme=dark` for the late edition.
import 'package:flutter/material.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:muse/src/api/client.dart';
import 'dart:math' as math;

import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/state/booth/automix.dart' show MixStyle;
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/ui/booth_page.dart';
import 'package:muse/src/ui/desk_dock.dart';
import 'package:muse/src/ui/now_playing.dart';
import 'package:muse/src/ui/theme.dart';

import '../test/fake_audio.dart';

Map<String, dynamic> song(int id, String title, String artist, String album, int pos) => {
      'id': id,
      'title': title,
      'artists': [artist],
      'album': album,
      'duration_ms': 214000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'cover_color': '#c2571a',
      'pos': pos,
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = FakeJustAudio();
  final q = Uri.base.queryParameters;
  final dark = q['theme'] == 'dark';
  final desk = q['where'] == 'desk';
  final booth = q['where'] == 'booth';

  final app = AppState()..api = (ApiClient(baseUrl: 'http://127.0.0.1:9')..token = 'x');
  app.player = PlayerService(app.api);
  final queue = Queue.fromJson({
    'id': 1,
    'name': 'Late night',
    'cursor_index': 1,
    'position_ms': 61000,
    'rev': 1,
    'items': [
      song(1, 'HUMBLE.', 'Kendrick Lamar', 'DAMN.', 0),
      song(2, 'Everything In Its Right Place', 'Radiohead', 'Kid A', 1),
      song(3, 'Teardrop', 'Massive Attack', 'Mezzanine', 2),
    ],
  });
  app.queues = [queue];
  app.activeQueue = queue;
  try {
    await app.player!.init();
    await app.player!.loadQueue(queue);
  } catch (e) {
    debugPrint('gallery: $e');
  }

  if (booth) {
    // Two records on, with a grid, cues and a shape each, so the room can be looked at.
    app.boothOn = true;
    final b = app.booth;
    await b.init();
    TrackTiming grid(double bpm, String key, String camelot) {
      final beat = 60000 / bpm;
      final beats = [for (var i = 0; i < 400; i++) (2000 + i * beat).round()];
      final down = [for (var i = 0; i < beats.length; i += 4) beats[i]];
      return TrackTiming(
        durationMs: 214000, bpm: bpm, beats: beats, key: key, camelot: camelot, keyConfidence: 0.8,
        downbeats: down, energy: [for (var i = 0; i < down.length; i++) i < 8 || i > 80 ? 90 : 240],
        phrases: [for (var i = 0; i < down.length; i += 16) down[i]],
        drops: [down[16], if (down.length > 64) down[64]],
        cues: MixCues(firstDownbeatMs: beats[0], mixInMs: down[8], mixOutMs: down[80], soundEndMs: 212000),
      );
    }
    ({List<int> low, List<int> mid, List<int> high}) shape(int seed) {
      final r = math.Random(seed);
      List<int> band(double base, double wob) => [
            for (var i = 0; i < 1600; i++)
              (255 * (base + wob * math.sin(i / 23.0) + 0.25 * r.nextDouble()) * (i > 60 && i < 1500 ? 1 : 0.35)).clamp(0, 255).round()
          ];
      return (low: band(0.55, 0.25), mid: band(0.4, 0.2), high: band(0.25, 0.15));
    }
    final items = app.player!.items;
    b.timing.put(items[0].id, grid(122, 'C major', '8B'));
    b.timing.put(items[1].id, grid(124, 'A minor', '8A'));
    b.timing.put(items[2].id, grid(126, 'E minor', '9A'));
    await b.a.load(items[1], timing: grid(124, 'A minor', '8A'), at: const Duration(seconds: 61));
    await b.b.load(items[2], timing: grid(126, 'E minor', '9A'));
    b.bands[items[1].id] = shape(1);
    b.bands[items[2].id] = shape(2);
    b.auto.mixLike(MixStyle.bold);
    b.master = b.a;
    await b.setCrossfader(0.2);
    // Enough on the decks that the room shows what it is for: a cue, a loop, a band
    // pulled down, and the booth lined up to mix.
    b.a.setCue(1, const Duration(seconds: 30));
    b.a.setCue(2, const Duration(seconds: 96));
    b.b.loop(16);
    await b.setEq(b.b, const EqSet(low: EqSet.killed));
    await b.setGain(b.b, 0.82);
    await b.setFilter(b.a, 0.25);
    await b.a.play();
    await b.auto.start(items, at: 1);
  }

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => Selection()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? MuseTheme.dark() : MuseTheme.light(),
      home: booth
          ? const BoothPage()
          : desk
          ? Scaffold(
              body: Row(children: [
                Expanded(
                    child: Builder(
                        builder: (context) => Container(
                            color: Theme.of(context).colorScheme.surfaceContainer,
                            alignment: Alignment.center,
                            child: const Text('the page')))),
                DeskDock(open: true, onClose: () {}),
              ]),
            )
          : const NowPlayingScreen(),
    ),
  ));
}
