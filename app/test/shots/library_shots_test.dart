// Pictures of the library with its sections folded, and of the services page:
// `flutter test test/shots/library_shots_test.dart` with SHOTS=<dir> in the environment
// writes PNGs there. Without it, it checks the pages build at a phone's size.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/library_page.dart';
import 'package:muse/src/ui/services_page.dart';
import 'package:muse/src/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['SHOTS'];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    const f = 'assets/fonts';
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/.local/flutter';
    final m = '$flutter/bin/cache/artifacts/material_fonts';
    await _font('Manrope', ['$f/Manrope.ttf']);
    await _font('Archivo', ['$f/Archivo.ttf']);
    await _font('CourierPrime', ['$f/CourierPrime-Regular.ttf', '$f/CourierPrime-Bold.ttf']);
    await _font('MaterialIcons', ['$m/MaterialIcons-Regular.otf']);
    await _font('Roboto', ['$m/Roboto-Regular.ttf']);
  });

  setUp(() {
    useThisClientInstead(MockClient((request) async {
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/library/tracks') => {'items': [], 'total': 22815},
        ('GET', '/library/albums') => {'items': [], 'total': 1203},
        ('GET', '/library/artists') => {'items': [], 'total': 4550},
        ('GET', '/feed') => {'items': [], 'unseen': 3, 'following': 12},
        ('GET', '/library/smart') => {
            'lists': [
              {'id': 'never', 'name': 'Never played', 'blurb': 'Not once put on', 'count': 812},
              {'id': 'most', 'name': 'Most played', 'blurb': 'The ones you come back to', 'count': 50},
            ],
          },
        ('GET', '/linked') => {
            'accounts': [
              {'provider': 'youtube', 'label': 'YouTube Music', 'hint': '', 'plays': false,
               'sign_in': 'code', 'linked': {'handle': 'Chris', 'display_name': 'Chris'}},
              {'provider': 'soundcloud', 'label': 'SoundCloud', 'hint': 'Paste your profile link',
               'plays': true, 'sign_in': 'name', 'linked': {'handle': 'chris', 'display_name': 'chris'}},
              {'provider': 'deezer', 'label': 'Deezer', 'hint': 'The numeric id', 'plays': false,
               'sign_in': 'name', 'linked': null},
            ],
          },
        ('GET', '/spotify/account') => {'configured': true, 'account': {'display_name': 'chris'}},
        ('GET', '/spotify/playlists') => {
            'items': [
              for (var i = 0; i < 18; i++)
                {'remote_id': 'sp$i', 'name': 'Spotify list ${i + 1}', 'owner': 'chris', 'count': 10 + i,
                 if (i < 2) 'mirror': {'playlist_id': 100 + i, 'tracks': 9 + i, 'unmatched': i}},
              {'remote_id': 'shz', 'name': 'My Shazam Tracks', 'count': 230, 'shazam': true},
            ],
          },
        ('GET', '/linked/youtube/playlists') => {
            'items': [
              {'remote_id': 'LM', 'name': 'Liked Songs', 'owner': 'you'},
              {'remote_id': 'PL1', 'name': 'Sunday Records', 'count': 9,
               'mirror': {'playlist_id': 9, 'items': 9}},
            ],
          },
        ('GET', '/linked/soundcloud/playlists') => {
            'items': [
              {'remote_id': 'chris/likes', 'name': 'Likes'},
              {'remote_id': 'chris/reposts', 'name': 'Reposts'},
            ],
          },
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
  });

  tearDown(() => useThisClientInstead(http.Client()));

  AppState state({Set<String> shrunk = const {}, Set<String> closed = const {}}) => AppState()
    ..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x')
    ..shrunkSections = {...shrunk}
    ..closedSections = {...closed}
    ..playlists = [
      Playlist.fromJson({'id': 1, 'name': 'Favourites', 'kind': 'favourites', 'items': 120}),
      Playlist.fromJson({'id': 2, 'name': 'Late night', 'kind': 'local', 'items': 34}),
      Playlist.fromJson({'id': 100, 'name': 'Spotify list 1', 'kind': 'spotify', 'items': 9}),
      Playlist.fromJson({'id': 101, 'name': 'Spotify list 2', 'kind': 'spotify', 'items': 10, 'unmatched': 1}),
      Playlist.fromJson({'id': 9, 'name': 'Sunday Records', 'kind': 'youtube', 'items': 9}),
    ];

  Future<void> shoot(WidgetTester tester, AppState app, Widget page, String name,
      {double height = 2600}) async {
    tester.view.physicalSize = Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MuseTheme.light(),
        builder: (context, child) =>
            RepaintBoundary(key: const ValueKey('shot'), child: child ?? const SizedBox()),
        home: Scaffold(body: page),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    if (out != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
      });
    }
  }

  testWidgets('the library in full', (tester) async {
    await shoot(tester, state(), const LibraryPage(), 'library-full', height: 3400);
  });

  testWidgets('the library shrunk, a service closed', (tester) async {
    await shoot(
        tester,
        state(
          shrunk: {'contents', 'smart', 'playlists', 'services'},
          closed: {'services:soundcloud'},
        ),
        const LibraryPage(),
        'library-shrunk');
  });

  testWidgets('the library closed', (tester) async {
    await shoot(
        tester,
        state(closed: {'contents', 'smart', 'playlists', 'services'}),
        const LibraryPage(),
        'library-closed',
        height: 844);
  });

  testWidgets('the services page', (tester) async {
    await shoot(tester, state(), const ServicesPage(), 'services', height: 1400);
  });
}

Future<void> _font(String family, List<String> files) async {
  final here = [for (final f in files) if (File(f).existsSync()) f];
  if (here.isEmpty) return;
  final l = FontLoader(family);
  for (final f in here) {
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}
