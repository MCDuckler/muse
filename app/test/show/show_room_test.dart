// The show's page: the combination selector (following the stage, a pick, the
// switch, the weight, PLAY IT), a world's rows locked, the RULES tab; the tab kept.
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
import 'package:muse/src/ui/booth/desk/console.dart' show Pad;
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

  testWidgets('the selector: following the stage, a card picks, the switch and the weight make a rule, PLAY IT plays', (tester) async {
    await open(tester);
    final show = booth.show;
    frame(show);
    // Following the stage: the scene on is lit.
    expect(find.text('FOLLOWING THE STAGE'), findsOneWidget);
    await tap(tester, find.text('Dancer').last);
    expect(find.text('WHAT IS ON'), findsOneWidget, reason: 'picked: no longer following');
    await tap(tester, find.text('plain').last);
    await tap(tester, find.text('MilkDrop').last);
    await tap(tester, find.text('No mask').last);
    await tap(tester, find.text('Normal').last);
    expect(find.textContaining('in the rotation at'), findsOneWidget);
    // Off: a rule of the hands' for exactly this combination.
    await tap(tester, find.byType(Switch).first);
    expect(show.pool.rules, [const ComboRule(grounds: {'milk'}, scenes: {'dance-art'}, styles: {'plain'}, masks: {Mask.none}, mixes: {Mix.normal}, weight: 0)]);
    expect(show.pool.weightOf(const Combo(ground: 'milk', scene: 'dance-art', style: 'plain')), 0);
    // Back on: the rule goes.
    await tap(tester, find.byType(Switch).first);
    expect(show.pool.rules, isEmpty);
    // PLAY IT: on the stage, held.
    await tap(tester, find.text('PLAY IT'));
    frame(show);
    expect(show.combo, const Combo(ground: 'milk', scene: 'dance-art', style: 'plain'));
    expect(show.sceneHeld, isTrue);
    expect(show.state.rig.figure.style, 'plain');
    expect(show.state.rig.ground.kind, Ground.milk);
    // ANY: the mask and the blend let go, a rule for the rest.
    await tap(tester, find.text('ANY').at(3));
    await tap(tester, find.text('ANY').at(4));
    expect(find.textContaining('combinations,'), findsOneWidget);
    await tap(tester, find.byType(Switch).first);
    expect(show.pool.rules.single.pattern, 'milk|dance-art|plain|*|*');
    // HOLD lets go.
    await tap(tester, find.text('HELD'));
    expect(show.sceneHeld, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a batch: a few cards of a row (a long press), ANY, ALL BUT; one rule off; the map picks into the selector', (tester) async {
    await open(tester);
    final show = booth.show;
    await tap(tester, find.text('Turntable').last);
    await tap(tester, find.text('ANY').at(1));
    await tap(tester, find.text('ANY').at(2));
    await tap(tester, find.text('Keyhole').last);
    await tap(tester, find.text('Add').last);
    await tester.ensureVisible(find.text('Screen').last);
    await tester.longPress(find.text('Screen').last);
    await tester.pump();
    expect(find.text('Turntable × any style × any background × Keyhole × Add, Screen'), findsOneWidget);
    expect(find.textContaining('combinations,'), findsOneWidget);
    await tap(tester, find.byType(Switch).first);
    final rule = show.pool.rules.single;
    expect(rule.pattern, '*|turntable|*|keyhole|add,screen');
    expect(rule.off, isTrue);
    expect(show.pool.weightOf(const Combo(ground: 'milk', scene: 'turntable', style: 'raw', mask: Mask.keyhole, mix: Mix.screen)), 0);
    expect(show.pool.weightOf(const Combo(ground: 'milk', scene: 'turntable', style: 'raw', mask: Mask.keyhole, mix: Mix.contrast)), greaterThan(0));
    // ALL BUT on the blend: normal and contrast.
    await tap(tester, find.text('ALL BUT').last);
    expect(find.text('Turntable × any style × any background × Keyhole × Normal, Contrast'), findsOneWidget);
    // The map: the turntable's row outlined; a square tapped picks its two.
    await tap(tester, find.text('MAP'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('combinations in the rotation'), findsOneWidget);
    expect(find.textContaining('of the time'), findsWidgets);
    final grid = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_MapPainter');
    expect(grid, findsOneWidget);
    // The first scene's row, the first background's column.
    await tester.tapAt(tester.getTopLeft(grid) + const Offset(104 + 4, 96 + 8));
    await tester.pump();
    expect(find.text('WHAT IS ON'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MilkDrop the scene off after a whole combination: only the background is left', (tester) async {
    await open(tester);
    final show = booth.show;
    for (final w in ['Dancer', 'plain', 'White', 'Keyhole', 'Contrast']) {
      await tap(tester, find.text(w).last);
    }
    // The SCENE row's MilkDrop (the NOW line has one before it, the backgrounds after).
    final sceneTop = tester.getCenter(find.text('SCENE')).dy, styleTop = tester.getCenter(find.text('STYLE')).dy;
    final card = find.text('MilkDrop').evaluate().map((e) => e.widget).firstWhere((w) {
      final y = tester.getCenter(find.byWidget(w)).dy;
      return y > sceneTop && y < styleTop;
    });
    await tap(tester, find.byWidget(card));
    expect(find.text('a world of its own: its own background'), findsOneWidget);
    expect(find.text('MilkDrop × any style × any background × any mask × any blend'), findsOneWidget, reason: 'the hidden rows let go');
    await tap(tester, find.byType(Switch).first);
    expect(show.pool.rules.single.pattern, '*|milk|*|*|*');
    expect(show.pool.weightOf(const Combo(ground: ownGround, scene: 'milk', style: 'raw')), 0);
    show.director.rules = show.pool.allRules;
    expect(show.director.on.map((s) => s.id), isNot(contains('milk')));
    expect(show.pool.weightOf(const Combo(ground: 'milk', scene: 'dance-art', style: 'plain')), greaterThan(0));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the camera: a row for the dancers and the birds, a batch of framings off, the map by framing', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(find.text('CAMERA'), findsOneWidget, reason: 'every scene at ANY: the dancers\' and the birds\'');
    await tap(tester, find.text('Kinetic').last);
    expect(find.text('CAMERA'), findsNothing);
    await tap(tester, find.text('Dancer').last);
    await tap(tester, find.text('ascii').last);
    await tap(tester, find.text('ANY').at(2));
    await tap(tester, find.text('ANY').at(3));
    await tap(tester, find.text('ANY').at(4));
    await tap(tester, find.text('Fisheye').last);
    await tester.ensureVisible(find.text('Fisheye floor').last);
    await tester.longPress(find.text('Fisheye floor').last);
    await tester.pump();
    expect(find.text('Dancer × ascii × any background × any mask × any blend × Dancers fisheye, Dancers fisheye floor'), findsOneWidget);
    expect(find.textContaining('a camera rule'), findsOneWidget);
    await tap(tester, find.byType(Switch).first);
    final rule = show.pool.rules.single;
    expect(rule.pattern, '*|dance-art|ascii|*|*|dancers.fisheye,dancers.fisheyeLow');
    expect(rule.off, isTrue);
    // How often a combination comes: as before.
    expect(show.pool.weightOf(const Combo(ground: 'milk', scene: 'dance-art', style: 'ascii')), greaterThan(0));
    expect(show.pool.shotWeightOf(const Combo(ground: 'milk', scene: 'dance-art', style: 'ascii'), 'dancers.fisheye'), 0);
    expect(show.pool.shotWeightOf(const Combo(ground: 'milk', scene: 'dance-art', style: 'plain'), 'dancers.fisheye'), 1);
    // The scene let go of the camera: none of it left in the pattern.
    await tap(tester, find.text('Kinetic').last);
    expect(find.text('Kinetic × ascii × any background × any mask × any blend'), findsOneWidget);
    // The map with the camera across.
    await tap(tester, find.text('MAP'));
    await tester.pump(const Duration(milliseconds: 200));
    await tap(tester, find.text('CAMERA').at(1));
    expect(find.textContaining('(by framing)'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Pad && w.label == 'CAMERA' && w.lit), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('snapshots: saved as, switched between, changes put aside with an UNDO', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(find.text('SNAPSHOT'), findsOneWidget);
    show.setPool(show.pool.withRule(const ComboRule(scenes: {'kinetic'}), 0));
    await tester.pump();
    await tap(tester, find.text('SAVE AS'));
    await tester.enterText(find.byType(TextField), 'Calm');
    await tap(tester, find.text('Save'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Calm'), findsOneWidget);
    expect(show.doc.snapshots.single.name, 'Calm');
    // Back to the rules as shipped, and to Calm again.
    await tap(tester, find.text('As shipped'));
    expect(show.pool.rules, isEmpty);
    await tap(tester, find.text('Calm'));
    expect(show.pool.rules, hasLength(1));
    // Changed: a dot; switching away says so, and UNDO brings them back.
    show.setPool(show.pool.withRule(const ComboRule(scenes: {'flash'}), 0));
    await tester.pump();
    expect(find.text('Calm •'), findsOneWidget);
    await tap(tester, find.text('As shipped'));
    expect(find.text('Your changes to Calm were not saved'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tap(tester, find.text('UNDO'));
    expect(show.pool.rules, hasLength(2));
    expect(show.doc.snapshot?.name, 'Calm');
    // SAVE: over Calm.
    await tap(tester, find.text('SAVE'));
    expect(show.doc.snapshots.single.rules, hasLength(2));
    expect(find.text('Calm •'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a world has its own background: its rows locked', (tester) async {
    await open(tester);
    await tap(tester, find.text('Dancer').last);
    await tap(tester, find.text('disco').last);
    expect(find.text('a world of its own: its own background'), findsOneWidget);
    expect(find.text('No mask'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the RULES tab: yours listed, one taken away, back to the defaults; the tab is kept', (tester) async {
    await open(tester);
    final show = booth.show;
    show.setPool(show.pool.withRule(const ComboRule(grounds: {'milk'}), 1).withRule(const ComboRule(scenes: {'flash'}), 0));
    await tester.pump();
    expect(find.text('YOURS'), findsOneWidget);
    expect(find.text('MilkDrop  (card)'), findsWidgets);
    await tap(tester, find.byTooltip('Take this rule away').first);
    expect(show.pool.rules, hasLength(1));
    await tester.dragUntilVisible(find.text('BACK TO THE DEFAULTS'), find.byType(ListView).first, const Offset(0, 120));
    await tap(tester, find.text('BACK TO THE DEFAULTS'));
    expect(show.pool.rules, isEmpty);
    await tap(tester, find.text('SETTINGS'));
    expect(find.textContaining('renderer:'), findsOneWidget);
    expect(find.text('THE FINISH'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.kept?.panel['tab'], 'settings');
    await tester.pumpWidget(const SizedBox());
  });
}
