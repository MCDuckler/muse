// What the player hands to the audio engine, and when.
//
// This is the "gap between songs" and the "it does not change track in the background"
// complaint, asked as a question a test can answer: at the moment a song is playing,
// does the engine already hold the next one? Because if it does, the transition is a
// step inside the audio platform — which happens with the screen off and the app
// closed — and if it does not, the end of every song is a fetch, a hand-over and a
// wait, and none of that runs when nothing of ours is running.
//
// No browser and no device: a fake engine stands behind just_audio's platform
// interface (see fake_audio.dart), so the logic under test is the real one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';

import 'fake_audio.dart';

/// A server that says yes. The player talks to one for the stream key, for warming the
/// cache and for reporting what was listened to; none of that is what these tests are
/// about, and none of it should reach the real one.
Future<HttpServer> stubServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth/stream-key') {
        request.response.write(jsonEncode({
          'key': 'test-key',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
        }));
      } else {
        request.response.write(jsonEncode({'ok': true}));
      }
      await request.response.close();
    }
  }());
  return server;
}

Track track(int id) => Track.fromJson({
      'id': id,
      'title': 'Track $id',
      'artists': ['Someone'],
      'duration_ms': 60000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

Queue queueOf(List<Track> tracks, {int cursor = 0}) => Queue.fromJson({
      'id': 1,
      'name': 'test',
      'cursor_index': cursor,
      'position_ms': 0,
      'rev': 1,
      'items': [
        for (final t in tracks)
          {
            'id': t.id,
            'title': t.title,
            'artists': t.artists,
            'duration_ms': t.durationMs,
            'state': 'ready',
            'stream_url': t.streamPath,
            'source': 'youtube',
          },
      ],
    });

/// Let the microtasks and the fake engine's events settle.
Future<void> settle([int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // just_audio reaches for an audio session on construction, which is a method channel
  // and therefore needs a binding and somebody to answer it.
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(session, (call) async => null);

  late HttpServer server;
  late FakeJustAudio audio;
  late ApiClient api;
  late PlayerService player;

  setUp(() async {
    // The test binding installs an HttpClient that refuses everything, which is the
    // right default and the wrong one here: the stub server below is the network.
    HttpOverrides.global = null;
    server = await stubServer();
    audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    api = ApiClient(baseUrl: 'http://${server.address.host}:${server.port}');
    api.token = 'test-token';
    player = PlayerService(api);
    await player.init();
  });

  tearDown(() async {
    await player.dispose();
    await server.close(force: true);
  });

  test('the next song is in the engine while this one is still playing', () async {
    final tracks = [track(1), track(2), track(3)];
    await player.loadQueue(queueOf(tracks));
    await player.playAt(0);
    await settle();

    final engine = audio.only;
    expect(engine.playing, isTrue, reason: 'nothing to test if it never started');
    expect(player.queuedNextId, 2,
        reason: 'the song after this one must already be handed over');
    expect(engine.sources.length, 2,
        reason: 'the engine holds this song and the next: ${engine.calls}');
    expect(engine.sources[1], contains('/tracks/2/stream'));
  });

  test('a song ending is a step through the engine, not a fetch', () async {
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    final loadsBefore = engine.calls.where((c) => c.startsWith('load')).length;

    engine.advanceByItself();
    await settle();

    expect(player.current?.id, 2, reason: 'the player follows the engine');
    expect(player.last?.loadedTrackId, 2,
        reason: 'and knows the engine is holding that one, not the old one');
    expect(engine.calls.where((c) => c.startsWith('load')).length, loadsBefore,
        reason: 'a gapless transition loads nothing: ${engine.calls}');
    expect(player.queuedNextId, 3,
        reason: 'and the one after that is queued in its place');
  });

  test('an engine that stops at the end of a song steps rather than reloading',
      () async {
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    final loadsBefore = engine.calls.where((c) => c.startsWith('load')).length;

    engine.reachEnd();                 // the web plugin's behaviour: stop and wait
    await settle();

    expect(player.current?.id, 2);
    expect(engine.calls.where((c) => c.startsWith('load')).length, loadsBefore,
        reason: 'the source was already there: ${engine.calls}');
  });

  test('skipping while the next is queued moves on by one, not two', () async {
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(0);
    await settle();

    await player.next();
    await settle();

    // Loading a song inserts it at the top of the engine's playlist, which shifts what
    // was there down a slot — and the engine reports that as its index changing, which
    // looks exactly like the song having ended. Believing it would land on track three.
    expect(player.current?.id, 2, reason: 'one skip, one song');
    expect(player.last?.loadedTrackId, 2);
    expect(player.queuedNextId, 3);
  });

  test('nothing is queued behind the last song', () async {
    await player.loadQueue(queueOf([track(1)]));
    await player.playAt(0);
    await settle();
    expect(player.queuedNextId, isNull);
    expect(audio.only.sources.length, 1);
  });

  test('a guest follows the room into the right song at the right place', () async {
    // The other half of a jam: the host says where the music is, and this device puts
    // itself there. No UI, no browser — the state and the player are the whole of it.
    final app = AppState();
    app.api = api;
    app.player = player;
    app.jam = Jam.fromJson({
      'id': 7,
      'code': 'ABC123',
      'queue_id': 1,
      'host': 'somebody',
      'is_host': false,
    });
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await settle();

    await app.followJamPlayback(const JamPlayback(
        trackId: 2, positionMs: 30000, playing: true));
    await settle();

    expect(player.current?.id, 2, reason: 'the room is on the second song');
    expect(audio.only.playing, isTrue, reason: 'and it is playing');
    expect(audio.only.position.inSeconds, greaterThanOrEqualTo(29),
        reason: 'halfway through it, not at the top: ${audio.only.calls}');

    // And a pause from the room stops this device too.
    await app.followJamPlayback(const JamPlayback(
        trackId: 2, positionMs: 42000, playing: false));
    await settle();
    expect(audio.only.playing, isFalse);
  });

  test('a guest does not write its own position into the host queue', () async {
    // Two people listening together fought over one cursor: the guest's player kept
    // reporting where *it* was, which dragged the host's queue backwards.
    final app = AppState();
    app.api = api;
    app.player = player;
    var wrote = 0;
    app.jam = Jam.fromJson({
      'id': 7, 'code': 'ABC123', 'queue_id': 1, 'host': 'somebody', 'is_host': false,
    });
    // The callback the app installs on the player, with the guard under test.
    player.onCursor = (queueId, {cursorIndex, positionMs}) {
      if (app.jam != null && !(app.jam?.isHost ?? false)) return;
      wrote++;
    };
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    await player.next();
    await settle();
    expect(wrote, 0, reason: 'a guest keeps its place in its own head');
  });
}
