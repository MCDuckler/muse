import 'dart:math' as math;

import '../../api/models.dart';
import 'automix.dart';
import 'booth.dart';
import 'set_planner.dart';

/// One record's side of a transition, as the planner sees it.
class MixSide {
  const MixSide({
    required this.timing,
    this.vocals,
    this.stems = false,
    this.pitch = 1,
    this.fx = false,
    this.position,
  });
  final TrackTiming timing;
  final VocalMap? vocals;

  /// Its stems are on its deck (or will be): a stem move can be made with it.
  final bool stems;
  final double pitch;

  /// Its deck has the desk's echo and pitch shift (Mixer.canShift).
  final bool fx;

  /// Where the record is now, for the outgoing: a place to go out that is already
  /// behind it is no place to go out.
  final Duration? position;
}

/// What the planner decided: the move, its length, where the old record goes out and
/// where the new one comes in (null: the ordinary places), the new record's key shift
/// in semitones (0: as made), and why — for the log.
class MixPlan {
  const MixPlan(this.kind, this.bars,
      {this.outAt, this.inAt, this.shift = 0, this.why = '', this.score = 0});
  final Transition kind;
  final int bars;
  final Duration? outAt, inAt;
  final double shift;
  final String why;
  final double score;

  /// The same move, told otherwise: by a hand steering the automix.
  MixPlan copyWith({int? bars, Duration? outAt, Duration? inAt, double? shift}) => MixPlan(
      kind, bars ?? this.bars,
      outAt: outAt ?? this.outAt,
      inAt: inAt ?? this.inAt,
      shift: shift ?? this.shift,
      why: why,
      score: score);

  @override
  String toString() =>
      '${kind.label} $bars bars${shift == 0 ? '' : ' ${shift > 0 ? '+' : ''}${shift.round()} st'} (${score.toStringAsFixed(2)}): $why';
}

/// How the booth is told to mix, as three dials rather than three words: how long a
/// move is, how wild, and how much two voices at once is minded. Each 0 to 1. (Where
/// the set's energy is meant to go is the fourth, kept with the set: EnergyArc.)
class StyleAxes {
  const StyleAxes({required this.length, required this.risk, required this.vocals});

  /// 0 short (8 bars) to 1 long (64).
  final double length;

  /// 0 safe (blends and sweeps) to 1 wild (drops, loops, echoes, a cappellas).
  final double risk;

  /// 0 never two voices at once, to 1 let them clash.
  final double vocals;

  /// The three words, as dials.
  static StyleAxes of(MixStyle style) => switch (style) {
        MixStyle.easy => const StyleAxes(length: 1.0, risk: 0.1, vocals: 0.0),
        MixStyle.normal => const StyleAxes(length: 0.6, risk: 0.5, vocals: 0.2),
        MixStyle.bold => const StyleAxes(length: 0.2, risk: 0.9, vocals: 0.5),
      };

  /// The bar counts a long move may have here, shortest first.
  List<int> get longOptions => length >= 0.8
      ? const [16, 32, 64]
      : length >= 0.4
          ? const [16, 32]
          : const [8, 16];

  /// A short move's length.
  int get short => length >= 0.4 ? 16 : 8;
}

/// Choosing the next transition the way a DJ would: first the *places* — where the
/// old record can be left (its outro, its own breakdown, the stretch it last sings)
/// and where the new one can be joined (its intro's end, its drop, its hook) — then
/// every *move* that can be made between them, each scored for how well it would go:
/// two voices at once is the clash anybody hears; a hook sung over the old record's
/// beat is the new record announcing itself; a drop is somewhere to land; a breakdown
/// is a transition the record wrote itself; an intro long enough is room for a long
/// blend. Then weighed by the dials (StyleAxes), against the moves just made, and
/// with a little chance in it, so that a set is not the same transition eleven times.
/// Two keys that would clash can be made to fit by shifting the new record a semitone
/// or two (the desk's Rubber Band), eased back once it leads.
class Planner {
  /// How much each move is liked before anything is known about the records, and
  /// whether it is a calm one (liked more the safer the dial) or a wild one.
  static const _likes = <Transition, (double, bool)>{
    Transition.blend: (0.8, true),
    Transition.stemBlend: (0.9, true),
    Transition.filterRide: (0.65, true),
    Transition.sweep: (0.6, true),
    Transition.fade: (0.3, true),
    Transition.announce: (0.9, false),
    Transition.acapellaOut: (0.75, false),
    Transition.dropSwap: (0.85, false),
    Transition.breakSwap: (0.9, false),
    Transition.loopBuild: (0.7, false),
    Transition.echoOut: (0.6, false),
    Transition.roll: (0.5, false),
    Transition.swap: (0.6, false),
    Transition.brake: (0.4, false),
  };

  static MixPlan plan({
    required MixSide from,
    required MixSide to,
    MixStyle style = MixStyle.normal,
    StyleAxes? axes,
    List<Transition> recent = const [],
    math.Random? random,
  }) =>
      options(from: from, to: to, style: style, axes: axes, recent: recent, random: random).first;

  /// Every move that can be made with these two, best first — what [plan] chooses
  /// from, and what a hand steering the automix is offered. Never empty.
  static List<MixPlan> options({
    required MixSide from,
    required MixSide to,
    MixStyle style = MixStyle.normal,
    StyleAxes? axes,
    List<Transition> recent = const [],
    math.Random? random,
  }) {
    final rng = random ?? math.Random();
    final dials = axes ?? StyleAxes.of(style);
    // What cannot be put in step, or has no grid, or fades itself (it goes out as it was
    // made), or stops dead on a cold ending in key: the old rules, right about those.
    final base = AutoMix.choose(from.timing, to.timing, style: style, fromPitch: from.pitch);
    if (base.kind == Transition.fade ||
        base.kind == Transition.cut ||
        !from.timing.hasBeats ||
        !to.timing.hasBeats) {
      return [MixPlan(base.kind, base.bars, why: 'the only way these two go together')];
    }
    final key = SetPlanner.keyMove(from.timing, to.timing);
    final inKey = !key.clash;
    // A clash a semitone or two of shift would mend, where the desk can shift.
    final mend = key.clash && to.fx ? _shiftToFit(from.timing, to.timing) : null;
    final stems = from.stems && to.stems;
    final candidates = <MixPlan>[];

    // Room, in bars: the new record's intro, the old record's outro.
    final intro = _bars(to.timing, to.timing.cues?.firstDownbeat, to.timing.cues?.mixIn);
    final outro = _bars(from.timing, from.timing.cues?.mixOut, from.timing.cues?.soundEnd);
    int longest(List<int> options, int room) =>
        options.where((b) => b <= math.max(room, options.first)).fold(options.first, math.max);

    /// One candidate: [fit] is how well the move itself goes; the dials, the clash of
    /// voices over the move, the keys, what was played lately and a little chance make
    /// the score. [designed] moves handle the voices themselves.
    void consider(Transition kind, int bars, double fit, String why,
        {Duration? outAt, Duration? inAt, bool designed = false, double shift = 0}) {
      final liked = _likes[kind];
      if (liked == null) return;
      final (like, calm) = liked;
      var score = like * (calm ? 0.4 + 0.6 * (1 - dials.risk) : 0.4 + 0.6 * dials.risk) * fit;
      final words = <String>[why];
      // Two voices at once, over this move's overlap — minded as much as the dial says.
      if (!designed) {
        final clash = _clash(from, to, bars, outAt: outAt, inAt: inAt);
        if (clash > 0) {
          score *= 1 - 0.55 * (1 - dials.vocals) * (clash / bars).clamp(0.0, 1.0);
          words.add('$clash bars of two voices');
        }
      }
      // Not the move just made, and less of one made lately.
      if (recent.isNotEmpty && recent.last == kind) score -= 0.4;
      if (recent.length > 1 && recent.sublist(math.max(0, recent.length - 4)).contains(kind)) {
        score -= 0.12;
      }
      // Two keys that clash are better out of the way quickly, through the filter, or
      // over drums alone — or mended by a shift, which costs a little of the sound.
      if (shift != 0) {
        score *= 0.9;
        words.add('${shift > 0 ? '+' : ''}${shift.round()} semitone${shift.abs() == 1 ? '' : 's'} to meet the key');
      } else if (!inKey &&
          kind != Transition.sweep &&
          kind != Transition.filterRide &&
          kind != Transition.dropSwap) {
        score -= 0.2;
      }
      if (key.boost && !designed && kind != Transition.sweep) words.add(key.why!);
      score += rng.nextDouble() * 0.22;
      candidates.add(MixPlan(kind, bars,
          outAt: outAt, inAt: inAt, shift: shift, why: words.join(' · '), score: score));
    }

    /// A move that a shift would mend, offered both ways: as made, and shifted.
    void considerMended(Transition kind, int bars, double fit, String why,
        {Duration? outAt, Duration? inAt}) {
      consider(kind, bars, fit, why, outAt: outAt, inAt: inAt);
      if (mend != null) consider(kind, bars, fit, why, outAt: outAt, inAt: inAt, shift: mend);
    }

    // The long ones, where there is room for them.
    final blendBars = longest(dials.longOptions, math.min(intro, outro));
    considerMended(Transition.blend, blendBars, 1, 'the ordinary blend');
    if (stems) {
      considerMended(
          Transition.stemBlend,
          longest(dials.length >= 0.4 ? const [32, 64] : const [16], math.min(intro, outro)),
          1,
          'stem by stem, nothing doubled');
    }
    consider(Transition.sweep, dials.short, inKey ? 0.8 : 1.1,
        inKey ? 'through the filter' : 'keys clash: out through the filter');
    if (math.min(intro, outro) >= 16) {
      consider(Transition.filterRide, longest(const [16, 32], math.min(intro, outro)),
          inKey ? 0.85 : 1.0, 'a long ride through the filters, both ways');
    }
    if (from.fx) considerMended(Transition.echoOut, dials.short, 0.9, 'goes out on its echo');

    // Announce: the new record's hook over the old record's beat.
    if (stems) {
      final bars = dials.length >= 0.8 ? 32 : 16;
      final hookAt = _announceFrom(to);
      // Where the new record goes on from its hook, most of it still to come: a hook
      // first sung late would announce a record that is then nearly over.
      if (hookAt != null && _roomAfter(to.timing, hookAt, bars + 32)) {
        final hook = to.vocals?.hook;
        consider(Transition.announce, bars, 1.1,
            hook != null && hook.at.isNotEmpty
                ? '"${_short(hook.text)}" over the beat before'
                : 'its voice first, over the beat before',
            inAt: hookAt, designed: true);
      }
      // A cappella out: the old record's last sung stretch over the new intro.
      final sungOut = _lastSung(from, 16);
      if (sungOut != null && _quietStart(to, 16)) {
        consider(Transition.acapellaOut, 16, 1.05, 'goes out singing over the next intro',
            outAt: sungOut, designed: true);
      }
    }

    // The drop: the new record dropping on the one the old one is taken away.
    final drop = _dropAfter(to, to.timing.cues?.firstDownbeat ?? Duration.zero);
    final short = dials.short;
    // Only a drop with the whole move's worth of record before it lands on the move's
    // last beat: parked any earlier than the record's start, it would come early.
    if (drop != null && _roomBefore(to.timing, drop, short)) {
      consider(Transition.dropSwap, short, 1.1, 'lands on its drop',
          inAt: _inBefore(to.timing, drop, short));
      if (inKey && _roomBefore(to.timing, drop, 8)) {
        consider(Transition.roll, 8, 0.9, 'rolled into its drop',
            inAt: _inBefore(to.timing, drop, 8));
      }
      if (_roomBefore(to.timing, drop, 16)) {
        consider(Transition.loopBuild, 16, 1.0, 'looped up into its drop',
            inAt: _inBefore(to.timing, drop, 16));
      }
      // The old record's own breakdown, with the new record's drop at the end of it.
      final breakdown = _breakdownAhead(from);
      if (breakdown != null) {
        final bars = breakdown.bars.clamp(8, 32);
        if (_roomBefore(to.timing, drop, bars)) {
          // Not a move that minds the voices itself: two records singing over a
          // breakdown is still two voices.
          consider(Transition.breakSwap, bars, 1.15, 'its breakdown under the next one\'s drop',
              outAt: breakdown.start, inAt: _inBefore(to.timing, drop, bars));
        }
      }
    }
    if (from.timing.ends == 'cold') {
      consider(Transition.brake, 8, 1, 'stopped dead on a cold ending');
    }
    if (stems) consider(Transition.swap, 16, inKey ? 1 : 0.8, 'the drums change hands');

    if (candidates.isEmpty) return [MixPlan(base.kind, base.bars, why: 'the ordinary way')];
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }

  /// The shift, in semitones, that would put [to] in key with [from] — one or two
  /// either way, the smallest first — or null where none does.
  static double? _shiftToFit(TrackTiming from, TrackTiming to) {
    final c = to.camelot;
    if (c == null || c.length < 2) return null;
    final n = int.tryParse(c.substring(0, c.length - 1));
    if (n == null) return null;
    final letter = c[c.length - 1];
    // A semitone up is seven steps round the wheel; a tone up is two.
    for (final (semitones, steps) in const [(1, 7), (-1, 5), (2, 2), (-2, 10)]) {
      final shifted = TrackTiming(
          camelot: '${(n - 1 + steps) % 12 + 1}$letter', keyConfidence: to.keyConfidence);
      final m = SetPlanner.keyMove(from, shifted);
      if (!m.clash && !m.boost && m.score >= 0.7) return semitones.toDouble();
    }
    return null;
  }

  static String _short(String s) => s.length > 40 ? '${s.substring(0, 38)}…' : s;

  /// The first drop of [to] after [at]: the ones read off the stems where there are
  /// any, else the ones read off the loudness.
  static Duration? _dropAfter(MixSide to, Duration at) {
    final fromStems = to.timing.structure?.dropsMs ?? const [];
    if (fromStems.isEmpty) return to.timing.dropAfter(at);
    for (final d in fromStems) {
      if (d >= at.inMilliseconds) return Duration(milliseconds: d);
    }
    return null;
  }

  /// Where to park [t] so that [drop] lands [bars] bars later, on the grid.
  static Duration _inBefore(TrackTiming t, Duration drop, int bars) {
    final bar = t.bar!;
    var at = drop - bar * bars;
    final first = t.cues?.firstDownbeat ?? Duration.zero;
    if (at < first) at = first;
    return t.onGrid(at);
  }

  /// The old record's next breakdown ahead of where it is, from its structure.
  static TrackSection? _breakdownAhead(MixSide from) {
    final s = from.timing.structure;
    if (s == null) return null;
    final now = from.position ?? Duration.zero;
    for (final section in s.sections) {
      if (section.label == 'breakdown' && section.start > now + const Duration(seconds: 8)) {
        return section;
      }
    }
    return null;
  }

  /// Whether [t] has [bars] bars between its first downbeat and [at].
  static bool _roomBefore(TrackTiming t, Duration at, int bars) {
    final bar = t.bar;
    final first = t.cues?.firstDownbeat ?? Duration.zero;
    return bar != null && at - bar * bars >= first;
  }

  /// Whether [t] goes on for [bars] bars after [at] before it starts going out.
  static bool _roomAfter(TrackTiming t, Duration at, int bars) {
    final bar = t.bar;
    final end = t.cues?.mixOut;
    return bar != null && (end == null || end <= Duration.zero || at + bar * bars <= end);
  }

  /// How many bars of [t] lie between [a] and [b].
  static int _bars(TrackTiming t, Duration? a, Duration? b) {
    final bar = t.bar;
    if (a == null || b == null || bar == null || b <= a) return 0;
    return ((b - a).inMicroseconds / bar.inMicroseconds).floor();
  }

  /// The bar of [t] that [at] falls in.
  static int _barOf(TrackTiming t, Duration at) {
    final d = t.downbeats;
    var i = 0;
    while (i + 1 < d.length && d[i + 1] <= at.inMilliseconds) {
      i++;
    }
    return i;
  }

  /// How many bars both records would be singing at once over a [bars]-bar move:
  /// from where the old record goes out ([outAt], or its outro) and where the new one
  /// comes in ([inAt], or the ordinary place).
  static int _clash(MixSide from, MixSide to, int bars, {Duration? outAt, Duration? inAt}) {
    final fv = from.vocals, tv = to.vocals;
    if (fv?.bars == null || tv?.bars == null) return 0;
    final out = outAt ?? from.timing.cues?.mixOut;
    final inn = inAt ?? AutoMix.inPoint(to.timing, bars: bars);
    if (out == null) return 0;
    final f0 = _barOf(from.timing, out), t0 = _barOf(to.timing, inn);
    var n = 0;
    for (var i = 0; i < bars; i++) {
      if (fv!.sungAt(f0 + i) && tv!.sungAt(t0 + i)) n++;
    }
    return n;
  }

  /// Where the new record should come in to announce itself: on the four-bar marker at
  /// or before its first hook — or, with no words to go by, before its first sung
  /// stretch after the intro. Null where there is nothing to sing.
  static Duration? _announceFrom(MixSide to) {
    final v = to.vocals;
    if (v == null) return null;
    final hook = v.hook;
    if (hook != null && hook.at.isNotEmpty) {
      final at = Duration(milliseconds: hook.at.first);
      // On the marker at or before it: the hook then comes within the first phrase.
      return to.timing.markerAtOrBefore(at);
    }
    final bars = v.bars;
    if (bars == null) return null;
    final start = _barOf(to.timing, to.timing.cues?.firstDownbeat ?? Duration.zero);
    for (var i = start; i + 8 <= bars.length; i++) {
      if (v.sungIn(i, i + 8) >= 6) {
        final d = to.timing.downbeats;
        if (i >= d.length) return null;
        return to.timing.markerAtOrBefore(Duration(milliseconds: d[i]));
      }
    }
    return null;
  }

  /// Where the old record's last well-sung stretch of [bars] starts, on a marker — for
  /// going out singing. Null where it does not sing near its end.
  static Duration? _lastSung(MixSide from, int bars) {
    final v = from.vocals;
    final b = v?.bars;
    if (b == null) return null;
    final d = from.timing.downbeats;
    final end = from.timing.cues?.soundEnd;
    final last = end == null ? b.length : math.min(b.length, _barOf(from.timing, end));
    for (var i = last - bars; i >= last - bars * 5 && i >= 0; i--) {
      if (v!.sungIn(i, i + bars) >= bars * 0.6 && i < d.length) {
        return from.timing.markerAtOrBefore(Duration(milliseconds: d[i]));
      }
    }
    return null;
  }

  /// Whether the new record's first [bars] bars are without a voice — or not known to
  /// have one.
  static bool _quietStart(MixSide to, int bars) {
    final v = to.vocals;
    if (v?.bars == null) return true;
    final start = _barOf(to.timing, to.timing.cues?.firstDownbeat ?? Duration.zero);
    return v!.sungIn(start, start + bars) <= bars ~/ 4;
  }
}
