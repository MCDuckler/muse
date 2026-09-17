// Do the album and artist pages show the whole record, or only what we downloaded?
//
// This is the complaint they were built for: an album somebody added two songs from
// looked like a two-song album, and an artist looked like those two songs. So the
// assertions are about the difference — more rows on the page than the library holds,
// rows that say they are not held, and a records list on the artist page — plus the
// follow button and the feed that follows from it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muse/main.dart' as app;
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/browse_page.dart';

const user = String.fromEnvironment('MUSE_USER', defaultValue: 'chris');
const pass = String.fromEnvironment('MUSE_PASS');

Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    tester.takeException();
  }
}

String visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? '')
    .where((s) => s.isNotEmpty)
    .join(' | ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an album page is the record, not just what we hold', (tester) async {
    app.main();
    await settle(tester, seconds: 4);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2), reason: 'login screen should be up');
    await tester.enterText(fields.at(0), user);
    await tester.enterText(fields.at(1), pass);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester, seconds: 8);

    final api = app.debugAppState!.api;

    // Pick an album the library has only part of — that is the case that used to look
    // wrong, and the one worth asserting on.
    final albums = (await api.albums()).items;
    AlbumSummary? partial;
    AlbumDetail? detail;
    for (final a in albums.take(12)) {
      final d = await api.albumDetail(album: a.name, artist: a.artist);
      if (d.complete && d.missing > 0) {
        partial = a;
        detail = d;
        break;
      }
    }
    expect(partial, isNotNull,
        reason: 'no album in this library resolved to a release with missing tracks');

    // The page has to show the whole record.
    expect(detail!.tracks.length, greaterThan(partial!.tracks),
        reason: 'the release should list more songs than the library holds: '
            '${detail.tracks.length} vs ${partial.tracks}');
    expect(detail.have, greaterThan(0),
        reason: 'what we do hold has to be matched into the release, not lost');
    expect(detail.tracks.where((t) => t.have).length, detail.have);

    // And the artist page has to be the artist, not a track list.
    final artistName = partial.artist;
    final artist = await api.artistDetail(artistName);
    expect(artist.remoteId, isNotNull,
        reason: 'the artist should resolve: $artistName');
    expect(artist.albums, isNotEmpty, reason: 'an artist has records');
    expect(artist.albums.length, greaterThan(1),
        reason: 'more than the one album we happen to have some of');
    expect(artist.albums.where((a) => a.have > 0), isNotEmpty,
        reason: 'the records we hold part of must be marked as held');

    // Following, and the feed it feeds.
    final before = await api.feed();
    await api.follow(remoteId: artist.remoteId, name: artist.name);
    final after = await api.artistDetail(artistName);
    expect(after.following, isTrue, reason: 'following must stick');

    final feed = await api.feed();
    expect(feed.following, greaterThan(0));
    expect(feed.items.where((f) => f.artistId == artist.remoteId), isNotEmpty,
        reason: 'their records should be in the feed. before=${before.items.length} '
            'after=${feed.items.length}');

    // Marking read is what makes the badge mean something.
    final unseen = [for (final f in feed.items) if (f.unseen) f.albumId];
    if (unseen.isNotEmpty) {
      await api.markFeedSeen(unseen);
      final quiet = await api.feed();
      expect(quiet.unseen, 0, reason: 'marking read must stick');
    }

    await api.unfollow(artist.remoteId!);
    expect((await api.artistDetail(artistName)).following, isFalse);

    // The screen, not just the API. Pushed onto the app's own navigator so it is the
    // real page in the real app rather than a widget in a test harness.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push(MaterialPageRoute(
        builder: (_) => AlbumPage(album: partial))));
    await settle(tester, seconds: 8);

    expect(find.textContaining('Not in your library'), findsWidgets,
        reason: 'a song we do not have must be shown, and shown as missing. '
            'On screen: ${visibleText(tester)}');
    expect(find.textContaining('missing'), findsWidgets,
        reason: 'and there must be a way to get it. '
            'On screen: ${visibleText(tester)}');
    expect(find.text('${detail.tracks.first.pos}'), findsWidgets,
        reason: 'track numbers come from the release');
  });
}
