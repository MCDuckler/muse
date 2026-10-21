// The show's page: the four big buttons, the pictures to pick from, the rules at a
// glance; the tab is kept.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/ui/show/show_room.dart';
import 'package:muse/src/ui/show/stage_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_audio.dart';

class QuietMixer extends Mixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {}
  @override
  Future<void> setEq(Deck deck, EqSet eq) async {}
  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

void main() {
  late Booth booth;
  late MemoryShowStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    JustAudioPlatform.instance = FakeJustAudio();
    ShowEngine.seedForTests = 3;
    store = MemoryShowStore();
    booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: QuietMixer(), showStore: store);
    await booth.init();
  });

  tearDown(() => booth.dispose());

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The kit (the scene files, the shaders) and the document read here, where the
    // test can wait for them; the room finds them ready.
    await StageKit.load();
    await booth.show.ready();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ShowRoom(booth: booth))));
    for (var i = 0; i < 20 && find.text('BACKGROUND').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('BACKGROUND'), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await tester.pump();
  }

  /// A frame of the show's, so the rig follows the pool.
  void frame(ShowEngine show) => show.tick(DateTime.now());

  testWidgets('a chip puts a scene on; the four buttons keep it, part it, blend it another way', (tester) async {
    await open(tester);
    final show = booth.show;
    // As it draws itself (no treatment from the conductor's mix meanwhile: a treated
    // scene is a pair of its own).
    show.setTreat('kinetic', 'raw');
    await tap(tester, find.text('Kinetic').last);
    expect(show.state.scene, 'kinetic');
    expect(show.pendingLook, isNull, reason: 'nothing plays: landed now');
    // A background picked is the hands' until LET GO.
    await tap(tester, find.text('Wash').last);
    frame(show);
    expect(show.state.rig.ground.kind, Ground.wash);
    expect(show.locked(RigSlot.ground), isTrue);
    expect(find.text('LET GO'), findsOneWidget);
    // OTHER BLEND: the next way for the pair, kept for it.
    const kinetic = RigFigure(kind: Figure.kinetic);
    final ways = show.pool.blendsFor(kinetic, Ground.wash);
    final was = show.state.rig.blend.ground;
    await tap(tester, find.text('OTHER BLEND'));
    final next = ways[(ways.indexOf(was) + 1) % ways.length];
    expect(show.pool.combos[ShowPool.comboKey(kinetic, Ground.wash)]?.ground, next);
    frame(show);
    expect(show.state.rig.blend.ground, next);
    await tester.pump();
    expect(find.textContaining('· yours'), findsOneWidget);
    // KEEP: the scene held and the background with it; again: let go.
    await tap(tester, find.text('KEEP'));
    expect(show.sceneHeld, isTrue);
    expect(find.text('KEPT'), findsOneWidget);
    await tap(tester, find.text('KEPT'));
    expect(show.sceneHeld, isFalse);
    expect(show.locked(RigSlot.ground), isFalse);
    // NOT TOGETHER: never again, the hands' background let go, and an undo.
    await tap(tester, find.text('Wash').last);
    frame(show);
    final before = show.pool;
    await tap(tester, find.text('NOT TOGETHER'));
    expect(show.pool.answer(kinetic, Ground.wash).never, isTrue);
    expect(show.locked(RigSlot.ground), isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('UNDO'), findsOneWidget);
    await tester.tap(find.text('UNDO'));
    await tester.pump();
    expect(show.pool.combos, before.combos);
    // The document's save, a moment after.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the rules as pictures: a tap switches a pair, a branch every style, a change undone', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(find.text('RULES'), findsOneWidget);
    Finder cell(String name, String ground) => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('$name on $ground:'));
    // The grid scrolls (its rows are pictures): a thing is brought into view first.
    final grid = find.descendant(of: find.byKey(const ValueKey('rules')), matching: find.byType(Scrollable)).first;
    Future<void> reach(Finder f) async {
      // From the top down, whatever was in view.
      await tester.drag(grid, const Offset(0, 20000));
      await tester.pump();
      await tester.scrollUntilVisible(f, 120, scrollable: grid, maxScrolls: 80);
      await tester.pump();
    }
    Future<void> tapAt(Finder f) async {
      await reach(f);
      await tester.tap(f);
      await tester.pump();
    }
    // Kinetic on the wash: together; a tap, never; the change listed; undone.
    const kinetic = RigFigure(kind: Figure.kinetic);
    expect(show.pool.answer(kinetic, Ground.wash).never, isFalse);
    await tapAt(cell('Kinetic', 'Wash'));
    expect(show.pool.answer(kinetic, Ground.wash).never, isTrue);
    await reach(find.text('YOUR CHANGES · 1'));
    expect(find.textContaining('Kinetic on Wash'), findsWidgets);
    await tapAt(find.byTooltip('Undo this change'));
    expect(show.pool.combos, isEmpty);
    expect(find.text('YOUR CHANGES · 0'), findsOneWidget);
    // The dancers open with their styles: the plain ones never on MilkDrop by the
    // rules; a tap, together (the page as drawn).
    const p = RigFigure(kind: Figure.dancers, style: 'plain');
    expect(show.pool.answer(p, Ground.milk).never, isTrue);
    await tapAt(cell('plain', 'MilkDrop'));
    expect(show.pool.answer(p, Ground.milk).never, isFalse);
    expect(show.pool.combos[ShowPool.comboKey(p, Ground.milk)], ComboRule.over);
    // The branch on the wash: not every style there (the viewports are a world of
    // their own) → a tap, every one together; again, every one never; again, together.
    const styles = ['plain', 'mono', 'trails', 'disco', 'viewports'];
    bool all(bool together) => styles.every((st) => show.pool.answer(RigFigure(kind: Figure.dancers, style: st), Ground.wash).never != together);
    expect(all(true), isFalse);
    await tapAt(cell('Dancer', 'Wash'));
    expect(all(true), isTrue);
    await tapAt(cell('Dancer', 'Wash'));
    expect(all(false), isTrue);
    await tapAt(cell('Dancer', 'Wash'));
    expect(all(true), isTrue);
    expect(show.pool.answer(p, Ground.milk).never, isFalse);
    // Closed: the styles go.
    await tapAt(find.textContaining('Dancer · every style'));
    expect(cell('plain', 'MilkDrop'), findsNothing);
    // Back to the defaults.
    await tapAt(find.text('BACK TO THE DEFAULTS'));
    expect(show.pool.combos, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ON/OFF: a part switched off is gone everywhere, and back', (tester) async {
    await open(tester);
    final show = booth.show;
    // A tall window, so the tab has room to scroll in.
    tester.view.physicalSize = const Size(1600, 1600);
    await tester.pump();
    await tap(tester, find.text('ON/OFF'));
    expect(find.text('SCENES'), findsOneWidget);
    Finder switchOf(String label) => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('$label: '));
    final list = find.descendant(of: find.byKey(const ValueKey('switches')), matching: find.byType(Scrollable)).first;
    Future<void> flip(Finder f) async {
      await tester.drag(list, const Offset(0, 20000));
      await tester.pump();
      await tester.scrollUntilVisible(f, 80, scrollable: list, maxScrolls: 60);
      await tester.pump();
      await tester.tap(f);
      await tester.pump();
    }
    // A scene off: gone from the scene strip and from the director.
    expect(find.text('Kinetic'), findsWidgets);
    await flip(switchOf('Kinetic').first);
    expect(show.pool.isOn('look.kinetic'), isFalse);
    expect(show.director.on.map((s) => s.id), isNot(contains('kinetic')));
    expect(find.text('Kinetic'), findsOneWidget, reason: 'only the switch says it now');
    // A way of blending off: no rule blends so, the next way instead.
    await flip(switchOf('contrast').first);
    expect(show.pool.blendOn(GroundMode.contrast), isFalse);
    for (var seed = 0; seed < 6; seed++) {
      expect(show.pool.blendFor(const RigFigure(kind: Figure.kinetic), Ground.milk, seed: seed).ground, isNot(GroundMode.contrast));
    }
    expect(show.pool.blendsFor(const RigFigure(kind: Figure.kinetic), Ground.milk), isNot(contains(GroundMode.contrast)));
    // A dancer style off: their clock may not pick it.
    await flip(switchOf('disco').first);
    expect(show.pool.styleOn(Figure.dancers, 'disco'), isFalse);
    expect(StylePool.allows(Figure.dancers, 'disco'), isFalse);
    // All on again, section by section.
    for (var i = 0; i < 3; i++) {
      await flip(find.text('ALL ON').first);
    }
    expect(show.pool.off, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the dancers\' style strip, and the tab is kept', (tester) async {
    await open(tester);
    final show = booth.show;
    await tap(tester, find.text('Dancer').last);
    expect(show.state.scene, 'dance-art');
    expect(find.text('DANCER STYLE'), findsOneWidget);
    expect(find.text('DISCO'), findsOneWidget);
    await tap(tester, find.text('CHRONO'));
    frame(show);
    expect(show.state.rig.figure.style, 'chrono');
    await tap(tester, find.text('AUTO').last);
    frame(show);
    expect(show.style, isNull);
    // Another scene: its treatment instead.
    await tap(tester, find.text('Kinetic').last);
    expect(find.text('TREATMENT'), findsOneWidget);
    await tap(tester, find.text('OFF'));
    expect(show.pool.treat['kinetic'], 'raw');
    await tap(tester, find.text('SETTINGS'));
    expect(find.textContaining('renderer:'), findsOneWidget);
    expect(find.text('THE FINISH'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.kept?.panel['tab'], 'settings');
    await tester.pumpWidget(const SizedBox());
  });
}
