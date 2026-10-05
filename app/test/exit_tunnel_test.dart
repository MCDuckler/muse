// The phone's half of the door to YouTube (worker/exit_tunnel.dart), against a pretend
// house: a WebSocket server speaking the frames server/muse/exits.py speaks, and a
// pretend YouTube on a local port.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/exit_tunnel.dart';

class _House {
  late final HttpServer server;
  final heard = <Uint8List>[];
  WebSocket? ws;
  String? auth;
  int doors = 0;

  static Future<_House> start() async {
    final h = _House();
    h.server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    h.server.listen((req) async {
      h.auth = req.headers.value('authorization');
      final ws = await WebSocketTransformer.upgrade(req);
      h.doors += 1;
      h.ws = ws;
      ws.listen((m) => h.heard.add(m as Uint8List));
    });
    return h;
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${server.port}/internal/exit');

  void send(int kind, int sid, [List<int> payload = const []]) =>
      ws!.add(exitFrame(kind, sid, payload));

  void open(int sid, String host, int port) {
    final p = Uint8List(2);
    ByteData.sublistView(p).setUint16(0, port);
    send(ExitFrame.open, sid, [...p, ...utf8.encode(host)]);
  }

  Iterable<(int, int, Uint8List)> get frames => heard.map((b) {
        final d = ByteData.sublistView(b);
        return (d.getUint8(0), d.getUint32(1), Uint8List.sublistView(b, 5));
      });

  Future<(int, int, Uint8List)> next(bool Function(int kind, int sid) want,
      {int after = 0}) async {
    for (var i = 0; i < 300; i++) {
      final hit = frames.skip(after).where((f) => want(f.$1, f.$2));
      if (hit.isNotEmpty) return hit.first;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('never heard it');
  }

  int dataFor(int sid) => frames
      .where((f) => f.$1 == ExitFrame.data && f.$2 == sid)
      .fold(0, (n, f) => n + f.$3.length);

  Future<void> close() async {
    await ws?.close();
    await server.close(force: true);
  }
}

/// Stands in for YouTube: "GET n" answers n bytes.
Future<ServerSocket> _youtube() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    final got = <int>[];
    c.listen((b) {
      got.addAll(b);
      final at = got.indexOf(10);
      if (at < 0) return;
      final n = int.parse(utf8.decode(got.sublist(0, at)).split(' ')[1]);
      c.add(List.generate(n, (i) => i % 251));
      c.close();
    });
  });
  return s;
}

Uint8List _u32(int n) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, n);
  return b;
}

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 300 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue);
}

void main() {
  late _House house;
  late ServerSocket youtube;
  late ExitTunnel tunnel;
  late List<String> reached;

  setUp(() async {
    house = await _House.start();
    youtube = await _youtube();
    reached = [];
    tunnel = ExitTunnel(
      url: () => house.url,
      token: () => 'tok',
      hello: () => {'network': 'wifi', 'mobile_data': true, 'platform': 'android'},
      connect: (host, port) {
        reached.add('$host:$port');
        return Socket.connect(InternetAddress.loopbackIPv4, youtube.port);
      },
    );
  });

  tearDown(() async {
    await tunnel.stop();
    await house.close();
    await youtube.close();
  });

  test('only YouTube, only on 443, only by name', () {
    expect(exitMayReach('www.youtube.com', 443), isTrue);
    expect(exitMayReach('rr3---sn-4g5ednsl.googlevideo.com', 443), isTrue);
    expect(exitMayReach('youtubei.googleapis.com', 443), isTrue);
    expect(exitMayReach('i.ytimg.com', 443), isTrue);
    expect(exitMayReach('www.youtube.com', 80), isFalse);
    expect(exitMayReach('example.com', 443), isFalse);
    expect(exitMayReach('notyoutube.com', 443), isFalse);
    expect(exitMayReach('youtube.com.example.com', 443), isFalse);
    expect(exitMayReach('142.250.1.1', 443), isFalse);
    expect(exitMayReach('[::1]', 443), isFalse);
    expect(exitMayReach('googleapis.com', 443), isFalse, reason: 'only the one API');
  });

  test('the door is the same server, over a WebSocket', () {
    expect(exitUrlFor('https://89-58-49-140.nip.io').toString(),
        'wss://89-58-49-140.nip.io/internal/exit');
    expect(exitUrlFor('http://127.0.0.1:8770/').toString(),
        'ws://127.0.0.1:8770/internal/exit');
  });

  test('opens with the token and says what this phone is like', () async {
    await tunnel.start();
    final hello = await house.next((k, s) => k == ExitFrame.hello && s == 0);
    expect(house.auth, 'Bearer tok');
    expect(jsonDecode(utf8.decode(hello.$3)),
        {'network': 'wifi', 'mobile_data': true, 'platform': 'android'});
    expect(tunnel.state, ExitState.open);
  });

  test('a song comes down a window at a time, and no faster than the house takes it',
      () async {
    await tunnel.start();
    await house.next((k, s) => k == ExitFrame.hello);
    house.open(7, 'www.youtube.com', 443);
    await house.next((k, s) => k == ExitFrame.opened && s == 7);
    expect(reached, ['www.youtube.com:443']);

    house.send(ExitFrame.data, 7, utf8.encode('GET 1000000\n'));
    // The house's bytes were written and acknowledged.
    final credit = await house.next((k, s) => k == ExitFrame.credit && s == 7);
    expect(ByteData.sublistView(credit.$3).getUint32(0), 12);

    // Nothing acknowledged yet: it stops at the window.
    await _until(() => house.dataFor(7) >= exitWindow);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(house.dataFor(7), lessThanOrEqualTo(exitWindow + 65536));

    // Acknowledged as it comes, and all of it arrives, then the door says it is done.
    var acked = 0;
    for (var i = 0; i < 300 && house.dataFor(7) < 1000000; i++) {
      final have = house.dataFor(7);
      if (have > acked) {
        house.send(ExitFrame.credit, 7, _u32(have - acked));
        acked = have;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(house.dataFor(7), 1000000);
    final all = house.frames
        .where((f) => f.$1 == ExitFrame.data && f.$2 == 7)
        .expand((f) => f.$3)
        .toList();
    expect(all, List.generate(1000000, (i) => i % 251));
    house.send(ExitFrame.credit, 7, _u32(house.dataFor(7) - acked));
    await house.next((k, s) => k == ExitFrame.close && s == 7);
    await _until(() => tunnel.streams == 0);
  });

  test('anywhere else is refused, and never even dialled', () async {
    await tunnel.start();
    await house.next((k, s) => k == ExitFrame.hello);
    house.open(1, 'example.com', 443);
    house.open(2, 'www.youtube.com', 80);
    house.open(3, '142.250.1.1', 443);
    for (final sid in [1, 2, 3]) {
      await house.next((k, s) => k == ExitFrame.refused && s == sid);
    }
    expect(reached, isEmpty);
  });

  test('no more connections at once than it said', () async {
    tunnel = ExitTunnel(
      url: () => house.url,
      token: () => 'tok',
      hello: () => {},
      maxStreams: 1,
      connect: (h, p) => Socket.connect(InternetAddress.loopbackIPv4, youtube.port),
    );
    await tunnel.start();
    await house.next((k, s) => k == ExitFrame.hello);
    house.open(1, 'www.youtube.com', 443);
    await house.next((k, s) => k == ExitFrame.opened && s == 1);
    house.open(2, 'www.youtube.com', 443);
    await house.next((k, s) => k == ExitFrame.refused && s == 2);
  });

  test('turned away by the house: stops asking', () async {
    await tunnel.start();
    await house.next((k, s) => k == ExitFrame.hello);
    house.send(ExitFrame.hello, 0,
        utf8.encode(jsonEncode({'ok': false, 'why': 'an admin has kept this device out'})));
    await house.ws!.close(4403);
    await _until(() => tunnel.state == ExitState.refused);
    expect(tunnel.problem, contains('admin'));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(house.doors, 1, reason: 'did not knock again');
  });

  test('a door that drops opens again by itself', () async {
    await tunnel.start();
    await house.next((k, s) => k == ExitFrame.hello);
    house.open(1, 'www.youtube.com', 443);
    await house.next((k, s) => k == ExitFrame.opened && s == 1);
    await house.ws!.close(1011);
    await _until(() => tunnel.state == ExitState.waiting);
    expect(tunnel.streams, 0, reason: 'what was open through it is shut');
    await _until(() => house.doors == 2 && tunnel.state == ExitState.open);
  });

  test('stop shuts it and keeps it shut', () async {
    await tunnel.start();
    await house.next((k, s) => k == ExitFrame.hello);
    await tunnel.stop();
    expect(tunnel.state, ExitState.off);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(house.doors, 1);
  });
}
