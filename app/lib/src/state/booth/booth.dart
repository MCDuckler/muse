import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../timing.dart';
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
}

/// One instruction in a transition, at a point in it (0 at the start, 1 at the end).
class MixStep {
  const MixStep(this.at, {this.crossfader, this.kills = const {}});

  final double at;

  /// Where the crossfader is by this point; the fader moves evenly from the previous
  /// step's place to this one.
  final double? crossfader;

  /// Kills switched at this point, per deck name: {'A': (low: true, ...)}.
  final Map<String, ({bool low, bool mid, bool high})> kills;
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
    // The browser has to be told which deck is about to make its element, before it
    // does; the deck makes it the first time it is spoken to.
    this.mixer.expecting('A');
    this.a = a ?? Deck('A', api: api, offlinePath: offlinePath);
    this.mixer.expecting('B');
    this.b = b ?? Deck('B', api: api, offlinePath: offlinePath);
    this.a.addListener(notifyListeners);
    this.b.addListener(notifyListeners);
  }

  final ApiClient api;
  final Mixer mixer;
  final TimingStore timing;
  late final Deck a;
  late final Deck b;

  List<Deck> get decks => [a, b];
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

  // ------------------------------------------------------------------ loading
  Future<void> load(Deck deck, Track track, {Duration? at}) async {
    final t = await timing.of(track);
    await deck.load(track, timing: t, at: at);
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
    final l = levelsFor(crossfader);
    notifyListeners();
    await mixer.setLevels({a: l.a, b: l.b}, over: over);
  }

  final Map<Deck, ({bool low, bool mid, bool high})> kills = {};

  Future<void> setKills(Deck d, {bool low = false, bool mid = false, bool high = false}) async {
    kills[d] = (low: low, mid: mid, high: high);
    notifyListeners();
    await mixer.setKills(d, low: low, mid: mid, high: high);
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
    const off = (low: false, mid: false, high: false);
    switch (kind) {
      case Transition.blend:
        return [
          MixStep(0, crossfader: 0, kills: {to: (low: true, mid: false, high: false)}),
          MixStep(0.5, crossfader: 0.5, kills: {
            to: off,
            from: (low: true, mid: false, high: false),
          }),
          MixStep(0.85, crossfader: 0.85, kills: {
            from: (low: true, mid: false, high: true),
          }),
          MixStep(1, crossfader: 1, kills: {from: off}),
        ];
      case Transition.cut:
        return const [MixStep(0, crossfader: 0), MixStep(1, crossfader: 1)];
      case Transition.fade:
        return const [MixStep(0, crossfader: 0), MixStep(1, crossfader: 1)];
    }
  }

  /// How long [bars] bars of the master last, by the wall clock.
  Duration barsLength(Deck deck, int bars) {
    final beat = deck.beat ?? const Duration(milliseconds: 500);
    return beat * 4 * bars;
  }

  Timer? _running;
  bool get inTransition => _running != null;

  /// From the master to the other deck, over [bars] of the master's bars, the
  /// incoming starting on the master's next downbeat. When it is done the other deck
  /// is the master.
  Future<void> go(Transition kind, {int bars = 16}) async {
    final from = master, to = other(master);
    if (!to.loaded) return;
    _running?.cancel();

    if (kind == Transition.cut) {
      await startOnBeat(to, every: 4);
      await setCrossfader(identical(to, b) ? 1 : 0);
      await from.pause();
      master = to;
      return;
    }

    final steps = plan(kind, from: from.name, to: to.name);
    final length = barsLength(from, bars);
    // The kills the plan opens with, set before the incoming makes a sound.
    await _applyKills(steps.first);
    if (!to.playing) await startOnBeat(to, every: kind == Transition.fade ? 1 : 4);

    final began = DateTime.now();
    final done = Completer<void>();
    var next = 1;
    // The fader between steps, from Dart, twenty-five times a second: a mixer that
    // can ramp on its own clock (the browser) is handed each leg as a ramp instead.
    final direction = identical(to, b) ? 1.0 : -1.0;
    double faderAt(double k) {
      var prev = steps.first, cur = steps.last;
      for (var i = 1; i < steps.length; i++) {
        if (k <= steps[i].at) {
          prev = steps[i - 1];
          cur = steps[i];
          break;
        }
      }
      final span = cur.at - prev.at;
      final local = span <= 0 ? 1.0 : ((k - prev.at) / span).clamp(0.0, 1.0);
      final x = (prev.crossfader ?? 0) + ((cur.crossfader ?? 1) - (prev.crossfader ?? 0)) * local;
      return direction > 0 ? x : 1 - x;
    }

    _running = Timer.periodic(const Duration(milliseconds: 40), (t) async {
      final k = (DateTime.now().difference(began).inMicroseconds / length.inMicroseconds)
          .clamp(0.0, 1.0);
      await setCrossfader(faderAt(k));
      while (next < steps.length && k >= steps[next].at) {
        await _applyKills(steps[next]);
        next++;
      }
      if (k >= 1) {
        t.cancel();
        _running = null;
        await from.pause();
        await setKills(from);
        master = to;
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  Future<void> _applyKills(MixStep step) async {
    for (final e in step.kills.entries) {
      final deck = e.key == a.name ? a : b;
      await setKills(deck, low: e.value.low, mid: e.value.mid, high: e.value.high);
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
    a.dispose();
    b.dispose();
    super.dispose();
  }
}
