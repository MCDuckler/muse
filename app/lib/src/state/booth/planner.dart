import 'dart:math' as math;

import '../../api/models.dart';
import 'automix.dart';
import 'booth.dart';

/// One record's side of a transition, as the planner sees it.
class MixSide {
  const MixSide({required this.timing, this.vocals, this.stems = false, this.pitch = 1});
  final TrackTiming timing;
  final VocalMap? vocals;

  /// Its stems are on its deck (or will be): a stem move can be made with it.
  final bool stems;
  final double pitch;
}

/// What the planner decided: the move, its length, where the old record goes out and
/// where the new one comes in (null: the ordinary places), and why — for the log.
class MixPlan {
  const MixPlan(this.kind, this.bars, {this.outAt, this.inAt, this.why = '', this.score = 0});
  final Transition kind;
  final int bars;
  final Duration? outAt, inAt;
  final String why;
  final double score;

  /// The same move, told otherwise: by a hand steering the automix.
  MixPlan copyWith({int? bars, Duration? outAt, Duration? inAt}) => MixPlan(kind, bars ?? this.bars,
      outAt: outAt ?? this.outAt, inAt: inAt ?? this.inAt, why: why, score: score);

  @override
  String toString() => '${kind.label} $bars bars (${score.toStringAsFixed(2)}): $why';
}

/// Choosing the next transition the way a DJ would: every move that can be made with
/// these two records, each scored for how well it would go — two voices at once is the
/// clash anybody hears; a hook sung over the old record's beat is the new record
/// announcing itself; a drop is somewhere to land; an intro long enough is room for a
/// long blend — then weighed by how hard the booth has been told to mix, against the
/// moves it has just made, and with a little chance in it, so that a set is not the
/// same transition eleven times.
class Planner {
  /// How much each style likes each move, before anything is known about the records.
  static const _likes = <MixStyle, Map<Transition, double>>{
    MixStyle.easy: {
      Transition.stemBlend: 1.0,
      Transition.blend: 0.9,
      Transition.announce: 0.55,
      Transition.acapellaOut: 0.5,
      Transition.sweep: 0.45,
      Transition.dropSwap: 0.2,
      Transition.fade: 0.3,
    },
    MixStyle.normal: {
      Transition.stemBlend: 0.9,
      Transition.announce: 0.9,
      Transition.blend: 0.75,
      Transition.acapellaOut: 0.75,
      Transition.dropSwap: 0.7,
      Transition.sweep: 0.6,
      Transition.swap: 0.55,
      Transition.roll: 0.4,
    },
    MixStyle.bold: {
      Transition.announce: 1.0,
      Transition.dropSwap: 1.0,
      Transition.acapellaOut: 0.9,
      Transition.swap: 0.85,
      Transition.roll: 0.8,
      Transition.stemBlend: 0.6,
      Transition.sweep: 0.6,
      Transition.brake: 0.5,
      Transition.blend: 0.45,
    },
  };

  static MixPlan plan({
    required MixSide from,
    required MixSide to,
    MixStyle style = MixStyle.normal,
    List<Transition> recent = const [],
    math.Random? random,
  }) =>
      options(from: from, to: to, style: style, recent: recent, random: random).first;

  /// Every move that can be made with these two, best first — what [plan] chooses
  /// from, and what a hand steering the automix is offered. Never empty.
  static List<MixPlan> options({
    required MixSide from,
    required MixSide to,
    MixStyle style = MixStyle.normal,
    List<Transition> recent = const [],
    math.Random? random,
  }) {
    final rng = random ?? math.Random();
    // What cannot be put in step, or has no grid, or fades itself (it goes out as it was
    // made), or stops dead on a cold ending in key: the old rules, right about those.
    final base = AutoMix.choose(from.timing, to.timing, style: style, fromPitch: from.pitch);
    if (base.kind == Transition.fade ||
        base.kind == Transition.cut ||
        !from.timing.hasBeats ||
        !to.timing.hasBeats) {
      return [MixPlan(base.kind, base.bars, why: 'the only way these two go together')];
    }
    final inKey = from.timing.inKeyWith(to.timing);
    final stems = from.stems && to.stems;
    final likes = _likes[style]!;
    final candidates = <MixPlan>[];

    // Room, in bars: the new record's intro, the old record's outro.
    final intro = _bars(to.timing, to.timing.cues?.firstDownbeat, to.timing.cues?.mixIn);
    final outro = _bars(from.timing, from.timing.cues?.mixOut, from.timing.cues?.soundEnd);
    int longest(List<int> options, int room) =>
        options.where((b) => b <= math.max(room, options.first)).fold(options.first, math.max);

    void consider(Transition kind, int bars, double fit, String why,
        {Duration? outAt, Duration? inAt}) {
      final like = likes[kind];
      if (like == null) return;
      var score = like * fit;
      // Not the move just made, and less of one made lately.
      if (recent.isNotEmpty && recent.last == kind) score -= 0.4;
      if (recent.length > 1 && recent.sublist(math.max(0, recent.length - 4)).contains(kind)) {
        score -= 0.12;
      }
      // Two keys that clash are better out of the way quickly, or through the filter.
      if (!inKey && kind != Transition.sweep && kind != Transition.dropSwap) score -= 0.2;
      score += rng.nextDouble() * 0.22;
      candidates.add(MixPlan(kind, bars, outAt: outAt, inAt: inAt, why: why, score: score));
    }

    // The long ones, where there is room for them.
    final long = style == MixStyle.bold ? const [8, 16] : const [16, 32, 64];
    final blendBars = longest(long, math.min(intro, outro));
    final clash = _clash(from, to, blendBars);
    consider(Transition.blend, blendBars, clash == 0 ? 1 : 0.55,
        clash == 0 ? 'no two voices at once' : '$clash bars of two voices — EQ only');
    if (stems) {
      consider(Transition.stemBlend, longest(style == MixStyle.bold ? const [16] : const [32, 64],
          math.min(intro, outro)), 1, 'stem by stem, nothing doubled');
    }
    consider(Transition.sweep, style == MixStyle.bold ? 8 : 16, inKey ? 0.8 : 1.1,
        inKey ? 'through the filter' : 'keys clash: out through the filter');

    // Announce: the new record's hook over the old record's beat.
    if (stems) {
      final bars = style == MixStyle.easy ? 32 : 16;
      final hookAt = _announceFrom(to);
      // Where the new record goes on from its hook, most of it still to come: a hook
      // first sung late would announce a record that is then nearly over.
      if (hookAt != null && _roomAfter(to.timing, hookAt, bars + 32)) {
        final hook = to.vocals?.hook;
        consider(Transition.announce, bars, 1.1,
            hook != null && hook.at.isNotEmpty
                ? '"${_short(hook.text)}" over the beat before'
                : 'its voice first, over the beat before',
            inAt: hookAt);
      }
      // A cappella out: the old record's last sung stretch over the new intro.
      final sungOut = _lastSung(from, 16);
      if (sungOut != null && _quietStart(to, 16)) {
        consider(Transition.acapellaOut, 16, 1.05, 'goes out singing over the next intro',
            outAt: sungOut);
      }
    }

    // The drop: the new record dropping on the one the old one is taken away.
    final drop = to.timing.dropAfter(to.timing.cues?.firstDownbeat ?? Duration.zero);
    final bars = style == MixStyle.bold ? 8 : 16;
    // Only a drop with the whole move's worth of record before it lands on the move's
    // last beat: parked any earlier than the record's start, it would come early.
    if (drop != null && _roomBefore(to.timing, drop, bars)) {
      consider(Transition.dropSwap, bars, 1.1, 'lands on its drop',
          inAt: AutoMix.inPoint(to.timing, bars: bars, onTheDrop: true));
      if (inKey && _roomBefore(to.timing, drop, 8)) {
        consider(Transition.roll, 8, 0.9, 'rolled into its drop',
            inAt: AutoMix.inPoint(to.timing, bars: 8, onTheDrop: true));
      }
    }
    if (from.timing.ends == 'cold') consider(Transition.brake, 8, 1, 'stopped dead on a cold ending');
    if (stems) consider(Transition.swap, 16, inKey ? 1 : 0.8, 'the drums change hands');

    if (candidates.isEmpty) return [MixPlan(base.kind, base.bars, why: 'the ordinary way')];
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
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

  static String _short(String s) => s.length > 40 ? '${s.substring(0, 38)}…' : s;

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

  /// How many bars both records would be singing at once in an ordinary [bars]-bar
  /// overlap: the old record's last [bars] before its outro, the new record's first
  /// [bars] before its intro ends.
  static int _clash(MixSide from, MixSide to, int bars) {
    final fv = from.vocals, tv = to.vocals;
    if (fv?.bars == null || tv?.bars == null) return 0;
    final out = from.timing.cues?.mixOut;
    final inn = AutoMix.inPoint(to.timing, bars: bars);
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
