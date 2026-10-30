// The stage over a wire: the plan and the combination on reach the far end, where the
// figures' clocks weigh their styles and cameras by it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_feed.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';
import 'package:muse/src/state/show/show_wire.dart';

class _Feed extends ChangeNotifier implements ShowFeed {
  @override
  ShowState state = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));
  final _events = StreamController<ShowEvent>.broadcast();
  @override
  Stream<ShowEvent> get events => _events.stream;
}

void main() {
  test('the plan and the combination on go over the wire, once and as they change', () {
    const combo = Combo(ground: 'milk', scene: 'dance-art', style: 'ascii');
    StylePool.from(ShowPool.none.withPlan(ShowPlan.shipped.withIn('dance-art', PlanAxis.shot, 'fisheye', muted: true)));
    StylePool.combo = combo;
    final lines = <String>[];
    final wire = ShowWire(_Feed(), lines.add);
    expect(lines.where((l) => l.contains('"plan"')), hasLength(1));
    // The far end, in a process of its own: nothing known yet.
    StylePool.from(ShowPool.none);
    StylePool.combo = null;
    expect(StylePool.shot(Figure.dancers, 'fisheye'), 1);
    final far = RemoteShowFeed();
    for (final l in lines) {
      far.arrived(l);
    }
    expect(StylePool.combo, combo);
    expect(StylePool.shot(Figure.dancers, 'fisheye'), 0);
    expect(StylePool.shot(Figure.dancers, 'front'), 1);
    wire.close();
    far.dispose();
    StylePool.from(ShowPool.none);
    StylePool.combo = null;
  });
}
