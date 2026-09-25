// The booth's transitions as tables, for the offline renderer (tool/booth_probe/
// render_transition.py): every move's steps — the fader, each deck's bands, filter,
// loop, brake, part, stems, echo — as JSON, written where CURVES_OUT says. Without
// it, only checked to be well formed: every move begins at 0 and ends at 1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/fx_sounds.dart';
import 'package:muse/src/state/booth/mixer.dart';

Map<String, dynamic> _deck(DeckStep d) => {
      if (d.eq != null) 'eq': {'low': d.eq!.low, 'mid': d.eq!.mid, 'high': d.eq!.high},
      if (d.filter != null) 'filter': d.filter,
      if (d.loopBars != null) 'loop_bars': d.loopBars,
      if (d.brake) 'brake': true,
      if (d.part != null) 'part': d.part == DeckStep.whole ? 'whole' : d.part,
      if (d.stems != null) 'stems': {'drums': d.stems!.drums, 'rest': d.stems!.rest, 'vocals': d.stems!.vocals},
      if (d.echo != null) 'echo': d.echo,
      if (d.dry != null) 'dry': d.dry,
      if (d.shift != null) 'shift': d.shift,
      if (d.gate != null) 'gate': d.gate,
      if (d.gateDiv != null) 'gate_div': d.gateDiv,
    };

/// A sound of the booth's own, as the probe renders it: which one, how long (as a
/// share of the move, or in the master's beats) and at what gain. See fx_sounds.dart.
Map<String, dynamic> _fx(FxShot f) => {
      'sound': f.sound.name,
      if (f.span > 0) 'span': f.span,
      if (f.beats > 0) 'beats': f.beats,
      'gain_db': f.gainDb,
    };

void main() {
  test('every transition is a table from 0 to 1', () {
    final all = <String, dynamic>{};
    for (final kind in Transition.values) {
      final steps = Booth.plan(kind, from: 'A', to: 'B');
      if (kind != Transition.cut) {
        expect(steps.first.at, 0, reason: kind.name);
        expect(steps.last.at, 1, reason: kind.name);
        for (var i = 1; i < steps.length; i++) {
          expect(steps[i].at, greaterThanOrEqualTo(steps[i - 1].at), reason: '${kind.name} step $i');
        }
      }
      // A sound has a length, and a sound measured as a share of the move ends within
      // it: a riser that runs past the last beat is a riser still climbing after the
      // drop has landed.
      for (final step in steps) {
        final shot = step.fx;
        if (shot == null) continue;
        expect(shot.span > 0 || shot.beats > 0, isTrue, reason: '${kind.name}: a sound of no length');
        if (shot.span > 0) {
          expect(step.at + shot.span, lessThanOrEqualTo(1.0001),
              reason: '${kind.name}: ${shot.sound.name} runs past the move');
        }
      }
      // And a move that plays one says so, so the booth knows to render it.
      expect(steps.any((s) => s.fx != null), kind.needsSound, reason: kind.name);
      all[kind.name] = {
        'label': kind.label,
        'needs_stems': kind.needsStems,
        'needs_fx': kind.needsFx,
        'needs_sound': kind.needsSound,
        'needs_gate': kind.needsGate,
        'plainly': kind.plainly.name,
        'fader_law': kind.full ? 'full' : 'power',
        'steps': [
          for (final s in steps)
            {
              'at': s.at,
              if (s.crossfader != null) 'crossfader': s.crossfader,
              if (s.fx != null) 'fx': _fx(s.fx!),
              'decks': {for (final e in s.decks.entries) e.key: _deck(e.value)},
            },
        ],
      };
    }
    // The killed band, so the renderer knows what -40 means.
    all['_eq_killed'] = EqSet.killed;
    all['_stems_all'] = {'drums': StemLevels.all.drums, 'rest': StemLevels.all.rest, 'vocals': StemLevels.all.vocals};
    final out = Platform.environment['CURVES_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(all));
    }
  });
}
