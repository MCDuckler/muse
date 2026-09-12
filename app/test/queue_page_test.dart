// The queue actually draws.
//
// This exists because of a grey rectangle. ReorderableListView reads the key off the
// top of each item it is handed; a row was wrapped in something new and the key stayed
// on the widget underneath, so the list threw on every build — and a thrown build in a
// release app is not a red screen with a message, it is a silent grey block where the
// music was. Nothing in the suite looked at the screen, so nothing caught it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/now_playing.dart';
import 'package:muse/src/ui/player_bar.dart';
import 'package:muse/src/ui/queue_page.dart';
import 'package:muse/src/ui/song_row.dart';

import 'fake_audio.dart';

Map<String, dynamic> song(int id, int pos) => {
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'album': 'A record',
      'duration_ms': 180000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'pos': pos,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(session, (call) async => null);

  late HttpServer server;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(request.uri.path == '/auth/stream-key'
            ? {
                'key': 'test-key',
                'expires_at':
                    DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
              }
            : {'ok': true}));
        await request.response.close();
      }
    }());
    JustAudioPlatform.instance = FakeJustAudio();

    final api = ApiClient(baseUrl: 'http://${server.address.host}:${server.port}');
    api.token = 'test-token';
    app = AppState();
    app.api = api;
    app.player = PlayerService(api);
    final queue = Queue.fromJson({
      'id': 1,
      'name': 'Mine',
      'cursor_index': 0,
      'position_ms': 0,
      'rev': 1,
      'items': [song(1, 0), song(2, 1), song(3, 2)],
    });
    app.queues = [queue];
    app.activeQueue = queue;
    // The rows on this screen come from the player, not from the queue object.
    await app.player!.init();
    await app.player!.loadQueue(queue);
  });

  tearDown(() async {
    await app.player!.dispose();
    await server.close(force: true);
  });

  testWidgets('the queue draws its rows', (tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePage())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull,
        reason: 'a queue that throws while building is a grey block in a release app');
    expect(find.byType(SongRow), findsWidgets);
    expect(find.text('Song 1'), findsOneWidget);
    expect(find.text('Song 3'), findsOneWidget);
  });

  testWidgets('swiping up on the player bar drags the player open', (tester) async {
    // The bar is the handle: a drag on it opens the player by however far it goes,
    // rather than asking for it and watching an animation happen. Wired through three
    // widgets — the marker, the drag that opens, and the sideways swipe that skips —
    // and the last of those used to claim the upward drag and do nothing with it.
    // A phone-shaped window: the player is a portrait screen and the default test
    // view is a small landscape one.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final routes = <Route<dynamic>>[];
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        navigatorObservers: [_Watching(routes)],
        home: const Scaffold(bottomNavigationBar: PlayerBar(), body: Text('behind')),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final bar = find.byType(PlayerBarMarker);
    expect(bar, findsOneWidget, reason: 'there is a bar to take hold of');

    // The marker holds still and what is inside it moves, so measure the inside.
    final inside = find.descendant(of: bar, matching: find.byType(ListTile));
    final at = tester.getRect(inside);
    final gesture = await tester.startGesture(tester.getCenter(bar));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();

    expect(tester.getRect(inside).top, lessThan(at.top - 20),
        reason: 'the bar follows the finger while the pull is happening');
    expect(routes.whereType<NowPlayingRoute>(), isEmpty,
        reason: 'nothing has been opened yet — the pull can still be abandoned');

    await gesture.up();
    await tester.pump();

    final opening = routes.whereType<NowPlayingRoute>().toList();
    expect(opening, hasLength(1), reason: 'letting go of a real pull opens it');
    expect(opening.single.hand!.value, greaterThan(0),
        reason: 'starting from where the pull got to, and carrying its speed');
    await tester.pumpAndSettle();
    expect(opening.single.hand!.value, 1);
  });

  testWidgets('a pull that is abandoned puts the bar back', (tester) async {
    // A phone-shaped window: the player is a portrait screen and the default test
    // view is a small landscape one.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final routes = <Route<dynamic>>[];
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        navigatorObservers: [_Watching(routes)],
        home: const Scaffold(bottomNavigationBar: PlayerBar(), body: Text('behind')),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final bar = find.byType(PlayerBarMarker);
    final inside = find.descendant(of: bar, matching: find.byType(ListTile));
    final at = tester.getRect(inside);
    final gesture = await tester.startGesture(tester.getCenter(bar));
    await gesture.moveBy(const Offset(0, -20));     // not far enough to mean it
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(routes.whereType<NowPlayingRoute>(), isEmpty);
    expect(tester.getRect(inside), at, reason: 'and it springs back where it was');
  });
}

/// Every route that went past, so a test can say what a gesture pushed.
class _Watching extends NavigatorObserver {
  _Watching(this.seen);
  final List<Route<dynamic>> seen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      seen.add(route);
}
