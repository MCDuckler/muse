// Where the record sits against the covers.
//
// The record on the deck is drawn behind the sleeves and peeks out from under them,
// and how much of it peeks is the whole point: the label is down there. Two things
// that both move decide it — the record is the width of the screen, the cover is
// whatever size somebody set it to — so the offset between them is worked out rather
// than picked, and this is the sum being checked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/ui/record_stage.dart';

Track song(int id) => Track(
    id: id,
    title: 'Song $id',
    artists: const ['Someone'],
    state: 'ready',
    source: 'youtube',
    coverPath: '/tracks/$id/cover',
    displayTitle: 'Song $id');

/// The smallest picture there is, so the artwork on stage loads rather than throwing.
final _pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==');

/// The cover in the middle: the square picture, without the reflection under it and
/// measured inside the sleeve's own transform, which is what puts it where it stands.
Finder _cover(double jacket) => find.descendant(
      of: find.byKey(const ValueKey('2@0.0')),
      matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == jacket && w.height == jacket),
    );

/// The record lying on the deck: the one box on stage that is a whole platter wide.
/// It is drawn as a turning picture rather than as a widget of its own, so it is found
/// by its size.
Finder _onTheDeck(double platter) => find.descendant(
      of: find.byType(Deck),
      matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == platter && w.height == platter),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late AppState app;

  setUp(() async {
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_pixel);
        await request.response.close();
      }
    }());
    final api = ApiClient(baseUrl: 'http://${server.address.host}:${server.port}');
    api.token = 'test-token';
    app = AppState();
    app.api = api;
  });

  tearDown(() => server.close(force: true));

  /// The stage as the player draws it: a square the width of the page, on a phone.
  Future<void> stage(WidgetTester tester, {required bool playing}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 352,
              height: 352,
              child: RecordStage(
                track: song(2),
                playing: playing,
                previous: song(1),
                next: song(3),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    // Longer than the record takes to come all the way out, for a stage that was
    // already standing when it was told something is playing.
    await tester.pump(const Duration(milliseconds: 1600));
  }

  testWidgets('a third of the record shows out from under the covers',
      (tester) async {
    await stage(tester, playing: true);

    final platter = 400 - 26.0 * 2;
    final record = tester.getRect(_onTheDeck(platter).first);
    final coverBottom = tester.getRect(_cover(352 * 0.74).first).bottom;
    // The record is drawn from its top to a little past its middle, fading out into
    // the deck rather than being cut at it.
    final showsTo = record.top + record.height * 0.52;

    expect(record.width, closeTo(platter, 0.5),
        reason: 'the record is the width of the screen, less its margins');
    expect(showsTo - coverBottom, closeTo(platter * 0.34, 2),
        reason: 'a third of it in the open, at the default cover size');
    expect(record.center.dy, greaterThan(coverBottom),
        reason: 'the label is the part being looked at, so it is not behind a cover');
  });

  testWidgets('the same third whatever size the covers are', (tester) async {
    // The sum is worth having only because it holds at both ends of the setting: a
    // fixed offset gave a sliver of record at one size and a floating cover at another.
    // Up to the size at which a sleeve and its reflection fill the stage: past that
    // the cover overflows the stage box, which it did long before any of this and is
    // not what is being measured here.
    for (final scale in [0.5, 0.6, 0.74, 0.8]) {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 352,
                height: 352,
                child: RecordStage(
                    key: ValueKey(scale),
                    track: song(2),
                    playing: true,
                    scale: scale,
                    previous: song(1),
                    next: song(3)),
              ),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 16));

      final record = tester.getRect(_onTheDeck(400 - 26.0 * 2).first);
      final peek = record.top +
          record.height * 0.52 -
          tester.getRect(_cover(352 * scale).first).bottom;
      expect(peek, closeTo((400 - 52) * 0.34, 2), reason: 'at cover size $scale');
    }
  });

  testWidgets('the reflection gives the deck up to the record', (tester) async {
    // The reflection lies in exactly the band the record comes to rest in, and a
    // cover ghosted across the label is why the record read as hidden rather than as
    // standing behind something.
    final mine = find.descendant(
        of: find.byKey(const ValueKey('2@0.0')), matching: find.byType(Mirror));

    await stage(tester, playing: false);
    expect(mine, findsOneWidget,
        reason: 'nothing is out, so the sleeve stands on its own reflection');
    expect(tester.widget<Mirror>(mine).strength, greaterThan(0.2));

    await stage(tester, playing: true);
    expect(mine, findsNothing, reason: 'the record stands where the reflection was');
    // Only the one with a record out of it: the neighbours still have theirs.
    expect(find.byType(Mirror), findsWidgets);
  });
}
