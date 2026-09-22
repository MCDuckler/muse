// One search, one list.
//
// The screen used to be four lists one under another, one per service. What this is
// about is that it is not any more: the rows are ranked together, they are all the
// same shape, and each one says where it came from.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/found_row.dart';
import 'package:muse/src/ui/search_page.dart';
import 'package:muse/src/ui/skeleton.dart';

Map<String, dynamic> row(String kind, String place, String title,
        {String subtitle = 'Someone',
        String? lyric,
        int? ms,
        Map<String, dynamic>? track}) =>
    {
      'kind': kind,
      'place': place,
      'id': '$place-$title',
      'title': title,
      'subtitle': subtitle,
      'cover_url': '/art/remote?u=x',
      if (lyric != null) 'lyric': lyric,
      if (ms != null) 'duration_ms': ms,
      if (track != null) 'track': track,
      'known': track != null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<Uri> asked;
  late List<http.Request> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    asked = [];
    sent = [];
    // No socket: the answers come straight back, so the whole screen can be driven on
    // the test's own clock.
    useThisClientInstead(MockClient((request) async {
      asked.add(request.url);
      if (request.method != 'GET') sent.add(request);
      Object? other;
      final path = request.url.path;
      if (path == '/search/add') {
        // Taken, and not here yet: the server has only just started fetching it.
        other = {'id': 77, 'title': 'Live at the Roundhouse', 'artists': ['Queen Archive'],
                 'state': 'pending'};
      } else if (path == '/library/smart') {
        other = {
          'lists': [
            {'id': 'never', 'name': 'Never played', 'blurb': 'Not once put on', 'count': 41},
            {'id': 'once', 'name': 'Played once', 'blurb': 'Worth a second go?', 'count': 0},
          ],
          'decades': [
            {'id': 'd1990', 'name': 'The 1990s', 'short': '90s', 'blurb': '1990 to 1999',
             'count': 112},
          ],
        };
      } else if (path == '/queues') {
        other = [
          {'id': 99, 'name': 'Now', 'cursor_index': 0, 'position_ms': 0, 'rev': 1, 'items': 0},
        ];
      } else if (path.startsWith('/queues/')) {
        other = {'id': 99, 'name': 'Now', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
                 'items': <dynamic>[]};
      }
      if (other != null) {
        return http.Response(jsonEncode(other), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(
        jsonEncode({
          'items': [
            row('song', 'library', 'Bohemian Rhapsody',
                subtitle: 'Queen',
                track: {
                  'id': 1,
                  'title': 'Bohemian Rhapsody',
                  'artists': ['Queen'],
                  'state': 'ready',
                  'stream_url': '/tracks/1/stream',
                }),
            row('album', 'ytmusic', 'A Night at the Opera', subtitle: 'Queen'),
            row('song', 'spotify', 'Bohemian Rhapsody - Live', subtitle: 'Queen'),
            row('artist', 'soundcloud', 'Queen tribute'),
            row('video', 'youtube', 'Live at the Roundhouse',
                subtitle: 'Queen Archive · 1.2M views', ms: 4331000),
          ],
          'notes': {'bandcamp': 'Bandcamp would not answer'},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }));

    final api = ApiClient(baseUrl: 'http://example.invalid');
    api.token = 'test-token';
    app = AppState()..api = api;
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester,
      {Size size = const Size(420, 900), double text = 1}) async {
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
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(text)),
          child: const Scaffold(body: SearchPage()),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Type, wait out the debounce, and let the request actually happen.
  ///
  /// Two clocks: the debounce runs on the test's own, and the request runs on the
  /// real one — so pumping alone leaves the search still in flight.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));   // past the debounce
    await tester.pump();                                    // and the answer lands
    await tester.pump();
    // The row of chips slides open once there is a question, and it only starts to on
    // the first frame that sees one — so give it the time to finish.
    await tester.pump(const Duration(milliseconds: 250));
  }

  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

  /// The last question put to the server — not the last request, which is as likely
  /// to be a cover being fetched for one of the answers.
  Uri lastSearch() => asked.lastWhere((u) => u.path == '/search/everything');

  Future<void> type(WidgetTester tester, String what) async {
    await tester.enterText(find.byType(TextField), what);
    await settle(tester);
  }

  testWidgets('everything lands in one list, whatever it is and wherever it is from',
      (tester) async {
    await show(tester);
    await type(tester, 'queen');

    expect(tester.takeException(), isNull);
    // Four results in one index: the best match on its own card, the rest as rows under
    // a head for each *kind* of thing — never a heading per service, which is the thing
    // this replaced.
    expect(find.text('TOP RESULT · SONG'), findsOneWidget);
    expect(find.byType(FoundRow), findsNWidgets(4));
    Finder either(String t) => find.byWidgetPredicate(
        (w) => w is Text && (w.data == t || w.data == t.toUpperCase()));
    expect(either('Bohemian Rhapsody'), findsOneWidget);
    expect(either('A Night at the Opera'), findsOneWidget);
    expect(either('Queen tribute'), findsOneWidget);
    expect(find.textContaining('On YouTube Music'), findsNothing,
        reason: 'no section headings: the list is one list');

    // And every row says where it came from.
    expect(find.byType(PlaceDot), findsWidgets);
  });

  testWidgets('while the first search is still out, the page is not blank',
      (tester) async {
    // Four services can take seconds between them. There is nothing to show yet, and
    // building the index out of nothing threw — a white page until they answered.
    final gate = Completer<void>();
    useThisClientInstead(MockClient((request) async {
      await gate.future;
      return http.Response(jsonEncode({'items': [], 'notes': {}}), 200,
          headers: {'content-type': 'application/json'});
    }));
    await show(tester);
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    expect(find.byType(SongsComing), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(SongsComing), findsNothing);
  });

  testWidgets('before anything is typed, the page is somewhere to start from',
      (tester) async {
    await show(tester);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('NEVER PLAYED'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('PLAYED ONCE'), findsNothing, reason: 'nothing in it: not offered');
    expect(find.text('90S'), findsOneWidget);
    // And it goes away the moment there is a question.
    await type(tester, 'queen');
    expect(find.text('NEVER PLAYED'), findsNothing);
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('the start page holds on a small phone at ${scale}x text',
        (tester) async {
      await show(tester, size: const Size(320, 640), text: scale);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('NEVER PLAYED'), findsOneWidget);
    });
  }

  testWidgets('at a desk, the keys walk the results', (tester) async {
    await show(tester);
    await type(tester, 'queen');

    // Down three: the top result, the record under it, then the song from Spotify —
    // the order on the page, not the order they arrived in.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));

    // Shift-Enter: on the queue, and the music left alone.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);

    final taken = sent.firstWhere((r) => r.url.path == '/search/add');
    expect(body(taken)['title'], 'Bohemian Rhapsody - Live');
    final queued = sent.firstWhere((r) => r.url.path == '/queues/99/items');
    expect(body(queued)['mode'], 'end');

    // Up past the first one lets go, and Enter is a search again.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
    }
    sent.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent.where((r) => r.url.path == '/search/add'), isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('a service that would not answer says so, without emptying the list',
      (tester) async {
    await show(tester);
    await type(tester, 'queen');
    expect(find.text('Bandcamp would not answer'), findsOneWidget);
    expect(find.byType(FoundRow), findsNWidgets(4), reason: 'and the top result');
  });

  testWidgets('narrowing to one service asks for that service', (tester) async {
    await show(tester);
    await type(tester, 'queen');
    asked.clear();

    // One button beside the field, rather than a row of six chips.
    await tester.tap(find.byTooltip('Where to look'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YouTube').last);
    await tester.pumpAndSettle();
    await settle(tester);
    expect(lastSearch().queryParameters['where'], 'youtube');

    // It says so where it can be seen, and one tap there takes it off again.
    expect(find.widgetWithText(InputChip, 'YouTube'), findsOneWidget);
    await tester.tap(find.widgetWithText(InputChip, 'YouTube'));
    await settle(tester);
    expect(lastSearch().queryParameters['where'], 'all');
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('nothing to narrow until there is a question', (tester) async {
    await show(tester);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(FilterChip), findsNothing);
    await type(tester, 'queen');
    expect(find.widgetWithText(ChoiceChip, 'Videos'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Lyrics'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Videos'));
    await settle(tester);
    expect(lastSearch().queryParameters['kind'], 'video');

    // There is no "All" chip: the same one again takes it off.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Videos'));
    await settle(tester);
    expect(lastSearch().queryParameters['kind'], 'all');
  });

  testWidgets('a video is a row like a song, and says how long it is', (tester) async {
    await show(tester);
    await type(tester, 'queen');
    expect(find.text('VIDEOS'), findsOneWidget);
    expect(find.text('Live at the Roundhouse'), findsOneWidget);
    expect(find.text('1:12:11'), findsOneWidget,
        reason: 'a song or a two-hour set: the length is half of what you want to know');
  });


  testWidgets('tapping something that plays, plays it', (tester) async {
    await show(tester);
    await type(tester, 'queen');
    await tester.tap(find.text('Live at the Roundhouse'));
    await settle(tester);

    final taken = sent.firstWhere((r) => r.url.path == '/search/add');
    expect(body(taken)['place'], 'youtube');
    final queued = sent.firstWhere((r) => r.url.path == '/queues/99/items');
    expect(body(queued)['mode'], 'next', reason: 'straight after what is on, not at the end');
    expect(find.textContaining('plays as soon as it is here'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('the plus puts it on the queue and leaves the music alone', (tester) async {
    await show(tester);
    await type(tester, 'queen');
    final plus = find.descendant(
        of: find.widgetWithText(FoundRow, 'Live at the Roundhouse'),
        matching: find.byTooltip('Add to the queue (hold: play next)'));
    await tester.tap(plus);
    await settle(tester);

    final queued = sent.firstWhere((r) => r.url.path == '/queues/99/items');
    expect(body(queued)['mode'], 'end');
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('asking by the words asks a different question', (tester) async {
    await show(tester);
    await type(tester, 'is this just fantasy');
    asked.clear();

    await tester.tap(find.widgetWithText(FilterChip, 'Lyrics'));
    await settle(tester);

    expect(lastSearch().queryParameters['lyrics'], 'true');
    expect(lastSearch().queryParameters['kind'], 'song',
        reason: 'a record has no lyrics');
    // The kind chips are gone while it is on, because there is only one kind.
    expect(find.widgetWithText(ChoiceChip, 'Records'), findsNothing);
  });

  testWidgets('the rest go under a head for each kind, in the order they turned up',
      (tester) async {
    await show(tester);
    await type(tester, 'queen');
    // After the top song: a record, then another song, then an artist — so the heads
    // come in that order, and the kind that matched best after the top is first.
    final records = tester.getTopLeft(find.text('RECORDS')).dy;
    final songs = tester.getTopLeft(find.text('SONGS')).dy;
    final artists = tester.getTopLeft(find.text('ARTISTS')).dy;
    expect(records < songs && songs < artists, isTrue);
  });
}
