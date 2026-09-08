import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'src/state/app_state.dart';
import 'src/state/player.dart';
import 'src/ui/home_page.dart';
import 'src/ui/login_page.dart';
import 'src/ui/theme.dart';

/// Exposed for the integration test: the player lives behind a stream, and a test
/// driving real widgets needs a way to read what it actually did.
AppState? debugAppState;
PlayerSnapshot? debugPlayerSnapshot() => debugAppState?.player?.last;

/// Raw engine state, for diagnosing a headless run where audio silently does nothing.
String debugEngineState() {
  final p = debugAppState?.player?.raw;
  if (p == null) return 'no player';
  return 'processing=${p.processingState} playing=${p.playing} '
      'volume=${p.volume} duration=${p.duration} position=${p.position}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lockscreen / notification controls and playback that survives the screen going off.
  //
  // Not on the web, where there is no lockscreen to control and where it actively
  // breaks playback: it wraps the audio platform, and on the web that wrapper accepts
  // every setAudioSource after the first and quietly does nothing with it. The element
  // keeps the first file it was ever given, so skipping moved the screen on while the
  // same song kept playing. Proved by hooking HTMLMediaElement: one src assignment for
  // the whole session, then nothing but repeated play() calls on it.
  if (!kIsWeb) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'dev.muse.audio',
      androidNotificationChannelName: 'muse',
      androidNotificationOngoing: true,
    );
  }
  runApp(const MuseApp());
}

class MuseApp extends StatelessWidget {
  const MuseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final state = AppState()..boot();
        debugAppState = state;
        return state;
      },
      child: MaterialApp(
        title: 'muse',
        debugShowCheckedModeBanner: false,
        theme: MuseTheme.light(),
        darkTheme: MuseTheme.dark(),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return app.user == null ? const LoginPage() : const HomePage();
  }
}
