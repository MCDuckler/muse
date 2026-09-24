import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import 'booth.dart';
import 'planner.dart';

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
        _inParts[t.id] = await booth.parts.want(t, 'stems') == Stem.ready;
      } catch (_) {
        // Not a record the server can take apart, or cannot be reached. Either way
        // the booth mixes it the ordinary way and says nothing about it.
        _inParts[t.id] = false;
      }
    }
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
  static double howWell(TrackTiming? from, TrackTiming? to, {double fromPitch = 1}) {
    if (from == null || to == null) return 0;
    var score = 0.0;
    final ratio = from.gridBpm != null && to.gridBpm != null
        ? Booth.syncRatio(to.gridBpm!, from.gridBpm! * fromPitch)
        : null;
    if (ratio != null) {
      // The less it has to be pulled, the better.
      score += 0.5 * (1 - ((ratio - 1).abs() / Booth.maxSync)).clamp(0.0, 1.0);
      score += 0.1;
    }
    // The wheel, graded: the same key or a neighbour mixes anywhere; two steps is an
    // energy move a DJ makes on purpose; further than that clashes.
    final steps = from.keyStepsTo(to);
    if (steps != null && steps <= 2) score += const [0.3, 0.25, 0.1][steps];
    final mine = _energy(from), theirs = _energy(to);
    if (mine != null && theirs != null) {
      score += 0.1 * (1 - (mine - theirs).abs()).clamp(0.0, 1.0);
    }
    return score;
  }

  /// A record's energy where the mix would happen, 0 to 1: how loud its loud part is
  /// against its own quietest. Null where the bars were never measured.
  static double? _energy(TrackTiming t) {
    if (t.energy.isEmpty) return null;
    final sorted = [...t.energy]..sort();
    return sorted[(sorted.length * 0.75).floor()] / 255;
  }

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
    if (next?.id != before && !booth.busy && !_going) {
      unawaited(_prepareNext());
    } else {
      notifyListeners();
    }
  }

  /// The moves made lately, newest last: what the planner steers away from repeating.
  final recent = <Transition>[];

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

  /// How hard the booth mixes.
  MixStyle style = MixStyle.normal;

  void mixLike(MixStyle how) {
    style = how;
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
    var at = cues?.mixOut ?? (end - length);
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
    _watch?.cancel();
    _watch = null;
    plan = null;
    goesAt = null;
    notifyListeners();
  }

  /// The record after this one, on the free deck: loaded, synced, parked where it
  /// will come in — and the plan for getting there written down.
  Future<void> _prepareNext() async {
    // The queue can change while this waits on the house (the parts, the voices — ten
    // seconds and more): a newer preparation takes over, and this one stops wherever
    // it has got to rather than writing its plan over the newer one's.
    final ticket = ++_preparing;
    bool stale() => ticket != _preparing;
    _prepping++;
    try {
      await _prepare(stale);
    } finally {
      _prepping--;
    }
  }

  int _preparing = 0;
  int _prepping = 0;

  Future<void> _prepare(bool Function() stale) async {
    why = null;
    if (pickBest && !replaying) await _bringTheBestForward();
    if (stale()) return;
    // Ask for the parts of what is coming before choosing how to get there: what the
    // server has already made is what the booth is allowed to plan around.
    await _askAhead();
    if (stale()) return;
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
    if (stale()) return;
    final was = from.track == null ? null : _keptFor(from.track!.id, coming.id);
    var chosen = was == null
        ? choose(from.timing, timing,
            style: style, parts: inParts(from.track, coming), fromPitch: from.pitch)
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
        Booth.syncRatio(timing.gridBpm!, timed.gridBpm! * from.pitch, reach: Booth.bridgeReach) != null;
    final at = timing == null
        ? null
        : inStep
            ? inPoint(timing, bars: chosen.bars, onTheDrop: onTheDrop)
            : (timing.cues?.firstDownbeat ?? timing.lead);
    // Only if it is not the one already waiting there, parked where it should be.
    if (to.track?.id != coming.id || to.playing) {
      await to.load(coming, timing: timing, at: at);
    }
    if (stale()) return;
    // Now that both are known — which is in stems, where each sings, what each
    // sings — the move itself, and where it goes out and comes in.
    MixPlan? planned;
    if (inStep && from.track != null) {
      final voices = await Future.wait([
        booth.vocals.of(from.track!).timeout(const Duration(seconds: 6), onTimeout: () => null),
        booth.vocals.of(coming).timeout(const Duration(seconds: 6), onTimeout: () => null),
      ]);
      if (stale()) return;
      planned = Planner.plan(
        from: MixSide(timing: timed, vocals: voices[0], stems: from.stemmed, pitch: from.pitch),
        to: MixSide(timing: timing, vocals: voices[1], stems: to.stemmed),
        style: style,
        recent: recent,
      );
      chosen = (kind: planned.kind, bars: planned.bars);
      plan = chosen;
      why = planned.why;
      final lengthNow = booth.barsLength(from, chosen.bars);
      final bar = timed.bar;
      final inRecord = bar == null ? lengthNow : bar * chosen.bars;
      goesAt = planned.outAt != null
          ? clearOfDrops(timed, planned.outAt!, length: inRecord)
          : clearOfDrops(timed, outPoint(timed, length: inRecord), length: inRecord);
      final inAt = planned.inAt ?? inPoint(timing, bars: chosen.bars, onTheDrop: onTheDrop);
      if (!to.playing && (to.position - inAt).abs() > const Duration(milliseconds: 20)) {
        await to.seek(inAt);
      }
    }
    // The incoming comes to the master's tempo, as far as the automix reaches; the
    // master's never moves. One that cannot be put in step plays at its own speed —
    // not at whatever pitch the deck was last left at.
    if (inStep) {
      await booth.sync(to, reach: Booth.bridgeReach);
    } else if (to.pitch != 1.0) {
      await to.setTempo(1.0);
    }
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
    final from = booth.master.timing;
    if (from == null || _at + 2 > _tracks.length - 1) return;
    var bestAt = _at + 1;
    var best = -1.0;
    for (var i = _at + 1; i < _tracks.length; i++) {
      final t = booth.timing.peek(_tracks[i].id);
      if (t == null) {
        unawaited(booth.timing.of(_tracks[i]));
        continue;
      }
      final score = howWell(from, t, fromPitch: booth.master.pitch);
      if (score > best) {
        best = score;
        bestAt = i;
      }
    }
    if (bestAt == _at + 1 || best <= 0) return;
    booth.note(BoothEventKind.next, 'Picked ${_tracks[bestAt].displayTitle}: it fits best');
    final moved = [..._tracks];
    moved.insert(_at + 1, moved.removeAt(bestAt));
    _tracks = moved;
  }

  bool _going = false;

  Future<void> _tick() async {
    // Nothing while a mix is waiting for its beat or running — the automix's own, or
    // one somebody started by hand.
    // Nor while the next record is still being planned: the plan half written is not one
    // to go on.
    if (!running || _going || booth.busy || _prepping > 0) return;
    final from = booth.master;
    final go = goesAt;
    final coming = next;
    if (coming == null) {
      // The last record: let it end, then stop.
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
      recent.add(chosen.kind);
      if (recent.length > 8) recent.removeAt(0);
      await booth.go(chosen.kind,
          bars: chosen.bars, startAt: ended ? null : startFor(from.timing, go, from.position));
      if (identical(booth.master, was)) {
        // It refused: the record it was going into would not play. Say so and stop,
        // rather than trying the same thing again every fifth of a second.
        stop();
        return;
      }
      _at++;
      await _prepareNext();
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

  @override
  void dispose() {
    _watch?.cancel();
    _arrivals.cancel();
    super.dispose();
  }
}
