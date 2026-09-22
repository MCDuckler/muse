// A search is one list.
//
// A song the library holds was drawn on the song row; every other hit — the same song
// from YouTube Music, a record, an artist — was a stock ListTile: a bigger picture, a
// different height, nothing under the finger and no swipe. Two kinds of row in one
// list, and only one of them could be pushed aside.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/found_row.dart';
import 'package:muse/src/ui/song_row.dart';
import 'package:muse/src/ui/swipe.dart';

Found hit(String kind, {String place = 'ytmusic', Track? track}) => Found(
      kind: kind,
      place: place,
      id: 'x1',
      title: 'Title',
      subtitle: 'Somebody',
      durationMs: 200000,
      track: track,
    );

Track song() => Track.fromJson({
      'id': 7,
      'title': 'Title',
      'artists': ['Somebody'],
      'state': 'ready',
      'stream_url': '/tracks/7/stream',
      'source': 'youtube',
    });

void main() {
  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  Future<void> show(WidgetTester tester, Widget row) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: Scaffold(body: Column(children: [row]))),
    ));
    await tester.pump();
  }

  testWidgets('a hit from a service can be pushed aside to play next', (tester) async {
    var next = false;
    await show(tester, FoundRow(found: hit('song'), onTap: () {}, onAdd: () {},
        onPlayNext: () => next = true));
    expect(find.byType(SwipeAction), findsOneWidget,
        reason: 'the same gesture as every other row of songs');

    // In steps, the way a finger moves: one eighty-pixel jump never clears the
    // recogniser's slop as a drag.
    final gesture = await tester.startGesture(tester.getCenter(find.text('Title')));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(next, isTrue);
  });

  testWidgets('a record or an artist opens, and is not pushed', (tester) async {
    await show(tester, FoundRow(found: hit('album'), onTap: () {}, onPlayNext: () {}));
    expect(find.byType(SwipeAction), findsNothing,
        reason: 'there is nothing to queue until the record is opened');
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('a hit from a service has the rest of its menu', (tester) async {
    var more = 0;
    await show(tester, FoundRow(found: hit('song'), onTap: () {}, onAdd: () {},
        onMore: () => more++));
    await tester.tap(find.byTooltip('More'));
    expect(more, 1, reason: 'the three dots');
    await tester.longPress(find.text('Title'));
    await tester.pump(const Duration(seconds: 1));
    expect(more, 2, reason: 'and a hold, like a song of the library');
  });

  testWidgets('a hit the library holds is the library row, and the rest stand level with it',
      (tester) async {
    await show(
        tester,
        Column(children: [
          FoundRow(found: hit('song', place: 'library', track: song()), onTap: () {}),
          FoundRow(found: hit('song'), onTap: () {}, onAdd: () {}),
        ]));
    expect(find.byType(SongRow), findsOneWidget);
    final rows = tester.widgetList(find.byType(FoundRow)).toList();
    final a = tester.getSize(find.byWidget(rows[0]));
    final b = tester.getSize(find.byWidget(rows[1]));
    expect(a.height, b.height, reason: 'one list, one row height');
    // And one picture size: the artwork on both is the row's forty pixels.
    final arts = tester.widgetList<SizedBox>(find.descendant(
        of: find.byType(FoundRow),
        matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 40 && w.height == 40)));
    expect(arts.length, greaterThanOrEqualTo(2));
  });
}
