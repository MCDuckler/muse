// What the show reads of a booth once a frame (ShowEngine.tick): the two decks as
// the ear hears them, the sound in the room, the mix in progress. The booth in this
// process ([BoothShowSource]), or one in another process that says it over the wire
// (desk_show_source.dart: the WetOwl Desk's, for a stage that directs the show itself).
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../audio/engine.dart';
import '../booth/booth.dart';
import '../booth/deck.dart';
import 'milk_feed.dart';
import 'show_deck.dart';
import 'show_events.dart';
import 'show_heard.dart';
import 'show_state.dart';

/// One frame's facts: the decks, the room's sound, the engine's own numbers (`live.on`,
/// the spectrum) where it was heard rather than modelled, and the mix.
typedef ShowFacts = ({ShowDeck a, ShowDeck b, ShowAudio audio, Map<String, double> live, ShowMix mix});

abstract class ShowSource {
  ApiClient get api;

  /// Where a moment said between frames goes (a step applied, an effect fired): the
  /// engine's, set once.
  void Function(ShowEvent e)? said;

  /// The facts at [now], the performer's offset [offsetMs] put on the decks' clocks.
  ShowFacts facts(DateTime now, int offsetMs);

  void dispose() {}
}

/// The booth in this process: its decks' clocks, the analysis of what they play, the
/// mixer, and what its engine hears.
class BoothShowSource extends ShowSource {
  BoothShowSource(this.booth) {
    booth.stepApplied.addListener(_stepSaid);
    booth.fxFired.addListener(_fxSaid);
    // MilkDrop's sound: the record's file here, or its stream.
    MilkFeed.shared.pcm.source = (id) {
      final local = booth.a.offlinePath?.call(id);
      if (local != null) return (url: local, headers: const <String, String>{});
      final track = booth.a.track?.id == id
          ? booth.a.track
          : booth.b.track?.id == id
              ? booth.b.track
              : null;
      if (track == null) return null;
      return (url: booth.api.streamUrl(track), headers: booth.api.streamHeaders);
    };
    // Or, where the booth plays on its own engine, what the room hears.
    MilkFeed.shared.pcm.heard = _heardPcm;
  }

  final Booth booth;

  @override
  ApiClient get api => booth.api;

  /// WETOWL_SHOW_SOUND=pulse: the house's pulse through the mixer model even where
  /// the engine could say what is heard (to compare the two).
  static final _pulseOnly = !kIsWeb && Platform.environment['WETOWL_SHOW_SOUND'] == 'pulse';

  /// What the engine hears, where the booth plays on it (show_heard.dart).
  ShowHeard? _heard;
  ShowHeard? get _heardNow {
    final e = Engine.started;
    if (e == null || _pulseOnly) return _heard = null;
    if (_heard?.engine != e) _heard = ShowHeard(e);
    return _heard;
  }

  /// MilkDrop's sound off the engine: the master's samples since the last tick.
  double? _pcmAt;
  Int16List? _heardPcm() {
    final e = Engine.started;
    if (e == null || _pulseOnly || !(booth.a.onEngine || booth.b.onEngine)) return null;
    final at = e.now() + math.min(e.latency, ShowHeard.maxLead);
    var from = _pcmAt;
    if (from == null || from > at || at - from > 0.25) from = at - 1 / 60;
    final n = ((at - from) * e.rate).round();
    if (n <= 0) return null;
    _pcmAt = from + n / e.rate;
    final x = e.scope(Engine.master, _pcmAt!, n);
    if (x == null) return null;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (x[i] * 32767).round().clamp(-32768, 32767);
    }
    return out;
  }

  final _askedVocals = <int>{};

  void _stepSaid() {
    final s = booth.stepApplied.last;
    if (s == null) return;
    said?.call(ShowEvent(ShowEventKind.step, DateTime.now(), data: {'at': s.at, 'crossfader': s.crossfader}));
  }

  void _fxSaid() {
    final f = booth.fxFired.last;
    if (f == null) return;
    said?.call(ShowEvent(ShowEventKind.fx, DateTime.now(), data: {'sound': f.sound.name, 'beats': f.beats}));
  }

  @override
  ShowFacts facts(DateTime now, int offsetMs) {
    final levels = booth.levels;
    var a = _deck(booth.a, now, levels.a, offsetMs);
    var b = _deck(booth.b, now, levels.b, offsetMs);

    // The sound as heard, where the decks play on the engine: each deck's own, and
    // the room's; the stems' levels stay the pulse's.
    var audio = a.audio + b.audio;
    final live = <String, double>{};
    final heardBy = _heardNow;
    final ai = booth.a.engineIndex, bi = booth.b.engineIndex;
    if (heardBy != null && (ai != null || bi != null)) {
      final h = heardBy.read([if (ai != null) ai, if (bi != null) bi]);
      if (h != null) {
        if (h.decks[ai] case final ha?) a = a.withAudio(ShowHeard.over(ha, a.audio));
        if (h.decks[bi] case final hb?) b = b.withAudio(ShowHeard.over(hb, b.audio));
        audio = ShowHeard.over(h.master, audio);
        live['live.on'] = 1;
        final spec = h.spectrum;
        if (spec != null) {
          for (var i = 0; i < spec.length; i++) {
            live['spec.$i'] = spec[i];
          }
        }
      }
    }

    final m = booth.mixing;
    final arm = booth.arming;
    final mix = m != null
        ? ShowMix(on: true, kind: m.kind.name, from: m.from, to: m.to, bars: m.bars, k: m.k)
        : arm != null
            ? ShowMix(armed: true, kind: arm.kind.name, from: arm.from, to: arm.to, startsIn: arm.startsAt.difference(now))
            : ShowMix.none;
    return (a: a, b: b, audio: audio, live: live, mix: mix);
  }

  ShowDeck _deck(Deck deck, DateTime now, double level, int offsetMs) {
    final track = deck.track;
    if (track == null) return ShowDeck(name: deck.name);
    // The ear's position: the engine's clock, less what the stretcher holds back,
    // plus the performer's offset.
    final at = deck.positionAt(now) - booth.mixer.stretchLatency(deck) + Duration(milliseconds: offsetMs);
    final timing = deck.timing ?? booth.timing.peek(track.id);
    var vocals = booth.vocals.peek(track.id);
    if (vocals == null && _askedVocals.add(track.id)) {
      unawaited(booth.vocals.of(track).then((_) => _askedVocals.remove(track.id)));
    }
    final pulse = booth.pulse[track.id];
    if (pulse == null) unawaited(booth.fetchPulse(track));
    return deriveDeck(
      name: deck.name,
      track: track,
      coverUrl: booth.api.coverUrl(track),
      streamUrl: booth.api.streamUrl(track),
      playing: deck.playing,
      position: at < Duration.zero ? Duration.zero : at,
      timing: timing,
      vocals: vocals,
      pulse: pulse,
      channel: ChannelSettings(
        level: level.clamp(0.0, 1.0),
        eq: booth.eqOf(deck),
        filter: booth.filters[deck] ?? 0,
        stems: deck.stemLevels,
        looping: deck.loopStart != null && deck.loopEnd != null,
      ),
    );
  }

  @override
  void dispose() {
    booth.stepApplied.removeListener(_stepSaid);
    booth.fxFired.removeListener(_fxSaid);
  }
}
