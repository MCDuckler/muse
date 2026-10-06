// A song's menu: every artist on it, not only the first, and "Not for me" — said, and
// taken back — beside them.
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
import 'package:muse/src/ui/artist_choice.dart';
import 'package:muse/src/ui/browse_page.dart' show ArtistPage;
import 'package:muse/src/ui/track_menu.dart';

Track _track(List<String> artists) => Track.fromJson({
      'id': 9,
      'title': 'Saku',
      'artists': artists,
      'album': 'Isles',
      'state': 'ready',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late List<Map<String, dynamic>> said;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    said = [];
    useThisClientInstead(MockClient((request) async {
      Object body = <String, dynamic>{};
      if (request.url.path == '/recommend/dislike') {
        final b = jsonDecode(request.body) as Map<String, dynamic>;
        said.add(b);
        body = {'disliked': !(b['undo'] as bool)};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> open(WidgetTester tester, Track t) async {
    // Tall enough that the whole menu is drawn: its rows are built as they come into view.
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
                onPressed: () => showTrackSheet(context, t), child: const Text('menu')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
  }

  testWidgets('a song by two has a way to each of them', (tester) async {
    await open(tester, _track(['Bicep', 'Clara La San']));
    expect(find.text('Go to Bicep'), findsOneWidget);
    expect(find.text('Go to Clara La San'), findsOneWidget);
    await tester.ensureVisible(find.text('Go to Clara La San'));
    await tester.tap(find.text('Go to Clara La San'));
    await tester.pumpAndSettle();
    expect(tester.widget<ArtistPage>(find.byType(ArtistPage)).artist.name, 'Clara La San');
  });

  testWidgets('not for me, and taken back', (tester) async {
    await open(tester, _track(['Bicep']));
    await tester.ensureVisible(find.text('Not for me'));
    await tester.tap(find.text('Not for me'));
    await tester.pumpAndSettle();
    expect(app.isDisliked(9), isTrue);
    expect(said.single, {'track_id': 9, 'undo': false});
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Not for me — take it back'));
    await tester.tap(find.text('Not for me — take it back'));
    await tester.pumpAndSettle();
    expect(app.isDisliked(9), isFalse);
  });

  test('who a song is by, as names', () {
    expect(artistsOf(_track(['A', 'B'])), ['A', 'B']);
    expect(artistsOf(_track([])), isEmpty, reason: '"Unknown artist" is nobody to open');
  });
}
