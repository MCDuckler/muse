// The tonearm you can pick up.
//
// Two things to hold it to. The arithmetic: the needle is on the groove the song has
// reached, the start of a side is out near the rim and the end is just outside the
// picture in the middle, and "where was it put down" reads back as the same place.
// And the hand: a finger on the arm takes it — even where the arm hangs outside the
// stage's own box, which on a phone is most of it — a finger anywhere else does not,
// and letting go plays from there or, off the edge of the record, stops.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/record_stage.dart';
import 'package:muse/src/ui/stage/arm_geometry.dart';
import 'package:muse/src/ui/stage/arm_grip.dart';

void main() {
  const box = Size(400, 400);
  const radius = 210.0;
  const drop = -52.0;

  ArmGeometry geometry({double label = 0.31}) =>
      ArmGeometry.of(box, radius: radius, drop: drop, label: label);

  double reach(ArmGeometry g, double angle) => (g.needleAt(angle) - g.middle).distance;

  group('where the needle is', () {
    test('a side starts in from the rim and ends outside the label', () {
      final g = geometry();
      expect(reach(g, g.playing(0)), closeTo(radius * 0.86, 0.5));
      expect(reach(g, g.playing(1)), closeTo(radius * (0.31 + 0.07), 0.5));
    });

    test('the needle only ever moves inwards as the song plays', () {
      final g = geometry();
      var last = double.infinity;
      for (var i = 0; i <= 20; i++) {
        final r = reach(g, g.playing(i / 20));
        expect(r, lessThan(last + 1e-9));
        last = r;
      }
    });

    test('parked is off the record, and the same length of arm', () {
      final g = geometry();
      expect(g.offRecord(g.parked), isTrue);
      expect((g.needleAt(g.parked) - g.pivot).distance, closeTo(g.length, 1e-6));
      expect(g.offRecord(g.playing(0)), isFalse);
    });

    test('where it was put down reads back as the same place', () {
      final g = geometry();
      for (final at in [0.0, 0.1, 0.37, 0.5, 0.92, 1.0]) {
        expect(g.grooveOf(g.playing(at)), closeTo(at, 1e-6));
      }
    });

    test('lowering the arm goes from the rest to the groove, nowhere else', () {
      final g = geometry();
      expect(g.angle(landed: 0, groove: 0.6), closeTo(g.parked, 1e-9));
      expect(g.angle(landed: 1, groove: 0.6), closeTo(g.playing(0.6), 1e-9));
    });

    test('a hand cannot push it past the rest or past the end of the side', () {
      final g = geometry();
      final pastEnd = g.playing(1) + ArmGeometry.turn(g.parked, g.playing(1)).sign * 0.5;
      expect(g.grooveOf(g.clamp(pastEnd)), closeTo(1, 1e-6));
      final pastRest = g.parked - ArmGeometry.turn(g.parked, g.playing(1)).sign * 0.5;
      expect(g.clamp(pastRest), closeTo(g.parked, 1e-9));
    });

    test('a label the size of the record leaves nowhere to travel, and nothing breaks',
        () {
      final g = geometry(label: 0.92);
      expect(g.inner, g.outer);
      expect(g.grooveOf(g.playing(0.5)), 0);
    });

    test('the arm points left, across the wrap, and still measures right', () {
      // The needle sits a little past straight left of the post, where an angle on the
      // screen flips from π to -π. Everything above only holds if that is handled.
      final g = geometry();
      expect(g.playing(0).abs(), greaterThan(math.pi * 0.9));
    });
  });

  group('a hand on the arm', () {
    late List<Duration> placed;
    late int parked;
    late ValueNotifier<ArmReading> reading;

    setUp(() {
      placed = [];
      parked = 0;
      reading = ValueNotifier(const ArmReading(
          position: Duration(seconds: 30),
          length: Duration(seconds: 300),
          playing: true));
    });

    ArmHand hand() => ArmHand(
          reading: reading,
          onPlace: placed.add,
          onPark: () => parked++,
        );

    /// The arm in a box the size of a cover, with room around it — the way the stage
    /// hangs it on a phone, where most of the arm is above the box it belongs to.
    Future<ArmGeometry> show(WidgetTester tester, {bool reach = true}) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final arm = Center(
        child: SizedBox(
          width: box.width,
          height: box.height,
          child: Tonearm(
            radius: radius,
            drop: drop,
            landed: 1,
            style: ArmStyle.classic,
            hand: hand(),
          ),
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: reach ? ArmReach(child: arm) : arm),
      ));
      await tester.pump();
      return geometry();
    }

    /// A point in the arm's box, on the screen.
    Offset onScreen(WidgetTester tester, Offset local) =>
        tester.getTopLeft(find.byType(Tonearm)) + local;

    testWidgets('picked up by the headshell, even outside the stage, and put down later',
        (tester) async {
      final g = await show(tester);
      final needle = g.needleAt(g.playing(reading.value.groove));
      expect(needle.dy, lessThan(0), reason: 'the head hangs above its own box');

      final gesture = await tester.startGesture(onScreen(tester, needle));
      await tester.pump();
      // Round the post towards the middle of the record: later in the song.
      final later = g.needleAt(g.playing(0.6));
      await gesture.moveTo(onScreen(tester, later), timeStamp: const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('3:00'), findsOneWidget, reason: 'the time it will play from');
      await gesture.up();
      await tester.pump();

      expect(placed, hasLength(1));
      expect(placed.single.inMilliseconds, closeTo(180000, 2000));
      expect(parked, 0);
    });

    testWidgets('let go off the edge of the record, it goes back on its rest',
        (tester) async {
      final g = await show(tester);
      final needle = g.needleAt(g.playing(reading.value.groove));
      final gesture = await tester.startGesture(onScreen(tester, needle));
      await tester.pump();
      await gesture.moveTo(onScreen(tester, g.needleAt(g.parked)));
      await tester.pump();
      expect(find.text('Lift off'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(parked, 1);
      expect(placed, isEmpty);
    });

    testWidgets('a tap lifts a playing arm off, and puts a parked one back down',
        (tester) async {
      final g = await show(tester);
      await tester.tapAt(onScreen(tester, g.needleAt(g.playing(reading.value.groove))));
      await tester.pumpAndSettle();
      expect(parked, 1);

      reading.value = const ArmReading(
          position: Duration(seconds: 30), length: Duration(seconds: 300));
      await tester.pumpWidget(const SizedBox());
      final g2 = await show(tester);
      await tester.tapAt(onScreen(tester, g2.needleAt(g2.playing(0.1))));
      await tester.pumpAndSettle();
      expect(placed.single, const Duration(seconds: 30),
          reason: 'down where the song was stopped');
    });

    testWidgets('a finger that is not on the arm is not taken', (tester) async {
      var tapped = 0;
      final g = geometry();
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArmReach(
            child: Stack(children: [
              Positioned.fill(
                child: GestureDetector(onTap: () => tapped++, behavior: HitTestBehavior.opaque),
              ),
              Center(
                child: SizedBox(
                  width: box.width,
                  height: box.height,
                  child: Tonearm(
                      radius: radius,
                      drop: drop,
                      landed: 1,
                      style: ArmStyle.classic,
                      hand: hand()),
                ),
              ),
            ]),
          ),
        ),
      ));
      await tester.pump();
      // The middle of the record: nowhere near the arm.
      await tester.tapAt(onScreen(tester, g.middle));
      await tester.pump();
      expect(tapped, 1);
      expect(placed, isEmpty);
      expect(parked, 0);
    });

    testWidgets('without a hand the arm is a picture and cannot be taken', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ArmReach(
            child: Center(
              child: SizedBox(
                width: 400,
                height: 400,
                child: Tonearm(radius: radius, drop: drop, landed: 1, style: ArmStyle.classic),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(ArmGrip), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
