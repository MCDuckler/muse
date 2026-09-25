import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import 'booth.dart';
import 'deck.dart';
import 'planner.dart';
import 'set_planner.dart';
import 'taste.dart';

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
/// How hard the booth mixes when it is left to itself.
enum MixStyle {
  /// Long and level: nothing sudden, nothing clever.
  easy,

  /// The blend, and the filter where two records do not sit together.
  normal,

  /// Short, and landed on the drop: loops that tighten, sweeps, a record stopped
  /// dead. What somebody would do to a room that is already going.
  bold,
}

class AutoMix extends ChangeNotifier {
  AutoMix(this.booth) {
    // A record the pool has just finished taking apart: in parts from now on, and if
    // it is the one coming next, planned again with that in hand.
    _arrivals = booth.parts.arrivals.stream.listen((id) {
      _inParts[id] = true;
      if (running && next?.id == id && !booth.busy) unawaited(_prepareNext());
    });
  }

  late final StreamSubscription<int> _arrivals;

  final Booth booth;

  List<Track> _tracks = const [];
  int _at = -1;
  Timer? _watch;
  bool running = false;

  /// Whether the booth chooses what comes next, rather than taking the queue in the
  /// order it is in: of everything still to play, the record that mixes best into
  /// the one on now. Off by default — a queue is usually a queue on purpose.
  bool pickBest = false;

  void chooseForYourself(bool on) {
    pickBest = on;
    notifyListeners();
    unawaited(_prepareNext());
  }

  /// Where the set's energy is meant to head, when the booth orders it itself.
  EnergyArc arc = EnergyArc.flat;

  void setArc(EnergyArc a) {
    arc = a;
    notifyListeners();
    if (pickBest) unawaited(_prepareNext());
  }

  /// Records a hand has pinned where they are: the booth orders around them.
  final locked = <int>{};

  /// What this person has thought of the booth's mixes, as leanings the planner adds
  /// to its scores — asked of the house when the automix starts, quietly.
  Taste taste = Taste.none;
  DateTime? _tasteAt;

  /// The house's word on this person's taste, once an hour at most.
  Future<void> learnTaste() async {
    final at = _tasteAt;
    if (at != null && DateTime.now().difference(at) < const Duration(hours: 1)) return;
    _tasteAt = DateTime.now();
    try {
      final rows = await booth.api.boothFeedbackList().timeout(const Duration(seconds: 8));
      taste = Taste.fromFeedback(rows);
      _moveScores.clear();
      if (taste.count > 0) {
        final fav = taste.favourite;
        booth.note(BoothEventKind.plan,
            'Read ${taste.count} of your word${taste.count == 1 ? '' : 's'} on its mixes'
            '${fav == null ? '' : ' · you like a ${Transition.values.byName(fav).label}'}');
      }
    } catch (_) {
      // A house that cannot be reached, or one from before it kept any: the booth
      // goes by its own judgement.
    }
  }

  /// Whether the booth, at the end of the queue, keeps going: the record in the
  /// whole library that follows the last one best, put on next — and so on until it
  /// is switched off. Off by default: a queue that ends is a queue that ends.
  bool fill = false;

  /// Where the fill puts its record: the crate, so what the booth plays is what the
  /// queue shows. Set by the app; without it the booth keeps the record to itself.
  Future<void> Function(Track track)? onFill;
  bool _filling = false;
  DateTime? _fillTriedAt;

  void keepGoing(bool on) {
    fill = on;
    notifyListeners();
    if (on && running && next == null) unawaited(_fillFromLibrary());
  }

  /// The end of the queue, and the booth told to keep going: the library's best
  /// partner for the record on now, judged finely, put on next.
  Future<void> _fillFromLibrary() async {
    final on = current;
    if (_filling || on == null || next != null) return;
    final tried = _fillTriedAt;
    if (tried != null && DateTime.now().difference(tried) < const Duration(seconds: 20)) return;
    _filling = true;
    _fillTriedAt = DateTime.now();
    try {
      final found = await partnersFor(on, limit: 8);
      if (_disposed || !running || next != null) return;
      if (found.isEmpty) {
        booth.note(BoothEventKind.plan, 'Nothing in the library to follow ${on.displayTitle}');
        return;
      }
      final pick = found.first;
      booth.note(BoothEventKind.next,
          'From the library: ${pick.track.displayTitle}${pick.why.isEmpty ? '' : ' · ${pick.why}'}');
      _tracks = [..._tracks, pick.track];
      final tell = onFill;
      if (tell != null) {
        try {
          await tell(pick.track);
        } catch (_) {}
      }
      if (!_disposed && running) await _prepareNext();
    } finally {
      _filling = false;
    }
  }

  /// The records in the library that would follow [from] best: the house's coarse
  /// pick of a few dozen, judged again here with everything the set planner reads —
  /// the seam, the sound, the move the transition planner would make — best first.
  Future<List<({Track track, double fit, String why})>> partnersFor(Track from, {int limit = 6}) async {
    final here = _tracks.indexWhere((t) => t.id == from.id);
    final before = here < 0 ? _before() : [for (var i = math.max(0, here - 3); i < here; i++) _tracks[i]];
    final n = _tracks.length;
    final start = current == null ? null : SetPlanner.energyOf(current, booth.timing.peek(current!.id));
    final wanted = here < 0 || start == null
        ? 0.0
        : (SetPlanner.target(arc, here + 1, n + 1, start) ?? start) - (SetPlanner.energyOf(from, booth.timing.peek(from.id)) ?? start);
    List<({Track track, double fit, String why})> coarse;
    try {
      coarse = await booth.api
          .partners(from.id,
              exclude: [for (final t in _tracks) t.id],
              limit: 24,
              step: wanted,
              avoid: {for (final t in [from, ...before]) ...t.artists})
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return const [];
    }
    if (coarse.isEmpty) return const [];
    final ta = await booth.timing.of(from).timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (ta == null) return coarse.take(limit).toList();
    // The fine judging needs each one's timing; asked for together, within reason.
    await Future.wait([
      for (final p in coarse) booth.timing.of(p.track).timeout(const Duration(seconds: 10), onTimeout: () => null),
    ]);
    final fine = <({Track track, double fit, String why})>[];
    for (final p in coarse) {
      final tb = booth.timing.peek(p.track.id);
      if (tb == null) {
        fine.add(p);
        continue;
      }
      final f = SetPlanner.fit(ta, tb,
          ta: from,
          tb: p.track,
          fromPitch: identical(from, current) ? masterTargetPitch : 1,
          before: before,
          wantedStep: wanted,
          move: _moveScore(from, p.track),
          taste: taste);
      fine.add((track: p.track, fit: f.score, why: f.why));
    }
    fine.sort((x, y) => y.fit.compareTo(x.fit));
    return fine.take(limit).toList();
  }

  /// How well the transition planner could mix [a] into [b], from what is known
  /// now — the best move's score — for the set planner to weigh a pair by. Null
  /// until both timings are here; the voices are asked for so the next asking is
  /// better informed. Cached per pair; cleared when the taste changes.
  final _moveScores = <(int, int, bool), double?>{};
  double? moveScoreOf(Track a, Track b) => _moveScore(a, b);
  double? _moveScore(Track a, Track b) {
    final ta = booth.timing.peek(a.id), tb = booth.timing.peek(b.id);
    if (ta == null || tb == null) return null;
    final stems = _inParts[a.id] == true && _inParts[b.id] == true && booth.mixer.canStem;
    final key = (a.id, b.id, stems);
    if (_moveScores.containsKey(key)) return _moveScores[key];
    final va = booth.vocals.peek(a.id), vb = booth.vocals.peek(b.id);
    if (va == null) unawaited(booth.vocals.of(a));
    if (vb == null) unawaited(booth.vocals.of(b));
    final best = Planner.options(
      from: MixSide(timing: ta, vocals: va, stems: stems, fx: booth.mixer.canShift,
          pitch: identical(a, current) ? masterTargetPitch : 1),
      to: MixSide(timing: tb, vocals: vb, stems: stems, fx: booth.mixer.canShift),
      style: style,
      axes: _axes,
      sound: booth.fx.can,
      gate: booth.mixer.canGate,
      random: math.Random(a.id * 7919 + b.id),
      taste: taste,
    ).first.score;
    // Kept only once both voices are known: until then the score is a guess that
    // would otherwise stand for the rest of the set.
    if (va != null && vb != null) _moveScores[key] = best;
    return best;
  }

  void setLocked(int trackId, bool on) {
    if (on) {
      locked.add(trackId);
    } else {
      locked.remove(trackId);
    }
    notifyListeners();
    if (pickBest) unawaited(_prepareNext());
  }

  /// How well [t] would follow the record on now, and why — for the set view.
  Fit fitOf(Track t) {
    final on = current;
    if (on == null) return Fit.nothing;
    return SetPlanner.fit(booth.timing.peek(on.id), booth.timing.peek(t.id),
        ta: on, tb: t, fromPitch: masterTargetPitch, before: _before(), move: _moveScore(on, t), taste: taste);
  }

  List<Track> _before() =>
      [for (var i = math.max(0, _at - 3); i < _at; i++) _tracks[i]];

  // ------------------------------------------------------------------ the parts
  /// Which records the server has in parts, as far as the booth has been told.
  final _inParts = <int, bool>{};

  /// How far down the queue the parts are asked for.
  ///
  /// This is the whole reason the drums can change hands at all. Taking a record
  /// apart is the better part of a minute of the server's time — far too long to
  /// wait for at the moment a mix wants it — but the queue is known for several
  /// records ahead, so the asking happens while something else is still playing and
  /// the answer is there when it is needed.
  static const lookAhead = 3;

  Future<void> _askAhead() async {
    for (var i = _at; i >= 0 && i < _tracks.length && i <= _at + lookAhead; i++) {
      final t = _tracks[i];
      if (_inParts[t.id] == true) continue;
      try {
        // The record on now is wanted now; those after it only soon — to the pool,
        // behind what somebody is about to play.
        _inParts[t.id] = await booth.parts
                .want(t, 'stems', soon: i > _at)
                .timeout(const Duration(seconds: 8)) ==
            Stem.ready;
      } catch (_) {
        // Not a record the server can take apart, or cannot be reached. Either way
        // the booth mixes it the ordinary way and says nothing about it.
        _inParts[t.id] = false;
      }
    }
    // This computer's own line in the order they play: the record on, then the next.
    booth.parts.inOrder([
      for (var i = _at; i >= 0 && i < _tracks.length && i <= _at + lookAhead; i++) _tracks[i].id,
    ]);
  }

  /// Whether both of these are in parts, which is what the drums changing hands
  /// needs: one record's kick and the other's music, never two of either.
  bool inParts(Track? from, Track? to) =>
      from != null && to != null && _inParts[from.id] == true && _inParts[to.id] == true;

  /// How well [to] would follow [from]: 0 is unmixable, 1 is as good as it gets.
  ///
  /// Tempo first, because a record that cannot be synced can only be faded into;
  /// then the wheel, because a clash is the thing anybody hears; then how close the
  /// two are in energy, so a set does not fall off a cliff between one and the next.
  ///
  /// [fromPitch] is the pitch the record on now is playing at: what [to] has to meet
  /// is the tempo on show, not the one it was made at.
  static double howWell(TrackTiming? from, TrackTiming? to, {double fromPitch = 1}) =>
      SetPlanner.fit(from, to, fromPitch: fromPitch).score;

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

  /// The queue as it is now, while mixing: what comes after the record on now follows
  /// it — a record moved up, taken out or added in the crate is what the booth mixes
  /// into next, rather than whatever the queue was when the automix was switched on.
  /// The record playing stays where it is. A mix being done again keeps its own order.
  void follow(List<Track> queue) {
    if (!running || replaying) return;
    final ready = [for (final t in queue) if (t.isReady) t];
    final on = current;
    final before = next?.id;
    final at = on == null ? -1 : ready.indexWhere((t) => t.id == on.id);
    if (at >= 0) {
      _tracks = ready;
      _at = at;
    } else {
      _tracks = [if (on != null) on, ...ready];
      _at = on == null ? -1 : 0;
    }
    // Choosing for itself, the record it chose stays chosen while it is still to come:
    // put back in the queue's order on every refresh of the queue, it was chosen again,
    // and the plan for it started over — for as long as the queue kept refreshing.
    if (pickBest && before != null) {
      final i = _tracks.indexWhere((t) => t.id == before);
      if (i > _at + 1) {
        _tracks = [..._tracks]..insert(_at + 1, _tracks[i]);
        _tracks.removeAt(i + 1);
      }
    }
    if (next?.id != before && !booth.busy && !_going) {
      unawaited(_prepareNext());
    } else {
      notifyListeners();
    }
  }

  /// The moves made lately, newest last — the booth's own log of them, by hand or by
  /// the automix, so a set does not begin by repeating what the last one ended on
  /// and a mix done by hand counts as one made.
  List<Transition> get recent {
    final taken = booth.taken;
    return [for (final m in taken.skip(math.max(0, taken.length - 8))) m.kind];
  }

  /// Why the plan is what it is, in a few words — for the log and the bar.
  String? why;

  /// What is coming, and how, once it is decided.
  Track? get next => _at + 1 < _tracks.length ? _tracks[_at + 1] : null;
  Track? get current => _at >= 0 && _at < _tracks.length ? _tracks[_at] : null;
  ({Transition kind, int bars})? plan;

  /// Where in the outgoing record the transition begins, once known.
  Duration? goesAt;

  /// How long until it does, by the wall clock at the master's tempo — or null when
  /// there is nothing lined up. Negative while the transition is running.
  Duration? get timeToGo {
    final at = goesAt;
    final from = booth.master;
    if (at == null || !running) return null;
    final left = at - from.position;
    return Duration(microseconds: (left.inMicroseconds / from.tempo).round());
  }

  /// How far the outgoing record is through the stretch before its transition, 0 to
  /// 1 — what the countdown is drawn from.
  double get toGo {
    final at = goesAt;
    final from = booth.master;
    if (at == null || !running || at <= Duration.zero) return 0;
    return (from.position.inMicroseconds / at.inMicroseconds).clamp(0.0, 1.0);
  }

  /// Go now, wherever the record has got to: the one thing a DJ does that a plan
  /// cannot know about — the room, or simply having heard enough of it.
  Future<void> mixNow() async {
    if (!running || next == null) return;
    booth.note(BoothEventKind.mix, 'Mixing now, by hand');
    goesAt = Duration.zero;
    notifyListeners();
    await _tick();
  }

  /// Not that one: put [track] next instead, and lay it out ready.
  Future<void> swapNext(Track track) async {
    if (_at + 1 < _tracks.length) {
      _tracks = [..._tracks]..[_at + 1] = track;
    } else {
      _tracks = [..._tracks, track];
    }
    await _prepareNext();
  }

  /// Leave the record after this one out altogether.
  Future<void> dropNext() async {
    if (_at + 1 >= _tracks.length) return;
    booth.note(BoothEventKind.skip, 'Skipped ${_tracks[_at + 1].displayTitle}');
    _tracks = [..._tracks]..removeAt(_at + 1);
    await _prepareNext();
  }

  /// What is coming after the one that is coming: the crate's own "and then".
  Track? get after => _at + 2 < _tracks.length ? _tracks[_at + 2] : null;

  /// How hard the booth mixes: the three words, or the dials set by hand.
  MixStyle style = MixStyle.normal;
  StyleAxes? _axes;
  StyleAxes get axes => _axes ?? StyleAxes.of(style);
  bool get dialsByHand => _axes != null;

  void mixLike(MixStyle how) {
    style = how;
    _axes = null;
    _moveScores.clear();
    notifyListeners();
    unawaited(_prepareNext());
  }

  /// The dials turned by hand; null goes back to the word.
  void setAxes(StyleAxes? dials) {
    _axes = dials;
    _moveScores.clear();
    notifyListeners();
    unawaited(_prepareNext());
  }

  /// The rules.
  ///
  /// A record with no grid, one that has already faded, or a tempo gap sync will not
  /// close: a fade, because there is nothing to hold two records together. Otherwise
  /// what is reached for depends on how hard the booth has been told to mix — and on
  /// the two records, because a clash is worse the longer it lasts and a record with
  /// a drop to land on wants a different exit from one without.
  ///
  /// [parts] says both records have been taken apart on the server, which puts the
  /// boldest move of all on the table: the drums changing hands.
  static ({Transition kind, int bars}) choose(TrackTiming? from, TrackTiming? to,
      {MixStyle style = MixStyle.normal, bool parts = false, double fromPitch = 1}) {
    if (from == null || to == null || !from.hasBeats || !to.hasBeats) {
      return (kind: Transition.fade, bars: 4);
    }
    // Whether the incoming can be brought to the tempo on show — the record on now at
    // its pitch ([fromPitch]), which is what SYNC will match, not the tempo it was made
    // at. Judged by the one, done by the other, the automix once planned a blend it
    // then could not put in step.
    final ratio = from.gridBpm != null && to.gridBpm != null
        ? Booth.syncRatio(to.gridBpm!, from.gridBpm! * fromPitch, reach: Booth.bridgeReach)
        : null;
    // Two speeds that cannot be one: handed over, not laid on top of each other. On
    // the downbeat where the old one stops dead; otherwise a short fade — two bars of
    // overlap is a moment, eight was thirteen seconds of two drummers disagreeing.
    if (ratio == null) {
      return from.ends == 'cold'
          ? (kind: Transition.cut, bars: 1)
          : (kind: Transition.fade, bars: 2);
    }
    // A record that fades itself goes out as it was made to — but in step.
    if (from.ends == 'fade') return (kind: Transition.fade, bars: 8);
    final inKey = from.inKeyWith(to);
    if (from.ends == 'cold' && inKey) return (kind: Transition.cut, bars: 1);
    switch (style) {
      case MixStyle.easy:
        // Nothing sudden: long where the two agree, short where they do not.
        return inKey ? (kind: Transition.blend, bars: 32) : (kind: Transition.fade, bars: 16);
      case MixStyle.normal:
        // A clash goes out through the filter: a high-passed record has hardly any
        // key left to clash with. Or, where the parts exist, it never arrives: a
        // record coming in on its drums alone has no key to clash with either, and
        // it sounds like a choice rather than a rescue — in the bold style, below.
        // (The drums changing hands is the bold style's: each change of part is a new
        // file on the deck, and on a desk that is a gap in the sound you can hear.)
        return inKey
            ? (kind: Transition.blend, bars: 16)
            : (kind: Transition.sweep, bars: 12);
      case MixStyle.bold:
        // The drums change hands, where there are drums to change: sixteen bars of
        // one record's music over the other's kick, and nobody can tell you when the
        // record changed.
        if (parts) return (kind: Transition.swap, bars: 16);
        // Failing that, something to land on: the old record is caught and tightened
        // while the new one arrives, or stopped dead under it.
        if (to.drops.isNotEmpty && inKey) return (kind: Transition.roll, bars: 8);
        if (to.drops.isNotEmpty) return (kind: Transition.sweep, bars: 8);
        if (from.ends == 'cold') return (kind: Transition.brake, bars: 8);
        return inKey
            ? (kind: Transition.blend, bars: 8)
            : (kind: Transition.sweep, bars: 8);
    }
  }

  /// Where the outgoing record's transition starts.
  ///
  /// The start of its outro, as the analysis read it — but moved to a phrase boundary
  /// near it, because a mix that starts four bars into a phrase is a mix that lands
  /// four bars into the next one, and that is the thing an ear notices. Where the
  /// analysis read no outro, far enough before the sound ends for the bars to fit,
  /// again on a phrase. Always on one of the record's four-bar markers.
  static Duration outPoint(TrackTiming from, {required Duration length}) {
    final cues = from.cues;
    final end = from.soundEnds ?? Duration(milliseconds: from.durationMs);
    // An outro the analysis put before the intro was over (it has: a short record
    // read as all outro) is no outro.
    final mixOut = cues == null || cues.mixOut <= cues.mixIn ? null : cues.mixOut;
    var at = mixOut ?? (end - length);
    if (at < Duration.zero) at = Duration.zero;
    // And never so late that the transition would run past the end of the sound.
    final latest = end - length;
    if (latest > Duration.zero && at > latest) at = latest;
    final on = onPhrase(from, at);
    // Moved later by the phrase, past that: the marker before instead.
    if (latest > Duration.zero && on > latest) return from.markerAtOrBefore(latest) ?? on;
    return on;
  }

  /// [at], moved off a drop it would run over.
  ///
  /// Two records dropping over each other is either the best thing in the set or a
  /// mess, and it is not something to do by accident. Where the outgoing record would
  /// open up inside the transition, the transition is brought forward to finish there
  /// instead: the old record never drops, and the new one — parked so its own drop
  /// lands where the transition ends — drops in its place. (It used to start at the
  /// drop, which laid the whole of the old record's loudest stretch over the new one's
  /// arrival.) Where that would start before the old record has begun, it is left.
  static Duration clearOfDrops(TrackTiming from, Duration at,
      {required Duration length}) {
    final end = at + length;
    for (final d in from.drops) {
      final drop = Duration(milliseconds: d);
      if (drop > at && drop < end) {
        // On the marker at or before, so the mix still starts where a phrase does.
        final earlier = from.markerAtOrBefore(drop - length) ?? drop - length;
        final first = from.cues?.firstDownbeat ?? Duration.zero;
        return earlier >= first ? earlier : at;
      }
    }
    return at;
  }

  /// [at], moved to the nearest phrase boundary within a phrase of it — one of the
  /// sections the analysis found, where it sits on a four-bar marker — or, with none
  /// that near, to the nearest marker: a mix that starts in the middle of a phrase
  /// lands in the middle of the next. Unmoved where the song has no bars.
  static Duration onPhrase(TrackTiming timing, Duration at) {
    final markers = timing.markers;
    if (markers.isEmpty) return at;
    final ms = at.inMilliseconds;
    // A phrase is eight bars at this tempo either way — or eight seconds where there
    // is no tempo to measure it by.
    final bar = timing.bar;
    final reach = bar == null ? 8000 : bar.inMilliseconds * 8;
    final onMarkers = markers.toSet();
    int? best;
    for (final p in timing.phrases) {
      // A section the grid moved away from is not one to line two records up on.
      if (!onMarkers.contains(p)) continue;
      if ((p - ms).abs() > reach) continue;
      if (best == null || (p - ms).abs() < (best - ms).abs()) best = p;
    }
    if (best != null) return timing.onGrid(Duration(milliseconds: best), every: 4);
    return timing.onMarker(at);
  }

  /// Whether the [bars] bars of [t] from [at] are quiet — 8 dB under its loud bars,
  /// by the house's structure. False where nothing was measured.
  static bool quietBars(TrackTiming t, Duration at, int bars) {
    final s = t.structure;
    if (s == null || s.barsMs.isEmpty || s.mixDb.isEmpty) return false;
    final heard = [for (final v in s.mixDb) if (v > -90) v]..sort();
    if (heard.isEmpty) return false;
    final loud = heard[(heard.length * 0.9).floor().clamp(0, heard.length - 1)];
    var i = 0;
    while (i + 1 < s.barsMs.length && s.barsMs[i + 1] <= at.inMilliseconds) {
      i++;
    }
    final span = [for (final v in s.mixDb.sublist(i, math.min(s.mixDb.length, i + bars))) if (v > -90) v];
    if (span.isEmpty) return false;
    return span.reduce((a, b) => a + b) / span.length < loud - 8;
  }

  /// Where the incoming record is parked.
  ///
  /// So many bars before its intro ends, on one of its own four-bar markers, never
  /// before its first downbeat — or, where it has a drop and the booth is aiming at
  /// it, so many bars before *that*, so the drop lands on the beat the fader finishes
  /// on. Which is the difference between a mix that is correct and one that sounds
  /// meant. On a marker because the outgoing goes on one: the two records' phrases
  /// then turn over together for the whole of the mix.
  static Duration inPoint(TrackTiming to, {required int bars, bool onTheDrop = false}) {
    final cues = to.cues;
    if (cues == null) return to.lead;
    final bpm = to.bpm;
    if (bpm == null) return cues.firstDownbeat;
    final bar = to.bar ?? Duration(microseconds: (4 * 60e6 / bpm).round());
    final drop = onTheDrop ? to.dropAfter(cues.firstDownbeat) : null;
    var at = (drop ?? cues.mixIn) - bar * bars;
    if (at < cues.firstDownbeat) at = cues.firstDownbeat;
    // Unless those bars are quiet — a long, thin intro, 8 dB under the record's loud
    // bars by the structure — when the record comes in later: half way through the
    // move, or already on. (A record parked in near-silence made a blend into a hole.)
    // Checked after the record's start has had its say: an intro shorter than the
    // move, parked at the first downbeat, is as often the quiet kind.
    if (drop == null && quietBars(to, at, bars)) {
      final half = cues.mixIn - bar * (bars ~/ 2);
      at = quietBars(to, half, math.max(1, bars ~/ 2)) ? cues.mixIn : half;
      if (at < cues.firstDownbeat) at = cues.firstDownbeat;
    }
    // Onto its own four-bar grid: the marker at or before, where there is one at or
    // after the first downbeat. Then onto the steady grid: the downbeat the analysis
    // gave can be a frame out, and a record parked a frame out starts a frame out.
    for (final m in to.markers.reversed) {
      if (m <= at.inMilliseconds && m >= cues.firstDownbeatMs) {
        return to.onGrid(Duration(milliseconds: m), every: 4);
      }
    }
    // Before the first marker: the nearest downbeat at or before — and never before
    // the first, whatever the grid says about the silence ahead of it.
    final downs = to.downbeats;
    for (var i = downs.length - 1; i >= 0; i--) {
      if (downs[i] <= at.inMilliseconds && downs[i] >= cues.firstDownbeatMs) {
        return to.onGrid(Duration(milliseconds: downs[i]));
      }
    }
    return to.onGrid(at);
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
    booth.note(BoothEventKind.auto,
        'Auto DJ on · ${_tracks.length - _at} record${_tracks.length - _at == 1 ? '' : 's'}, ${style.name}');
    unawaited(learnTaste());
    final deck = booth.master;
    // The record it is already playing stays where it is: handing the queue to the
    // booth mid-song should be the booth taking over, not the song starting again.
    if (deck.track?.id != _tracks[_at].id) {
      await booth.load(deck, _tracks[_at], at: from);
    } else if (from != null && (deck.position - from).abs() > const Duration(seconds: 2)) {
      await deck.seek(from);
    }
    if (!deck.playing) await deck.play();
    await booth.setCrossfader(identical(deck, booth.b) ? 1 : 0);
    await _prepareNext();
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
    notifyListeners();
  }

  void stop() {
    if (running) booth.note(BoothEventKind.auto, 'Auto DJ off');
    running = false;
    _asked++; // and a preparation under way writes no plan after it
    _endGlide();
    _watch?.cancel();
    _watch = null;
    plan = null;
    goesAt = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ what was made
  /// The last mix the automix made: what it went from and into, how, where — and
  /// what was thought of it, once said. What the rating buttons and REPLAY work on.
  LastMix? lastMix;

  /// A thumb up (1), down (-1), or neither (0) on [lastMix]: kept by the house.
  Future<void> rate(int rating) async {
    final m = lastMix;
    if (m == null) return;
    lastMix = m.copyWith(rating: rating);
    notifyListeners();
    await _tell('rating', m, {'rating': rating});
  }

  /// The last mix again: the old record back on the free deck a phrase before it
  /// went out, the new one parked where it came in, the same move — so a mix can be
  /// heard twice before it is judged, or heard again after steering.
  Future<void> replayLast() async {
    final m = lastMix;
    if (m == null || !running || booth.busy) return;
    final now = booth.master;
    if (now.track?.id != m.to.id || _at < 1 || _tracks[_at].id != m.to.id) return;
    final old = booth.other(now);
    _endGlide();
    booth.note(BoothEventKind.auto, 'Again: ${m.from.displayTitle} into ${m.to.displayTitle}');
    final bar = now.timing?.bar ?? const Duration(seconds: 2);
    await now.pause();
    await now.setTempo(1.0);
    await booth.setGain(now, 1.0);
    if (booth.pitchShiftOf(now) != 0) await booth.setPitchShift(now, 0);
    // The old record back where it was four bars before it went out, and leading.
    final fromAt = m.outAt - bar * 4;
    await old.load(m.from, timing: booth.timing.peek(m.from.id), at: fromAt > Duration.zero ? fromAt : Duration.zero);
    await old.setTempo(1.0);
    booth.master = old;
    await booth.setCrossfader(identical(old, booth.b) ? 1 : 0);
    await old.play();
    _at--;
    steers[(m.from.id, m.to.id)] = m.plan;
    await _tell('replay', m, const {});
    await _prepareNext();
  }

  /// Every mix made and every hand on the plan, told to the house — quietly: a house
  /// that cannot be reached loses a note, not the mix.
  Future<void> _tell(String event, LastMix m, Map<String, dynamic> more) async {
    try {
      await booth.api.boothFeedback({
        'event': event,
        'from_track': m.from.id,
        'to_track': m.to.id,
        'kind': m.plan.kind.name,
        'bars': m.plan.bars,
        'shift': m.plan.shift,
        'out_ms': m.outAt.inMilliseconds,
        'in_ms': m.inAt.inMilliseconds,
        'detail': {
          'why': m.plan.why,
          'score': m.plan.score,
          'steered': m.steered,
          'style': style.name,
          'axes': {'length': axes.length, 'risk': axes.risk, 'vocals': axes.vocals},
          ...more,
        },
      }).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// A hand on the plan coming, told to the house as such.
  void _tellSteer(String how, MixPlan p) {
    final on = current, nxt = next;
    if (on == null || nxt == null) return;
    final m = LastMix(from: on, to: nxt, plan: p, outAt: goesAt ?? Duration.zero, inAt: comesInAt ?? Duration.zero, steered: true, at: DateTime.now());
    unawaited(_tell('steer', m, {'how': how, 'was': planned?.kind.name, 'wasBars': planned?.bars}));
  }

  // ------------------------------------------------------------------ the glide
  /// After a mix the new master is at the old one's tempo and, where it was the
  /// louder, turned down to its level. Left there, a set is stuck at its first
  /// record's tempo for good — and a record ten percent from *that* one falls out of
  /// reach although it is two from the one before it. So over the next bars the
  /// master eases back to its own tempo and its own level: a set of faster records
  /// gets faster, and nobody hears it happen.
  Timer? _glide;
  bool _gliding = false;
  bool get gliding => _gliding;

  /// The pitch the master will be at once it has settled: what the next record is
  /// matched to and judged against — not the pitch it is passing through.
  double get masterTargetPitch => _gliding ? 1.0 : booth.master.pitch;

  /// How long the glide takes, in the master's bars.
  int get glideBars => switch (style) {
        MixStyle.easy => 32,
        MixStyle.normal => 16,
        MixStyle.bold => 8,
      };

  void _startGlide() {
    _endGlide();
    final m = booth.master;
    final fromPitch = m.pitch;
    final fromGain = booth.gainOf(m);
    final fromShift = booth.pitchShiftOf(m);
    if ((fromPitch - 1).abs() < 0.003 && (fromGain - 1).abs() < 0.01 && fromShift == 0) return;
    final length = booth.barsLength(m, glideBars);
    if (length <= Duration.zero) return;
    final began = DateTime.now();
    _gliding = true;
    booth.note(BoothEventKind.sync, '${m.name} eases back to its own tempo over $glideBars bars', deck: m);
    _glide = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      // Not once the record is going out, or somebody has taken the booth back.
      if (!identical(booth.master, m) || booth.busy || !running) {
        _endGlide();
        return;
      }
      final k = (DateTime.now().difference(began).inMicroseconds / length.inMicroseconds).clamp(0.0, 1.0);
      // Evenly in ratio, not in beats a minute: a tenth up and a tenth down feel alike.
      final pitch = fromPitch * math.pow(1 / fromPitch, k);
      if ((m.pitch - pitch).abs() > 0.0005) await m.setTempo(pitch);
      final gain = fromGain + (1 - fromGain) * k;
      if ((booth.gainOf(m) - gain).abs() > 0.002) await booth.setGain(m, gain);
      // A shifted key eased back to the record's own, in steps small enough not to
      // hear as steps.
      final shift = fromShift * (1 - k);
      if ((booth.pitchShiftOf(m) - shift).abs() > 0.04) await booth.setPitchShift(m, shift);
      if (k >= 1) {
        _endGlide();
        if (m.pitch != 1.0) await m.setTempo(1.0);
        if (booth.gainOf(m) != 1.0) await booth.setGain(m, 1.0);
        if (booth.pitchShiftOf(m) != 0) await booth.setPitchShift(m, 0);
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _endGlide() {
    _glide?.cancel();
    _glide = null;
    _gliding = false;
  }

  /// The record after this one, on the free deck: loaded, synced, parked where it
  /// will come in — and the plan for getting there written down.
  Future<void> _prepareNext() {
    // One at a time. The queue can change while one waits on the house (the parts,
    // the voices — ten seconds and more), and each change asks again: run side by
    // side they loaded the free deck over and over and wrote their plans over each
    // other. Asked again while one runs, that one stops at its next step and starts
    // over with what is true now.
    _asked++;
    return _preparing ??= () async {
      try {
        while (true) {
          final ticket = _asked;
          await _prepare(() => ticket != _asked || _disposed);
          // Asked again meanwhile: again — unless what asked was the automix being
          // switched off or the booth going.
          if (ticket == _asked || !running || _disposed) break;
        }
      } finally {
        _preparing = null;
        if (working != null) {
          working = null;
          notifyListeners();
        }
      }
    }();
  }

  int _asked = 0;
  Future<void>? _preparing;

  Future<void> _prepare(bool Function() stale) async {
    why = null;
    _workingSince = DateTime.now();
    if (pickBest && !replaying) await _bringTheBestForward();
    if (stale()) return;
    // The parts of what is coming asked for alongside, not waited for: the plan goes
    // by what is on the decks (a record in stems plays as stems), and asking — a
    // question of the house per record, a record fetched to split here — once held
    // the plan up for half a minute.
    working = 'looking ahead';
    notifyListeners();
    unawaited(_askAhead());
    final coming = next;
    final from = booth.master;
    final to = booth.other(from);
    if (coming == null) {
      plan = null;
      goesAt = null;
      notifyListeners();
      return;
    }
    // Not waited for for ever: a house that does not answer is a record without a
    // grid, mixed the plain way, not a queue that stops.
    working = 'reading the beat of ${coming.displayTitle}';
    notifyListeners();
    final timing = await booth.timing
        .of(coming)
        .timeout(const Duration(seconds: 15), onTimeout: () => null);
    if (stale()) return;
    final was = from.track == null ? null : _keptFor(from.track!.id, coming.id);
    final fromPitch = masterTargetPitch;
    var chosen = was == null
        ? choose(from.timing, timing,
            style: style, parts: inParts(from.track, coming), fromPitch: fromPitch)
        : (kind: was.kind, bars: was.bars);
    plan = chosen;
    if (was != null) {
      // As it was done: the same places, the same rate.
      goesAt = Duration(milliseconds: was.outMs);
      if (to.track?.id != coming.id) {
        await to.load(coming, timing: timing, at: Duration(milliseconds: was.inMs));
      }
      if (was.tempo != 1.0) await to.setTempo(was.tempo);
      notifyListeners();
      return;
    }
    final length = booth.barsLength(from, chosen.bars);
    // A record nobody has analysed still has to be mixed out of: without a timing
    // the booth simply waited for ever, which is a queue that stops after one song.
    // Its own length, less the transition, is where it goes.
    final timed = from.timing;
    if (timed != null) {
      // Counted in the record's own bars: at a pitch other than its own, the bars on
      // the clock are not the bars in the file, and a place in the file is wanted.
      final bar = timed.bar;
      final inRecord = bar == null ? length : bar * chosen.bars;
      goesAt = clearOfDrops(timed, outPoint(timed, length: inRecord), length: inRecord);
    } else {
      final total = from.duration ?? Duration.zero;
      final at = total - length;
      goesAt = at > Duration.zero ? at : total;
    }
    // Aimed at the drop where there is one and the style is for landing on it.
    final onTheDrop = style == MixStyle.bold && (timing?.drops.isNotEmpty ?? false);
    // Records that cannot be put in step are handed over, not blended, so the new
    // one starts where it starts rather than deep in an intro meant for mixing.
    final inStep = timed != null &&
        timing != null &&
        timed.gridBpm != null &&
        timing.gridBpm != null &&
        Booth.syncRatio(timing.gridBpm!, timed.gridBpm! * fromPitch, reach: Booth.bridgeReach) != null;
    final at = timing == null
        ? null
        : inStep
            ? inPoint(timing, bars: chosen.bars, onTheDrop: onTheDrop)
            : (timing.cues?.firstDownbeat ?? timing.lead);
    // Only if it is not the one already waiting there, parked where it should be.
    if (to.track?.id != coming.id || to.playing) {
      working = 'putting it on deck ${to.name}';
      notifyListeners();
      await to.load(coming, timing: timing, at: at);
    }
    if (stale()) return;
    // Now that both are known — which is in stems, where each sings, what each
    // sings — the move itself, and where it goes out and comes in.
    MixPlan? planned;
    options = const [];
    this.planned = null;
    if (inStep && from.track != null) {
      working = 'listening for the voices';
      notifyListeners();
      final voices = await Future.wait([
        booth.vocals.of(from.track!).timeout(const Duration(seconds: 6), onTimeout: () => null),
        booth.vocals.of(coming).timeout(const Duration(seconds: 6), onTimeout: () => null),
      ]);
      if (stale()) return;
      fromVoice = voices[0];
      toVoice = voices[1];
      options = Planner.options(
        from: MixSide(
            timing: timed, vocals: voices[0], stems: from.stemmed, pitch: fromPitch,
            fx: booth.mixer.canShift, position: from.position),
        to: MixSide(timing: timing, vocals: voices[1], stems: to.stemmed, fx: booth.mixer.canShift),
        style: style,
        axes: _axes,
        recent: recent,
        sound: booth.fx.can,
        gate: booth.mixer.canGate,
        taste: taste,
      );
      // A hand's choice for this very pair stands.
      final byHand = steers[(from.track!.id, coming.id)];
      planned = byHand ?? options.first;
      await _apply(planned, from, to, timing, onTheDrop: onTheDrop, exact: byHand != null);
      chosen = (kind: planned.kind, bars: planned.bars);
    }
    if (stale()) return;
    // The incoming comes to the master's tempo, as far as the automix reaches; the
    // master's never moves. One that cannot be put in step plays at its own speed —
    // not at whatever pitch the deck was last left at.
    if (inStep) {
      // To the master's own tempo — where it will be once it has settled (the glide),
      // not where it is passing through now.
      await booth.sync(to, reach: Booth.bridgeReach, target: timed.gridBpm! * fromPitch);
    } else if (to.pitch != 1.0) {
      await to.setTempo(1.0);
    }
    if (stale()) return;
    working = null;
    booth.note(BoothEventKind.next, 'Next: ${coming.displayTitle}', deck: to);
    final go2 = goesAt;
    booth.note(
        BoothEventKind.plan,
        inStep
            ? '${chosen.kind.label}, ${chosen.bars} bars, from ${go2 == null ? '…' : clock(go2)}'
                ' · cued at ${clock(to.position)}${planned == null ? '' : ' — ${planned.why}'}'
            : 'Too far apart to put in step: ${chosen.kind.label}',
        deck: to);
    notifyListeners();
  }

  /// Every move the planner offered for the transition coming, best first: what the
  /// plan view shows, and what a hand may choose from instead. Empty where the two
  /// cannot be put in step (there is only the one way then).
  List<MixPlan> options = const [];

  /// The move in hand for the transition coming — the planner's, or a hand's — with
  /// its places. Null where there is none worth showing (see [options]).
  MixPlan? planned;

  /// What the preparation of the next transition is doing, while it is: for the plan
  /// view to say rather than only "working it out". Null when it is not.
  String? working;
  DateTime? _workingSince;
  Duration? get workingFor => working == null || _workingSince == null
      ? null
      : DateTime.now().difference(_workingSince!);

  /// Where in the new record the move starts it: where it is parked.
  Duration? comesInAt;

  /// Where each of the two records sings, as the planner saw it.
  VocalMap? fromVoice, toVoice;

  /// A hand's choices, by the pair each was made for: kept across the automix asking
  /// again (the queue moving, the style changed) until that pair has been mixed —
  /// for the pair coming, and for any pair further down the set (the set view).
  final steers = <(int from, int to), MixPlan>{};

  /// Whether the move coming is one a hand chose.
  bool get steered {
    final on = current, nxt = next;
    return on != null && nxt != null && planned != null && identical(steers[(on.id, nxt.id)], planned);
  }

  // ------------------------------------------------------------------ the set
  int get at => _at;
  List<Track> get tracks => _tracks;

  /// The records still to come after the one on now, in the order they will play.
  List<Track> get upcoming => _at + 1 < _tracks.length ? _tracks.sublist(_at + 1) : const [];

  /// How well [b] would follow [a], by what is known of both now — for the set view.
  Fit fitBetween(Track a, Track b) => SetPlanner.fit(booth.timing.peek(a.id), booth.timing.peek(b.id),
      ta: a, tb: b, fromPitch: identical(a, current) ? masterTargetPitch : 1, move: _moveScore(a, b), taste: taste);

  /// Every move the planner would offer between [a] and [b], best first — what the
  /// set view shows for a pair further down, and steers by. Asks the house for what
  /// it does not have yet (the grids, the voices), within reason.
  Future<List<MixPlan>> optionsFor(Track a, Track b) async {
    final ta = await booth.timing.of(a).timeout(const Duration(seconds: 15), onTimeout: () => null);
    final tb = await booth.timing.of(b).timeout(const Duration(seconds: 15), onTimeout: () => null);
    if (ta == null || tb == null) return const [];
    final voices = await Future.wait([
      booth.vocals.of(a).timeout(const Duration(seconds: 6), onTimeout: () => null),
      booth.vocals.of(b).timeout(const Duration(seconds: 6), onTimeout: () => null),
    ]);
    final stems = _inParts[a.id] == true && _inParts[b.id] == true && booth.mixer.canStem;
    return Planner.options(
      from: MixSide(timing: ta, vocals: voices[0], stems: stems, fx: booth.mixer.canShift,
          pitch: identical(a, current) ? masterTargetPitch : 1),
      to: MixSide(timing: tb, vocals: voices[1], stems: stems, fx: booth.mixer.canShift),
      style: style,
      axes: _axes,
      recent: recent,
      sound: booth.fx.can,
      gate: booth.mixer.canGate,
      taste: taste,
    );
  }

  /// The move the planner would make between [a] and [b], as far as it has been
  /// worked out — asked for the first time this is called, and told when it is there.
  final _previews = <(int, int), MixPlan?>{};
  MixPlan? previewOf(Track a, Track b) {
    final key = (a.id, b.id);
    final byHand = steers[key];
    if (byHand != null) return byHand;
    if (_previews.containsKey(key)) return _previews[key];
    _previews[key] = null;
    unawaited(() async {
      final options = await optionsFor(a, b);
      if (_disposed) return;
      _previews[key] = options.isEmpty ? null : options.first;
      notifyListeners();
    }());
    return null;
  }

  /// A hand's choice for a pair further down the set: kept until that pair is mixed.
  void steerPair(Track a, Track b, MixPlan? p) {
    final key = (a.id, b.id);
    if (p == null) {
      steers.remove(key);
    } else {
      steers[key] = p;
    }
    if (identical(a, current) && identical(b, next)) {
      unawaited(p == null ? letThePlannerChoose() : steer(p));
      return;
    }
    notifyListeners();
  }

  /// Whether a hand can steer now: a plan laid out, its record waiting on the other
  /// deck, and nothing already under way.
  bool get canSteer {
    final to = booth.other(booth.master);
    return running &&
        !replaying &&
        !booth.inTransition &&
        !booth.busy &&
        planned != null &&
        next != null &&
        to.track?.id == next!.id &&
        booth.master.timing != null &&
        to.timing != null;
  }

  /// Put [p] in hand: the move, its length, where the old record goes out (a place a
  /// hand chose is kept as it is; the planner's is moved off a drop it would run
  /// over) and where the new one is parked to come in.
  Future<void> _apply(MixPlan p, Deck from, Deck to, TrackTiming timing,
      {bool onTheDrop = false, bool exact = false}) async {
    final timed = from.timing!;
    planned = p;
    plan = (kind: p.kind, bars: p.bars);
    why = p.why;
    final bar = timed.bar;
    final inRecord = bar == null ? booth.barsLength(from, p.bars) : bar * p.bars;
    final out = p.outAt;
    goesAt = out != null && exact
        ? out
        : clearOfDrops(timed, out ?? outPoint(timed, length: inRecord), length: inRecord);
    final inAt = comesInAt = p.inAt ?? inPoint(timing, bars: p.bars, onTheDrop: onTheDrop);
    if (!to.playing && (to.position - inAt).abs() > const Duration(milliseconds: 20)) {
      await to.seek(inAt);
    }
    // Level-matched over the overlap: the incoming, where it is the louder there,
    // turned down to the outgoing's level — and eased back up after (the glide).
    final match = levelMatch(from, to, goesAt ?? Duration.zero, inAt, p.bars);
    if (match != null) await booth.setGain(to, match);
    notifyListeners();
  }

  /// The gain that puts [to]'s first [bars] from [inAt] at the level of [from]'s
  /// [bars] from [outAt], by the bars' loudness as the house measured them (the
  /// record's own trim already taken off) — 1.0 where [to] is the quieter, which
  /// cannot be turned up, and null where either was never measured.
  double? levelMatch(Deck from, Deck to, Duration outAt, Duration inAt, int bars) {
    final f = from.timing?.structure, t = to.timing?.structure;
    if (f == null || t == null || f.mixDb.isEmpty || t.mixDb.isEmpty) return null;
    double? over(TrackStructure s, Duration at, double trim) {
      var i = 0;
      while (i + 1 < s.barsMs.length && s.barsMs[i + 1] <= at.inMilliseconds) {
        i++;
      }
      final slice = s.mixDb.sublist(i, math.min(s.mixDb.length, i + bars)).where((d) => d > -90);
      if (slice.isEmpty) return null;
      final mean = slice.reduce((a, b) => a + b) / slice.length;
      return mean + 20 * math.log(trim) / math.ln10;
    }

    final outDb = over(f, outAt, booth.trimFor(from));
    final inDb = over(t, inAt, booth.trimFor(to));
    if (outDb == null || inDb == null) return null;
    final diff = outDb - inDb;
    if (diff >= -0.5) return 1.0;
    return math.pow(10, diff / 20).toDouble().clamp(0.35, 1.0);
  }

  /// A hand steering: [p] instead of what the planner chose, for this pair only.
  Future<void> steer(MixPlan p) async {
    if (!canSteer) return;
    _tellSteer('steer', p);
    final from = booth.master, to = booth.other(from);
    steers[(from.track!.id, to.track!.id)] = p;
    // A preparation under way would plan over the hand: it starts over, and keeps it.
    _asked++;
    await _apply(p, from, to, to.timing!, exact: true);
    booth.note(BoothEventKind.plan,
        'By hand: ${p.kind.label}, ${p.bars} bars, from ${goesAt == null ? '…' : clock(goesAt!)}',
        deck: to);
  }

  /// The move coming, over [bars] instead. One that lands on the new record's drop
  /// is parked again so that it still does.
  Future<void> lengthen(int bars) async {
    final p = planned;
    final to = booth.other(booth.master);
    if (p == null || !canSteer) return;
    final onDrop = p.kind == Transition.dropSwap || p.kind == Transition.roll;
    await steer(MixPlan(p.kind, bars,
        outAt: p.outAt ?? goesAt,
        inAt: onDrop ? inPoint(to.timing!, bars: bars, onTheDrop: true) : p.inAt,
        why: p.why,
        score: p.score));
  }

  /// The old record goes out [phrases] four-bar phrases later (or earlier).
  Future<void> nudgeOut(int phrases) async {
    final p = planned;
    final from = booth.master;
    final bar = from.timing?.bar;
    final at = goesAt;
    if (p == null || bar == null || at == null || !canSteer) return;
    var out = at + bar * (4 * phrases);
    final first = from.timing!.cues?.firstDownbeat ?? Duration.zero;
    final last = (from.duration ?? out) - bar * p.bars;
    if (out < first) out = first;
    if (out > last) out = last;
    if (out <= from.position) return;
    await steer(p.copyWith(outAt: out));
  }

  /// The new record comes in [phrases] four-bar phrases further into it (or less).
  Future<void> nudgeIn(int phrases) async {
    final p = planned;
    final to = booth.other(booth.master);
    final bar = to.timing?.bar;
    if (p == null || bar == null || to.playing || !canSteer) return;
    var inAt = to.position + bar * (4 * phrases);
    final first = to.timing!.cues?.firstDownbeat ?? Duration.zero;
    if (inAt < first) inAt = first;
    final end = to.duration;
    if (end != null && inAt > end - bar * p.bars) return;
    await steer(p.copyWith(inAt: inAt, outAt: goesAt));
  }

  /// The planner's again: what a hand chose is let go of, and the move chosen afresh.
  Future<void> letThePlannerChoose() async {
    final on = current, nxt = next;
    if (on == null || nxt == null || steers.remove((on.id, nxt.id)) == null) return;
    booth.note(BoothEventKind.plan, 'Back to the Auto DJ\'s own choice');
    await _prepareNext();
  }

  /// A place in a record as a DJ reads it: 3:12.
  static String clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Of everything still to play, put the one that follows this best next.
  ///
  /// Only judged on what is already known: a record whose timing has not arrived yet
  /// keeps its place in the queue, and is asked about so the next choice is better
  /// informed. Nothing is dropped — the order changes, the records do not.
  Future<void> _bringTheBestForward() async {
    final on = current;
    if (on == null || booth.master.timing == null || _at + 2 > _tracks.length - 1) return;
    final rest = _tracks.sublist(_at + 1);
    for (final t in rest) {
      if (booth.timing.peek(t.id) == null) unawaited(booth.timing.of(t));
    }
    final ordered = SetPlanner.order(rest,
        from: on,
        timingOf: booth.timing.peek,
        arc: arc,
        locked: locked,
        before: _before(),
        fromPitch: masterTargetPitch,
        moveOf: _moveScore,
        taste: taste);
    if (ordered.first.id != rest.first.id) {
      final why = fitOf(ordered.first).why;
      booth.note(BoothEventKind.next,
          'Picked ${ordered.first.displayTitle}${why.isEmpty ? '' : ': $why'}');
    }
    _tracks = [..._tracks.sublist(0, _at + 1), ...ordered];
  }

  bool _going = false;

  Future<void> _tick() async {
    // Nothing while a mix is waiting for its beat or running — the automix's own, or
    // one somebody started by hand.
    if (!running || _going || booth.busy) return;
    final from = booth.master;
    final go = goesAt;
    final coming = next;
    if (coming == null) {
      // The last record — unless the booth is to keep going, from the library.
      if (fill && from.playing) {
        unawaited(_fillFromLibrary());
        return;
      }
      // Let it end, then stop.
      if (!from.playing) stop();
      return;
    }
    if (go == null) return;
    // The record ran out — or never started. Either way the next one is what the
    // queue is for: the booth does not sit in silence waiting for a clock that has
    // stopped.
    final ended = !from.playing &&
        from.duration != null &&
        from.position >= from.duration! - const Duration(milliseconds: 400);
    if (!from.playing && !ended) return;
    // Armed a moment early, so the incoming can be started on the exact beat rather
    // than on the first tick after it — which was the next phrase, eight seconds and
    // more too late, with the whole mix landing that much after where it was aimed.
    final left = Duration(
        microseconds: ((go - from.position).inMicroseconds / from.tempo).round());
    if (left > armAhead && !ended) return;
    _going = true;
    try {
      final chosen = plan ??
          choose(from.timing, booth.other(from).timing,
              style: style,
              parts: inParts(from.track, booth.other(from).track),
              fromPitch: from.pitch);
      final was = booth.master;
      // A preparation still under way was for the decks as they were: stopped here,
      // before it can load the next record over the one going live. A glide still on
      // stops too: the record it was bending is going out.
      _asked++;
      _endGlide();
      await booth.go(chosen.kind,
          bars: chosen.bars,
          startAt: ended ? null : startFor(from.timing, go, from.position),
          shift: planned?.shift ?? 0);
      if (identical(booth.master, was)) {
        // It refused: the record it was going into would not play. Say so and stop,
        // rather than trying the same thing again every fifth of a second.
        stop();
        return;
      }
      final done = (from.track?.id, booth.master.track?.id);
      if (from.track != null && booth.master.track != null) {
        final made = LastMix(
          from: from.track!,
          to: booth.master.track!,
          plan: planned ?? MixPlan(chosen.kind, chosen.bars),
          outAt: go,
          inAt: comesInAt ?? Duration.zero,
          steered: steered,
          at: DateTime.now(),
        );
        lastMix = made;
        unawaited(_tell('mix', made, {'byHand': ended}));
      }
      _at++;
      steers.remove(done);
      _previews.remove(done);
      options = const [];
      planned = null;
      // The record now leading was bent to the last one's tempo, and turned down to
      // its level: eased back to its own over the next bars.
      _startGlide();
      // The plan just carried out is spent: left standing, its moment — long past on
      // the record now leading — would send the booth straight back the other way.
      plan = null;
      goesAt = null;
      // Laid out in the background: a house slow to answer holds up the next plan,
      // never the booth.
      unawaited(_prepareNext());
    } finally {
      _going = false;
    }
  }

  /// How long before the planned moment the booth gets ready to go.
  static const armAhead = Duration(milliseconds: 1500);

  /// The downbeat of the outgoing record the incoming starts on: the four-bar marker
  /// nearest the plan's [go], where that is still ahead of [now] — or the next
  /// downbeat, where the plan's moment has passed (a hand said "now", or the record
  /// was late getting here), and the incoming is moved to the same bar of its own
  /// phrase as it starts (Booth.go). Null with no grid, which is a start straight
  /// away.
  static Duration? startFor(TrackTiming? timing, Duration go, Duration now) {
    if (timing == null || !timing.hasBeats) return null;
    final soon = now + const Duration(milliseconds: 250);
    final downs = timing.downbeats.isNotEmpty
        ? timing.downbeats
        : [
            for (var i = 0; i < timing.beats.length; i++)
              if ((i - timing.barStartsOn) % 4 == 0) timing.beats[i],
          ];
    if (downs.isEmpty) return null;
    int? best;
    if (go > soon) {
      for (final d in timing.markers.isNotEmpty ? timing.markers : downs) {
        if (d < soon.inMilliseconds) continue;
        if (best == null || (d - go.inMilliseconds).abs() < (best - go.inMilliseconds).abs()) {
          best = d;
        }
      }
    } else {
      for (final d in downs) {
        if (d >= soon.inMilliseconds) {
          best = d;
          break;
        }
      }
    }
    // On the steady grid, for the same reason the incoming is parked on it.
    return best == null ? null : timing.onGrid(Duration(milliseconds: best));
  }

  // A preparation runs in the background (_prepareNext) and can finish after the
  // booth is gone: it stops at its next step, and says nothing to nobody.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _asked++;
    _endGlide();
    _watch?.cancel();
    _arrivals.cancel();
    super.dispose();
  }
}


/// One mix the automix made, as it was made: what it went from and into, the move
/// and its places, whether a hand chose it — and the thumb, once given.
class LastMix {
  const LastMix({
    required this.from,
    required this.to,
    required this.plan,
    required this.outAt,
    required this.inAt,
    required this.steered,
    required this.at,
    this.rating,
  });
  final Track from, to;
  final MixPlan plan;
  final Duration outAt, inAt;
  final bool steered;
  final DateTime at;
  final int? rating;

  LastMix copyWith({int? rating}) => LastMix(
      from: from, to: to, plan: plan, outAt: outAt, inAt: inAt, steered: steered, at: at, rating: rating ?? this.rating);
}
