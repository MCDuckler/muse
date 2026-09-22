// The player, on a phone and beside a page, to be looked at.
//
// `flutter build web -t dev/player_gallery.dart -o build/player_gallery`; open with
// `?where=phone` or `?where=desk`, and `&theme=dark` for the late edition.
import 'package:flutter/material.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/state/selection.dart';
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

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => Selection()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? MuseTheme.dark() : MuseTheme.light(),
      home: desk
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
