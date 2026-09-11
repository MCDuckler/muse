import 'media_session_none.dart'
    if (dart.library.js_interop) 'media_session_web.dart' as impl;

/// Tell the browser what is playing, where there is a browser to tell.
///
/// Chosen at compile time rather than guarded with `kIsWeb`, for the same reason the
/// page colour is: `package:web` is built on `dart:js_interop`, which does not exist on
/// Android at all, so importing it unconditionally fails the APK build long before any
/// runtime check could have helped.
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
}) =>
    impl.describeToTheBrowser(
      title: title,
      artist: artist,
      album: album,
      artwork: artwork,
      playing: playing,
      onPlay: onPlay,
      onPause: onPause,
      onNext: onNext,
      onPrevious: onPrevious,
    );

void nothingIsPlaying() => impl.nothingIsPlaying();
