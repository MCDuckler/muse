import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two engines on one device: the booth's decks to libmpv, everything else to the
/// platform's own.
///
/// On an iPhone or an iPad the player the app is built around has to be AVPlayer — it
/// is what the lock screen, the headset buttons and CarPlay speak to — but a deck
/// played by AVPlayer can only be turned up and down: no kills, no filter, no echo,
/// and no stems at all, since AVPlayer cannot open Ogg/Opus. libmpv can do all of it,
/// with the same filter chain a desk has (DesktopMixer). So a deck asks for it by name
/// (`AudioPlayer(engine: DeckRouter.mpv)`), and this sends it there; every other
/// player goes where it always went.
///
/// Installed under just_audio_background, which already passes every player but the
/// first straight through to what is beneath it — the decks — so the one media
/// session stays with the app's own player.
class DeckRouter extends JustAudioPlatform {
  DeckRouter._(this._native, this._mpv);

  /// The engine a deck asks for.
  static const mpv = 'mpv';

  /// Whether decks are being sent to libmpv on this device: installed, and libmpv
  /// started.
  static bool get active => _installed != null;
  static DeckRouter? _installed;

  /// Why it is not, where it was tried and did not start. For the engine check.
  static String? failed;

  final JustAudioPlatform _native;
  final JustAudioMediaKit _mpv;

  /// Which players went to libmpv, so their disposal goes there too.
  final _onMpv = <String>{};

  /// Make sure iOS is letting sound out before a deck plays.
  ///
  /// libmpv's output on iOS is an AudioUnit, and an AudioUnit only runs while the
  /// app's audio session is active. just_audio activates it for its own players as
  /// they play; nothing did for a deck on libmpv, so with the app's player stopped the
  /// session stayed inactive and a deck "played" without sound or a moving position
  /// (the first engine check on an iPad: 0.0× at every speed). Cheap to call again.
  static Future<void> wake() async {
    if (!active) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      debugPrint('DeckRouter: the audio session would not start: $e');
    }
  }

  /// Where somebody can say "not libmpv" and have the decks back on AVPlayer, from the
  /// next start — the way out if it will not play on some device.
  static const _kEngine = 'muse.booth.engine';

  /// Whether the decks are to go to libmpv: yes unless somebody said not.
  static Future<bool> wanted() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_kEngine) != 'native';
    } catch (_) {
      return true;
    }
  }

  static Future<void> setWanted(bool mpv) async =>
      (await SharedPreferences.getInstance()).setString(_kEngine, mpv ? 'mpv' : 'native');

  /// Put the router in place over whatever platform is registered now. Call before
  /// JustAudioBackground.init, which wraps whatever it finds.
  static void install() {
    if (_installed != null) return;
    try {
      MediaKit.ensureInitialized();
      final mk = JustAudioMediaKit();
      JustAudioMediaKit.routed = mk;
      final router = DeckRouter._(JustAudioPlatform.instance, mk);
      JustAudioPlatform.instance = router;
      _installed = router;
    } catch (e) {
      failed = '$e';
      debugPrint('DeckRouter: libmpv did not start: $e');
    }
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) {
    if (AudioPlayer.engines.remove(request.id) == mpv) {
      _onMpv.add(request.id);
      return _mpv.init(request);
    }
    return _native.init(request);
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) =>
      _onMpv.remove(request.id) ? _mpv.disposePlayer(request) : _native.disposePlayer(request);

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    if (_onMpv.isNotEmpty) {
      _onMpv.clear();
      await _mpv.disposeAllPlayers(request);
    }
    return _native.disposeAllPlayers(request);
  }
}
