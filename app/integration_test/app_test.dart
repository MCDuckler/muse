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
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/player_bar.dart';
import 'package:muse/src/ui/artwork.dart';
import 'package:muse/src/ui/record_stage.dart';
import 'package:muse/src/ui/downloads_page.dart';
import 'package:muse/src/ui/jam_page.dart';
import 'package:muse/src/ui/library_page.dart';
import 'package:muse/src/ui/queue_page.dart';
import 'package:muse/src/ui/search_page.dart';
import 'package:muse/src/ui/song_row.dart';

const user = String.fromEnvironment('MUSE_USER', defaultValue: 'chris');
const pass = String.fromEnvironment('MUSE_PASS');

/// Which icons are on screen, for when an icon finder comes up empty.
String visibleIcons(WidgetTester tester) => tester
    .widgetList<Icon>(find.byType(Icon))
    .map((w) => w.icon?.codePoint.toRadixString(16) ?? '?')
    .join(' ');

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
/// Tabs are addressed by label, not icon: destinations now use an outlined icon when
/// unselected and a filled one when selected, so an icon finder matches only half the
/// time.
Finder tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

/// Tabs live in an IndexedStack, so every page stays mounted and a bare finder will
/// happily match a widget on a page nobody can see. Scope to the page under test.
Finder onPage(Type page, Finder inner) =>
    find.descendant(of: find.byType(page), matching: inner);

/// Collected while pumping. The framework only reports "multiple exceptions were
/// detected" and swallows the first, which is no help at all when the widget tree is
/// throwing in a loop.
final caught = <String>[];

Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    final e = tester.takeException();
    if (e != null) {
      final text = e.toString();
      if (caught.length < 5 && !caught.any((c) => c == text)) caught.add(text);
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  // The framework reports "multiple exceptions were detected" and swallows the first
  // one, which is useless when something in the widget tree is throwing repeatedly.
  final renderErrors = <String>[];

  setUpAll(() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      if (renderErrors.length < 6 && !renderErrors.contains(text)) {
        renderErrors.add(text);
      }
      previous?.call(details);
    };
  });

  testWidgets('sign in, queue a song, play it, and keep playing while adding another',
      (tester) async {
    app.main();
    await settle(tester, seconds: 4);

    // ---- sign in ----
    expect(find.text('Sign in'), findsWidgets, reason: 'login screen should be up');
    // Two fields now: the server is correct by construction on web and hides behind
    // "Change server", so the common case is user and password only.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), user);
    await tester.enterText(fields.at(1), pass);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester, seconds: 6);
    expect(find.text('Queues'), findsWidgets,
        reason: 'should land on the home shell. On screen: ${visibleText(tester)}');

    // ---- a scratch queue of our own, so real ones stay untouched ----
    await tester.tap(tab('Queues'));
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
    await tester.tap(tab('Search'));
    await settle(tester, seconds: 3);
    // Scoped to the page: the queue dialog leaves a field behind for a frame, and
    // typing into that one searches nothing while the prompt stays on screen.
    await tester.enterText(onPage(SearchPage, find.byType(TextField)).first, 'lucky');
    // No submit any more: typing runs the search itself after a short debounce.
    await settle(tester, seconds: 14);   // debounce plus the remote leg

    expect(onPage(SearchPage, find.textContaining('IN YOUR LIBRARY')), findsOneWidget,
        reason: 'the seeded track must come back from the local catalog (header is uppercased). '
            'On screen: ${visibleText(tester)}');
    // Add a track by name, not by position: the library grows, so "the first result"
    // stops being the track this test reasons about.
    // Songs are drawn by one widget everywhere now, so the row is a SongRow rather
    // than whatever each screen used to build for itself.
    await tester.tap(onPage(
      SearchPage,
      find.ancestor(
        of: find.textContaining('Get Lucky'),
        matching: find.byType(SongRow),
      ),
    ).first);
    await settle(tester, seconds: 2);
    note('afterAdd active=${app.debugAppState?.activeQueue?.name} '
        'items=${app.debugAppState?.activeQueue?.items.length} '
        'pos=${app.debugAppState?.activeQueue?.positionMs} '
        'engine=${app.debugEngineState()}');
    await settle(tester, seconds: 4);

    // ---- play it from the queue ----
    await tester.tap(tab('Queues'));
    await settle(tester, seconds: 3);

    // Tap the row we just added, not simply the first one: a queue can hold tracks
    // that are still downloading, and those are deliberately not tappable.
    final row = onPage(
      QueuePage,
      find.ancestor(
        of: find.textContaining('Get Lucky'),
        matching: find.byType(SongRow),
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
    await tester.tap(tab('Search'));
    await settle(tester);
    // Add another track through the explicit menu this time. Scroll it into view
    // first: tapping a button below the fold silently does nothing, and the failure
    // then surfaces further down as "no element" on the menu that never opened.
    final menuButton = onPage(SearchPage, find.byIcon(Icons.playlist_add)).at(1);
    await tester.ensureVisible(menuButton);
    await settle(tester, seconds: 1);
    await tester.tap(menuButton);
    await settle(tester, seconds: 2);
    expect(find.text('Add to end'), findsWidgets,
        reason: 'the queue menu should be open. On screen: ${visibleText(tester)}');
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

    // ---- skipping must land on the song the UI is showing ----
    // The engine loading one track while the list highlights another is what "it does
    // not reliably play the right song" looked like from outside.
    // Make sure the queue holds two *distinct* ready tracks. Searching one term can
    // easily return the same song twice, and "skip" onto another copy of the same
    // track proves nothing about landing on the right song.
    final appState = app.debugAppState!;
    final playing = appState.player!.current!.id;
    final other = (await appState.api.search('otherside'))
        .local
        .where((t) => t.id != playing && t.isReady)
        .toList();
    expect(other, isNotEmpty, reason: 'need a second distinct ready track to skip to');

    // Start from a known two-track queue. Earlier steps deliberately add the same
    // song more than once, and skipping onto another copy of it is correct behaviour
    // that would make this assertion meaningless.
    await appState.clearQueue();
    await settle(tester, seconds: 2);
    await appState.addTrack(appState.player!.items.isEmpty
        ? other.first
        : appState.player!.items.first);
    final firstTrack = (await appState.api.search('get lucky'))
        .local
        .firstWhere((t) => t.isReady);
    await appState.addTrack(firstTrack);
    await appState.addTrack(other.first);
    await settle(tester, seconds: 3);
    await appState.player!.playTrack(firstTrack.id);
    await settle(tester, seconds: 5);

    final startId = app.debugPlayerSnapshot()!.current!.id;
    final startIndex = app.debugPlayerSnapshot()!.index;
    await appState.player!.next();
    await settle(tester, seconds: 5);
    final afterSkip = app.debugPlayerSnapshot()!;
    expect(afterSkip.isConsistent, isTrue,
        reason: 'loaded ${afterSkip.loadedTrackId} but showing ${afterSkip.current?.id}');
    expect(afterSkip.index, isNot(startIndex),
        reason: 'skip must move through the queue. queue='
            '${appState.player!.items.map((t) => "${t.id}:${t.state}").join(",")}');
    expect(afterSkip.current!.id, isNot(startId),
        reason: 'and it must land on a different song');

    // Two skips in quick succession: the slower load must not win the race.
    await appState.player!.next();
    await appState.player!.next();
    await settle(tester, seconds: 6);
    final afterDouble = app.debugPlayerSnapshot()!;
    expect(afterDouble.isConsistent, isTrue,
        reason: 'rapid skips left the engine on the wrong track: '
            'loaded ${afterDouble.loadedTrackId}, showing ${afterDouble.current?.id}');

    // Skipping off the end of a short queue stops playback, which is correct — so
    // start something again before testing that typing does not disturb it.
    await appState.player!.playTrack(firstTrack.id);
    await settle(tester, seconds: 5);
    expect(app.debugPlayerSnapshot()!.playing, isTrue,
        reason: 'playback should resume when a track is picked again');

    // ---- typing in search must not fire playback shortcuts ----
    // S is shuffle, N is next, space is play/pause. Typing "snx " into the search box
    // used to shuffle the queue, skip the track and pause the music.
    await tester.tap(tab('Search'));
    await settle(tester, seconds: 2);
    final orderBefore = [for (final t in appState.player!.items) t.id];
    final trackBefore = app.debugPlayerSnapshot()!.current?.id;
    await tester.enterText(onPage(SearchPage, find.byType(TextField)).first, 'sn ');
    await settle(tester, seconds: 3);
    final typed = app.debugPlayerSnapshot()!;
    expect(typed.playing, isTrue, reason: 'space in the search box must not pause');
    expect([for (final t in appState.player!.items) t.id], orderBefore,
        reason: 's in the search box must not shuffle the queue');
    expect(typed.current?.id, trackBefore, reason: 'n in the search box must not skip');

    // ---- the now-playing screen opens from the bar and can scrub ----
    await tester.tap(find.descendant(
        of: find.byType(PlayerBarMarker), matching: find.byType(ListTile)));
    await settle(tester, seconds: 3);
    expect(find.byType(Slider), findsWidgets,
        reason: 'now playing must offer a real scrubber. On screen: ${visibleText(tester)}');

    // The player shows a record being played: the jacket standing up, the disc out
    // and turning. Screenshots so the thing can be looked at, not just asserted about.
    expect(find.byType(RecordStage), findsOneWidget,
        reason: 'the player artwork must be the record, not a flat square');
    final onScreen = app.debugPlayerSnapshot()?.current;
    if (onScreen != null) {
      expect(appState.api.jacketUrl(onScreen), contains('style=jacket'));
      expect(appState.api.discUrl(onScreen), contains('style=disc'));
    }
    await binding.takeScreenshot('player-playing');
    await appState.player!.playPause();
    await settle(tester, seconds: 3);
    await binding.takeScreenshot('player-paused');
    await appState.player!.playPause();
    await settle(tester, seconds: 1);
    await binding.takeScreenshot('player-standing-up');
    await settle(tester, seconds: 2);

    // Skipping is one journey along the shelf, so the sleeve that was next has to end
    // up in the middle. Caught here because the record only ever *looks* wrong: the
    // shot is the evidence, and the assertion is that the thing still stands after it.
    await appState.player!.next();
    await settle(tester);
    await binding.takeScreenshot('player-mid-skip');
    await settle(tester, seconds: 3);
    await binding.takeScreenshot('player-after-skip');
    expect(find.byType(RecordStage), findsOneWidget,
        reason: 'the stage must survive a skip');

    final beforeSeek = app.debugPlayerSnapshot()!.position;
    final scrubber = find.byType(Slider).first;
    await tester.tap(scrubber);            // taps the middle of the track
    await settle(tester, seconds: 4);
    final afterSeek = app.debugPlayerSnapshot()!;
    expect(afterSeek.position, isNot(beforeSeek), reason: 'seeking must move playback');
    expect(afterSeek.playing, isTrue, reason: 'seeking must not stop playback');

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await settle(tester, seconds: 2);

    // ---- search reacts to typing, without a submit ----
    await tester.tap(tab('Search'));
    await settle(tester, seconds: 2);
    await tester.enterText(onPage(SearchPage, find.byType(TextField)).first, 'daft punk');
    await settle(tester, seconds: 12);      // debounce plus the remote leg
    expect(onPage(SearchPage, find.textContaining('Daft Punk')), findsWidgets,
        reason: 'typing alone must produce results, with no submit. '
            'On screen: ${visibleText(tester)}');

    // Clearing the field returns to the prompt rather than an ambiguous empty list.
    // (A "nothing found" query is not deterministic here: YouTube Music answers even
    // nonsense with fuzzy matches, so that state is covered by a widget test.)
    expect(onPage(SearchPage, find.byIcon(Icons.close)), findsOneWidget,
        reason: 'a field with text in it needs a way to clear it');
    await tester.tap(onPage(SearchPage, find.byIcon(Icons.close)));
    await settle(tester, seconds: 3);
    expect(find.textContaining('Find something to play'), findsOneWidget,
        reason: 'an empty field must look different from a search that found nothing');

    // ---- removing a track offers to put it back ----
    await tester.tap(tab('Queues'));
    await settle(tester, seconds: 2);
    final queueLength = appState.player!.items.length;
    if (queueLength > 1) {
      final doomed = appState.player!.items[1];
      await appState.removeFromQueue(1, context: tester.element(find.byType(QueuePage)));
      await settle(tester, seconds: 3);
      expect(appState.player!.items.length, queueLength - 1);
      expect(find.text('Undo'), findsOneWidget,
          reason: 'a destructive action must offer a way back');

      await tester.tap(find.text('Undo'));
      await settle(tester, seconds: 5);
      expect(appState.player!.items.length, queueLength,
          reason: 'undo must restore the track');
      expect(appState.player!.items[1].id, doomed.id,
          reason: 'and put it back where it was, not on the end');
    }

    // ---- the library can be browsed at all ----
    final api2 = appState.api;
    final all = await api2.libraryTracks(limit: 5);
    expect(all.total, greaterThan(0), reason: 'the library must be listable');
    final albums = (await api2.albums()).items;
    final artists = (await api2.artists()).items;
    expect(albums, isNotEmpty, reason: 'albums come from track metadata');
    expect(artists, isNotEmpty);
    final albumTracks = await api2.albumTracks(albums.first.name,
        artist: albums.first.artist);
    expect(albumTracks, isNotEmpty,
        reason: 'an album that is listed must have tracks behind it');
    final played = await api2.playHistory();
    if (played.isNotEmpty) {
      expect(played.first.playedAt, isNotNull,
          reason: 'history entries must carry when they happened');
    }

    // ---- shuffling rearranges the queue itself, and keeps all of it ----
    // Read the count here rather than earlier: the steps in between deliberately
    // change the queue, and a stale count would fail for the wrong reason.
    final before = await api.queue(scratchId!);
    final itemsBefore = before.items.length;
    await app.debugAppState!.shuffleWhatIsComing();
    await app.debugAppState!.cycleRepeat();
    await settle(tester, seconds: 4);
    final settings = await api.queue(scratchId!);
    expect(settings.repeat, 'all');
    expect(settings.items.length, itemsBefore,
        reason: 'shuffling must never lose a song');
    expect([for (final t in settings.items) t.id]..sort(),
        [for (final t in before.items) t.id]..sort(),
        reason: 'the same songs, rearranged — not different ones');
    expect(settings.items[settings.cursorIndex].id,
        before.items[before.cursorIndex].id,
        reason: 'and the song playing is still the song playing');

    // ---- playlists have covers of their own ----
    await tester.tap(tab('Library'));
    await settle(tester, seconds: 3);
    final playlists = appState.playlists;
    if (playlists.isNotEmpty) {
      final art = appState.api.playlistCoverUrl(playlists.first);
      expect(art, isNotNull,
          reason: 'every playlist must offer a cover, even an empty one');
      expect(art, contains('v='), reason: 'the URL must carry the art version');
      expect(onPage(LibraryPage, find.byType(PlaylistArt)), findsWidgets,
          reason: 'the playlist list must show that art, not a generic icon. '
              'On screen: ${visibleText(tester)}');
    }

    // ---- sleep timer and speed ----
    // Both live in the player's app bar, so the player has to be open: the earlier
    // section closed it on its way out.
    await tester.tap(find.descendant(
        of: find.byType(PlayerBarMarker), matching: find.byType(ListTile)));
    await settle(tester, seconds: 3);
    expect(find.byIcon(Icons.timer_outlined), findsWidgets,
        reason: 'the open player must offer the sleep timer. '
            'Icons: ${visibleIcons(tester)}');
    await tester.tap(find.byIcon(Icons.timer_outlined).first);
    await settle(tester, seconds: 2);
    expect(find.text('Sleep timer'), findsOneWidget,
        reason: 'On screen: ${visibleText(tester)}');
    await tester.tap(find.text('1.5×'));
    await settle(tester, seconds: 2);
    expect(appState.player!.speed, 1.5, reason: 'speed must reach the engine');
    await tester.tap(find.text('Normal'));
    await settle(tester, seconds: 2);
    await tester.tap(find.text('30 min'));
    await settle(tester, seconds: 2);
    expect(appState.sleepAt, isNotNull, reason: 'the timer must be set');
    expect(find.textContaining('Stops in'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester, seconds: 2);
    expect(appState.sleepAt, isNull);
    await tester.tapAt(const Offset(200, 60));      // dismiss the sheet
    await settle(tester, seconds: 2);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await settle(tester, seconds: 2);

    // ---- the other sources answer too ----
    // SoundCloud and Bandcamp are fetched by the server, so these must work whether or
    // not the machine at home is awake.
    final scHits = await appState.api.searchSource('soundcloud', 'tycho awake', limit: 3);
    expect(scHits, isNotEmpty, reason: 'SoundCloud must answer a search');
    expect(scHits.first.durationMs, isNotNull,
        reason: 'durations come through, so a thirty-second preview is visible as one');

    final album = await appState.api.previewAlbum('https://tycho.bandcamp.com/album/awake');
    expect(album.tracks.length, greaterThan(4),
        reason: 'a Bandcamp album page carries the whole record in one request');
    expect(album.artist, 'Tycho');
    expect(album.tracks.every((t) => t.title.isNotEmpty), isTrue);

    // ---- a track says where it came from, when that is worth saying ----
    final fromYouTube = Track.fromJson(const {
      'id': 1, 'title': 'x', 'artists': ['y'], 'state': 'ready', 'source': 'youtube'});
    final fromBandcamp = Track.fromJson(const {
      'id': 2, 'title': 'x', 'artists': ['y'], 'state': 'ready', 'source': 'bandcamp'});
    expect(fromYouTube.sourceLabel, isNull,
        reason: 'almost everything is from YouTube; saying so on every row is noise');
    expect(fromBandcamp.sourceLabel, 'Bandcamp');

    // ---- services linked by name ----
    final services = await appState.api.linkedServices();
    expect(services.map((s) => s.provider).toList(),
        ['deezer', 'soundcloud', 'bandcamp']);
    expect(services.firstWhere((s) => s.provider == 'deezer').plays, isFalse,
        reason: 'Deezer can say what is in a playlist but cannot be played');
    // Linking is typing a name; a name that is not a profile has to say so rather than
    // failing silently.
    await expectLater(
        appState.api.linkService('bandcamp', 'definitely-not-a-fan-page-xyzzy'),
        throwsA(isA<ApiException>()));

    // ---- another device changes the queue ----
    // This is what a jam is underneath: someone else's edit to the queue this device
    // is playing. It has to arrive without anyone pressing refresh.
    final beforeCount = appState.player!.items.length;
    final elsewhere = ApiClient(
        baseUrl: appState.api.baseUrl, token: appState.api.token);
    final extra = await elsewhere.resolve(query: 'daft punk get lucky');
    await elsewhere.addToQueue(scratchId!, [extra.id]);
    await settle(tester, seconds: 8);
    expect(appState.player!.items.length, beforeCount + 1,
        reason: 'a change made on another device must arrive on its own. '
            'On screen: ${visibleText(tester)}');

    // ---- the artwork style is a choice ----
    // Whatever the previous section left open, settings is reached from the shell.
    if (find.byIcon(Icons.keyboard_arrow_down).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await settle(tester, seconds: 2);
    }
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget,
        reason: 'should be back on the shell. On screen: ${visibleText(tester)}');
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await settle(tester, seconds: 3);
    // The page's own list, not any scrollable on it: the colour swatches are a
    // horizontal strip, and "the last scrollable" quietly became that.
    final settingsList = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down);
    await tester.scrollUntilVisible(find.text('Album cover'), 120,
        scrollable: settingsList.last);
    await settle(tester, seconds: 1);
    await tester.tap(find.text('Album cover'));
    await settle(tester, seconds: 2);
    expect(appState.coverStyle, CoverStyle.flat);
    // Scroll to it as well: the settings page has grown, and "visible earlier" is not
    // the same as "still on screen".
    await tester.scrollUntilVisible(find.text('Record'), -120,
        scrollable: settingsList.last);
    await settle(tester, seconds: 1);
    await tester.tap(find.text('Record'));
    await settle(tester, seconds: 2);
    expect(appState.coverStyle, CoverStyle.record,
        reason: 'the choice must stick and be reversible');
    await tester.pageBack();
    await settle(tester, seconds: 2);

    // ---- listening together ----
    // A jam left running by an earlier run would change both the icon and the screen,
    // so start from nothing.
    if (appState.jam != null) {
      await appState.leaveJam();
      await settle(tester, seconds: 3);
    }
    await tester.tap(find.byIcon(Icons.podcasts_outlined));
    await settle(tester, seconds: 3);
    expect(find.byType(JamPage), findsOneWidget);
    expect(find.textContaining('Listen together'), findsOneWidget,
        reason: 'with no jam running the screen explains what one is. '
            'On screen: ${visibleText(tester)}');

    await appState.startJam();
    await settle(tester, seconds: 3);
    final jam = appState.jam;
    expect(jam, isNotNull, reason: 'starting a jam must produce one');
    expect(jam!.code.length, 6);
    expect(find.text(jam.code), findsOneWidget,
        reason: 'the code is the point of the screen and must be on it');
    expect(jam.isHost, isTrue);
    expect(jam.queueId, scratchId, reason: 'a jam opens the queue you are playing');

    await appState.leaveJam();
    await settle(tester, seconds: 3);
    expect(appState.jam, isNull, reason: 'ending a jam must leave nothing running');
    await tester.pageBack();
    await settle(tester, seconds: 2);

    // ---- the download queue can be looked at and understood ----
    // Read-only on purpose: the real server here is mid-import, and pause/cancel are
    // covered by server tests. What can only break here is the screen itself.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await settle(tester, seconds: 3);
    // A page that throws while building leaves an ErrorWidget behind, which contains
    // no Text and no Scrollable at all — so check the shape of the page, and report
    // what the tree threw, or the failure says nothing about why.
    expect(find.byType(Scrollable), findsWidgets,
        reason: 'settings must open. caught=$caught');
    // Settings is a lazy ListView: a row below the fold does not exist in the tree
    // yet, so it has to be scrolled to before it can be found at all.
    // The page's own list again: "the last scrollable" is the horizontal strip of
    // colour swatches, and dragging that downwards moves nothing at all.
    await tester.scrollUntilVisible(find.text('Download queue'), 120,
        scrollable: settingsList.last);
    await settle(tester, seconds: 2);
    expect(find.text('Download queue'), findsOneWidget,
        reason: 'downloads must be reachable without hunting. '
            'On screen: ${visibleText(tester)}');
    await tester.tap(find.text('Download queue'));
    await settle(tester, seconds: 6);
    expect(find.byType(DownloadsPage), findsOneWidget);
    final overview = await appState.api.downloads();
    expect(
        find.textContaining(overview.paused
            ? 'Paused'
            : overview.outstanding == 0
                ? 'Up to date'
                : 'to download'),
        findsWidgets,
        reason: 'the screen must say what the queue is doing. '
            'On screen: ${visibleText(tester)}');
    if (overview.batches.isNotEmpty) {
      expect(find.textContaining(overview.batches.first.label), findsWidgets,
          reason: 'an import must appear as one named row, not N anonymous ones');
      expect(onPage(DownloadsPage, find.byType(LinearProgressIndicator)), findsWidgets,
          reason: 'and carry how far along it is');
    }
    await tester.pageBack();
    await settle(tester, seconds: 2);

    expect(caught, isEmpty,
        reason: 'the widget tree must not throw while all this happens');
  });
}
