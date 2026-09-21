import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/theme.dart';

void main() {
  // MaterialApp cross-fades between any two themes that are not equal, and a theme
  // holding closures is only ever equal to itself. Built fresh on each rebuild, that was
  // every themed surface drifting pale and back whenever the app state spoke.
  test('asking for the theme twice gives the very same theme', () {
    expect(identical(MuseTheme.light(), MuseTheme.light()), isTrue);
    expect(identical(MuseTheme.dark(), MuseTheme.dark()), isTrue);
    expect(identical(MuseTheme.compact(MuseTheme.light()),
        MuseTheme.compact(MuseTheme.light())), isTrue);
    expect(MuseTheme.light(Palette.red), isNot(MuseTheme.dark(Palette.red)));
  });

  testWidgets('rebuilding the app does not repaint its controls a different colour', (tester) async {
    final key = GlobalKey();
    Widget app(ThemeData theme) => MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.skip_previous), onPressed: () {}),
                  Builder(
                      builder: (context) => IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                              fixedSize: const Size.square(40),
                            ),
                            icon: const Icon(Icons.pause),
                            onPressed: () {},
                          )),
                  FilledButton(onPressed: () {}, child: const Text('Go')),
                ]),
              ),
            ),
          ),
        );

    Future<List<int>> shot() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      late List<int> bytes;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        bytes = data!.buffer.asUint8List().toList();
      });
      return bytes;
    }

    await tester.pumpWidget(app(MuseTheme.light()));
    await tester.pumpAndSettle();
    final before = await shot();
    await tester.pumpWidget(app(MuseTheme.light()));
    var worst = 0;
    for (var ms = 0; ms <= 240; ms += 20) {
      await tester.pump(const Duration(milliseconds: 20));
      final now = await shot();
      var diff = 0;
      for (var i = 0; i < now.length; i++) {
        final d = (now[i] - before[i]).abs();
        if (d > diff) diff = d;
      }
      if (diff > worst) worst = diff;
    }
    expect(worst, 0, reason: 'nothing changed, so nothing may be drawn differently');
  });
}
