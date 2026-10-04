// The library's sections, made smaller; the playlists on the other services, listed
// under the library's own; and who you follow, brought over from the services page.
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
import 'package:muse/src/ui/library_page.dart';
import 'package:muse/src/ui/services_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<http.Request> asked;
  var linked = true;

  Map<String, dynamic> service(String provider, String label, {String? handle}) => {
        'provider': provider,
        'label': label,
        'hint': '',
        'plays': provider != 'deezer' && provider != 'youtube',
        'sign_in': provider == 'youtube' ? 'code' : 'name',
        'linked': handle == null ? null : {'handle': handle, 'display_name': handle},
      };

  setUp(() {
    linked = true;
    asked = [];
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add(request);
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/library/tracks') => {'items': [], 'total': 22815},
        ('GET', '/library/albums') => {'items': [], 'total': 1203},
        ('GET', '/library/artists') => {'items': [], 'total': 4550},
        ('GET', '/feed') => {'items': [], 'unseen': 0, 'following': 0},
        ('GET', '/library/smart') => {'lists': []},
        ('GET', '/linked') => {
            'accounts': [
              service('youtube', 'YouTube Music', handle: linked ? 'Chris' : null),
              service('soundcloud', 'SoundCloud', handle: linked ? 'chris' : null),
              service('deezer', 'Deezer'),
            ],
          },
        ('GET', '/spotify/account') => {
            'configured': true,
            'account': linked ? {'display_name': 'chris'} : null,
          },
        ('GET', '/spotify/playlists') => {
            'items': [
              {'remote_id': 'sp1', 'name': 'Night Drive', 'owner': 'chris', 'count': 40},
              {
                'remote_id': 'sp2',
                'name': 'Gym',
                'count': 12,
                'mirror': {'playlist_id': 7, 'tracks': 11, 'unmatched': 1},
              },
            ],
          },
        ('GET', '/linked/youtube/playlists') => {
            'items': [
              {
                'remote_id': 'PL1',
                'name': 'Sunday Records',
                'count': 9,
                'image': 'https://i.ytimg.com/vi/x/hqdefault.jpg',
              },
            ],
          },
        ('GET', '/linked/soundcloud/playlists') => {'items': []},
        ('POST', '/linked/youtube/sync') => {'queued': ['PL1']},
        ('POST', '/spotify/sync') => {
            'playlists': [
              {'name': 'Night Drive', 'matched': 38, 'total': 40, 'missing': 2},
            ],
          },
        ('GET', '/follows/sources') => {
            'items': [
              if (linked) {'provider': 'spotify', 'label': 'Spotify'},
              if (linked) {'provider': 'soundcloud', 'label': 'SoundCloud', 'handle': 'chris'},
            ],
          },
        ('POST', '/follows/import') => {
            'from': 'spotify',
            'found': 3,
            'followed': 2,
            'already': 1,
            'not_found': ['Nobody Known'],
          },
        ('GET', '/playlists') => [],
        ('GET', '/follows') => {'items': []},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
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
      child: MaterialApp(home: Scaffold(body: page)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  bool wasAsked(String method, String path) =>
      asked.any((r) => r.method == method && r.url.path == path);

  testWidgets('a section shrinks to a strip, and closes to its head', (tester) async {
    await show(tester, const LibraryPage());
    expect(find.text('Everything, sortable'), findsOneWidget);

    await tester.tap(find.byTooltip('Shrink it').first);
    await tester.pumpAndSettle();
    expect(find.text('Everything, sortable'), findsNothing,
        reason: 'a strip of labels has no room for the line under each');
    expect(find.text('22,815'), findsOneWidget, reason: 'the number stays');
    expect(app.shrunkSections, contains('contents'));

    expect(find.text('No playlists yet.'), findsOneWidget);
    await tester.tap(find.text('PLAYLISTS'));
    await tester.pumpAndSettle();
    expect(find.text('No playlists yet.'), findsNothing);
    expect(find.text('PLAYLISTS'), findsOneWidget, reason: 'the head stays');

    // Remembered on this device.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('muse.library.closed'), contains('playlists'));
    expect(prefs.getStringList('muse.library.shrunk'), contains('contents'));

    await tester.tap(find.text('PLAYLISTS'));
    await tester.pumpAndSettle();
    expect(find.text('No playlists yet.'), findsOneWidget);
  });

  testWidgets('every connected service, its lists, and a button to mirror one',
      (tester) async {
    await show(tester, const LibraryPage());
    await tester.pumpAndSettle();
    expect(find.text('FROM YOUR SERVICES'), findsOneWidget);
    expect(find.text('SPOTIFY'), findsOneWidget);
    expect(find.text('YOUTUBE MUSIC'), findsOneWidget);
    expect(find.text('SOUNDCLOUD'), findsOneWidget);
    expect(find.text('DEEZER'), findsNothing, reason: 'not linked, so not listed');

    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text('Sunday Records'), findsOneWidget);
    // Mirrored, so it says what is here rather than offering to mirror it.
    expect(find.text('11 here · 1 not matched'), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Sunday Records'),
        matching: find.text('Mirror')));
    await tester.pumpAndSettle();
    final sync = asked.lastWhere((r) => r.url.path == '/linked/youtube/sync');
    expect(jsonDecode(sync.body)['remote_id'], 'PL1');
    // The list's own picture goes along, so the copy here wears the same face.
    expect(jsonDecode(sync.body)['image'], 'https://i.ytimg.com/vi/x/hqdefault.jpg');
    expect(find.text('copying…'), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Night Drive'),
        matching: find.text('Mirror')));
    await tester.pumpAndSettle();
    final spotify = asked.lastWhere((r) => r.url.path == '/spotify/sync');
    expect(jsonDecode(spotify.body)['remote_id'], 'sp1');
    expect(find.textContaining('38 of 40 songs'), findsOneWidget);
  });

  testWidgets('a closed shelf asks the services nothing', (tester) async {
    SharedPreferences.setMockInitialValues({
      'muse.library.closed': ['services'],
    });
    app.closedSections = {'services'};
    await show(tester, const LibraryPage());
    await tester.pumpAndSettle();
    expect(find.text('FROM YOUR SERVICES'), findsOneWidget);
    expect(wasAsked('GET', '/linked'), isFalse);
    expect(wasAsked('GET', '/spotify/playlists'), isFalse);

    await tester.tap(find.text('FROM YOUR SERVICES'));
    await tester.pumpAndSettle();
    expect(wasAsked('GET', '/linked'), isTrue);
    expect(find.text('Night Drive'), findsOneWidget);
  });

  testWidgets('with nothing connected, the way to connect something', (tester) async {
    linked = false;
    await show(tester, const LibraryPage());
    await tester.pumpAndSettle();
    expect(find.text('CONNECT A SERVICE'), findsOneWidget);
  });

  testWidgets('who you follow is brought over from the services page', (tester) async {
    await show(tester, const ServicesPage());
    await tester.pumpAndSettle();
    expect(find.text('Lists'), findsNothing,
        reason: 'what a service holds is listed in the library now');
    expect(find.text('From Spotify'), findsOneWidget);
    expect(find.text('From SoundCloud'), findsOneWidget);
    expect(find.text('From Deezer'), findsNothing, reason: 'not linked');
    expect(find.text('From YouTube Music'), findsNothing,
        reason: 'YouTube does not say who you follow');

    await tester.tap(find.text('From Spotify'));
    await tester.pumpAndSettle();
    final post = asked.lastWhere((r) => r.url.path == '/follows/import');
    expect(jsonDecode(post.body)['provider'], 'spotify');
    // Said in full, names that could not be placed included.
    expect(find.text('2 newly followed'), findsOneWidget);
    expect(find.text('Nobody Known'), findsOneWidget);
  });

  testWidgets('the following page no longer imports', (tester) async {
    await show(tester, const FollowingPage());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Import who you follow'), findsNothing);
    expect(find.byTooltip('Follow'), findsOneWidget);
  });
}
