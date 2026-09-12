// Where the record sits against the covers.
//
// The record is drawn behind the sleeves and hangs above them, and how much of it
// shows over their top edge is the whole point. Two things that both move decide it —
// the record is the width of the screen, the cover is whatever size somebody set it
// to — so the offset between them is worked out rather than picked, and this is the
// sum being checked.
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

  testWidgets('a quarter of the record shows above the covers', (tester) async {
    await stage(tester, playing: true);

    final platter = 400 - 26.0 * 2;
    final record = tester.getRect(_onTheDeck(platter).first);
    final cover = tester.getRect(_cover(352 * 0.74).first);
    // Upside down: the record is drawn from a little above its middle to its bottom,
    // so the topmost pixel of it is the fade rather than the edge of the picture.
    final showsFrom = record.top + record.height * 0.48;

    expect(record.width, closeTo(platter, 0.5),
        reason: 'the record is the width of the screen, less its margins');
    expect(cover.top - showsFrom, closeTo(platter * 0.26, 2),
        reason: 'a quarter of it in the open, at the default cover size');
    expect(showsFrom, greaterThan(tester.getRect(find.byType(RecordStage)).top - 1),
        reason: 'and not a pixel of it over the buttons above the stage');
  });

  testWidgets('the same quarter whatever size the covers are', (tester) async {
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
      final peek = tester.getRect(_cover(352 * scale).first).top -
          (record.top + record.height * 0.48);
      expect(peek, closeTo((400 - 52) * 0.26, 2), reason: 'at cover size $scale');
    }
  });

  testWidgets('the record keeps clear of the reflections', (tester) async {
    // The reflection under a cover is the one thing on this stage that needs a layer
    // of its own, and it was turned off while the record lay across it. The record
    // hangs above the covers now, so the shine below them is nobody's business but
    // the cover's — as long as the record really does stay out of that band.
    await stage(tester, playing: true);

    final record = tester.getRect(_onTheDeck(400 - 26.0 * 2).first);
    final cover = tester.getRect(_cover(352 * 0.74).first);
    expect(record.bottom, lessThan(cover.bottom),
        reason: 'the reflection hangs below the cover, and the record ends above it');
    final mine = find.descendant(
        of: find.byKey(const ValueKey('2@0.0')), matching: find.byType(Mirror));
    expect(mine, findsOneWidget);
    expect(tester.widget<Mirror>(mine).strength, greaterThan(0.2));
  });
}
