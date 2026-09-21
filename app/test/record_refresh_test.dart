// Pull to refresh, as a record being put on.
//
// The pulling is Flutter's own; what is checked is that ours is what is drawn, that a
// pull far enough still refreshes, that the record stays for as long as that takes and
// goes when it is done, and that a pull let go early refreshes nothing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/record_refresh.dart';

void main() {
  Future<void> show(WidgetTester tester, Future<void> Function() onRefresh) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RecordRefresh(
            onRefresh: onRefresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [for (var i = 0; i < 30; i++) ListTile(title: Text('Row $i'))],
            ),
          ),
        ),
      ));

  Finder deck() => find.descendant(
      of: find.byType(RecordRefresh),
      matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && '${w.painter.runtimeType}' == '_SmallDeck'));

  testWidgets('a pull far enough puts the record on until the page is back',
      (tester) async {
    final back = Completer<void>();
    var asked = 0;
    await show(tester, () {
      asked++;
      return back.future;
    });
    expect(deck(), findsNothing, reason: 'nothing hanging over a list left alone');
    expect(find.byType(RefreshProgressIndicator), findsNothing);

    await tester.drag(find.text('Row 1'), const Offset(0, 320));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(asked, 1);
    expect(deck(), findsOneWidget, reason: 'turning for as long as it takes');
    expect(find.byType(RefreshProgressIndicator), findsNothing,
        reason: "and not the platform's grey circle as well");

    back.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(deck(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('let go early, it refreshes nothing and goes away', (tester) async {
    var asked = 0;
    await show(tester, () async => asked++);
    final finger = await tester.startGesture(tester.getCenter(find.text('Row 1')));
    await finger.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(deck(), findsOneWidget, reason: 'on its way down with the finger');
    await finger.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(asked, 0);
    expect(deck(), findsNothing);
  });
}
