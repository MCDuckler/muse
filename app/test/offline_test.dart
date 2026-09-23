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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
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
    SharedPreferences.setMockInitialValues({});
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
    // And a cover fetched alongside a song can still be landing after the song
    // itself is done, which made a delete fail with "directory not empty" and
    // failed a test that had already passed. Try a few times, then leave it: this is
    // a temporary directory, and tidying up is not what any of this is testing.
    for (var i = 0; i < 20 && home.existsSync(); i++) {
      try {
        await home.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
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
    expect(audio.only.sources.first, contains('Track%201'),
        reason: 'filed by its name, in its artist\'s folder');

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
    expect(home.listSync(recursive: true).whereType<File>().where(
        (f) => f.path.endsWith('.m4a')).isEmpty, isTrue);
  });

  group('filed like a library', () {
    Track song(int id, {String? album, String title = 'A Song', String artist = 'Some Band'}) =>
        Track.fromJson({
          'id': id,
          'title': title,
          'artists': [artist],
          if (album != null) 'album': album,
          'state': 'ready',
          'stream_url': '/tracks/$id/stream',
          'cover_url': '/tracks/$id/cover',
          'source': 'youtube',
        });

    test('a song goes in its artist\'s folder, in its record\'s folder', () async {
      await offline.keep([song(1, album: 'The Record')]);
      await finished();
      final path = offline.pathFor(1)!;
      expect(path, endsWith('/Some Band/The Record/A Song.m4a'),
          reason: 'the shape every other player expects: ${offline.lastError}');
      expect(File('${offline.home}/Some Band/The Record/cover.jpg').existsSync(), isTrue,
          reason: 'the picture, once, named the way players look for it');
    });

    test('a song from no record sits in the artist\'s folder', () async {
      await offline.keep([song(2)]);
      await finished();
      expect(offline.pathFor(2), endsWith('/Some Band/A Song.m4a'));
    });

    test('names a filesystem would refuse are made safe', () {
      expect(OfflineStore.safeName('AC/DC'), 'ACDC');
      expect(OfflineStore.safeName('What? "Yes": <no>|'), 'What Yes no');
      expect(OfflineStore.safeName('Trailing dots...'), 'Trailing dots');
      expect(OfflineStore.safeName('   '), 'Unknown');
      expect(OfflineStore.safeName('CON'), '_CON');
    });

    test('two songs of one name on one record both keep their names', () async {
      await offline.keep([
        song(3, album: 'Live', title: 'Encore'),
        song(4, album: 'Live', title: 'Encore'),
      ]);
      await finished();
      expect(offline.pathFor(3), endsWith('/Live/Encore.m4a'));
      expect(offline.pathFor(4), endsWith('/Live/Encore (4).m4a'));
      // And the record's one picture stays until the last song from it goes.
      final cover = File('${offline.home}/Some Band/Live/cover.jpg');
      await offline.forget(3);
      expect(cover.existsSync(), isTrue);
      await offline.forget(4);
      expect(cover.existsSync(), isFalse);
      expect(Directory('${offline.home}/Some Band').existsSync(), isFalse,
          reason: 'empty folders go with the last song');
    });

    test('moving the folder takes the library with it, and a later start finds it',
        () async {
      await offline.keep([song(5, album: 'The Record'), song(6)]);
      await finished();
      final elsewhere = await Directory.systemTemp.createTemp('muse-elsewhere-');
      addTearDown(() => elsewhere.delete(recursive: true));

      await offline.moveTo(elsewhere.path);
      expect(offline.lastError, isNull);
      expect(offline.home, elsewhere.path);
      expect(offline.pathFor(5), '${elsewhere.path}/Some Band/The Record/A Song.m4a');
      expect(File('${elsewhere.path}/Some Band/The Record/cover.jpg').existsSync(), isTrue);
      expect(File('${home.path}/offline/Some Band/A Song.m4a').existsSync(), isFalse,
          reason: 'moved, not copied');

      final later = OfflineStore(api);
      await later.init();
      expect(later.home, elsewhere.path, reason: 'the choice is remembered');
      expect(later.has(5), isTrue);
      expect(later.has(6), isTrue);

      await later.moveTo(null);
      expect(later.home, '${home.path}/offline', reason: 'and can be undone');
      expect(later.pathFor(6), endsWith('/offline/Some Band/A Song.m4a'));
    });
  });

  group('with no connection at all', () {
    /// The server, gone: every request fails the way a phone in a tunnel fails.
    void noSignal() => useThisClientInstead(watching(
        MockClient((_) async => throw const SocketException('no route to host'))));

    tearDown(() {
      useThisClientInstead(http.Client());
      serverIsThere.value = true;
    });

    test('a kept song plays without asking the server for anything', () async {
      // It used to ask for a stream key first, like any other song, and that request
      // failing took the play with it: music kept for the flight did not play on it.
      await offline.keep([track(1)]);
      await finished();

      noSignal();
      final audio = FakeJustAudio();
      JustAudioPlatform.instance = audio;
      final away = ApiClient(baseUrl: 'http://nowhere.invalid')..token = 'test-token';
      final player = PlayerService(away);
      await player.init();
      player.offlinePath = offline.pathFor;

      await player.loadQueue(queueOf([track(1)]));
      await player.playAt(0);
      await settle();

      expect(player.lastError, isNull);
      expect(audio.only.sources.first, startsWith('file://'));
      await player.dispose();
    });

    test('the app starts, signed in, with what is on the device', () async {
      // Nothing caught a start with no connection: the app sat on its loading screen
      // for ever, with a phone full of kept music behind it.
      await offline.keep([track(1)]);
      await finished();

      noSignal();
      JustAudioPlatform.instance = FakeJustAudio();
      SharedPreferences.setMockInitialValues({
        'muse.token': 'test-token',
        'muse.server': 'http://nowhere.invalid',
        'muse.user': 'chris',
        'muse.userId': 1,
      });
      final app = AppState();
      await app.boot();

      expect(app.ready, isTrue, reason: 'a start with no connection is still a start');
      expect(app.user, 'chris', reason: 'the same person, as far as anybody knows');
      expect(app.offlineSession, isTrue);
      expect(serverIsThere.value, isFalse, reason: 'and the app knows it is on its own');
      expect(app.offline.has(1), isTrue, reason: 'it found what is kept here');

      // Playing a list from here plays what of it is on the device, as a queue the
      // server has never heard of.
      final audio = FakeJustAudio();
      JustAudioPlatform.instance = audio;
      await app.playNow([track(1), track(2)], named: 'On this device');
      await settle();
      expect(app.activeQueue!.id, lessThan(0));
      expect([for (final t in app.activeQueue!.items) t.id], [1],
          reason: 'only the one that is kept');

      // And a list with nothing kept in it says so rather than spinning.
      await expectLater(app.playNow([track(2)]), throwsA(isA<ApiException>()));
      await app.player?.dispose();
    });
  });
}
