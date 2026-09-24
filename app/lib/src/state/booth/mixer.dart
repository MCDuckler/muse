import 'dart:async';
import 'dart:math' as math;

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
/// How loud each of a stem deck's three stems is, 0 to 1: the drums, the bass and
/// everything else but the voice, and the voice. All three up is the record.
class StemLevels {
  const StemLevels({this.drums = 1, this.rest = 1, this.vocals = 1});
  final double drums, rest, vocals;

  static const all = StemLevels();

  /// What each of the booth's parts is, as levels.
  static StemLevels of(String? part) => switch (part) {
        'drums' => const StemLevels(rest: 0, vocals: 0),
        'music' => const StemLevels(drums: 0),
        'instrumental' => const StemLevels(vocals: 0),
        'vocals' => const StemLevels(drums: 0, rest: 0),
        'bass-other' => const StemLevels(drums: 0, vocals: 0),
        _ => all,
      };

  /// The part these levels are, where they are one — for the pads.
  String? get part {
    bool on(double v) => v > 0.5;
    return switch ((on(drums), on(rest), on(vocals))) {
      (true, true, true) => null,
      (true, false, false) => 'drums',
      (false, true, true) => 'music',
      (true, true, false) => 'instrumental',
      (false, false, true) => 'vocals',
      _ => null,
    };
  }

  StemLevels lerp(StemLevels to, double t) => StemLevels(
        drums: drums + (to.drums - drums) * t,
        rest: rest + (to.rest - rest) * t,
        vocals: vocals + (to.vocals - vocals) * t,
      );

  bool closeTo(StemLevels o) =>
      (drums - o.drums).abs() < 0.005 &&
      (rest - o.rest).abs() < 0.005 &&
      (vocals - o.vocals).abs() < 0.005;

  @override
  String toString() => 'd${drums.toStringAsFixed(2)} r${rest.toStringAsFixed(2)} v${vocals.toStringAsFixed(2)}';
}

/// What the three bands of one channel are set to, in decibels.
class EqSet {
  const EqSet({this.low = 0, this.mid = 0, this.high = 0});

  /// A band turned all the way down. Gone to the ear, and back without a click.
  static const killed = -40.0;

  /// How far up a band can be turned. A mixer's EQ gives a little and takes a lot.
  static const most = 6.0;

  /// Where on a knob's travel, 0 to 1, a band at [db] sits — as on a DJ mixer: straight
  /// up (0.5) is flat, the right half the boost to [most], the left half the cut, gentle
  /// near the middle and falling away to the kill at the stop (an audio taper: nine
  /// o'clock is -12 dB, seven -24). The knobs were straight lines from -24 to +6, which
  /// put flat at two o'clock and every knob at rest pointing somewhere it should not.
  static double knobOf(double db) {
    if (db <= killed) return 0;
    if (db >= 0) return 0.5 + 0.5 * (db / most).clamp(0.0, 1.0);
    return (0.5 * math.pow(10, db / 40)).clamp(0.0, 0.5).toDouble();
  }

  /// The band a knob at [t] sets: [knobOf] turned round. The last of the travel is the
  /// kill.
  static double dbOf(double t) {
    if (t >= 0.5) return most * ((t - 0.5) / 0.5).clamp(0.0, 1.0);
    if (t <= 0.02) return killed;
    final db = 40 * math.log(t / 0.5) / math.ln10;
    return db <= killed ? killed : db;
  }

  final double low, mid, high;

  static const flat = EqSet();

  bool get isFlat => low == 0 && mid == 0 && high == 0;
  bool get lowKilled => low <= killed;
  bool get midKilled => mid <= killed;
  bool get highKilled => high <= killed;

  EqSet withLow(double db) => EqSet(low: db, mid: mid, high: high);
  EqSet withMid(double db) => EqSet(low: low, mid: db, high: high);
  EqSet withHigh(double db) => EqSet(low: low, mid: mid, high: db);

  /// The band turned off, or back to where it was — which for a knob that was moved
  /// is flat, because a kill has no memory a DJ can see.
  EqSet killing(int band, bool on) => switch (band) {
        0 => withLow(on ? killed : 0),
        1 => withMid(on ? killed : 0),
        _ => withHigh(on ? killed : 0),
      };

  @override
  bool operator ==(Object other) =>
      other is EqSet && other.low == low && other.mid == mid && other.high == high;

  @override
  int get hashCode => Object.hash(low, mid, high);
}

abstract class Mixer {
  /// Whether this device can shape a channel at all — the kills and the knobs.
  bool get canKill;
  bool get canFilter;

  /// Said just before a deck is made, so a mixer that has to recognise the deck's
  /// player as it is made (the browser) knows which one it is. Nothing, elsewhere.
  void expecting(String deck) {}

  /// Before either deck plays: the browser claims the decks' elements here.
  Future<void> prepare(List<Deck> decks) async {}

  /// The two levels, as amplitudes 0..1, at once. [over] zero is now.
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero});

  /// The three bands, in decibels: 0 is flat, [EqSet.killed] is a kill. One call
  /// rather than a kill switch and a knob, because they are the same control — a
  /// kill is a knob turned all the way down, and a mixer that kept them apart would
  /// have to decide which of the two won.
  Future<void> setEq(Deck deck, EqSet eq);

  /// -1 (low-pass, closed) through 0 (off) to 1 (high-pass, closed).
  Future<void> setFilter(Deck deck, double value);

  /// A record has just gone on [deck]. Where the mixer lives in the player, this is
  /// when it can first reach it.
  Future<void> loaded(Deck deck) async {}

  /// How far behind its reported position [deck]'s sound is, per unit of speed away
  /// from 1.0 — the time-stretcher's own delay, which the engine accounts for as if
  /// the record were playing at its own speed. Zero where there is nothing to correct.
  Duration stretchLatency(Deck deck) => Duration.zero;

  /// Find out [deck]'s [stretchLatency] afresh: its record's sample rate, which the
  /// stretcher's delay is counted in, is only known once it is playing.
  Future<void> measureLatency(Deck deck) async {}

  /// Loop [deck] from [from] to [to] inside the engine, or stop with nulls. False where
  /// the engine cannot, and the deck loops by itself.
  Future<bool> setLoop(Deck deck, Duration? from, Duration? to) async => false;

  /// Whether a deck here can play a record's stems — the drums, the bass and the
  /// rest, the voice — as one file with a level each, turned with no gap (a stem
  /// deck). Only a desk: its engine takes the six channels apart itself.
  bool get canStem => false;

  /// Before [deck] loads a record: ready its engine for [stems] (the six-channel file)
  /// or for an ordinary record, with the record's beat ([beatMs]) for what keeps time
  /// with it (the echo). Says whether it is ready for stems.
  Future<bool> beforeLoad(Deck deck, {required bool stems, double? beatMs}) async => false;

  /// Whether a deck here can be played at another pitch without its tempo moving
  /// (a semitone up for a boost mix), and carries an echo to go out on.
  bool get canShift => false;

  /// Play [deck] [semitones] higher (or lower, negative) at the same tempo.
  Future<void> setPitchShift(Deck deck, double semitones) async {}

  /// [deck]'s echo: how much of it is sent into the echo (0 to 1) and how much of the
  /// record itself is still heard ([dry], 0 to 1). The echo's tail rings on after the
  /// dry is taken away: an echo-out.
  Future<void> setEcho(Deck deck, {required double send, required double dry}) async {}

  /// Whether [deck]'s engine only now exists — its first record just went on — and
  /// what [beforeLoad] would have set could not be: the record is loaded again, parked
  /// and silent, with it set. Asked once after each load.
  Future<bool> firstLoadMissed(Deck deck) async => false;

  /// The levels of a stem deck's three stems, 0 to 1 each.
  Future<void> setStems(Deck deck, StemLevels levels) async {}

  /// Where to put a loop's ends so its seam does not click (see seam.dart), read from
  /// the sound [deck] is playing — or null where this engine cannot read it.
  Future<(Duration, Duration)?> quietSeam(Deck deck, Duration start, Duration end) async => null;

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

  /// The volume to tell a player for a [level] — a gain, 0 to 1, as a multiplier on
  /// the sound. The same number where the player's volume is a gain; see the desk's.
  @protected
  double toEngine(double level) => level;

  /// The gain a player's own volume figure makes: [toEngine] undone.
  @protected
  double fromEngine(double volume) => volume;

  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    _ramp?.cancel();
    if (over <= Duration.zero) {
      for (final e in levels.entries) {
        await e.key.player.setVolume(toEngine(e.value.clamp(0.0, 1.0)));
      }
      return;
    }
    // Thirty milliseconds a step: below what an ear hears as a step, above what a
    // player wants to be told a volume. Ramped in gain, the curve the booth chose, and
    // only then turned into whatever the player wants to be told.
    const step = Duration(milliseconds: 30);
    final from = {for (final d in levels.keys) d: fromEngine(d.player.volume)};
    final began = DateTime.now();
    final done = Completer<void>();
    _ramp = Timer.periodic(step, (t) async {
      final k = (DateTime.now().difference(began).inMicroseconds / over.inMicroseconds)
          .clamp(0.0, 1.0);
      for (final e in levels.entries) {
        final v = from[e.key]! + (e.value - from[e.key]!) * k;
        await e.key.player.setVolume(toEngine(v.clamp(0.0, 1.0)));
      }
      if (k >= 1) {
        t.cancel();
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  @override
  Future<void> setEq(Deck deck, EqSet eq) async {}

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
  Future<void> setEq(Deck deck, EqSet eq) async {
    final system = deck.equalizer;
    if (system == null) return;
    try {
      final p = await system.parameters;
      for (final band in p.bands) {
        final centre = (band.lowerFrequency + band.upperFrequency) / 2;
        final db = centre < 300
            ? eq.low
            : centre < 4000
                ? eq.mid
                : eq.high;
        // The phone's own equalizer has a range, and a kill is the bottom of it.
        await band.setGain(db.clamp(p.minDecibels, p.maxDecibels));
      }
    } catch (_) {
      // A phone with no equalizer in its system: the crossfader still works.
    }
  }
}
