// Drives the real widgets in a real browser against a real server. This exists
// because "playback and queues are unreliable" was not visible in unit tests: the
// failures lived in how the player reacted to queue updates, not in any one call.
//
//   chromedriver --port=4444 &
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/app_test.dart -d web-server --browser-name=chrome \
//     --dart-define=MUSE_SERVER=https://... --dart-define=MUSE_USER=... --dart-define=MUSE_PASS=...
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muse/main.dart' as app;
import 'package:muse/src/ui/player_bar.dart';
import 'package:muse/src/ui/queue_page.dart';
import 'package:muse/src/ui/search_page.dart';

const user = String.fromEnvironment('MUSE_USER', defaultValue: 'chris');
const pass = String.fromEnvironment('MUSE_PASS');

/// What is actually on screen, for when a finder comes up empty in a headless run.
String visibleText(WidgetTester tester) {
  final texts = tester.widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
  return texts.join(' | ');
}

/// Icons repeat across the UI (queue_music is both a tab and an empty-state
/// illustration), so tab taps have to be scoped to the navigation bar or the test
/// silently stays on the wrong page and asserts against it.
Finder tab(IconData icon) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(icon),
    );

/// Tabs live in an IndexedStack, so every page stays mounted and a bare finder will
/// happily match a widget on a page nobody can see. Scope to the page under test.
Finder onPage(Type page, Finder inner) =>
    find.descendant(of: find.byType(page), matching: inner);

Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The test drives a real server, so it must not write into real queues. It makes
  // its own, uses only that, and deletes it afterwards. An earlier version added to
  // whatever queue happened to be active and left a dozen copies of one song there.
  final scratchName = 'e2e-${DateTime.now().millisecondsSinceEpoch}';
  int? scratchId;

  tearDownAll(() async {
    final api = app.debugAppState?.api;
    if (api != null && scratchId != null) {
      await api.deleteQueue(scratchId!);
    }
  });

  // flutter drive does not forward prints from a web test, so the trace travels in
  // the failure message instead.
  final trace = <String>[];
  void note(String s) => trace.add(s);

  testWidgets('sign in, queue a song, play it, and keep playing while adding another',
      (tester) async {
    app.main();
    await settle(tester, seconds: 4);

    // ---- sign in ----
    expect(find.text('Sign in'), findsOneWidget, reason: 'login screen should be up');
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.tap(find.text('Sign in'));
    await settle(tester, seconds: 6);
    expect(find.text('Queues'), findsWidgets,
        reason: 'should land on the home shell. On screen: ${visibleText(tester)}');

    // ---- a scratch queue of our own, so real ones stay untouched ----
    await tester.tap(tab(Icons.queue_music));
    await settle(tester, seconds: 2);
    await tester.tap(find.text('New queue'));
    await settle(tester, seconds: 2);
    await tester.enterText(find.byType(TextField).last, scratchName);
    await tester.tap(find.text('Create'));
    await settle(tester, seconds: 5);
    scratchId = app.debugAppState?.activeQueue?.id;
    note('scratch=${app.debugAppState?.activeQueue?.name} id=$scratchId '
        'pos=${app.debugAppState?.activeQueue?.positionMs} '
        'cursor=${app.debugAppState?.activeQueue?.cursorIndex}');
    expect(app.debugAppState?.activeQueue?.name, scratchName,
        reason: 'the scratch queue must be the active one before anything is added');

    // ---- find something already in the library and queue it ----
    await tester.tap(tab(Icons.search));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'lucky');
    // Tap the button rather than sending an IME action: the on-screen keyboard is not
    // real in a headless browser, so the submit action never arrives.
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await settle(tester, seconds: 14);   // the remote leg hits YouTube Music

    expect(onPage(SearchPage, find.text('IN YOUR LIBRARY')), findsOneWidget,
        reason: 'the seeded track must come back from the local catalog (header is uppercased). '
            'On screen: ${visibleText(tester)}');
    // Add a track by name, not by position: the library grows, so "the first result"
    // stops being the track this test reasons about.
    await tester.tap(onPage(
      SearchPage,
      find.ancestor(
        of: find.textContaining('Get Lucky'),
        matching: find.byType(ListTile),
      ),
    ).first);
    await settle(tester, seconds: 2);
    note('afterAdd active=${app.debugAppState?.activeQueue?.name} '
        'items=${app.debugAppState?.activeQueue?.items.length} '
        'pos=${app.debugAppState?.activeQueue?.positionMs} '
        'engine=${app.debugEngineState()}');
    await settle(tester, seconds: 4);

    // ---- play it from the queue ----
    await tester.tap(tab(Icons.queue_music));
    await settle(tester, seconds: 3);

    // Tap the row we just added, not simply the first one: a queue can hold tracks
    // that are still downloading, and those are deliberately not tappable.
    final row = onPage(
      QueuePage,
      find.ancestor(
        of: find.textContaining('Get Lucky'),
        matching: find.byType(ListTile),
      ),
    );
    expect(row, findsWidgets, reason: 'queued row missing. On screen: ${visibleText(tester)}');
    note('beforeTap ${app.debugEngineState()}');
    await tester.tap(row.first);
    await settle(tester, seconds: 4);
    note('afterTap4s ${app.debugEngineState()}');
    await settle(tester, seconds: 4);
    note('afterTap8s ${app.debugEngineState()}');

    final state = app.debugPlayerSnapshot();
    expect(state, isNotNull, reason: 'player should have loaded a track');
    expect(state!.error, isNull, reason: 'playback must not fail: ${state.error}');
    expect(state.playing, isTrue,
        reason: 'tapping a ready track should start audio. '
            'current=${state.current?.title} state=${state.current?.state} '
            'pos=${state.position} err=${state.error} '
            'engine[${app.debugEngineState()}] TRACE: ${trace.join(' || ')}');
    final firstPosition = state.position;
    expect(firstPosition, greaterThan(Duration.zero),
        reason: 'position must advance — a frozen position was the original bug');

    // ---- the regression that broke everything: adding a track mid-playback ----
    await tester.tap(tab(Icons.search));
    await settle(tester);
    // Add a *different* track, through the explicit menu this time.
    await tester.tap(onPage(SearchPage, find.byIcon(Icons.playlist_add)).last);
    await settle(tester, seconds: 2);
    await tester.tap(find.text('Add to end').last);
    await settle(tester, seconds: 5);

    final after = app.debugPlayerSnapshot()!;
    expect(after.playing, isTrue,
        reason: 'adding to the queue must not stop what is playing');
    expect(after.position, greaterThanOrEqualTo(firstPosition),
        reason: 'adding to the queue must not rewind the current track');

    // ---- the position must actually reach the server while playing ----
    // It never did: the save timer was re-armed by every position tick, so it only
    // fired once playback stopped, and closing the tab lost your place entirely.
    await settle(tester, seconds: 14);   // cursor is written every 10s of playback
    final api = app.debugAppState!.api;
    final saved = await api.queue(scratchId!);
    expect(saved.positionMs, greaterThan(0),
        reason: 'the play position must be persisted during playback, not only on stop');

    // ---- typing in search must not fire playback shortcuts ----
    // S is shuffle, N is next, space is play/pause. Typing "snx " into the search box
    // used to shuffle the queue, skip the track and pause the music.
    await tester.tap(tab(Icons.search));
    await settle(tester, seconds: 2);
    final shuffleBefore = app.debugPlayerSnapshot()!.shuffle;
    final trackBefore = app.debugPlayerSnapshot()!.current?.id;
    await tester.enterText(onPage(SearchPage, find.byType(TextField)).first, 'sn ');
    await settle(tester, seconds: 3);
    final typed = app.debugPlayerSnapshot()!;
    expect(typed.playing, isTrue, reason: 'space in the search box must not pause');
    expect(typed.shuffle, shuffleBefore, reason: 's in the search box must not shuffle');
    expect(typed.current?.id, trackBefore, reason: 'n in the search box must not skip');

    // ---- the now-playing screen opens from the bar and can scrub ----
    await tester.tap(find.descendant(
        of: find.byType(PlayerBarMarker), matching: find.byType(ListTile)));
    await settle(tester, seconds: 3);
    expect(find.byType(Slider), findsWidgets,
        reason: 'now playing must offer a real scrubber. On screen: ${visibleText(tester)}');

    final beforeSeek = app.debugPlayerSnapshot()!.position;
    final scrubber = find.byType(Slider).first;
    await tester.tap(scrubber);            // taps the middle of the track
    await settle(tester, seconds: 4);
    final afterSeek = app.debugPlayerSnapshot()!;
    expect(afterSeek.position, isNot(beforeSeek), reason: 'seeking must move playback');
    expect(afterSeek.playing, isTrue, reason: 'seeking must not stop playback');

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await settle(tester, seconds: 2);

    // ---- shuffle and repeat persist, and do not eat the queue ----
    final itemsBefore = saved.items.length;
    await app.debugAppState!.setShuffle(true);
    await app.debugAppState!.cycleRepeat();
    await settle(tester, seconds: 4);
    final settings = await api.queue(scratchId!);
    expect(settings.shuffle, isTrue);
    expect(settings.repeat, 'all');
    expect(settings.items.length, itemsBefore,
        reason: 'a settings change must never clear the queue');
  });
}
