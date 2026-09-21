// An artist's page, set as a profile.
//
// The name pasted over their picture, the counts that are true, FOLLOW loud until it is
// pressed and quiet after, the sections under their flags — and the whole thing holding
// on a small phone with the type turned up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/browse_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  var following = false;

  setUp(() {
    following = false;
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final body = request.url.path == '/library/artists/detail'
          ? {
              'artist': {
                'name': 'Low Tide Radio',
                'remote_id': 'a1',
                'following': following,
                'fans': 12400,
              },
              'albums': [
                {'remote_id': 'r1', 'title': 'Salt on the Window', 'release_date': '1994', 'have': 3},
                {'remote_id': 'r2', 'title': 'Grey Gulls', 'release_date': '1996', 'have': 0},
              ],
              'top': [
                {'pos': 1, 'title': 'Harbour Lights'},
              ],
              'tracks': [
                {'id': 1, 'title': 'Harbour Lights', 'artists': ['Low Tide Radio'], 'state': 'ready'},
                {'id': 2, 'title': 'Low Water', 'artists': ['Low Tide Radio'], 'state': 'ready'},
              ],
            }
          : <String, dynamic>{};
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
          child: const ArtistPage(artist: ArtistSummary(name: 'Low Tide Radio', tracks: 2)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('the profile says who they are and what is here', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(find.text('LOW TIDE RADIO'), findsOneWidget);
    expect(find.text('2 RECORDS · 2 IN YOUR LIBRARY · 12K FANS'), findsOneWidget);
    expect(find.text('FOLLOW'), findsOneWidget);
    expect(find.text('BEST KNOWN'), findsOneWidget);
    expect(find.text('DISCOGRAPHY'), findsOneWidget);
    expect(find.text('IN YOUR LIBRARY · 2'), findsOneWidget);
  });

  testWidgets('once followed, the button says so', (tester) async {
    following = true;
    await show(tester);
    expect(find.text('FOLLOWING'), findsOneWidget);
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await show(tester, size: const Size(320, 1800), text: scale);
      expect(tester.takeException(), isNull);
    });
  }
}
