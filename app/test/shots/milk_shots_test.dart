// The MilkDrop pages drawn: the browser and the maker, with no helper (a test has
// none) — every tab, so a layout that overflows or a widget that throws is caught
// here rather than on a desk.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/milk_preset_text.dart';
import 'package:muse/src/ui/show/milk_maker.dart';
import 'package:muse/src/ui/show/milk_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_audio.dart';

/// A mixer that does nothing, as the engine test's.
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JustAudioPlatform.instance = FakeJustAudio();
  });

  for (final (w, h) in const [(1400.0, 900.0), (800.0, 1000.0)]) {
    testWidgets('the maker at ${w.round()}x${h.round()}, every tab', (tester) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final text = MilkText.parse(
        '[preset00]\nzoom=1.01\nshapecode_0_enabled=1\nper_frame_1=zoom = zoom + 0.060*wo_hit_kick;\nper_frame_2=wave_r = 0.5 + 0.5*sin(time);',
      );
      await tester.pumpWidget(MaterialApp(home: MilkMaker(text: text, name: 'Me - Test')));
      await tester.pump(const Duration(milliseconds: 100));
      for (final tab in const ['Wave & borders', 'Shapes', 'Reactions', 'Code', 'Look']) {
        await tester.tap(find.widgetWithText(Tab, tab));
        await tester.pumpAndSettle();
      }
      expect(find.text('Add a reaction'), findsNothing, reason: 'the Look tab is on');
      await tester.tap(find.widgetWithText(Tab, 'Reactions'));
      await tester.pumpAndSettle();
      expect(find.text('wo_hit_kick'), findsWidgets, reason: 'the reaction read off the file');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the browser at ${w.round()}x${h.round()}', (tester) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: QuietMixer());
      await tester.pumpWidget(MaterialApp(home: MilkPage(booth: booth)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('New preset'), findsOneWidget);
      expect(find.text('favourites only'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await booth.stopAll();
    });
  }
}
