// The seek bar's segments.
//
// One look in three states: a slow swell while the song's shape is being fetched, a
// rise into the shape when it arrives, flat where there is none — and no movement at
// all once it has settled, or on a phone asked to keep still.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/now_playing.dart';

void main() {
  Future<void> show(WidgetTester tester,
          {List<int>? shape, required bool loading, bool still = false}) =>
      tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                  width: 300,
                  height: 24,
                  child: WaveBar(shape: shape, loading: loading, played: 0.3)),
            ),
          ),
        ),
      ));

  int moving() => SchedulerBinding.instance.transientCallbackCount;

  testWidgets('it swells while the shape is being fetched', (tester) async {
    await show(tester, loading: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(moving(), greaterThan(0));
  });

  testWidgets('a shape that never arrives does not keep the bar moving for ever',
      (tester) async {
    await show(tester, loading: true);
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
    expect(moving(), 0, reason: 'a few swells, then it rests');
  });

  testWidgets('the shape arriving rises into place, and then it is still',
      (tester) async {
    await show(tester, loading: true);
    await tester.pump(const Duration(milliseconds: 300));
    await show(tester, shape: [for (var i = 0; i < 160; i++) (i * 7) % 256], loading: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(moving(), greaterThan(0), reason: 'rising');
    await tester.pumpAndSettle();
    expect(moving(), 0, reason: 'and settled: a drawn bar costs nothing');
  });

  testWidgets('a song with no shape to give is flat and still', (tester) async {
    await show(tester, loading: false);
    await tester.pumpAndSettle();
    expect(moving(), 0);
  });

  testWidgets('nothing moves on a phone asked to keep still', (tester) async {
    await show(tester, loading: true, still: true);
    await tester.pumpAndSettle();
    expect(moving(), 0);
  });
}
