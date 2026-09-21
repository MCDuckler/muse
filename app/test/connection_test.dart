// One connection, reused — rather than a handshake per request.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse/src/api/connection.dart';

void main() {
  test('the shared client keeps its connection open between requests', () async {
    final sockets = <String>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      // Each accepted socket has its own remote port; counting them counts
      // connections, which is what a handshake costs.
      sockets.add('${req.connectionInfo?.remotePort}');
      req.response
        ..write('ok')
        ..close();
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}/thing');

    for (var i = 0; i < 8; i++) {
      expect((await net.get(url)).body, 'ok');
    }
    expect(sockets.length, 1,
        reason: 'eight requests down one socket, not eight handshakes');

    // What it used to do, for contrast: the top-level helpers open and close one
    // client per call.
    sockets.clear();
    for (var i = 0; i < 4; i++) {
      await http.get(url);
    }
    expect(sockets.length, 4);

    await server.close(force: true);
  });

  group('knowing whether the box is there', () {
    setUp(() => serverIsThere.value = true);
    tearDown(() {
      useThisClientInstead(http.Client());
      serverIsThere.value = true;
    });

    test('a request that never arrives says the server is gone', () async {
      useThisClientInstead(watching(MockClient(
          (_) async => throw const SocketException('no route to host'))));
      await expectLater(net.get(Uri.parse('http://box/me')), throwsA(anything));
      expect(serverIsThere.value, isFalse);
    });

    test('an answer of any kind says it is back', () async {
      useThisClientInstead(watching(MockClient(
          (_) async => throw const SocketException('no route to host'))));
      await expectLater(net.get(Uri.parse('http://box/me')), throwsA(anything));

      useThisClientInstead(watching(MockClient((_) async => http.Response('{}', 200))));
      await net.get(Uri.parse('http://box/me'));
      expect(serverIsThere.value, isTrue);
    });

    test('the server having an opinion is not the server being away', () async {
      // A 500 is the box answering badly, which is a different problem and one the
      // caller already reports in its own words.
      useThisClientInstead(
          watching(MockClient((_) async => http.Response('boom', 500))));
      await net.get(Uri.parse('http://box/me'));
      expect(serverIsThere.value, isTrue);
    });
  });
}
