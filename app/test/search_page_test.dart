// One search, one list.
//
// The screen used to be four lists one under another, one per service. What this is
// about is that it is not any more: the rows are ranked together, they are all the
// same shape, and each one says where it came from.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/found_row.dart';
import 'package:muse/src/ui/search_page.dart';

Map<String, dynamic> row(String kind, String place, String title,
        {String subtitle = 'Someone', String? lyric, Map<String, dynamic>? track}) =>
    {
      'kind': kind,
      'place': place,
      'id': '$place-$title',
      'title': title,
      'subtitle': subtitle,
      'cover_url': '/art/remote?u=x',
      if (lyric != null) 'lyric': lyric,
      if (track != null) 'track': track,
      'known': track != null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<Uri> asked;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    asked = [];
    // No socket: the answers come straight back, so the whole screen can be driven on
    // the test's own clock.
    useThisClientInstead(MockClient((request) async {
      asked.add(request.url);
      return http.Response(
        jsonEncode({
          'items': [
            row('song', 'library', 'Bohemian Rhapsody',
                subtitle: 'Queen',
                track: {
                  'id': 1,
                  'title': 'Bohemian Rhapsody',
                  'artists': ['Queen'],
                  'state': 'ready',
                  'stream_url': '/tracks/1/stream',
                }),
            row('album', 'ytmusic', 'A Night at the Opera', subtitle: 'Queen'),
            row('song', 'spotify', 'Bohemian Rhapsody - Live', subtitle: 'Queen'),
            row('artist', 'soundcloud', 'Queen tribute'),
          ],
          'notes': {'bandcamp': 'Bandcamp would not answer'},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }));

    final api = ApiClient(baseUrl: 'http://example.invalid');
    api.token = 'test-token';
    app = AppState()..api = api;
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: Scaffold(body: SearchPage())),
    ));
    await tester.pump();
  }

  /// Type, wait out the debounce, and let the request actually happen.
  ///
  /// Two clocks: the debounce runs on the test's own, and the request runs on the
  /// real one — so pumping alone leaves the search still in flight.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));   // past the debounce
    await tester.pump();                                    // and the answer lands
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String what) async {
    await tester.enterText(find.byType(TextField), what);
    await settle(tester);
  }

  testWidgets('everything lands in one list, whatever it is and wherever it is from',
      (tester) async {
    await show(tester);
    await type(tester, 'queen');

    expect(tester.takeException(), isNull);
    // Four rows, one list, in the order the server ranked them — not grouped under a
    // heading per service, which is the thing this replaced.
    expect(find.byType(FoundRow), findsNWidgets(4));
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);
    expect(find.text('A Night at the Opera'), findsOneWidget);
    expect(find.text('Queen tribute'), findsOneWidget);
    expect(find.textContaining('On YouTube Music'), findsNothing,
        reason: 'no section headings: the list is one list');

    // And every row says where it came from.
    expect(find.byType(PlaceDot), findsWidgets);
  });

  testWidgets('a service that would not answer says so, without emptying the list',
      (tester) async {
    await show(tester);
    await type(tester, 'queen');
    expect(find.text('Bandcamp would not answer'), findsOneWidget);
    expect(find.byType(FoundRow), findsNWidgets(4));
  });

  testWidgets('narrowing to one service asks for that service', (tester) async {
    await show(tester);
    await type(tester, 'queen');
    asked.clear();

    // Whichever chip is on screen at this width — the row scrolls, and what is being
    // checked is that picking one narrows the question.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Library'));
    await settle(tester);

    expect(asked.last.queryParameters['where'], 'library');
  });

  testWidgets('asking by the words asks a different question', (tester) async {
    await show(tester);
    await type(tester, 'is this just fantasy');
    asked.clear();

    await tester.tap(find.widgetWithText(FilterChip, 'Lyrics'));
    await settle(tester);

    expect(asked.last.queryParameters['lyrics'], 'true');
    expect(asked.last.queryParameters['kind'], 'song',
        reason: 'a record has no lyrics');
    // The kind chips are gone while it is on, because there is only one kind.
    expect(find.widgetWithText(ChoiceChip, 'Albums'), findsNothing);
  });
}
