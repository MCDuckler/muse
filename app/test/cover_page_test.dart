// Home: this week's issue.
//
// The cover is written from what is true — so the test is that it says what the server
// says, that a part with nothing to say is left off rather than printed as a zero, that
// a first issue with nothing played still has a cover, and that none of it breaks on a
// small phone with the type turned up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/cover_page.dart';
import 'package:muse/src/ui/mag_parts.dart';

Map<String, dynamic> stats({bool played = true}) => {
      'who': {'id': 1, 'name': 'chris'},
      'since': 'week',
      'totals': {'plays': played ? 41 : 0, 'minutes': played ? 152 : 0},
      'songs': played
          ? [
              {'id': 7, 'title': 'Tape Hiss', 'artists': ['Morning Static'], 'plays': 14},
              {'id': 8, 'title': 'Salt on the Window', 'artists': ['Low Tide Radio'], 'plays': 9},
              {'id': 9, 'title': 'Night Bus', 'artists': ['The Overhead Lights'], 'plays': 8},
            ]
          : [],
    };

Map<String, dynamic> people() => {
      'you': 1,
      'people': [
        {'id': 1, 'name': 'chris', 'songs': 10, 'playlists': 1},
        {
          'id': 2,
          'name': 'Joe',
          'songs': 3,
          'playlists': 1,
          'playing': {
            'track': {'id': 40, 'title': 'Harbour Lights', 'artists': ['Low Tide Radio'], 'state': 'ready'},
            'now': true,
          },
        },
        {
          'id': 3,
          'name': 'Sam',
          'songs': 3,
          'playlists': 1,
          // Played an hour ago and stopped: not "spotted" now.
          'playing': {
            'track': {'id': 41, 'title': 'Low Water', 'artists': ['Low Tide Radio'], 'state': 'ready'},
            'now': false,
          },
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  var played = true;
  var unseen = 3;

  setUp(() {
    played = true;
    unseen = 3;
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final body = switch (request.url.path) {
        '/library/stats' => stats(played: played),
        '/feed' => {'items': [], 'unseen': unseen, 'following': 12},
        '/social/people' => people(),
        '/library/tracks' => {
            'items': [
              {'id': 50, 'title': 'Just Arrived', 'artists': ['Somebody'], 'state': 'ready'},
            ],
            'total': 1,
          },
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, {Size size = const Size(420, 900), double text = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(text)),
          child: const Scaffold(body: CoverPage()),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('the cover says what is true this week', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Masthead), findsOneWidget);
    expect(find.text('No. ${issueNumber(DateTime.now())}'), findsOneWidget);
    expect(find.text('TAPE HISS'), findsOneWidget, reason: 'the cover star');
    expect(find.textContaining('14 plays'), findsOneWidget);
    expect(find.text('NEW RECORDS'), findsOneWidget);
    expect(find.textContaining('Spotted: Joe'), findsOneWidget);
    expect(find.textContaining('Spotted: Sam'), findsNothing,
        reason: 'somebody who stopped an hour ago is not listening now');
  });

  testWidgets('nothing new is not printed as a zero', (tester) async {
    unseen = 0;
    await show(tester);
    expect(find.text('NEW RECORDS'), findsNothing);
    expect(find.byType(Starburst), findsNothing);
  });

  testWidgets('a first issue, with nothing played, still has a cover', (tester) async {
    played = false;
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('NOTHING PLAYED'), findsOneWidget);
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await show(tester, size: const Size(320, 640), text: scale);
      expect(tester.takeException(), isNull);
    });
  }

  test('the issue number is the week of the year', () {
    expect(issueNumber(DateTime(2026, 9, 21)), 39);
    expect(issueNumber(DateTime(2026, 1, 1)), 1, reason: 'a Thursday: week one');
    expect(issueNumber(DateTime(2027, 1, 1)), 53, reason: 'a Friday: still 2026');
    expect(coverDate(DateTime(2026, 9, 21)), '21 Sep 2026');
  });
}
