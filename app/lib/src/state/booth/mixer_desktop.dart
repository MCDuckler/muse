import 'dart:math' as math;

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import 'deck.dart';
import 'mixer.dart';

/// A desk: the gain as everywhere, and the kills and the filter as mpv's own audio
/// filter chain on the deck's player — shelves and a low- or high-pass from ffmpeg,
/// set on the player as it plays.
Mixer? desktopMixer() =>
    JustAudioMediaKit.instanceIfRegistered == null ? null : DesktopMixer();

class DesktopMixer extends VolumeMixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;

  final _kills = <String, ({bool low, bool mid, bool high})>{};
  final _filter = <String, double>{};

  Player? _raw(Deck deck) {
    final id = deck.player.platformId;
    if (id == null) return null;
    return JustAudioMediaKit.instanceIfRegistered?.playerFor(id)?.raw;
  }

  /// The whole chain for a deck, from what is wanted of it. Empty is no filters,
  /// which is what mpv is told when nothing is wanted.
  static String chain({required ({bool low, bool mid, bool high}) kills, required double filter}) {
    final parts = <String>[
      if (kills.low) 'lowshelf=f=250:g=-40',
      if (kills.mid) 'equalizer=f=1000:width_type=o:width=2:g=-40',
      if (kills.high) 'highshelf=f=4000:g=-40',
    ];
    if (filter < 0) {
      // Closing towards 60 Hz on a log scale, like the browser's.
      final hz = 22000 * math.pow(60 / 22000, -filter);
      parts.add('lowpass=f=${hz.round()}');
    } else if (filter > 0) {
      final hz = 10 * math.pow(8000 / 10, filter);
      parts.add('highpass=f=${hz.round()}');
    }
    return parts.isEmpty ? '' : 'lavfi=[${parts.join(',')}]';
  }

  Future<void> _apply(Deck deck) async {
    // The platform half of the player is the one that speaks mpv.
    final platform = _raw(deck)?.platform;
    if (platform is! NativePlayer) return;
    final value = chain(
        kills: _kills[deck.name] ?? (low: false, mid: false, high: false),
        filter: _filter[deck.name] ?? 0);
    try {
      await platform.setProperty('af', value);
    } catch (_) {
      // An mpv without lavfi: the fader still works.
    }
  }

  @override
  Future<void> setKills(Deck deck, {bool low = false, bool mid = false, bool high = false}) async {
    _kills[deck.name] = (low: low, mid: mid, high: high);
    await _apply(deck);
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {
    _filter[deck.name] = value.clamp(-1.0, 1.0);
    await _apply(deck);
  }
}
