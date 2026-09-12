// A line of text that walks when it is too long, and holds still when it is not.
//
// The point of it is not the movement: it is that the block a title sits in is the
// same height for every song, because that block is above the record in a centred
// column and anything that changes its height moves the picture.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/back_and_forth.dart';

/// Where the text has got to, from the transform the walk is drawn through.
double? walkedTo(WidgetTester tester) {
  final t = tester.widgetList<Transform>(find.descendant(
      of: find.byType(BackAndForth), matching: find.byType(Transform)));
  if (t.isEmpty) return null;
  return t.first.transform.getTranslation().x;
}

Future<void> show(WidgetTester tester, String text, {double width = 120}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: BackAndForth(text, style: const TextStyle(fontSize: 20)),
          ),
        ),
      ),
    ));

void main() {
  testWidgets('a name that fits holds still', (tester) async {
    await show(tester, 'Blue');
    await tester.pump(const Duration(seconds: 2));
    expect(walkedTo(tester), isNull,
        reason: 'nothing is moving it, so there is no ticker behind it either');
    expect(find.text('Blue'), findsOneWidget);
  });

  testWidgets('a name that does not fit walks, and comes back', (tester) async {
    await show(tester, 'Sound of Silence');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final start = walkedTo(tester);
    expect(start, isNotNull, reason: 'it is too long, so it is being walked');
    expect(start, 0, reason: 'and it starts at the beginning of the name');

    // Past the hold at the start, it is moving.
    await tester.pump(const Duration(milliseconds: 3000));
    final away = walkedTo(tester)!;
    expect(away, lessThan(-1), reason: 'the far end of the name is coming into view');

    // And it turns round rather than snapping back to the start.
    var furthest = away;
    var turned = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final now = walkedTo(tester)!;
      if (now < furthest) furthest = now;
      // Back the way it came, rather than snapping to the start.
      if (furthest < away - 1 && now > furthest + 1) turned = true;
    }
    expect(furthest, lessThan(away), reason: 'it kept going');
    expect(turned, isTrue, reason: 'and came back the way it went');
  });

  testWidgets('the block is the same height whatever the name is', (tester) async {
    // The whole reason this exists: a title that wrapped to two lines shoved the
    // record up the screen, so going from one song to the next moved the picture as
    // much as it changed it.
    await show(tester, 'Blue');
    final short = tester.getSize(find.byType(BackAndForth));
    await show(tester, 'Sound of Silence (Extended Mix), live at the Bowl');
    final long = tester.getSize(find.byType(BackAndForth));
    expect(long.height, short.height);
  });
}
