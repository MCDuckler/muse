// Moving the music between this account's devices.
//
// Two copies of the app, one account: the half that matters is the half receiving —
// what a device does when another one hands it the music, and what the transport does
// on a screen whose music is coming out of something in the next room.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';

import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/devices_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<({String path, Map<String, dynamic> body})> sent;

  Map<String, dynamic> device(int id, String name,
          {bool playing = false, bool live = true, int at = 0}) =>
      {
        'id': id,
        'name': name,
        'kind': 'phone',
        'this': id == 1,
        'live': live,
        'playing': playing,
        'position_ms': at,
        'queue': 'Evening',
        'queue_id': 9,
        'track': playing
            ? {
                'id': 77,
                'title': 'A song',
                'artists': ['Somebody'],
                'state': 'ready',
                'source': 'youtube',
              }
            : null,
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = [];
    useThisClientInstead(MockClient((request) async {
      final body = request.body.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(request.body) as Map).cast<String, dynamic>();
      sent.add((path: request.url.path, body: body));
      if (request.url.path == '/devices') {
        return http.Response(
            jsonEncode({
              'this': 1,
              'devices': [
                device(1, 'This phone'),
                device(2, 'The desk', playing: true, at: 61000),
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  test('the devices of this account, and which one you are holding', () async {
    await app.refreshDevices();
    expect(app.thisDevice, 1);
    expect(app.devices.map((d) => d.name), ['This phone', 'The desk']);
    expect(app.devices[1].playing, isTrue);
    expect(app.devices[1].track?.title, 'A song');
    expect(app.controllingAnother, isFalse, reason: 'nothing has been picked yet');
  });

  test('handing the music to another device asks it, and quiets this one', () async {
    await app.refreshDevices();
    await app.playOn(app.devices[1]);

    final order = sent.firstWhere((r) => r.path == '/devices/2/command');
    expect(order.body['action'], 'take');
    expect(app.playingOn, 2);
    expect(app.controllingAnother, isTrue);
    expect(app.elsewhere?.name, 'The desk');
  });

  test('then the transport is a remote control', () async {
    await app.refreshDevices();
    await app.playOn(app.devices[1]);
    sent.clear();

    await app.skipNext();
    await app.seekTo(const Duration(seconds: 30));

    final orders = sent.where((r) => r.path == '/devices/2/command').toList();
    expect(orders.map((o) => o.body['action']), containsAll(['next', 'seek']));
    expect(orders.last.body['position_ms'], 30000);
  });

  test('being told to yield is a device letting go of the music', () async {
    await app.refreshDevices();
    await app.obey({'action': 'yield', 'except': 2});
    expect(app.playingOn, 2, reason: 'the desk has it now, and this screen says so');
  });

  test('a device is not made to yield to itself', () async {
    await app.refreshDevices();
    app.playingOn = 2;
    await app.obey({'action': 'yield', 'except': 1});
    expect(app.playingOn, 2,
        reason: 'this device is the exception, so nothing about it changes');
  });

  test('an order for somebody else is not obeyed', () async {
    await app.refreshDevices();
    sent.clear();
    await app.obey({'to': 2, 'action': 'pause'});
    expect(sent.where((r) => r.path == '/devices/state'), isEmpty,
        reason: 'nothing happened here, so there is nothing to report');
  });

  testWidgets('the button says where the music is, and opens the list',
      (tester) async {
    // A live PlayerService cannot be pumped in a widget test — it hangs the binding —
    // so what is checked here is the button itself: that it names the device with the
    // music rather than only offering to change it, which is the question somebody is
    // asking when they go looking for it. Which arrangements of the player carry the
    // button is now a matter of one place in the app bar rather than four rows.
    await app.refreshDevices();
    await app.playOn(app.devices[1]);

    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: WhereItPlays())),
      ),
    ));
    await tester.pump();

    expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        'Playing on The desk',
        reason: 'the answer to "why is nothing coming out of this laptop"');

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.text('Where it plays'), findsOneWidget);
    expect(find.text('The desk'), findsWidgets);
  });

  test('a device that stops answering is not where the music is', () async {
    await app.refreshDevices();
    app.playingOn = 2;
    useThisClientInstead(MockClient((request) async => http.Response(
        jsonEncode({
          'this': 1,
          'devices': [device(1, 'This phone'), device(2, 'The desk', live: false)],
        }),
        200,
        headers: {'content-type': 'application/json'})));

    await app.refreshDevices();
    expect(app.controllingAnother, isFalse);
    expect(app.playingOn, isNull, reason: 'the desk went quiet; this is here again');
  });
}
