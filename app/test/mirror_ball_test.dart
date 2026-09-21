// The mirror ball's light: spots swinging across the player while music plays.
//
// Decoration has to know when to stop. It moves only while the song plays, stops the
// moment it does not, and holds still for a phone that has been asked to keep still —
// which is also what lets a test settle.
import 'dart:math' as math;

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
        reason: 'the spots are moving');
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

  // What makes it a mirror ball and not dust in a sunbeam: the spots are thrown by one
  // turning thing, so they all go the same way together, and the ones sliding off
  // towards the sides are the stretched ones.
  group('where the light lands', () {
    const page = Size(400, 860);

    test('every spot swings the same way as the ball turns', () {
      final before = {
        for (final s in spotsOnThePage(page, 1.0)) (s.tile, s.lamp): s.at
      };
      final after = {
        for (final s in spotsOnThePage(page, 1.01)) (s.tile, s.lamp): s.at
      };
      final moved = [
        for (final k in before.keys)
          if (after[k] != null) after[k]!.dx - before[k]!.dx
      ];
      expect(moved.length, greaterThan(15), reason: 'a page with light on it');
      expect(moved.every((dx) => dx > 0), isTrue);
    });

    test('a spot out at the side is wider than one in the middle', () {
      final spots = spotsOnThePage(const Size(1400, 860), 0.3);
      final middle = spots.where((s) => (s.at.dx - 700).abs() < 120);
      final sides = spots.where((s) => (s.at.dx - 700).abs() > 550);
      expect(middle, isNotEmpty);
      expect(sides, isNotEmpty);
      expect(sides.map((s) => s.wide).reduce(math.min),
          greaterThan(middle.map((s) => s.wide).reduce(math.max)));
    });

    test('a whole turn brings every spot back to where it was', () {
      final a = spotsOnThePage(page, 0.4);
      final b = spotsOnThePage(page, 0.4 + 2 * math.pi);
      expect(b.length, a.length);
      for (var i = 0; i < a.length; i++) {
        expect((a[i].at - b[i].at).distance, lessThan(0.01));
      }
    });

    test('nothing lands on a page with no size', () {
      expect(spotsOnThePage(Size.zero, 0), isEmpty);
    });
  });
}
