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

/// How long the stub server takes to answer. A load that is still in flight is where
/// the interesting races live, and instant answers hide them.
Duration stubDelay = Duration.zero;

/// A server that says yes. The player talks to one for the stream key, for warming the
/// cache and for reporting what was listened to; none of that is what these tests are
/// about, and none of it should reach the real one.
Future<HttpServer> stubServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      if (stubDelay > Duration.zero) await Future<void>.delayed(stubDelay);
      request.response.headers.contentType = ContentType.json;
      final path = request.uri.path;
      if (path == '/auth/stream-key') {
        request.response.write(jsonEncode({
          'key': 'test-key',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
        }));
      } else if (path == '/queues' && request.method == 'GET') {
        // One queue of this person's own, which is what somebody leaving a jam is
        // handed back to.
        request.response.write(jsonEncode([
          {'id': 99, 'name': 'Mine', 'cursor_index': 0, 'position_ms': 0,
           'rev': 1, 'items': 0},
        ]));
      } else if (path.startsWith('/queues/') && request.method == 'GET') {
        request.response.write(jsonEncode({
          'id': int.tryParse(path.split('/')[2]) ?? 99,
          'name': 'Mine', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
          'items': <dynamic>[],
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
    PlayerService.stallAfter = const Duration(seconds: 12);
    // The test binding installs an HttpClient that refuses everything, which is the
    // right default and the wrong one here: the stub server below is the network.
    HttpOverrides.global = null;
    stubDelay = Duration.zero;
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

  test('a skip is not undone by the queue update it causes', () async {
    // The echo has to land *during* the load — after the skip, while the engine is
    // still holding the previous track — because that is the only window in which the
    // question "which song is this device on" has two answers.
    // Skipping writes the cursor, the server tells every device, and the device that
    // skipped hears about its own move — while its new track is still loading and the
    // engine is still holding the old one. Anchoring on what the engine holds put the
    // queue back on the song just skipped, which is the flick backwards.
    final tracks = [track(1), track(2), track(3)];
    await player.loadQueue(queueOf(tracks));
    await player.playAt(0);
    await settle();
    audio.only.slowness = const Duration(milliseconds: 300);

    final skip = player.next();                 // deliberately not awaited
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // The echo: the same queue, unchanged, arriving as a "something happened" update
    // while the skipped-to song is still being fetched.
    await player.loadQueue(queueOf(tracks, cursor: 0));
    await skip;
    await settle(20);

    expect(player.current?.id, 2,
        reason: 'the skip stands: ${audio.only.calls}');
  });

  test('a move is on screen before the server is asked', () async {
    final tracks = [track(1), track(2), track(3)];
    await player.loadQueue(queueOf(tracks));
    await player.playAt(0);
    await settle();

    player.moveLocally(2, 0);          // drag the third row to the top

    expect([for (final t in player.items) t.id], [3, 1, 2],
        reason: 'the list changes with the finger, not with the network');
    expect(player.current?.id, 1,
        reason: 'and the song playing is still the song playing');
  });

  test('removing a row keeps the music on the same song', () async {
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(1);            // playing the middle one
    await settle();

    player.removeLocally(0);           // take out the row above it

    expect([for (final t in player.items) t.id], [2, 3]);
    expect(player.current?.id, 2, reason: 'still playing what was playing');
  });

  test('a song playing along is never interrupted', () async {
    // The regression this exists for: the watchdog used to read "the engine has not
    // mentioned a new position lately" as a stall. On a platform that only reports on
    // state changes — which is most of them — that is true throughout a perfectly good
    // song, and the "recovery" put the needle back at the top of it every few seconds.
    PlayerService.stallAfter = const Duration(milliseconds: 100);
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    engine.calls.clear();

    // Time passes and the engine says nothing, because it has nothing to say.
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await player.checkForStall();
    }

    expect(engine.calls, isEmpty,
        reason: 'silence from the engine is not a stall: ${engine.calls}');
    expect(player.current?.id, 1);
  });

  test('a stream that dies is put back where the listener was', () async {
    PlayerService.stallAfter = const Duration(milliseconds: 100);
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    engine.tick(const Duration(seconds: 20));      // twenty seconds in
    await settle();

    engine.stall();                                // and the audio stops arriving
    await settle();
    engine.calls.clear();
    await player.checkForStall();                  // notices, waits
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await player.checkForStall();                  // long enough now
    await settle();

    expect(engine.calls.any((c) => c.startsWith('seek 20s')), isTrue,
        reason: 'back to where the song had got to, not to the top: '
            '${engine.calls}');
    expect(player.current?.id, 1, reason: 'and still the same song');
  });

  test('coming back to the app finds a stream that died out of sight', () async {
    PlayerService.stallAfter = const Duration(milliseconds: 100);
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    engine.tick(const Duration(seconds: 30));
    await settle();
    engine.stall();
    await settle();
    await player.checkForStall();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    engine.calls.clear();

    await player.resumeIfStopped();               // the app comes back
    await settle();

    expect(engine.calls.any((c) => c.startsWith('seek 30s')), isTrue,
        reason: 'it picks up where the sound stopped: ${engine.calls}');
  });

  test('an engine that dies in the background is started again', () async {
    // The complaint: leave the app and the music stops after a while. Nothing looked
    // for this. The snapshot is rebuilt from the engine on every state change, so
    // "the app thinks it is playing but the engine has stopped" was a state that could
    // not exist to be noticed — the check meant to catch it compared the engine
    // against a copy of itself and was always false. The signal that does survive is
    // the processing state: an engine holding nothing reports idle.
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    audio.only.tick(const Duration(seconds: 40));
    await settle();

    audio.only.die();                              // the stream's socket closed
    await settle();
    await player.checkForStall();                  // the watchdog's next round
    await settle();

    final engine = audio.only;                     // possibly a fresh platform player
    expect(engine.calls.any((c) => c.startsWith('load')), isTrue,
        reason: 'the source is opened again: ${engine.calls}');
    expect(engine.calls, contains('play'),
        reason: 'and started: ${engine.calls}');
    expect(engine.position, const Duration(seconds: 40),
        reason: 'from where the song had actually got to');
    expect(player.current?.id, 1, reason: 'the same song, not the next one');
  });

  test('an engine that will not come back is not hammered for ever', () async {
    // A phone quietly reopening a dead stream every five seconds until the battery
    // is flat is worse than silence.
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();

    FakeAudioPlayer.loadCount = 0;
    for (var i = 0; i < PlayerService.maxRevivals + 4; i++) {
      if (audio.players.isNotEmpty) audio.only.die();
      await settle();
      await player.checkForStall();
      await settle();
    }

    expect(FakeAudioPlayer.loadCount, lessThanOrEqualTo(PlayerService.maxRevivals),
        reason: 'it gives up rather than retrying for ever');
    expect(FakeAudioPlayer.loadCount, greaterThan(0), reason: 'but it does try');
  });

  test('a paused player is left paused', () async {
    // The other half of the same fix: reviving must follow what the person asked for,
    // never what the engine happens to be doing. Pausing and putting the phone down
    // is not a fault to be repaired.
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    await player.pause();
    await settle();
    final engine = audio.only;
    engine.calls.clear();

    for (var i = 0; i < 4; i++) {
      await player.checkForStall();
      await settle();
    }
    await player.resumeIfStopped();
    await settle();

    expect(engine.calls, isEmpty,
        reason: 'nothing starts music nobody asked for: ${engine.calls}');
  });

  test('a queue that has run out is not restarted', () async {
    await player.loadQueue(queueOf([track(1)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    engine.reachEnd();
    await settle();
    engine.calls.clear();

    await player.checkForStall();
    await settle();

    expect(engine.calls.where((c) => c == 'play'), isEmpty,
        reason: 'the end of the queue is not a stall: ${engine.calls}');
  });

  test('shuffling deals what is coming and leaves the rest alone', () async {
    // Twelve, so that "something moved" is a fact rather than a coin toss: nine songs
    // are dealt, and the chance of the same order coming back is one in 362,880.
    final tracks = [for (var i = 1; i <= 12; i++) track(i)];
    await player.loadQueue(queueOf(tracks));
    await player.playAt(2);            // third song
    await settle();
    final before = [for (final t in player.items) t.id];

    player.shuffleWhatIsComing();

    final after = [for (final t in player.items) t.id];
    expect(after.sublist(0, 3), before.sublist(0, 3),
        reason: 'what has played and what is playing stay where they are');
    expect(after.sublist(3)..sort(), before.sublist(3)..sort(),
        reason: 'the same songs are still there');
    expect(player.current?.id, 3, reason: 'and the same one is playing');
    expect(after, isNot(before), reason: 'something moved');
  });

  test('a guest follows the room into the right song at the right place', () async {
    // The other half of a jam: the host says where the music is, and this device puts
    // itself there. No UI, no browser — the state and the player are the whole of it.
    final app = AppState();
    app.api = api;
    app.player = player;
    app.jamListening = true;        // this guest is somewhere else and wants to hear it
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

  test('a guest in the room follows it without making a sound', () async {
    // The normal case, and the reason it is the default: everybody in one room hearing
    // the same record out of five phones a half-second apart is not listening
    // together. The screen keeps up; the speaker stays out of it.
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

    expect(player.current?.id, 2, reason: 'the screen is on the room\'s song');
    expect(player.last?.playing ?? false, isFalse,
        reason: 'and this device is silent');
    // Not "loaded and then paused": a stream nobody is listening to is somebody's
    // phone data spent on a song they cannot hear.
    expect(audio.players.values.expand((p) => p.sources), isEmpty,
        reason: 'no audio was fetched at all');
  });

  test('leaving a jam hands back the queue that came with it', () async {
    // The host's queue is in a guest's list only while they are in the room. Clearing
    // the jam alone left it sitting there, selected, refusing every edit.
    final app = AppState();
    app.api = api;
    app.player = player;
    final theirs = queueOf([track(1), track(2)]);
    app.activeQueue = theirs;
    app.queues = [theirs];
    app.jam = Jam.fromJson({
      'id': 7, 'code': 'ABC123', 'queue_id': theirs.id, 'host': 'somebody',
      'is_host': false,
    });
    await player.loadQueue(theirs);
    await player.playAt(0);
    await settle();
    expect(audio.only.playing, isTrue);

    await app.leaveJam();
    await settle();

    expect(app.jam, isNull);
    // Asked of the player rather than the engine: an empty queue deactivates the
    // platform player altogether, which is the engine agreeing rather than an answer.
    expect(player.last?.playing, isFalse,
        reason: 'the music was the room\'s; ending the room ends it');
    expect(app.activeQueue?.id, isNot(theirs.id),
        reason: 'and the queue that came with the room goes back with it');
    expect(app.queues.any((q) => q.id == theirs.id), isFalse,
        reason: 'it is not in the list of queues either');
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
