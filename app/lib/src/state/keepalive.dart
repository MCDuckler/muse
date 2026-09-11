import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ask the platform to keep the network up while a song is streaming.
///
/// Android only, and best effort: see Keepalive.kt for what it actually holds and
/// why neither just_audio nor just_audio_background does it for us. Everywhere else
/// this is nothing at all, which is correct — a browser tab and a desktop have no such
/// lock to take.
class Keepalive {
  static const _channel = MethodChannel('muse/keepalive');
  static bool _on = false;

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const _notify = MethodChannel('muse/notify');
  static bool _asked = false;

  /// Ask to be allowed to show the playing notification, once.
  ///
  /// Declared in the manifest since the beginning and never requested — and since
  /// Android 13 declaring it is not enough. No notification means no foreground
  /// service, and a process without one is a cached process, which the system may
  /// freeze the moment the app leaves the screen.
  ///
  /// At the first play rather than at launch: a permission prompt in front of somebody
  /// who has not yet seen the app is a prompt they say no to.
  static Future<void> mayWeShowThePlayer() async {
    if (!supported || _asked) return;
    _asked = true;
    try {
      await _notify.invokeMethod<void>('ask');
    } catch (_) {
      // Older Android, or no activity to ask through. It plays either way.
    }
  }

  static Future<void> set(bool on) async {
    if (!supported || on == _on) return;
    _on = on;
    try {
      await _channel.invokeMethod<void>('set', {'on': on});
    } on PlatformException catch (_) {
      // A lock we cannot take is not a reason to stop the music.
    } on MissingPluginException catch (_) {
      // The activity is gone and its channel with it. The service keeps playing.
    }
  }
}
