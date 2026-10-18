// The show's page: the rig's rows set the layers, a chip launches a look, the tab
// is kept.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
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
    // The kit (the scene files, the shaders) is read: a few frames.
    for (var i = 0; i < 20 && find.text('BACKGROUND').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('BACKGROUND'), findsOneWidget);
  }

  testWidgets('the rows set the layers, locked', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(find.text('SCENE'), findsOneWidget);
    // The rig's rows scroll: the finish is at the foot.
    await tester.dragUntilVisible(find.text('FINISH'), find.byType(ListView).first, const Offset(0, -150));
    await tester.pump();
    expect(find.text('FINISH'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, 600));
    await tester.pump();
    expect(find.text('BLEND'), findsOneWidget);
    await tester.tap(find.text('Wash').first, warnIfMissed: false);
    await tester.pump();
    expect(show.state.rig.ground.kind, Ground.wash);
    expect(show.locked(RigSlot.ground), isTrue);
    Future<void> tapWord(String word) async {
      final f = find.text(word).first;
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await tester.pump();
    }
    await tapWord('WINDOW');
    expect(show.state.rig.blend.ground, GroundMode.window);
    expect(show.locked(RigSlot.blend), isTrue);
    expect(show.state.rig.blend.auto, isFalse);
    await tapWord('BLEND TOO');
    expect(show.state.rig.blend.figure, FigureMode.same);
    // Back to the rules.
    await tapWord('AS THE SCENE ASKS');
    expect(show.state.rig.blend.auto, isTrue);
    expect(show.locked(RigSlot.blend), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a look\'s chip launches it (now, as nothing plays), and the tab is kept', (tester) async {
    await open(tester);
    final show = booth.show;
    expect(show.looks, isNotEmpty);
    // The chips are a strip scrolled sideways: a chip past its edge is brought in first.
    Future<void> chip(String name) async {
      final f = find.text(name).first;
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await tester.pump();
    }
    await chip('Flash');
    expect(show.state.scene, 'flash');
    expect(show.pendingLook, isNull, reason: 'nothing plays: landed now');
    await chip('Kinetic');
    expect(show.state.scene, 'kinetic');
    // The dancers' chip lands the stylized dancers; their style row appears; a style holds.
    await chip('Dancers');
    expect(show.state.scene, 'dance-art');
    expect(find.text('ASCII'), findsOneWidget);
    await tester.tap(find.text('ASCII'), warnIfMissed: false);
    await tester.pump();
    expect(show.state.rig.figure.style, 'ascii');
    await tester.tap(find.text('AUTO').first, warnIfMissed: false);
    await tester.pump();
    expect(show.state.rig.figure.style, isNull);
    await tester.tap(find.text('PERF'));
    await tester.pump();
    expect(find.textContaining('renderer:'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.kept?.panel['tab'], 'perf');
    await tester.pumpWidget(const SizedBox());
  });
}
