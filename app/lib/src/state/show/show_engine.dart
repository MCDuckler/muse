// The show's engine: the booth read once a frame into a ShowState, and the edges
// between frames said as events.
//
// Runs while the booth is open (BoothClock starts and stops it), on a ticker of its
// own at the screen's rate. Each tick reads the decks' clocks as the ear hears them
// (the time-stretcher's delay taken off, the performer's offset added), what the
// analysis says of that moment (show_deck.dart), the mixer's settings and the mix
// in progress, eases the palette towards the record's, decays the hit, and hands
// the frame on. Everything downstream — the stage, the lights, a recording — reads
// [state] and [events] and nothing else.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../api/models.dart';
import '../booth/booth.dart';
import '../booth/deck.dart';
import 'show_deck.dart';
import 'show_director.dart';
import 'show_dynamics.dart';
import 'show_events.dart';
import 'camera_feed.dart';
import 'show_feed.dart';
import 'show_genome.dart';
import 'show_palette.dart';
import 'show_state.dart';

class ShowEngine extends ChangeNotifier implements ShowFeed {
  ShowEngine(this.booth) {
    booth.stepApplied.addListener(_stepSaid);
    booth.fxFired.addListener(_fxSaid);
    _state = _blank(DateTime.now());
  }

  final Booth booth;

  /// The performer's offset, in milliseconds: how much later than the deck's clock
  /// the picture should run, to land on the ear. Positive draws later. Measured once
  /// per screen by the tap test; nought until then.
  int offsetMs = 0;

  /// How long a palette takes to ease to the next record's, and a hit to fade.
  static const paletteEase = Duration(seconds: 2);
  static const hitFade = Duration(milliseconds: 350);

  late ShowState _state;
  @override
  ShowState get state => _state;

  final _events = StreamController<ShowEvent>.broadcast(sync: true);
  @override
  Stream<ShowEvent> get events => _events.stream;

  Ticker? _ticker;
  DateTime? _last;
  bool get running => _ticker?.isActive ?? false;

  ShowMacros _macros = ShowMacros.none;
  ShowMacros get macros => _macros;

  /// Which scene is on: see show_director.dart. Its scenes are handed in by whoever
  /// loaded the scene files (the stage, the room's clock).
  final director = ShowDirector();

  /// The hits and the exposure: see show_dynamics.dart.
  final dynamics = ShowDynamics();
  ShowPalette _palette = ShowPalette.house;
  String _masterName = 'A';
  Genome _genome = Genome.none;
  int? _genomeTrack;

  /// Said by the booth between frames, told on the next.
  final _pending = <ShowEvent>[];
  final _askedVocals = <int>{};

  void start() {
    if (_ticker != null) return;
    _ticker = Ticker(_onTick)..start();
  }

  void stop() {
    _ticker?.dispose();
    _ticker = null;
    _last = null;
  }

  void _onTick(Duration _) => tick(DateTime.now());

  // ------------------------------------------------------------------ the hands
  void setMacros(ShowMacros m) {
    _macros = m;
    if (!running) tick(DateTime.now());
  }

  /// The performer hit the show: a flash that fades over [hitFade]. [at] for a test
  /// driving the clock by hand.
  void hit({DateTime? at}) {
    final now = at ?? DateTime.now();
    _hitAt = now;
    _pending.add(ShowEvent(ShowEventKind.hit, now));
    if (!running) tick(now);
  }

  DateTime? _hitAt;

  /// The performer's hands on the scenes.
  void nextScene() => director.next();
  void previousScene() => director.next(by: -1);
  void chooseScene(String id) => director.choose(id);

  void _stepSaid() {
    final s = booth.stepApplied.last;
    if (s == null) return;
    _pending.add(ShowEvent(ShowEventKind.step, DateTime.now(), data: {'at': s.at, 'crossfader': s.crossfader}));
  }

  void _fxSaid() {
    final f = booth.fxFired.last;
    if (f == null) return;
    _pending.add(ShowEvent(ShowEventKind.fx, DateTime.now(), data: {'sound': f.sound.name, 'beats': f.beats}));
  }

  // ------------------------------------------------------------------ the frame
  /// One frame, at [now]. Public for a test; the ticker calls it.
  void tick(DateTime now) {
    final last = _last;
    final dt = last == null ? 0.0 : now.difference(last).inMicroseconds / 1e6;
    _last = now;
    final prev = _state;

    final levels = booth.levels;
    final a = _deck(booth.a, now, levels.a);
    final b = _deck(booth.b, now, levels.b);

    // Which deck has the room: the louder channel, and it keeps it until the other
    // is clearly louder — a fader at the middle must not flip the show every frame.
    final cur = _masterName == 'B' ? b : a, oth = _masterName == 'B' ? a : b;
    final curLoud = cur.playing ? cur.level : 0.0, othLoud = oth.playing ? oth.level : 0.0;
    if (othLoud > curLoud + 0.2 || (curLoud == 0 && othLoud > 0)) _masterName = oth.name;
    final master = _masterName == 'B' ? b : a;

    // The record's genome, drawn once per record on the master deck.
    if (master.trackId != _genomeTrack) {
      _genomeTrack = master.trackId;
      _genome = master.trackId == null
          ? Genome.none
          : Genome.of(trackId: master.trackId!, camelot: master.camelot, bpm: master.bpm, cover: master.coverColor);
    }

    final m = booth.mixing;
    final arm = booth.arming;
    final mix = m != null
        ? ShowMix(on: true, kind: m.kind.name, from: m.from, to: m.to, bars: m.bars, k: m.k)
        : arm != null
            ? ShowMix(armed: true, kind: arm.kind.name, from: arm.from, to: arm.to, startsIn: arm.startsAt.difference(now))
            : ShowMix.none;

    // The palette eased towards the record's.
    final want = paletteFor(
      coverColor: master.coverColor,
      keyHue: master.keyHue,
      section: master.section,
      colourTurn: _macros.colour + _genome['palette.turn'],
      apart: _genome.isEmpty ? null : _genome['palette.apart'],
    );
    final ease = dt <= 0 ? 1.0 : (dt / (paletteEase.inMicroseconds / 1e6)).clamp(0.0, 1.0);
    _palette = _palette.lerp(want, ease);

    // The hit, fading from when it landed.
    final hitAt = _hitAt;
    final hit = hitAt == null
        ? 0.0
        : (1 - now.difference(hitAt).inMicroseconds / hitFade.inMicroseconds).clamp(0.0, 1.0);
    if (hit != _macros.hit) _macros = _macros.copyWith(hit: hit);

    _state = ShowState(
      now: now,
      dt: dt,
      a: a,
      b: b,
      masterName: _masterName,
      audio: a.audio + b.audio,
      mix: mix,
      palette: _palette,
      macros: _macros,
      genome: _genome,
    );
    _state = _state.copyWith(dyn: {...dynamics.frame(_state, dt), ...CameraFeed.shared.numbers});

    final said = eventsBetween(prev, _state);
    if (_pending.isNotEmpty) {
      said.addAll(_pending);
      _pending.clear();
    }
    // The director's word on the scene, and its hit where it cut on a drop.
    final d = director.direct(_state, said);
    if (director.takeHit()) {
      _hitAt = now;
      _macros = _macros.copyWith(hit: 1);
      said.add(ShowEvent(ShowEventKind.hit, now, data: const {'by': 'director'}));
    }
    _state = _state.copyWith(
      scene: d.scene,
      sceneFrom: d.from,
      sceneK: d.k,
      clearSceneFrom: d.from == null,
      macros: _macros,
    );
    notifyListeners();
    for (final e in said) {
      _events.add(e);
    }
  }

  ShowDeck _deck(Deck deck, DateTime now, double level) {
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

  static ShowState _blank(DateTime now) =>
      ShowState(now: now, a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));

  @override
  void dispose() {
    stop();
    booth.stepApplied.removeListener(_stepSaid);
    booth.fxFired.removeListener(_fxSaid);
    unawaited(_events.close());
    super.dispose();
  }
}

/// A track's words for the engine, where a test wants to hand them in.
extension ShowTrackWords on Track {
  String get showArtist => artists.join(', ');
}
