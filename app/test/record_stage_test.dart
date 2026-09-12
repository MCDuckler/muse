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

  testWidgets('the record shows above the covers as far as its label',
      (tester) async {
    await stage(tester, playing: true);

    final platter = 400 - 40.0 * 2;
    final record = tester.getRect(_onTheDeck(platter).first);
    final cover = tester.getRect(_cover(352 * 0.74).first);
    // The right way up: what shows above the cover is the round top edge of the
    // record itself, and the cut is the far side of it, behind the cover.
    final showsFrom = record.top;

    expect(record.width, closeTo(platter, 0.5),
        reason: 'the record is the width of the screen, less its margins');
    expect(cover.top - showsFrom, closeTo(platter * 0.45, 2),
        reason: 'the label is in the open, at the default cover size');
    // The label is printed at 0.31 of the record's radius, so this is the top of it.
    final label = platter * 0.155;
    expect(cover.top - (record.center.dy - label), greaterThan(label * 0.5),
        reason: 'and a good part of the label itself is in the open, not just edge');
  });

  testWidgets('the same peek whatever size the covers are', (tester) async {
    // The sum is worth having only because it holds at both ends of the setting: a
    // fixed offset gave a sliver of record at one size and a floating cover at another.
    // Up to the size at which standing the cover low enough would put its own bottom
    // edge through the song's name — past that the clamp takes over and the peek is
    // allowed to give, which is checked separately below.
    for (final scale in [0.5, 0.6, 0.7, 0.74]) {
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

      final record = tester.getRect(_onTheDeck(400 - 40.0 * 2).first);
      final peek = tester.getRect(_cover(352 * scale).first).top - record.top;
      expect(peek, closeTo((400 - 80) * 0.45, 2), reason: 'at cover size $scale');
    }
  });

  testWidgets('a cover too big to stand that low keeps most of the peek anyway',
      (tester) async {
    // The clamp: a cover nearly as tall as the stage cannot come down far enough to
    // leave the whole of that record showing without its own bottom edge landing in
    // the song's name. What gives is the peek, and only as much as it has to.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              // Room enough for the biggest cover and its reflection, so what is
              // being measured is the clamp rather than a sleeve that has run out of
              // stage — which it does at this size whatever the record is doing.
              width: 352,
              height: 420,
              child: RecordStage(
                  track: song(2),
                  playing: true,
                  scale: 0.95,
                  previous: song(1),
                  next: song(3)),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 16));

    const platter = 400 - 40.0 * 2;
    final peek = tester.getRect(_cover(352 * 0.95).first).top -
        tester.getRect(_onTheDeck(platter).first).top;
    expect(peek, lessThan(platter * 0.45),
        reason: 'it gave something, because it had to');
    expect(peek, greaterThan(platter * 0.34),
        reason: 'and not much: the label is still in the open');
  });

  testWidgets('pausing stops the record turning and swings the arm off it',
      (tester) async {
    // What a pause used to do was put the record away — the whole disc slid back into
    // its sleeve and the arm went with it, so stopping the music emptied the stage.
    // A deck does not do that: the turntable stops, the arm swings to its rest, and
    // the record stays exactly where it is.
    const platter = 400 - 40.0 * 2;
    // The second one is the picture inside the rotation; the first is the box around
    // it, which does not turn.
    final turning = _onTheDeck(platter).at(1);

    await stage(tester, playing: true);
    final was = tester.getTopLeft(turning);
    await tester.pump(const Duration(milliseconds: 300));
    expect((tester.getTopLeft(turning) - was).distance, greaterThan(1),
        reason: 'it is turning while it plays');
    expect(tester.widget<Tonearm>(find.byType(Tonearm)).landed, greaterThan(0.98),
        reason: 'and the arm is down on it');

    await stage(tester, playing: false);
    expect(_onTheDeck(platter), findsWidgets,
        reason: 'the record is still on the deck');
    final held = tester.getTopLeft(turning);
    await tester.pump(const Duration(milliseconds: 300));
    expect((tester.getTopLeft(turning) - held).distance, lessThan(0.01),
        reason: 'stopped where it was, rather than slowing or carrying on');
    expect(tester.widget<Tonearm>(find.byType(Tonearm)).landed, lessThan(0.02),
        reason: 'and the arm has swung aside — still drawn, not gone');

    await stage(tester, playing: true);
    expect(tester.widget<Tonearm>(find.byType(Tonearm)).landed, greaterThan(0.98),
        reason: 'asking for it back puts the arm down again');
  });

  testWidgets('the record keeps clear of the reflections', (tester) async {
    // The reflection under a cover is the one thing on this stage that needs a layer
    // of its own, and it was turned off while the record lay across it. The record
    // hangs above the covers now, so the shine below them is nobody's business but
    // the cover's — as long as the record really does stay out of that band.
    await stage(tester, playing: true);

    final record = tester.getRect(_onTheDeck(400 - 40.0 * 2).first);
    final cover = tester.getRect(_cover(352 * 0.74).first);
    expect(record.top + record.height * 0.68, lessThan(cover.bottom),
        reason: 'the reflection hangs below the cover, and the record is cut above it');
    final mine = find.descendant(
        of: find.byKey(const ValueKey('2@0.0')), matching: find.byType(Mirror));
    expect(mine, findsOneWidget);
    expect(tester.widget<Mirror>(mine).strength, greaterThan(0.2));
  });
}
