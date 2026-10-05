// A song this phone fetches itself on the server's word (worker/door_pull.dart): kept
// on the disk and played from there, handed in to the house, and when YouTube says no,
// the server told so — and nowhere but YouTube is ever fetched from.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse/src/worker/door_pull.dart';

/// Stands in for googlevideo, over plain HTTP on a loopback port: [song] whole, or the
/// piece a `range=a-b` asks for; [status] instead when set.
class _YouTube {
  late final HttpServer server;
  Uint8List song = Uint8List(0);
  int? status;

  /// Answer whatever there is, however much more was asked for.
  bool short = false;
  final asked = <Uri>[];
  final headers = <HttpHeaders>[];

  static Future<_YouTube> start() async {
    final y = _YouTube();
    y.server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    y.server.listen((req) async {
      y.asked.add(req.uri);
      y.headers.add(req.headers);
      if (y.status != null) {
        req.response.statusCode = y.status!;
      } else {
        final range = req.uri.queryParameters['range'];
        if (range == null) {
          req.response.add(y.song);
        } else {
          final [from, to] = range.split('-').map(int.parse).toList();
          final end = y.short ? y.song.length : to + 1;
          req.response.add(y.song.sublist(from.clamp(0, y.song.length), end.clamp(0, y.song.length)));
        }
      }
      await req.response.close();
    });
    return y;
  }

  /// A client that believes it is talking to YouTube over TLS and is talking to this.
  HttpClient client() => HttpClient()
    ..connectionFactory =
        (uri, host, port) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
}

void main() {
  late _YouTube youtube;
  late Directory dir;
  late List<http.BaseRequest> house;
  late List<String> houseBodies;
  late int houseAnswer;
  late List<(int, String)> arrived;

  DoorPuller puller() => DoorPuller(
        baseUrl: () => 'https://house.test',
        token: () => 'tok',
        keepDir: () async => dir,
        onArrived: (t, p) => arrived.add((t, p)),
        youtube: youtube.client,
        client: MockClient.streaming((req, body) async {
          house.add(req);
          houseBodies.add(utf8.decode(await body.toBytes(), allowMalformed: true));
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), houseAnswer);
        }),
      );

  PullOrder order({String host = 'rr1---sn-test.googlevideo.com', int? bytes, int? chunk}) =>
      PullOrder.fromJson({
        'job': 41,
        'track': 7,
        'url': 'https://$host/videoplayback?ip=192.0.2.7&itag=140',
        'headers': {'User-Agent': 'Mozilla/5.0 test', 'Accept-Encoding': 'gzip'},
        'bytes': bytes,
        'chunk': chunk,
      })!;

  setUp(() async {
    youtube = await _YouTube.start();
    dir = Directory.systemTemp.createTempSync('door-pull-');
    house = [];
    houseBodies = [];
    houseAnswer = 200;
    arrived = [];
  });

  tearDown(() async {
    await youtube.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('fetched, kept, played from here, and handed in', () async {
    youtube.song = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    final p = puller();
    await p.pull(order(bytes: 5000));
    expect(youtube.headers.single.value('user-agent'), 'Mozilla/5.0 test',
        reason: 'asked the way yt-dlp would have');
    expect(youtube.asked.single.queryParameters['range'], '0-4999',
        reason: 'by range even in one piece: asked for whole, YouTube sends it slowly');
    expect(arrived.single.$1, 7);
    expect(File(arrived.single.$2).readAsBytesSync(), youtube.song,
        reason: 'not in pieces, so kept as it came');
    expect(p.kept[7], arrived.single.$2);
    final up = house.single;
    expect(up.url.path, '/internal/exit/jobs/41/audio');
    expect(up.headers['Authorization'], 'Bearer tok');
    expect(houseBodies.single, contains('"bytes":5000'));
    expect(p.pulled, 1);
  });

  test('a big song is asked for a piece at a time', () async {
    youtube.song = Uint8List.fromList(List.generate(10000, (i) => (i * 7) % 256));
    await puller().pull(order(bytes: 10000, chunk: 4096));
    expect(youtube.asked.map((u) => u.queryParameters['range']),
        ['0-4095', '4096-8191', '8192-9999']);
    expect(File(arrived.single.$2).readAsBytesSync(), youtube.song);
  });

  test('YouTube says no: the house is told, nothing is kept or handed in', () async {
    youtube.status = 403;
    final p = puller();
    await p.pull(order());
    expect(arrived, isEmpty);
    expect(house.single.url.path, '/internal/exit/jobs/41/failed');
    expect(jsonDecode(houseBodies.single)['why'], contains('403'));
    expect(p.failed, 1);
  });

  test('half a song is not a song', () async {
    youtube.song = Uint8List(100);
    youtube.short = true;
    await puller().pull(order(bytes: 5000));
    expect(arrived, isEmpty);
    expect(house.single.url.path, endsWith('/failed'));
  });

  test('nowhere but YouTube, whatever the server says', () async {
    await puller().pull(order(host: 'example.com'));
    expect(youtube.asked, isEmpty, reason: 'never even asked');
    expect(house.single.url.path, endsWith('/failed'));
  });

  test('a song of unknown size is asked for until a piece comes back short', () async {
    youtube.song = Uint8List.fromList(List.generate(9000, (i) => i % 256));
    await puller().pull(order(chunk: 4096));
    expect(youtube.asked.map((u) => u.queryParameters['range']),
        ['0-4095', '4096-8191', '8192-12287']);
    expect(File(arrived.single.$2).readAsBytesSync(), youtube.song);
  });

  test('a house that says it has it already is not asked again', () async {
    youtube.song = Uint8List(64);
    houseAnswer = 409;
    await puller().pull(order(bytes: 64));
    expect(house, hasLength(1));
    expect(arrived, hasLength(1), reason: 'and it still plays from here');
  });

  test('an order that is not one is not followed', () {
    expect(PullOrder.fromJson({'job': 'one'}), isNull);
    expect(PullOrder.fromJson('nonsense'), isNull);
  });

  test('old songs are tidied off the disk', () async {
    final old = File('${dir.path}/1.m4a')..writeAsBytesSync([1]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    final fresh = File('${dir.path}/2.m4a')..writeAsBytesSync([2]);
    await DoorPuller.tidy(dir);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });
}
