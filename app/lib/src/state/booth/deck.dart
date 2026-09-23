import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../api/client.dart';
import '../../api/models.dart';

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

  /// Android's own, attached to this deck's player: what its kills are done with.
  final AndroidEqualizer? equalizer;

  late final AudioPlayer _player;
  AudioPlayer get player => _player;
  final _subs = <StreamSubscription<dynamic>>[];

  Track? track;
  TrackTiming? timing;

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
  /// Put [track] on, parked at [at] — its first sound, unless told otherwise.
  Future<void> load(Track track, {TrackTiming? timing, Duration? at}) async {
    // What is already known about this record is not forgotten because the server
    // could not be asked again: a deck that loses its grid loses its sync, its loop
    // and its beat light, and the grid had not changed.
    final knew = this.track?.id == track.id ? this.timing : null;
    this.track = track;
    this.timing = timing ?? knew;
    _ended_ = false;
    hotCues.clear();
    loopStart = loopEnd = null;
    // Parked where a DJ would drop it: on the first downbeat, if there is one.
    final start =
        at ?? this.timing?.cues?.firstDownbeat ?? this.timing?.lead ?? Duration.zero;
    await _player.setAudioSource(_sourceFor(track), initialPosition: start);
    if (tempo != 1.0) await _player.setSpeed(tempo);
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
    if (local != null) return AudioSource.uri(Uri.file(local), tag: tag);
    return AudioSource.uri(
      Uri.parse(api.streamUrl(track)),
      headers: kIsWeb ? null : api.streamHeaders,
      tag: tag,
    );
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
