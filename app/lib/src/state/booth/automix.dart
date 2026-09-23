import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/models.dart';
import 'booth.dart';

/// The booth mixing on its own: the queue played record into record, each
/// transition chosen from what is known about the two songs and landed on the phrase.
///
/// What a DJ does between songs, written down: where to come out of this one (the
/// start of its outro, as the analysis read it), where to come into the next (so that
/// its intro is over by the time the first has gone), how (a blend when both have a
/// grid and sit together on the wheel; a shorter one when they do not; a fade when one
/// has no pulse, or has already faded itself, or the tempos are too far apart to
/// sync), and over how many bars. It watches the master's clock and goes when the
/// time comes, then loads the record after that on the deck it just freed.
class AutoMix extends ChangeNotifier {
  AutoMix(this.booth);

  final Booth booth;

  List<Track> _tracks = const [];
  int _at = -1;
  Timer? _watch;
  bool running = false;

  /// A mix being done again: the moves as they were kept, looked up by the two
  /// records. Where a pair has one, it is followed rather than decided.
  List<MixMove> _kept = const [];
  bool get replaying => _kept.isNotEmpty;

  MixMove? _keptFor(int from, int to) {
    for (final m in _kept) {
      if (m.from == from && m.to == to) return m;
    }
    return null;
  }

  /// What is coming, and how, once it is decided.
  Track? get next => _at + 1 < _tracks.length ? _tracks[_at + 1] : null;
  Track? get current => _at >= 0 && _at < _tracks.length ? _tracks[_at] : null;
  ({Transition kind, int bars})? plan;

  /// Where in the outgoing record the transition begins, once known.
  Duration? goesAt;

  /// The rules. A record with no grid, or one that has already faded, or a gap in
  /// tempo sync will not close, gets a fade. Two records that sit together on the
  /// wheel get the long blend; two that do not get a short one — a clash is worse
  /// the longer it lasts.
  static ({Transition kind, int bars}) choose(TrackTiming? from, TrackTiming? to) {
    if (from == null || to == null || !from.hasBeats || !to.hasBeats) {
      return (kind: Transition.fade, bars: 4);
    }
    if (from.ends == 'fade') return (kind: Transition.fade, bars: 8);
    final ratio = from.bpm != null && to.bpm != null ? Booth.syncRatio(to.bpm!, from.bpm!) : null;
    if (ratio == null) return (kind: Transition.fade, bars: 8);
    if (from.ends == 'cold' && from.inKeyWith(to)) return (kind: Transition.cut, bars: 1);
    return from.inKeyWith(to) ? (kind: Transition.blend, bars: 16) : (kind: Transition.blend, bars: 8);
  }

  /// Where the outgoing record's transition starts: the start of its outro, or —
  /// with none read — far enough before the sound ends for the bars to fit.
  static Duration outPoint(TrackTiming from, {required Duration length}) {
    final cues = from.cues;
    if (cues != null) return cues.mixOut;
    final end = from.soundEnds ?? Duration(milliseconds: from.durationMs);
    final at = end - length;
    return at < Duration.zero ? Duration.zero : at;
  }

  /// Where the incoming record is parked: so many bars before its intro ends, on one
  /// of its own downbeats, and never before its first.
  static Duration inPoint(TrackTiming to, {required int bars}) {
    final cues = to.cues;
    if (cues == null) return to.lead;
    final bpm = to.bpm;
    if (bpm == null) return cues.firstDownbeat;
    final bar = Duration(microseconds: (4 * 60e6 / bpm).round());
    var at = cues.mixIn - bar * bars;
    if (at < cues.firstDownbeat) at = cues.firstDownbeat;
    // Onto its own grid: the nearest downbeat at or before — and never before the
    // first, whatever the grid says about the silence ahead of it.
    final downs = to.downbeats;
    for (var i = downs.length - 1; i >= 0; i--) {
      if (downs[i] <= at.inMilliseconds && downs[i] >= cues.firstDownbeatMs) {
        return Duration(milliseconds: downs[i]);
      }
    }
    return at;
  }

  /// Play [tracks] from [at], record into record, until they run out or [stop] —
  /// or, given the [kept] moves of a mix, do that mix again.
  ///
  /// [from] is where in the first record to begin — where the ordinary player had
  /// got to when it handed over, so the music carries on rather than starting again.
  Future<void> start(List<Track> tracks,
      {int at = 0, List<MixMove> kept = const [], Duration? from}) async {
    _tracks = [for (final t in tracks) if (t.isReady) t];
    if (_tracks.isEmpty) return;
    _kept = kept;
    _at = at.clamp(0, _tracks.length - 1);
    running = true;
    final deck = booth.master;
    await booth.load(deck, _tracks[_at], at: from);
    await deck.play();
    await booth.setCrossfader(identical(deck, booth.b) ? 1 : 0);
    await _prepareNext();
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
    notifyListeners();
  }

  void stop() {
    running = false;
    _watch?.cancel();
    _watch = null;
    plan = null;
    goesAt = null;
    notifyListeners();
  }

  /// The record after this one, on the free deck: loaded, synced, parked where it
  /// will come in — and the plan for getting there written down.
  Future<void> _prepareNext() async {
    final coming = next;
    final from = booth.master;
    final to = booth.other(from);
    if (coming == null) {
      plan = null;
      goesAt = null;
      notifyListeners();
      return;
    }
    final timing = await booth.timing.of(coming);
    final was = from.track == null ? null : _keptFor(from.track!.id, coming.id);
    final chosen = was == null ? choose(from.timing, timing) : (kind: was.kind, bars: was.bars);
    plan = chosen;
    if (was != null) {
      // As it was done: the same places, the same rate.
      goesAt = Duration(milliseconds: was.outMs);
      await to.load(coming, timing: timing, at: Duration(milliseconds: was.inMs));
      if (was.tempo != 1.0) await to.setTempo(was.tempo);
      notifyListeners();
      return;
    }
    final length = booth.barsLength(from, chosen.bars);
    goesAt = from.timing == null ? null : outPoint(from.timing!, length: length);
    final at = timing == null ? null : inPoint(timing, bars: chosen.bars);
    await to.load(coming, timing: timing, at: at);
    if (chosen.kind != Transition.fade) await booth.sync(to);
    notifyListeners();
  }

  bool _going = false;

  Future<void> _tick() async {
    if (!running || _going) return;
    final from = booth.master;
    final go = goesAt;
    final coming = next;
    if (coming == null) {
      // The last record: let it end, then stop.
      if (!from.playing) stop();
      return;
    }
    if (go == null || !from.playing) return;
    if (from.position < go) return;
    _going = true;
    try {
      final chosen = plan ?? choose(from.timing, booth.other(from).timing);
      await booth.go(chosen.kind, bars: chosen.bars);
      _at++;
      await _prepareNext();
    } finally {
      _going = false;
    }
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }
}
