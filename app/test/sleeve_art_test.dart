// A sleeve for a song with no cover.
//
// What most of this library looks like: eighteen thousand of its songs have no artwork
// yet. So the printed sleeve has to be the same for the same song every time, different
// between songs, and it has to print — at the size of a list row and at the size of a
// whole screen, for a title of one letter or of sixty, in German as well as English —
// without ever throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/sleeve_art.dart';

void main() {
  test('the same song gets the same sleeve', () {
    final a = SleevePainter(seed: 4211, title: 'Night Bus');
    final b = SleevePainter(seed: 4211, title: 'Night Bus');
    expect(a.layout, b.layout);
    expect(a.inks, b.inks);
    expect(PrintedSleeve.seedOf('Night Bus'), PrintedSleeve.seedOf('Night Bus'));
  });

  test('a shelf of songs is not one sleeve repeated', () {
    final layouts = <SleeveLayout>{};
    final inks = <(Color, Color)>{};
    for (var id = 1; id <= 40; id++) {
      final p = SleevePainter(seed: id, title: 'x');
      layouts.add(p.layout);
      inks.add(p.inks);
    }
    // Neighbouring ids — which is what a list of recently added songs is — still
    // spread across the whole shop.
    expect(layouts.length, SleeveLayout.values.length);
    expect(inks.length, sleeveInks.length);
  });

  testWidgets('every layout prints, at every size, whatever the title',
      (tester) async {
    // Find a seed for each layout, so each one is drawn on purpose.
    final seeds = <SleeveLayout, int>{};
    for (var id = 1; seeds.length < SleeveLayout.values.length; id++) {
      seeds.putIfAbsent(SleevePainter(seed: id, title: '').layout, () => id);
    }
    const titles = [
      '',
      'X',
      'Everything In Its Right Place (2017 Remastered Anniversary Edition)',
      'Größenwahn über Düsseldorf',
      '!!!',
    ];
    for (final seed in seeds.values) {
      for (final size in [24.0, 44.0, 120.0, 360.0]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: Wrap(children: [
              for (final t in titles) PrintedSleeve(seed: seed, title: t, size: size),
            ]),
          ),
        ));
        expect(tester.takeException(), isNull, reason: 'seed $seed at $size');
      }
    }
  });
}
