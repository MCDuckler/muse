// The mixer for decks on the booth's own engine (lib/src/audio/engine.dart): the
// channel's level, the bands, the filter, key lock, the stems, the chop, the echo
// and the semitone shift, all inside the engine's callback — sample-accurate, and
// none of it lost on a seek or a loop, because nothing there is ever rebuilt.
import 'dart:async';
import 'dart:math' as math;

import '../../audio/engine.dart';
import 'deck.dart';
import 'mixer.dart';

class NativeMixer extends Mixer {
  NativeMixer(this.engine);
  final Engine engine;

  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;
  @override
  bool get canStem => true;
  @override
  bool get canShift => true;
  @override
  bool get canGate => true;

  int? _i(Deck d) => d.engineIndex;

  /// The booth's own sounds (FxChannel) still play on libmpv players, whose volume is
  /// the cube of the gain.
  @override
  double playerVolume(double level) => math.pow(level.clamp(0.0, 1.0), 1 / 3).toDouble();

  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    for (final e in levels.entries) {
      final i = _i(e.key);
      if (i != null) engine.level(i, e.value.clamp(0.0, 1.0), ramp: over);
    }
    if (over > Duration.zero) await Future<void>.delayed(over);
  }

  @override
  Future<void> setEq(Deck deck, EqSet eq) async {
    final i = _i(deck);
    if (i != null) engine.eq(i, eq.low, eq.mid, eq.high);
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {
    final i = _i(deck);
    if (i != null) engine.filter(i, value);
  }

  @override
  Future<void> setKeylock(Deck deck, bool on) async {
    final i = _i(deck);
    if (i != null) engine.keylock(i, on);
  }

  // Stems: the deck loads the six-channel file itself (deck_native.dart); the levels
  // come here.
  @override
  Future<bool> beforeLoad(Deck deck, {required bool stems, double? beatMs}) async => stems;

  @override
  Future<void> setStems(Deck deck, StemLevels levels) async {
    final i = _i(deck);
    if (i == null) return;
    engine.sourceGain(i, 0, 1, drums: levels.drums, rest: levels.rest, vocals: levels.vocals, ramp: const Duration(milliseconds: 20));
  }

  @override
  Future<void> setGate(Deck deck, {required double depth, required Duration period, required Duration origin}) async {
    final i = _i(deck);
    if (i != null) engine.gate(i, depth, period, origin);
  }

  @override
  Future<void> setPitchShift(Deck deck, double semitones) async {
    final i = _i(deck);
    if (i != null) engine.shift(i, semitones);
  }

  @override
  Future<void> setEcho(Deck deck, {required double send, required double dry}) async {
    final i = _i(deck);
    if (i == null) return;
    engine.echo(i, send, dry, deck.beat ?? const Duration(milliseconds: 500));
  }
}
