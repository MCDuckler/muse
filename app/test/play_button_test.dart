// The play button.
//
// It is one size whatever is happening: the ring that says "the stream is opening" used
// to make it a bigger box while it showed, and the whole row of controls moved with it
// on every skip. And it is a button: it says what it does, and does it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/now_playing.dart';

void main() {
  Future<void> show(WidgetTester tester, {required bool busy, VoidCallback? onPressed}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.skip_previous, key: Key('before')),
                PlayPauseButton(
                    playing: true, size: 42, busy: busy, onPressed: onPressed ?? () {}),
                const Icon(Icons.skip_next, key: Key('after')),
              ],
            ),
          ),
        ),
      ));

  testWidgets('the ring coming and going moves nothing', (tester) async {
    await show(tester, busy: false);
    final size = tester.getSize(find.byType(PlayPauseButton));
    final before = tester.getTopLeft(find.byKey(const Key('before')));
    final after = tester.getTopLeft(find.byKey(const Key('after')));

    await show(tester, busy: true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getSize(find.byType(PlayPauseButton)), size);
    expect(tester.getTopLeft(find.byKey(const Key('before'))), before);
    expect(tester.getTopLeft(find.byKey(const Key('after'))), after);

    await show(tester, busy: false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.getSize(find.byType(PlayPauseButton)), size);
  });

  testWidgets('it says what it does, and does it', (tester) async {
    var pressed = 0;
    await show(tester, busy: false, onPressed: () => pressed++);
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    await tester.tap(find.byType(PlayPauseButton));
    await tester.pump(const Duration(milliseconds: 120));
    expect(pressed, 1);
  });
}
