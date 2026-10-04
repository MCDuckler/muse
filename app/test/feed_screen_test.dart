// The feed: one song a page, with what it is filed under and what people said; a
// genre chip follows the genre; the Discover tab tapped twice is the way in.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/feed_screen.dart';
import 'package:muse/src/ui/home_page.dart' show MuseNavigationBar;
import 'package:muse/src/ui/library_page.dart';
import 'package:muse/src/ui/theme.dart';

Map<String, dynamic> track(int id, String title, String artist) =>
    {'id': id, 'title': title, 'artists': [artist], 'state': 'ready', 'album': 'Country Tropics', 'pos': id};

Future<void> _font(String family, List<String> files) async {
  final here = [for (final f in files) if (File(f).existsSync()) f];
  if (here.isEmpty) return;
  final l = FontLoader(family);
  for (final f in here) {
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['SHOTS'];

  setUpAll(() async {
    if (out == null) return;
    const f = 'assets/fonts';
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
    final m = '$flutter/bin/cache/artifacts/material_fonts';
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('MaterialIcons', ['$m/MaterialIcons-Regular.otf']);
    await _font('Roboto', ['$m/Roboto-Regular.ttf']);
  });

  late AppState app;
  final asked = <String>[];
  var sort = 'added_desc';

  setUp(() {
    asked.clear();
    sort = 'added_desc';
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add('${request.method} ${request.url.path}');
      final body = switch (request.url.path) {
        '/discover/cards' => {
            'total': 2,
            'offset': 0,
            'items': [
              {'track': track(1, 'Mechanical Bull', 'Old Saw'), 'list': 'trend:ambient', 'list_name': 'Trending in ambient', 'why': 'trending in ambient'},
              {'track': track(2, 'Second Song', 'Somebody'), 'list': 'weekly', 'list_name': "This week's finds", 'why': ''},
            ],
          },
        '/discover/cards/1' => {
            'genres': ['ambient', 'country'],
            'source': 'bandcamp',
            'comments': [
              {'name': 'zwarren824', 'text': 'This song reminds me of the Nuvema Town theme.', 'favourite': 'Your Notebook'},
              {'name': 'thornwoodonline31', 'text': 'Those educational VHS tapes from school.', 'favourite': null},
              {'name': 'third', 'text': 'Lovely.', 'favourite': null},
            ],
          },
        '/discover/cards/2' => {'genres': [], 'comments': []},
        '/discover/genres' => {'following': ['ambient'], 'suggested': [], 'found': []},
        '/discover/genres/country' => {'genre': 'country', 'following': true},
        '/playlists/5' => {
            'id': 5,
            'name': 'Mixed',
            'kind': 'local',
            'mine': true,
            'editable': true,
            'sort': sort,
            'items': [track(1, 'Mechanical Bull', 'Old Saw'), track(2, 'Second Song', 'Somebody')],
          },
        '/playlists' => [],
        _ => <String, dynamic>{},
      };
      if (request.method == 'PATCH' && request.url.path == '/playlists/5') {
        sort = (jsonDecode(request.body) as Map)['sort'] as String;
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  // The magazine theme only where the picture is taken: under it the playlist head
  // overflows at this width with the test font, which is the font, not the page.
  Future<void> show(WidgetTester tester, Widget body,
      {bool themed = false, Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
          theme: themed ? MuseTheme.light() : null,
          home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: body))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (out == null) return;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('a card is the song, big, then where it is filed and what was said', (tester) async {
    await show(tester, const FeedScreen(), themed: true);
    expect(tester.takeException(), isNull);
    expect(find.text('MECHANICAL BULL'), findsOneWidget);
    expect(find.textContaining('by Old Saw'), findsOneWidget);
    expect(find.text('AMBIENT'), findsOneWidget);
    expect(find.text('COUNTRY'), findsOneWidget);
    expect(find.text('SUPPORTED BY'), findsOneWidget);
    expect(find.text('zwarren824'), findsOneWidget);
    expect(find.text('Favourite track: Your Notebook'), findsOneWidget);
    // Three short comments fit; they are all shown.
    expect(find.text('third'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    await shot(tester, 'feed-phone');
    // One list, scrolled: a drag up brings the second card into view.
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('SECOND SONG'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('a genre on a card can be followed from there', (tester) async {
    await show(tester, const FeedScreen());
    await tester.tap(find.text('COUNTRY'));
    await tester.pump();
    expect(asked, contains('PUT /discover/genres/country'));
  });

  test('two quick taps on Discover are the way into the feed, two slow ones are not', () async {
    final state = AppState();
    expect(state.discoverTappedAgain(), isFalse);
    expect(state.discoverTappedAgain(), isTrue, reason: 'the second of a quick pair');
    expect(state.discoverTappedAgain(), isFalse, reason: 'and the pair is spent');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(state.discoverTappedAgain(), isFalse, reason: 'too slow to be a pair');
  });

  testWidgets('from another tab it is two taps on Discover, not three', (tester) async {
    app.homeTab = Tabs.home;
    await show(tester, const MuseNavigationBar());
    await tester.tap(find.text('Discover'));
    await tester.pump();
    expect(app.homeTab, Tabs.discover, reason: 'the first tap switches');
    await tester.tap(find.text('Discover'));
    await tester.pump();
    expect(app.discoverTappedAgain(), isFalse,
        reason: 'the pair was spent on opening the feed, so a third tap starts afresh');
  });

  testWidgets('a playlist offers its order, and only the hand order can be dragged', (tester) async {
    // Wider than a phone: with the test font's square glyphs the playlist head's three
    // buttons overflow at 420, which real fonts do not do (the shot run proves it).
    await show(tester, const PlaylistPage(playlistId: 5, name: 'Mixed'), size: const Size(640, 900));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.drag_indicator), findsNothing, reason: 'newest-first is a view');
    // Fixed pumps rather than settling: the page keeps a breathing skeleton and a
    // pull-to-refresh record alive, and settling waits on them for ever.
    await tester.tap(find.byTooltip('Order'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Newest added first'), findsOneWidget);
    await tester.tap(find.text('Hand order'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(asked, contains('PATCH /playlists/5'));
    expect(sort, 'manual', reason: 'saved on the server, beside the playlist');
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
  });
}
