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

  testWidgets('the list does not scroll away from you when the song changes',
      (tester) async {
    // Following the music is right while you are watching it, and wrong while you
    // are half way down a long queue looking for something: the list used to jump
    // to the new song whatever you were doing.
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final long = Queue.fromJson({
      'id': 1,
      'name': 'Mine',
      'cursor_index': 0,
      'position_ms': 0,
      'rev': 1,
      'items': [for (var i = 1; i <= 80; i++) song(i, i - 1)],
    });
    app.queues = [long];
    app.activeQueue = long;
    // Real async, not the test's fake clock: the player talks to the stub server
    // and waits on the fake engine, and neither of those moves under FakeAsync.
    await tester.runAsync(() => app.player!.loadQueue(long));

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePage())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Song 1'), findsOneWidget, reason: 'the playing song is in view');

    // Scroll a long way down, away from the song playing.
    final list = find.byType(ReorderableListView);
    await tester.drag(list, const Offset(0, -2400));
    await tester.pump(const Duration(milliseconds: 400));
    // One more: the row leaves the tree in that frame, and the pill is drawn in the
    // frame after the page has noticed.
    await tester.pump();
    final position = tester
        .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first)
        .position;
    final farDown = position.pixels;
    expect(farDown, greaterThan(1000));
    // The row is gone; the name that remains is on the pill.
    Finder rowOf(String title) =>
        find.descendant(of: find.byType(SongRow), matching: find.text(title));
    expect(rowOf('Song 1'), findsNothing, reason: 'it is off the screen');
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget,
        reason: 'the way back to it is offered');
    expect(find.text('Song 1'), findsOneWidget, reason: 'and the pill names it');

    // The song changes. Bound the way the app binds it, so the change reaches the
    // screen the way it does for real: through the app state, not by being looked at.
    app.bindPlayer();
    await tester.runAsync(() => app.player!.playAt(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(position.pixels, farDown,
        reason: 'the list stays where you left it: ${position.pixels}');
    expect(rowOf('Song 2'), findsNothing);
    expect(find.text('Song 2'), findsOneWidget,
        reason: 'the pill names the new song');

    // And the pill is the way back.
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(position.pixels, lessThan(300));
    expect(rowOf('Song 2'), findsOneWidget, reason: 'the playing row is back');
    expect(find.byIcon(Icons.arrow_upward), findsNothing,
        reason: 'and the pill goes once the song is in view again');
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
