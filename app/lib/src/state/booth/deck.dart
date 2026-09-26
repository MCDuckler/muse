import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import 'mixer.dart' show StemLevels;
import 'parts.dart';

/// One of the two records on the deck.
///
/// A deck is a player of its own — the engine underneath plays one file at a time, and
/// mixing is two files at once — with the three things a mixer needs to know about it
/// that the player does not say: where it is *right now* (the engine reports a few
/// times a second, which is too coarse to land on a beat), how fast it is going, and
/// where its beats and bars fall.
///
/// The clock is the important part. The last position the engine reported is taken as
/// a fix, and carried forward from the moment it arrived at the deck's tempo; the next
/// report re-anchors it. That is what makes "start on the next downbeat" land on it.
class Deck extends ChangeNotifier {
  Deck(
    this.name, {
    required this.api,
    this.offlinePath,
    this.claiming,
    AudioPlayer? player,
    AndroidEqualizer? equalizer,
  })  : equalizer = equalizer ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android
                ? AndroidEqualizer()
                : null) {
    _player = player ??
        AudioPlayer(
          audioPipeline: this.equalizer == null
              ? null
              : AudioPipeline(androidAudioEffects: [this.equalizer!]),
        );
    _subs.add(_player.positionStream.listen(_anchor));
    _subs.add(_player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) _ended();
      notifyListeners();
    }));
  }

  /// 'A' or 'B'.
  final String name;
  final ApiClient api;
  final String? Function(int trackId)? offlinePath;

  /// Where the parts of a record come from — this computer where there is one, the
  /// server otherwise. Null falls back to asking the server directly.
  PartsStore? parts;

  /// Said just before this deck's player is handed a record, because that is when
  /// the engine underneath finally makes the thing that plays it — a browser makes
  /// its audio element *there*, not when the player is constructed, and the mixer
  /// has to know which deck the next one belongs to. See Mixer.expecting.
  final void Function()? claiming;

  /// What went wrong the last time this deck was asked to hold a record. A deck that
  /// cannot play has to say so: silence is the same sound as a mixer turned down.
  String? trouble;

  /// Android's own, attached to this deck's player: what its kills are done with.
  final AndroidEqualizer? equalizer;

  late final AudioPlayer _player;
  AudioPlayer get player => _player;
  final _subs = <StreamSubscription<dynamic>>[];

  Track? track;
  TrackTiming? timing;

  /// Which part of the record is on the platter: its drums, the music under them, or
  /// the whole of it with the voice taken out. Null is the record itself.
  ///
  /// The parts are made by the server the first time anybody asks for them and kept
  /// after that; see the server's stems.py for what they are and what they are not.
  String? part;

  /// The record is on as its stems — the six-channel file (see PartsStore): every
  /// part is then just levels ([stemLevels]), turned with no gap, rather than another
  /// file loaded in the record's place.
  bool stemmed = false;

  /// How loud each stem is, where [stemmed].
  StemLevels stemLevels = StemLevels.all;

  /// Whether the engine here can play stems at all, and the booth's hands on it: ready
  /// it for the next record, turn the stems. Set by the booth (the mixer's).
  bool canStem = false;
  Future<bool> Function(Deck deck, {required bool stems, double? beatMs})? readyEngine;
  Future<void> Function(Deck deck, StemLevels levels)? stemEngine;
  Future<bool> Function(Deck deck)? firstLoadMissed;

  /// Where the stems of the record going on are, for [_load]: a file or the house.
  String? _stemsFrom;

  /// Turn the stems to [to] — over [over], a step every 20 ms, so a stem coming in or
  /// going out is a move rather than a click.
  Future<void> setStemLevels(StemLevels to, {Duration over = const Duration(milliseconds: 120)}) async {
    if (!stemmed) return;
    final from = stemLevels;
    final steps = (over.inMilliseconds / 20).ceil().clamp(1, 200);
    for (var i = 1; i <= steps; i++) {
      final l = from.lerp(to, i / steps);
      stemLevels = l;
      await stemEngine?.call(this, l);
      if (i < steps) await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    notifyListeners();
  }

  /// A part has been asked for and is being made. Nothing changes on the deck while
  /// this is true — the record it is holding keeps playing — but the booth says so,
  /// because "in a minute" and "no" are different answers.
  bool makingPart = false;

  /// Parts this record does not get, as last answered: every one of them for a record
  /// longer than a record, which nobody spends twenty minutes on; the voice on its own
  /// where the separator cannot run, since nothing else makes that one; any of them
  /// once its taking apart was cancelled. Kept so the booth can say "not this one"
  /// rather than "in a minute" for ever.
  final neverParts = <String>{};

  /// Whether this record gets taken apart at all, as far as anybody has said.
  bool get noParts => neverParts.containsAll(const ['drums', 'music', 'instrumental']);

  /// The rate the engine is playing it at right now: 1.0 is the record as recorded.
  /// Usually the same as [pitch]; a little either side of it while the booth holds
  /// this record on another's beat.
  double tempo = 1.0;

  /// The rate the deck is set to: its pitch fader, SYNC.
  double pitch = 1.0;

  /// SYNC is on: this deck follows the other — its tempo matched to the other's, and
  /// its beat held on the other's for as long as both play. See Booth.setSync.
  bool synced = false;

  /// Where, with SYNC on, this deck's beat is held against the other's: ahead by this
  /// much. Nought unless somebody nudged it there by ear — a grid can be a little off
  /// for one record, and a nudge that the holding undid again would be no use at all.
  Duration syncTrim = Duration.zero;

  bool get playing => _player.playing && !_ended_;
  bool _ended_ = false;
  bool get loaded => track != null;

  Duration? get duration => _player.duration ?? track?.duration;

  // ------------------------------------------------------------------ the clock
  Duration _fix = Duration.zero;
  DateTime _fixedAt = DateTime.now();

  /// A report from the engine, folded into the deck's clock.
  ///
  /// The engine says where it is every few tens of milliseconds, and each report is
  /// off by as much again (mpv's, measured: ±12 ms about the true line, 25 ms at
  /// worst). Taken as gospel, every one of them moved the clock — and everything lined
  /// up to it, the beat-holding most of all, twitched with it. So a report only pulls
  /// the clock a little way towards itself, and the clock runs on at the deck's rate
  /// between: steady to a couple of milliseconds. A report far from where the clock
  /// is — a seek, a start, a stall, a loop jumping back — is believed outright.
  void _anchor(Duration at) {
    final now = DateTime.now();
    if (!_trusting || !playing) {
      _fix = at;
      _fixedAt = now;
      _trusting = playing;
      return;
    }
    final expected = positionAt(now);
    final off = at - expected;
    if (off.abs() > const Duration(milliseconds: 80)) {
      // The engine says it is somewhere else, by more than its reports ever wander:
      // believed, and said in the log — a record the booth did not move, moving, is
      // what "it twitched" is. (A loop coming round is expected, and not said.)
      if (loopStart == null) {
        debugPrint('deck: $name moved ${off.inMilliseconds} ms by itself at ${at.inMilliseconds} ms');
      }
      _fix = at;
    } else {
      _fix = expected + off * 0.12;
    }
    _fixedAt = now;
  }

  /// Whether the clock is running on reports, and so only nudged by them. False
  /// after anything that moves the record at once, until the next report.
  bool _trusting = false;

  /// A fix from outside — the tests, mostly.
  @visibleForTesting
  void anchor(Duration at, DateTime when) {
    _fix = at;
    _fixedAt = when;
    _trusting = false;
  }

  /// Where the record is *now*, carried forward from the last fix while it plays.
  Duration positionAt(DateTime now) {
    if (!playing) return _fix;
    final since = now.difference(_fixedAt);
    final moved = Duration(microseconds: (since.inMicroseconds * tempo).round());
    final at = _fix + moved;
    final end = duration;
    return end != null && end > Duration.zero && at > end ? end : at;
  }

  Duration get position => positionAt(DateTime.now());

  /// Beats a minute, as the deck says it: the record's own figure at the deck's
  /// [pitch]. The number SYNC matches, and one that holds still — the small bends the
  /// booth makes to keep two records on the beat are the engine's, not the deck's,
  /// and never show here. The record's figure is its steady grid's
  /// (TrackTiming.gridBpm), which is also what the beat-holding holds: a number on
  /// show that differed from the grid by a tenth of a per cent was a tenth of a per
  /// cent the holding had to lean against for the whole mix.
  double? get bpm {
    final own = timing?.gridBpm;
    return own == null ? null : own * pitch;
  }

  bool get hasBeats => timing?.hasBeats ?? false;

  /// The platter is being stopped by hand: nothing should be lined up to it.
  bool braking = false;

  // ------------------------------------------------------------------ beats and bars
  /// Which beat the record is on and how far through it, at [now]: on the steady grid,
  /// the one the beat-holding uses.
  ({int index, double phase})? beatAt(DateTime now) {
    final b = timing?.smoothBeatAt(positionAt(now));
    return b == null ? null : (index: b.index, phase: b.phase);
  }

  /// The record's next beat at or after [at], as a place in the file — or, with
  /// [every] beats, the next beat whose index (from the bar's first beat) is a
  /// multiple of it: 4 for the next downbeat, 16 for the next four-bar phrase.
  Duration? nextBeat(Duration at, {int every = 1}) {
    final t = timing;
    if (t == null || !t.hasBeats) return null;
    // On the steady grid where there is one: a start or a loop timed off a beat the
    // analysis placed a frame out is a start or a loop that frame out.
    if (t.steady != null) return t.nextOnGrid(at, every: every);
    final ms = at.inMilliseconds;
    final beats = t.beats;
    var i = 0;
    while (i < beats.length && beats[i] < ms) {
      i++;
    }
    if (every > 1) {
      // Counted from where the bar starts, so "every 4" is downbeats.
      while (i < beats.length && (i - t.barStartsOn) % every != 0) {
        i++;
      }
    }
    return i < beats.length ? Duration(milliseconds: beats[i]) : null;
  }

  /// How long, by the wall clock, until this deck's next beat (or bar, phrase): the
  /// record's time to it, divided by the tempo it is playing at. Null when it is not
  /// playing or has no beats.
  Duration? untilNextBeat(DateTime now, {int every = 1}) {
    if (!playing) return null;
    final at = positionAt(now);
    final next = nextBeat(at, every: every);
    if (next == null) return null;
    final inFile = next - at;
    return Duration(microseconds: (inFile.inMicroseconds / tempo).round());
  }

  /// The length of one beat at this tempo, or null with no pulse.
  Duration? get beat {
    final b = bpm;
    return b == null || b <= 0 ? null : Duration(microseconds: (60e6 / b).round());
  }

  // ------------------------------------------------------------------ loading and transport
  /// One deck at a time takes its turn at the engine, across both of them.
  ///
  /// Not for the engine's sake but for the browser's: the page recognises a deck's
  /// audio element by which deck said it was about to make one, and two loads
  /// overlapping would have the second deck claim the first one's element — which is
  /// exactly the bug that made the booth play one record and not the other. It is
  /// only the claim and the handover that are taken in turn; whatever a load has to
  /// ask the server for happens before the turn is taken, and a turn that somehow
  /// never ends is given up on rather than stopping the other deck for good.
  static Future<void> _turn = Future.value();
  static const _waitForATurn = Duration(seconds: 8);

  /// Put [track] on, parked at [at] — its first sound, unless told otherwise. With a
  /// [part], that part of it rather than the whole record.
  Future<void> load(Track track,
      {TrackTiming? timing, Duration? at, String? part}) async {
    this.part = part;
    // Its stems where the engine can play them and they are made — here, or at the
    // house: then every part of it is only levels.
    _stemsFrom = null;
    final store = parts;
    // What this deck had on is not going to be played here now: if it is still only
    // waiting to be taken apart on this computer, the pool can have it.
    final was = this.track;
    if (store != null && was != null && was.id != track.id) store.backToPool(was);
    if (canStem && store != null) {
      try {
        final got = await store.want(track, 'stems').timeout(const Duration(seconds: 4));
        if (got == Stem.ready) {
          _stemsFrom = store.pathFor(track.id, 'stems') ?? api.stemUrl(track, 'stems');
        }
        debugPrint('deck $name: stems for ${track.id} — $got${_stemsFrom == null ? '' : ' from $_stemsFrom'}');
      } catch (e) {
        debugPrint('deck $name: could not ask for the stems of ${track.id}: $e');
      }
    }
    // A stream is signed and the signature ages out, so it is refreshed before a
    // load — but never at the price of the load itself: a deck that cannot reach the
    // server still plays what is kept on the device.
    if (part != null ||
        offlinePath?.call(track.id) == null ||
        (_stemsFrom?.startsWith('http') ?? false)) {
      try {
        await api.ensureStreamKey().timeout(const Duration(seconds: 5));
      } catch (_) {
        // An old key, or none: the request that follows will say so plainly.
      }
    }
    final before = _turn;
    final mine = Completer<void>();
    _turn = mine.future;
    try {
      await before.timeout(_waitForATurn, onTimeout: () {});
      await _load(track, timing: timing, at: at);
    } finally {
      mine.complete();
    }
  }

  Future<void> _load(Track track, {TrackTiming? timing, Duration? at}) async {
    // What is already known about this record is not forgotten because the server
    // could not be asked again: a deck that loses its grid loses its sync, its loop
    // and its beat light, and the grid had not changed.
    final same = this.track?.id == track.id;
    final knew = same ? this.timing : null;
    // A different record starts at its own speed: the pitch the last one was left at
    // is nothing to do with this one, and a deck that showed a record at another
    // record's pitch showed a BPM that was neither's.
    if (!same) {
      pitch = 1.0;
      tempo = 1.0;
      syncTrim = Duration.zero;
    }
    this.track = track;
    this.timing = timing ?? knew;
    _ended_ = false;
    trouble = null;
    neverParts.clear();
    hotCues.clear();
    loopStart = loopEnd = null;
    _loopBars = null;
    // Parked where a DJ would drop it: on the first downbeat, if there is one — on the
    // steady grid, so a start timed off it lands on the beat.
    final first = this.timing?.cues?.firstDownbeat;
    final start = at ??
        (first == null ? null : this.timing!.onGrid(first)) ??
        this.timing?.lead ??
        Duration.zero;
    try {
      claiming?.call();
      final stems = _stemsFrom != null;
      final beatMs = timing?.bar == null ? null : timing!.bar!.inMicroseconds / 4000;
      stemmed = await readyEngine?.call(this, stems: stems, beatMs: beatMs) ?? false;
      stemLevels = StemLevels.all;
      await _player.setAudioSource(_sourceFor(track), initialPosition: start);
      // The engine only exists once something is on it: the first record goes on
      // again, parked, with what could not be set before it (the stems, the clock).
      if (await firstLoadMissed?.call(this) ?? false) {
        stemmed = await readyEngine?.call(this, stems: stems, beatMs: beatMs) ?? false;
        await _player.setAudioSource(_sourceFor(track), initialPosition: start);
      }
      if (!stemmed) _stemsFrom = null;
      if (stemmed) {
        stemLevels = StemLevels.of(part);
        await stemEngine?.call(this, stemLevels);
      }
      if (_player.speed != tempo) await _player.setSpeed(tempo);
    } catch (e) {
      trouble = '$e';
      notifyListeners();
      rethrow;
    }
    _anchor(start);
    notifyListeners();
  }

  AudioSource _sourceFor(Track track) {
    final local = offlinePath?.call(track.id);
    final tag = MediaItem(
      id: 'deck-$name-${track.id}',
      title: track.displayTitle,
      artist: track.artistLine,
      duration: track.duration,
    );
    final stems = stemmed ? _stemsFrom : null;
    if (stems != null) {
      return stems.startsWith('http')
          ? AudioSource.uri(Uri.parse(stems), headers: kIsWeb ? null : api.streamHeaders, tag: tag)
          : AudioSource.uri(Uri.file(stems), tag: tag);
    }
    if (part == null) {
      if (local != null) return AudioSource.uri(Uri.file(local), tag: tag);
    } else {
      // A part this computer made itself: no network, no waiting.
      final mine = parts?.pathFor(track.id, part!);
      if (mine != null) return AudioSource.uri(Uri.file(mine), tag: tag);
    }
    return AudioSource.uri(
      Uri.parse(part == null ? api.streamUrl(track) : api.stemUrl(track, part!)),
      headers: kIsWeb ? null : api.streamHeaders,
      tag: tag,
    );
  }

  /// Change which part of the record is playing, without taking it off: the drums
  /// alone, the music under them, the whole of it with the voice out, or — with null
  /// — the record as it was made.
  ///
  /// Answers false, having asked for it to be made, when that part does not exist
  /// yet. Nothing changes in that case: the record carries on, and the booth says a
  /// part is being made rather than going quiet. [byHand] is a person pressing for it
  /// (see PartsStore.want), not a transition or the automix.
  ///
  /// There is a real seam here. One deck is one player and one player holds one file,
  /// so the swap is a load, and a load is a fraction of a second of nothing. It lands
  /// where the record would have been, and the mixer re-aligns the phase after it, but
  /// it is a gap all the same — which is why the moves that use it put it under
  /// another record rather than in the clear.
  Future<bool> swapTo(String? part, {bool byHand = false}) async {
    final t = track;
    if (t == null || part == this.part) return true;
    // A stem deck has every part already: it is only the levels, and no gap at all.
    if (stemmed) {
      this.part = part;
      await setStemLevels(StemLevels.of(part));
      notifyListeners();
      return true;
    }
    if (part != null) {
      makingPart = true;
      notifyListeners();
      Stem state;
      try {
        final store = parts;
        state = store != null
            ? await store.want(t, part, byHand: byHand)
            : await api.stemState(t, part);
      } catch (_) {
        // The server could not be asked. Not the deck's problem to report: it is
        // still holding a record and still playing it.
        state = Stem.beingMade;
      }
      makingPart = false;
      // The answer is about the record that was asked about — which may not be the
      // one on the deck any more.
      if (track?.id != t.id) return false;
      // The voice alone is the one part a record can lack on its own: only the
      // separator makes it. Any other "never" is about the record — too long, or
      // taken off the list — and any other answer says that no longer holds.
      const record = ['instrumental', 'drums', 'music'];
      if (state == Stem.never) {
        neverParts
          ..add(part)
          ..addAll(part == 'vocals' ? const <String>[] : record);
      } else {
        neverParts
          ..remove(part)
          ..removeAll(record);
      }
      if (state != Stem.ready) {
        notifyListeners();
        return false;
      }
    }
    final was = playing;
    final at = position;
    this.part = part;
    final before = _turn;
    final mine = Completer<void>();
    _turn = mine.future;
    try {
      await before.timeout(_waitForATurn, onTimeout: () {});
      claiming?.call();
      // Where the record will be when the load is done, not where it is now: a load
      // takes a moment, and a deck that comes back a moment behind is out of time.
      final began = DateTime.now();
      await _player.setAudioSource(_sourceFor(t), initialPosition: at);
      if (tempo != 1.0) await _player.setSpeed(tempo);
      var there = at;
      if (was) {
        final took = DateTime.now().difference(began);
        there = at + Duration(microseconds: (took.inMicroseconds * tempo).round());
        await _player.seek(there);
      }
      // The clock starts again from where the new file was put, not from reports
      // about the old one.
      _fix = there;
      _fixedAt = DateTime.now();
      _trusting = false;
    } catch (e) {
      trouble = '$e';
      notifyListeners();
      return false;
    } finally {
      mine.complete();
    }
    // Started and let go of, after the turn is handed back: just_audio's own play()
    // completes when playback stops, and awaited inside the turn it held every other
    // load — the other deck's next record included — behind this one.
    if (was) await play();
    notifyListeners();
    return true;
  }

  /// Start the record, and return once it is playing — not once it has stopped.
  ///
  /// just_audio's own play() completes when playback *ends*, on the engines that
  /// keep that promise (a phone's): awaited, a transition starting a record would sit
  /// there until the record was over. So it is started and let go of, and this waits
  /// only for the engine to say it is playing.
  Future<void> play() async {
    _ended_ = false;
    _fixedAt = DateTime.now();
    _trusting = false;
    unawaited(_player.play().catchError((Object e) {
      trouble = '$e';
      notifyListeners();
    }));
    if (!_player.playing) {
      try {
        await _player.playingStream
            .firstWhere((p) => p)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Said nothing: the deck reads as not playing, which is what the booth checks.
      }
    }
    _fixedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> pause() async {
    _fix = position;
    await _player.pause();
    _fixedAt = DateTime.now();
    _trusting = false;
    notifyListeners();
  }

  Future<void> seek(Duration to) async {
    _fix = to;
    _fixedAt = DateTime.now();
    _trusting = false;
    await _player.seek(to);
    notifyListeners();
  }

  /// A little forwards or back, to bring the beats in line: the DJ's nudge.
  Future<void> nudge(Duration by) => seek(position + by);

  /// Set the deck's pitch: what the fader says, what SYNC sets, what the deck's BPM
  /// is worked out from.
  Future<void> setTempo(double rate) async {
    pitch = rate.clamp(0.5, 2.0);
    await bend(pitch);
  }

  /// Run the engine at [rate] without moving the deck's pitch: the booth holding two
  /// records on the beat. Put back with `bend(pitch)`.
  Future<void> bend(double rate) async {
    _fix = position;
    _fixedAt = DateTime.now();
    tempo = rate.clamp(0.5, 2.0);
    await _player.setSpeed(tempo);
    notifyListeners();
  }

  void _ended() {
    _ended_ = true;
    _loop?.cancel();
    notifyListeners();
  }

  // ------------------------------------------------------------------ cues and loops
  /// Places in the record a button jumps to.
  final Map<int, Duration> hotCues = {};

  /// Said when something outside changed what this deck holds — a cue cleared, say.
  void changed() => notifyListeners();

  void setCue(int n, [Duration? at]) {
    hotCues[n] = at ?? position;
    notifyListeners();
  }

  Future<void> jumpCue(int n) async {
    final at = hotCues[n];
    if (at != null) await seek(at);
  }

  Duration? loopStart;
  Duration? loopEnd;

  /// The engine's own loop, where it has one (mpv's A–B loop on a desk): set by the
  /// booth. Says whether the engine took it; where it did not, the deck loops itself.
  Future<bool> Function(Duration? from, Duration? to)? engineLoop;
  bool _engineLooping = false;

  Future<void> _loopInEngine() async {
    final f = engineLoop;
    if (f == null) return;
    final took = await f(loopStart, loopEnd);
    _engineLooping = took && loopStart != null;
    if (_engineLooping) {
      _loop?.cancel();
    } else if (loopStart != null) {
      _watchLoop();
    }
  }

  /// How many bars the loop is, when there is one: what the buttons light by.
  int? get loopBars => loopStart == null ? null : _loopBars;
  int? _loopBars;
  Timer? _loop;

  /// One beat as a stretch of the record itself: the length a loop is counted in. Not
  /// [beat], which is a beat by the wall clock at the deck's pitch — a loop measured in
  /// that on a deck at 1.07× came round 7 % short of its bars and stumbled off the beat.
  Duration get beatInRecord {
    final t = timing;
    final s = t?.steady;
    if (s != null) return Duration(microseconds: (s.period * 1000).round());
    final own = t?.gridBpm;
    return own == null || own <= 0
        ? const Duration(milliseconds: 500)
        : Duration(microseconds: (60e6 / own).round());
  }

  /// What is playing, as the engine was handed it: the file or the stream, and what to
  /// send with it. What a loop's seam is read from.
  ({String uri, Map<String, String>? headers})? get sourceNow {
    final t = track;
    if (t == null) return null;
    final p = part;
    final local = p == null ? offlinePath?.call(t.id) : parts?.pathFor(t.id, p);
    if (local != null) return (uri: Uri.file(local).toString(), headers: null);
    return (
      uri: p == null ? api.streamUrl(t) : api.stemUrl(t, p),
      headers: kIsWeb ? null : api.streamHeaders,
    );
  }

  /// Reads where a loop's seam will not click (the booth's mixer: see seam.dart).
  Future<(Duration, Duration)?> Function(Deck deck, Duration start, Duration end)? seamFinder;

  /// Move the loop's two ends to where its seam will not click, once the sound there
  /// has been read — well before the first time round, which is a bar away at least.
  /// Nothing moves if the loop has changed in the meantime.
  Future<void> _quietSeam() async {
    final finder = seamFinder, from = loopStart, to = loopEnd;
    if (finder == null || from == null || to == null) return;
    final quiet = await finder(this, from, to);
    if (quiet == null || loopStart != from || loopEnd != to) return;
    loopStart = quiet.$1;
    loopEnd = quiet.$2;
    await _loopInEngine();
  }

  /// Go round [beats] beats from the next downbeat (or from here, with no grid).
  void loop(int beats) {
    // From this bar's one where the deck has just passed it — within a beat — rather
    // than the next one: a transition's steps land on downbeats, and a loop caught on
    // the step was starting a bar after it, which put every rung of a roll a bar late
    // and the last one past the end of the move.
    final next = nextBeat(position, every: 4) ?? position;
    final bar = beatInRecord * 4;
    final prev = next - bar;
    final from = next - position > beatInRecord * 3 && prev >= Duration.zero ? prev : next;
    loopStart = from;
    loopEnd = from + beatInRecord * beats;
    _loopBars = beats ~/ 4;
    _watchLoop();
    unawaited(_loopInEngine().then((_) => _quietSeam()));
    notifyListeners();
  }

  /// Half the loop, from where it starts: 4 bars, 2, 1, half a bar — the roll that
  /// tightens as a record goes out. Floors at an eighth of a beat, below which it is
  /// a tone rather than a rhythm.
  void halveLoop() {
    final from = loopStart, to = loopEnd;
    if (from == null || to == null) return;
    final now = to - from;
    final least = beatInRecord ~/ 8;
    if (now <= least) return;
    loopEnd = from + now ~/ 2;
    _loopBars = null;                  // no longer one of the buttons' lengths
    unawaited(_loopInEngine().then((_) => _quietSeam()));
    notifyListeners();
  }

  /// The record braking to a stop, the way a hand on the platter does it: the rate
  /// falls away over [over] and the deck is left parked, at the pitch it was set to.
  ///
  /// Not a backspin — a browser's audio element will not play backwards, so what is
  /// offered is the half of it that every engine here can actually do.
  ///
  /// The pitch falls with the rate. The engines here stretch — Rubber Band, or mpv's
  /// own — and a stretcher's whole job is to keep the pitch while the rate moves, so
  /// a rate run down to nothing through one is a record getting slower at the same
  /// pitch: a stutter, not a platter. Where the desk can shift pitch ([pitchEngine]),
  /// it is shifted down by the same ratio at every step, which is what a platter does.
  ///
  /// [over] defaults to two of the record's beats, so a brake is the same musical
  /// length at any tempo.
  Future<void> brake({Duration? over}) async {
    if (!playing) return;
    braking = true;
    final was = tempo;
    final length = over ??
        Duration(microseconds: ((beat ?? const Duration(milliseconds: 450)).inMicroseconds * 2)
            .clamp(600000, 1400000));
    const steps = 18;
    for (var i = 1; i <= steps; i++) {
      _fix = position;
      _fixedAt = DateTime.now();
      tempo = (was * (1 - i / steps)).clamp(_slowest, 2.0);
      try {
        await _player.setSpeed(tempo);
        // The pitch, down by the same ratio: semitones = 12·log2(rate / rate before).
        await pitchEngine?.call(this, 12 * math.log(tempo / was) / math.ln2);
      } catch (_) {
        break;                          // an engine that will not crawl: stop here
      }
      notifyListeners();
      await Future<void>.delayed(length ~/ steps);
    }
    await pause();
    braking = false;
    tempo = was;
    try {
      await _player.setSpeed(was);
      await pitchEngine?.call(this, 0);
    } catch (_) {}
    notifyListeners();
  }

  /// The desk's pitch shift for this deck, in semitones, where it has one: what the
  /// brake falls through. Set by the booth.
  Future<void> Function(Deck deck, double semitones)? pitchEngine;

  /// The slowest an engine can be asked to run without refusing outright.
  static const _slowest = 0.12;

  void unloop() {
    final was = loopStart != null;
    loopStart = loopEnd = null;
    _loopBars = null;
    _loop?.cancel();
    if (was || _engineLooping) unawaited(_loopInEngine());
    _engineLooping = false;
    notifyListeners();
  }

  void _watchLoop() {
    _loop?.cancel();
    _loop = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final end = loopEnd, start = loopStart;
      if (end == null || start == null || !playing || _engineLooping) return;
      if (position >= end) unawaited(seek(start));
    });
  }

  // A load can still be under way when the booth goes (the automix prepares in the
  // background): it finishes without a word.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loop?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
