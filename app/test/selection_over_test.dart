// The selection bar is somewhere a finger can reach.
//
// Every list in the app runs underneath the glass player and tabs, so the bottom of a
// list's box is behind them. A bar placed from that edge was drawn under the player —
// visible through the glass, impossible to press.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/selection_bar.dart';

void main() {
  testWidgets('the selection bar sits above what floats over the list',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const floating = 130.0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // As the home screen and every pushed page lay it out.
        extendBody: true,
        bottomNavigationBar: const SizedBox(
            key: Key('player'), height: floating, child: ColoredBox(color: Colors.black)),
        body: SelectionOver(
          bar: const SizedBox(key: Key('bar'), height: 48),
          child: ListView(children: [for (var i = 0; i < 40; i++) Text('row $i')]),
        ),
      ),
    ));

    final bar = tester.getRect(find.byKey(const Key('bar')));
    final player = tester.getRect(find.byKey(const Key('player')));
    expect(bar.bottom, lessThanOrEqualTo(player.top),
        reason: 'the bar ends above the player ($bar, player at $player)');
    await tester.tap(find.byKey(const Key('bar')));
  });
}
