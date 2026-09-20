// Finding one song in a list longer than a screen.
//
// The library's own lists have been searchable for a while; the lists *inside* it —
// a playlist of four hundred, a queue of nine thousand — could only be scrolled, which
// is where somebody is standing when they think "where is that song".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/track_list.dart';

Track song(int i, String title, String artist) => Track.fromJson({
      'id': i,
      'title': title,
      'artists': [artist],
      'album': 'A record',
      'state': 'ready',
      'source': 'youtube',
      'stream_url': '/tracks/$i/stream',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> show(WidgetTester tester, List<Track> tracks) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState()..api = ApiClient(baseUrl: 'http://example.invalid');
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: Scaffold(body: TrackList(tracks: tracks))),
    ));
    await tester.pump();
  }

  testWidgets('a long list can be searched, by title or by who made it',
      (tester) async {
    await show(tester, [
      for (var i = 0; i < 14; i++) song(i, 'Song number $i', 'Somebody $i'),
      song(99, 'Get Lucky', 'Daft Punk'),
    ]);

    expect(find.widgetWithText(TextField, 'Find in this list'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'daft');
    await tester.pumpAndSettle();

    expect(find.text('Get Lucky'), findsOneWidget);
    expect(find.text('Song number 3'), findsNothing,
        reason: 'the point of a search is what it leaves out');
  });

  testWidgets('a search that finds nothing says so', (tester) async {
    await show(tester, [for (var i = 0; i < 14; i++) song(i, 'Song $i', 'Band')]);
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing here matches'), findsOneWidget);
  });

  testWidgets('a short list is not given a search box it does not need',
      (tester) async {
    await show(tester, [for (var i = 0; i < 4; i++) song(i, 'Song $i', 'Band')]);
    expect(find.byType(TextField), findsNothing);
  });
}
