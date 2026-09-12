// The wait, as a field of spinners: evenly spaced, repeating, and anchored on the one
// that was there before.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/loading.dart';

void main() {
  const screen = Size(400, 800);

  test('the one in the middle is where the only one used to be', () {
    final spots = LoadingField.spots(screen);
    expect(spots.map((s) => s.at), contains(const Offset(200, 400)),
        reason: 'the lattice is laid out from the centre, so the middle spinner is '
            'exactly where a single centred one sits');
  });

  test('every circle has the same four neighbours, the same distance away', () {
    const step = 26.0;
    final spots = LoadingField.spots(screen, step: step);
    final places = spots.map((s) => s.at).toList();
    final diagonal = step * math.sqrt2;

    // Away from the edges, where the pattern is not cut off by the screen.
    final inside = places.where((p) =>
        p.dx > 60 && p.dx < screen.width - 60 &&
        p.dy > 60 && p.dy < screen.height - 60);
    expect(inside.length, greaterThan(20));

    for (final p in inside) {
      final near = places
          .where((q) => q != p && (q - p).distance < step * 1.9)
          .map((q) => (q - p).distance)
          .toList();
      expect(near.length, 4, reason: 'four nearest neighbours, no more and no less');
      for (final d in near) {
        expect(d, closeTo(diagonal, 0.01),
            reason: 'and all four the same distance away');
      }
    }
  });

  test('it repeats across the whole screen rather than clustering in the middle', () {
    final spots = LoadingField.spots(screen);
    expect(spots.length, greaterThan(150), reason: 'a pattern, not a handful');

    // Something in every corner region of the screen, which is what makes it a
    // repeating pattern rather than a diamond sitting in the middle of nothing.
    bool anyIn(Rect r) => spots.any((s) => r.contains(s.at));
    expect(anyIn(const Rect.fromLTWH(0, 0, 160, 200)), isTrue);
    expect(anyIn(const Rect.fromLTWH(240, 0, 160, 200)), isTrue);
    expect(anyIn(const Rect.fromLTWH(0, 600, 160, 200)), isTrue);
    expect(anyIn(const Rect.fromLTWH(240, 600, 160, 200)), isTrue);
  });

  test('nothing is cut off by the edge of the screen', () {
    for (final spot in LoadingField.spots(screen)) {
      const r = LoadingField.spinner / 2;
      expect(spot.at.dx - r, greaterThanOrEqualTo(0));
      expect(spot.at.dy - r, greaterThanOrEqualTo(0));
      expect(spot.at.dx + r, lessThanOrEqualTo(screen.width));
      expect(spot.at.dy + r, lessThanOrEqualTo(screen.height));
    }
  });

  test('the further out a circle is, the further behind it runs', () {
    final spots = LoadingField.spots(screen);
    final rings = spots.map((s) => s.ring).toSet();
    expect(rings.length, greaterThan(5), reason: 'plenty of phases to go round');
    expect(rings.contains(0), isTrue, reason: 'the middle one leads');
  });

  testWidgets('it draws, and keeps drawing', (tester) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LoadingField())));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
