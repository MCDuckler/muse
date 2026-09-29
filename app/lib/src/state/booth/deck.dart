import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../playback_log.dart';
import 'deck_router.dart';
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
          // libmpv where this device sends decks there (an iPhone's, an iPad's).
          engine: DeckRouter.active ? DeckRouter.mpv : null,
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
  /// The stems moved to [to] over [over] — by the clock on the wall, not by counting
  /// steps.
  ///
  /// It used to be a fixed number of twenty-millisecond steps with the engine awaited
  /// inside each one, so the true length was the ramp *plus* every round trip it took:
  /// six steps of three mpv commands each, and a part changed by hand took a third of
  /// a second to be heard rather than the tenth it asked for. Now the shape is read
  /// off the elapsed time, so a slow engine takes fewer, larger steps and the move
  /// still lasts [over]. (The same way VolumeMixer ramps the crossfader.)
  Future<void> setStemLevels(StemLevels to, {Duration over = const Duration(milliseconds: 120)}) async {
    if (!stemmed) return;
    final from = stemLevels;
    if (over <= Duration.zero) {
      stemLevels = to;
      await stemEngine?.call(this, to);
      notifyListeners();
      return;
    }
    const step = Duration(milliseconds: 20);
    final began = DateTime.now();
    var slot = step;
    while (true) {
      final k =
          (DateTime.now().difference(began).inMicroseconds / over.inMicroseconds)
              .clamp(0.0, 1.0);
      stemLevels = k >= 1 ? to : from.lerp(to, k);
      await stemEngine?.call(this, stemLevels);
      if (k >= 1) break;
      final wait = slot - DateTime.now().difference(began);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      slot += step;
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
    _watchTheWrap(at, now);
    // A seek asked for and not yet arrived: the engine goes on reporting where it
    // still is for a few frames, and those frames are a lie about where the record is.
    //
    // Taken at face value they were the worst of the jitter: every report during a
    // drag fell into the `!_trusting` branch below and put the playhead *back* where
    // the engine had not yet left, so the record fought the finger all the way across.
    // Reports are ignored until one lands near where the seek was aimed — or until it
    // is plain the seek is not going to be answered.
    final settling = _settling;
    if (settling != null) {
      if ((at - settling).abs() <= const Duration(milliseconds: 120)) {
        _settling = null;
      } else if (now.difference(_settlingAt) < const Duration(milliseconds: 1500)) {
        return;
      } else {
        // The engine never got there. Believe it again rather than freeze the screen.
        _settling = null;
      }
    }
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
      // A twelfth of the difference each report, which keeps the clock from twitching
      // with every one — and, it turns out, is most of what keeps the beat-holding
      // stable. The reckoning runs *ahead* of the engine's reports by whatever the
      // engine is slow by, which makes it a predictor; the loop reading it therefore
      // sees less delay than the engine really has. Trusting the reports harder just
      // after a rate change was tried, on the reasoning that the reckoning is wrong
      // then — and it measured worse (34 ms still out after four seconds against
      // under 20), because it hands that delay straight back to the loop.
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
    var at = _fix + moved;
    // A loop carried in the filter chain hands the same samples round again without
    // the engine knowing, so the engine's own clock walks straight on past the loop's
    // end for ever. What is *heard* is the loop, so what is reported is folded into it.
    // Everything else on this deck reads the record through here, so folding once here
    // is folding everywhere — and the needle comes round with no report to wait for,
    // which is a loop that teleports rather than one that travels.
    if (_chainLooping) {
      final s = loopStart, e = loopEnd;
      if (s != null && e != null && e > s && at >= e) {
        final len = (e - s).inMicroseconds;
        at = s + Duration(microseconds: (at - s).inMicroseconds % len);
      }
    }
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
    _freshlyLoaded = true;
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
    _sayIfTheLengthsDisagree();
    _sayIfTheGridsDisagree();
    notifyListeners();
  }

  /// Notes it when the engine and the analysis disagree about how long the record is.
  ///
  /// They are two different measurements of the same file and they are normally the
  /// same to the millisecond. When they are not, everything drawn from one slides
  /// against everything drawn from the other — the waveform against the grid over it,
  /// worse the further through the record you are — and that is invisible from here
  /// and obvious on the machine it happens on. So it is written down rather than
  /// guessed at: a tenth of a percent of a four-minute record is a quarter of a beat,
  /// and a percent is two.
  void _sayIfTheLengthsDisagree() {
    final said = timing?.durationMs ?? 0;
    final engine = _player.duration?.inMilliseconds ?? 0;
    if (said <= 0 || engine <= 0) return;
    final off = engine - said;
    if (off.abs() < said * 0.001) return;
    PlaybackLog.note('DECK $name ${track?.displayTitle}: engine says $engine ms, '
        'the analysis says $said ms — ${off > 0 ? '+' : ''}$off ms '
        '(${(off / said * 100).toStringAsFixed(2)}%)');
  }

  /// Notes it when the four-bar rules do not sit on the grid drawn under them.
  ///
  /// The rules are the house's milliseconds, printed where they were given. The beat
  /// ticks beside them — and SYNC, and the beat-holding — come from the straight line
  /// fitted to those same beats here. Where the two agree, which is nearly always, a
  /// rule passes through a tick. Where they do not, the rules stand between the ticks,
  /// a phrase looks like it starts off the beat, and the drop that starts it looks a
  /// beat or two from its own marker — which is what it was reported as. Invisible
  /// from here; plain on the machine it happens on, so it is written down.
  void _sayIfTheGridsDisagree() {
    final t = timing;
    final s = t?.steady;
    if (t == null || s == null) return;
    final marks = t.markers;
    if (marks.isEmpty) return;
    var worst = 0.0;
    var at = 0;
    for (final m in marks) {
      final k = (m - s.origin) / s.period;
      final off = ((k - k.roundToDouble()).abs() * s.period);
      if (off > worst) {
        worst = off;
        at = m;
      }
    }
    // A millisecond or two is rounding. Half a beat is a different grid.
    if (worst < 12) return;
    PlaybackLog.note('DECK $name ${track?.displayTitle}: a four-bar rule sits '
        '${worst.round()} ms off the beat grid drawn under it (at $at ms, '
        'period ${s.period.toStringAsFixed(2)} ms, ${marks.length} rules)');
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
      // Read *here*, not before the wait above. That wait is the other deck's turn at
      // the engine and lasts as long as its load — up to [_waitForATurn] — and the
      // record plays on through all of it. Taken beforehand, the part came back that
      // whole wait behind the beat, and only when the other deck happened to be
      // loading: which is what "changing the stems misaligns it, sometimes" was.
      final at = position;
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
    final fresh = _freshlyLoaded;
    _freshlyLoaded = false;
    // A loop already on: its next wrap is aimed at from here, not from wherever it was
    // when the record was stopped.
    if (_engineLooping) _meetTheWrap();
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
    // The first sound out of a record that has just gone on: see [refreshFilters].
    // Out here rather than inside the wait, because an engine that was already playing
    // when it was asked to does not go through it — and that is exactly the case where
    // a record was swapped under a deck that never stopped.
    if (fresh) unawaited(Future<void>.sync(() => refreshFilters?.call()));
    notifyListeners();
  }

  Future<void> pause() async {
    _fix = position;
    _wrapSoon?.cancel();
    await _player.pause();
    _fixedAt = DateTime.now();
    _trusting = false;
    notifyListeners();
  }

  /// The engine's loop coming round, timed: how long it actually took against how
  /// long the loop is worth. The difference is what the wrap costs.
  void _watchTheWrap(Duration at, DateTime now) {
    final start = loopStart, end = loopEnd;
    // Nothing wraps when the chain carries the loop: the engine plays straight on.
    if (_chainLooping) return;
    if (start == null || end == null || !playing || end <= start) {
      _wrappedAt = null;
      return;
    }
    // The deck's own loop times its wraps itself (see _learnTheWrap); this is only
    // for the engine's. Returning rather than clearing matters: this runs on every
    // report the engine sends, and clearing here wiped the other one's last wrap
    // before it could ever measure against it.
    if (!_engineLooping) return;
    // Come round: the engine says it is back near the loop's start when the reckoning
    // had it near the end.
    final span = end - start;
    if (at > start + span ~/ 2 || positionAt(now) < end - span ~/ 2) return;
    final was = _wrappedAt;
    // Twice for one time round: two reports running can both land in the first half
    // of the loop while the reckoning is still in the second, and counting that as
    // two wraps says the loop is a fraction of its length.
    if (was != null && now.difference(was) < span ~/ 3) return;
    // Many times round, not one.
    //
    // This used to answer every wrap on its own, and what it was answering was almost
    // entirely noise. The moment a wrap is seen is the moment a *position report*
    // shows it, and those come a couple of hundred milliseconds apart — so a thirty
    // millisecond effect was being read off a measurement quantised five times
    // coarser than itself. The log says exactly that: +29, -11, +13, -1, +78, -25,
    // -23, +97, -33 ms, and an end pulled 7, 0, 7, 0, 19, 13, 1, 24, 15 ms early
    // after them. It never settled, and a loop end that moves by twenty milliseconds
    // is a loop that is musically short by twenty milliseconds — which at two seconds
    // a time is twelve milliseconds a second of drift against the other deck. The
    // timing being off and the two records colliding were the same fault.
    //
    // Counted over several times round instead, the coarseness falls on the two ends
    // of the run rather than on every reading, so six wraps divide it by five.
    if (was == null) {
      _wrappedAt = now;
      _wrapsSince = 0;
      return;
    }
    // The engine came round without this deck asking it to, so nothing above counted
    // it as a placing and nothing put the filters back. Both matter: the record moved,
    // which is a step in whatever is measuring how the two decks drift, and the graph
    // was flushed, which is the equalizer and the stems gone.
    placed++;
    unawaited(Future<void>.sync(() => refreshFilters?.call()));
    _wrapsSince++;
    if (_wrapsSince < _wrapsToJudge) return;
    final want = Duration(
        microseconds:
            (span.inMicroseconds * _wrapsSince / (tempo <= 0 ? 1 : tempo)).round());
    final late = Duration(
        microseconds: (now.difference(was) - want).inMicroseconds ~/ _wrapsSince);
    _wrappedAt = now;
    _wrapsSince = 0;
    // Anything wilder than the clamp is the wrong thing entirely.
    if (late.abs() > _mostLate * 2) return;
    final want2 = loopLate + Duration(microseconds: (late.inMicroseconds * 0.5).round());
    loopLate = want2 < Duration.zero
        ? Duration.zero
        : want2 > _mostLate
            ? _mostLate
            : want2;
    // Told to the engine while the loop is still running, once it is worth telling:
    // a loop somebody is sitting on should come good under them, not on the next one.
    if ((loopLate - _appliedLate).abs() > const Duration(milliseconds: 6)) {
      _appliedLate = loopLate;
      debugPrint('deck: $name loop wraps ${late.inMilliseconds} ms late; '
          'the end is pulled ${loopLate.inMilliseconds} ms early');
      PlaybackLog.note('BOOTH loop wrap ${late.inMilliseconds} ms late, '
          'end pulled ${loopLate.inMilliseconds} ms early');
      unawaited(_loopInEngine());
    }
  }

  /// The wrap, timed on the deck's own loop — the one every phone and every browser
  /// actually uses.
  ///
  /// [_watchTheWrap] does this for a loop the engine runs, and only for that: on
  /// anything without one, nothing ever measured what a time round really cost, so
  /// nothing ever corrected for it. Two wraps are [span] apart at this rate plus
  /// whatever the seek between them stopped the sound for, so the difference is the
  /// cost, and it is eased into exactly as the engine's is.
  void _learnTheWrap(Duration span, double rate) {
    final now = DateTime.now();
    final was = _wrappedAt;
    // Over several times round, for the reason in [_watchTheWrap]: one is noise.
    // Less so here — this one knows the moment it asked for the seek rather than
    // hearing about it from a report — but a seek's cost varies by more than it is,
    // and averaging costs nothing.
    if (was == null) {
      _wrappedAt = now;
      _wrapsSince = 0;
      placed++;
      unawaited(Future<void>.sync(() => refreshFilters?.call()));
      return;
    }
    _wrapsSince++;
    if (_wrapsSince < _wrapsToJudge) return;
    final want =
        Duration(microseconds: (span.inMicroseconds * _wrapsSince / rate).round());
    final late = Duration(
        microseconds: (now.difference(was) - want).inMicroseconds ~/ _wrapsSince);
    _wrappedAt = now;
    _wrapsSince = 0;
    if (late.abs() > _mostLate * 2) return;
    final want2 = loopLate + Duration(microseconds: (late.inMicroseconds * 0.5).round());
    loopLate = want2 < Duration.zero
        ? Duration.zero
        : want2 > _mostLate
            ? _mostLate
            : want2;
  }

  /// What the engine was last told to pull the end back by.
  Duration _appliedLate = Duration.zero;

  /// Where a seek was aimed and when, until the engine reports having got there.
  Duration? _settling;
  DateTime _settlingAt = DateTime.now();

  /// How many times this record has been *put* somewhere rather than played there.
  ///
  /// A hand on it, a scrub, a loop coming round, the booth placing it: anything that
  /// moves the record without the rate having done it. Whoever is measuring how fast
  /// the two decks are coming apart has to know when that happened, because a step in
  /// the line is not a drift and fitting a rate through one invents a drift that was
  /// never there. Counted rather than timed, so nothing can be missed between looks.
  int placed = 0;

  Future<void> seek(Duration to) async {
    placed++;
    _fix = to;
    _fixedAt = DateTime.now();
    _trusting = false;
    _settling = to;
    _settlingAt = _fixedAt;
    await _player.seek(to);
    // A seek flushes what the engine was holding, the filter graph with it: see
    // [refreshFilters]. This is the path a loop comes round by, and a hot cue, and
    // the booth's own placing of a record.
    unawaited(Future<void>.sync(() => refreshFilters?.call()));
    notifyListeners();
  }

  /// Where a hand has asked this record to be, kept until the engine has caught up.
  ///
  /// Not the same as [position]: the engine goes on reporting where it still is for a
  /// few frames after being told to move, and a second nudge read off *that* is a
  /// nudge measured from the wrong place.
  Duration? _aim;
  bool _seeking = false;
  bool _seekAgain = false;

  /// Where the record is headed — what a hand has asked for if it has asked for
  /// anything, and where it actually is otherwise.
  Duration get aimedAt => _aim ?? position;

  /// Move the record by hand: dragged on the waveform, or nudged with a button.
  ///
  /// One seek in flight at a time, and the newest target wins. Dragging fired a seek
  /// on every pointer frame — a hundred and twenty a second on a fast screen — with
  /// nothing awaiting them, so they queued in the engine and were worked through long
  /// after the finger had stopped: the record lurched about catching up with where the
  /// hand had been. Now the screen follows at once (the fix is set before anything is
  /// awaited) and the engine is told again only once it has answered.
  Future<void> seekByHand(Duration to) async {
    // A hand anywhere on the record ends a chain loop: the chain's loop is fixed to
    // the samples it was built around, and a seek would set it going from somewhere
    // else entirely.
    if (_chainLooping) unawaited(_outOfTheChain());
    final at = to < Duration.zero ? Duration.zero : to;
    _aim = at;
    _fix = at;
    _fixedAt = DateTime.now();
    _trusting = false;
    _settling = at;
    _settlingAt = _fixedAt;
    notifyListeners();
    if (_seeking) {
      _seekAgain = true;
      return;
    }
    _seeking = true;
    try {
      do {
        _seekAgain = false;
        await _player.seek(_aim ?? at);
      } while (_seekAgain);
    } finally {
      _seeking = false;
      _aim = null;
      notifyListeners();
    }
  }

  /// Nudge by [by] — from where the hand has already asked for, not from where the
  /// engine says the record is. Read off the engine, a second press within the few
  /// frames a seek takes to land measured from the old place and threw the first
  /// nudge away, which is what made the arrows feel like they were missing presses.
  Future<void> nudgeByHand(Duration by) => seekByHand(aimedAt + by);

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
    _wrapSoon?.cancel();
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

  /// Whether the record on this deck has yet made a sound since it went on.
  bool _freshlyLoaded = false;

  /// Told whenever the engine's filter graph may have been thrown away under this
  /// deck (set by the booth), so that whatever was on it can be put back.
  ///
  /// A desk's equalizer and its stems live in that graph, and mpv builds it afresh
  /// for every file and flushes it on every seek. So they went the moment a record
  /// changed — the bands were put on when setAudioSource returned, which is not when
  /// the graph exists — and again every time a loop came round, because a loop comes
  /// round by seeking. The knobs sat where they were left while the sound played
  /// flat, and moving one by hand was the only thing that ever put it back, that
  /// being the one path which does not go through the mixer's "nothing changed"
  /// check.
  void Function()? refreshFilters;

  /// Loop inside the filter chain rather than by seeking. See Mixer.loopInChain.
  Future<bool> Function(Duration length)? chainLoop;

  /// Take that loop back out, leaving the record playing on from where it is heard.
  Future<void> Function(Duration at)? stopChainLoop;

  /// Whether the chain is carrying this deck's loop. While it is, the engine never
  /// wraps and never seeks, so there is nothing for [_watchTheWrap] to time and
  /// nothing to put the filters back after.
  bool get chainLooping => _chainLooping;
  bool _chainLooping = false;

  /// The engine's own loop, where it has one (mpv's A–B loop on a desk): set by the
  /// booth. Says whether the engine took it; where it did not, the deck loops itself.
  Future<bool> Function(Duration? from, Duration? to)? engineLoop;
  bool _engineLooping = false;

  /// How late the engine's own loop comes round, learned while one runs.
  ///
  /// A desk loops inside mpv, which wraps an ab-loop by *seeking* — and a seek costs
  /// time: the decoder restarts, the chain is flushed, the output buffer refills. So
  /// the loop is musically long by whatever that costs, every single time round, and
  /// a loop that is a few milliseconds long every bar is heard as a stumble rather
  /// than a loop. It is the same fault the Dart fallback carries its overshoot for;
  /// the engine's own loop has nowhere to carry it, so the end is simply pulled
  /// earlier by what the wrap is measured to cost.
  ///
  /// Learned rather than guessed: it is a different number on every machine, every
  /// container and every buffer size. Clamped hard, because a bad reading here
  /// shortens a musical loop, which is worse than the delay it is curing.
  static Duration loopLate = Duration.zero;
  static const _mostLate = Duration(milliseconds: 120);

  /// How many times round before what the wrap costs is judged. See _watchTheWrap for
  /// why one is not enough.
  static const _wrapsToJudge = 6;
  DateTime? _wrappedAt;
  int _wrapsSince = 0;

  /// The end the engine is given: the musical one, less what the wrap costs.
  Duration? get _engineLoopEnd {
    final end = loopEnd, start = loopStart;
    if (end == null || start == null) return end;
    // In the record's own time, which is what a loop's ends are in.
    final pull = Duration(microseconds: (loopLate.inMicroseconds * tempo).round());
    final back = end - pull;
    return back > start + beatInRecord ~/ 4 ? back : end;
  }

  /// A loop long enough to be worth carrying in the chain: a bar.
  ///
  /// Under that it is a chop or a roll, and those are pressed and let go constantly —
  /// the rebuild a chain loop costs at each end would be felt far more than the
  /// milliseconds it saves each time round. Over it, the loop is left running and the
  /// arithmetic goes the other way: a four-bar loop at 130 comes round every seven
  /// seconds, and every one of those used to start with the filters empty.
  Duration get _worthCarrying => beatInRecord * 4;

  Future<void> _loopInEngine() async {
    final f = engineLoop;
    if (f == null) return;
    _wrappedAt = null;
    _appliedLate = loopLate;
    final start = loopStart, end = loopEnd;
    if (start != null &&
        end != null &&
        end - start >= _worthCarrying &&
        chainLoop != null &&
        playing &&
        await _intoTheChain(start, end)) {
      return;
    }
    await _outOfTheChain();
    final took = await f(loopStart, _engineLoopEnd);
    _engineLooping = took && loopStart != null;
    if (_engineLooping) {
      _loop?.cancel();
      _meetTheWrap();
    } else if (loopStart != null) {
      _watchLoop();
    }
  }

  /// Sets the loop the way pressing a loop button does, for a test that has put the
  /// ends on by hand.
  @visibleForTesting
  Future<void> setLoopForTest() => _loopInEngine();

  /// Puts this deck's clock where the *engine* would have it — which, when the chain
  /// is carrying the loop, walks straight on past the loop's end. What [positionAt]
  /// makes of that is the thing under test.
  @visibleForTesting
  void putClockAtForTest(Duration at) {
    _fix = at;
    _fixedAt = DateTime.now();
  }

  /// Hands the loop to the filter chain, and the record to the loop's start.
  ///
  /// In that order, and it matters: the chain's loop begins at the first sample the
  /// filter is given, and the first sample it is given is the first after a seek. Put
  /// the chain on and then send the deck to the loop's start, and zero is exactly
  /// there.
  Future<bool> _intoTheChain(Duration start, Duration end) async {
    if (_chainLooping) return true;
    if (!(await chainLoop!(end - start))) return false;
    await engineLoop?.call(null, null);
    await _player.seek(start);
    _fix = start;
    _fixedAt = DateTime.now();
    _trusting = false;
    _chainLooping = true;
    _engineLooping = false;
    _loop?.cancel();
    _wrapSoon?.cancel();
    notifyListeners();
    return true;
  }

  /// Takes it back out, and leaves the record where the room last heard it.
  Future<void> _outOfTheChain() async {
    if (!_chainLooping) return;
    final at = position;
    _chainLooping = false;
    await stopChainLoop?.call(at);
    await _player.seek(at);
    _fix = at;
    _fixedAt = DateTime.now();
    _trusting = false;
  }

  /// Puts the mixer's settings back the instant the engine comes round, rather than
  /// once something has noticed that it did.
  ///
  /// The engine loops by *seeking*, and a seek empties its filter chain: the equalizer
  /// and the stems come back at nothing until they are set again. They were being set
  /// again by _watchTheWrap, which runs on position reports — and those arrive a couple
  /// of hundred milliseconds apart, so every time round the loop began with a fifth of
  /// a second of the record at flat EQ and full stems. That is "there is a small
  /// timeframe at the start of the loop where the eq settings are still ignored", and
  /// no amount of noticing faster fixes it, because the report is the wrong clock to
  /// hang it on.
  ///
  /// The wrap is not a surprise: the deck knows both ends of its own loop and how fast
  /// it is going, so it knows when the engine will come round to within a millisecond
  /// or two. Aimed at that, with the settings going out a hair after the splice, and
  /// re-armed a loop's length at a time for as long as the loop is on.
  void _meetTheWrap() {
    _wrapSoon?.cancel();
    final start = loopStart, end = _engineLoopEnd;
    if (!_engineLooping || start == null || end == null || !playing) return;
    final span = end - start;
    if (span <= Duration.zero) return;
    final at = position;
    // Where it is in the loop now, in the record's own time; then in the room's.
    var left = end - at;
    if (left <= Duration.zero || left > span) left = span;
    final wall = Duration(
        microseconds: (left.inMicroseconds / (tempo <= 0 ? 1 : tempo)).round());
    _wrapSoon = Timer(wall, () {
      if (!_engineLooping || !playing) return;
      // The record teleports; the needle has to teleport with it.
      //
      // The engine comes round the instant the loop ends, but this deck's clock only
      // learns of it from a position report, and those arrive a fifth of a second
      // apart. So the needle sailed on past the loop's end for up to that long and then
      // jumped back — which on screen is not a loop coming round, it is a needle
      // travelling, which is what it was reported as. The wrap is known to the
      // millisecond here, so the clock is put on the loop's start at the moment the
      // engine reaches it, and the reports that follow only confirm it.
      //
      // Only when the reckoning has actually reached the end: a timer that fires early
      // must not drag the record backwards out from under the sound.
      final at = position, end = _engineLoopEnd, start = loopStart;
      if (start != null && end != null && at >= end - const Duration(milliseconds: 20)) {
        _fix = start;
        _fixedAt = DateTime.now();
        _trusting = false;
        placed++;
        notifyListeners();
      }
      unawaited(Future<void>.sync(() => refreshFilters?.call()));
      _meetTheWrap();
    });
  }

  Timer? _wrapSoon;

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
  /// Whether a loop's splice is worth going and reading the record for.
  ///
  /// False while the booth is mixing. Reading a seam means two more mpv instances,
  /// each opening the record — over the network, for a record the house is streaming —
  /// seeking, decoding and writing a file. That is a lot to ask of a machine that is
  /// playing two records, and a *roll* asks for it four times over: it catches a loop
  /// and halves it three times, so eight of them go up in a couple of seconds in the
  /// middle of a transition. The stutter that cost is worth far more than the click it
  /// was spent avoiding — and a roll is the loudest thing the booth does, where a
  /// splice is the last thing anybody can hear.
  bool findSeams = true;

  Timer? _seamSoon;
  int _seamTicket = 0;

  /// The splice read once the loop has stopped moving. A hand going down the loop
  /// buttons moves it several times a second; only where it settles is worth reading.
  void _seamLater() {
    _seamSoon?.cancel();
    if (!findSeams) return;
    final ticket = ++_seamTicket;
    _seamSoon = Timer(const Duration(milliseconds: 600), () {
      if (ticket != _seamTicket || !findSeams) return;
      unawaited(_quietSeam());
    });
  }

  Future<void> _quietSeam() async {
    final finder = seamFinder, from = loopStart, to = loopEnd;
    if (finder == null || from == null || to == null) return;
    // The end the *engine* is given, not the musical one.
    //
    // These two are not the same: the engine's end is pulled early by what the wrap
    // costs (see _engineLoopEnd), which is learned and can be a tenth of a second. So
    // the seam was being chosen around one sample and the splice made at another a
    // hundred milliseconds away — an arbitrary one, in the middle of a waveform,
    // which is a click. All the care taken to land the loop where it would not click
    // was being spent on a place the engine never cut.
    //
    // Searched around where the cut will actually be made, and the offset put back
    // afterwards, so the loop keeps the length the timing wants and the cut lands
    // somewhere quiet. This is what "the timing is right and there is still a click"
    // was.
    final pull = to - (_engineLoopEnd ?? to);
    final quiet = await finder(this, from, to - pull);
    if (quiet == null || loopStart != from || loopEnd != to) return;
    loopStart = quiet.$1;
    loopEnd = quiet.$2 + pull;
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
    unawaited(_loopInEngine());
    _seamLater();
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
    unawaited(_loopInEngine());
    _seamLater();
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
    _seamSoon?.cancel();
    final was = loopStart != null;
    loopStart = loopEnd = null;
    _loopBars = null;
    _loop?.cancel();
    _wrapSoon?.cancel();
    if (was || _engineLooping || _chainLooping) unawaited(_loopInEngine());
    _engineLooping = false;
    notifyListeners();
  }

  /// The loop, where the engine will not hold one itself (everything but a desk).
  ///
  /// It was a twenty-millisecond poll asking "are we past the end yet", so the loop
  /// came round up to twenty milliseconds late — and by a *different* amount each
  /// time, since where the poll fell against the end wandered. At a hundred and
  /// twenty a minute that is up to a sixteenth of a beat of slop, arriving early or
  /// late at random, which is exactly what a loop that will not sit still sounds like.
  ///
  /// Two changes. The end is *waited for* rather than polled — slept most of the way
  /// and then measured again, the way the booth waits for a beat (Booth._until) — so
  /// the timer fires within a millisecond or so of it. And whatever it is late by is
  /// carried over: the seek goes to the start plus the overshoot, so the loop keeps
  /// the record's grid instead of walking off it a little more every time round.
  void _watchLoop() {
    _loop?.cancel();
    late void Function() again;
    again = () {
      final end = loopEnd, start = loopStart;
      // Let go of, or the engine took it: unloop cancels the timer, so just stop.
      if (end == null || start == null || _engineLooping || end <= start) return;
      if (!playing) {
        _loop = Timer(const Duration(milliseconds: 20), again);
        return;
      }
      final rate = tempo <= 0 ? 1.0 : tempo;
      // Sent round early by what the wrap is measured to cost, the same way the
      // engine's own loop is given a pulled-back end. Without it every time round is
      // long by however long the seek takes — the sound stops while the decoder
      // restarts — and a loop that stumbles by the same twenty milliseconds every bar
      // is the thing you hear rather than the loop.
      final pull = Duration(microseconds: (loopLate.inMicroseconds * rate).round());
      final aim = end - pull > start + beatInRecord ~/ 4 ? end - pull : end;
      final left = aim - position;
      final wall = Duration(microseconds: (left.inMicroseconds / rate).round());
      if (wall <= const Duration(milliseconds: 1)) {
        // However far past the aim this landed, the loop starts that far in: the
        // length stays right and the grid is kept.
        final over = position - aim;
        final span = end - start;
        final to = over > Duration.zero && over < span ? start + over : start;
        _learnTheWrap(span, rate);
        unawaited(seek(to));
        _loop = Timer(const Duration(milliseconds: 4), again);
        return;
      }
      _loop = Timer(
          wall > const Duration(milliseconds: 24)
              ? wall - const Duration(milliseconds: 12)
              : const Duration(milliseconds: 1),
          again);
    };
    again();
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
    _seamSoon?.cancel();
    _disposed = true;
    _loop?.cancel();
    _wrapSoon?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
