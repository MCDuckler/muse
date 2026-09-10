// Music kept on the device: does it arrive, does it stay, and does the player use it?
//
// The last question is the one that matters. A download that is never read is a
// wasted gigabyte, and "it plays offline" is not something to find out on a plane.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/offline.dart';
import 'package:muse/src/state/player.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'fake_audio.dart';
import 'player_engine_test.dart' show queueOf, settle, track;

/// Somewhere to keep things that is not somebody's real music folder.
class _Somewhere extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Somewhere(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// A server with two songs on it.
Future<HttpServer> audioServer({Duration slow = Duration.zero}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      // Order matters: "/auth/stream-key" also contains "/stream".
      if (request.uri.path.startsWith('/tracks/') &&
          request.uri.path.endsWith('/stream')) {
        if (slow > Duration.zero) await Future<void>.delayed(slow);
        // Something file-shaped, big enough to arrive in more than one chunk.
        request.response.headers.contentType = ContentType('audio', 'mp4');
        request.response.add(List<int>.filled(200 * 1024, 7));
      } else if (request.uri.path.contains('/cover')) {
        request.response.add(List<int>.filled(64, 9));
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'key': 'test-key',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
        }));
      }
      await request.response.close();
    }
  }());
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(session, (call) async => null);

  late Directory home;
  late HttpServer server;
  late ApiClient api;
  late OfflineStore offline;

  setUp(() async {
    HttpOverrides.global = null;
    home = await Directory.systemTemp.createTemp('muse-offline-');
    PathProviderPlatform.instance = _Somewhere(home.path);
    server = await audioServer();
    api = ApiClient(baseUrl: 'http://${server.address.host}:${server.port}');
    api.token = 'test-token';
    offline = OfflineStore(api);
    await offline.init();
  });

  tearDown(() async {
    // Let any download still running finish before the ground is taken away, or the
    // failure lands on whichever test runs next.
    for (var i = 0; i < 200; i++) {
      if (offline.downloading == null && offline.waiting == 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await server.close(force: true);
    if (home.existsSync()) await home.delete(recursive: true);
  });

  /// Wait for the queue of downloads to run dry.
  Future<void> finished() async {
    for (var i = 0; i < 200; i++) {
      if (offline.downloading == null && offline.waiting == 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('the download never finished');
  }

  test('a song that is kept is on the device and stays there', () async {
    expect(offline.has(1), isFalse);

    await offline.keep([track(1)]);
    await finished();

    expect(offline.has(1), isTrue, reason: '${offline.lastError}');
    expect(offline.count, 1);
    expect(offline.bytes, greaterThan(100 * 1024));
    final path = offline.pathFor(1);
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);

    // And a second store — the app being opened again — finds it without asking the
    // server anything.
    final later = OfflineStore(api);
    await later.init();
    expect(later.has(1), isTrue, reason: 'the list of what is kept is written down');
    expect(later.kept.first.title, 'Track 1');
  });

  test('what is kept is played from the device, not fetched again', () async {
    final audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    final player = PlayerService(api);
    await player.init();
    player.offlinePath = offline.pathFor;

    await offline.keep([track(1)]);
    await finished();

    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();

    expect(audio.only.sources.first, startsWith('file://'),
        reason: 'the engine was handed the file on the device: '
            '${audio.only.sources}');
    expect(audio.only.sources.first, contains('track-1'));

    // The one that is not kept still comes from the server.
    await player.next();
    await settle();
    expect(audio.only.sources.first, startsWith('http'),
        reason: 'nothing was kept for that one: ${audio.only.sources}');
    await player.dispose();
  });

  test('keeping the same song twice does not fetch it twice', () async {
    await offline.keep([track(1)]);
    await finished();
    final first = File(offline.pathFor(1)!).statSync().modified;

    await offline.keep([track(1)]);
    await finished();
    expect(File(offline.pathFor(1)!).statSync().modified, first);
    expect(offline.count, 1);
  });

  test('forgetting one takes the file with it', () async {
    await offline.keep([track(1), track(2)]);
    await finished();
    expect(offline.count, 2);
    final path = offline.pathFor(1)!;

    await offline.forget(1);

    expect(offline.has(1), isFalse);
    expect(File(path).existsSync(), isFalse, reason: 'the space is actually freed');
    expect(offline.has(2), isTrue, reason: 'and only that one');
  });

  test('a file deleted from underneath is not claimed as kept', () async {
    await offline.keep([track(1)]);
    await finished();
    await File(offline.pathFor(1)!).delete();

    final later = OfflineStore(api);
    await later.init();
    expect(later.has(1), isFalse,
        reason: 'the index is a record of files, not a promise about them');
  });

  test('a queue of downloads reports what it is doing', () async {
    await server.close(force: true);
    server = await audioServer(slow: const Duration(milliseconds: 120));
    api.baseUrl = 'http://${server.address.host}:${server.port}';

    unawaited(offline.keep([track(1), track(2), track(3)]));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(offline.downloading, isNotNull, reason: 'one of them is being fetched');
    expect(offline.waiting, greaterThan(0), reason: 'and the rest are waiting');

    offline.stopWaiting();
    await finished();
    expect(offline.count, 1, reason: 'stopping leaves what was already finished');
  });

  test('everything can be given back at once', () async {
    await offline.keep([track(1), track(2)]);
    await finished();
    await offline.forgetAll();
    expect(offline.count, 0);
    expect(offline.bytes, 0);
    expect(home.listSync().whereType<File>().where(
        (f) => f.path.contains('track-')).isEmpty, isTrue);
  });
}
