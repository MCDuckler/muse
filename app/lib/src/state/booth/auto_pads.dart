import '../../api/models.dart';
import 'automix.dart';

/// What a pad the booth placed is for: the word on the pad and on the strip.
enum PadWhy {
  mixIn('IN', 'where the intro is over'),
  drop('DROP', 'the first drop'),
  breakdown('BREAK', 'the breakdown after it'),
  mixOut('OUT', 'where the record would be mixed out');

  const PadWhy(this.short, this.long);
  final String short;
  final String long;
}

/// The pads a record comes with: the four places a DJ marks on a record before playing
/// it out — where it is on, where it drops, where it breaks down, where it is left —
/// put where the Auto DJ would itself go, so a pad and an automatic mix agree.
///
/// Every one on the record's four-bar grid (a hot cue a beat out is a mix a beat out),
/// in the order they come in the record, and none within four bars of another: a
/// record whose intro ends on its drop gets one pad for the two, not two pads a frame
/// apart. Pads the record has no answer for stay empty.
class AutoPads {
  static Map<int, ({Duration at, PadWhy why})> of(TrackTiming t) {
    final cues = t.cues;
    final bar = t.bar;
    if (cues == null || bar == null) return const {};
    final first = cues.firstDownbeat;
    // The intro's end as the structure read it, the plain analysis's otherwise — what
    // AutoMix.inPoint aims the incoming record at.
    Duration? introEnd;
    for (final c in t.structure?.ins ?? const <CuePoint>[]) {
      if (c.why.contains('intro')) {
        introEnd = c.at;
        break;
      }
    }
    final mixIn = _on(t, introEnd ?? cues.mixIn, first);
    final drop = _dropAfter(t, mixIn ?? first);
    final out = AutoMix.outPoint(t, length: bar * 16);
    final pads = <({Duration at, PadWhy why})>[
      if (mixIn != null) (at: mixIn, why: PadWhy.mixIn),
      if (drop != null) (at: _on(t, drop, first) ?? drop, why: PadWhy.drop),
    ];
    final breakdown = drop == null ? null : _breakdownAfter(t, drop + bar * 8, out);
    if (breakdown != null) pads.add((at: breakdown, why: PadWhy.breakdown));
    if (out > first) pads.add((at: out, why: PadWhy.mixOut));

    // Each kind has its own pad, so pad 2 is the drop on every record. Two places too
    // near each other are one: the drop's, where the intro ends on it.
    final kept = <int, ({Duration at, PadWhy why})>{};
    ({Duration at, PadWhy why})? last;
    for (final p in pads) {
      if (last != null && p.at - last.at < bar * 4) {
        if (p.why != PadWhy.drop) continue;
        kept.remove(last.why.index + 1);
      }
      kept[p.why.index + 1] = p;
      last = p;
    }
    return kept;
  }

  /// [at] on the four-bar grid, and never before the first downbeat.
  static Duration? _on(TrackTiming t, Duration at, Duration first) {
    final on = t.onGrid(t.onMarker(at), every: 4);
    return on < first ? first : on;
  }

  /// The first drop after [at]: the plain analysis's (already on a marker), else the
  /// one the stems heard.
  static Duration? _dropAfter(TrackTiming t, Duration at) {
    final d = t.dropAfter(at);
    if (d != null) return d;
    for (final ms in t.structure?.dropsMs ?? const <int>[]) {
      if (ms > at.inMilliseconds) return Duration(milliseconds: ms);
    }
    return null;
  }

  /// Where the record breaks down between [from] and [before]: the structure's
  /// breakdown where it heard one, else the first four-bar marker where the record
  /// goes quiet — four quiet bars after loud ones.
  static Duration? _breakdownAfter(TrackTiming t, Duration from, Duration before) {
    final s = t.structure;
    if (s != null) {
      for (final ms in s.breakdownsMs) {
        final at = Duration(milliseconds: ms);
        if (at >= from && at < before) return t.onGrid(t.onMarker(at), every: 4);
      }
      for (final sec in s.sections) {
        if ((sec.label == 'breakdown' || sec.label == 'break') && sec.start >= from && sec.start < before) {
          return t.onGrid(t.onMarker(sec.start), every: 4);
        }
      }
    }
    final bar = t.bar!;
    for (final m in t.markers) {
      final at = Duration(milliseconds: m);
      if (at < from || at + bar * 4 > before) continue;
      if (AutoMix.quietBars(t, at, 4) && !AutoMix.quietBars(t, at - bar * 4, 4)) {
        return t.onGrid(at, every: 4);
      }
    }
    return null;
  }
}
