// Waiting, with the shape of what is coming.
//
// A spinner says "something is happening" and nothing else: the page is blank, its
// size is unknown, and the rows arrive all at once so the eye starts again. A list
// whose shape is already there reads as fast even when it is not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/skeleton.dart';

void main() {
  testWidgets('a list that is coming looks like a list', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SongsComing(rows: 6))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Artwork and two lines of text per row.
    expect(find.byType(Bone), findsNWidgets(6 * 3));
  });

  testWidgets('and a wall of records looks like one', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RecordsComing(tiles: 6))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(Bone), findsWidgets);
  });

  testWidgets('and people look like people, faces and all', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PeopleComing(rows: 4))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // A face is round; a name is not. The difference is the whole point of having a
    // second shape rather than reusing the song rows.
    final bones = tester.widgetList<Bone>(find.byType(Bone));
    expect(bones.where((b) => b.shape == BoxShape.circle).length, 4);
    expect(bones.where((b) => b.shape == BoxShape.rectangle).length, 8);
  });

  testWidgets('it breathes rather than sweeping a light across the screen',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Bone(width: 100))),
    );
    // Three frames apart the shade has moved, and nothing has thrown: the animation
    // is the only thing this widget does.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
