import 'package:web/web.dart' as web;
import 'dart:js_interop';

/// Telling the browser what is playing.
///
/// Not decoration, and on iOS not optional. A page that plays audio without a media
/// session is a page playing a sound; a page with one is a media app, and the two are
/// treated very differently once the app is not on screen — an installed web app on
/// iOS that has never declared a session gets its work suspended when it is switched
/// away from, which means nothing runs to start the next song, which is a queue that
/// plays exactly one record and stops.
///
/// It is also the only way a web app gets lockscreen controls at all.
void describeToTheBrowser({
  required String title,
  required String artist,
  required String album,
  String? artwork,
  required bool playing,
  void Function()? onPlay,
  void Function()? onPause,
  void Function()? onNext,
  void Function()? onPrevious,
}) {
  final session = web.window.navigator.mediaSession;

  session.metadata = web.MediaMetadata(web.MediaMetadataInit(
    title: title,
    artist: artist,
    album: album,
    // One entry at the size the platforms actually ask for. A list of sizes we do not
    // really have would only be the same picture described four ways.
    artwork: <web.MediaImage>[
      if (artwork != null)
        web.MediaImage(src: artwork, sizes: '512x512', type: 'image/jpeg'),
    ].toJS,
  ));
  session.playbackState = playing ? 'playing' : 'paused';

  // Handlers rather than nothing: a session with no actions is one the browser may
  // decide is not worth showing, and these are the buttons on the lockscreen.
  void give(String action, void Function()? handler) {
    try {
      session.setActionHandler(
          action, handler == null ? null : ((JSAny? _) => handler()).toJS);
    } catch (_) {
      // A browser that does not know this action. Asking is the only way to find out.
    }
  }

  give('play', onPlay);
  give('pause', onPause);
  give('nexttrack', onNext);
  give('previoustrack', onPrevious);
}

void nothingIsPlaying() {
  try {
    web.window.navigator.mediaSession.playbackState = 'none';
    web.window.navigator.mediaSession.metadata = null;
  } catch (_) {}
}
