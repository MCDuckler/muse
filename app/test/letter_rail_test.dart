// The alphabet down the side of a long list.
//
// A finger on the rail goes to the letter under it and says which; dragged through
// several, the list ends up at the last one rather than visiting each; and going to a
// letter fetches that far first, because the rows in between have not arrived yet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/letter_rail.dart';

void main() {
  testWidgets('a finger on the rail says which letter, large, and asks for it',
      (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: LetterRail(letters: const ['#', 'A', 'B', 'M', 'T'], onLetter: asked.add),
        ),
      ),
    ));
    final rail = tester.getRect(find.byType(GestureDetector).first);
    final finger = await tester.startGesture(rail.topCenter + const Offset(0, 4));
    await tester.pump();
    expect(asked, ['#']);

    await finger.moveTo(rail.bottomCenter - const Offset(0, 4));
    await tester.pump();
    expect(asked.last, 'T');
    expect(asked.toSet().length, asked.length, reason: 'each letter once as it is passed');
    // The sticker beside the thumb, as well as the small one in the rail.
    expect(find.text('T'), findsNWidgets(2));

    await finger.up();
    await tester.pump();
    expect(find.text('T'), findsOneWidget, reason: 'and gone when the finger is');
  });

  testWidgets('a rail with one letter on it is no rail', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LetterRail(letters: const ['A'], onLetter: (_) {})),
    ));
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('going to a letter fetches that far, then puts the list there',
      (tester) async {
    var have = 30;
    final reached = <int>[];
    late StateSetter redraw;
    late final LetterJump jump;
    jump = LetterJump(
      ask: () async => [(letter: 'A', offset: 0), (letter: 'M', offset: 120), (letter: 'T', offset: 200)],
      reach: (i) async {
        reached.add(i);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (i >= have) redraw(() => have = i + 50);
      },
      pixelsTo: (i) => i * 50.0,
    );
    await jump.load();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          redraw = setState;
          return ListView.builder(
            controller: jump.scroll,
            itemExtent: 50,
            itemCount: have,
            itemBuilder: (_, i) => Text('Row $i'),
          );
        }),
      ),
    ));

    // Dragged through M on the way to T: both are asked for, the list goes to T.
    final m = jump.go('M');
    final t = jump.go('T');
    await tester.pump(const Duration(milliseconds: 30));
    await m;
    await t;
    // A frame to find out how long the list has become, and one to go there.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(reached, [120, 200]);
    expect(jump.scroll.offset, 200 * 50.0);
    expect(find.text('Row 200'), findsOneWidget);
    jump.dispose();
  });
}
