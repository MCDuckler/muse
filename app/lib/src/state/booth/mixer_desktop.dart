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

  final _eq = <String, EqSet>{};
  final _filter = <String, double>{};

  Player? _raw(Deck deck) {
    final id = deck.player.platformId;
    if (id == null) return null;
    return JustAudioMediaKit.instanceIfRegistered?.playerFor(id)?.raw;
  }

  /// The whole chain for a deck, from what is wanted of it. Empty is no filters,
  /// which is what mpv is told when nothing is wanted.
  static String chain({required EqSet eq, required double filter}) {
    String db(double v) => v.toStringAsFixed(1);
    final parts = <String>[
      if (eq.low != 0) 'lowshelf=f=250:g=${db(eq.low)}',
      if (eq.mid != 0) 'equalizer=f=1000:width_type=o:width=2:g=${db(eq.mid)}',
      if (eq.high != 0) 'highshelf=f=4000:g=${db(eq.high)}',
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
    final value = chain(eq: _eq[deck.name] ?? EqSet.flat, filter: _filter[deck.name] ?? 0);
    try {
      await platform.setProperty('af', value);
    } catch (_) {
      // An mpv without lavfi: the fader still works.
    }
  }

  @override
  Future<void> setEq(Deck deck, EqSet eq) async {
    _eq[deck.name] = eq;
    await _apply(deck);
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {
    _filter[deck.name] = value.clamp(-1.0, 1.0);
    await _apply(deck);
  }
}
