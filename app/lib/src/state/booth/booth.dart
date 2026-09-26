import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../worker/parts_jobs.dart';
import '../timing.dart';
import 'automix.dart';
import 'deck.dart';
import 'fx_channel.dart';
import 'fx_sounds.dart';
import 'mixer.dart';
import 'parts.dart';

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

  /// The drums change hands. The new record comes in as its drums alone, under the
  /// old one; the old one gives up its own drums half way, so there is never a second
  /// kick fighting the first; then the new record becomes whole and the old one goes.
  ///
  /// The most convincing thing here when it works, and it only works on records that
  /// have been taken apart — by this computer where there is one to do it, by the
  /// server otherwise — which is why nothing chooses it until they have. See
  /// PartsStore for which machine does it, and the server's stems.py for how good
  /// that separation is and what it costs.
  swap,

  /// The new record announces itself: its voice alone — its hook, where the words say
  /// where that is — sung over the old record's beat for half the transition, the old
  /// record's own voice taken out under it; then the new record's band arrives under
  /// its voice and the old one goes. Stem decks only.
  announce,

  /// The old record goes out singing: its voice alone rides over the new record's
  /// intro, the new record's own voice held back until the old one has finished.
  /// Stem decks only.
  acapellaOut,

  /// The long, modern blend: the stems change hands one at a time — the new drums
  /// under the old record, then its bass and the rest while the old drums go, the old
  /// voice out, the new voice in last. Nothing ever doubles. Stem decks only.
  stemBlend,

  /// The drop swap: the old record builds, climbing out through the filter and caught
  /// in a tightening loop, and on the one the new record drops in its place — parked
  /// so that its drop lands exactly on the transition's last beat.
  dropSwap,

  /// The echo-out: the new record comes in under the old, and the old goes out into
  /// its echo — the send opened over its last bars, then the record itself taken
  /// away on the one and the echo's tail left to die under the new record.
  echoOut,

  /// The loop build: the old record is caught in a loop of four bars, then two, then
  /// one, climbing through the filter, and the new record drops on the one — a
  /// longer, wilder drop swap.
  loopBuild,

  /// The break swap: the old record's own breakdown is the transition — the new
  /// record comes in over it, and drops where the old one would have dropped. Two
  /// drops become one.
  breakSwap,

  /// The filter ride: long, both ways — the old record climbs out through the
  /// high-pass while the new one opens up through the low-pass.
  filterRide,

  /// The riser: an uplifter the booth makes itself climbs under the whole move, the
  /// old record held whole until it leaves through the filter over the last bars, and
  /// on the one the new record takes the room with a hit under it.
  ///
  /// Almost nothing is done to either record here, which is the point: the sound the
  /// booth *brings* is the transition. So it is the one move that works on two records
  /// that agree about nothing — no shared key, no stems, no drop to aim at — and the
  /// only one whose timing is exact to the sample, because a riser that peaks a beat
  /// after the drop is worse than no riser. See fx_sounds.dart.
  riser,

  /// The sweep: a short blend with a noise sweep rising into the change and another
  /// falling away behind it. The whoosh, and what most people mean by one.
  noiseSweep,

  /// The gush: both records' tops are pulled under a resonant wash of noise that
  /// arches over the change and is gone by the end of it, so the join happens inside
  /// the noise where there is nothing to hear it against.
  hydrant,

  /// The dissolve: the old record evaporates rather than ends. The echo is opened
  /// under it over the whole move and its own sound taken away a little at a time
  /// through a closing low-pass, until what is left is a tail in the dark. For a
  /// record with no ending of its own to lean on. Needs the desk's echo.
  dissolve,

  /// The lunar echo: the same, falling. The old record is pulled five semitones down
  /// as it goes into its echo — slow, like a hand easing a platter — and the tail
  /// rings on under the new record. Needs the desk's echo and its pitch shift.
  lunarEcho,

  /// The tremolo: the old record is chopped in time with its own beat, deeper and
  /// then faster as the new one comes up under it, until there is more gap than
  /// record and it is gone. Needs an engine that can chop (Mixer.canGate).
  tremolo,
}

extension TransitionWords on Transition {
  /// As a person says it.
  String get label => switch (this) {
        Transition.acapellaOut => 'a cappella out',
        Transition.stemBlend => 'stem blend',
        Transition.dropSwap => 'drop swap',
        Transition.echoOut => 'echo out',
        Transition.loopBuild => 'loop build',
        Transition.breakSwap => 'break swap',
        Transition.filterRide => 'filter ride',
        Transition.noiseSweep => 'noise sweep',
        Transition.tremolo => 'tremolo',
        Transition.lunarEcho => 'lunar echo',
        _ => name,
      };

  /// Needs the desk's echo (Mixer.canShift): elsewhere it is [plainly].
  bool get needsFx =>
      this == Transition.echoOut || this == Transition.dissolve || this == Transition.lunarEcho;

  /// Made of a sound the booth plays itself (FxChannel). Where a rendered sound can
  /// be put nowhere a player will take it, these are [plainly] too — and the booth
  /// says which, rather than playing the move with its middle missing.
  bool get needsSound =>
      this == Transition.riser || this == Transition.noiseSweep || this == Transition.hydrant;

  /// Made of the engine's chop (Mixer.canGate): elsewhere it is [plainly].
  bool get needsGate => this == Transition.tremolo;

  /// What this move becomes on an engine that cannot do it. Near enough to be the
  /// same idea, and never itself needing something else the engine has not got.
  Transition get plainly => switch (this) {
        Transition.riser => Transition.loopBuild,
        Transition.hydrant => Transition.sweep,
        _ => Transition.blend,
      };

  /// Made of stems: nothing it means can be done on a deck playing the whole record.
  bool get needsStems =>
      this == Transition.announce || this == Transition.acapellaOut || this == Transition.stemBlend;

  /// Whether the fader runs the "full" law for this move: both records whole at the
  /// middle, rather than each at 0.71. The moves that hand the record over a stem or a
  /// part at a time are one record's worth of sound shared between two decks, and
  /// the equal-power law took 3 dB off every stem of it for as long as the fader sat
  /// in the middle — the whole of a stem blend.
  ///
  /// The filter moves run it too: the outgoing loses most of its energy to the
  /// high-pass anyway, and under the equal-power law the sweep was a 7 dB hole with an
  /// 8.6 dB quarter-second in it (the probe, 2026-09-25) — the room going quiet in the
  /// middle of a change.
  bool get full =>
      needsStems ||
      this == Transition.swap ||
      this == Transition.breakSwap ||
      this == Transition.sweep ||
      this == Transition.filterRide;
}

/// What a transition does to one deck at one moment.
class DeckStep {
  const DeckStep(
      {this.eq,
      this.filter,
      this.loopBars,
      this.brake = false,
      this.part,
      this.stems,
      this.echo,
      this.dry,
      this.shift,
      this.gate,
      this.gateDiv});

  /// How deep this deck's chop is by this point, 0 (off) to 1 (to silence) —
  /// travelled to like the filter, so a gate arrives rather than appears. Only where
  /// the engine can chop (Mixer.canGate).
  final double? gate;

  /// How many chops to a beat: 2 is eighths, 4 sixteenths. Held, like a band, rather
  /// than travelled — a rate between two rates is not a rate anybody plays.
  final int? gateDiv;

  /// Where this deck's pitch shift is by this point, in semitones, on an engine that
  /// has one (Mixer.canShift) — travelled to like the filter rather than jumped to,
  /// because a record pulled five semitones down in one step is a record that has
  /// been switched off, and one eased down is a record being let go of.
  ///
  /// The incoming's key shift is set once before a move begins and is not this; this
  /// is the *outgoing* falling out of the mix (the lunar echo).
  final double? shift;

  /// The echo send, 0 to 1, and how much of the record itself is still heard, where
  /// this step sets them (Mixer.setEcho). Send shut and dry taken away together is
  /// the echo-out: the tail rings on.
  final double? echo, dry;

  /// A stem deck's levels by this point: moved to evenly from the last step that set
  /// them, like the fader. Ignored on a deck that is not playing its stems.
  final StemLevels? stems;

  /// The record itself, as a thing a step can ask for: [part] left null means "leave
  /// whatever is on the platter alone", so putting the whole record back needs a word
  /// of its own.
  static const whole = '';

  /// The three bands, where this step sets them.
  final EqSet? eq;

  /// The filter knob, where this step sets it: interpolated to, like the fader, so a
  /// sweep is a sweep rather than four jumps.
  final double? filter;

  /// A loop of so many bars, zero to let one go, or -1 to halve the one running.
  final int? loopBars;

  /// The record brakes to a stop here.
  final bool brake;

  /// Which part of the record plays from here on — 'drums', 'music', 'instrumental',
  /// or [whole] for the record as it was made. Null leaves it as it is.
  final String? part;
}

/// One instruction in a transition, at a point in it (0 at the start, 1 at the end).
class MixStep {
  const MixStep(this.at, {this.crossfader, this.decks = const {}, this.fx});

  final double at;

  /// A sound of the booth's own, fired as this step is reached. See FxShot.
  final FxShot? fx;

  /// Where the crossfader is by this point; the fader moves evenly from the previous
  /// step's place to this one.
  final double? crossfader;

  /// What each deck is doing by then, by deck name.
  final Map<String, DeckStep> decks;

  /// The same step at another point of the transition.
  MixStep at_(double k) => MixStep(k, crossfader: crossfader, decks: decks, fx: fx);

  /// [steps] moved onto the bars of a transition [bars] long: a bass swap, a kill, a
  /// loop caught — each on a downbeat, where a DJ does it. The plans are written in
  /// fractions of the whole, and 0.85 of sixteen bars is bar 13.6: an EQ that changed
  /// part-way through a bar, which is the thing that made a mix sound wrong without
  /// anybody being able to say why.
  ///
  /// A loop *halved* is the one thing that belongs between bars: a roll goes two
  /// bars, one, a half, a quarter, and the last rungs are shorter than a bar by
  /// definition. Those steps land on beats.
  static List<MixStep> onBars(List<MixStep> steps, int bars) {
    if (bars <= 1) return steps;
    return [
      for (final s in steps)
        s.at_(s.decks.values.any((d) => d.loopBars == -1)
            ? (s.at * bars * 4).round() / (bars * 4)
            : (s.at * bars).round() / bars),
    ];
  }
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

/// What sort of thing happened in the booth, for the log to draw it by.
enum BoothEventKind { auto, next, sync, cue, plan, mix, held, done, skip, parts, trouble }

/// One line of the booth's log: what it did, and when.
class BoothEvent {
  BoothEvent(this.kind, this.text, {this.deck}) : at = DateTime.now();
  final BoothEventKind kind;
  final String text;

  /// The deck it was about, where it was about one.
  final String? deck;
  final DateTime at;
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
    FxChannel? fx,
    Deck? a,
    Deck? b,
  })  : mixer = mixer ?? Mixer.forThisDevice(),
        fx = fx ?? FxChannel(),
        timing = timing ?? TimingStore(api),
        parts = PartsStore(api, offlinePath: offlinePath) {
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
    this.a.parts = parts;
    this.b.parts = parts;
    this.a.engineLoop = (from, to) => this.mixer.setLoop(this.a, from, to);
    this.b.engineLoop = (from, to) => this.mixer.setLoop(this.b, from, to);
    this.a.seamFinder = this.mixer.quietSeam;
    this.b.seamFinder = this.mixer.quietSeam;
    for (final d in [this.a, this.b]) {
      d
        ..pitchEngine = ((deck, semis) => this.mixer.setPitchShift(deck, semis))
        ..canStem = this.mixer.canStem
        ..readyEngine = this.mixer.beforeLoad
        ..stemEngine = this.mixer.setStems
        ..firstLoadMissed = this.mixer.firstLoadMissed;
    }
    this.a.addListener(notifyListeners);
    this.b.addListener(notifyListeners);
    this.a.addListener(_follow);
    // A record's parts or beats arriving: what the house says of it is asked again.
    parts.arrivals.stream.listen(this.timing.forget);
    this.b.addListener(_follow);
    partsJobs.addListener(_partsChanged);
  }

  /// What the list of records being taken apart last said, by record: so the log gets
  /// a line when one starts, is ready or fails — not one for every tick of progress.
  final _partsSaid = <int, PartsStage>{};

  void _partsChanged() {
    for (final j in partsJobs.all) {
      final was = _partsSaid[j.trackId];
      if (was == j.stage) continue;
      _partsSaid[j.trackId] = j.stage;
      final deck = decks.where((d) => d.track?.id == j.trackId).firstOrNull;
      switch (j.stage) {
        // Once per taking apart: a first-time fetch of the separator in the middle of
        // it is not a second start.
        case PartsStage.separating when was != PartsStage.gettingSeparator:
          note(BoothEventKind.parts, 'Taking apart: ${j.title}', deck: deck);
        case PartsStage.pooled when was != PartsStage.pooled:
          note(BoothEventKind.parts, 'Asked the pool to take apart: ${j.title}', deck: deck);
        case PartsStage.ready:
          note(BoothEventKind.parts, 'Parts ready: ${j.title}', deck: deck);
        case PartsStage.failed:
          note(BoothEventKind.trouble, 'Could not take apart: ${j.title}', deck: deck);
        default:
      }
    }
  }

  final ApiClient api;
  final Mixer mixer;

  /// The third voice: the sounds the booth plays that are neither record — the riser
  /// under a build, the whoosh over a change, the hit on the one. See fx_channel.dart.
  final FxChannel fx;
  final TimingStore timing;

  /// Where the voice is in each record and what it sings: what the automix plans its
  /// vocal moves by.
  late final VocalStore vocals = VocalStore(api);

  /// Where the parts of a record come from. See PartsStore.
  final PartsStore parts;
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

  /// The widest gap the automix still mixes on the beat: the incoming is pulled all
  /// the way to the master, whose tempo never moves. Rubber Band keeps a record this
  /// far off its own speed sounding like itself; past this, two records are two
  /// different speeds of music and are handed over quickly rather than laid on top of
  /// each other.
  static const bridgeReach = 0.16;

  /// How far SYNC pressed by hand will go: anywhere. Once half and double time are
  /// taken into account no two tempos are more than about 41 % apart, and a DJ who
  /// presses SYNC has decided the two go together — the booth's part is to do it,
  /// not to argue. (It once refused past ±8 % of the record's own speed, which with a
  /// deck already pitched meant refusing two tempos a few tenths apart on screen.)
  static const handReach = 0.5;

  bool _prepared = false;
  Future<void> init() async {
    if (_prepared) return;
    _prepared = true;
    // Speaking to each player once makes its element / session, in order.
    await a.player.setVolume(1);
    await b.player.setVolume(1);
    await mixer.prepare(decks);
    await setCrossfader(crossfader);
    // Anything an interrupted run left in the parts folder. Nothing of this run's is
    // there yet, which is what makes it safe to do here and nowhere else.
    unawaited(parts.tidyAtStart());
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
      await mixer.loaded(deck);
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
  ///
  /// [full] is the other law a mixer offers: each record whole until the middle,
  /// and only then taken down — so a record alone on one side, with the other's
  /// stems arriving on the other, is not 3 dB down for the fader being there.
  static ({double a, double b}) levelsFor(double x, {bool full = false}) {
    final v = x.clamp(0.0, 1.0);
    if (full) {
      return (
        a: v <= 0.5 ? 1.0 : math.cos((v - 0.5) * math.pi),
        b: v >= 0.5 ? 1.0 : math.sin(v * math.pi),
      );
    }
    final k = v * math.pi / 2;
    return (a: math.cos(k), b: math.sin(k));
  }

  /// Which law the fader runs now: the full one during a move that says so
  /// (Transition.full), equal power otherwise.
  bool fullLaw = false;

  Future<void> setCrossfader(double x, {Duration over = Duration.zero}) async {
    crossfader = x.clamp(0.0, 1.0);
    notifyListeners();
    await _levels(over: over);
  }

  /// What each channel is actually sending: its share of the crossfader, at its
  /// gain, with the record's own loudness taken off.
  ({double a, double b}) get levels {
    final l = levelsFor(crossfader, full: fullLaw);
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

  /// Whether [band] (0 low, 1 mid, 2 high) is lopsided across the two decks: one of
  /// them has it killed or nearly down and the other has not.
  ///
  /// This is the shape a bass swap is *about* to happen in — one record's bottom taken
  /// out under the other's — and the only shape where swapping the two is a move
  /// rather than a shuffle.
  static const _lowEnough = -11.0;

  double _bandOf(Deck d, int band) => switch (band) {
        0 => eqOf(d).low,
        1 => eqOf(d).mid,
        _ => eqOf(d).high,
      };

  bool bandLopsided(int band) {
    final x = _bandOf(a, band), y = _bandOf(b, band);
    return (x <= _lowEnough) != (y <= _lowEnough);
  }

  /// [band] handed across: what A had, B gets, and the other way round.
  ///
  /// The move every DJ makes with two hands at once — the new record's bass up as the
  /// old one's goes — done on one button so the two happen on the same beat instead of
  /// however fast two knobs can be turned.
  Future<void> swapBand(int band) async {
    final x = _bandOf(a, band), y = _bandOf(b, band);
    if (x == y) return;
    EqSet put(EqSet on, double db) => switch (band) {
          0 => on.withLow(db),
          1 => on.withMid(db),
          _ => on.withHigh(db),
        };
    await setEq(a, put(eqOf(a), y));
    await setEq(b, put(eqOf(b), x));
    note(BoothEventKind.cue,
        '${switch (band) { 0 => 'Low', 1 => 'Mid', _ => 'High' }} swapped between the decks');
  }

  /// One band all the way down, or back to flat.
  Future<void> kill(Deck d, int band, bool on) => setEq(d, eqOf(d).killing(band, on));

  /// [d] played [semitones] up or down at the same tempo — a boost mix's semitone.
  Future<void> setPitchShift(Deck d, double semitones) async {
    _shift[d] = semitones;
    await mixer.setPitchShift(d, semitones);
    notifyListeners();
  }

  final Map<Deck, double> _shift = {};
  double pitchShiftOf(Deck d) => _shift[d] ?? 0;

  /// [d]'s echo: the send into it, and how much of the record itself is still heard.
  Future<void> setEcho(Deck d, {required double send, required double dry}) async {
    _echo[d] = (send: send, dry: dry);
    await mixer.setEcho(d, send: send, dry: dry);
  }

  final Map<Deck, ({double send, double dry})> _echo = {};

  /// [d] as it was made: no echo, no shift — after a move that used them.
  Future<void> _plain(Deck d) async {
    final e = _echo[d];
    if (e != null && (e.send != 0 || e.dry != 1)) await setEcho(d, send: 0, dry: 1);
    if ((_shift[d] ?? 0) != 0) await setPitchShift(d, 0);
  }

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
  static double? syncRatio(double from, double to, {double reach = maxSync}) {
    if (from <= 0 || to <= 0) return null;
    // Half or double time is the same tempo: 140 syncs to 70 as 70. Whichever is
    // nearer, counted the way the ear counts — in ratios, not beats a minute.
    var target = to;
    while (target / from > math.sqrt2) {
      target /= 2;
    }
    while (target / from < 1 / math.sqrt2) {
      target *= 2;
    }
    final ratio = target / from;
    return (ratio - 1).abs() > reach ? null : ratio;
  }

  /// Why [deck] cannot be synced to the other one, in a few words — or null when it
  /// can. With nothing refused for being too far apart by hand, only a record with no
  /// tempo is left to say no.
  String? whyNotSync(Deck deck) {
    final o = other(deck);
    if (deck.track == null) return 'Nothing on ${deck.name}';
    if (o.track == null) return 'Nothing on ${o.name} to sync to';
    if (deck.timing == null) return 'No beat grid for ${deck.name} yet';
    if (deck.timing!.bpm == null) return 'No steady beat on ${deck.name}';
    if (o.timing == null) return 'No beat grid for ${o.name} yet';
    if (o.bpm == null) return 'No steady beat on ${o.name}';
    return null;
  }

  /// Bring [deck]'s tempo to the master's. Says whether it could.
  ///
  /// By the figures the decks show — each record's own BPM at its pitch — so that
  /// after SYNC the two read the same, and keep reading the same. (It once matched
  /// the tempo of the bars around each record instead, which is truer to the beat
  /// but left the two numbers on show a few tenths apart, and up to three beats a
  /// minute apart on a record whose intro runs faster than the rest of it. Keeping
  /// the beats together over what is left is the beat-holding's job: see holdOnBeat.)
  ///
  /// [target] is the tempo to meet where it is not the master's as shown: the automix
  /// matches the next record to the master's own tempo, which the master is on its
  /// way back to after a mix (AutoMix glide).
  Future<bool> sync(Deck deck, {double reach = handReach, bool quiet = false, double? target}) async {
    final m = other(deck);
    final from = deck.timing?.gridBpm;
    final to = target ?? m.bpm;
    if (from == null || to == null) return false;
    final ratio = syncRatio(from, to, reach: reach);
    if (ratio == null) return false;
    final was = deck.pitch;
    await deck.setTempo(ratio);
    if (!quiet && (was - ratio).abs() > 0.0001) {
      final pct = (ratio - 1) * 100;
      note(BoothEventKind.sync,
          '${deck.name} to ${deck.bpm?.toStringAsFixed(1)} bpm (${pct >= 0 ? '+' : '-'}${pct.abs().toStringAsFixed(1)}%)',
          deck: deck);
    }
    return true;
  }

  /// Nudge [deck] so its beat falls with the master's. Only the phase, not the tempo.
  Future<void> align(Deck deck) async {
    final m = other(deck);
    final now = DateTime.now();
    final mine = deck.beatAt(now), theirs = m.beatAt(now);
    // A nudge is a move in the record, so it is counted in the record's own beats.
    final beat = deck.hasBeats ? deck.beatInRecord : null;
    if (mine == null || theirs == null || beat == null) return;
    // How far ahead of the master's phase this deck is, as a fraction of a beat,
    // taken the short way round.
    var ahead = mine.phase - theirs.phase;
    if (ahead > 0.5) ahead -= 1;
    if (ahead < -0.5) ahead += 1;
    await deck.nudge(Duration(microseconds: (-ahead * beat.inMicroseconds).round()));
  }

  // ------------------------------------------------------------------ SYNC by hand
  /// Turn [deck]'s SYNC on or off. Says whether it could.
  ///
  /// On is what the button does on a DJ's deck: the tempo matched to the other deck's,
  /// and then the beat — not once, but held there for as long as both play (see
  /// holdOnBeat), started on the beat when either is started while the other plays
  /// ([play]), and matched again when the other deck's tempo moves. One deck follows,
  /// the other leads, and the one it follows is the master. It used to match the
  /// tempo and nudge the phase once: a record started a moment later by hand was out
  /// of step from its first beat, and nothing ever brought it back.
  Future<bool> setSync(Deck deck, bool on) async {
    if (!on) {
      if (!deck.synced) return true;
      deck.synced = false;
      deck.syncTrim = Duration.zero;
      if (identical(_lockFollower, deck) && !busy) await letGo();
      note(BoothEventKind.sync, 'SYNC off on ${deck.name}', deck: deck);
      notifyListeners();
      return true;
    }
    if (whyNotSync(deck) != null) return false;
    final m = other(deck);
    if (!await sync(deck)) return false;
    m.synced = false;
    m.syncTrim = Duration.zero;
    deck.synced = true;
    master = m;
    // Already both playing: put in step at once, as the button does, rather than
    // bent there. Not when the follower is parked: it is started on the beat instead
    // ([play]), and a jump then would only take it off it again — a jump lands late.
    _snapNext = deck.playing && m.playing;
    // And the bars lined up, where the deck is parked: tempo and beat put it in time,
    // this puts it in the right *place* in the phrase. Silent — it is not playing.
    if (!deck.playing) await meetThePhrase(deck);
    note(BoothEventKind.sync, '${deck.name} follows ${m.name}', deck: deck);
    _follow();
    notifyListeners();
    return true;
  }

  /// The next hold puts the follower in step with one jump, audible or not.
  bool _snapNext = false;
  bool _following = false;

  /// Keep a synced deck with the deck it follows: its tempo matched again when either
  /// changes, and its beat held whenever both play. Called whenever either deck
  /// changes; cheap when there is nothing to do.
  void _follow() {
    if (_following) return;
    final f = a.synced ? a : b.synced ? b : null;
    if (f == null || busy) return;
    final m = other(f);
    if (!f.loaded || !m.loaded) return;
    _following = true;
    try {
      // The leader's pitch moved, or either has a new record: matched again, quietly —
      // a fader being dragged is a hundred changes, not a hundred lines in the log.
      final from = f.timing?.gridBpm, to = m.bpm;
      final want = from == null || to == null ? null : syncRatio(from, to, reach: handReach);
      if (want != null && (f.pitch - want).abs() > 1e-6) {
        unawaited(sync(f, quiet: true));
      }
      if (f.playing && m.playing && !holding && f.hasBeats && m.hasBeats) {
        holdOnBeat(f, snap: _snapNext);
        _snapNext = false;
      }
    } finally {
      _following = false;
    }
  }

  /// Start [deck]. Where one of the two decks follows the other (SYNC is on) and the
  /// other is playing, in step: moved to the beat of its own nearest where it is
  /// parked — with [bars], to the one that sits in its bar where the other's next
  /// beat sits in its — and started just before the other reaches that beat, by the
  /// engine's own start-up time. Otherwise it just plays.
  Future<void> play(Deck deck, {bool bars = true}) async {
    final m = other(deck);
    if (deck.playing) return;
    if (!(deck.synced || m.synced) || !m.playing || busy) {
      await deck.play();
      return;
    }
    await _startInStep(deck, bars: bars);
  }

  /// Start [deck] on the beat of the other, playing deck, in step with it — the
  /// "start on the master's next bar" pad, and a synced deck's play button.
  Future<void> startOnBeat(Deck deck, {bool bars = true}) async {
    if (deck.playing) return;
    if (!other(deck).playing) {
      await deck.play();
      return;
    }
    await _startInStep(deck, bars: bars);
  }

  Future<void> _startInStep(Deck deck, {required bool bars}) async {
    final m = other(deck);
    final ft = deck.timing, mt = m.timing;
    final now = DateTime.now();
    // The other's beat to land on: its next, far enough ahead to seek in time.
    final soon = m.positionAt(now) + Duration(microseconds: (250000 * m.tempo).round());
    final land = m.nextBeat(soon);
    final mb = land == null || mt == null ? null : mt.smoothBeatAt(land + const Duration(milliseconds: 1));
    final parked = deck.position;
    final fb = ft?.smoothBeatAt(parked);
    if (ft == null || mt == null || land == null || mb == null || fb == null) {
      await deck.play();
      return;
    }
    // The follower's beat nearest where it is parked — moved, with bars, by up to two
    // beats to the one in the same place in its bar.
    var k = fb.phase < 0.5 ? fb.index : fb.index + 1;
    if (bars) {
      final there = ((mb.index - mt.barStartsOn) % 4 + 4) % 4;
      var d = ((there - (k - ft.barStartsOn)) % 4 + 4) % 4;
      if (d > 2) d -= 4;
      k += d;
    }
    final beat = ft.beatTime(k, near: parked);
    if (beat == null || beat.isNegative) {
      await deck.play();
      return;
    }
    // Held a little ahead where a hand trimmed it so: started that much ahead too.
    await deck.seek(beat + Duration(microseconds: (deck.syncTrim.inMicroseconds * deck.tempo).round()));
    _snapNext = false;
    final early = Duration(microseconds: (_startLead.inMicroseconds * m.tempo).round());
    await _until(m, land - early);
    await deck.play();
    _follow();
  }

  /// A nudge by hand. With SYNC on and the beat held, the record moves and so does
  /// where it is held (Deck.syncTrim): the holding would otherwise pull it straight
  /// back, and a nudge is how a grid a little off is put right by ear.
  Future<void> nudge(Deck deck, Duration by) async {
    if (deck.synced && identical(_lockFollower, deck) && holding) {
      final trimmed = deck.syncTrim + by;
      const most = Duration(milliseconds: 150);
      deck.syncTrim = trimmed > most ? most : trimmed < -most ? -most : trimmed;
    }
    await deck.nudgeByHand(by);
  }

  /// The pitch fader, by hand. Moving a synced deck's fader is taking it back, so its
  /// SYNC goes off; moving the leader's takes the follower with it.
  Future<void> pitchByHand(Deck deck, double rate) async {
    if (deck.synced) await setSync(deck, false);
    await deck.setTempo(rate);
    _follow();
  }

  // ------------------------------------------------------------------ holding two records together
  /// How far [follower] is ahead of [master] in their beats, by the wall clock — the
  /// short way round, so never more than half of a beat either way. Null where either
  /// has no grid there.
  ///
  /// Read off each record's fitted grid (TrackTiming.smoothBeatAt), at each deck's
  /// rate. Where one runs at twice the other's beats — 140 synced to 70 — the quicker
  /// one's beats are taken in pairs, counted from its bars, so what is lined up is the
  /// same pulse rather than every other beat of it.
  static Duration? beatError({
    required TrackTiming follower,
    required Duration followerAt,
    required double followerRate,
    required TrackTiming master,
    required Duration masterAt,
    required double masterRate,
  }) {
    final f = follower.smoothBeatAt(followerAt), m = master.smoothBeatAt(masterAt);
    if (f == null || m == null || followerRate <= 0 || masterRate <= 0) return null;
    final fWall = f.period / followerRate, mWall = m.period / masterRate;
    final r = fWall / mWall;
    final fk = r < 0.75 ? 2 : 1; // the follower's beats, in pairs
    final mk = r > 1.5 ? 2 : 1; // or the master's
    double coarse(({int index, double phase, double period}) b, int k, int barStart) =>
        (((b.index - barStart) % k + k) % k + b.phase) / k;
    var d = coarse(f, fk, follower.barStartsOn) - coarse(m, mk, master.barStartsOn);
    d -= d.roundToDouble(); // into -0.5..0.5
    return Duration(microseconds: (d * mWall * mk * 1000).round());
  }

  /// The rate a follower runs at to lose [error] over [over]: a DJ's hand on the
  /// platter, never more than [most] either way. The engines keep pitch when the
  /// rate changes, so a bend this small is heard as nothing at all.
  ///
  /// Two speeds. Close in — inside [near], below what anybody hears as a flam — gently,
  /// over four seconds, so the rate
  /// does not chase the engines' own jitter. Further out, where the flam can be heard,
  /// over well under a second and up to six per cent: a sixty-millisecond flam bent out
  /// over four seconds was ten seconds of two records audibly apart.
  static double bendFor(Duration error,
      {Duration over = const Duration(seconds: 4),
      Duration quick = const Duration(milliseconds: 700),
      Duration near = const Duration(milliseconds: 8),
      double most = 0.06}) {
    final far = error.abs() > near;
    final b = -error.inMicroseconds / (far ? quick : over).inMicroseconds;
    return 1 + b.clamp(-most, far ? most : 0.03);
  }

  Timer? _lock;
  static const _trace = bool.fromEnvironment('BOOTH_TRACE');

  /// Hold [follower] on the master's beat for as long as both play: measured twenty
  /// times a second, corrected with small bends of its rate rather than jumps.
  ///
  /// Why it has to be done at all: an engine takes its own time to start — tens of
  /// milliseconds, and never the same twice — and no two tempo readings agree to the
  /// last decimal. Left alone, a blend that starts together drifts into a flam and
  /// then a gallop. This is what a DJ's hand is doing on the platter the whole time.
  ///
  /// The rate it settles on is learned as it goes (the slow half of the controller),
  /// so when the bending stops the record carries on at the rate that actually holds.
  /// A follower that starts a long way off, while it cannot yet be heard, is simply
  /// moved there once. Nothing is lined up to a master that is looping or braking.
  ///
  /// With [snap], the first correction is a jump even while it can be heard: SYNC
  /// pressed with both records playing puts them in step at once, as it does on any
  /// deck, rather than bending them there over several seconds.
  void holdOnBeat(Deck follower, {bool snap = false}) {
    _lock?.cancel();
    final m = other(follower);
    final seen = <int>[];
    final began = DateTime.now();
    var moved = 0;
    var lastMove = began;
    var lastBend = began;
    var settleUntil = began;
    // The first settled reading tells how late the engine was to start; the first
    // after a jump, how far short the jump landed. Both are learned for next time.
    var firstReading = true;
    var afterJump = false;
    var saidLost = false;
    _lock = Timer.periodic(const Duration(milliseconds: 50), (t) async {
      if (!follower.playing || !m.playing || !identical(other(follower), m)) {
        t.cancel();
        // One of them stopped: the follower goes back to its own pitch, and what was
        // held is written down, as when a mix lets go.
        if (identical(_lock, t)) unawaited(letGo());
        return;
      }
      // The pitch it is held about, read afresh: SYNC matches it again when the
      // other deck's tempo moves.
      final base = follower.pitch;
      final ft = follower.timing, mt = m.timing;
      if (ft == null || mt == null || m.braking || m.loopStart != null) return;
      // The engines' first reports after a start, or a jump, are the least reliable
      // they give.
      if (DateTime.now().difference(began) < const Duration(milliseconds: 600)) return;
      if (DateTime.now().isBefore(settleUntil)) return;
      final now = DateTime.now();
      final e = beatError(
        follower: ft,
        followerAt: follower.positionAt(now),
        followerRate: follower.tempo,
        master: mt,
        masterAt: m.positionAt(now),
        masterRate: m.tempo,
      );
      if (e == null) return;
      // What is heard rather than what is reported: each deck's stretcher delay,
      // which the engine counts as if it ran at 1.0, puts its sound that delay times
      // (1 - speed) *ahead* of where it says it is. Measured on the real engine (the
      // probe, three pitchings of the master): 48 ms per unit of speed between the two
      // decks at 44.1 kHz — Rubber Band's 2048 samples — and the sign this way round.
      // Less where a hand has trimmed it: held that much ahead, by ear.
      final heard = e.inMicroseconds -
          (mixer.stretchLatency(follower).inMicroseconds * (follower.tempo - 1)).round() +
          (mixer.stretchLatency(m).inMicroseconds * (m.tempo - 1)).round() -
          follower.syncTrim.inMicroseconds;
      seen.add(heard);
      if (seen.length > 5) seen.removeAt(0);
      if (seen.length < 3) return;
      final sorted = [...seen]..sort();
      final err = Duration(microseconds: sorted[sorted.length ~/ 2]);
      final ms = err.inMicroseconds / 1000;
      _held.add(ms.abs());
      if (_trace) {
        debugPrint('lock: ${DateTime.now().difference(began).inMilliseconds} '
            'err ${ms.toStringAsFixed(1)} rate ${follower.tempo.toStringAsFixed(4)} '
            'base ${base.toStringAsFixed(4)}');
      }
      if (firstReading) {
        firstReading = false;
        // Behind by this much from the start: the engine takes that long to make a
        // sound after it is told to play. The next mix starts it that much sooner.
        _startLead = Duration(
            microseconds: (_startLead.inMicroseconds - err.inMicroseconds * 0.8)
                .round()
                .clamp(0, 300000));
        onLearned?.call();
        if (_trace) {
          debugPrint('lock: first reading ${ms.toStringAsFixed(1)} ms; '
              'next start ${_startLead.inMilliseconds} ms early');
        }
      } else if (afterJump) {
        afterJump = false;
        // A jump stops the sound for a moment, so it lands short by about that much:
        // the next one goes that much further.
        _jumpCarry = Duration(
            microseconds: (_jumpCarry.inMicroseconds - err.inMicroseconds * 0.7)
                .round()
                .clamp(-20000, 120000));
        onLearned?.call();
        if (_trace) {
          debugPrint('lock: after the jump ${ms.toStringAsFixed(1)} ms; '
              'next jump ${_jumpCarry.inMilliseconds} ms further');
        }
      }
      final l = levelsFor(crossfader, full: fullLaw);
      final share = identical(follower, a) ? l.a : l.b;
      final heardNow = share >= 0.25;
      // Twice at most while it cannot be heard: the first reading after a start is
      // the engine's least reliable, and a jump can land a little short.
      final quiet = (moved < 2 && ms.abs() > 20 && !heardNow) ||
          (snap && moved == 0 && ms.abs() > 40);
      // Lost the beat entirely — but *only* while nothing can hear it.
      //
      // This used to fire whatever the fader was doing, and it is the stutter. A jump
      // is a seek, and a seek is a hole in the sound. An error the bend cannot clear
      // inside a second — anything past about 40 ms, where the bend saturates at 6% —
      // met this rule a second later, jumped, landed short (a jump always does, which
      // is what _jumpCarry is for), and met it again a second after that. A record
      // that would not settle was therefore seeked once a second, out loud, for as
      // long as it played.
      //
      // The bend alone clears 60 ms a second at its 6% limit, so even half a beat is
      // gone in four seconds without a sound. That is slower than a jump and worth it:
      // nobody hears four seconds of a beat easing into place, and everybody hears one
      // seek.
      final lost = ms.abs() > 150 &&
          !heardNow &&
          now.difference(lastMove) > const Duration(seconds: 1);
      // Said once, so a record that will not settle while it is playing is something
      // the log knows about rather than something only the bend quietly fights.
      if (!saidLost && heardNow && ms.abs() > 150 &&
          now.difference(began) > const Duration(seconds: 6)) {
        saidLost = true;
        note(BoothEventKind.trouble,
            '${follower.name} is ${ms.round()} ms off and being bent back, not jumped',
            deck: follower);
      }
      if (quiet || lost) {
        // Too far to bend in time: moved, once, while it is still quiet — or
        // whenever it is so far out that it is two records rather than one.
        moved++;
        lastMove = now;
        settleUntil = now.add(const Duration(seconds: 1));
        seen.clear();
        afterJump = true;
        // Aimed that much further on, whichever way it goes: a seek stops the sound for
        // a moment while the other record plays on, so it always lands late — a jump
        // back as much as one forward. (Aimed "further" in the jump's own direction, a
        // jump back overshot by twice that.)
        final jump = -err.inMicroseconds + _jumpCarry.inMicroseconds;
        // Said in the log, always: a jump is the one thing the holding does that can be
        // heard, and "it twitched" is only something to work with if there is a when.
        debugPrint('booth: ${follower.name} jumped ${(jump / 1000).toStringAsFixed(0)} ms to the beat '
            '(${quiet ? snap && share >= 0.25 ? 'SYNC pressed' : 'while quiet' : 'lost the beat by ${ms.toStringAsFixed(0)} ms'})');
        await follower.nudge(Duration(microseconds: (jump * follower.tempo).round()));
        return;
      }
      // No learning of the rate: the grids give it to a few hundredths of a percent,
      // and every way of learning it on the real engine learned something wrong —
      // from the catch-up after a start, a rate 0.12 % off that walked the two 16 ms
      // apart over twenty seconds. The bend alone holds a grid that is slightly out
      // to a couple of milliseconds.
      // Inside a few milliseconds is in step: the engines' own clocks are no finer,
      // and chasing their noise would be the rate twitching for nothing.
      final want = ms.abs() < 3 ? base : (base * bendFor(err)).clamp(0.5, 2.0);
      // At most five changes of rate a second: each is a message to the engine, and
      // a rate that changes every twentieth of a second is a rate that warbles.
      if ((want - follower.tempo).abs() > 0.0008 &&
          now.difference(lastBend) >= const Duration(milliseconds: 200)) {
        lastBend = now;
        await follower.bend(want);
      }
      _lockBase = base;
    });
    _lockBase = follower.pitch;
    _lockFollower = follower;
  }

  double? _lockBase;
  Deck? _lockFollower;

  /// How much sooner than the beat a record is told to play, so that it sounds on
  /// it: the engine's own start-up time, learned from each mix's first reading.
  Duration _startLead = Duration.zero;

  /// Told when [_startLead] or [_jumpCarry] has been learned again, so whoever keeps
  /// the app's settings can keep these too: forgotten at every start, the first mix and
  /// the first SYNC of every session were fifty milliseconds out while they relearned
  /// this machine's engine. The booth never writes anything itself.
  void Function()? onLearned;

  /// What has been learned about this machine's engine, to keep.
  ({Duration startLead, Duration jumpCarry}) get learned =>
      (startLead: _startLead, jumpCarry: _jumpCarry);

  /// What was learned in an earlier session.
  void restoreLearned({required Duration startLead, required Duration jumpCarry}) {
    _startLead = Duration(microseconds: startLead.inMicroseconds.clamp(0, 300000));
    _jumpCarry = Duration(microseconds: jumpCarry.inMicroseconds.clamp(-20000, 120000));
  }

  /// How much further than the gap a quiet jump goes, for the moment a seek stops
  /// the sound: learned from the reading after each jump.
  Duration _jumpCarry = Duration.zero;

  @visibleForTesting
  Duration get startLead => _startLead;

  /// How far apart the two were, each time it was measured while held: what the
  /// log says afterwards, so "it did not sound in step" can be a number.
  final _held = <double>[];

  /// Stop holding, and put the follower's engine back at the deck's own pitch.
  Future<void> letGo() async {
    _lock?.cancel();
    _lock = null;
    if (_held.isNotEmpty) {
      final sorted = [..._held]..sort();
      note(BoothEventKind.held,
          'Beats held within ${sorted[(sorted.length * 0.9).floor()].toStringAsFixed(0)} ms',
          deck: _lockFollower);
      debugPrint('booth: held in step — half the time within '
          '${sorted[sorted.length ~/ 2].toStringAsFixed(1)} ms, nine tenths within '
          '${sorted[(sorted.length * 0.9).floor()].toStringAsFixed(1)} ms, worst '
          '${sorted.last.toStringAsFixed(1)} ms; settled at ${_lockBase?.toStringAsFixed(4)}×');
      _held.clear();
    }
    final f = _lockFollower, base = _lockBase;
    _lockFollower = null;
    _lockBase = null;
    if (f != null && base != null && (f.tempo - f.pitch).abs() > 1e-6) await f.bend(f.pitch);
  }

  /// Whether a follower is being held on the master's beat.
  bool get holding => _lock != null;

  /// Wait until the master reaches [at] in its record, by the wall clock at its rate —
  /// closely: slept most of the way, then the last stretch measured again, because a
  /// timer is late by however busy the machine is.
  Future<void> _until(Deck master, Duration at, {bool Function()? stop}) async {
    for (var i = 0; i < 50; i++) {
      if (stop?.call() ?? false) return;
      final left = at - master.position;
      final wall = Duration(microseconds: (left.inMicroseconds / master.tempo).round());
      if (wall <= const Duration(milliseconds: 2)) return;
      await Future<void>.delayed(
          wall > const Duration(milliseconds: 120) ? wall - const Duration(milliseconds: 60) : wall);
    }
  }

  // ------------------------------------------------------------------ transitions
  /// What a transition does, as steps. Written down rather than performed straight
  /// away so it can be read, tested, and one day replayed.
  static List<MixStep> plan(Transition kind, {required String from, required String to}) {
    const off = DeckStep(eq: EqSet.flat, filter: 0);
    const noBass = DeckStep(eq: EqSet(low: EqSet.killed));
    // The bass held down for a build, the kick still there under it.
    const lessBass = DeckStep(eq: EqSet(low: -18));
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
        // Two bars, one, a half, a quarter, an eighth: each rung once round and then
        // halved, the last two shorter than a bar (onBars puts those on beats).
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass}),
          MixStep(0.45, crossfader: 0.45, decks: {to: flat}),
          MixStep(0.5, crossfader: 0.5, decks: {from: const DeckStep(loopBars: 2)}),
          MixStep(0.75, crossfader: 0.7, decks: {from: const DeckStep(loopBars: -1)}),
          MixStep(0.875, crossfader: 0.8, decks: {from: const DeckStep(loopBars: -1)}),
          MixStep(0.9375, crossfader: 0.88, decks: {from: const DeckStep(loopBars: -1)}),
          MixStep(0.96875, crossfader: 0.94, decks: {from: const DeckStep(loopBars: -1)}),
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
      case Transition.announce:
        // Voice first: the new record's alone, over the old record's beat with the old
        // voice gone — so there is one voice, and it is the new one. Half way the new
        // band comes up under it, the old bass goes, and the old record leaves.
        // The two voices hand over, rather than overlap, in the first bars.
        const onlyVoice = StemLevels(drums: 0, rest: 0);
        const noVoice = StemLevels(vocals: 0);
        return [
          MixStep(0, crossfader: 0.5, decks: {
            to: const DeckStep(stems: StemLevels(drums: 0, rest: 0, vocals: 0), eq: EqSet.flat),
            from: const DeckStep(stems: StemLevels.all),
          }),
          MixStep(0.12, decks: {
            to: const DeckStep(stems: onlyVoice),
            from: const DeckStep(stems: noVoice),
          }),
          MixStep(0.5, crossfader: 0.5, decks: {
            to: const DeckStep(stems: onlyVoice),
            from: const DeckStep(stems: noVoice),
          }),
          // The new band arrives with its drums, so the old drums go — handed over
          // from the step before, two bars of a thirty-two-bar move, with the old bass
          // killed alongside. (Left to 0.8, two drum stems played for a quarter of
          // the move; the probe read no doubled kicks only because the bass was off.)
          MixStep(0.56, decks: {
            to: const DeckStep(stems: StemLevels.all),
            from: const DeckStep(eq: EqSet(low: EqSet.killed), stems: StemLevels(vocals: 0, drums: 0)),
          }),
          MixStep(0.8, crossfader: 0.75, decks: {
            from: const DeckStep(filter: 0.5, stems: StemLevels(vocals: 0, drums: 0)),
          }),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, stems: StemLevels.all),
          }),
        ];
      case Transition.acapellaOut:
        // The old record's voice over the new record's intro: the old band goes first,
        // under the new one arriving, and the new voice waits for the old to finish.
        const onlyVoice = StemLevels(drums: 0, rest: 0);
        return [
          MixStep(0, crossfader: 0, decks: {
            to: const DeckStep(stems: StemLevels(vocals: 0), eq: EqSet(low: EqSet.killed)),
            from: const DeckStep(stems: StemLevels.all),
          }),
          MixStep(0.25, crossfader: 0.5, decks: {
            to: const DeckStep(eq: EqSet.flat),
            from: const DeckStep(stems: StemLevels(vocals: 1, rest: 0.5, drums: 0)),
          }),
          MixStep(0.45, decks: {from: const DeckStep(stems: onlyVoice)}),
          MixStep(0.8, crossfader: 0.5, decks: {
            from: const DeckStep(stems: onlyVoice),
            to: const DeckStep(stems: StemLevels(vocals: 0)),
          }),
          MixStep(0.92, crossfader: 1, decks: {
            to: const DeckStep(stems: StemLevels.all),
          }),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, stems: StemLevels.all),
          }),
        ];
      case Transition.stemBlend:
        // One stem at a time, never two of a kind: new drums under the old record; the
        // old drums hand over; the new bass and the rest come up as the old go; the
        // old voice out before the new one comes in.
        // Each handover is quick — two bars of a thirty-two-bar move — so that two
        // kicks, or two basslines, are never long together; the voices alone are
        // faded, the old out before the new comes in.
        const none = StemLevels(drums: 0, rest: 0, vocals: 0);
        return [
          MixStep(0, crossfader: 0.5, decks: {
            to: const DeckStep(stems: none, eq: EqSet.flat),
            from: const DeckStep(stems: StemLevels.all),
          }),
          MixStep(0.19, decks: {
            to: const DeckStep(stems: none),
            from: const DeckStep(stems: StemLevels.all),
          }),
          MixStep(0.25, decks: {
            to: const DeckStep(stems: StemLevels(drums: 1, rest: 0, vocals: 0)),
            from: const DeckStep(stems: StemLevels(drums: 0)),
          }),
          MixStep(0.44, decks: {
            to: const DeckStep(stems: StemLevels(drums: 1, rest: 0, vocals: 0)),
            from: const DeckStep(stems: StemLevels(drums: 0)),
          }),
          MixStep(0.5, decks: {
            to: const DeckStep(stems: StemLevels(drums: 1, rest: 1, vocals: 0)),
            from: const DeckStep(stems: StemLevels(drums: 0, rest: 0)),
          }),
          // The fader sits in the middle — both whole, by the full law — until the old
          // record has nothing left; only then does it go across. Travelled from the
          // first step to the last, it had the old record 8 dB down by half way, with
          // its bass and voice still to give.
          MixStep(0.7, crossfader: 0.5, decks: {
            from: const DeckStep(stems: none),
          }),
          MixStep(0.9, crossfader: 1, decks: {to: const DeckStep(stems: StemLevels.all)}),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, stems: StemLevels.all),
          }),
        ];
      case Transition.dropSwap:
        // The old record builds and is taken away on the one; the new record is there
        // underneath, bass off, and drops exactly as the old one is gone.
        // The new record waits with its bass down — down, not off: a full kill took
        // 10 dB off a bass-heavy record for the whole wait, and with its mid pulled
        // 12 dB and low-passed at 3 kHz as well, and the old record high-passed to
        // 4 kHz from half way, the eight bars before the drop were a 20 dB hole. The
        // thinning is the last quarter's: the old record whole under the new one's
        // build until then, then caught in a loop and sent up through the filter.
        return [
          MixStep(0, crossfader: 0, decks: {
            to: lessBass,
            from: const DeckStep(filter: 0),
          }),
          MixStep(0.5, crossfader: 0.5, decks: {from: const DeckStep(filter: 0.15)}),
          MixStep(0.75, crossfader: 0.65, decks: {
            from: const DeckStep(filter: 0.4, loopBars: 1),
          }),
          MixStep(0.875, decks: {from: const DeckStep(filter: 0.55, loopBars: -1)}),
          MixStep(0.95, crossfader: 0.75, decks: {from: const DeckStep(filter: 0.7, loopBars: -1)}),
          MixStep(1, crossfader: 1, decks: {
            to: const DeckStep(eq: EqSet.flat, filter: 0),
            from: const DeckStep(eq: EqSet.flat, filter: 0, loopBars: 0),
          }),
        ];
      case Transition.echoOut:
        // The new record under the old; the old record's echo opened over its last
        // bars; on the one the record itself goes and the echo's tail is left under
        // the new record, the fader finishing over it.
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass}),
          MixStep(0.5, crossfader: 0.5, decks: {to: flat, from: noBass}),
          // The record goes at three quarters, the tail ringing over the last quarter:
          // gone at 0.9 of eight bars, the deck was stopped under it a bar later with
          // the echo still going.
          MixStep(0.625, crossfader: 0.6, decks: {from: const DeckStep(echo: 0.35, dry: 1)}),
          MixStep(0.75, crossfader: 0.6, decks: {from: const DeckStep(echo: 0.6, dry: 1)}),
          MixStep(0.78, crossfader: 0.6, decks: {from: const DeckStep(echo: 0, dry: 0)}),
          MixStep(0.875, crossfader: 0.75),
          MixStep(1, crossfader: 1, decks: {from: const DeckStep(eq: EqSet.flat, filter: 0, echo: 0, dry: 1)}),
        ];
      case Transition.loopBuild:
        // Four bars, two, one, the filter climbing all the while and the new record
        // waiting underneath with its bass off — and on the one it drops.
        return [
          MixStep(0, crossfader: 0, decks: {
            to: lessBass,
            from: const DeckStep(filter: 0),
          }),
          MixStep(0.5, crossfader: 0.5, decks: {from: const DeckStep(filter: 0.15, loopBars: 4)}),
          MixStep(0.75, crossfader: 0.65, decks: {from: const DeckStep(filter: 0.4, loopBars: -1)}),
          MixStep(0.875, crossfader: 0.7, decks: {from: const DeckStep(filter: 0.55, loopBars: -1)}),
          MixStep(0.9375, crossfader: 0.75, decks: {from: const DeckStep(filter: 0.7, loopBars: -1)}),
          MixStep(1, crossfader: 1, decks: {
            to: const DeckStep(eq: EqSet.flat, filter: 0),
            from: const DeckStep(eq: EqSet.flat, filter: 0, loopBars: 0),
          }),
        ];
      case Transition.breakSwap:
        // The old record's breakdown is the transition: the new record comes in over
        // it and drops on the one where the old would have. A breakdown has no drums,
        // so the new record's build is not fighting a kick: it comes in whole but for
        // its bass over the first bars, both records whole by the full law (held back
        // to half the fader and bass off for the whole breakdown, the new record was
        // 13 dB under what it had to give), takes the bass over at 0.6, and the old
        // record leaves through the filter as the drop lands.
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass}),
          MixStep(0.3, crossfader: 0.5),
          MixStep(0.6, crossfader: 0.5, decks: {to: flat, from: noBass}),
          MixStep(0.9, crossfader: 0.7, decks: {from: const DeckStep(filter: 0.4)}),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
      case Transition.filterRide:
        // Both ways at once, long: the old record climbs out through the high-pass
        // while the new one opens up through the low-pass, the basses swapped in the
        // middle.
        // The incoming has to be heard arriving: under a low-pass closed to 350 Hz
        // with its bass killed as well it was silent for half the move. So the
        // low-pass starts a little more open (about 1.2 kHz: the record muffled, as a
        // filter-in sounds) with the bass off, and the bass is let back over the last
        // bars before the swap as the low-pass opens — not before, or two kicks share
        // the room for a quarter of the move.
        return [
          MixStep(0, crossfader: 0, decks: {
            from: const DeckStep(filter: 0),
            to: const DeckStep(filter: -0.5, eq: EqSet(low: EqSet.killed)),
          }),
          MixStep(0.4, crossfader: 0.4, decks: {
            from: const DeckStep(filter: 0.25),
            to: const DeckStep(filter: -0.4, eq: EqSet(low: -12)),
          }),
          MixStep(0.5, crossfader: 0.5, decks: {
            from: const DeckStep(filter: 0.35, eq: EqSet(low: EqSet.killed)),
            to: const DeckStep(filter: -0.3, eq: EqSet.flat),
          }),
          MixStep(0.85, crossfader: 0.85, decks: {
            from: const DeckStep(filter: 0.8),
            to: const DeckStep(filter: 0),
          }),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
      case Transition.riser:
        // The sound does the work, so the records are left alone: the old one whole
        // under the climb until the last bars, when it leaves through the filter; the
        // new one held *right* back — bass killed, barely on the fader — until the
        // one, when it takes the room and the hit lands on it. The riser has just
        // stopped dead, and the silence it leaves is what the drop falls into.
        //
        // Held back that far on purpose. A riser is not a blend with a noise over it:
        // the incoming waiting at a third of the fader with its bass merely *down* put
        // two kicks against each other for seven and a half seconds of a sixteen-bar
        // move (the probe's drums_doubled_s), which is the one thing a build must not
        // do — the whole point of a build is that there is one beat under it.
        return [
          MixStep(0, crossfader: 0, decks: {
            to: noBass,
            from: const DeckStep(filter: 0),
          }, fx: const FxShot(FxSound.riser, span: 1, gainDb: -13)),
          MixStep(0.75, crossfader: 0.12, decks: {from: const DeckStep(filter: 0.2)}),
          MixStep(0.94, crossfader: 0.3, decks: {from: const DeckStep(filter: 0.55)}),
          MixStep(1, crossfader: 1, decks: {
            to: const DeckStep(eq: EqSet.flat, filter: 0),
            from: const DeckStep(eq: EqSet.flat, filter: 0),
          }, fx: const FxShot(FxSound.impact, beats: 8, gainDb: -15)),
        ];
      case Transition.noiseSweep:
        // A blend with a whoosh over its middle: the sweep rises into the bass swap
        // half way — the moment of a blend anybody can hear — and the second falls
        // away behind it over the rest.
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass},
              fx: const FxShot(FxSound.sweepUp, span: 0.5, gainDb: -14)),
          MixStep(0.5, crossfader: 0.5, decks: {to: flat, from: noBass},
              fx: const FxShot(FxSound.sweepDown, span: 0.5, gainDb: -16)),
          MixStep(0.85, crossfader: 0.85, decks: {
            from: const DeckStep(eq: EqSet(low: EqSet.killed, high: EqSet.killed)),
          }),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
      case Transition.hydrant:
        // The wash arches over the whole move, and the records are thinned at the top
        // underneath it while it is loudest — the noise stands where their highs were,
        // so the swap happens in a band of the spectrum that is already full.
        //
        // Its gain is set by what it is *for*. A sound that has to cover a join has to
        // be heard against the records: the probe's fx_db reads how far under them the
        // booth's own sound sits at its loudest, and this wants to be within about
        // eight decibels. A sound that only decorates one — the sweeps — can sit
        // twelve or fifteen under and still be the thing everybody notices.
        return [
          MixStep(0, crossfader: 0, decks: {to: noBass},
              fx: const FxShot(FxSound.hydrant, span: 1, gainDb: -11)),
          MixStep(0.3, crossfader: 0.3, decks: {from: const DeckStep(eq: EqSet(high: -9))}),
          MixStep(0.5, crossfader: 0.5, decks: {
            to: flat,
            from: const DeckStep(eq: EqSet(low: EqSet.killed, high: -12)),
          }),
          MixStep(0.8, crossfader: 0.85, decks: {
            from: const DeckStep(eq: EqSet(low: EqSet.killed, high: EqSet.killed)),
          }),
          MixStep(1, crossfader: 1, decks: {from: off}),
        ];
      case Transition.dissolve:
        // Not an ending: a disappearance. The send is opened over the whole move and
        // the record's own sound given up a fifth at a time through a low-pass that
        // closes with it, so that what is being faded is less and less of a record and
        // more and more of its echo. The dry goes at 0.93 and the tail does the rest.
        return [
          MixStep(0, crossfader: 0, decks: {
            to: noBass,
            from: const DeckStep(echo: 0.15, dry: 1, filter: 0),
          }),
          // Its bottom goes first, with the send: a record that is evaporating has no
          // business still putting a kick against the one coming in (three and a half
          // seconds of two kicks, before it did).
          MixStep(0.4, crossfader: 0.4, decks: {
            from: const DeckStep(echo: 0.45, dry: 0.85, filter: -0.25, eq: EqSet(low: EqSet.killed)),
          }),
          MixStep(0.65, crossfader: 0.6, decks: {
            to: flat,
            from: const DeckStep(echo: 0.7, dry: 0.5, filter: -0.5),
          }),
          MixStep(0.85, crossfader: 0.8, decks: {
            from: const DeckStep(echo: 0.8, dry: 0.15, filter: -0.7),
          }),
          MixStep(0.93, crossfader: 0.9, decks: {from: const DeckStep(echo: 0, dry: 0)}),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, echo: 0, dry: 1),
          }),
        ];
      case Transition.lunarEcho:
        // The old record falls out of the mix. Its bass goes half way, the send opens,
        // and over the last quarter it is pulled five semitones down — eased, not
        // dropped — while the low-pass closes over it. At 0.88 the record itself is
        // gone and its echo, pitched where it was left, rings under the new one.
        return [
          MixStep(0, crossfader: 0, decks: {
            to: noBass,
            from: const DeckStep(echo: 0.2, dry: 1, shift: 0, filter: 0),
          }),
          MixStep(0.5, crossfader: 0.5, decks: {
            to: flat,
            from: const DeckStep(echo: 0.45, dry: 1, shift: 0, eq: EqSet(low: EqSet.killed)),
          }),
          MixStep(0.75, crossfader: 0.65, decks: {
            from: const DeckStep(echo: 0.75, dry: 1, shift: -2, filter: -0.2),
          }),
          MixStep(0.88, crossfader: 0.75, decks: {
            from: const DeckStep(echo: 0.85, dry: 0, shift: -5, filter: -0.45),
          }),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, echo: 0, dry: 1, shift: 0),
          }),
        ];
      case Transition.tremolo:
        // The old record is chopped away rather than faded away. The gate opens on
        // eighths a quarter of the way in and deepens; at three quarters it doubles to
        // sixteenths, by which point there is more gap than record and the new one is
        // filling every one of them. Its bass goes half way, as in any blend, so that
        // what is being chopped is not a kick.
        return [
          MixStep(0, crossfader: 0, decks: {
            to: noBass,
            from: const DeckStep(gate: 0, gateDiv: 2),
          }),
          MixStep(0.25, crossfader: 0.25, decks: {from: const DeckStep(gate: 0.5)}),
          MixStep(0.5, crossfader: 0.5, decks: {
            to: flat,
            from: const DeckStep(gate: 0.8, eq: EqSet(low: EqSet.killed)),
          }),
          MixStep(0.75, crossfader: 0.7, decks: {from: const DeckStep(gate: 0.95, gateDiv: 4)}),
          MixStep(0.9, crossfader: 0.88, decks: {from: const DeckStep(filter: 0.35)}),
          MixStep(1, crossfader: 1, decks: {
            from: const DeckStep(eq: EqSet.flat, filter: 0, gate: 0, gateDiv: 2),
          }),
        ];
      case Transition.swap:
        // The drums change hands. Each swap is a load, so each one happens where
        // there is another record over it: the first under the outgoing at full
        // level, the second under the outgoing's last bars. Nothing swaps in the
        // clear, and nothing ever plays two sets of drums at once.
        return [
          MixStep(0, crossfader: 0, decks: {to: const DeckStep(part: 'drums', eq: EqSet.flat)}),
          MixStep(0.4, crossfader: 0.4, decks: {from: const DeckStep(part: 'music')}),
          MixStep(0.7, crossfader: 0.75, decks: {
            to: const DeckStep(part: DeckStep.whole, eq: EqSet.flat),
          }),
          MixStep(1, crossfader: 1, decks: {from: const DeckStep(eq: EqSet.flat, filter: 0)}),
        ];
    }
  }

  /// Where the fader is at [k] of a plan: travelled evenly between the steps that
  /// set it; a step that says nothing of it leaves it on its way. Before any, the
  /// first's; after the last, the last's.
  static double faderOf(List<MixStep> steps, double k) {
    MixStep? before, after;
    for (final s in steps) {
      if (s.crossfader == null) continue;
      if (s.at <= k) {
        before = s;
      } else {
        after ??= s;
      }
    }
    if (before == null) return after?.crossfader ?? 0;
    if (after == null) return before.crossfader!;
    final span = after.at - before.at;
    final local = span <= 0 ? 1.0 : ((k - before.at) / span).clamp(0.0, 1.0);
    return before.crossfader! + (after.crossfader! - before.crossfader!) * local;
  }

  /// Where a stem deck's levels should be at [k] of a plan, or null where the plan
  /// says nothing of them: moved evenly from the last step that set them to the next
  /// that does. The last step puts a deck's stems back for its next record, once the
  /// fader has taken it out: it is not moved towards, or the outgoing's voice and
  /// drums would come back up under the last bars of the mix.
  static StemLevels? stemsOf(List<MixStep> steps, String deck, double k) {
    MixStep? before, after;
    for (final st in steps) {
      if (st.decks[deck]?.stems == null) continue;
      if (st.at <= k) {
        before = st;
      } else {
        after ??= st;
      }
    }
    if (before == null) return null;
    final a = before.decks[deck]!.stems!;
    if (after == null || after.at >= 1) return a;
    final span = after.at - before.at;
    return a.lerpPower(after.decks[deck]!.stems!, span <= 0 ? 1 : ((k - before.at) / span).clamp(0.0, 1.0));
  }

  /// The clock a gate on [deck] runs on: how long one chop lasts and where the chops
  /// are counted from, both in the *record's* own time rather than the room's.
  ///
  /// The gate happens inside the engine, ahead of the stretcher, so it sees the record
  /// at the speed it was made — a record held 4% slow still has its own beat there.
  /// [Deck.beat] is the beat as it is heard, which is that one divided by the pitch.
  ({Duration period, Duration origin})? gateClock(Deck deck, int div) {
    final heard = deck.beat;
    if (heard == null || div <= 0) return null;
    final own = Duration(microseconds: (heard.inMicroseconds * deck.pitch).round());
    return (
      period: Duration(microseconds: own.inMicroseconds ~/ div),
      origin: deck.timing?.cues?.firstDownbeat ?? Duration.zero,
    );
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

  /// What the booth has been doing, newest last, and no more than [_kept] of it:
  /// the log beside the crate, so the automix is something you can watch think.
  final List<BoothEvent> events = [];
  static const _kept = 60;

  void note(BoothEventKind kind, String text, {Deck? deck}) {
    events.add(BoothEvent(kind, text, deck: deck?.name));
    if (events.length > _kept) events.removeRange(0, events.length - _kept);
    notifyListeners();
  }

  /// The transition running now, and how far through it (0 to 1): what the room draws
  /// its banner from. Null when nothing is.
  ({Transition kind, String from, String to, int bars, double k})? mixing;

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

  /// A mix asked for and waiting for its beat: which way, how, and when it starts —
  /// what the MIX button counts down. Null when nothing is waiting.
  ({Transition kind, String from, String to, DateTime startsAt})? arming;

  /// Each mix asked for gets a number; calling one off moves the number on, and a
  /// mix still waiting for its beat that wakes to find its number gone does nothing.
  int _asked = 0;

  /// What the caller of the mix running now is waiting on.
  Completer<void>? _done;

  /// A mix is waiting for its beat, or running.
  bool get busy => arming != null || _running != null;

  /// Line a parked deck's bars up with the master's — the tall rules on the strip.
  ///
  /// Matching tempo and beat leaves the two records on the same *beat* and says
  /// nothing about which beat: a record joined a bar and a half into the master's
  /// phrase is in time and in the wrong place, and every four-bar rule down the two
  /// strips passes the playhead at a different moment. This moves the parked one by
  /// whole bars, two at the most either way, so the rules line up.
  ///
  /// Only a parked deck. On one that is playing this is a seek, and a seek is a hole
  /// in the sound — the beat-holding eases a playing deck into place instead.
  Future<bool> meetThePhrase(Deck follower) async {
    final m = other(follower);
    if (follower.playing || !follower.loaded) return false;
    final was = follower.position;
    await _meetThePhrase(m, m.position, follower);
    final moved = follower.position != was;
    if (moved) {
      note(BoothEventKind.cue, '${follower.name} moved to meet ${m.name}\'s bars',
          deck: follower);
    }
    return moved;
  }

  /// Move [to], parked, so it has as many bars left to its next four-bar marker as
  /// [from] will have at [at] — by whole bars, two at the most either way, and never
  /// back past its first downbeat.
  Future<void> _meetThePhrase(Deck from, Duration at, Deck to) async {
    final ft = from.timing, tt = to.timing;
    final bar = tt?.bar;
    if (ft == null || tt == null || bar == null) return;
    final parked = to.position;
    final theirs = ft.placeInPhrase(at), mine = tt.placeInPhrase(parked);
    if (theirs == null || mine == null) return;
    // Forward by the difference in bars left: then both reach a marker together.
    var d = (mine.of - mine.bar) - (theirs.of - theirs.bar);
    if (d == 0) return;
    if (d > 2) d -= 4;
    if (d < -2) d += 4;
    var target = parked + bar * d;
    final first = tt.cues?.firstDownbeat ?? Duration.zero;
    if (target < first) target += bar * 4;
    debugPrint('booth: ${to.name} moved ${d > 0 ? 'on' : 'back'} ${d.abs()} bar${d.abs() == 1 ? '' : 's'} '
        'to meet ${from.name}\'s phrase (bar ${theirs.bar + 1} of ${theirs.of})');
    await to.seek(tt.onGrid(target));
  }

  /// From the master to the other deck, over [bars] of the master's bars. When it is
  /// done the other deck is the master.
  ///
  /// The incoming starts at [startAt] in the master's record where that is given —
  /// the downbeat the automix chose, to the millisecond — or otherwise on the
  /// master's next bar (the next beat, for a fade). Its tempo is matched again at that
  /// moment, and from then until the end it is held on the master's beat.
  ///
  /// One mix at a time. Asked again while one is waiting for its beat or running,
  /// this does nothing: pressing MIX three times while it waited for the phrase once
  /// started three mixes at the same moment, each moving the same fader, and a roll
  /// had its loop halved nine times over.
  ///
  /// [shift] plays the incoming so many semitones up or down at the same tempo, for
  /// the length of the record (the automix eases it back): a key made to fit.
  Future<void> go(Transition kind, {int bars = 16, Duration? startAt, double shift = 0}) async {
    if (busy) return;
    final from = master, to = other(master);
    if (!to.loaded) return;
    // A move made of the desk's echo, on an engine without one: the plain one instead.
    if (kind.needsFx && !mixer.canShift) {
      note(BoothEventKind.plan, '${kind.label} needs the desk\'s echo: ${kind.plainly.label} instead');
      kind = kind.plainly;
    }
    // And one made of the engine's chop, on an engine that cannot chop.
    if (kind.needsGate && !mixer.canGate) {
      note(BoothEventKind.plan, '${kind.label} needs the engine\'s chop: ${kind.plainly.label} instead');
      kind = kind.plainly;
    }
    // And one made of a sound the booth plays itself, where it can put one nowhere.
    if (kind.needsSound && !fx.can) {
      note(BoothEventKind.plan, '${kind.label} needs a sound of its own: ${kind.plainly.label} instead');
      kind = kind.plainly;
    }
    if (shift != 0 && mixer.canShift) await setPitchShift(to, shift);
    // A move made of stems, asked of a deck that is playing the whole record: the
    // blend it is a kind of, rather than a plan whose stems nothing can turn.
    if (kind.needsStems && !(from.stemmed && to.stemmed)) {
      note(BoothEventKind.plan, '${kind.label} needs both records in stems: a blend instead');
      kind = Transition.blend;
    }
    final ticket = ++_asked;
    bool calledOff() => ticket != _asked;
    // A mix does its own matching and holding, and after it the other record leads:
    // SYNC by hand is over.
    for (final d in decks) {
      d.synced = false;
      d.syncTrim = Duration.zero;
    }
    // Busy from this moment: the matching below is a wait of its own.
    arming = (kind: kind, from: from.name, to: to.name, startsAt: DateTime.now());

    // Matched again now, from where both records actually are — whatever the
    // transition, a fade too: two records laid over each other out of step is the one
    // thing nobody forgives.
    final synced = from.hasBeats && to.hasBeats && await sync(to, reach: bridgeReach);
    if (calledOff()) return;

    // When it goes: the automix's chosen downbeat, or the master's next bar.
    final every = kind == Transition.fade ? 1 : 4;
    final now = DateTime.now();
    final precise = startAt != null && from.playing && startAt > from.position;
    final wait = precise
        ? Duration(microseconds: ((startAt - from.position).inMicroseconds / from.tempo).round())
        : (from.untilNextBeat(now, every: every) ?? Duration.zero);
    arming = (kind: kind, from: from.name, to: to.name, startsAt: now.add(wait));
    notifyListeners();
    // Phrase to phrase: the incoming starts as many bars short of its next four-bar
    // marker as the outgoing will be of its own, so the two records' phrases turn
    // over together for the whole of the mix. The automix parks the one on a marker
    // and goes on the other's, and this moves nothing; a mix by hand, or one that went
    // late, is put right here, by two bars at the most. Not a cut, which starts the
    // record where it was cued.
    if (synced && every == 4 && kind != Transition.cut && !to.playing) {
      final goes = precise
          ? startAt
          : from.position + Duration(microseconds: (wait.inMicroseconds * from.tempo).round());
      await _meetThePhrase(from, goes, to);
      if (calledOff()) return;
    }

    final steps = kind == Transition.cut
        ? const <MixStep>[]
        : MixStep.onBars(plan(kind, from: from.name, to: to.name), bars);
    // The booth's own sounds, rendered and loaded *now*, while there is still a bar
    // to wait: a sixteen-second riser is a second or two of arithmetic and a file to
    // hand an engine, and a riser that arrives a beat late is worse than none.
    // [fxSlot] is which loaded sound each step fires, by step.
    final fxSlot = <int, int>{};
    if (steps.any((s) => s.fx != null)) {
      final move = barsLength(from, bars);
      final beat = from.beat ?? const Duration(milliseconds: 500);
      final wanted = <({FxShot shot, double seconds})>[];
      for (var i = 0; i < steps.length; i++) {
        final shot = steps[i].fx;
        if (shot == null) continue;
        fxSlot[i] = wanted.length;
        wanted.add((shot: shot, seconds: shot.lengthIn(move, beat).inMicroseconds / 1e6));
      }
      final loaded = await fx.load(wanted, beat: beat.inMicroseconds / 1e6,
          volume: mixer.playerVolume);
      fxSlot.removeWhere((_, slot) => slot >= loaded);
    }
    // What the plan opens with, set before the incoming makes a sound.
    if (steps.isNotEmpty) await _applyStep(steps.first);
    if (!to.playing) {
      // Told to play a little before the beat, by as long as the engine has lately
      // taken to make a sound: then the sound lands on it.
      final lead = _startLead;
      if (precise) {
        final early = Duration(microseconds: (lead.inMicroseconds * from.tempo).round());
        await _until(from, startAt - early, stop: calledOff);
      } else if (wait - lead > Duration.zero) {
        await Future<void>.delayed(wait - lead);
      }
    }
    if (calledOff()) {
      // Called off while it waited: the incoming is left as it was, flat and parked.
      if (steps.isNotEmpty) await _applyStep(MixStep(0, decks: {to.name: const DeckStep(eq: EqSet.flat)}));
      await fx.silence();
      return;
    }
    final parkedAt = to.position;
    if (!to.playing) await to.play();
    // And if it did not start, nothing is handed over: fading out of a record into
    // a deck that is not playing is fading out into silence.
    if (!_reallyPlaying(to)) {
      arming = null;
      if (steps.isNotEmpty) await _applyStep(MixStep(0, decks: {to.name: const DeckStep(eq: EqSet.flat)}));
      await fx.silence();
      notifyListeners();
      return;
    }

    // Written down as it starts, from where each record is.
    if (from.track != null && to.track != null) {
      taken.add(MixMove(
        from: from.track!.id,
        to: to.track!.id,
        kind: kind,
        bars: bars,
        outMs: (startAt ?? from.position).inMilliseconds,
        inMs: parkedAt.inMilliseconds,
        tempo: to.pitch,
      ));
    }

    if (kind == Transition.cut) {
      arming = null;
      await setCrossfader(identical(to, b) ? 1 : 0);
      await from.pause();
      master = to;
      note(BoothEventKind.done, 'Cut to ${to.name} on the one', deck: to);
      return;
    }

    final length = barsLength(from, bars);
    debugPrint('booth: ${kind.name} over $bars bars into "${to.track?.title}" — '
        '${synced ? 'in step: ${to.bpm?.toStringAsFixed(2)} against ${from.bpm?.toStringAsFixed(2)} bpm' : 'not in step'}');
    if (synced) {
      await mixer.measureLatency(from);
      await mixer.measureLatency(to);
      holdOnBeat(to);
    }
    note(BoothEventKind.mix, '${from.name} into ${to.name} · ${kind.name}, $bars bars', deck: to);
    mixing = (kind: kind, from: from.name, to: to.name, bars: bars, k: 0.0);

    // Waiting is over and running begins, with nothing awaited in between: there is
    // no moment at which a second MIX finds the booth free.
    arming = null;
    fullLaw = kind.full;
    final began = DateTime.now();
    final done = Completer<void>();
    _done = done;
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
    // it, because a sweep in four jumps is four jumps rather than a sweep. Travelled
    // between the steps that *set* it: a step that only turns a stem or a band says
    // nothing about the fader, and it stays on its way. (Read as 0 and 1, such steps
    // sent the fader sawing up and down through every stem move.)
    double faderAt(double k) {
      final x = faderOf(steps, k);
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

    /// And the pitch shift, the same way: read backwards for the last value set, so a
    /// leg that says nothing of it leaves it where it was.
    double? shiftAt(String deck, double k) {
      final leg = legAt(k);
      double? lastBefore(MixStep at) {
        for (var i = steps.indexOf(at); i >= 0; i--) {
          final v = steps[i].decks[deck]?.shift;
          if (v != null) return v;
        }
        return null;
      }

      final a = lastBefore(leg.from);
      final b = leg.to.decks[deck]?.shift ?? a;
      if (a == null || b == null) return null;
      return a + (b - a) * leg.local;
    }

    /// The gate's depth, travelled like the filter; its rate is held, like a band.
    double? gateAt(String deck, double k) {
      final leg = legAt(k);
      double? lastBefore(MixStep at) {
        for (var i = steps.indexOf(at); i >= 0; i--) {
          final v = steps[i].decks[deck]?.gate;
          if (v != null) return v;
        }
        return null;
      }

      final a = lastBefore(leg.from);
      final b = leg.to.decks[deck]?.gate ?? a;
      if (a == null || b == null) return null;
      return a + (b - a) * leg.local;
    }

    int gateDivAt(String deck, double k) {
      var div = 2;
      for (final st in steps) {
        if (st.at > k) break;
        final v = st.decks[deck]?.gateDiv;
        if (v != null) div = v;
      }
      return div;
    }

    StemLevels? stemsAt(String deck, double k) => stemsOf(steps, deck, k);

    /// The bands, travelled: a step's EQ is reached over the beat *before* the step
    /// rather than set on it. A kill was one command — forty decibels in a frame —
    /// and a bass swap two of them in the same tick; a knob is turned, over about a
    /// beat, and real mixes' EQ curves are gradual (Chen et al. 2022 learned them
    /// from DJ mixes and got ramps, not steps). Null where no step is coming.
    final beatK = 1 / (bars * 4);
    final eqWhenBegan = {for (final d in decks) d.name: eqOf(d)};
    EqSet? eqAt(String deck, double k) {
      EqSet? prev;
      MixStep? coming;
      for (final st in steps) {
        final e = st.decks[deck]?.eq;
        if (e == null) continue;
        if (st.at <= k) {
          prev = e;
        } else {
          coming = st;
          break;
        }
      }
      if (coming == null) return null;
      final start = coming.at - beatK;
      if (k < start) return null;
      return (prev ?? eqWhenBegan[deck] ?? EqSet.flat)
          .lerp(coming.decks[deck]!.eq!, (k - start) / beatK);
    }

    // The levels a stem plan opens with, on the incoming before it makes a sound.
    for (final deck in decks) {
      final open = stemsAt(deck.name, 0);
      if (open != null && deck.stemmed) await deck.setStemLevels(open, over: Duration.zero);
    }

    // A sound hung on the step at 0 goes now: that step was applied before the
    // incoming was even started, which is a bar too early to make a noise.
    if (fxSlot.containsKey(0)) unawaited(fx.fire(fxSlot[0]!));

    _running = Timer.periodic(const Duration(milliseconds: 40), (t) async {
      final k = (DateTime.now().difference(began).inMicroseconds / length.inMicroseconds)
          .clamp(0.0, 1.0);
      final m = mixing;
      if (m != null) mixing = (kind: m.kind, from: m.from, to: m.to, bars: m.bars, k: k);
      await setCrossfader(faderAt(k));
      for (final deck in decks) {
        final want = filterAt(deck.name, k);
        if (want != null && (filters[deck] ?? 0) != want) await setFilter(deck, want);
        final bands = eqAt(deck.name, k);
        if (bands != null && !bands.closeTo(eqOf(deck))) await setEq(deck, bands);
        final semis = shiftAt(deck.name, k);
        if (semis != null && mixer.canShift && ((_shift[deck] ?? 0) - semis).abs() > 0.02) {
          await setPitchShift(deck, semis);
        }
        final depth = gateAt(deck.name, k);
        if (depth != null && mixer.canGate) {
          final clock = gateClock(deck, gateDivAt(deck.name, k));
          if (clock != null) {
            await mixer.setGate(deck, depth: depth, period: clock.period, origin: clock.origin);
          }
        }
        final levels = stemsAt(deck.name, k);
        if (levels != null && deck.stemmed && !levels.closeTo(deck.stemLevels)) {
          await deck.setStemLevels(levels, over: Duration.zero);
        }
      }
      while (next < steps.length && k >= steps[next].at) {
        if (fxSlot.containsKey(next)) unawaited(fx.fire(fxSlot[next]!));
        await _applyStep(steps[next]);
        next++;
      }
      if (k >= 1) {
        t.cancel();
        _running = null;
        await letGo();
        mixing = null;
        note(BoothEventKind.done, '${to.name} has the room', deck: to);
        from.unloop();
        await from.pause();
        await setEq(from, EqSet.flat);
        await setFilter(from, 0);
        if (mixer.canGate) {
          await mixer.setGate(from,
              depth: 0, period: const Duration(milliseconds: 250), origin: Duration.zero);
        }
        await _plain(from);
        master = to;
        // The fader is across: the same levels under either law.
        fullLaw = false;
        _done = null;
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
    note(BoothEventKind.trouble, 'Deck ${deck.name} would not start', deck: deck);
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
      if (want.echo != null || want.dry != null) {
        final now = _echo[deck] ?? (send: 0.0, dry: 1.0);
        await setEcho(deck, send: want.echo ?? now.send, dry: want.dry ?? now.dry);
      }
      if (want.part != null) {
        final wanted = want.part == DeckStep.whole ? null : want.part;
        if (!deck.playing) {
          // Parked, so waiting costs nothing — and the right thing has to be on the
          // platter before the deck is started, not a moment after.
          await deck.swapTo(wanted);
        } else {
          // In the mix. A swap is a load, and a load cannot be waited for here
          // without the fader stopping with it: it is let go of, and the phase put
          // right when it lands.
          unawaited(deck.swapTo(wanted).then((done) {
            if (done && deck != master) align(deck);
          }));
        }
      }
    }
  }

  /// Stop the mix: one waiting for its beat is called off, one running stops where
  /// it is — and whatever was waiting for it to finish (the automix) is let go of
  /// rather than left waiting for ever.
  void stopTransition() {
    if (arming != null) {
      note(BoothEventKind.skip, 'Mix called off');
    } else if (_running != null) {
      note(BoothEventKind.skip, 'Mix stopped by hand');
    }
    final wasRunning = _running != null;
    _asked++;
    arming = null;
    _running?.cancel();
    _running = null;
    mixing = null;
    unawaited(letGo());
    // What the mix had done to the two channels is undone: stopped halfway, a blend
    // left the incoming with no bass and a sweep left the outgoing filtered — a knob
    // showing a kill nobody turned. The fader stays where it is: that is the room.
    if (wasRunning) {
      fullLaw = false;
      unawaited(_levels());
      for (final d in decks) {
        unawaited(setEq(d, EqSet.flat));
        unawaited(setFilter(d, 0));
        d.unloop();
        unawaited(_plain(d));
        // And the stems a stem move had turned: back to the part on the pads.
        if (d.stemmed) unawaited(d.setStemLevels(StemLevels.of(d.part)));
      }
    }
    final d = _done;
    _done = null;
    if (d != null && !d.isCompleted) d.complete();
    notifyListeners();
  }

  @override
  void dispose() {
    partsJobs.removeListener(_partsChanged);
    _running?.cancel();
    _lock?.cancel();
    unawaited(fx.dispose());
    auto.dispose();
    a.dispose();
    b.dispose();
    super.dispose();
  }
}
