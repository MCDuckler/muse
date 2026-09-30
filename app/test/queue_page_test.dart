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

  /// What the fake house answers for a path, where a test wants to choose.
  final answers = <String, Map<String, dynamic>>{};

  /// Every request it was asked, so a test can say what the app did rather than guess.
  final asked = <String>[];

  /// Where a test wants the fake house to do the real one's arithmetic.
  Map<String, dynamic> Function(int from, int to)? moves;

  setUp(() async {
    answers.clear();
    asked.clear();
    moves = null;
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        asked.add('${request.method} ${request.uri.path}');
        request.response.headers.contentType = ContentType.json;
        final mover = moves;
        if (mover != null && request.uri.path == '/queues/1/move') {
          final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
          asked[asked.length - 1] = 'MOVE ${body['from']} -> ${body['to']}';
          request.response.write(jsonEncode(mover(
              (body['from'] as num).toInt(), (body['to'] as num).toInt())));
          await request.response.close();
          continue;
        }
        request.response.write(jsonEncode(answers[request.uri.path] ??
            (request.uri.path == '/auth/stream-key'
                ? {
                    'key': 'test-key',
                    'expires_at':
                        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
                  }
                : {'ok': true})));
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

  /// [total] past the number of rows makes it a *windowed* queue, which is the one
  /// that tops itself up as playback nears the edge of what was loaded.
  Map<String, dynamic> queueOf(int rev, List<int> ids, {int? total}) => {
        'id': 1,
        'name': 'Mine',
        'cursor_index': 0,
        'position_ms': 0,
        'rev': rev,
        'total': total ?? ids.length,
        'window_from': 0,
        'items': [for (final (i, id) in ids.indexed) song(id, i)],
      };

  test('an answer from before a reorder cannot put the row back', () async {
    // Reported as "reordering the queue in a jam always snaps back", on both sides of
    // the room. Every read of a queue races every write of it, and a room sends a
    // handful of events a minute, each of which re-reads the queue — so a drag that
    // takes a second nearly always has a read in flight across it. The row moved, the
    // house was told, the house agreed, and then an answer from *before* the drag
    // landed on top and put the row back.
    //
    // The queue's revision only ever goes up, so anything carrying an older one is
    // news from the past and is thrown away.
    answers['/queues/1/move'] = queueOf(2, [3, 1, 2]);
    await app.moveInQueue(2, 0);
    expect(app.player!.items.map((t) => t.id).toList(), [3, 1, 2]);

    // The room speaks, and what it has to say set off before the drag did.
    answers['/queues/1'] = queueOf(1, [1, 2, 3]);
    expect(await app.reloadQueueForTest(), isFalse, reason: 'older than what is on');
    expect(app.player!.items.map((t) => t.id).toList(), [3, 1, 2],
        reason: 'the row stayed where it was put');

    // Somebody else really does move something, and that is taken.
    answers['/queues/1'] = queueOf(3, [2, 3, 1]);
    expect(await app.reloadQueueForTest(), isTrue);
    expect(app.player!.items.map((t) => t.id).toList(), [2, 3, 1]);
  });

  test('topping the window up cannot put a reorder back either', () async {
    // The same race with no room involved at all. keepUpWithTheQueue re-reads the
    // queue whenever playback nears the edge of what was loaded — which on a long
    // queue is constantly — and it used to hand whatever came back to the player. A
    // drag across one of those had the row put back exactly as a jam did, which is why
    // this was reported again with no jam running.
    answers['/queues/1/move'] = queueOf(2, [3, 1, 2], total: 900);
    await app.moveInQueue(2, 0);
    expect(app.player!.items.map((t) => t.id).toList(), [3, 1, 2]);
    expect(app.activeQueue!.windowed, isTrue, reason: 'this is the topping-up kind');

    // A window read that set off before the drag.
    answers['/queues/1'] = queueOf(1, [1, 2, 3], total: 900);
    await app.keepUpWithTheQueue();
    expect(app.player!.items.map((t) => t.id).toList(), [3, 1, 2],
        reason: 'the row stayed where it was put');
  });

  test('the same revision twice is still taken, and a different queue always is',
      () async {
    // Equal is not older: two reads of one state have to agree, and refusing the
    // second would be refusing the truth.
    answers['/queues/1'] = queueOf(1, [1, 2, 3]);
    expect(await app.reloadQueueForTest(), isTrue);
    expect(await app.reloadQueueForTest(), isTrue);
  });

  testWidgets('Up next is a page of its own, with the queue on it', (tester) async {
    // The queue left the tabs for the player; opened from there it is a page with a
    // title of its own and the same rows as ever.
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: QueueScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('Up next'), findsOneWidget);
    // In the list, and on the player bar the page carries with it.
    expect(find.text('Song 1'), findsWidgets);
    expect(find.text('Song 3'), findsOneWidget);
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

  testWidgets('dragging a row by its grip actually moves it', (tester) async {
    // The thing that was reported, done the way a finger does it: take the grip, drag
    // the row, let go, and see where it is. Everything before this tested the state
    // underneath — which was fine — and never the drag itself.
    answers['/queues/1/move'] = queueOf(2, [3, 1, 2]);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePage())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final grips = find.byIcon(Icons.drag_indicator);
    expect(grips, findsWidgets, reason: 'every row has a grip to take it by');
    final third = tester.getCenter(grips.at(2));
    final first = tester.getCenter(grips.at(0));

    // Up, past the first row, and let go.
    final drag = await tester.startGesture(third);
    await tester.pump(const Duration(milliseconds: 40));
    // Moved a little at a time, the way a finger does: the recogniser wants to see the
    // pointer travel, not teleport.
    final travel = first.dy - 24 - third.dy;
    for (var step = 0; step < 10; step++) {
      await drag.moveBy(Offset(0, travel / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();

    expect(app.player!.items.map((t) => t.id).toList(), [3, 1, 2],
        reason: 'the third row was dragged to the top and has to stay there. '
            'What the app asked for: $asked');
    // And what is *drawn*, which is the thing that was reported. A reorderable list
    // decides what moved from the keys it was given, so a key that carries the row's
    // position rather than its name tells it nothing moved — the list is free to put
    // the row back where its key says it belongs, however the data underneath reads.
    final drawn = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d != null && d.startsWith('Song '))
        .toList();
    expect(drawn.take(3).toList(), ['Song 3', 'Song 1', 'Song 2'],
        reason: 'the rows on screen are in the order they were dragged into');
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

  // See tight_screen_test: the same question, for the two things that need a real
  // player to draw — the queue, and the bar that is on every screen.
  for (final scale in [1.6, 2.0]) {
    testWidgets('the queue and the bar hold on a small phone at ${scale}x text',
        (tester) async {
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
            child: const Scaffold(
              body: QueuePage(),
              bottomNavigationBar: PlayerBar(),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  }
}

/// Every route that went past, so a test can say what a gesture pushed.
class _Watching extends NavigatorObserver {
  _Watching(this.seen);
  final List<Route<dynamic>> seen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      seen.add(route);
}
