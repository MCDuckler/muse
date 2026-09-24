// The booth's transitions as tables, for the offline renderer (tool/booth_probe/
// render_transition.py): every move's steps — the fader, each deck's bands, filter,
// loop, brake, part, stems, echo — as JSON, written where CURVES_OUT says. Without
// it, only checked to be well formed: every move begins at 0 and ends at 1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/booth.dart';
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
      all[kind.name] = {
        'label': kind.label,
        'needs_stems': kind.needsStems,
        'needs_fx': kind.needsFx,
        'fader_law': kind.full ? 'full' : 'power',
        'steps': [
          for (final s in steps)
            {
              'at': s.at,
              if (s.crossfader != null) 'crossfader': s.crossfader,
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
