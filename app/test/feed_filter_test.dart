// The feed narrowed to one service: the cards by where each song came from, the new
// releases by where each record is followed — and a Bandcamp record marked read as a
// Bandcamp record.
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
import 'package:muse/src/ui/feed_page.dart';
import 'package:muse/src/ui/feed_screen.dart';

Map<String, dynamic> _track(int id, String title) =>
    {'id': id, 'title': title, 'artists': ['Somebody'], 'state': 'ready', 'pos': id};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<http.Request> asked;

  setUp(() {
    asked = [];
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add(request);
      final service = request.url.queryParameters['service'];
      final cards = [
        {'track': _track(1, 'From Bandcamp'), 'list': 'radar', 'why': 'new on Tresor',
         'service': 'bandcamp'},
        {'track': _track(2, 'From YouTube'), 'list': 'weekly', 'why': '', 'service': 'youtube'},
        {'track': _track(3, 'From SoundCloud'), 'list': 'weekly', 'why': '',
         'service': 'soundcloud'},
      ];
      final shown = [for (final c in cards) if (service == null || c['service'] == service) c];
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/discover/cards') => {
            'items': shown,
            'total': shown.length,
            'services': {'bandcamp': 1, 'soundcloud': 1, 'youtube': 1},
          },
        ('GET', '/discover/genres') => {'following': [], 'suggested': [], 'found': []},
        ('GET', '/feed') => {
            'items': [
              {'provider': 'deezer', 'album_id': '42', 'title': 'Deezer Record',
               'artist': 'An Act', 'artist_id': '1', 'unseen': true},
              {'provider': 'bandcamp', 'album_id': 'https://act.bandcamp.com/album/new',
               'title': 'Bandcamp Record', 'artist': 'Act', 'artist_id': 'https://label.bandcamp.com',
               'unseen': true, 'via': 'Label'},
            ],
            'unseen': 2,
            'following': 3,
          },
        ('POST', '/feed/seen') => {'seen': 1},
        _ => <String, dynamic>{'genres': [], 'comments': []},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: page),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the feed reads one service at a time', (tester) async {
    await show(tester, const FeedScreen());
    expect(find.text('FROM BANDCAMP'), findsOneWidget);
    expect(find.text('FROM YOUTUBE'), findsOneWidget);
    expect(find.text('BANDCAMP'), findsOneWidget, reason: 'a chip for each service with songs');
    expect(find.text('SOUNDCLOUD'), findsOneWidget);

    await tester.tap(find.text('BANDCAMP'));
    await tester.pumpAndSettle();
    expect(asked.last.url.queryParameters['service'], 'bandcamp');
    expect(find.text('FROM BANDCAMP'), findsOneWidget);
    expect(find.text('FROM YOUTUBE'), findsNothing);

    await tester.tap(find.text('ALL'));
    await tester.pumpAndSettle();
    expect(asked.last.url.queryParameters.containsKey('service'), isFalse);
    expect(find.text('FROM YOUTUBE'), findsOneWidget);
  });

  testWidgets('new releases by where they are followed, and read as such', (tester) async {
    await show(tester, const FeedPage());
    expect(find.text('Deezer Record'), findsOneWidget);
    expect(find.text('Bandcamp Record'), findsOneWidget);
    expect(find.text('2 new · 3 followed'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Bandcamp'));
    await tester.pumpAndSettle();
    expect(find.text('Deezer Record'), findsNothing);
    expect(find.text('1 new · 3 followed'), findsOneWidget);

    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();
    final seen = asked.lastWhere((r) => r.url.path == '/feed/seen');
    expect(jsonDecode(seen.body), {
      'items': [
        {'album_id': 'https://act.bandcamp.com/album/new', 'provider': 'bandcamp'}
      ],
    });
  });
}
