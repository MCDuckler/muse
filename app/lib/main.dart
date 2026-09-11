import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'src/state/app_state.dart';
import 'src/state/selection.dart';
import 'src/state/player.dart';
import 'src/ui/home_page.dart';
import 'src/ui/login_page.dart';
import 'src/ui/theme.dart';
import 'src/ui/page_colour.dart';

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
      androidNotificationChannelName: 'WetOwl',
      // The service stays in the foreground through a pause.
      //
      // Every moment the engine reports "stopped" used to tear the foreground state
      // down, and a process that is not running a foreground service is a cached one —
      // which Android is free to freeze the instant the app leaves the screen. The log
      // shows the engine flapping between stopped and playing a second apart while a
      // queue downloads, so the app was spending much of its time cached, and leaving
      // it during one of those windows froze it mid-song: no sound, and no Dart running
      // to notice or say so. The last kill recorded by the system agrees — it had the
      // app down as "cached" at the time.
      //
      // `ongoing` has to go with it: audio_service will not allow a notification that
      // cannot be dismissed on a service that is allowed to leave the foreground, and
      // between the two, staying alive matters more than being undismissable.
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    );
  }
  runApp(const MuseApp());
}

class MuseApp extends StatelessWidget {
  const MuseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) {
          final state = AppState()..boot();
          debugAppState = state;
          return state;
        }),
        // Picking several songs out of a list is its own small piece of state, and it
        // belongs to no one screen: the queue, a playlist and an album all use it.
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      // Watched, not read: changing the palette has to repaint the whole app, and the
      // app is what holds the theme.
      child: Consumer<AppState>(
        builder: (context, app, _) {
          // The strips the app does not draw — the clock at the top, the home bar at
          // the bottom — are painted by the system from the page's colour, so it has to
          // follow the palette rather than sit at whatever was compiled in.
          final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
          setPageColour(dark ? app.palette.groundDark : app.palette.groundLight);
          return MaterialApp(
        title: 'WetOwl',
        debugShowCheckedModeBanner: false,
        theme: MuseTheme.light(app.palette),
        darkTheme: MuseTheme.dark(app.palette),
        builder: (context, child) => _AnyTap(child: child ?? const SizedBox()),
        home: const _Root(),
          );
        },
      ),
    );
  }
}

/// Lets any tap stand in for the one the browser was waiting for.
///
/// A browser will not make a sound until someone has interacted with the page, so a
/// track that finishes downloading — or one that follows the track that just ended —
/// can be refused. The player says so instead of failing; this turns the next touch
/// anywhere in the app into permission, so it usually resolves itself before anyone
/// has to aim for the play button.
class _AnyTap extends StatelessWidget {
  const _AnyTap({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Down, not up: the browser counts the whole gesture, and this way playback
      // starts on the press.
      onPointerDown: (_) {
        final player = context.read<AppState>().player;
        if (player != null && player.needsGesture) {
          unawaited(player.resumeAfterGesture());
        }
      },
      child: child,
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
