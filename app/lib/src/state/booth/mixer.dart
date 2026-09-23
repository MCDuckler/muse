import 'dart:async';

import 'package:flutter/foundation.dart';

import 'deck.dart';
import 'mixer_none.dart' if (dart.library.js_interop) 'mixer_web.dart' as web;
import 'mixer_none.dart' if (dart.library.io) 'mixer_desktop.dart' as desk;

/// What sits between the two decks and the speaker.
///
/// Three different things behind one interface, for the same reason the equalizer is:
/// the platforms have nothing in common here.
///
///  * A browser plays each deck's element through a graph of its own — a gain, three
///    bands with true kills, a filter, and the crossfader — and can schedule every
///    change on the audio clock. See web/booth.js. This is the exact one.
///  * Android has a gain per player and its own equalizer per audio session, so the
///    crossfader is done in volume steps and the kills through the bands.
///  * Everywhere else, for now, a gain per player: the crossfader works and the kills
///    do not, and the booth says so rather than pretending.
abstract class Mixer {
  bool get canKill;
  bool get canFilter;

  /// Said just before a deck is made, so a mixer that has to recognise the deck's
  /// player as it is made (the browser) knows which one it is. Nothing, elsewhere.
  void expecting(String deck) {}

  /// Before either deck plays: the browser claims the decks' elements here.
  Future<void> prepare(List<Deck> decks) async {}

  /// The two levels, as amplitudes 0..1, at once. [over] zero is now.
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero});

  Future<void> setKills(Deck deck, {bool low = false, bool mid = false, bool high = false});

  /// -1 (low-pass, closed) through 0 (off) to 1 (high-pass, closed).
  Future<void> setFilter(Deck deck, double value);

  /// Whichever one this device has.
  static Mixer forThisDevice() {
    if (kIsWeb) return web.webMixer() ?? VolumeMixer();
    if (defaultTargetPlatform == TargetPlatform.android) return AndroidMixer();
    if (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return desk.desktopMixer() ?? VolumeMixer();
    }
    return VolumeMixer();
  }
}

/// A gain per player, and a ramp done in small steps from Dart.
class VolumeMixer extends Mixer {
  @override
  bool get canKill => false;
  @override
  bool get canFilter => false;

  Timer? _ramp;

  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    _ramp?.cancel();
    if (over <= Duration.zero) {
      for (final e in levels.entries) {
        await e.key.player.setVolume(e.value.clamp(0.0, 1.0));
      }
      return;
    }
    // Thirty milliseconds a step: below what an ear hears as a step, above what a
    // player wants to be told a volume.
    const step = Duration(milliseconds: 30);
    final from = {for (final d in levels.keys) d: d.player.volume};
    final began = DateTime.now();
    final done = Completer<void>();
    _ramp = Timer.periodic(step, (t) async {
      final k = (DateTime.now().difference(began).inMicroseconds / over.inMicroseconds)
          .clamp(0.0, 1.0);
      for (final e in levels.entries) {
        final v = from[e.key]! + (e.value - from[e.key]!) * k;
        await e.key.player.setVolume(v.clamp(0.0, 1.0));
      }
      if (k >= 1) {
        t.cancel();
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  @override
  Future<void> setKills(Deck deck, {bool low = false, bool mid = false, bool high = false}) async {}

  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

/// Android: the gain as above, and the kills through the system equalizer's bands.
///
/// The phone's maker chose the bands — five, usually, from 60 Hz to 14 kHz — so a
/// "kill" is every band in that third of the spectrum turned all the way down. Not a
/// brick wall, but a kill on a five-band graphic never was.
class AndroidMixer extends VolumeMixer {
  @override
  bool get canKill => true;

  @override
  Future<void> prepare(List<Deck> decks) async {
    for (final d in decks) {
      try {
        await d.equalizer?.setEnabled(true);
      } catch (_) {}
    }
  }

  @override
  Future<void> setKills(Deck deck, {bool low = false, bool mid = false, bool high = false}) async {
    final eq = deck.equalizer;
    if (eq == null) return;
    try {
      final p = await eq.parameters;
      for (final band in p.bands) {
        final centre = (band.lowerFrequency + band.upperFrequency) / 2;
        final killed = centre < 300
            ? low
            : centre < 4000
                ? mid
                : high;
        await band.setGain(killed ? p.minDecibels : 0);
      }
    } catch (_) {
      // A phone with no equalizer in its system: the crossfader still works.
    }
  }
}
