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
