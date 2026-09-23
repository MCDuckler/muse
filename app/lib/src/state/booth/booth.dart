import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../timing.dart';
import 'automix.dart';
import 'deck.dart';
import 'mixer.dart';

/// How one record gives way to the next.
enum Transition {
  /// Over some bars: the incoming enters with its bass killed, the bass swaps half
  /// way, the outgoing's top rolls off at the end. The classic.
  blend,

  /// On the one: the incoming takes over on a downbeat, no overlap. For a cold
  /// ending, or two records in the same key and tempo.
  cut,

  /// Levels only, crossed over the bars. For a record with no pulse, or a tempo gap
  /// too wide to sync.
  fade,

  /// The outgoing climbs out through a high-pass while the incoming comes up under
  /// it: everything but the top of the old record is gone by the end. What to reach
  /// for when the two do not sit together harmonically — a filtered record has
  /// hardly any key left to clash with.
  sweep,

  /// The outgoing is caught in a loop that halves as it goes — two bars, one, half,
  /// a quarter — and lets go as the new one lands. The loudest way out there is.
  roll,

  /// The outgoing brakes to a stop like a hand on the platter, and the new record is
  /// already running underneath. For a hard change of gear.
  brake,
}

/// What a transition does to one deck at one moment.
class DeckStep {
  const DeckStep({this.eq, this.filter, this.loopBars, this.brake = false});

  /// The three bands, where this step sets them.
  final EqSet? eq;

  /// The filter knob, where this step sets it: interpolated to, like the fader, so a
  /// sweep is a sweep rather than four jumps.
  final double? filter;

  /// A loop of so many bars, zero to let one go, or -1 to halve the one running.
  final int? loopBars;

  /// The record brakes to a stop here.
  final bool brake;
}

/// One instruction in a transition, at a point in it (0 at the start, 1 at the end).
class MixStep {
  const MixStep(this.at, {this.crossfader, this.decks = const {}});

  final double at;

  /// Where the crossfader is by this point; the fader moves evenly from the previous
  /// step's place to this one.
  final double? crossfader;

  /// What each deck is doing by then, by deck name.
  final Map<String, DeckStep> decks;
}

/// One thing the booth did between two records, as it is kept and done again.
class MixMove {
  const MixMove({
    required this.from,
    required this.to,
    required this.kind,
    required this.bars,
    required this.outMs,
    required this.inMs,
    this.tempo = 1.0,
  });

  final int from;
  final int to;
  final Transition kind;
  final int bars;

  /// Where in the outgoing record the move began, and where the incoming was parked.
  final int outMs;
  final int inMs;

  /// The rate the incoming was run at.
  final double tempo;

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
        'kind': kind.name,
        'bars': bars,
        'out_ms': outMs,
        'in_ms': inMs,
        'tempo': tempo,
      };

  factory MixMove.fromJson(Map<String, dynamic> j) => MixMove(
        from: (j['from'] as num).toInt(),
        to: (j['to'] as num).toInt(),
        kind: Transition.values.firstWhere((k) => k.name == j['kind'],
            orElse: () => Transition.fade),
        bars: (j['bars'] as num?)?.toInt() ?? 8,
        outMs: (j['out_ms'] as num?)?.toInt() ?? 0,
        inMs: (j['in_ms'] as num?)?.toInt() ?? 0,
        tempo: (j['tempo'] as num?)?.toDouble() ?? 1.0,
      );

  /// The moves a kept playlist carries, or none.
  static List<MixMove> allIn(Map<String, dynamic>? mix) => [
        for (final t in (mix?['transitions'] ?? const []) as List)
          if (t is Map) MixMove.fromJson(t.cast<String, dynamic>()),
      ];
}

/// Two records on the deck, and the mixer between them.
///
/// The booth is the player's other life: the same records, played by hand into one
/// another. It owns two [Deck]s and a [Mixer], knows which of the two is the *master*
/// — the one whose beats everything else lines up to — and does the three things a
/// DJ does with the mixer that are hard to do by hand on a phone: sync one record's
/// tempo to the other's, start a record on the master's next downbeat, and perform a
/// whole transition over so many bars.
class Booth extends ChangeNotifier {
  Booth(
    this.api, {
    String? Function(int trackId)? offlinePath,
    Mixer? mixer,
    TimingStore? timing,
    Deck? a,
    Deck? b,
  })  : mixer = mixer ?? Mixer.forThisDevice(),
        timing = timing ?? TimingStore(api) {
    // Each deck says which it is at the moment its player is handed a record, which
    // is when a browser makes the element that plays it. Said here, in the
    // constructor, it was said twice before either existed — so the first element
    // made was claimed as the second deck and the real one was never claimed at all.
    this.a = a ??
        Deck('A',
            api: api,
            offlinePath: offlinePath,
            claiming: () => this.mixer.expecting('A'));
    this.b = b ??
        Deck('B',
            api: api,
            offlinePath: offlinePath,
            claiming: () => this.mixer.expecting('B'));
    this.a.addListener(notifyListeners);
    this.b.addListener(notifyListeners);
  }

  final ApiClient api;
  final Mixer mixer;
  final TimingStore timing;
  late final Deck a;
  late final Deck b;

  /// The booth mixing on its own. See AutoMix.
  late final AutoMix auto = AutoMix(this)..addListener(notifyListeners);

  List<Deck> get decks => [a, b];

  /// Whether the booth is the thing making a sound right now: a deck playing, or
  /// the booth mixing. While it is, the bar at the bottom of the app is the booth's.
  bool get live => a.playing || b.playing || auto.running;

  /// Everything off: both decks parked, the mix stopped.
  Future<void> stopAll() async {
    auto.stop();
    stopTransition();
    await a.pause();
    await b.pause();
  }
  Deck other(Deck d) => identical(d, a) ? b : a;

  /// The record everything lines up to. Whichever is playing; A when neither is.
  Deck? _master;
  Deck get master => _master ?? (b.playing && !a.playing ? b : a);
  set master(Deck d) {
    _master = d;
    notifyListeners();
  }

  /// 0 is all A, 1 is all B.
  double crossfader = 0.0;

  /// The tempo gap sync will close on its own. Wider than this and the record would
  /// sound wrong; the booth says so instead.
  static const maxSync = 0.08;

  bool _prepared = false;
  Future<void> init() async {
    if (_prepared) return;
    _prepared = true;
    // Speaking to each player once makes its element / session, in order.
    await a.player.setVolume(1);
    await b.player.setVolume(1);
    await mixer.prepare(decks);
    await setCrossfader(crossfader);
  }

  // ------------------------------------------------------------------ the shapes
  /// Each record's shape in three bands, once fetched, by track. Shared by the two
  /// decks and by whatever else draws a record's strip.
  final bands = <int, ({List<int> low, List<int> mid, List<int> high})>{};
  final _fetchingBands = <int>{};

  Future<void> fetchBands(Track track) async {
    if (bands.containsKey(track.id) || !_fetchingBands.add(track.id)) return;
    try {
      final got = await api.peakBands(track.id);
      if (got != null) bands[track.id] = got;
    } catch (_) {
      // No shape: the grid is still drawn, on a quiet line.
    } finally {
      _fetchingBands.remove(track.id);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ loading
  /// What went wrong on either deck, if anything did.
  String? get trouble => a.trouble ?? b.trouble;

  Future<void> load(Deck deck, Track track, {Duration? at}) async {
    final t = await timing.of(track);
    try {
      await deck.load(track, timing: t, at: at);
    } catch (_) {
      // The deck has written down what happened and said so; the room reads it off
      // the deck rather than the booth throwing out of whatever asked for the load.
    }
    // A different record is a different loudness: the levels are worked out again.
    await _levels();
    notifyListeners();
  }

  // ------------------------------------------------------------------ the fader
  /// Equal power: at the middle both are at 0.71, and the sum of their energy is the
  /// same at every point of the travel. A straight line dips in the middle.
  static ({double a, double b}) levelsFor(double x) {
    final k = x.clamp(0.0, 1.0) * math.pi / 2;
    return (a: math.cos(k), b: math.sin(k));
  }

  Future<void> setCrossfader(double x, {Duration over = Duration.zero}) async {
    crossfader = x.clamp(0.0, 1.0);
    notifyListeners();
    await _levels(over: over);
  }

  /// What each channel is actually sending: its share of the crossfader, at its
  /// gain, with the record's own loudness taken off.
  ({double a, double b}) get levels {
    final l = levelsFor(crossfader);
    return (a: l.a * gainOf(a) * trimFor(a), b: l.b * gainOf(b) * trimFor(b));
  }

  /// How much a record is turned down so that it sits at the same level as the other
  /// one: the server measured each song's loudness, and two records a few decibels
  /// apart make a blend where one of them ducks the other. Only ever down — turning
  /// a quiet record up is turning its clipping up with it — which is the same call
  /// the player makes when it plays one song after another.
  static double trimOf(Track? track) {
    final db = track?.gainDb;
    if (db == null || db >= 0) return 1.0;
    return math.pow(10, db / 20).toDouble().clamp(0.05, 1.0);
  }

  double trimFor(Deck deck) => trimOf(deck.track);

  Future<void> _levels({Duration over = Duration.zero}) async {
    final l = levels;
    await mixer.setLevels({a: l.a, b: l.b}, over: over);
  }

  /// Each channel's three bands, and its own fader. The crossfader says how the two
  /// share the output; the gain says how loud this one is in its own right, which is
  /// what a DJ rides while a blend is happening.
  final Map<Deck, EqSet> eq = {};
  final Map<Deck, double> gain = {};

  EqSet eqOf(Deck d) => eq[d] ?? EqSet.flat;
  double gainOf(Deck d) => gain[d] ?? 1.0;

  Future<void> setEq(Deck d, EqSet want) async {
    eq[d] = want;
    notifyListeners();
    await mixer.setEq(d, want);
  }

  /// One band all the way down, or back to flat.
  Future<void> kill(Deck d, int band, bool on) => setEq(d, eqOf(d).killing(band, on));

  Future<void> setGain(Deck d, double value) async {
    gain[d] = value.clamp(0.0, 1.0);
    notifyListeners();
    await _levels();
  }

  final Map<Deck, double> filters = {};

  Future<void> setFilter(Deck d, double value) async {
    filters[d] = value.clamp(-1.0, 1.0);
    notifyListeners();
    await mixer.setFilter(d, filters[d]!);
  }

  // ------------------------------------------------------------------ sync
  /// The rate that makes a record at [from] beats a minute run at [to], or null when
  /// the gap is wider than [maxSync] — the record would be a different record.
  static double? syncRatio(double from, double to) {
    if (from <= 0 || to <= 0) return null;
    // Half or double time is the same tempo: 140 syncs to 70 as 70.
    var target = to;
    while (target / from > 1.5) {
      target /= 2;
    }
    while (target / from < 0.66) {
      target *= 2;
    }
    final ratio = target / from;
    return (ratio - 1).abs() > maxSync ? null : ratio;
  }

  /// Bring [deck]'s tempo to the master's. Says whether it could.
  Future<bool> sync(Deck deck) async {
    final m = other(deck);
    final from = deck.timing?.bpm, to = m.bpm;
    if (from == null || to == null) return false;
    final ratio = syncRatio(from, to);
    if (ratio == null) return false;
    await deck.setTempo(ratio);
    return true;
  }

  /// Nudge [deck] so its beat falls with the master's. Only the phase, not the tempo.
  Future<void> align(Deck deck) async {
    final m = other(deck);
    final now = DateTime.now();
    final mine = deck.beatAt(now), theirs = m.beatAt(now);
    final beat = deck.beat;
    if (mine == null || theirs == null || beat == null) return;
    // How far ahead of the master's phase this deck is, as a fraction of a beat,
    // taken the short way round.
    var ahead = mine.phase - theirs.phase;
    if (ahead > 0.5) ahead -= 1;
    if (ahead < -0.5) ahead += 1;
    await deck.nudge(Duration(microseconds: (-ahead * beat.inMicroseconds).round()));
  }

  // ------------------------------------------------------------------ starting on the beat
  /// Start [deck], from where it is parked, on the master's next downbeat (with
  /// [every] 4) — or its next phrase (16). Straight away when the master has no grid.
  Future<void> startOnBeat(Deck deck, {int every = 4}) async {
    final m = other(deck);
    final wait = m.untilNextBeat(DateTime.now(), every: every);
    if (wait != null && wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
    await deck.play();
  }

  // ------------------------------------------------------------------ transitions
  /// What a transition does, as steps. Written down rather than performed straight
  /// away so it can be read, tested, and one day replayed.
  static List<MixStep> plan(Transition kind, {required String from, required String to}) {
    const off = DeckStep(eq: EqSet.flat, filter: 0);
    const noBass = DeckStep(eq: EqSet(low: EqSet.killed));
    const flat = DeckStep(eq: EqSet.flat);
    switch (kind) {
      case Transition.blend:
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass}),
          MixStep(0.5, crossfader: 0.5, decks: {to: flat, from: noBass}),
          MixStep(0.85, crossfader: 0.85, decks: {
            from: DeckStep(eq: EqSet(low: EqSet.killed, high: EqSet.killed)),
          }),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
      case Transition.cut:
        return const [MixStep(0, crossfader: 0), MixStep(1, crossfader: 1)];
      case Transition.fade:
        return const [MixStep(0, crossfader: 0), MixStep(1, crossfader: 1)];
      case Transition.sweep:
        // The old record climbs out: the high-pass closes under it while the new one
        // comes up, and by the end there is nothing left of it below the top.
        return [
          MixStep(0, crossfader: 0, decks: {
            from: const DeckStep(filter: 0),
            to: noBass,
          }),
          MixStep(0.45, crossfader: 0.35, decks: {
            from: const DeckStep(filter: 0.45),
          }),
          MixStep(0.75, crossfader: 0.7, decks: {
            from: const DeckStep(filter: 0.8, eq: EqSet(low: EqSet.killed)),
            to: flat,
          }),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
      case Transition.roll:
        // Caught and tightened: two bars, one, half — and let go as the new record
        // lands. The fader is most of the way across before the roll starts, so what
        // is being tightened is a tail rather than the whole record.
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass}),
          MixStep(0.45, crossfader: 0.45, decks: {to: flat}),
          MixStep(0.6, crossfader: 0.6, decks: {from: const DeckStep(loopBars: 2)}),
          MixStep(0.75, crossfader: 0.75, decks: {from: const DeckStep(loopBars: -1)}),
          MixStep(0.88, crossfader: 0.9, decks: {from: const DeckStep(loopBars: -1)}),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, loopBars: 0),
          }),
        ];
      case Transition.brake:
        // The new record is already running when the old one is stopped dead: the
        // fader is across first, then the platter is caught.
        return [
          MixStep(0, crossfader: 0, decks: {to: flat}),
          MixStep(0.7, crossfader: 0.85),
          MixStep(0.8, crossfader: 1, decks: {from: const DeckStep(brake: true)}),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
    }
  }

  /// How long [bars] bars of the master last, by the wall clock.
  Duration barsLength(Deck deck, int bars) {
    final beat = deck.beat ?? const Duration(milliseconds: 500);
    return beat * 4 * bars;
  }

  Timer? _running;
  bool get inTransition => _running != null;

  /// What has been done in this session, transition by transition, so it can be kept
  /// and done again: which record into which, how, over how many bars, from where in
  /// the one to where in the other, and at what tempo the incoming was run.
  final List<MixMove> taken = [];

  /// The records the session played, in order, as the log has them.
  List<int> get takenTrackIds {
    if (taken.isEmpty) return const [];
    return [taken.first.from, for (final m in taken) m.to];
  }

  void forgetTaken() {
    taken.clear();
    notifyListeners();
  }

  /// This session as a mix: a playlist of the records, carrying the moves.
  Future<Playlist> keepMix(String name) async {
    final ids = takenTrackIds;
    var made = await api.createPlaylist(name);
    if (ids.isNotEmpty) made = await api.addToPlaylist(made.id, ids);
    return api.setPlaylistMix(made.id, {
      'version': 1,
      'transitions': [for (final m in taken) m.toJson()],
    });
  }

  /// From the master to the other deck, over [bars] of the master's bars, the
  /// incoming starting on the master's next downbeat. When it is done the other deck
  /// is the master.
  Future<void> go(Transition kind, {int bars = 16}) async {
    final from = master, to = other(master);
    if (!to.loaded) return;
    _running?.cancel();

    // Written down as it starts, from where each record is.
    if (from.track != null && to.track != null) {
      taken.add(MixMove(
        from: from.track!.id,
        to: to.track!.id,
        kind: kind,
        bars: bars,
        outMs: from.position.inMilliseconds,
        inMs: to.position.inMilliseconds,
        tempo: to.tempo,
      ));
    }

    if (kind == Transition.cut) {
      await startOnBeat(to, every: 4);
      if (!_reallyPlaying(to)) return;
      await setCrossfader(identical(to, b) ? 1 : 0);
      await from.pause();
      master = to;
      return;
    }

    final steps = plan(kind, from: from.name, to: to.name);
    final length = barsLength(from, bars);
    // What the plan opens with, set before the incoming makes a sound.
    await _applyStep(steps.first);
    // A blend goes in on the master's next phrase, where a DJ would bring one in;
    // a fade on the next beat, which is soon enough for something with no grid.
    if (!to.playing) await startOnBeat(to, every: kind == Transition.fade ? 1 : 16);
    // And if it did not start, nothing is handed over: fading out of a record into
    // a deck that is not playing is fading out into silence.
    if (!_reallyPlaying(to)) {
      await _applyStep(MixStep(0, decks: {to.name: const DeckStep(eq: EqSet.flat)}));
      return;
    }

    final began = DateTime.now();
    final done = Completer<void>();
    var next = 1;
    final direction = identical(to, b) ? 1.0 : -1.0;

    /// The pair of steps [k] falls between, and how far between them it is.
    ({MixStep from, MixStep to, double local}) legAt(double k) {
      var prev = steps.first, cur = steps.last;
      for (var i = 1; i < steps.length; i++) {
        if (k <= steps[i].at) {
          prev = steps[i - 1];
          cur = steps[i];
          break;
        }
      }
      final span = cur.at - prev.at;
      return (
        from: prev,
        to: cur,
        local: span <= 0 ? 1.0 : ((k - prev.at) / span).clamp(0.0, 1.0)
      );
    }

    // The fader, moved from Dart twenty-five times a second — and the filter with
    // it, because a sweep in four jumps is four jumps rather than a sweep.
    double faderAt(double k) {
      final leg = legAt(k);
      final x = (leg.from.crossfader ?? 0) +
          ((leg.to.crossfader ?? 1) - (leg.from.crossfader ?? 0)) * leg.local;
      return direction > 0 ? x : 1 - x;
    }

    /// Where a deck's filter should be at [k], or null where the plan says nothing
    /// about it. Read backwards for the last value set, so a leg that only moves the
    /// fader leaves the filter where it was.
    double? filterAt(String deck, double k) {
      final leg = legAt(k);
      double? lastBefore(MixStep at) {
        for (var i = steps.indexOf(at); i >= 0; i--) {
          final f = steps[i].decks[deck]?.filter;
          if (f != null) return f;
        }
        return null;
      }

      final a = lastBefore(leg.from);
      final b = leg.to.decks[deck]?.filter ?? a;
      if (a == null || b == null) return null;
      return a + (b - a) * leg.local;
    }

    _running = Timer.periodic(const Duration(milliseconds: 40), (t) async {
      final k = (DateTime.now().difference(began).inMicroseconds / length.inMicroseconds)
          .clamp(0.0, 1.0);
      await setCrossfader(faderAt(k));
      for (final deck in decks) {
        final want = filterAt(deck.name, k);
        if (want != null && (filters[deck] ?? 0) != want) await setFilter(deck, want);
      }
      while (next < steps.length && k >= steps[next].at) {
        await _applyStep(steps[next]);
        next++;
      }
      if (k >= 1) {
        t.cancel();
        _running = null;
        from.unloop();
        await from.pause();
        await setEq(from, EqSet.flat);
        await setFilter(from, 0);
        master = to;
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  /// Whether the deck being mixed into is actually making a sound. A record that
  /// would not load looks loaded — it has a title and a cover — and a transition into
  /// one is a transition into nothing, so it is refused and said rather than done.
  bool _reallyPlaying(Deck deck) {
    if (deck.playing) return true;
    _wouldNotPlay = deck.trouble ?? 'Deck ${deck.name} did not start';
    notifyListeners();
    return false;
  }

  /// Why the last transition did not happen, if it did not.
  String? get wouldNotPlay => _wouldNotPlay;
  String? _wouldNotPlay;

  void forgetTrouble() {
    _wouldNotPlay = null;
    notifyListeners();
  }

  /// Everything a step says to do at once — the bands, a loop caught or tightened
  /// or let go, a record braked. The filter is not here: it is travelled to rather
  /// than set, along with the fader.
  Future<void> _applyStep(MixStep step) async {
    for (final e in step.decks.entries) {
      final deck = e.key == a.name ? a : b;
      final want = e.value;
      if (want.eq != null) await setEq(deck, want.eq!);
      switch (want.loopBars) {
        case null:
          break;
        case 0:
          deck.unloop();
        case -1:
          deck.halveLoop();
        case final int bars:
          deck.loop(bars * 4);
      }
      if (want.brake) unawaited(deck.brake());
    }
  }

  void stopTransition() {
    _running?.cancel();
    _running = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _running?.cancel();
    auto.dispose();
    a.dispose();
    b.dispose();
    super.dispose();
  }
}
