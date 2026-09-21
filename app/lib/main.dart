import 'dart:async';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';

import 'src/state/app_state.dart';
import 'src/state/selection.dart';
import 'src/state/playback_log.dart';
import 'src/state/player.dart';
import 'src/ui/search_page.dart' show searchWanted;
import 'src/ui/home_page.dart';
import 'src/ui/loading.dart';
import 'src/ui/login_page.dart';
import 'src/ui/theme.dart';
import 'src/ui/page_colour.dart';
import 'src/ui/paper.dart';
import 'src/ui/widths.dart';

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
  _fontLicences();

  // How much decoded artwork to keep, in a browser.
  //
  // Flutter's default is a hundred megabytes of decoded pictures, which is a sensible
  // number for an app that owns the device and a dangerous one inside a tab: Safari on
  // an iPhone gives a page a budget for everything — the pictures, the canvas, the
  // engine itself — and reloads the page out from under you when it is spent. A queue
  // of covers is worth far less than staying on screen.
  if (kIsWeb) {
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 24 << 20
      ..maximumSize = 120;
  }
  // Lockscreen / notification controls and playback that survives the screen going off.
  //
  // Not on the web, where there is no lockscreen to control and where it actively
  // breaks playback: it wraps the audio platform, and on the web that wrapper accepts
  // every setAudioSource after the first and quietly does nothing with it. The element
  // keeps the first file it was ever given, so skipping moved the screen on while the
  // same song kept playing. Proved by hooking HTMLMediaElement: one src assignment for
  // the whole session, then nothing but repeated play() calls on it.
  if (!kIsWeb) {
    try {
      await JustAudioBackground.init(
      androidNotificationChannelId: 'dev.muse.audio',
      androidNotificationChannelName: 'WetOwl',
      // The status bar draws a small icon as a stencil — it keeps the alpha and
      // throws the colours away — so it is given a white one cut from the app's own
      // icon rather than the full-colour launcher icon. A launcher icon up there is a
      // white blob at best, and on some builds a notification the system declines to
      // post at all: no notification is no foreground service, and no foreground
      // service is an app the system may freeze the moment it leaves the screen.
      androidNotificationIcon: 'drawable/ic_stat_wetowl',
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
      // Written down because the one thing the logs could not say was whether this
      // worked. A wrapper that is not installed is a player with no media session
      // behind it: no notification, no foreground service, and a process the system
      // may freeze the moment the app leaves the screen.
      PlaybackLog.note(
          'background audio ready (${JustAudioPlatform.instance.runtimeType})');
      // Everything audio_service fails at after this point, written down.
      //
      // The state the app broadcasts reaches the Android service through a platform
      // call in a loop that swallows what it throws — into this stream, which nothing
      // was listening to. If those calls are failing, that is the whole of the
      // background-playback bug and it has been invisible the entire time; if they are
      // not, the fault is on the far side of them. Either answer is worth a line.
      AudioService.asyncError.listen(
          (e) => PlaybackLog.note('AUDIO SERVICE ERROR: $e'));
    } catch (e) {
      PlaybackLog.note('BACKGROUND AUDIO FAILED TO START: $e');
    }
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
          final state = AppState();
          // Where this tab was opened, before anything has had a chance to navigate
          // away from it. On the phone there is no address to read and this is "/".
          state.arrivedAt(Uri.base.path);
          state.boot();
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
        // A mouse gets a scrollbar and can drag a list about, which a finger has
        // never needed: on the web the app was a phone with no scrollbar, so a
        // library of twenty-two thousand songs was a scroll with no bottom and no
        // sense of where in it you were.
        scrollBehavior: const _DeskScrolling(),
        // Above the navigator, so the keys work on every route. They used to sit in
        // the home shell, and the player is a route pushed over it: open what is
        // playing and space stopped pausing it.
        //
        // Rows also sit closer together where there is a mouse: the extra height in
        // a list is room for a fingertip, and on a desk it is half a screen of
        // nothing.
        builder: (context, child) => AppShortcuts(
          child: _AnyTap(
            child: Theme(
              data: Theme.of(context).copyWith(
                  visualDensity: Width.of(context) == Width.expanded
                      ? VisualDensity.compact
                      : null),
              child: PaperGrain(child: child ?? const SizedBox()),
            ),
          ),
        ),
        home: const _Root(),
          );
        },
      ),
    );
  }
}

/// How lists behave where there is a pointer.
class _DeskScrolling extends MaterialScrollBehavior {
  const _DeskScrolling();

  /// A trackpad and a finger drag a list; a mouse does not.
  ///
  /// Letting a mouse drag scrollables looked like a kindness and was not: a queue row
  /// picked up to be dragged somewhere else was as likely to scroll the list under it,
  /// and a word in a lyric could not be selected because the drag belonged to the
  /// scroll view. A mouse has a wheel, which is what it scrolls with.
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
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

/// Keyboard control, because the web build is the client most of the time and a
/// music player you cannot pause from the keyboard is annoying to live with.
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({super.key, required this.child});
  final Widget child;

  /// True while a text field has focus.
  ///
  /// Checking `primaryFocus.context.widget` is not enough: the node that holds focus
  /// belongs to a Focus widget *inside* EditableText, so the type test never matched
  /// and every letter typed into the search box also triggered a shortcut — S toggled
  /// shuffle, N skipped the track, space paused the music.
  static bool get _isTyping {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    var typing = false;
    ctx.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        typing = true;
        return false;
      }
      return true;
    });
    return typing;
  }

  /// Every key that does something, and what it does.
  ///
  /// One list, read by the handler below and by the sheet that shows it: a shortcut
  /// nobody is told about is a shortcut nobody uses, and two lists would be one list
  /// and a lie.
  static const keys = <(String, String)>[
    ('Space', 'Play or pause'),
    ('← / →', 'Back or forward ten seconds'),
    ('N / P', 'Next song, previous song'),
    ('S', 'Shuffle what is coming'),
    ('R', 'Repeat: off, all, one'),
    ('M', 'Mute'),
    ('/', 'Search'),
    ('?', 'This list'),
  ];

  static KeyEventResult handle(AppState app, KeyEvent event) {
    final player = app.player;
    if (player == null || event is! KeyDownEvent) return KeyEventResult.ignored;

    // Never steal keys from a text field: space belongs to the search box.
    if (_isTyping) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
        app.playPause();
      case LogicalKeyboardKey.arrowRight:
        player.nudge(const Duration(seconds: 10));
      case LogicalKeyboardKey.arrowLeft:
        player.nudge(const Duration(seconds: -10));
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.mediaTrackNext:
        app.skipNext();
      case LogicalKeyboardKey.keyP:
      case LogicalKeyboardKey.mediaTrackPrevious:
        app.skipPrevious();
      case LogicalKeyboardKey.keyS:
        app.shuffleWhatIsComing();
      case LogicalKeyboardKey.keyR:
        app.cycleRepeat();
      case LogicalKeyboardKey.keyM:
        app.toggleMute();
      case LogicalKeyboardKey.slash:
        // Every app with a search box answers this key, and this one has a search
        // *tab*: go there first, then take the cursor.
        app.setHomeTab(1);
        searchWanted.value++;
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          // The question mark is the one key that is about the keys themselves, so it
          // is handled here where there is a context to show a dialog with.
          if (event is KeyDownEvent &&
              !_isTyping &&
              (event.logicalKey == LogicalKeyboardKey.question ||
                  event.character == '?')) {
            showShortcuts(context);
            return KeyEventResult.handled;
          }
          return handle(context.read<AppState>(), event);
        },
        child: child,
      );
}

/// What the keys do, for anybody who has not been told.
void showShortcuts(BuildContext context) {
  showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: const Text('Keys'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (key, what) in AppShortcuts.keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(key,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                  Expanded(child: Text(what)),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Right'),
        ),
      ],
    ),
  );
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.ready) {
      return const Scaffold(body: LoadingField());
    }
    return app.user == null ? const LoginPage() : const HomePage();
  }
}

/// The typefaces' licences, on the licences page with everything else's.
///
/// The fonts are open, and the licence they are open under asks for itself to travel
/// with them. Read from the files bundled beside the fonts, only when the page that
/// lists them is opened.
void _fontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final (names, file) in const [
      (['Archivo'], 'OFL-Archivo.txt'),
      (['Bodoni Moda'], 'OFL-BodoniModa.txt'),
      (['Courier Prime'], 'OFL-CourierPrime.txt'),
      (['Manrope'], 'OFL-Manrope.txt'),
      (['Permanent Marker'], 'LICENSE-PermanentMarker.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks(
          names, await rootBundle.loadString('assets/fonts/$file'));
    }
  });
}
