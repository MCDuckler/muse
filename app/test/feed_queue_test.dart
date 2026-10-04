// A song in the feed plays the feed: one queue of all of its songs, from the one tapped,
// with what had not been scrolled to yet put on the end. And each card goes into the
// queue on its own, too.
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
import 'package:muse/src/ui/feed_screen.dart';

Map<String, dynamic> _card(int id) => {
      'track': {'id': id, 'title': 'Song $id', 'artists': ['Somebody'], 'state': 'ready'},
      'list': 'weekly',
      'why': 'new to you this week',
      'service': 'bandcamp',
    };

/// The app with its queue calls written down rather than made.
class _App extends AppState {
  final played = <({List<int> ids, int startAt, String? named})>[];
  final added = <({List<int> ids, String mode})>[];

  @override
  Future<void> playNow(List<Track> tracks,
      {int startAt = 0, bool shuffle = false, String? named}) async {
    played.add((ids: [for (final t in tracks) t.id], startAt: startAt, named: named));
    activeQueue = Queue.fromJson({'id': 77, 'name': named ?? 'Now', 'items': []});
  }

  @override
  Future<void> addTracks(List<Track> tracks, {String mode = 'end'}) async {
    added.add((ids: [for (final t in tracks) t.id], mode: mode));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _App app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final q = request.url.queryParameters;
      final offset = int.parse(q['offset'] ?? '0');
      final limit = int.parse(q['limit'] ?? '20');
      // Five songs in the feed, served three to a first page.
      final Object body = switch (request.url.path) {
        '/discover/cards' => {
            'items': [
              for (var id = offset + 1; id <= 5 && id <= offset + (offset == 0 ? 3 : limit); id++)
                _card(id)
            ],
            'total': 5,
            'services': {'bandcamp': 5},
          },
        '/discover/genres' => {'following': [], 'suggested': [], 'found': []},
        _ => {'genres': [], 'comments': []},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    app = _App()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, {double width = 420}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: FeedScreen()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a song played is the feed played, from that song, the rest put on after',
      (tester) async {
    await show(tester);
    // The second card's picture is its play button.
    final play2 = find.descendant(
        of: find.bySemanticsLabel('Play Song 2'), matching: find.byIcon(Icons.play_arrow));
    await tester.ensureVisible(play2);
    await tester.pumpAndSettle();
    await tester.tap(play2);
    await tester.pumpAndSettle();

    expect(app.played, hasLength(1));
    final play = app.played.single;
    expect(play.startAt, 1, reason: 'it starts on the song tapped');
    expect(play.named, 'The feed', reason: 'a queue of its own, not over what was on');
    expect(play.ids.take(2), [1, 2]);
    final everything = [...play.ids, for (final a in app.added) ...a.ids];
    expect(everything, [1, 2, 3, 4, 5], reason: 'every song in the feed, in its order, once');
    expect(app.added.every((a) => a.mode == 'end'), isTrue);
  });

  testWidgets('a card goes into the queue, or next with a long press', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Add to queue').first);
    await tester.pumpAndSettle();
    expect(app.added.last.ids, [1]);
    expect(app.added.last.mode, 'end');

    await tester.longPress(find.byTooltip('Add to queue').first);
    await tester.pumpAndSettle();
    expect(app.added.last.ids, [1]);
    expect(app.added.last.mode, 'next');
  });

  testWidgets('five buttons under a song fit a small phone', (tester) async {
    await show(tester, width: 320);
    expect(tester.takeException(), isNull);
  });
}
