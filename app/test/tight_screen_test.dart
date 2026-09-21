// Small screens and big type.
//
// Two settings nobody in this house uses and everybody's phone offers: a 320-point
// screen, and text scaled up for eyes that want it. Both make every row taller and
// every line longer, and a Row that fits at 1.0 on a 420-point phone is a yellow-and-
// black overflow stripe at 2.0 on a small one. Nothing in the app was ever built at
// those sizes, so nothing was known to survive them.
//
// A rendering exception is the assertion here: Flutter reports an overflow by throwing
// in debug, which means "did it throw" is exactly "did it break".
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
import 'package:muse/src/ui/dialogs.dart';
import 'package:muse/src/ui/downloads_page.dart';
import 'package:muse/src/ui/not_connected.dart';
import 'package:muse/src/ui/search_page.dart';
import 'package:muse/src/ui/settings_page.dart';
import 'package:muse/src/ui/skeleton.dart';
import 'package:muse/src/ui/social_page.dart';
import 'package:muse/src/ui/song_row.dart';
import 'package:muse/src/ui/track_list.dart';

/// Long enough to be a real test: a title and an artist that no 320-point row can hold,
/// which is what most of a real library looks like once the remasters arrive.
Track longTrack() => Track.fromJson({
      'id': 7,
      'title': 'Everything In Its Right Place (2017 Remastered Anniversary Edition)',
      'artists': ['A Band With A Very Long And Deliberate Name', 'And A Guest'],
      'album': 'The Album This Came From, Deluxe',
      'state': 'ready',
      'source': 'youtube',
      'duration': 754,
      'stream_url': '/tracks/7/stream',
    });

/// Everybody at once: a jam, a song playing now, a long name, a long queue name.
final people = {
  'you': 1,
  'people': [
    {'id': 1, 'name': 'chris', 'songs': 12000, 'playlists': 73},
    {
      'id': 2,
      'name': 'Somebody With A Rather Long Display Name',
      'songs': 3,
      'playlists': 1,
      'jam': {'code': 'ABCD', 'people': 12},
      'playing': {
        'track': {
          'id': 9,
          'title': 'Everything In Its Right Place (2017 Remastered Anniversary Edition)',
          'artists': ['A Band With A Very Long And Deliberate Name'],
          'state': 'ready',
        },
        'queue': 'The Long Evening Queue For Driving Home Slowly',
        'now': true,
      },
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      if (request.url.path == '/social/people') {
        return http.Response(jsonEncode(people), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() {
    useThisClientInstead(http.Client());
    serverIsThere.value = true;
  });

  /// One widget, on a small screen, at whatever text size.
  Future<void> tight(WidgetTester tester, Widget child, {double scale = 1.0}) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: child),
        ),
      ),
    ));
    await tester.pump();
  }

  for (final scale in [1.0, 1.6, 2.0]) {
    testWidgets('a song row holds a long name at ${scale}x on a small screen',
        (tester) async {
      await tight(tester, SongRow(track: longTrack(), onTap: () {}), scale: scale);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song that is not here yet, an hour long, holds at ${scale}x',
        (tester) async {
      // The row's widest case: a fetch button, the source, a five-character length
      // and the menu, all fixed width, beside a title that has to fit somewhere.
      final pending = Track.fromJson({
        'id': 8,
        'title': 'Everything In Its Right Place (2017 Remastered Anniversary Edition)',
        'artists': ['A Band With A Very Long And Deliberate Name'],
        'state': 'pending',
        'source': 'youtube',
        'duration': 3600,
      });
      await tight(tester, SongRow(track: pending, onTap: () {}), scale: scale);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the not-connected line holds at ${scale}x', (tester) async {
      serverIsThere.value = false;
      await tight(tester, const Column(children: [NotConnected()]), scale: scale);
      expect(tester.takeException(), isNull);
      expect(find.textContaining("Can't reach the server"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a whole list of long names holds at ${scale}x', (tester) async {
      // With the filter box showing, which is what a list of twelve or more gets.
      await tight(
          tester,
          TrackList(tracks: [
            for (var i = 0; i < 14; i++) longTrack(),
          ]),
          scale: scale);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the people tab holds a busy, long-named list at ${scale}x',
        (tester) async {
      await tight(tester, const SocialPage(), scale: scale);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Somebody With'), findsWidgets);
    });

    testWidgets('an empty page and a failed one hold at ${scale}x', (tester) async {
      await tight(
          tester,
          const EmptyHint(
            icon: Icons.music_note,
            title: 'Nothing here yet, and a long way from anything',
            body: 'Tracks appear once they are in your library, which they are not.',
          ),
          scale: scale);
      expect(tester.takeException(), isNull);
      await tight(
          tester,
          ErrorRetry(
              error: ApiException(502, 'The server said something long and unhelpful'),
              onRetry: () {}),
          scale: scale);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search, before anything is typed, holds at ${scale}x',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'muse.recentSearches': [
          'a search somebody made once that went on for a very long time',
          'boards of canada',
        ],
      });
      await tight(tester, const SearchPage(), scale: scale);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('settings hold at ${scale}x', (tester) async {
      await tight(tester, const SettingsPage(), scale: scale);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('downloads hold at ${scale}x', (tester) async {
      await tight(tester, const DownloadsPage(), scale: scale);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the loading shapes hold at ${scale}x', (tester) async {
      await tight(tester, const PeopleComing(rows: 3), scale: scale);
      expect(tester.takeException(), isNull);
      await tight(tester, const SongsComing(rows: 3), scale: scale);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the line goes away by itself when the server comes back',
      (tester) async {
    serverIsThere.value = false;
    await tight(tester, const Column(children: [NotConnected()]));
    expect(find.text('Try again'), findsOneWidget);

    // What a request getting through does, from anywhere in the app.
    serverIsThere.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Try again'), findsNothing);
  });
}
