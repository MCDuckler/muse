import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../api/client.dart';
import '../../api/models.dart';
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

  /// A part has been asked for and is being made. Nothing changes on the deck while
  /// this is true — the record it is holding keeps playing — but the booth says so,
  /// because "in a minute" and "no" are different answers.
  bool makingPart = false;

  /// This record does not get taken apart at all: it is longer than a record, and the
  /// server will not spend twenty minutes on it. The last answer, kept so the booth
  /// can say "not this one" rather than "in a minute" for ever.
  bool noParts = false;

  /// The rate it plays at: 1.0 is the record as recorded.
  double tempo = 1.0;

  bool get playing => _player.playing && !_ended_;
  bool _ended_ = false;
  bool get loaded => track != null;

  Duration? get duration => _player.duration ?? track?.duration;

  // ------------------------------------------------------------------ the clock
  Duration _fix = Duration.zero;
  DateTime _fixedAt = DateTime.now();

  void _anchor(Duration at) {
    _fix = at;
    _fixedAt = DateTime.now();
  }

  /// A fix from outside — the tests, mostly.
  @visibleForTesting
  void anchor(Duration at, DateTime when) {
    _fix = at;
    _fixedAt = when;
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

  /// Beats a minute as it is playing now: the record's own, at the deck's tempo.
  double? get bpm {
    final own = timing?.bpm;
    return own == null ? null : own * tempo;
  }

  bool get hasBeats => timing?.hasBeats ?? false;

  // ------------------------------------------------------------------ beats and bars
  /// Which beat the record is on and how far through it, at [now].
  ({int index, double phase})? beatAt(DateTime now) => timing?.beatAt(positionAt(now));

  /// The record's next beat at or after [at], as a place in the file — or, with
  /// [every] beats, the next beat whose index (from the bar's first beat) is a
  /// multiple of it: 4 for the next downbeat, 16 for the next four-bar phrase.
  Duration? nextBeat(Duration at, {int every = 1}) {
    final t = timing;
    if (t == null || !t.hasBeats) return null;
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
    // A stream is signed and the signature ages out, so it is refreshed before a
    // load — but never at the price of the load itself: a deck that cannot reach the
    // server still plays what is kept on the device.
    if (part != null || offlinePath?.call(track.id) == null) {
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
    final knew = this.track?.id == track.id ? this.timing : null;
    this.track = track;
    this.timing = timing ?? knew;
    _ended_ = false;
    trouble = null;
    noParts = false;
    hotCues.clear();
    loopStart = loopEnd = null;
    _loopBars = null;
    // Parked where a DJ would drop it: on the first downbeat, if there is one.
    final start =
        at ?? this.timing?.cues?.firstDownbeat ?? this.timing?.lead ?? Duration.zero;
    try {
      claiming?.call();
      await _player.setAudioSource(_sourceFor(track), initialPosition: start);
      if (tempo != 1.0) await _player.setSpeed(tempo);
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
  /// Answers false, having asked the server to make it, when that part does not exist
  /// yet. Nothing changes in that case: the record carries on, and the booth says a
  /// part is being made rather than going quiet.
  ///
  /// There is a real seam here. One deck is one player and one player holds one file,
  /// so the swap is a load, and a load is a fraction of a second of nothing. It lands
  /// where the record would have been, and the mixer re-aligns the phase after it, but
  /// it is a gap all the same — which is why the moves that use it put it under
  /// another record rather than in the clear.
  Future<bool> swapTo(String? part) async {
    final t = track;
    if (t == null || part == this.part) return true;
    if (part != null) {
      makingPart = true;
      notifyListeners();
      Stem state;
      try {
        final store = parts;
        state = store != null
            ? await store.want(t, part)
            : await api.stemState(t, part);
      } catch (_) {
        // The server could not be asked. Not the deck's problem to report: it is
        // still holding a record and still playing it.
        state = Stem.beingMade;
      }
      makingPart = false;
      noParts = state == Stem.never;
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
      if (was) {
        final took = DateTime.now().difference(began);
        await _player.seek(at + Duration(microseconds: (took.inMicroseconds * tempo).round()));
        await _player.play();
      }
    } catch (e) {
      trouble = '$e';
      notifyListeners();
      return false;
    } finally {
      mine.complete();
    }
    notifyListeners();
    return true;
  }

  Future<void> play() async {
    _ended_ = false;
    _fixedAt = DateTime.now();
    await _player.play();
    notifyListeners();
  }

  Future<void> pause() async {
    _fix = position;
    await _player.pause();
    _fixedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> seek(Duration to) async {
    _anchor(to);
    await _player.seek(to);
    notifyListeners();
  }

  /// A little forwards or back, to bring the beats in line: the DJ's nudge.
  Future<void> nudge(Duration by) => seek(position + by);

  Future<void> setTempo(double rate) async {
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

  /// How many bars the loop is, when there is one: what the buttons light by.
  int? get loopBars => loopStart == null ? null : _loopBars;
  int? _loopBars;
  Timer? _loop;

  /// Go round [beats] beats from the next downbeat (or from here, with no grid).
  void loop(int beats) {
    final from = nextBeat(position, every: 4) ?? position;
    final len = beat ?? const Duration(milliseconds: 500);
    loopStart = from;
    loopEnd = from + len * beats;
    _loopBars = beats ~/ 4;
    _watchLoop();
    notifyListeners();
  }

  /// Half the loop, from where it starts: 4 bars, 2, 1, half a bar — the roll that
  /// tightens as a record goes out. Floors at an eighth of a beat, below which it is
  /// a tone rather than a rhythm.
  void halveLoop() {
    final from = loopStart, to = loopEnd;
    if (from == null || to == null) return;
    final now = to - from;
    final least = (beat ?? const Duration(milliseconds: 500)) ~/ 8;
    if (now <= least) return;
    loopEnd = from + now ~/ 2;
    _loopBars = null;                  // no longer one of the buttons' lengths
    notifyListeners();
  }

  /// The record braking to a stop, the way a hand on the platter does it: the rate
  /// falls away over [over] and the deck is left parked, at the pitch it was set to.
  ///
  /// Not a backspin — a browser's audio element will not play backwards, so what is
  /// offered is the half of it that every engine here can actually do.
  Future<void> brake({Duration over = const Duration(milliseconds: 900)}) async {
    if (!playing) return;
    final was = tempo;
    const steps = 18;
    for (var i = 1; i <= steps; i++) {
      _fix = position;
      _fixedAt = DateTime.now();
      tempo = (was * (1 - i / steps)).clamp(_slowest, 2.0);
      try {
        await _player.setSpeed(tempo);
      } catch (_) {
        break;                          // an engine that will not crawl: stop here
      }
      notifyListeners();
      await Future<void>.delayed(over ~/ steps);
    }
    await pause();
    tempo = was;
    try {
      await _player.setSpeed(was);
    } catch (_) {}
    notifyListeners();
  }

  /// The slowest an engine can be asked to run without refusing outright.
  static const _slowest = 0.12;

  void unloop() {
    loopStart = loopEnd = null;
    _loopBars = null;
    _loop?.cancel();
    notifyListeners();
  }

  void _watchLoop() {
    _loop?.cancel();
    _loop = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final end = loopEnd, start = loopStart;
      if (end == null || start == null || !playing) return;
      if (position >= end) unawaited(seek(start));
    });
  }

  @override
  void dispose() {
    _loop?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
