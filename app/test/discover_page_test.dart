// Discover: lists made for you, stations, new releases, acts to try — drawn from
// what the server says, each part left out when it has nothing. With SHOTS=<dir> in
// the environment the page is also written out as PNGs, for looking at.
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
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/discover_page.dart';
import 'package:muse/src/ui/theme.dart';

Map<String, dynamic> track(int id, String title, String artist) =>
    {'id': id, 'title': title, 'artists': [artist], 'state': 'ready', 'album': 'Some Record'};

Map<String, dynamic> page({bool built = true, bool releases = true}) => {
      'lists': built
          ? [
              {
                'slug': 'weekly',
                'name': "This week's finds",
                'blurb': 'Songs you have not got, out of what you have been playing.',
                'kind': 'weekly',
                'built_at': DateTime.now().toUtc().toIso8601String(),
                'count': 3,
                'why': {'101': 'because you play Morning Static'},
                'tracks': [
                  track(101, 'Unheard Song', 'Brand New Act'),
                  track(102, 'Second Find', 'Another Act'),
                  track(103, 'Third Find', 'Third Act'),
                ],
              },
              {
                'slug': 'daily:1',
                'name': 'Daily mix 1',
                'blurb': 'Morning Static, Low Tide Radio and more',
                'kind': 'daily',
                'count': 2,
                'tracks': [track(7, 'Tape Hiss', 'Morning Static'), track(8, 'Salt on the Window', 'Low Tide Radio')],
              },
              {
                'slug': 'repeat',
                'name': 'On repeat',
                'blurb': 'What you have played most this month.',
                'kind': 'repeat',
                'count': 1,
                'tracks': [track(7, 'Tape Hiss', 'Morning Static')],
              },
            ]
          : [],
      'building': !built,
      'stations': {
        'yours': [
          {'queue_id': 31, 'name': 'Techno radio', 'kind': 'genre', 'seed_text': 'techno', 'count': 14},
        ],
        'artists': [
          {'name': 'Morning Static', 'cover_track': null},
          {'name': 'Low Tide Radio', 'cover_track': null},
        ],
        'tracks': [],
        'genres': [
          {'genre': 'techno', 'following': true},
          {'genre': 'ambient', 'following': false},
        ],
      },
      'feed': {
        'items': releases
            ? [
                {
                  'source': 'artist',
                  'provider': 'deezer',
                  'album_id': '9001',
                  'title': 'New Record',
                  'artist': 'Morning Static',
                  'release_date': '2026-10-01',
                  'record_type': 'album',
                  'unseen': true,
                  'in_library': false,
                },
                {
                  'source': 'genre',
                  'provider': 'mb',
                  'album_id': null,
                  'release_mbid': 'rel-1',
                  'title': 'Warehouse',
                  'artist': 'Some Producer',
                  'release_date': '2026-09-30',
                  'record_type': 'ep',
                  'unseen': false,
                  'genre': 'techno',
                },
              ]
            : [],
        'unseen': releases ? 1 : 0,
        'following': 12,
        'genres': 1,
      },
      'genres': {
        'following': ['techno'],
        'suggested': [
          {'genre': 'ambient', 'why': 'from Morning Static'}
        ],
      },
      'artists': [
        {'name': 'Brand New Act', 'mbid': 'm1', 'because': 'people who play Morning Static play this'},
      ],
    };

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

  late AppState app;
  Map<String, dynamic> Function() answer = page;
  final asked = <String>[];

  setUpAll(() async {
    if (out == null) return;
    const f = 'assets/fonts';
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
    final m = '$flutter/bin/cache/artifacts/material_fonts';
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('PermanentMarker', ['$f/PermanentMarker.ttf']);
    await _font('MaterialIcons', ['$m/MaterialIcons-Regular.otf']);
    await _font('Roboto', ['$m/Roboto-Regular.ttf']);
  });

  setUp(() {
    answer = page;
    asked.clear();
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add('${request.method} ${request.url.path}');
      final body = switch (request.url.path) {
        '/discover' => answer(),
        '/discover/genres' => {
            'following': ['techno'],
            'suggested': [
              {'genre': 'ambient', 'why': 'from Morning Static'}
            ],
            'found': request.url.queryParameters['q'] == 'sho' ? ['shoegaze'] : ['house', 'ambient'],
          },
        '/discover/feed/seen' => {'seen': 1},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, Widget body,
      {Size size = const Size(420, 900), bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        theme: dark ? MuseTheme.dark() : MuseTheme.light(),
        home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: body)),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (out == null) return;
    await tester.runAsync(() async {
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('the page draws every department it was given', (tester) async {
    await show(tester, const DiscoverPage());
    expect(tester.takeException(), isNull);
    expect(find.text('MADE FOR YOU'), findsOneWidget);
    expect(find.text("THIS WEEK'S FINDS"), findsOneWidget);
    expect(find.text('DAILY MIX 1'), findsOneWidget);
    expect(find.text('STATIONS'), findsOneWidget);
    expect(find.text('TECHNO RADIO'), findsOneWidget, reason: 'a station made before');
    expect(find.text('Morning Static'), findsWidgets, reason: 'an act to start one from');
    expect(find.text('TECHNO'), findsWidgets, reason: 'a followed genre to start one from');
    expect(find.text('NEW RELEASES'), findsOneWidget);
    expect(find.text('New Record'), findsOneWidget);
    expect(find.text('Warehouse'), findsOneWidget, reason: 'a record in a followed genre');
    expect(find.text('Following 12 artists and 1 genre.'), findsOneWidget);
  });

  // The pictures are taken without the "1 NEW" sticker: with real fonts loaded the
  // test rasteriser never returns from drawing it (it is on the live cover every day,
  // so this is the harness, not the sticker).
  Map<String, dynamic> quiet() {
    final p = page();
    (p['feed'] as Map)['unseen'] = 0;
    return p;
  }

  testWidgets('a phone, for looking at', (tester) async {
    answer = quiet;
    await show(tester, const DiscoverPage());
    expect(tester.takeException(), isNull);
    await shot(tester, 'discover-phone');
  });

  testWidgets('a desk gets the same page, wider', (tester) async {
    answer = quiet;
    await show(tester, const DiscoverPage(), size: const Size(1100, 900), dark: true);
    expect(tester.takeException(), isNull);
    await shot(tester, 'discover-desk-dark');
    await tester.scrollUntilVisible(find.text('ACTS TO TRY'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('ACTS TO TRY'), findsOneWidget);
    expect(find.text('Brand New Act'), findsOneWidget);
    await shot(tester, 'discover-desk-dark-down');
  });

  testWidgets('while the lists are being made the page says so and looks again', (tester) async {
    answer = () => page(built: false);
    await show(tester, const DiscoverPage());
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Being made out of what you play'), findsOneWidget);
    expect(find.text("THIS WEEK'S FINDS"), findsNothing);
    final before = asked.where((a) => a == 'GET /discover').length;
    // The server's word that they are done makes the page read again.
    answer = page;
    app.discoverBuilt++;
    app.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(asked.where((a) => a == 'GET /discover').length, before + 1);
    expect(find.text("THIS WEEK'S FINDS"), findsOneWidget);
    // Nothing left ticking once the page has what it wanted.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('a made list says why each song is in it, and can be kept', (tester) async {
    final list = Discover.fromJson(page()).lists.first;
    await show(tester, MadeListPage(slug: list.slug, first: list));
    expect(tester.takeException(), isNull);
    expect(find.text('Unheard Song'), findsOneWidget);
    expect(find.text('because you play Morning Static'), findsOneWidget);
    expect(find.byTooltip('Keep as a playlist'), findsOneWidget);
    await shot(tester, 'made-list-phone');
  });

  testWidgets('genres can be followed from the register', (tester) async {
    await show(tester, const GenresPage());
    expect(tester.takeException(), isNull);
    expect(find.text('FOLLOWING'), findsOneWidget);
    expect(find.text('TECHNO'), findsOneWidget);
    expect(find.text('AMBIENT'), findsWidgets, reason: 'suggested from what is played');
    await tester.enterText(find.byType(TextField), 'sho');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('SHOEGAZE'), findsOneWidget);
    await tester.tap(find.text('SHOEGAZE'));
    await tester.pump();
    expect(asked, contains('PUT /discover/genres/shoegaze'));
    await shot(tester, 'genres-phone');
  });
}
