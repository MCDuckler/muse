import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import 'booth.dart';
import 'deck.dart';
import 'dj_set.dart';
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

/// How the booth orders what it plays.
enum SetMode {
  /// The queue, in the order it is in. Changes a hand makes are followed; nothing is
  /// reordered.
  asQueued,

  /// What is queued, in the order that mixes best and follows the arc.
  bestOrder,

  /// A set built from a pool (PLAN A SET), re-routed from the pool as things change.
  set,
}

extension SetModeWords on SetMode {
  String get label => switch (this) {
        SetMode.asQueued => 'as queued',
        SetMode.bestOrder => 'best order',
        SetMode.set => 'the set',
      };
}

/// What the automix is doing, in one word — what the bars on the desk and the phone
/// say, the same way on both.
enum AutoState {
  /// Switched off.
  off,

  /// Working out the next transition, or waiting for its record to arrive.
  preparing,

  /// The next record is on the free deck, the move planned, the moment counted down.
  ready,

  /// The record in the room was paused by a hand: nothing happens until it plays.
  waiting,

  /// The next record is not ready and the one in the room was running out: its last
  /// bars go round until it is.
  holding,

  /// A transition is running — the automix's, or one somebody is doing by hand.
  mixing,

  /// Playing the last record there is, with nothing to follow it.
  last,
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

  /// How the booth orders what it plays: the queue as it is, what is queued in the
  /// order that mixes best, or a set built from a pool and re-routed as it goes.
  SetMode mode = SetMode.asQueued;

  /// Whether the booth chooses what comes next, rather than taking the queue in the
  /// order it is in: of everything still to play, the record that mixes best into
  /// the one on now. Off by default — a queue is usually a queue on purpose.
  bool get pickBest => mode == SetMode.bestOrder;
  set pickBest(bool on) => mode = on ? SetMode.bestOrder : (mode == SetMode.set ? SetMode.set : SetMode.asQueued);

  void chooseForYourself(bool on) => setMode(on ? SetMode.bestOrder : SetMode.asQueued);

  void setMode(SetMode m) {
    if (m == SetMode.set && set == null) m = SetMode.bestOrder;
    mode = m;
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

  // ------------------------------------------------------------------ the set
  /// The set being played, where one was laid out (PLAN A SET): its pool, its shape,
  /// its records. In [SetMode.set] the booth re-routes the rest of it whenever
  /// something changes, and keeps going from its pool.
  DjSet? set;

  SetHouse get house => SetHouse(booth.api);

  /// Play [s]: its records laid into the queue straight after the record on now —
  /// or from the top where nothing plays — and the booth following it, re-routing
  /// it as it goes. [now]: into its first record at once (a skip), rather than when
  /// the one playing ends.
  Future<void> playSet(DjSet s, {bool now = false}) async {
    set = s;
    mode = SetMode.set;
    _setPlayed.clear();
    locked
      ..clear()
      ..addAll([for (final x in s.slots) if (x.pinned) x.track.id]);
    arc = s.shape.preset.arc;
    final order = s.tracks;
    if (order.isEmpty) return;
    if (running) {
      _remember('the set laid out');
      final on = current;
      final ids = {for (final t in order) t.id};
      _heldNext = null;
      _tracks = [
        ..._tracks.sublist(0, _at + 1),
        ...order,
        for (final t in _tracks.sublist(_at + 1)) if (!ids.contains(t.id)) t,
      ];
      booth.note(BoothEventKind.plan,
          'The set: ${order.length} records from ${s.source.label.toLowerCase()}, ${s.shape.preset.label}');
      notifyListeners();
      unawaited(_arrange(on, order));
      await _prepareNext();
      if (now) await skip();
      return;
    }
    // Not running: from the record in the room where one plays, else the set's first.
    final m = booth.master;
    final playing = m.playing && m.track != null && !order.any((t) => t.id == m.track!.id);
    final list = [if (playing) m.track!, ...order];
    unawaited(_arrange(playing ? m.track : null, order));
    await start(list, at: 0);
  }

  /// The records of the set played so far, by id.
  final _setPlayed = <int>{};
  Iterable<int> get setPlayedIds => _setPlayed;
  void restorePlayed(Iterable<int> ids) => _setPlayed
    ..clear()
    ..addAll(ids);

  /// How far through the set the booth is, 0 to 1, by records played.
  double get setAt {
    final s = set;
    if (s == null || s.slots.isEmpty) return 0;
    return (_setPlayed.length / s.slots.length).clamp(0.0, 1.0);
  }

  Timer? _rerouteSoon;
  String? _rerouteWhy;

  /// The rest of the set laid again, in a moment: something changed (a record put on
  /// by hand, one sent away, the room asked for more), and what was planned after it
  /// was planned for a set that is no longer the one playing.
  void _rerouteLater(String why) {
    if (mode != SetMode.set || set == null || !running) return;
    _rerouteWhy = why;
    _rerouteSoon?.cancel();
    _rerouteSoon = Timer(const Duration(milliseconds: 1500), () => unawaited(_reroute()));
  }

  int _rerouted = 0;

  Future<void> _reroute() async {
    final s = set;
    final on = current;
    if (s == null || on == null || !running || mode != SetMode.set) return;
    if (booth.busy || _going) {
      _rerouteLater(_rerouteWhy ?? 'again');
      return;
    }
    final ticket = ++_rerouted;
    // The next stays where it is ready or a hand chose it: re-routed is what comes
    // after it.
    final nxt = next;
    final keep = nxt != null && (isReady || _heldNext == nxt.id || booth.other(booth.master).track?.id == nxt.id)
        ? nxt
        : null;
    final from = keep ?? on;
    final played = _tracks.sublist(0, _at + 1);
    final coming = {for (final t in s.tracks) t.id}..removeAll(_setPlayed);
    final left = math.max(2, coming.length - (keep == null ? 0 : 1));
    // The pins still to come, at their places among what is left.
    final upcomingSet = [for (final t in s.tracks) if (coming.contains(t.id) && t.id != keep?.id) t];
    final pins = <({int id, int slot})>[
      for (var i = 0; i < upcomingSet.length; i++)
        if (locked.contains(upcomingSet[i].id)) (id: upcomingSet[i].id, slot: i),
    ];
    final k = setAt + (keep == null ? 0 : 1 / math.max(1, s.slots.length));
    try {
      final built = await house
          .build(
            source: s.source,
            shape: s.shape.from(k),
            start: from,
            before: played.sublist(math.max(0, played.length - 4)),
            pins: pins,
            exclude: {for (final t in played) t.id, if (keep != null) keep.id},
            pitch: keep == null ? masterTargetPitch : 1,
            tracks: left,
          )
          .timeout(const Duration(seconds: 15));
      if (ticket != _rerouted || !running || current?.id != on.id || set != s) return;
      if (built.slots.isEmpty) return;
      final order = [if (keep != null) keep, ...built.tracks];
      _remember('the set re-routed: ${_rerouteWhy ?? 'something changed'}');
      final ids = {for (final t in order) t.id};
      _tracks = [
        ..._tracks.sublist(0, _at + 1),
        ...order,
        for (final t in _tracks.sublist(_at + 1)) if (!ids.contains(t.id)) t,
      ];
      // The set itself: what was played of it, the kept next, the new rest.
      final kept = [
        for (final x in s.slots) if (_setPlayed.contains(x.track.id) || x.track.id == on.id) x,
        if (keep != null) s.slots.firstWhere((x) => x.track.id == keep.id, orElse: () => SetSlot.of(keep)),
      ];
      set = s.copyWith(slots: [...kept, ...built.slots]).retimed();
      booth.note(BoothEventKind.plan,
          'The set re-routed (${_rerouteWhy ?? 'something changed'}): ${built.slots.first.track.displayTitle}'
          '${keep == null ? ' next' : ' after ${keep.displayTitle}'}');
      notifyListeners();
      unawaited(_arrange(on, order));
      if (keep == null) await _prepareNext();
    } catch (e) {
      booth.note(BoothEventKind.trouble, 'Could not re-route the set: the house did not answer');
    }
  }

  /// [s] judged again here, record by record: the house's coarse fit and words
  /// replaced by the set planner's own wherever both records' timings can be had —
  /// the first [first] of them, asked for four at a time — with the move the
  /// transition planner would make and this person's taste. [from] is the record
  /// the set follows, where it follows one.
  Future<DjSet> judgeSet(DjSet s, {Track? from, int first = 12}) async {
    final ask = [if (from != null) from, ...s.tracks.take(first)];
    for (var i = 0; i < ask.length; i += 4) {
      await Future.wait([
        for (final t in ask.skip(i).take(4))
          booth.timing.of(t).timeout(const Duration(seconds: 10), onTimeout: () => null),
      ]);
      if (_disposed) return s;
    }
    final out = <SetSlot>[];
    for (var i = 0; i < s.slots.length; i++) {
      final slot = s.slots[i];
      final prev = i == 0 ? from : s.slots[i - 1].track;
      final ta = prev == null ? null : booth.timing.peek(prev.id);
      final tb = booth.timing.peek(slot.track.id);
      if (i >= first || prev == null || ta == null || tb == null) {
        out.add(slot);
        continue;
      }
      final f = SetPlanner.fit(ta, tb,
          ta: prev,
          tb: slot.track,
          fromPitch: identical(prev, current) ? masterTargetPitch : 1,
          before: [for (var j = math.max(0, i - 4); j < i - 1; j++) s.slots[j].track],
          move: _moveScore(prev, slot.track),
          taste: taste);
      out.add(slot.copyWith(fit: f.score, why: f.why));
    }
    return s.copyWith(slots: out);
  }

  /// Rebuild the rest of the set from now, by hand.
  void rerouteNow() {
    if (mode != SetMode.set || set == null) return;
    _rerouteWhy = 'by hand';
    unawaited(_reroute());
  }

  // ------------------------------------------------------------------ the room's word
  /// Where the room has asked for more energy (or less) than the plan: added to the
  /// set's curve, or to the arc the booth orders the queue by.
  double energyOffset = 0;

  /// "More like this": the record the next ones lean towards, by sound.
  Track? likeThis;

  /// "Something different": the next records lean away from the one before, by sound.
  bool different = false;

  /// More energy (1) or less (-1) from here on.
  void nudgeEnergy(int dir) {
    final to = (energyOffset + 0.12 * dir).clamp(-0.36, 0.36);
    if (to == energyOffset) return;
    _remember(dir > 0 ? 'more energy' : 'less energy');
    energyOffset = to;
    booth.note(BoothEventKind.plan,
        '${dir > 0 ? 'More' : 'Less'} energy from here: ${energyOffset > 0 ? '+' : ''}${(energyOffset * 100).round()} %');
    _steered(dir > 0 ? 'more energy' : 'less energy');
  }

  /// The next records lean towards the sound of the one on now.
  void moreLikeThis() {
    final on = current;
    if (on == null) return;
    _remember('more like ${on.displayTitle}');
    likeThis = on;
    different = false;
    booth.note(BoothEventKind.plan, 'More like ${on.displayTitle} from here');
    _steered('more like this');
  }

  /// The next records lean away from the sound of the one before them.
  void somethingDifferent() {
    _remember('something different');
    likeThis = null;
    different = true;
    booth.note(BoothEventKind.plan, 'Something different from here');
    _steered('something different');
  }

  /// The room's word taken back: the plan's own curve and sound again.
  void steerNeutral() {
    if (energyOffset == 0 && likeThis == null && !different) return;
    _remember('the room\'s word taken back');
    energyOffset = 0;
    likeThis = null;
    different = false;
    _steered('as planned');
  }

  void _steered(String why) {
    notifyListeners();
    switch (mode) {
      case SetMode.set:
        final s = set;
        if (s != null) {
          set = s.copyWith(
              shape: s.shape.copyWith(
            offset: energyOffset,
            anchor: likeThis?.id,
            noAnchor: likeThis == null,
            smooth: likeThis != null ? 0.85 : different ? 0.1 : 0.5,
          ));
        }
        _rerouteLater(why);
      case SetMode.bestOrder:
        unawaited(_prepareNext());
      case SetMode.asQueued:
        // Asked of a queue played as it is: the booth orders what is queued now, the
        // way the room asked — said, and undoable like any other change.
        mode = SetMode.bestOrder;
        booth.note(BoothEventKind.plan, 'The booth orders what is queued from now on ($why)');
        unawaited(_prepareNext());
    }
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
    if (on && running) unawaited(_fillAhead());
  }

  /// Where KEEP GOING takes its records from: the set's own pool while a set plays,
  /// the whole library otherwise — or what was chosen for it by hand.
  SetSource? fillFrom;
  SetSource get fillSource => fillFrom ?? (mode == SetMode.set ? set?.source : null) ?? SetSource.wholeLibrary;

  void fillFromSource(SetSource? s) {
    fillFrom = s;
    notifyListeners();
  }

  /// How many records KEEP GOING keeps lined up after the one on now: two, so the
  /// next is always chosen well before its moment, not in the last seconds.
  static const fillAhead = 2;

  /// Told to keep going and running short: the best follower of the last record lined
  /// up, from [fillSource], judged finely — until [fillAhead] are lined up.
  Future<void> _fillAhead() async {
    if (_filling || !fill || !running) return;
    final tried = _fillTriedAt;
    if (tried != null && DateTime.now().difference(tried) < const Duration(seconds: 20)) return;
    _filling = true;
    try {
      while (fill && running && !_disposed && upcoming.length < fillAhead) {
        final last = _tracks.isEmpty ? null : _tracks.last;
        if (last == null) return;
        _fillTriedAt = DateTime.now();
        final found = await partnersFor(last, limit: 8);
        if (_disposed || !running || !fill) return;
        if (found.isEmpty) {
          booth.note(BoothEventKind.plan,
              'Nothing in ${fillSource.label.toLowerCase()} to follow ${last.displayTitle}');
          return;
        }
        final pick = found.first;
        booth.note(BoothEventKind.next,
            'Keep going: ${pick.track.displayTitle}${pick.why.isEmpty ? '' : ' · ${pick.why}'}');
        final hadNext = next;
        _tracks = [..._tracks, pick.track];
        final s = set;
        if (mode == SetMode.set && s != null) {
          set = s.copyWith(slots: [...s.slots, SetSlot(track: pick.track, fit: pick.fit, why: pick.why)]).retimed();
        }
        final tell = onFill;
        if (tell != null) {
          try {
            await tell(pick.track);
          } catch (_) {}
        }
        if (hadNext == null && !_disposed && running) unawaited(_prepareNext());
        notifyListeners();
      }
    } finally {
      _filling = false;
    }
  }

  /// The records that would follow [from] best, from [fillSource] (or [source]): the
  /// house's coarse pick of a few dozen, judged again here with everything the set
  /// planner reads — the seam, the sound, the move the transition planner would make
  /// — best first.
  Future<List<({Track track, double fit, String why})>> partnersFor(Track from,
      {int limit = 6, SetSource? source}) async {
    final here = _tracks.indexWhere((t) => t.id == from.id);
    final before = here < 0 ? _before() : [for (var i = math.max(0, here - 3); i < here; i++) _tracks[i]];
    final n = _tracks.length;
    final start = current == null ? null : SetPlanner.energyOf(current, booth.timing.peek(current!.id));
    final wanted = here < 0 || start == null
        ? 0.0
        : (SetPlanner.target(arc, here + 1, n + 1, start) ?? start) + energyOffset - (SetPlanner.energyOf(from, booth.timing.peek(from.id)) ?? start);
    List<({Track track, double fit, String why})> coarse;
    final pool = source ?? fillSource;
    final s = set;
    try {
      // The set builder's one-slot answer: from any pool, to the set's shape.
      final shape = (mode == SetMode.set && s != null ? s.shape.from(setAt) : SetShape(preset: EnergyPreset.plateau))
          .copyWith(offset: energyOffset, anchor: likeThis?.id, noAnchor: likeThis == null,
              smooth: likeThis != null ? 0.85 : different ? 0.1 : null);
      final choices = await house
          .choices(
            source: pool,
            shape: shape,
            prev: from,
            k: 0,
            exclude: [for (final t in _tracks) t.id, ...before.map((t) => t.id)],
            limit: 16,
          )
          .timeout(const Duration(seconds: 12));
      coarse = [for (final c in choices) (track: c.track, fit: c.fitIn ?? 0, why: c.why)];
      if (coarse.isEmpty) throw StateError('nothing from the set builder');
    } catch (_) {
      // A house from before sets were built there: the library-wide partners.
      if (!pool.library && pool != SetSource.wholeLibrary) return const [];
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

  // ------------------------------------------------------------------ the order is the queue's
  /// Where an order the booth decides goes: into the queue, [order] straight after
  /// [after]'s row (the record on now), records not in it added — so what the crate
  /// shows is what plays, on every screen, and a record put back by a refresh of the
  /// queue is not one the booth had put elsewhere. Set by the app; without it (a test,
  /// a kept mix being done again) the booth keeps its order to itself.
  Future<void> Function(Track? after, List<Track> order)? onArrange;
  int _arranging = 0;
  List<Track>? _queueWhileArranging;

  Future<void> _arrange(Track? after, List<Track> order) async {
    final tell = onArrange;
    if (tell == null || order.isEmpty) return;
    _arranging++;
    try {
      await tell(after, order).timeout(const Duration(seconds: 12));
    } catch (_) {
      // The house said no, or not in time: the booth plays its own order, and the
      // queue shows the house's until somebody moves it.
    } finally {
      _arranging--;
      // What the queue said while it was being told: its last word, now that it has
      // heard the booth's.
      final q = _queueWhileArranging;
      if (_arranging == 0 && q != null) {
        _queueWhileArranging = null;
        follow(q);
      }
    }
  }

  /// The record a hand made next (put on the free deck, "play it next"): it stays
  /// next whatever the booth would have chosen, until it has been mixed into.
  int? _heldNext;

  /// The queue as it is now, while mixing: what comes after the record on now follows
  /// it — a record moved up, taken out or added in the crate is what the booth mixes
  /// into next, rather than whatever the queue was when the automix was switched on.
  /// The record playing stays where it is. A mix being done again keeps its own order.
  void follow(List<Track> queue) {
    if (!running || replaying) return;
    // Half-way through telling the queue an order of its own: the queue's answers
    // until then are about orders the booth has already moved on from.
    if (_arranging > 0) {
      _queueWhileArranging = queue;
      return;
    }
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
    // and the plan for it started over — for as long as the queue kept refreshing. And
    // a record a hand made next stays next, whatever order the queue comes back in.
    final keep = _heldNext ?? (pickBest ? before : null);
    if (keep != null) {
      final i = _tracks.indexWhere((t) => t.id == keep);
      if (i > _at + 1) {
        _tracks = [..._tracks]..insert(_at + 1, _tracks[i]);
        _tracks.removeAt(i + 1);
      } else if (i < 0 && keep == _heldNext) {
        // Not in the queue (it never got there, or was taken out of it) but on the
        // free deck, where a hand put it: what is on the deck is what plays next.
        final held = booth.other(booth.master).track;
        if (held?.id == keep) _tracks = [..._tracks]..insert(_at + 1, held!);
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
    final at = _nowAsked ? Duration.zero : goesAt;
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
    // At the next downbeat once the next record is ready — straight away where it is.
    _nowAsked = true;
    notifyListeners();
    await _tick();
  }

  /// [track] next: put straight after the record on now — the one that was next
  /// comes after it, not out — and laid out ready. A hand's choice: it stays next.
  Future<void> swapNext(Track track) async {
    if (!running) return;
    if (next?.id == track.id) return;
    _remember('${track.displayTitle} put next');
    _heldNext = track.id;
    _putNext(track);
    booth.note(BoothEventKind.next, 'Next: ${track.displayTitle} — by hand');
    unawaited(_arrange(current, [track]));
    _rerouteLater('${track.displayTitle} next, by hand');
    await _prepareNext();
  }

  /// [track] as the record after this one, in the booth's own list: a record already
  /// further down moves up rather than playing twice.
  void _putNext(Track track) {
    final rest = [..._tracks.sublist(math.min(_at + 1, _tracks.length))];
    final i = rest.indexWhere((t) => t.id == track.id);
    if (i >= 0) rest.removeAt(i);
    _tracks = [..._tracks.sublist(0, _at + 1), track, ...rest];
  }

  /// Not that one: the record after this one goes to the end of the queue — later, not
  /// never — and whatever comes after it is laid out instead.
  Future<void> dropNext() async {
    if (_at + 1 >= _tracks.length) return;
    final gone = _tracks[_at + 1];
    _remember('${gone.displayTitle} moved later');
    booth.note(BoothEventKind.skip, 'Not now: ${gone.displayTitle} — to the end of the queue');
    if (_heldNext == gone.id) _heldNext = null;
    final last = _tracks.last;
    _tracks = [..._tracks]..removeAt(_at + 1);
    // Behind everything else, where the queue has more than this one; the booth's own
    // list keeps it too, at the end, so the queue's next word agrees.
    if (!identical(last, gone)) {
      _tracks = [..._tracks, gone];
      unawaited(_arrange(last, [gone]));
    }
    final s = set;
    if (mode == SetMode.set && s != null) {
      set = s.copyWith(slots: [for (final x in s.slots) if (x.track.id != gone.id) x]).retimed();
      _rerouteLater('not ${gone.displayTitle}');
    }
    await _prepareNext();
  }

  // ------------------------------------------------------------------ undoing
  /// The last few things the booth did to the order by itself or on a hand's word —
  /// each the order of what was to come before it, and in a few words what it was.
  final _undo = <({
    String what,
    int? next,
    List<Track> upcoming,
    DateTime at,
    SetMode mode,
    double energy,
    Track? like,
    bool different,
    DjSet? set,
  })>[];

  /// The newest of those while it is fresh: what the UNDO chip offers.
  ({String what, DateTime at})? get change {
    if (_undo.isEmpty) return null;
    final u = _undo.last;
    if (DateTime.now().difference(u.at) > const Duration(seconds: 15)) return null;
    return (what: u.what, at: u.at);
  }

  void _remember(String what) {
    _undo.add((
      what: what,
      next: _heldNext,
      upcoming: upcoming,
      at: DateTime.now(),
      mode: mode,
      energy: energyOffset,
      like: likeThis,
      different: different,
      set: set,
    ));
    if (_undo.length > 5) _undo.removeAt(0);
  }

  /// What was to come before the last change, back as it was.
  Future<void> undoLast() async {
    if (_undo.isEmpty || !running || booth.busy) return;
    final u = _undo.removeLast();
    _heldNext = u.next;
    _rerouteSoon?.cancel();
    _rerouted++; // and a re-route under way lays nothing down after this
    mode = u.mode;
    energyOffset = u.energy;
    likeThis = u.like;
    different = u.different;
    set = u.set;
    final played = <int>{for (var i = 0; i <= _at && i < _tracks.length; i++) _tracks[i].id};
    final back = [for (final t in u.upcoming) if (!played.contains(t.id)) t];
    _tracks = [..._tracks.sublist(0, _at + 1), ...back];
    booth.note(BoothEventKind.plan, 'Undone: ${u.what}');
    unawaited(_arrange(current, back));
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
      // Four bars: a phrase's half, which is the shortest thing that is still counted
      // (real transitions cluster on 32-beat multiples — Kim et al. 2020); two was a
      // moment, and a moment that landed the new record's phrase a half-phrase off.
      return from.ends == 'cold'
          ? (kind: Transition.cut, bars: 1)
          : (kind: Transition.fade, bars: 4);
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
        // Eight, not twelve: twelve bars is three four-bar periods and lands the
        // incoming's phrase turn a half-phrase off the outgoing's.
        return inKey
            ? (kind: Transition.blend, bars: 16)
            : (kind: Transition.sweep, bars: 8);
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
  ///
  /// In order: where a hand said it leaves (TrackTiming.handCues); the structure's
  /// own places to leave (its outro, after its last chorus or drop, before its
  /// breakdown — the best of those with room for the move and sixteen bars of record
  /// before them); and only then the plain analysis's cue. Whatever is chosen is
  /// moved off the middle of a chorus or a drop where the sections are known, to its
  /// end — the room gets the payoff before the record leaves — or, with no room after,
  /// to its start.
  static Duration outPoint(TrackTiming from, {required Duration length}) {
    final cues = from.cues;
    final end = from.soundEnds ?? Duration(milliseconds: from.durationMs);
    // And never so late that the transition would run past the end of the sound.
    final latest = end - length;
    final bar = from.bar;
    final first = cues?.firstDownbeat ?? Duration.zero;
    // A hand's word stands, moved only onto the grid and off the end.
    final hand = from.handOut;
    if (hand != null) {
      var at = hand;
      if (latest > Duration.zero && at > latest) at = from.markerAtOrBefore(latest) ?? latest;
      return from.onGrid(at, every: 4);
    }
    // An outro the analysis put before the intro was over (it has: a short record
    // read as all outro) is no outro.
    final mixOut = cues == null || cues.mixOut <= cues.mixIn ? null : cues.mixOut;
    final s = from.structure;
    Duration? chosen;
    if (s != null && bar != null && s.outs.isNotEmpty) {
      final earliest = (cues?.mixIn ?? first) + bar * 16;
      int rank(CuePoint c) => c.why.contains('outro') ? 3 : c.why.startsWith('after') ? 2 : 1;
      CuePoint? pick;
      for (final c in s.outs) {
        if (latest > Duration.zero && c.at > latest) continue;
        if (c.at < earliest) continue;
        if (pick == null || rank(c) > rank(pick) || (rank(c) == rank(pick) && c.at > pick.at)) pick = c;
      }
      chosen = pick?.at;
    }
    var at = chosen ?? mixOut ?? (end - length);
    if (at < Duration.zero) at = Duration.zero;
    if (latest > Duration.zero && at > latest) at = latest;
    // Not in the middle of the payoff.
    if (s != null && bar != null) {
      final sec = s.sectionAt(at);
      if (sec != null && (sec.label == 'chorus' || sec.label == 'drop') && at > sec.start + bar) {
        if (latest <= Duration.zero || sec.end <= latest) {
          at = sec.end;
        } else if (sec.start >= first + bar * 16) {
          at = sec.start;
        }
      }
    }
    // A place the structure chose is already a section's edge: onto the grid only.
    // The plain cue is moved to the phrase boundary near it.
    final on = chosen != null ? from.onGrid(at, every: 4) : onPhrase(from, at);
    // Moved later by the phrase, past that: the marker before instead.
    if (latest > Duration.zero && on > latest) return from.markerAtOrBefore(latest) ?? on;
    return on;
  }

  /// Each bar's loudness, in dB, with where each bar starts: the structure's mix
  /// where there is one (absolute, dBFS), else the plain analysis's shape (0 to 255
  /// against the loudest bar, on a 0.7 power) turned back into dB and, with [lufs],
  /// put against the record's own loudness so two records can be compared. Null where
  /// the record has no bars.
  static ({List<int> barsMs, List<double> db})? barsDbOf(TrackTiming t, {double? lufs}) {
    final s = t.structure;
    if (s != null && s.barsMs.isNotEmpty && s.mixDb.isNotEmpty) return (barsMs: s.barsMs, db: s.mixDb);
    if (t.energy.isEmpty || t.downbeats.isEmpty) return null;
    final base = lufs ?? 0;
    return (
      barsMs: t.downbeats,
      db: [
        for (final v in t.energy)
          v <= 0 ? -100.0 : base + 20 * math.log(math.pow(v / 255, 1 / 0.7).toDouble()) / math.ln10,
      ],
    );
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
  ///
  /// By the structure's bars where there is one, else by the plain analysis's — which
  /// four records in five have and only that.
  static bool quietBars(TrackTiming t, Duration at, int bars) {
    final s = barsDbOf(t);
    if (s == null) return false;
    final heard = [for (final v in s.db) if (v > -90) v]..sort();
    if (heard.isEmpty) return false;
    final loud = heard[(heard.length * 0.9).floor().clamp(0, heard.length - 1)];
    var i = 0;
    while (i + 1 < s.barsMs.length && s.barsMs[i + 1] <= at.inMilliseconds) {
      i++;
    }
    final span = [for (final v in s.db.sublist(i, math.min(s.db.length, i + bars))) if (v > -90) v];
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
    // A hand's word stands: parked there, on the grid.
    final hand = to.handIn;
    if (hand != null) return to.onGrid(hand >= cues.firstDownbeat ? hand : cues.firstDownbeat);
    final drop = onTheDrop ? to.dropAfter(cues.firstDownbeat) : null;
    // The end of the intro as the structure read it off the record's sections, where
    // there is one; the plain analysis's cue otherwise.
    Duration? introEnd;
    for (final c in to.structure?.ins ?? const <CuePoint>[]) {
      if (c.why.contains('intro')) {
        introEnd = c.at;
        break;
      }
    }
    final target = drop ?? introEnd ?? cues.mixIn;
    var at = target - bar * bars;
    if (at < cues.firstDownbeat) at = cues.firstDownbeat;
    // Unless those bars are quiet — a long, thin intro, 8 dB under the record's loud
    // bars by the structure — when the record comes in later: half way through the
    // move, or already on. (A record parked in near-silence made a blend into a hole.)
    // Checked after the record's start has had its say: an intro shorter than the
    // move, parked at the first downbeat, is as often the quiet kind.
    if (drop == null && quietBars(to, at, bars)) {
      final half = target - bar * (bars ~/ 2);
      at = quietBars(to, half, math.max(1, bars ~/ 2)) ? target : half;
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
    _heldNext = null;
    _undo.clear();
    _forgetThePair();
    _waiting = false;
    _self++;
    running = true;
    booth.note(BoothEventKind.auto,
        'Auto DJ on · ${_tracks.length - _at} record${_tracks.length - _at == 1 ? '' : 's'}, ${style.name}');
    unawaited(learnTaste());
    final deck = booth.master;
    // The record it is already playing stays where it is: handing the queue to the
    // booth mid-song should be the booth taking over, not the song starting again.
    try {
      if (deck.track?.id != _tracks[_at].id) {
        await booth.load(deck, _tracks[_at], at: from, byHand: false);
      } else if (from != null && (deck.position - from).abs() > const Duration(seconds: 2)) {
        await deck.seek(from);
      }
      if (!deck.playing) await deck.play();
      await booth.setCrossfader(identical(deck, booth.b) ? 1 : 0);
    } finally {
      _self--;
    }
    for (final d in booth.decks) {
      _seenMoves[d.name] = d.handMoves;
      _seenPitches[d.name] = d.handPitches;
    }
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
    _forgetThePair();
    _waiting = false;
    _rerouteSoon?.cancel();
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
    _forgetThePair();
    _self++;
    try {
      await _replay(m, now, old);
    } finally {
      _self--;
    }
    for (final d in booth.decks) {
      _seenMoves[d.name] = d.handMoves;
    }
    await _tell('replay', m, const {});
    await _prepareNext();
  }

  Future<void> _replay(LastMix m, Deck now, Deck old) async {
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
    _readyFor = null;
    _plannedBars = null;
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
      _plannedOut = null;
      notifyListeners();
      return;
    }
    // The next record already playing on the free deck, and not by the automix: a
    // hand is mixing into it. Nothing is loaded over it or planned for it; the booth
    // takes it from there once the hand is done (see _observe).
    if (to.playing && to.track?.id == coming.id && !booth.busy) {
      working = null;
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
      goesAt = _plannedOut = Duration(milliseconds: was.outMs);
      if (to.track?.id != coming.id) {
        await _loadOn(to, coming, timing, Duration(milliseconds: was.inMs));
      }
      if (was.tempo != 1.0) await to.setTempo(was.tempo);
      if (!stale()) _readyFor = (from.track?.id, coming.id);
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
      await _loadOn(to, coming, timing, at);
    }
    if (stale()) return;
    _plannedOut = goesAt;
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
    // The moment kept ahead of the record: a plan for a place already behind it (the
    // next changed late, the house was slow) goes at the soonest marker there is room
    // and time for.
    _fitToNow();
    _readyFor = (from.track?.id, coming.id);
    _seenMoves[to.name] = to.handMoves;
    if (fill) unawaited(_fillAhead());
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
    _plannedOut = goesAt;
    _plannedBars = p.bars;
    _fitToNow();
    notifyListeners();
  }

  /// The gain that puts [to]'s first [bars] from [inAt] at the level of [from]'s
  /// [bars] from [outAt], by the bars' loudness as the house measured them (the
  /// record's own trim already taken off) — 1.0 where [to] is the quieter, which
  /// cannot be turned up, and null where either was never measured.
  double? levelMatch(Deck from, Deck to, Duration outAt, Duration inAt, int bars) {
    final ft = from.timing, tt = to.timing;
    if (ft == null || tt == null) return null;
    // Absolute where the structure gives dBFS; otherwise the plain shape against
    // each record's own loudness, which needs both to have been measured.
    final fl = from.track?.loudnessLufs, tl = to.track?.loudnessLufs;
    if ((ft.structure == null || tt.structure == null) && (fl == null || tl == null)) return null;
    final f = barsDbOf(ft, lufs: fl), t = barsDbOf(tt, lufs: tl);
    if (f == null || t == null) return null;
    double? over(({List<int> barsMs, List<double> db}) s, Duration at, double trim) {
      var i = 0;
      while (i + 1 < s.barsMs.length && s.barsMs[i + 1] <= at.inMilliseconds) {
        i++;
      }
      final slice = s.db.sublist(i, math.min(s.db.length, i + bars)).where((d) => d > -90);
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
    // A hand's cue is the record's from now on.
    final id = from.track?.id;
    if (id != null) unawaited(_keepCue(id, outMs: out.inMilliseconds));
  }

  /// Told to the house quietly: a house that cannot be reached loses a cue, not a mix.
  Future<void> _keepCue(int trackId, {int? outMs, int? inMs}) async {
    try {
      await booth.api.setCues(trackId, outMs: outMs, inMs: inMs).timeout(const Duration(seconds: 8));
      booth.timing.forget(trackId);
    } catch (_) {}
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
    final id = to.track?.id;
    if (id != null) unawaited(_keepCue(id, inMs: inAt.inMilliseconds));
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
    // A record a hand made next stays next: the order is chosen after it.
    final held = _heldNext != null && next?.id == _heldNext;
    final from = held ? next! : on;
    final rest = _tracks.sublist(_at + (held ? 2 : 1));
    if (rest.length < 2 && !held) return;
    for (final t in rest) {
      if (booth.timing.peek(t.id) == null) unawaited(booth.timing.of(t));
    }
    final ordered = rest.length < 2
        ? rest
        : SetPlanner.order(rest,
            from: from,
            timingOf: booth.timing.peek,
            arc: arc,
            locked: locked,
            before: [..._before(), if (held) on],
            fromPitch: held ? 1 : masterTargetPitch,
            moveOf: _moveScore,
            taste: taste,
            energyShift: energyOffset,
            like: likeThis == null ? null : booth.timing.peek(likeThis!.id),
            contrast: different);
    if (!held && ordered.isNotEmpty && ordered.first.id != rest.first.id) {
      final why = fitOf(ordered.first).why;
      booth.note(BoothEventKind.next,
          'Picked ${ordered.first.displayTitle}${why.isEmpty ? '' : ': $why'}');
    }
    var same = ordered.length == rest.length;
    for (var i = 0; same && i < rest.length; i++) {
      same = ordered[i].id == rest[i].id;
    }
    if (same) return;
    _tracks = [..._tracks.sublist(0, _at + (held ? 2 : 1)), ...ordered];
    // The queue told, so the crate reads the order the booth will play.
    unawaited(_arrange(from, ordered));
  }

  bool _going = false;

  // ------------------------------------------------------------------ following the booth
  /// The pair the last preparation finished for — the record on now and the record
  /// next — and so the pair a transition may go between. Null while one is being
  /// worked out. Written last, so a pair with this set is loaded, parked and matched.
  (int?, int)? _readyFor;

  /// Whether the free deck holds the next record, laid out and planned for.
  bool get isReady {
    final on = current, nxt = next;
    if (on == null || nxt == null) return false;
    return _readyFor == (on.id, nxt.id) && booth.other(booth.master).track?.id == nxt.id;
  }

  /// Where the planner wanted the old record to go out, and over how many bars, before
  /// [_fitToNow] kept it ahead of the playhead: with the record moved back to before
  /// it, the planner's own place and length come back.
  Duration? _plannedOut;
  int? _plannedBars;

  /// The automix's own loads, deck by deck, while they run: a hand's load on the same
  /// deck waits for one to finish rather than racing it for the engine.
  final _loadingOn = <String, Future<void>>{};

  Future<void> _loadOn(Deck deck, Track track, TrackTiming? timing, Duration? at) {
    final f = deck.load(track, timing: timing, at: at);
    _loadingOn[deck.name] = f;
    return f.whenComplete(() {
      if (identical(_loadingOn[deck.name], f)) _loadingOn.remove(deck.name);
    });
  }

  /// What a hand did to each deck that the automix has already taken in: moves of the
  /// record (Deck.handMoves) and of its pitch (Deck.handPitches).
  final _seenMoves = <String, int>{};
  final _seenPitches = <String, int>{};

  /// Doing something to the decks itself that is not a transition (a mix done again):
  /// what the decks say meanwhile is the automix's own doing, not a hand's.
  int _self = 0;

  /// A hand paused the record in the room.
  bool _waiting = false;

  /// "Go now" asked (MIX NOW, SKIP): goes at the next downbeat once the next record is
  /// ready — straight away where it is.
  bool _nowAsked = false;

  /// SKIP asked: the move is a short one, whatever was planned.
  bool _quick = false;

  /// The booth is holding the floor: the record in the room going round its last bars
  /// while the next one is not ready — on this deck, since this moment.
  Deck? _holdDeck;
  DateTime? _holdSince;
  bool get _holding => _holdDeck != null;

  /// A hand took the hold's loop off: this pair is not held again.
  bool _holdRefused = false;

  /// "Waiting for …" said once per pair, not on every push.
  (int?, int)? _saidWaiting;

  /// What the automix is doing, in one word.
  AutoState get state {
    if (!running) return AutoState.off;
    if (booth.busy) return AutoState.mixing;
    if (_waiting) return AutoState.waiting;
    if (_holding) return AutoState.holding;
    final to = booth.other(booth.master);
    if (to.playing && booth.master.playing) return AutoState.mixing;
    if (next == null) return AutoState.last;
    if (!isReady) return AutoState.preparing;
    return AutoState.ready;
  }

  /// The booth is about to put a record on [deck] for a hand. Whatever the automix was
  /// preparing stops at its next step; a load of its own already under way on that
  /// deck is let finish first — two loads on one deck at once end with whichever the
  /// engine happened to answer last.
  Future<void> beforeHandLoad(Deck deck) async {
    if (!running) return;
    _asked++;
    final busy = _loadingOn[deck.name];
    if (busy != null) {
      try {
        await busy.timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
  }

  /// A hand has put [track] on [deck] while the automix runs. On the free deck it is
  /// what plays next — the one that was next comes after it, not out; on the deck in
  /// the room it is what plays now, and the way out is planned again from it.
  void handLoaded(Deck deck, Track track) {
    if (!running || replaying) return;
    _seenMoves[deck.name] = deck.handMoves;
    _seenPitches[deck.name] = deck.handPitches;
    if (identical(deck, booth.master)) {
      if (current?.id == track.id) {
        // The same record again: its way out planned again from where it now is.
        unawaited(_prepareNext());
        return;
      }
      _adoptCurrent(track, why: 'put on deck ${deck.name} by hand');
    } else {
      _adoptNext(track, why: 'put on deck ${deck.name} by hand');
    }
  }

  void _adoptNext(Track track, {required String why}) {
    if (next?.id == track.id) {
      _heldNext = track.id;
      unawaited(_prepareNext());
      return;
    }
    _remember('${track.displayTitle} $why');
    _heldNext = track.id;
    _putNext(track);
    booth.note(BoothEventKind.next, 'Next: ${track.displayTitle} — $why');
    unawaited(_arrange(current, [track]));
    unawaited(_prepareNext());
    _rerouteLater('${track.displayTitle} next, by hand');
  }

  /// [track] is what plays now: the record that was on counts as played, the plan for
  /// getting out of it is gone, and what comes next is worked out from this one.
  void _adoptCurrent(Track track, {required String why}) {
    final was = current;
    _remember('${track.displayTitle} $why');
    if (was == null) {
      _tracks = [track, ..._tracks.where((t) => t.id != track.id)];
      _at = 0;
    } else {
      _putNext(track);
      _at++;
    }
    if (_heldNext == track.id) _heldNext = null;
    _forgetThePair();
    _endGlide();
    final m = booth.master;
    _seenMoves[m.name] = m.handMoves;
    _seenPitches[m.name] = m.handPitches;
    booth.note(BoothEventKind.auto, 'Now: ${track.displayTitle} — $why; the Auto DJ carries on from it');
    if (was != null && (set?.slots.any((x) => x.track.id == was.id) ?? false)) _setPlayed.add(was.id);
    notifyListeners();
    unawaited(_arrange(was, [track]));
    unawaited(_prepareNext());
    _rerouteLater('${track.displayTitle} on, by hand');
  }

  /// A hand mixed into the record that was next: taken as a mix made, and the booth
  /// carries on from there.
  void _advanceByHand() {
    final from = current, to = next;
    if (to == null) return;
    if (from != null) {
      final m = booth.taken.isNotEmpty ? booth.taken.last : null;
      final same = m != null && m.from == from.id && m.to == to.id;
      final made = LastMix(
        from: from,
        to: to,
        plan: same ? MixPlan(m.kind, m.bars, why: 'by hand') : MixPlan(plan?.kind ?? Transition.blend, plan?.bars ?? 0, why: 'by hand'),
        outAt: same ? Duration(milliseconds: m.outMs) : Duration.zero,
        inAt: same ? Duration(milliseconds: m.inMs) : Duration.zero,
        steered: true,
        at: DateTime.now(),
      );
      lastMix = made;
      unawaited(_tell('mix', made, {'byHand': true}));
      steers.remove((from.id, to.id));
      _previews.remove((from.id, to.id));
    }
    _at++;
    if (from != null && (set?.slots.any((x) => x.track.id == from.id) ?? false)) _setPlayed.add(from.id);
    _heldNext = null;
    _forgetThePair();
    booth.note(BoothEventKind.auto, 'Mixed into ${to.displayTitle} by hand — the Auto DJ carries on');
    _startGlide();
    notifyListeners();
    unawaited(_prepareNext());
  }

  /// The plan for the pair that was coming, let go of: what is on now is another.
  void _forgetThePair() {
    _endHold();
    plan = null;
    planned = null;
    options = const [];
    goesAt = _plannedOut = null;
    _plannedBars = null;
    _readyFor = null;
    _nowAsked = false;
    _quick = false;
    _holdRefused = false;
  }

  /// What the hands did since the last look, taken in: a record mixed into or put on
  /// by hand, the record in the room moved or pitched, the record coming cued.
  void _observe() {
    if (!running || replaying || _going || booth.busy || _self > 0) return;
    final m = booth.master, o = booth.other(m);
    final on = m.track;
    if (on != null && on.id != current?.id) {
      if (on.id == next?.id) {
        _advanceByHand();
      } else {
        _adoptCurrent(on, why: 'mixed in by hand');
      }
      return;
    }
    // The record in the room moved by hand: the way out kept ahead of it.
    final moved = m.handMoves;
    if (_seenMoves[m.name] != moved) {
      final first = !_seenMoves.containsKey(m.name);
      _seenMoves[m.name] = moved;
      if (!first) {
        if (_holding) _holdRefused = true;
        _endHold();
        _fitToNow(said: 'moved by hand');
        notifyListeners();
      }
    }
    // Its pitch moved by hand: a glide stops fighting the hand, and the record coming
    // is matched to the new tempo and judged again (it can be out of reach now).
    final pitched = m.handPitches;
    if (_seenPitches[m.name] != pitched) {
      final first = !_seenPitches.containsKey(m.name);
      _seenPitches[m.name] = pitched;
      if (!first) {
        _endGlide();
        unawaited(_prepareNext());
      }
    }
    // The record coming cued by hand: it comes in from there.
    final cued = o.handMoves;
    if (_seenMoves[o.name] != cued) {
      final first = !_seenMoves.containsKey(o.name);
      _seenMoves[o.name] = cued;
      final p = planned;
      if (!first && p != null && !o.playing && o.track?.id == next?.id && canSteer) {
        unawaited(steer(p.copyWith(inAt: o.position, outAt: goesAt)));
      }
    }
  }

  /// Time to get ready to go, in the record's own time: the arming and a breath for
  /// the transition's own matching — never less than a bar.
  Duration _budget(Deck from) {
    final wall = armAhead + const Duration(milliseconds: 500);
    var rec = Duration(microseconds: (wall.inMicroseconds * from.tempo).round());
    final bar = from.timing?.bar;
    if (bar != null && rec < bar) rec = bar;
    return rec;
  }

  /// The move's length changed to [bars], the record coming parked again for it where
  /// the plan did not place it itself.
  void _setBars(int bars) {
    final p = plan;
    if (p == null || p.bars == bars) return;
    plan = (kind: p.kind, bars: bars);
    final was = planned;
    if (was != null) planned = was.copyWith(bars: bars);
    final to = booth.other(booth.master);
    final tt = to.timing;
    if (tt != null && !to.playing && to.track?.id == next?.id && was?.inAt == null) {
      final inAt = comesInAt =
          inPoint(tt, bars: bars, onTheDrop: style == MixStyle.bold && tt.drops.isNotEmpty);
      if ((to.position - inAt).abs() > const Duration(milliseconds: 20)) unawaited(to.seek(inAt));
    }
  }

  /// Keep the moment the old record goes out ahead of it.
  ///
  /// The planner's place where there is still time to get there; otherwise the
  /// soonest four-bar marker that leaves time to get ready, with the move shortened,
  /// where it has to be, to what is left of the record. Never a plan for a moment
  /// already behind the playhead — which is a mix that starts the instant it is
  /// noticed, wherever the record has got to: what a record moved by hand, or a next
  /// changed a few seconds before the mix, used to get.
  void _fitToNow({String? said}) {
    final from = booth.master;
    final t = from.timing;
    final want = _plannedOut;
    if (!running || want == null || _nowAsked) return;
    final p = plan;
    if (p != null) _plannedBars ??= p.bars;
    if (t == null) {
      goesAt = want;
      return;
    }
    final soon = from.position + _budget(from);
    if (want >= soon) {
      goesAt = want;
      final bars = _plannedBars;
      if (bars != null) _setBars(bars);
      return;
    }
    final at = t.markerAtOrAfter(soon) ?? soon;
    final end = t.soundEnds ?? Duration(milliseconds: t.durationMs);
    final bar = t.bar;
    var bars = _plannedBars ?? p?.bars ?? 8;
    if (bar != null) {
      while (bars > 1 && at + bar * bars > end) {
        bars = bars ~/ 2;
      }
    }
    goesAt = at;
    _setBars(bars);
    booth.note(BoothEventKind.plan,
        'Out of ${from.track?.displayTitle ?? 'it'} at ${clock(at)} over $bars bars'
        ' — ${said ?? 'the planned place had gone by'}');
  }

  /// The next record is not ready at the moment it was due: later, if the record in
  /// the room has room for it; if it has not, its last bars go round until it is.
  void _notReady(Deck from, Track coming, {required bool ended}) {
    // Silence can only wait; a loop already holds.
    if (ended || _holding) return;
    final t = from.timing;
    final bar = t?.bar;
    final plannedGo = goesAt;
    if (t == null || bar == null || plannedGo == null) return;
    final now = from.position;
    // Only "go now" brought it here, and the planned moment is still ahead: that
    // moment stands.
    if (plannedGo > now + _budget(from)) return;
    final end = t.soundEnds ?? Duration(milliseconds: t.durationMs);
    final from2 = plannedGo + bar > now + _budget(from) ? plannedGo + bar : now + _budget(from);
    final later = t.markerAtOrAfter(from2);
    var bars = plan?.bars ?? 8;
    if (later != null) {
      while (bars > 4 && later + bar * bars > end) {
        bars = bars ~/ 2;
      }
      if (later + bar * bars <= end) {
        goesAt = later;
        _setBars(bars);
        final pair = (current?.id, coming.id);
        if (_saidWaiting != pair) {
          _saidWaiting = pair;
          booth.note(BoothEventKind.plan,
              'Waiting for ${coming.displayTitle} to be ready — out at ${clock(later)} instead');
        }
        notifyListeners();
        return;
      }
    }
    if (!_holdRefused) _startHold(from, coming);
  }

  /// Hold the floor: four bars of the record in the room go round until the next one
  /// is ready — what a DJ whose next record has not arrived does, rather than let the
  /// room go quiet.
  void _startHold(Deck from, Track coming) {
    if (_holding || from.timing?.bar == null) return;
    _holdDeck = from;
    _holdSince = DateTime.now();
    from.loop(16);
    booth.note(BoothEventKind.held,
        'Holding the floor: four bars of ${from.track?.displayTitle ?? 'it'} go round until ${coming.displayTitle} is ready',
        deck: from);
    notifyListeners();
  }

  void _endHold() {
    final d = _holdDeck;
    if (d == null) return;
    _holdDeck = null;
    _holdSince = null;
    if (d.loopStart != null) d.unloop();
    notifyListeners();
  }

  void _setWaiting(bool on) {
    if (_waiting == on) return;
    _waiting = on;
    if (on) {
      booth.note(BoothEventKind.auto, 'Paused — the Auto DJ waits for the record to play again');
    }
    notifyListeners();
  }

  /// Skip: into the next record at the next bar, over a few bars — whatever the plan
  /// said and wherever this one has got to. What a DJ does with a record the room has
  /// had enough of.
  Future<void> skip() async {
    if (!running || next == null || booth.busy) return;
    _quick = true;
    _nowAsked = true;
    booth.note(BoothEventKind.mix, 'Skip: into ${next!.displayTitle} at the next bar');
    notifyListeners();
    await _tick();
  }

  /// The short move a skip makes: in step, a blend of a few bars (an echo out for the
  /// bold style, where the desk has one); out of step, a quick fade.
  MixPlan _quickMove(Deck from, Deck to) {
    final ft = from.timing, tt = to.timing;
    final inStep = ft != null &&
        tt != null &&
        ft.hasBeats &&
        tt.hasBeats &&
        ft.gridBpm != null &&
        tt.gridBpm != null &&
        Booth.syncRatio(tt.gridBpm!, ft.gridBpm! * from.pitch, reach: Booth.bridgeReach) != null;
    if (!inStep) return const MixPlan(Transition.fade, 2, why: 'skipped: a quick fade');
    if (style == MixStyle.bold && booth.mixer.canShift) {
      return const MixPlan(Transition.echoOut, 2, why: 'skipped: echoed out');
    }
    final bars = style == MixStyle.easy ? 8 : 4;
    return MixPlan(Transition.blend, bars, why: 'skipped: $bars bars');
  }

  /// More of the record on now — [phrases] four-bar phrases (fewer with it negative):
  /// the room wants more of it, or less. For this time only; nudgeOut is the one that
  /// keeps a hand's word as the record's own cue.
  void extend([int phrases = 2]) {
    final from = booth.master;
    final t = from.timing;
    final bar = t?.bar;
    final at = goesAt ?? _plannedOut;
    if (!running || t == null || bar == null || at == null || booth.busy) return;
    final end = t.soundEnds ?? Duration(milliseconds: t.durationMs);
    final bars = plan?.bars ?? 8;
    var out = at + bar * (4 * phrases);
    final latest = end - bar * bars;
    if (out > latest) out = t.markerAtOrBefore(latest) ?? latest;
    final soon = from.position + _budget(from);
    if (out < soon) out = t.markerAtOrAfter(soon) ?? soon;
    final title = from.track?.displayTitle ?? 'it';
    if ((out - at).abs() < const Duration(milliseconds: 50)) {
      booth.note(BoothEventKind.plan,
          phrases > 0 ? 'No more of $title to give: it is going out as late as it can' : 'It cannot go any sooner');
      return;
    }
    _plannedOut = goesAt = out;
    _nowAsked = false;
    booth.note(BoothEventKind.plan, '${out > at ? 'Longer' : 'Sooner'}: out of $title at ${clock(out)}');
    notifyListeners();
  }

  Future<void> _tick() async {
    // Nothing while a mix is waiting for its beat or running — the automix's own, or
    // one somebody started by hand.
    if (!running || _going || booth.busy) return;
    _observe();
    if (!running) return;
    final from = booth.master;
    final to = booth.other(from);
    final coming = next;
    // The record ran out — or never started. Either way the next one is what the
    // queue is for: the booth does not sit in silence waiting for a clock that has
    // stopped.
    final ended = !from.playing &&
        from.duration != null &&
        from.position >= from.duration! - const Duration(milliseconds: 400);
    if (!from.playing) {
      // The hands took the other record into the room without a transition: started
      // it, brought the fader across, stopped this one. That one leads now.
      final towards = identical(to, booth.b) ? booth.crossfader : 1 - booth.crossfader;
      if (to.playing && to.loaded && towards >= 0.5) {
        booth.master = to;
        _observe();
        return;
      }
      if (!ended) {
        _setWaiting(true);
        return;
      }
    }
    if (_waiting) {
      _setWaiting(false);
      _fitToNow(said: 'played again');
    }
    if (coming == null) {
      // The last record — unless the booth is to keep going, from the library.
      if (fill && from.playing) {
        unawaited(_fillAhead());
        return;
      }
      // Let it end, then stop.
      if (!from.playing) stop();
      return;
    }
    // A hand mixing into the next record itself: the automix leaves it to the hand.
    if (to.playing && from.playing) return;
    // A hand took the hold's loop off: the record plays on, and is not held again.
    final held = _holdDeck;
    if (held != null && held.loopStart == null) {
      _holdDeck = null;
      _holdRefused = true;
    }
    final go = _nowAsked ? Duration.zero : goesAt;
    if (go == null) return;
    // Armed a moment early, so the incoming can be started on the exact beat rather
    // than on the first tick after it — which was the next phrase, eight seconds and
    // more too late, with the whole mix landing that much after where it was aimed.
    final left = Duration(
        microseconds: ((go - from.position).inMicroseconds / from.tempo).round());
    if (left > armAhead && !ended && !_holding) return;
    // Never into anything but the record that is next. Its preparation still under
    // way (the free deck may still hold the one before it): later, or held.
    final holds = to.loaded && to.track?.id == coming.id;
    if (!holds || (!isReady && _preparing != null && !ended)) {
      if (_holding && _holdSince != null &&
          DateTime.now().difference(_holdSince!) > const Duration(seconds: 90)) {
        // Held for a minute and a half and still not there: the one after it instead.
        booth.note(BoothEventKind.trouble, '${coming.displayTitle} did not arrive — the one after it instead');
        _holdSince = DateTime.now();
        if (after != null) {
          unawaited(dropNext());
        } else {
          _endHold();
          _holdRefused = true;
        }
        return;
      }
      _notReady(from, coming, ended: ended);
      return;
    }
    if (_holding) {
      // Ready while the floor was held: the loop let go, and the move starts where it
      // would have come round — over what is left of the record after it.
      final end = _holdDeck?.loopEnd;
      _endHold();
      final t = from.timing, bar = from.timing?.bar;
      if (end != null && !_nowAsked && t != null && bar != null) {
        _plannedOut = goesAt = end;
        final sound = t.soundEnds ?? Duration(milliseconds: t.durationMs);
        var bars = plan?.bars ?? 8;
        while (bars > 1 && end + bar * bars > sound) {
          bars = bars ~/ 2;
        }
        _plannedBars = bars;
        _setBars(bars);
        booth.note(BoothEventKind.plan,
            '${coming.displayTitle} is ready: out of the loop at ${clock(end)} over $bars bars');
      }
      notifyListeners();
      return;
    }
    _going = true;
    try {
      var chosen = plan ??
          choose(from.timing, to.timing,
              style: style,
              parts: inParts(from.track, to.track),
              fromPitch: from.pitch);
      var shift = planned?.shift ?? 0;
      if (_quick) {
        final q = _quickMove(from, to);
        chosen = (kind: q.kind, bars: q.bars);
        shift = 0;
        planned = q;
        final tt = to.timing;
        if (tt != null && !to.playing) {
          final inAt = comesInAt = inPoint(tt, bars: q.bars);
          if ((to.position - inAt).abs() > const Duration(milliseconds: 20)) await to.seek(inAt);
        }
      }
      final was = booth.master;
      // A preparation still under way was for the decks as they were: stopped here,
      // before it can load the next record over the one going live. A glide still on
      // stops too: the record it was bending is going out.
      _asked++;
      _endGlide();
      await booth.go(chosen.kind,
          bars: chosen.bars,
          startAt: ended ? null : startFor(from.timing, go, from.position),
          shift: shift);
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
          steered: steered || _quick,
          at: DateTime.now(),
        );
        lastMix = made;
        unawaited(_tell('mix', made, {'byHand': ended, if (_quick) 'skip': true}));
      }
      _at++;
      final ft = from.track;
      if (ft != null && (set?.slots.any((x) => x.track.id == ft.id) ?? false)) _setPlayed.add(ft.id);
      steers.remove(done);
      _previews.remove(done);
      _heldNext = null;
      _saidWaiting = null;
      // The record now leading was bent to the last one's tempo, and turned down to
      // its level: eased back to its own over the next bars.
      _startGlide();
      // The plan just carried out is spent: left standing, its moment — long past on
      // the record now leading — would send the booth straight back the other way.
      _forgetThePair();
      _seenMoves[booth.master.name] = booth.master.handMoves;
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
    _rerouteSoon?.cancel();
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
