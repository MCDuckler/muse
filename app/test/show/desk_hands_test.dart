// The Desk's PERFORM hands on a stage: the look on judged (NEVER THIS, WIDER, LESS,
// MORE, UNDO), the holds let go, a set put on, and all of it told back on `shown`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/show/desk_show_source.dart';
import 'package:muse/src/state/show/show_combos.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_plan.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/ui/show/desk_hands.dart';

const kinetic = Look(
  id: 'kinetic',
  name: 'Kinetic',
  rig: ShowRig(figure: RigFigure(kind: Figure.kinetic)),
  meta: SceneMeta(id: 'kinetic', priority: 2),
  shipped: true,
);
const flash = Look(id: 'flash', name: 'Flash', rig: ShowRig(figure: RigFigure(kind: Figure.flash)), meta: SceneMeta(id: 'flash'), shipped: true);

String hands(String what, [Map<String, Object> more = const {}]) => jsonEncode({'t': 'hands', 'do': what, ...more});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ShowEngine show;
  late DeskHands desk;
  const c = Combo(ground: 'white', scene: 'kinetic', style: 'ascii', mask: Mask.inverted, mix: Mix.contrast);

  setUp(() {
    ShowEngine.seedForTests = 3;
    show = ShowEngine.fed(DeskShowSource(ApiClient(baseUrl: 'http://example.invalid')), store: MemoryShowStore());
    show.looks = {for (final l in [kinetic, flash]) l.id: l};
    show.director.scenes = [kinetic.meta, flash.meta];
    show.play(c);
    show.tick(DateTime(2026, 1, 1));
    desk = DeskHands(show, null);
  });

  tearDown(() => show.dispose());

  Map<String, dynamic> shown() => jsonDecode(desk.shownJson()) as Map<String, dynamic>;

  test('NEVER THIS, WIDER, UNDO: the look, then any mask and blend, then the plan as it was', () {
    final before = show.pool.plan;
    expect(desk.handle(hands('never')), isTrue);
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], 0);
    expect(shown()['said'], startsWith('Never: Kinetic · ascii'));
    expect(shown()['undo'], isTrue);
    expect(shown()['wider'], isTrue);
    desk.handle(hands('wider'));
    expect(show.pool.plan.of('kinetic').cells[cellKey(style: 'ascii', ground: 'white')], 0);
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], isNull, reason: 'WIDER reaches from the plan before the NEVER');
    final n = shown()['saidN'] as int;
    desk.handle(hands('undo'));
    expect(show.pool.plan, before);
    expect(shown()['saidN'], n + 1);
    expect(shown()['undo'], isFalse);
  });

  test('LESS and MORE halve and double the look', () {
    desk.handle(hands('less'));
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], 0.5);
    desk.handle(hands('more'));
    desk.handle(hands('more'));
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], 2);
    expect(shown()['said'], startsWith('More: Kinetic'));
  });

  test('LET GO: every hold let go', () {
    expect(show.holds, isNotEmpty);
    expect(shown()['holds'], show.holds.length);
    desk.handle(hands('letgo'));
    expect(show.holds, isEmpty);
    expect(shown()['held'], isFalse);
  });

  test('the sets: listed, one put on by id, and back to the show as shipped', () {
    final s = show.snapshots.saveAs('Club');
    show.snapshots.useShipped();
    expect(shown()['sets'], [
      {'id': s.id, 'name': 'Club'},
    ]);
    expect(shown()['set'], isNull);
    desk.handle(hands('set', {'id': s.id}));
    expect(shown()['set'], s.id);
    expect(shown()['said'], 'Set: Club');
    desk.handle(hands('set', {'id': ''}));
    expect(shown()['set'], isNull);
  });

  test("the lines it does not know are the stage's", () {
    expect(desk.handle(hands('hit')), isFalse);
    expect(desk.handle('{"t":"desk","d":{}}'), isFalse);
    expect(shown()['look'], 'Kinetic · ascii on White · inverted · contrast');
  });
}
