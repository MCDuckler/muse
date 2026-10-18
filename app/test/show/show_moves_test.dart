// The moves browser: the bank listed and filtered, a strip plays the move, the
// switch and the star reach the pool.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_pool.dart' show MovePool;
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/ui/show/show_dance.dart' show DanceAssets;
import 'package:muse/src/ui/show/show_moves.dart';
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
    await booth.show.ready();
  });

  tearDown(() {
    MoveStrip.clear();
    return booth.dispose();
  });

  testWidgets('the bank is listed, a strip plays its move, the pool hears the switch and the star', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The bank's skin is decoded off the test's fake clock.
    final chris = DanceAssets.of('chris');
    await tester.runAsync(() => chris.loaded);
    expect(chris.ready, isTrue, reason: 'the chris bank is shipped');
    final show = booth.show;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MovesBrowser(show: show))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('moves'), findsWidgets);
    expect(find.text('Pick a move'), findsOneWidget);
    // The first row: its strip drawn, tapped, its move on the viewer.
    final strips = find.byType(MoveStrip);
    expect(strips, findsWidgets);
    final id = tester.widget<MoveStrip>(strips.first).move.id;
    await tester.tap(strips.first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Pick a move'), findsNothing);
    expect(find.textContaining(' bpm · '), findsWidgets);
    // Filtered to one style: fewer rows.
    await tester.tap(find.text('LATIN'));
    await tester.pump();
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final s = t.data ?? '';
      if (s.contains(' · ') && s.contains(' bpm') && s.contains('energy')) expect(s, startsWith('latin'));
    }
    await tester.tap(find.text('ALL'));
    await tester.pump();
    // The switch and the star of the first row.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(show.pool.isOn('move.$id'), isFalse);
    await tester.tap(find.byIcon(Icons.star_border).first);
    await tester.pump();
    expect(show.pool.leanOf('move.$id'), 2);
    // An audition: asked of the dancers on the stage.
    await tester.tap(find.byIcon(Icons.play_circle_outline).first);
    await tester.pump();
    expect(MovePool.audition, id);
    MovePool.audition = null;
    // The document is kept a moment later: let that moment pass.
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.kept?.pool.leanOf('move.$id'), 2);
    await tester.pumpWidget(const SizedBox());
  });
}
