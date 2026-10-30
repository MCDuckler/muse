// The show's page: PERFORM — what is on judged in a tap (NEVER THIS and WIDER, LESS,
// UNDO), everything held said and let go; the ROTATION — a scene off and its level, a
// background's, the sets; a scene's page — its styles, its own backgrounds, its looks
// judged square by square, made like another scene; what a scene shows (the 3D text);
// the favourites; the tab and the page kept.
import 'package:flutter/gestures.dart' show kSecondaryButton;
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
    for (var i = 0; i < 20 && find.text('SCENES').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('SCENES'), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await tester.pump();
  }

  /// The ON/OFF pad of a fader row.
  Finder onOff(String key) =>
      find.descendant(of: find.byKey(ValueKey(key)), matching: find.byWidgetPredicate((w) => w is Text && (w.data == 'ON' || w.data == 'OFF'))).first;

  /// A fader row's slider, moved to its stop [i] (¼ ⅓ ½ ¾ 1 1½ 2 3 4).
  Future<void> fade(WidgetTester tester, String key, int i) async {
    final slider = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Slider));
    await tester.ensureVisible(slider);
    tester.widget<Slider>(slider).onChanged!(i.toDouble());
    await tester.pump();
  }

  /// A frame of the show's, so the rig follows the plan.
  void frame(ShowEngine show) => show.tick(DateTime.now());

  /// A moment for a menu or a message to come (the live picture never settles).
  Future<void> moment(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  /// The messages gone, the document kept, the page taken down.
  Future<void> done(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('the rotation: a scene off and back at its level, a third, a background\'s level; its share said', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(find.text('BACKGROUNDS'), findsOneWidget);
    expect(find.text('nothing — the director has it all'), findsOneWidget);
    await fade(tester, 'scene:glide', 1);
    expect(show.pool.plan.of('glide').level, closeTo(1 / 3, 1e-9));
    expect(find.descendant(of: find.byKey(const ValueKey('scene:glide')), matching: find.text('×1/3')), findsOneWidget);
    await tap(tester, onOff('scene:glide'));
    expect(show.pool.plan.sceneLevel('glide'), 0);
    expect(find.descendant(of: find.byKey(const ValueKey('scene:glide')), matching: find.text('—')), findsOneWidget, reason: 'no share while off');
    await tap(tester, onOff('scene:glide'));
    expect(show.pool.plan.sceneLevel('glide'), closeTo(1 / 3, 1e-9), reason: 'back at its level');
    // A background at 4, another off everywhere.
    await fade(tester, 'ground:milk', 8);
    expect(show.pool.plan.shared(PlanAxis.ground, 'milk'), 4);
    await tap(tester, onOff('ground:wash'));
    expect(show.pool.plan.sharedMuted(PlanAxis.ground, 'wash'), isTrue);
    await done(tester);
  });

  testWidgets('what is on judged: NEVER THIS, WIDER, UNDO; LESS; held said and let go', (tester) async {
    await open(tester);
    final show = booth.show;
    const c = Combo(ground: 'milk', scene: 'kinetic', style: 'ascii', mix: Mix.contrast);
    show.play(c);
    frame(show);
    await tester.pump();
    // Held: the look, said, with its ×.
    expect(find.textContaining('Kinetic · ascii on MilkDrop'), findsWidgets);
    show.holdGround('milk');
    await tester.pump();
    expect(find.text('LET GO ALL'), findsOneWidget);
    await tap(tester, find.text('NEVER THIS'));
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], 0);
    await moment(tester);
    expect(find.textContaining('Never: Kinetic · ascii on MilkDrop'), findsOneWidget);
    await tap(tester, find.text('WIDER'));
    await moment(tester);
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], isNull);
    expect(show.pool.plan.of('kinetic').cells[cellKey(style: 'ascii', ground: 'milk')], 0);
    await tap(tester, find.text('WIDER'));
    await moment(tester);
    expect(show.pool.plan.mutedIn('kinetic', PlanAxis.style, 'ascii'), isTrue);
    await tap(tester, find.text('UNDO'));
    expect(show.pool.plan, ShowPlan.shipped);
    await tester.pump(const Duration(seconds: 6));
    await tap(tester, find.text('LESS'));
    expect(show.pool.plan.of('kinetic').cells[cellOf(c)], 0.5);
    await tester.pump(const Duration(seconds: 6));
    // LET GO ALL: nothing held.
    await tap(tester, find.text('LET GO ALL'));
    expect(show.holds, isEmpty);
    expect(find.text('nothing — the director has it all'), findsOneWidget);
    await done(tester);
  });

  testWidgets('a scene\'s page: its styles, its own backgrounds, a look never and back, less; like another scene; kept', (tester) async {
    await open(tester);
    final show = booth.show;
    // Three backgrounds on, as a night has them (and a grid of a few squares).
    var plan = show.pool.plan;
    for (final g in comboGrounds) {
      if (!const {'black', 'white', 'milk'}.contains(g)) plan = plan.withShared(PlanAxis.ground, g, muted: true);
    }
    show.setPlan(plan);
    await tap(tester, find.byTooltip('Its page: Kinetic'));
    expect(find.text('KINETIC'), findsOneWidget);
    expect(find.text('ITS LOOKS'), findsOneWidget);
    // A style off in it alone.
    await tap(tester, onOff('style:ascii'));
    expect(show.pool.plan.mutedIn('kinetic', PlanAxis.style, 'ascii'), isTrue);
    expect(show.pool.plan.mutedIn('flash', PlanAxis.style, 'ascii'), isFalse);
    // Its own backgrounds: white off for it alone.
    await tap(tester, find.text('ITS OWN').first);
    expect(show.pool.plan.owns('kinetic', PlanAxis.ground), isTrue);
    await tap(tester, onOff('own ground:white'));
    expect(show.pool.plan.levelIn('kinetic', PlanAxis.ground, 'white'), 0);
    expect(show.pool.plan.levelIn('flash', PlanAxis.ground, 'white'), greaterThan(0));
    // A look: never, and back.
    final square = find.byKey(const ValueKey('look:raw|milk'));
    await tap(tester, square);
    expect(show.pool.plan.of('kinetic').cells[cellKey(style: 'raw', ground: 'milk')], 0);
    await tap(tester, square);
    expect(show.pool.plan.of('kinetic').cells, isEmpty);
    // Less, by its menu.
    await tester.ensureVisible(square);
    await tester.tap(square, buttons: kSecondaryButton);
    await moment(tester);
    await tester.tap(find.textContaining('Less (×½)'));
    await moment(tester);
    expect(show.pool.plan.of('kinetic').cells[cellKey(style: 'raw', ground: 'milk')], 0.5);
    // Made like the dancer: its cells and own rows.
    show.setPlan(show.pool.plan.withCell('dance-art', cellKey(style: 'lines', ground: 'white'), 0));
    await tester.pump();
    await tester.dragUntilVisible(find.text('COPY FROM'), find.byKey(const ValueKey('scene page')), const Offset(0, 300));
    await tap(tester, find.text('COPY FROM'));
    await moment(tester);
    await tester.tap(find.text('Like Dancer'));
    await moment(tester);
    expect(show.pool.plan.of('kinetic').cells, {cellKey(style: 'lines', ground: 'white'): 0});
    expect(show.pool.plan.owns('kinetic', PlanAxis.ground), isFalse);
    // The page is kept: back on it after the room is built again.
    await tester.pump(const Duration(milliseconds: 400));
    expect(show.doc.panel['scene'], 'kinetic');
    await tap(tester, find.text('ROTATION').last);
    expect(find.text('SCENES'), findsOneWidget);
    await done(tester);
  });

  testWidgets('a world: no backgrounds to set; a world style in a scene says so', (tester) async {
    await open(tester);
    await tap(tester, find.byTooltip('Its page: MilkDrop'));
    expect(find.text('MILKDROP'), findsWidgets);
    expect(find.text('BACKGROUNDS'), findsNothing);
    await tap(tester, find.text('ROTATION').last);
    await tap(tester, find.byTooltip('Its page: Dancer'));
    await tester.dragUntilVisible(find.text('a world of its own: its own background').first, find.byKey(const ValueKey('scene page')), const Offset(0, -200));
    await tester.dragUntilVisible(find.text('WHO DANCES'), find.byKey(const ValueKey('scene page')), const Offset(0, -300));
    expect(find.text('WHO DANCES'), findsOneWidget);
    await done(tester);
  });

  testWidgets('sets: saved as, switched between, changes put aside with an UNDO, saved over', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(find.text('SET'), findsOneWidget);
    show.setPlan(show.pool.plan.withScene('kinetic', muted: true));
    show.setPool(show.pool.copyWith(mosh: 0.8));
    await tester.pump();
    await tap(tester, find.text('SAVE AS'));
    await tester.enterText(find.byType(TextField), 'Calm');
    await tap(tester, find.text('Save'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Calm'), findsOneWidget);
    expect(show.doc.snapshots.single.name, 'Calm');
    await tap(tester, find.text('As shipped'));
    expect(show.pool.plan, ShowPlan.shipped);
    expect(show.pool.mosh, ShowPool.defaultMosh, reason: 'a set is the whole setup');
    await tap(tester, find.text('Calm'));
    expect(show.pool.plan.sceneLevel('kinetic'), 0);
    expect(show.pool.mosh, 0.8);
    // Changed: a dot; switching away says so, and UNDO brings it back.
    show.setPlan(show.pool.plan.withScene('flash', muted: true));
    await tester.pump();
    expect(find.text('Calm •'), findsOneWidget);
    await tap(tester, find.text('As shipped'));
    await moment(tester);
    expect(find.text('Your changes to Calm were not saved'), findsOneWidget);
    await tap(tester, find.text('UNDO'));
    expect(show.pool.plan.sceneLevel('flash'), 0);
    expect(show.doc.snapshot?.name, 'Calm');
    await tap(tester, find.text('SAVE'));
    expect(show.doc.snapshots.single.setup.plan.sceneLevel('flash'), 0);
    expect(find.text('Calm •'), findsNothing);
    await done(tester);
  });

  testWidgets('the 3D text\'s page: the lines typed, a face, a motion more, SHOW IT', (tester) async {
    await open(tester);
    final show = booth.show;
    await tap(tester, find.byTooltip('Its page: 3D Text'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.dragUntilVisible(find.text('LINES'), find.byKey(const ValueKey('scene page')), const Offset(0, -300));
    expect(find.text('LINES'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'HELLO\n{artist}');
    await tester.pump(const Duration(milliseconds: 600));
    expect(show.pool.type3d.lines, ['HELLO', '{artist}']);
    Future<void> press(String word) async {
      final chip = find.ancestor(of: find.text(word), matching: find.byType(InkWell)).first;
      tester.widget<InkWell>(chip).onTap!();
      await tester.pump();
    }

    await press('Orbitron');
    expect(show.pool.type3d.font, TypeFont.orbitron);
    await press('ZOOM');
    expect(show.pool.type3d.motions, contains(TypeMotion.zoom));
    for (final m in show.pool.type3d.motions.toList()) {
      await press(m.name.toUpperCase());
    }
    expect(show.pool.type3d.motions, hasLength(1), reason: 'the last motion is never taken away');
    await press('MELT');
    expect(show.pool.type3d.deforms, contains(TypeDeform.melt));
    await press('EVERY BEAT');
    expect(show.pool.type3d.change, TypeChange.beat);
    await tester.ensureVisible(find.text('SHOW IT'));
    tester.widget<Pad>(find.ancestor(of: find.text('SHOW IT'), matching: find.byType(Pad))).onTap!();
    await tester.pump();
    show.tick(DateTime.now());
    expect(show.combo?.scene, 'type3d');
    expect(show.state.macros.type3d.font, TypeFont.orbitron);
    await done(tester);
  });

  testWidgets('favourites: KEEP keeps what is on, rated in its message; FAVES puts one back on, held, steps through, filters by stars', (tester) async {
    await open(tester);
    final show = booth.show;
    const combo = Combo(ground: 'milk', scene: 'dance-art', style: 'plain', mix: Mix.screen);
    show.play(combo);
    frame(show);
    StylePool.shotNow[Figure.dancers] = 'fisheye';
    addTearDown(() {
      StylePool.shotNow.clear();
      StylePool.heldShot = null;
    });
    await tap(tester, find.text('KEEP'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(show.faves.single.combo, combo);
    expect(show.faves.single.shot, 'dancers.fisheye');
    final stars = find.descendant(of: find.byType(SnackBar), matching: find.byIcon(Icons.star_outline_rounded));
    expect(stars, findsNWidgets(5));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(stars.at(3));
    await tester.pump();
    expect(show.faves.single.stars, 4);

    show.holdScene(false);
    await tap(tester, find.text('FAVES'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('FAVOURITES'), findsOneWidget);
    await tap(tester, find.descendant(of: find.byType(GridView), matching: find.byType(InkWell)).first);
    frame(show);
    expect(show.faveOn?.id, show.faves.single.id);
    expect(show.combo, combo);
    expect(show.sceneHeld, isTrue);
    expect(StylePool.heldShot, 'dancers.fisheye');
    expect(find.textContaining('the favourite'), findsOneWidget, reason: 'held, said under the picture');
    await tap(tester, find.text('LET GO'));
    expect(show.faveOn, isNull);
    expect(show.sceneHeld, isFalse);
    expect(StylePool.heldShot, isNull);
    await tap(tester, find.byIcon(Icons.chevron_right).last);
    expect(show.faveOn, isNotNull);
    await tap(tester, find.text('★★★★★'));
    expect(find.text('None with these stars.'), findsOneWidget);
    await done(tester);
  });
}
