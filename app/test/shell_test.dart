// The shell: the four tabs, and what happens to a screen opened from one.
//
// Two complaints, one cause. Opening an album, an artist or a playlist pushed it over
// the whole app, so the bar with the tabs in it vanished — there was no way anywhere
// except back the way you came — and coming back to the library later found it at its
// top rather than on the playlist you had been reading, because the screen you were on
// had been thrown away when you left the tab.
//
// Each tab now has a navigator of its own: what it opens belongs to it, the shell
// stays on screen underneath, and a tab you are not looking at keeps what it was
// showing.
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
import 'package:muse/src/ui/desk_dock.dart';
import 'package:muse/src/ui/home_page.dart';
import 'package:muse/src/ui/now_playing.dart';
import 'package:muse/src/ui/widths.dart';
import 'package:muse/src/ui/mini_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState()..api = ApiClient(baseUrl: 'http://example.invalid');
  });

  /// A tab's worth of shell: the two pieces this is about, with pages that do nothing
  /// but say their name — the real tabs all talk to a server.
  Future<NavigatorState> shell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: Scaffold(
          extendBody: true,
          body: InsideShell(
            bottomInsetHere: 96,
            child: Navigator(
              key: key,
              onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('the library')),
              ),
            ),
          ),
          bottomNavigationBar: const MuseNavigationBar(),
        ),
      ),
    ));
    await tester.pump();
    return key.currentState!;
  }

  testWidgets('a screen opened inside a tab keeps the tabs on screen',
      (tester) async {
    final navigator = await shell(tester);
    expect(find.text('Library'), findsOneWidget, reason: 'the bar is there to start');

    navigator.push(MaterialPageRoute(
        builder: (_) => const PlayerScaffold(body: Text('a playlist'))));
    await tester.pumpAndSettle();

    expect(find.text('a playlist'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget,
        reason: 'the way to the other three tabs is still under it');
    expect(find.byType(NavigationBar), findsOneWidget,
        reason: 'one bar, the shell’s — not a second one under the page');
  });

  testWidgets('a page inside the shell does not carry its own player',
      (tester) async {
    final navigator = await shell(tester);
    navigator.push(MaterialPageRoute(
        builder: (_) => const PlayerScaffold(body: Text('a playlist'))));
    await tester.pumpAndSettle();

    // The shell is already carrying the player at its bottom; a second one under this
    // page would be two players stacked on one screen.
    expect(find.byType(MiniPlayer), findsNothing);
  });

  testWidgets('a screen opened over the whole app still offers the tabs',
      (tester) async {
    await shell(tester);
    // Not inside the shell: pushed on the app's own navigator, the way the player
    // opens things.
    final root = tester.state<NavigatorState>(find.byType(Navigator).first);
    root.push(MaterialPageRoute(
        builder: (_) => const PlayerScaffold(body: Text('from the player'))));
    await tester.pumpAndSettle();

    expect(find.text('from the player'), findsOneWidget);
    expect(find.byType(NavigationBar), findsWidgets,
        reason: 'a screen over the app carries the bar out of itself');
  });

  testWidgets('the real shell builds, with the tabs under it', (tester) async {
    // The whole thing, with a server that answers everything with nothing: the tabs
    // are built for real, which is what catches a shell that throws before anybody
    // sees it.
    useThisClientInstead(MockClient((request) async => http.Response(
        request.url.path.endsWith('/queues') ? '[]' : '{}', 200,
        headers: {'content-type': 'application/json'})));
    addTearDown(() => useThisClientInstead(http.Client()));
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Library'), findsWidgets, reason: 'the tab, in the bar');

    // Put the tree away and let whatever the tabs scheduled run out: several of them
    // poll, and a timer still pending when a test ends fails the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  /// The whole shell at a given width, with a server that answers everything with
  /// nothing.
  Future<void> wholeShell(WidgetTester tester, Size size) async {
    useThisClientInstead(MockClient((request) async => http.Response(
        request.url.path.endsWith('/queues') ? '[]' : '{}', 200,
        headers: {'content-type': 'application/json'})));
    addTearDown(() => useThisClientInstead(http.Client()));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Put the tree away and let what the tabs scheduled run out: several of them poll,
  /// and a timer still pending when a test ends fails the test.
  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('a phone still gets the bar across the bottom', (tester) async {
    await wholeShell(tester, const Size(420, 900));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(DeskDock), findsNothing,
        reason: 'there is no room beside a phone');
    await drain(tester);
  });

  testWidgets('a desk gets a rail down the side and the player beside the page',
      (tester) async {
    await wholeShell(tester, const Size(1440, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing,
        reason: 'the four destinations are in the rail, not across the bottom');
    expect(find.byType(DeskDock), findsOneWidget);
    expect(find.byType(DeskNowPlaying), findsOneWidget,
        reason: 'what is playing stays on screen while you read something else');
    await drain(tester);
  });

  testWidgets('the dock folds away and stays folded', (tester) async {
    await wholeShell(tester, const Size(1440, 900));
    final dock = tester.widget<DeskDock>(find.byType(DeskDock));
    expect(dock.open, isTrue);

    app.toggleDeskDock();
    await tester.pumpAndSettle();
    expect(tester.widget<DeskDock>(find.byType(DeskDock)).open, isFalse);
    expect(app.deskDock, isFalse, reason: 'and it is remembered for next time');
    await drain(tester);
  });

  testWidgets('a middling window has the rail but keeps the player at the bottom',
      (tester) async {
    await wholeShell(tester, const Size(900, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(DeskDock), findsNothing,
        reason: 'not enough width to give three hundred of it away');
    await drain(tester);
  });

  testWidgets('a page keeps a readable measure however wide the window is',
      (tester) async {
    // A song row that runs the whole width of a desk has its artwork at one end and
    // its menu button a thousand pixels away at the other, and reading one row means
    // crossing the screen.
    await wholeShell(tester, const Size(1920, 900));
    // The box Readable puts round the page, not the room it was given.
    final page = tester.getSize(find
        .descendant(
            of: find.byType(Readable).first,
            matching: find.byType(ConstrainedBox))
        .first);
    expect(page.width, lessThanOrEqualTo(1100),
        reason: 'the page stops at a measure, the window does not');
    expect(page.width, greaterThan(600), reason: 'and it does use the room it has');
    await drain(tester);
  });

  testWidgets('the tab you left is where you left it', (tester) async {
    // What "the library is saved when you leave it" means: the tab is built once and
    // kept, so the screen it was showing is still the screen it shows.
    final library = GlobalKey<NavigatorState>();
    var tab = 2;
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: StatefulBuilder(
          builder: (context, refresh) => Scaffold(
            body: IndexedStack(
              index: tab,
              children: [
                const Text('queues'),
                const Text('search'),
                Navigator(
                  key: library,
                  onGenerateRoute: (_) => MaterialPageRoute(
                      builder: (_) => const Text('the library')),
                ),
                const Text('people'),
              ],
            ),
            bottomNavigationBar: TextButton(
              onPressed: () => refresh(() => tab = tab == 2 ? 0 : 2),
              child: const Text('switch'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    library.currentState!.push(
        MaterialPageRoute(builder: (_) => const Text('a playlist')));
    await tester.pumpAndSettle();
    expect(find.text('a playlist'), findsOneWidget);

    await tester.tap(find.text('switch'));         // off to the queue
    await tester.pumpAndSettle();
    await tester.tap(find.text('switch'));         // and back
    await tester.pumpAndSettle();

    expect(find.text('a playlist'), findsOneWidget,
        reason: 'back on the playlist that was open, not at the top of the library');
  });
}
