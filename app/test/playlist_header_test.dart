// A playlist's page, headed like a compilation's sleeve notes.
//
// Whose it is and what kind, its name set big, a typed line of what is in it — songs,
// length, what is not downloaded — and holding together at big text on a small phone.
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
import 'package:muse/src/ui/library_page.dart';

Map<String, dynamic> track(int id, String title, int ms, {String state = 'ready'}) => {
      'id': id,
      'title': title,
      'artists': ['Somebody'],
      'duration_ms': ms,
      'state': state,
      'source': 'youtube',
      if (state == 'ready') 'stream_url': '/tracks/$id/stream',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  var editable = false;
  final held = <Map<String, dynamic>>[];
  final asked = <http.Request>[];

  setUp(() {
    editable = false;
    held.clear();
    asked.clear();
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add(request);
      if (request.url.path == '/playlists/5/suggested') {
        return http.Response(
            jsonEncode({
              'items': [track(9, 'Breakwater', 302000)],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/playlists/5/items' && request.method == 'POST') {
        held.add(track(9, 'Breakwater', 302000));
      }
      final body = request.url.path == '/playlists/5' ||
              request.url.path == '/playlists/5/items'
          ? {
              'id': 5,
              'name': 'Sunday Driving',
              'kind': 'local',
              'saved': true,
              'owner_name': 'Joe',
              'editable': editable,
              'waiting': 1,
              'items': [
                track(1, 'Harbour Lights', 261000),
                track(2, 'Low Water', 238000),
                track(3, 'Night Bus', 3600000, state: 'pending'),
                ...held,
              ],
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
          child: const PlaylistPage(playlistId: 5, name: 'Sunday Driving'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('the header says whose it is and what is in it', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('PLAYLIST · FROM JOE'), findsOneWidget);
    expect(find.text('SUNDAY DRIVING'), findsOneWidget);
    expect(find.text('3 SONGS · 1 H 8 MIN · 1 NOT DOWNLOADED'), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);
    expect(find.text('SHUFFLE'), findsOneWidget);
  });

  testWidgets('a list you can add to is offered what would sit well in it',
      (tester) async {
    editable = true;
    await show(tester, size: const Size(420, 1600));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('WOULD SIT WELL HERE'), findsOneWidget);
    expect(find.text('Breakwater'), findsOneWidget);

    await tester.tap(find.byTooltip('Add to this playlist'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final added = asked.firstWhere(
        (r) => r.url.path == '/playlists/5/items' && r.method == 'POST');
    expect(jsonDecode(added.body), {'track_ids': [9]});
    expect(find.byTooltip('Add to this playlist'), findsNothing,
        reason: 'in the list now, so no longer on offer');
  });

  testWidgets("somebody else's list is offered nothing", (tester) async {
    await show(tester, size: const Size(420, 1600));
    expect(find.text('WOULD SIT WELL HERE'), findsNothing);
    expect(asked.any((r) => r.url.path.endsWith('/suggested')), isFalse);
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await show(tester, size: const Size(320, 1600), text: scale);
      expect(tester.takeException(), isNull);
    });
  }
}
