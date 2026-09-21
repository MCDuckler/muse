// A record's page, set as a review.
//
// It says what is true about the record — its year, how many tracks and how long, where
// it came from, whether it is all here — gives it a printed sleeve with its own name
// when it has no cover, and holds together on a small phone with big type.
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
import 'package:muse/src/ui/sleeve_art.dart';

Map<String, dynamic> track(int id, String title, int ms) => {
      'id': id,
      'title': title,
      'artists': ['Low Tide Radio'],
      'album': 'Salt on the Window',
      'duration_ms': ms,
      'state': 'ready',
      'source': 'bandcamp',
      'stream_url': '/tracks/$id/stream',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final body = request.url.path == '/library/albums/detail'
          ? {
              'album': {
                'name': 'Salt on the Window',
                'artist': 'Low Tide Radio',
                'release_date': '1994-05-02',
                'record_type': 'album',
                'remote_id': 'r1',
              },
              'tracks': [
                {'pos': 1, 'title': 'Low Water', 'duration_ms': 238000, 'track': track(1, 'Low Water', 238000)},
                {'pos': 2, 'title': 'Harbour Lights', 'duration_ms': 261000, 'track': track(2, 'Harbour Lights', 261000)},
                {'pos': 3, 'title': 'Breakwater', 'duration_ms': 302000, 'remote_id': 'x3'},
              ],
              'extra': [],
              'missing': 1,
            }
          : <String, dynamic>{};
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, {Size size = const Size(420, 1200), double text = 1}) async {
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
          child: const AlbumPage(
              album: AlbumSummary(name: 'Salt on the Window', artist: 'Low Tide Radio', tracks: 3)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('the review says what is true about the record', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('REVIEWS'), findsOneWidget);
    expect(find.text('SALT ON THE WINDOW'), findsOneWidget);
    expect(find.text('LOW TIDE RADIO'), findsOneWidget);
    expect(find.text('FACT FILE'), findsOneWidget);
    expect(find.text('1994'), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget, reason: 'two held of three');
    expect(find.text('13 min'), findsOneWidget, reason: '3:58 + 4:21 + 5:02');
    expect(find.text('Bandcamp'), findsOneWidget);
    expect(find.text('1 still to get'), findsOneWidget);
    expect(find.text('GET 1 MISSING'), findsOneWidget);
  });

  testWidgets('a record with no cover gets a sleeve with its own name', (tester) async {
    await show(tester);
    final sleeve = tester.widget<PrintedSleeve>(find.byType(PrintedSleeve).first);
    expect(sleeve.title, 'Salt on the Window');
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await show(tester, size: const Size(320, 1600), text: scale);
      expect(tester.takeException(), isNull);
    });
  }
}
