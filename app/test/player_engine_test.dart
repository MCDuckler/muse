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
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/playback_log.dart';
import 'package:muse/src/state/player.dart';

import 'fake_audio.dart';

/// How long the stub server takes to answer. A load that is still in flight is where
/// the interesting races live, and instant answers hide them.
Duration stubDelay = Duration.zero;

/// A server that says yes. The player talks to one for the stream key, for warming the
/// cache and for reporting what was listened to; none of that is what these tests are
/// about, and none of it should reach the real one.
/// Where songs start and end, for the tests that are about that: by track id. A song
/// not in here is answered the way a server from before this would — with nothing.
final timings = <int, Map<String, dynamic>>{};

Future<HttpServer> stubServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      if (stubDelay > Duration.zero) await Future<void>.delayed(stubDelay);
      request.response.headers.contentType = ContentType.json;
      final path = request.uri.path;
      final timingFor = RegExp(r'^/tracks/(\d+)/analysis$').firstMatch(path);
      if (timingFor != null && timings.containsKey(int.parse(timingFor.group(1)!))) {
        request.response.write(jsonEncode(timings[int.parse(timingFor.group(1)!)]));
      } else if (path == '/auth/stream-key') {
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
      } else if (RegExp(r'^/tracks/\d+$').hasMatch(path) && request.method == 'GET') {
        // One song's details, the way the server sends them outside a queue: no row.
        final id = int.parse(path.split('/')[2]);
        request.response.write(jsonEncode({
          'id': id, 'title': 'Track $id (tidied)', 'artists': ['Someone'],
          'duration_ms': 60000, 'state': 'ready',
          'stream_url': '/tracks/$id/stream', 'source': 'youtube',
        }));
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

Queue queueOf(List<Track> tracks, {int cursor = 0, List<int>? rows}) =>
    Queue.fromJson({
      'id': 1,
      'name': 'test',
      'cursor_index': cursor,
      'position_ms': 0,
      'rev': 1,
      'items': [
        for (final (i, t) in tracks.indexed)
          {
            'id': t.id,
            'title': t.title,
            'artists': t.artists,
            'duration_ms': t.durationMs,
            'state': 'ready',
            'stream_url': t.streamPath,
            'source': 'youtube',
            'pos': i,
            // The row's own name, which the server keeps with the row wherever it
            // moves to. Given explicitly so a test can hold one still while the
            // positions around it change.
            'item_id': rows == null ? 100 + i : rows[i],
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
    timings.clear();
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

  group('one song into the next', () {
    // Songs here are a minute long. This one has two seconds of nothing after it.
    Map<String, dynamic> timed({int lead = 0, int tail = 0}) =>
        {'duration_ms': 60000, 'lead_ms': lead, 'tail_ms': tail, 'beats': <int>[]};

    test('the moment its sound is over, the next one is on', () async {
      timings[1] = timed(tail: 2000);
      await player.loadQueue(queueOf([track(1), track(2), track(3)]));
      await player.playAt(0);
      await settle();
      final engine = audio.only;

      engine.tick(const Duration(seconds: 50));
      await settle();
      expect(player.current?.id, 1);

      // A tenth of a second before the sound ends: the timer is set for the rest.
      engine.tick(const Duration(milliseconds: 57900));
      await settle(3);
      expect(player.current?.id, 1, reason: 'not before it is over');
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await settle();

      expect(player.current?.id, 2, reason: 'two seconds of nothing, not sat through');
      expect(player.joins, 1);
      expect(engine.calls, contains('seek 0s index:1'),
          reason: 'a step through the engine, which already had it: ${engine.calls}');
      expect(engine.calls.where((c) => c.startsWith('load')).length, 1,
          reason: 'and not a load');
    });

    test('a song paused in its last second is left where it is', () async {
      timings[1] = timed(tail: 2000);
      await player.loadQueue(queueOf([track(1), track(2)]));
      await player.playAt(0);
      await settle();
      audio.only.tick(const Duration(milliseconds: 57900));
      await settle(3);
      await player.playPause();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await settle();
      expect(player.current?.id, 1);
      expect(player.joins, 0);
    });

    test('the last song plays out: there is nothing to join it to', () async {
      timings[2] = timed(tail: 2000);
      await player.loadQueue(queueOf([track(1), track(2)]));
      await player.playAt(1);
      await settle();
      audio.only.tick(const Duration(milliseconds: 57950));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await settle();
      expect(player.joins, 0);
      expect(player.current?.id, 2);
    });

    test('a song starts where its sound does', () async {
      timings[2] = timed(lead: 1500);
      await player.loadQueue(queueOf([track(1), track(2), track(3)]));
      await player.playAt(0);
      await settle();                       // and the next song's timing is asked for
      final engine = audio.only;

      // The engine moves on by itself, at the top of the file…
      engine.advanceByItself();
      await settle();
      expect(player.current?.id, 2);
      expect(engine.position, const Duration(milliseconds: 1500),
          reason: '…and is put where the sound is: ${engine.calls}');

      // Chosen by hand, it is loaded there in the first place.
      await player.playAt(0);
      await settle();
      await player.playAt(1);
      await settle();
      expect(engine.position, const Duration(milliseconds: 1500));
    });

    test('switched off, files play from end to end as they are', () async {
      timings[1] = timed(tail: 2000);
      timings[2] = timed(lead: 1500);
      player.seamless = false;
      await player.loadQueue(queueOf([track(1), track(2)]));
      await player.playAt(0);
      await settle();
      final engine = audio.only;
      engine.tick(const Duration(milliseconds: 57950));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await settle();
      expect(player.joins, 0);
      engine.advanceByItself();
      await settle();
      expect(engine.position, Duration.zero);
    });
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

  test('a prefetch that cannot work is tried once, not for ever', () async {
    // What this is really about: the player hands the engine the next song so the
    // change costs nothing, and it does that again on every queue update — which, with
    // a couple of hundred songs downloading in the background, is several times a
    // second. Clearing the "already queued" mark when the attempt failed meant the
    // next call tried again, and every attempt makes the engine re-prepare and re-open
    // the stream. The music stutters, and it is this loop doing it.
    // One song first, so the engine exists and has nothing to prefetch yet: the
    // failure has to be the *first* attempt, or the "already queued" mark is set from
    // the successful one and nothing ever tries again.
    await player.loadQueue(queueOf([track(1)]));
    await settle();
    final engine = audio.only;
    engine.refuseInserts = true;

    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(0);
    await settle();
    engine.calls.clear();

    // Every one of these used to be another go at the same impossible insert.
    for (var i = 0; i < 6; i++) {
      await player.loadQueue(queueOf([track(1), track(2), track(3)]));
      await settle();
    }

    final tries = engine.calls.where((c) => c == 'insert refused').length;
    expect(tries, lessThanOrEqualTo(1),
        reason: 'tried $tries times: ${engine.calls}');
  });

  test('and the song still moves on when it ends', () async {
    // The other half: giving up on the prefetch must not give up on the queue. The old
    // path — the song ends, Dart notices, the next one is loaded — still has to work.
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    audio.only.refuseInserts = true;

    audio.only.reachEnd();
    await settle();

    expect(player.current?.id, 2, reason: 'it went on to the next song');
  });

  test('a record\'s loudness match reaches the engine as the decibels it is', () async {
    // mpv cubes its volume; the match is a number of decibels, and -6 dB told to it as
    // a gain of 0.5 came out at -18. On a desk the gain goes in as its cube root.
    final was = PlayerService.gainToVolume;
    PlayerService.gainToVolume = (g) => g <= 0 ? 0 : math.pow(g, 1 / 3).toDouble();
    addTearDown(() => PlayerService.gainToVolume = was);
    await player.loadQueue(Queue.fromJson({
      'id': 1, 'name': 'test', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
      'items': [
        {'id': 7, 'title': 'Loud', 'artists': ['Someone'], 'duration_ms': 60000,
         'state': 'ready', 'stream_url': '/tracks/7/stream', 'source': 'youtube',
         'gain_db': -6.0, 'pos': 0},
      ],
    }));
    await player.playAt(0);
    await settle();
    final heard = math.pow(audio.only.volume, 3);
    expect(20 * math.log(heard) / math.ln10, closeTo(-6.0, 0.01));
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
    // The fake engine plays on while time passes, as a real one does, so "where it
    // had got to" is forty seconds and the moments the test took since.
    expect((engine.position - const Duration(seconds: 40)).inMilliseconds, inInclusiveRange(0, 500),
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

  test('shuffling says what order it dealt, for the server to keep', () async {
    final tracks = [for (var i = 1; i <= 8; i++) track(i)];
    await player.loadQueue(queueOf(tracks));
    await player.playAt(1);
    await settle();

    final dealt = player.shuffleWhatIsComing();

    expect(dealt, isNotNull);
    expect(dealt, [for (final t in player.items.sublist(2)) t.id],
        reason: 'the order reported is the order now on screen');
    expect(player.shuffleWhatIsComing(), isNotNull);
    await player.loadQueue(queueOf([track(1), track(2)]));
    expect(player.shuffleWhatIsComing(), isNull,
        reason: 'nothing worth rearranging is nothing to send');
  });

  test('where a song just added sits, counted in the whole queue', () {
    Queue sliced(List<int> ids, {int from = 0, int? total}) => Queue.fromJson({
          'id': 1, 'name': 'q', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
          'total': total ?? from + ids.length, 'window_from': from,
          'items': [
            for (final id in ids)
              {'id': id, 'title': 'T$id', 'artists': ['A'], 'state': 'ready',
               'stream_url': '/tracks/$id/stream', 'source': 'youtube'},
          ],
        });

    // Appended: the last row of the whole queue, even beyond the slice held.
    expect(AppState.whereItLanded(sliced([1, 2, 3], from: 600, total: 2000), 9,
            mode: 'end', after: 601),
        1999);
    // Put on next behind two others: the first copy after the song playing.
    expect(AppState.whereItLanded(sliced([1, 2, 7, 8, 5, 6]), 5,
            mode: 'next', after: 1),
        4);
    // A copy above the song playing is history, not the one just added.
    expect(AppState.whereItLanded(sliced([5, 2, 3, 5]), 5, mode: 'next', after: 1), 3);
    expect(AppState.whereItLanded(sliced([2, 3], from: 600, total: 1200), 3,
            mode: 'next', after: 600),
        601);
    // Appended where the slice reaches the end: the last copy, not simply the last
    // row — somebody else may have added a song behind it since.
    expect(AppState.whereItLanded(sliced([9, 1, 9, 2]), 9, mode: 'end', after: 0), 2);
  });

  test('a server address typed without a scheme is still an address', () {
    expect(AppState.normaliseServer('wetowl.example'), 'https://wetowl.example');
    expect(AppState.normaliseServer(' https://wetowl.example// '),
        'https://wetowl.example');
    expect(AppState.normaliseServer('192.168.1.20:8770'), 'http://192.168.1.20:8770');
    expect(AppState.normaliseServer('localhost:8770'), 'http://localhost:8770');
    expect(AppState.normaliseServer('http://box:8770'), 'http://box:8770');
    expect(AppState.normaliseServer('172.40.0.1'), 'https://172.40.0.1',
        reason: 'outside the private range is a public address');
  });

  test('play at the end of the queue plays the last song again, from the top',
      () async {
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(1);
    await settle();
    audio.only.tick(const Duration(seconds: 50));
    audio.only.reachEnd();
    await settle();
    expect(player.last?.finished, isTrue, reason: 'the queue has run out');

    await player.playPause();
    await settle();

    expect(player.last?.finished, isFalse);
    expect(player.current?.id, 2, reason: 'the last song, not the first');
    final engine = audio.players.values.last;
    expect(engine.position, Duration.zero, reason: 'from the top: ${engine.calls}');
    expect(engine.playing, isTrue);
  });

  test('play at the end of the queue plays what was added since', () async {
    await player.loadQueue(queueOf([track(1)]));
    await player.playAt(0);
    await settle();
    audio.only.reachEnd();
    await settle();
    expect(player.last?.finished, isTrue);

    await player.loadQueue(queueOf([track(1), track(2)]));
    await settle();
    await player.playPause();
    await settle();

    expect(player.current?.id, 2, reason: 'the song added after it ran out');
    expect(audio.players.values.last.playing, isTrue);
  });

  test('switching to repeat-one takes the queued next song back out', () async {
    // The next song was handed to the engine while repeat was off. Left there,
    // the engine walks to it when this one ends, and "repeat this one" did not.
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(0);
    await settle();
    expect(audio.only.sources.length, 2, reason: 'the next one is queued');

    player.setRepeat(QueueRepeat.one);
    await settle();

    expect(audio.only.sources.length, 1,
        reason: 'and is taken back: ${audio.only.calls}');
    expect(player.queuedNextId, isNull);

    audio.only.reachEnd();
    await settle();
    expect(player.current?.id, 1, reason: 'the same song again');
    // Back to the top and on: just_audio still believes it is playing through the
    // end of a song, so the only call the engine sees is the seek.
    expect(audio.only.calls.last, 'seek 0s', reason: '${audio.only.calls}');
  });

  test('previous restarts the song through the same door a seek uses', () async {
    final written = <int>[];
    player.onCursor = (q, {cursorIndex, positionMs}) => written.add(positionMs ?? -1);
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(1);
    await settle();
    audio.only.tick(const Duration(seconds: 30));
    await settle();

    await player.previous();
    await settle();

    expect(player.current?.id, 2, reason: 'deep into a song, previous restarts it');
    expect(audio.only.calls, contains('seek 0s'));
    expect(written.last, 0, reason: 'and the cursor is written at the top of it');

    await player.previous();
    await settle();
    expect(player.current?.id, 1, reason: 'at the top of a song it steps back');
  });

  test('play on a song that is not here yet waits instead of asking the engine',
      () async {
    final pending = Track.fromJson({
      'id': 5,
      'title': 'Not yet',
      'artists': ['Someone'],
      'duration_ms': 60000,
      'state': 'pending',
      'source': 'youtube',
    });
    final queue = Queue.fromJson({
      'id': 1, 'name': 'test', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
      'items': [
        {'id': 1, 'title': 'Track 1', 'artists': ['Someone'], 'duration_ms': 60000,
         'state': 'ready', 'stream_url': '/tracks/1/stream', 'source': 'youtube'},
        {'id': 5, 'title': 'Not yet', 'artists': ['Someone'], 'duration_ms': 60000,
         'state': 'pending', 'source': 'youtube'},
      ],
    });
    expect(pending.isReady, isFalse);
    await player.loadQueue(queue);
    await player.playAt(0);
    await settle();
    final first = audio.only;
    // On to the one that is not here: the player parks on it and waits — and
    // stopping there lets the platform player go, so there is no engine at all.
    await player.next();
    await settle();
    expect(player.last?.waitingForDownload, isTrue);
    final plays = first.calls.where((c) => c == 'play').length;

    // Pressing play while it waits.
    await player.playPause();
    await settle();

    expect(player.last?.waitingForDownload, isTrue, reason: 'still waiting');
    expect(first.calls.where((c) => c == 'play').length, plays,
        reason: 'the old engine was not asked to play nothing: ${first.calls}');
    expect(audio.players.values.any((p) => p.calls.contains('play')), isFalse,
        reason: 'and no new engine was made to play nothing either');
  });

  test('a stream still opening is reported as such', () async {
    await player.loadQueue(queueOf([track(1)]));
    await player.playAt(0);
    await settle();
    expect(player.last?.buffering, isFalse);

    audio.only.stall();
    await settle();
    expect(player.last?.buffering, isTrue,
        reason: 'waiting on the network is a state the screen can show');

    audio.only.recover();
    await settle();
    expect(player.last?.buffering, isFalse);
  });

  test('signing out takes the session with it', () async {
    // Only the token used to go: the player kept the old account's queue loaded and
    // signing in as somebody else found it still there.
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    app.api = api;
    app.player = player;
    final mine = queueOf([track(1), track(2)]);
    app.activeQueue = mine;
    app.queues = [mine];
    app.user = 'chris';
    app.favourites = {1};
    await player.loadQueue(mine);
    await player.playAt(0);
    await settle();
    expect(audio.only.playing, isTrue);

    await app.logout();
    await settle();

    expect(app.user, isNull);
    expect(app.player, isNull, reason: 'the next account gets a player of its own');
    expect(app.activeQueue, isNull);
    expect(app.queues, isEmpty);
    expect(app.favourites, isEmpty);
    expect(api.token, isNull);
    expect(audio.players, isEmpty, reason: 'the engine was let go of');
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

  AppState guestOf(PlayerService player, ApiClient api, {bool listening = true}) {
    final app = AppState();
    app.api = api;
    app.player = player;
    app.jamListening = listening;
    app.jam = Jam.fromJson({
      'id': 7,
      'code': 'ABC123',
      'queue_id': 1,
      'host': 'somebody',
      'is_host': false,
    });
    return app;
  }

  test('a report overtaken on the way does not drag a guest back', () async {
    // The heartbeat sent just before a skip can arrive just after it. Believed, it is
    // the queue jumping back to the old song and forward again five seconds later.
    final app = guestOf(player, api);
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await settle();

    await app.followJamPlayback(const JamPlayback(
        trackId: 2, positionMs: 0, playing: true, seq: 2000));
    await settle();
    await app.followJamPlayback(const JamPlayback(
        trackId: 1, positionMs: 58000, playing: true, seq: 1000));
    await settle();
    expect(player.current?.id, 2, reason: 'the late one was about the past');
  });

  test('a guest lands on the copy of the song the host is on', () async {
    final app = guestOf(player, api, listening: false);
    await player.loadQueue(
        queueOf([track(1), track(2), track(1), track(3)], rows: [10, 11, 12, 13]));
    await settle();

    await app.followJamPlayback(const JamPlayback(
        trackId: 1, itemId: 12, positionMs: 1000, playing: true, seq: 1));
    await settle();
    expect(player.current?.queueItemId, 12,
        reason: 'the second copy, though the first is the one already on');
    expect(audio.players.values.any((a) => a.playing), isFalse,
        reason: 'and still without a sound');
  });

  test('a guest who reached the end first is not sent back for the last bars',
      () async {
    final app = guestOf(player, api);
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await settle();
    // This device finished the first song a moment before the host and went on.
    await player.playTrack(2);
    await settle();

    // The host, still two seconds from the end of it.
    await app.followJamPlayback(const JamPlayback(
        trackId: 1, positionMs: 58000, playing: true, seq: 1));
    await settle();
    expect(player.current?.id, 2, reason: 'where the host will be in two seconds');

    // But a host who really is somewhere else in that song is followed.
    await app.followJamPlayback(const JamPlayback(
        trackId: 1, positionMs: 20000, playing: true, seq: 2));
    await settle();
    expect(player.current?.id, 1);
  });

  test('the room has one clock, and a change to the queue is not it', () async {
    final app = guestOf(player, api, listening: false);
    await player.loadQueue(queueOf([track(1), track(2)]));
    await settle();

    await app.followJamPlayback(const JamPlayback(
        trackId: 1, positionMs: 30000, playing: true, seq: 1));
    expect(app.hostPosition!.inSeconds, inInclusiveRange(30, 31));

    // A paused room stays where it paused, however long ago that was said.
    await app.followJamPlayback(const JamPlayback(
        trackId: 1, positionMs: 31000, playing: false, seq: 2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(app.hostPosition, const Duration(milliseconds: 31000));
    expect(app.musicIsPlaying, isFalse);

    // And it never runs off the end of the song.
    await app.followJamPlayback(const JamPlayback(
        trackId: 1, positionMs: 59900, playing: true, seq: 3));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(app.hostPosition, const Duration(seconds: 60));
  });

  test('a remote control shows what the other device is doing', () async {
    final app = AppState();
    app.api = api;
    app.player = player;
    app.thisDevice = 1;
    app.activeQueue = queueOf([track(1), track(2), track(3)]);
    await player.loadQueue(app.activeQueue!);
    await settle();
    app.devices = [
      DeviceInfo(
          id: 5, name: 'The desk', live: true, playing: true, positionMs: 1000,
          queueId: 1, track: track(1), itemId: 100, heardAt: DateTime.now()),
    ];
    app.playingOn = 5;

    // The desk says where it is: the screen here runs from that, not from the silent
    // player in this hand.
    await app.heardFromADevice({
      'device_id': 5, 'playing': true, 'track_id': 1, 'queue_id': 1,
      'item_id': 100, 'position_ms': 20000,
    });
    expect(app.musicIsPlaying, isTrue);
    expect(app.positionNow!.inSeconds, inInclusiveRange(20, 21));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(app.positionNow!.inMilliseconds, greaterThan(20200),
        reason: 'carried forward between reports');
    expect(audio.players.values.any((a) => a.playing), isFalse,
        reason: 'this one makes no sound');

    // Pause is on screen before the desk has answered.
    unawaited(app.playPause());
    await Future<void>.delayed(Duration.zero);
    expect(app.musicIsPlaying, isFalse);
    final held = app.positionNow;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(app.positionNow, held, reason: 'and the clock stops with it');
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

  test('a guest sees the room playing even with their own speaker off', () async {
    // Everything on the now-playing screen is about the music, and for a guest in a
    // room the music is happening — it is just coming out of somebody else's speaker.
    // Reading this device's own engine showed a stopped player, a still record and a
    // play button to somebody listening to a song.
    final app = AppState();
    app.api = api;
    app.player = player;
    app.jam = Jam.fromJson({
      'id': 7, 'code': 'ABC123', 'queue_id': 1,
      'host': 'somebody', 'is_host': false,
    });
    await player.loadQueue(queueOf([track(1), track(2)]));
    await settle();

    expect(app.musicIsPlaying, isFalse, reason: 'nothing said yet');

    await app.followJamPlayback(const JamPlayback(
        trackId: 2, positionMs: 30000, playing: true));
    await settle();

    expect(audio.players.values.expand((p) => p.sources), isEmpty,
        reason: 'still silent here');
    expect(app.musicIsPlaying, isTrue, reason: 'but the room is playing');
    expect(app.positionNow, isNotNull);
    expect(app.positionNow!.inSeconds, greaterThanOrEqualTo(30),
        reason: 'and the clock runs from the host, not from a silent engine');

    // And a room that pauses stops the record turning.
    await app.followJamPlayback(const JamPlayback(
        trackId: 2, positionMs: 42000, playing: false));
    await settle();
    expect(app.musicIsPlaying, isFalse);
  });

  test('a guest playing along reads its own engine', () async {
    // The other half: once the speaker here is on, this device is the thing making
    // the sound, and its own clock is the one that matters.
    final app = AppState();
    app.api = api;
    app.player = player;
    app.jamListening = true;
    app.jam = Jam.fromJson({
      'id': 7, 'code': 'ABC123', 'queue_id': 1,
      'host': 'somebody', 'is_host': false,
    });
    await player.loadQueue(queueOf([track(1), track(2)]));
    await settle();

    await app.followJamPlayback(const JamPlayback(
        trackId: 2, positionMs: 30000, playing: true));
    await settle();

    expect(app.musicIsPlaying, isTrue);
    expect(audio.only.playing, isTrue, reason: 'this device is the one playing');
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

  test('something else taking the speaker for good does not disable the watchdog',
      () async {
    // The complaint that would not go away: playback stops sometimes when you leave
    // the app. Opening anything that makes a sound takes the audio focus for good —
    // there is no "over" event for that, ever — and the app used to stay flagged as
    // interrupted from then on. The flag is what tells the watchdog to keep its hands
    // off, so from the first video somebody watched until the app was restarted, every
    // stop in the background was permanent.
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();

    await player.handleInterruption(
        begin: true, type: AudioInterruptionType.unknown);
    await settle();
    expect(audio.only.calls, contains('pause'),
        reason: 'the other app has the speaker');

    // Back in this app, pressing play.
    await player.playPause();
    await settle();

    // The log keeps only its last few hundred lines, so "everything after here" is
    // read from a marker rather than from a length that stops growing once it is full.
    PlaybackLog.note('--- marker');
    audio.only.die();                              // and then the engine dies
    await settle();
    await player.checkForStall();
    await settle();

    final said = PlaybackLog.lines.skipWhile((l) => !l.endsWith('--- marker')).toList();
    expect(said.any((l) => l.contains('reviving')), isTrue,
        reason: 'the watchdog still works after an interruption: $said');
  });

  test('a fault the player catches is written down, not only shown', () async {
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();

    PlaybackLog.note('--- marker');
    audio.only.failLoad = true;          // the next record will not open
    await player.next();
    await settle();

    final said = PlaybackLog.lines.skipWhile((l) => !l.endsWith('--- marker')).toList();
    // Both halves: the label the player bar shows, and the line that survives a
    // restart and is handed to the server. A caught error never reaches Flutter's own
    // error handler, so without this it is a label and nothing else — which is how a
    // range error during ordinary playback on a phone stayed unfindable.
    expect(player.lastError, isNotNull, reason: 'nothing on screen');
    expect(said.any((l) => l.contains('PLAYER FAULT')), isTrue,
        reason: 'nothing written down: $said');
    // The point of keeping the stack: it names our own file and line, which is the
    // whole difference between "a range error happened" and somewhere to look.
    expect(said.any((l) => l.contains('player.dart:')), isTrue,
        reason: 'no stack, so nothing says where it came from: $said');
    // And the same fault caught again on its way up does not cost another eight lines.
    expect(said.where((l) => l.contains('PLAYER FAULT')).length, 2);
    expect(said.any((l) => l.contains('as above')), isTrue, reason: '$said');

    // But the same fault an hour later is a second occurrence, not an echo of the
    // first, and gets its own stack: the bug this was built for is intermittent, and
    // keeping only the first stack would be keeping the one we already have.
    PlaybackLog.note('--- later');
    await player.playAt(0);
    await settle();
    final again = PlaybackLog.lines.skipWhile((l) => !l.endsWith('--- later')).toList();
    expect(again.any((l) => l.contains('player.dart:')), isTrue,
        reason: 'the second occurrence lost its stack: $again');
  });

  test('a phone call is resumed from, an interruption that never ends is not',
      () async {
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    audio.only.calls.clear();

    await player.handleInterruption(begin: true, type: AudioInterruptionType.pause);
    await settle();
    expect(audio.only.calls, contains('pause'));

    await player.handleInterruption(begin: false, type: AudioInterruptionType.pause);
    await settle();
    expect(audio.only.calls, contains('play'),
        reason: 'it was ours before the call and it is ours again');
  });

  test('a bluetooth route settling is not a headphone being pulled out', () {
    // ignore_for_file: experimental_member_use
    AudioDevice device(AudioDeviceType type, String name) => AudioDevice(
        id: name, name: name, isInput: false, isOutput: true, type: type);

    // Still something to play through: the broadcast was the routing settling, which
    // this phone does about twice a minute, and pausing on it stopped the music for
    // good with nothing to show why.
    expect(
        PlayerService.somewhereElseToPlay([
          device(AudioDeviceType.builtInSpeaker, 'speaker'),
          device(AudioDeviceType.bluetoothA2dp, 'Kitchen'),
        ]),
        'Kitchen');

    // Nothing left but the speaker: something really was unplugged.
    expect(
        PlayerService.somewhereElseToPlay(
            [device(AudioDeviceType.builtInSpeaker, 'speaker')]),
        isNull);
  });

  test('the speaker coming back after another app is done starts it again', () async {
    // The complaint: switching to another app sometimes stops the music, while
    // turning the screen off never does. Almost any app takes the audio focus for
    // good when it opens — a video, a game, a browser tab with a muted autoplay —
    // and Android hands it back when that app is finished with it. Treating that
    // hand-back as "somebody stopped the music" is the whole bug: the screen going
    // off takes no focus from anybody, which is why that case was always fine.
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    audio.only.calls.clear();

    await player.handleInterruption(
        begin: true, type: AudioInterruptionType.unknown);
    await settle();
    expect(audio.only.calls, contains('pause'));

    await player.handleInterruption(
        begin: false, type: AudioInterruptionType.unknown);
    await settle();
    expect(audio.only.calls, contains('play'),
        reason: 'the other app is done and the speaker is ours again');
  });

  test('the same song twice keeps playing the copy it is on', () async {
    // Radio produces queues like this, and so does adding a favourite again. Two rows
    // holding the same track are the same track: only the row itself tells copy one
    // from copy two, and matching by track id could only pick "whichever copy is
    // nearest", which on a tie slid playback back to the earlier one and played the
    // song again.
    final again = track(7);
    await player.loadQueue(queueOf([again, track(5), again, track(9)],
        rows: [100, 101, 102, 103]));
    await player.playAt(2);                        // the second copy
    await settle();
    expect(player.index, 2);

    // Something is added at the top, so every row below it moves down one — and the
    // two copies are now equally far from where playback was.
    await player.loadQueue(queueOf([track(4), again, track(5), again, track(9)],
        rows: [99, 100, 101, 102, 103]));
    await settle();

    expect(player.index, 3, reason: 'still the copy that was playing, one row down');
    expect(player.current?.queueItemId, 102);
  });

  test('the screen follows the speaker when the engine jumps', () async {
    // Any move that was not exactly one along used to be ignored: the engine played
    // the third song while the screen named the first, and nothing ever put the two
    // back together. What the engine is playing is a fact — it carries the track's own
    // tag — so that is what the screen is made to agree with.
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    // Three sources in the engine: this one, the one queued behind it, and one more
    // handed over after that.
    engine.sources.add('http://example.invalid/tracks/3/stream');

    engine.jumpBy(2);
    await settle();

    expect(player.current?.id, 3,
        reason: 'the screen names what is coming out of the speaker');
  });

  test('a queue with the same song twice moves to the copy that is playing',
      () async {
    final again = track(7);
    await player.loadQueue(queueOf([again, track(5), again, track(9)],
        rows: [200, 201, 202, 203]));
    await player.playAt(1);                       // the row before the second copy
    await settle();

    audio.only.advanceByItself();                 // into the second copy of track 7
    await settle();

    expect(player.current?.id, 7);
    expect(player.current?.queueItemId, 202,
        reason: 'the copy the engine holds, not the one at the top of the queue');
  });

  test('a song in the queue twice does not hop copies when its details change',
      () async {
    // Covers and tidied titles arrive for a song while it plays — several a minute
    // while a library is being enriched. The fresh details were put into the queue's
    // rows *in place of* the rows, which lost each row its name; the watchdog then
    // could not match the row the engine was playing, went looking for "the next copy
    // of this song", and found the other one. And then the first again.
    final again = track(7);
    await player.loadQueue(queueOf([again, track(5), again, track(9)],
        rows: [300, 301, 302, 303]));
    await player.playAt(2);                       // the second copy
    await settle();

    await player.onTrackUpdated(7);
    await settle();
    expect(player.current?.title, 'Track 7 (tidied)', reason: 'the news did arrive');
    expect(player.current?.queueItemId, 302, reason: 'and the row is still the row');

    await player.checkForStall();                 // the watchdog's round
    await settle();
    expect(player.index, 2, reason: 'still the second copy');

    await player.onTrackReady(7);
    await player.checkForStall();
    await settle();
    expect(player.index, 2);
    expect(player.items[0].queueItemId, 300);
  });

  test('a row renamed by the server is not a reason to change copies', () async {
    // An older server renames every row on a reorder. The engine still holds the old
    // name; the right song under a name nobody has any more is agreement.
    final again = track(7);
    await player.loadQueue(queueOf([again, track(5), again, track(9)],
        rows: [400, 401, 402, 403]));
    await player.playAt(2);
    await settle();
    await player.loadQueue(queueOf([again, track(5), again, track(9)],
        rows: [500, 501, 502, 503]));
    await settle();
    expect(player.index, 2);

    await player.checkForStall();
    await settle();
    expect(player.index, 2, reason: 'not the copy at the top');
  });

  test('a screen left on the wrong song is put right by the watchdog', () async {
    await player.loadQueue(queueOf([track(1), track(2), track(3)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;

    // The engine moves on while the app is not listening — a transition that arrived
    // while something else was mid-flight, which is how the two used to come apart.
    await player.whileBusy(() async {
      engine.advanceByItself();
      await settle();
    });
    expect(player.current?.id, 1, reason: 'the setup: screen and speaker disagree');

    await player.checkForStall();                 // the watchdog's round
    await settle();

    expect(player.current?.id, 2, reason: 'and the screen is put right');
  });

  test('pause from the notification stays paused', () async {
    // The notification, the lockscreen, a headset button and Android Auto all reach
    // the engine through the media session without this app being asked. Playback
    // stopped, nothing here knew a decision had been made, and a few seconds later the
    // watchdog saw music that was supposed to be playing and started the song again.
    PlayerService.stallAfter = const Duration(milliseconds: 100);
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    expect(engine.playing, isTrue);

    engine.pressedElsewhere(playing: false);
    await settle();
    expect(player.last?.playing, isFalse, reason: 'the app knows it stopped');

    engine.calls.clear();
    await player.checkForStall();                  // the watchdog's round
    await settle();
    await player.checkForStall();
    await settle();

    expect(engine.calls, isNot(contains('play')),
        reason: 'a pause is a decision, wherever it was pressed: ${engine.calls}');
    expect(engine.playing, isFalse);
  });

  test('play from the notification is a decision too', () async {
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();
    final engine = audio.only;
    engine.pressedElsewhere(playing: false);
    await settle();

    engine.pressedElsewhere(playing: true);
    await settle();
    expect(player.last?.playing, isTrue);

    // And the watchdog is on duty again: an engine that dies now is brought back.
    engine.die();
    await player.checkForStall();
    await settle();
    expect(engine.calls.where((c) => c.startsWith('load')), isNotEmpty,
        reason: 'music that was asked for is worth reviving: ${engine.calls}');
  });

  test('a pause of your own is not owed the speaker back', () async {
    await player.loadQueue(queueOf([track(1), track(2)]));
    await player.playAt(0);
    await settle();

    await player.handleInterruption(
        begin: true, type: AudioInterruptionType.unknown);
    await settle();
    // Thought better of it and pressed pause while the other app had it.
    await player.pause();
    await settle();
    audio.only.calls.clear();

    await player.handleInterruption(
        begin: false, type: AudioInterruptionType.unknown);
    await settle();
    expect(audio.only.calls, isNot(contains('play')),
        reason: 'starting music over somebody who stopped it is worse than silence');
  });
}
