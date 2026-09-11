// One connection, reused — rather than a handshake per request.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
}
