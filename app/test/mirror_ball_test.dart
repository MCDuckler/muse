// The mirror ball's light: specks drifting across the player while music plays.
//
// Decoration has to know when to stop. It moves only while the song plays, stops the
// moment it does not, and holds still for a phone that has been asked to keep still —
// which is also what lets a test settle.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/mirror_ball.dart';

void main() {
  Future<void> show(WidgetTester tester, {required bool playing, bool still = false}) =>
      tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: Scaffold(body: MirrorBallLight(playing: playing)),
        ),
      ));

  testWidgets('it drifts while the song plays', (tester) async {
    await show(tester, playing: true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
        reason: 'the specks are moving');
  });

  testWidgets('and stops when it does not', (tester) async {
    await show(tester, playing: true);
    await tester.pump(const Duration(milliseconds: 200));
    await show(tester, playing: false);
    // The fade out, then nothing: settling at all is the claim.
    await tester.pumpAndSettle();
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('a phone asked to keep still gets still light', (tester) async {
    await show(tester, playing: true, still: true);
    await tester.pumpAndSettle();
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
    expect(find.byType(MirrorBallLight), findsOneWidget);
  });
}
