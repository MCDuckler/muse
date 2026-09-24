// A whole set planned from prepared records, for the offline renderer (tool/
// booth_probe/eval_set.py): the records in SET_DIR (as prepare_records.py writes
// them, <id>.json), ordered for an arc by the set planner and each pair's move chosen
// by the transition planner, written to SET_OUT as JSON. Without SET_DIR it only
// checks the planning runs on a synthetic set.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/automix.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/planner.dart';
import 'package:muse/src/state/booth/set_planner.dart';

Track _song(int id, double? lufs) => Track.fromJson({
      'id': id,
      'title': 'Record $id',
      'artists': ['Someone $id'],
      'duration_ms': 240000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
      'loudness_lufs': lufs,
    });

void main() {
  test('a set is planned end to end', () {
    final dir = Platform.environment['SET_DIR'];
    final out = Platform.environment['SET_OUT'];
    final arc = EnergyArc.values.asNameMap()[Platform.environment['SET_ARC'] ?? 'flat'] ?? EnergyArc.flat;
    final style = MixStyle.values.asNameMap()[Platform.environment['SET_STYLE'] ?? 'normal'] ?? MixStyle.normal;
    final timings = <int, TrackTiming>{};
    final tracks = <Track>[];
    if (dir != null) {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final m = RegExp(r'^(\d+)\.json$').firstMatch(name);
        if (m == null) continue;
        final id = int.parse(m.group(1)!);
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        timings[id] = TrackTiming.fromJson(j);
        tracks.add(_song(id, (j['structure'] as Map?)?['lufs'] as double?));
      }
    } else {
      for (var i = 1; i <= 4; i++) {
        const beat = 469;
        final beats = [for (var b = 0; b < 480; b++) b * beat];
        timings[i] = TrackTiming(
          durationMs: 240000,
          bpm: 60000 / beat,
          beats: beats,
          downbeats: [for (var b = 0; b < beats.length; b += 4) beats[b]],
          camelot: '8A',
          keyConfidence: 0.8,
          cues: MixCues(firstDownbeatMs: 0, mixInMs: beats[64], mixOutMs: beats[352], soundEndMs: beats[479]),
        );
        tracks.add(_song(i, -12.0 + i));
      }
    }
    expect(tracks.length, greaterThan(1));
    tracks.sort((a, b) => a.id.compareTo(b.id));
    final first = tracks.first;
    final ordered = [
      first,
      ...SetPlanner.order(tracks.sublist(1), from: first, timingOf: (id) => timings[id], arc: arc),
    ];
    final plan = <Map<String, dynamic>>[];
    final recent = <Transition>[];
    for (var i = 0; i + 1 < ordered.length; i++) {
      final a = ordered[i], b = ordered[i + 1];
      final ta = timings[a.id]!, tb = timings[b.id]!;
      final p = Planner.plan(
        from: MixSide(timing: ta, stems: true, fx: true),
        to: MixSide(timing: tb, stems: true, fx: true),
        style: style,
        recent: recent,
        random: math.Random(i),
      );
      recent.add(p.kind);
      final fit = SetPlanner.fit(ta, tb, ta: a, tb: b);
      final bar = ta.bar ?? const Duration(seconds: 2);
      plan.add({
        'from': a.id,
        'to': b.id,
        'kind': p.kind.name,
        'bars': p.bars,
        'shift': p.shift,
        'out_ms': (p.outAt ?? AutoMix.outPoint(ta, length: bar * p.bars)).inMilliseconds,
        'in_ms': (p.inAt ?? AutoMix.inPoint(tb, bars: p.bars)).inMilliseconds,
        'why': p.why,
        'fit': fit.score,
        'fit_why': fit.why,
      });
    }
    expect(plan, isNotEmpty);
    if (out != null) {
      File(out).writeAsStringSync(const JsonEncoder.withIndent(' ')
          .convert({'arc': arc.name, 'style': style.name, 'order': [for (final t in ordered) t.id], 'moves': plan}));
    }
  });
}
