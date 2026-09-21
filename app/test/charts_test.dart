// The charts.
//
// A chart is a ranking that moves. So the claims are about movement: up and down by
// the right amount, NEW for what was not on the last chart, "=" for what held still,
// weeks on chart for how long it has been there — and nothing at all about movement on
// the all-time chart, which has no last week to compare with.
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
import 'package:muse/src/ui/listening_page.dart';

Map<String, dynamic> song(int id, String title, int rank, int? last, int charts, int plays) => {
      'id': id,
      'title': title,
      'artists': ['Somebody'],
      'plays': plays,
      'started': plays,
      'rank': rank,
      'last_rank': last,
      'charts': charts,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  final asked = <String>[];
  var empty = false;

  setUp(() {
    asked.clear();
    empty = false;
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final since = request.url.queryParameters['since'] ?? '';
      asked.add(since);
      final body = {
        'who': {'id': 1, 'name': 'chris'},
        'since': since,
        'people': [
          {'id': 1, 'name': 'chris'}
        ],
        'totals': {'plays': empty ? 0 : 41, 'started': empty ? 0 : 44, 'minutes': 152, 'tracks': 18},
        'songs': empty
            ? []
            : [
                song(1, 'Tape Hiss', 1, 1, 3, 14),
                song(2, 'Salt on the Window', 2, 5, 2, 9),
                song(3, 'Night Bus', 3, null, 1, 8),
                song(4, 'Harbour Lights', 4, 2, 5, 7),
                song(5, 'Dunes', 5, 5, 3, 6),
              ],
        'artists': [
          {'name': 'Low Tide Radio', 'plays': 16}
        ],
        'albums': [],
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, {Size size = const Size(420, 1400), double text = 1}) async {
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
          child: const ListeningPage(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a weekly chart, with its movement', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(asked.first, 'week', reason: 'a chart is a weekly thing first');
    expect(find.text('TAPE HISS'), findsOneWidget, reason: 'the number one, set big');
    expect(find.text('No.1'.toUpperCase()), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'\bup 3\b')), findsOneWidget,
        reason: 'fifth last week, second now');
    expect(find.text('NEW'), findsOneWidget, reason: 'not on last week\'s chart');
    expect(find.bySemanticsLabel(RegExp(r'\bdown 2\b')), findsOneWidget,
        reason: 'second last week, fourth now');
    expect(find.bySemanticsLabel(RegExp(r'no change')), findsNWidgets(2), reason: 'number one held, and fifth held');
    expect(find.text('5 wks'), findsOneWidget);
  });

  testWidgets('the all-time chart has nothing to move against', (tester) async {
    await show(tester);
    await tester.tap(find.text('ALL TIME'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(asked.last, 'all');
    expect(find.text('NEW'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'\bup 3\b')), findsNothing);
  });

  testWidgets('an empty stretch says there is no chart rather than printing zeros',
      (tester) async {
    empty = true;
    await show(tester);
    expect(find.textContaining('no chart to print'), findsOneWidget);
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await show(tester, size: const Size(320, 1800), text: scale);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a server from before charts moved gets positions and no arrows',
      (tester) async {
    useThisClientInstead(MockClient((request) async => http.Response(
        jsonEncode({
          'who': {'id': 1, 'name': 'chris'},
          'since': 'week',
          'totals': {'plays': 5, 'started': 5},
          'songs': [
            {'id': 1, 'title': 'A', 'artists': ['x'], 'plays': 3},
            {'id': 2, 'title': 'B', 'artists': ['x'], 'plays': 2},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'})));
    await show(tester);
    expect(find.text('NEW'), findsNothing, reason: 'not every song is new');
    expect(find.text('2'), findsOneWidget, reason: 'positions from the order');
  });
}
