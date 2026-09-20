// Where a song is, in one small mark.
//
// Most of this library has never been downloaded — eighteen thousand of twenty-two
// thousand rows are a name and a place to fetch it from — so "will this play right
// now" is the question a list has to answer without being asked. It was answered on
// one kind of row and nowhere else.
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
import 'package:muse/src/ui/song_row.dart';

Track track({required String state, bool withAudio = false}) => Track.fromJson({
      'id': 7,
      'title': 'A song',
      'artists': ['Somebody'],
      'state': state,
      'source': 'youtube',
      if (withAudio) 'stream_url': '/tracks/7/stream',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<Map<String, dynamic>> asked;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    asked = [];
    useThisClientInstead(MockClient((request) async {
      if (request.body.isNotEmpty) {
        asked.add((jsonDecode(request.body) as Map).cast<String, dynamic>());
      }
      return http.Response(jsonEncode({'queued': 1, 'about_mb': 4}), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, Track t) async {
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(home: Scaffold(body: Center(child: TrackMark(track: t)))),
    ));
    await tester.pump();
  }

  testWidgets('a song that is not here says so, and offers to get it',
      (tester) async {
    await show(tester, track(state: 'pending'));
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cloud_outlined));
    await tester.pump();
    expect(asked.single['track_ids'], [7],
        reason: 'the cloud has always looked like a button; now it is one');
  });

  testWidgets('a song whose audio is here is not marked at all', (tester) async {
    await show(tester, track(state: 'ready', withAudio: true));
    expect(find.byIcon(Icons.cloud_outlined), findsNothing,
        reason: 'the common case is the quiet one');
  });

  testWidgets('a row being read rather than acted on does not offer the button',
      (tester) async {
    final t = track(state: 'pending');
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        home: Scaffold(body: Center(child: TrackMark(track: t, canFetch: false))),
      ),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
  });
}
