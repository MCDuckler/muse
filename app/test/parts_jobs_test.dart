// Taking records apart as a list you can watch: one at a time and in order, where each
// one is, stopping one, putting one first, trying a failed one again — and the voice
// on its own, which only the separator can give.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/parts.dart';
import 'package:muse/src/worker/parts_jobs.dart';
import 'package:muse/src/worker/render_parts.dart';
import 'package:muse/src/worker/separation_kit.dart' show separatorProgramForTesting;

import 'fake_audio.dart';

Track song(int id, {int durationMs = 240000}) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'duration_ms': durationMs,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

int idOf(Map<String, String> into) =>
    int.parse(into.values.first.split(Platform.pathSeparator).last.split('-').first);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

/// The network as it really is: the test binding answers every request with a 400.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ApiClient api;
  late List<String> asked;

  // A renderer that holds each record until let go of, so the line can be looked at.
  late List<int> started;
  late Map<int, Completer<void>> gates;
  late Map<int, Map<String, String>> intos;
  void holding() {
    renderer = (audio, name, into) async {
      final id = idOf(into);
      started.add(id);
      intos[id] = into;
      await (gates[id] ??= Completer<void>()).future;
      for (final f in into.values) {
        File(f).writeAsBytesSync([1]);
      }
    };
  }

  void letGo(int id) => (gates[id] ??= Completer<void>()).complete();

  setUp(() {
    // A desk with a graphics card: it takes its own records apart (PartsStore).
    PartsStore.bestHere = () => true;
    forgetHere();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    dir = Directory.systemTemp.createTempSync('muse-jobs-');
    partsDirForTesting = dir.path;
    // The separator is here unless a test says otherwise — found again, too, when a
    // retry makes the computer look for it afresh.
    separationHouse = () => 'http://example.invalid';
    separatorProgramForTesting = '/bin/true';
    separatorOffForTesting = false;
    api = ApiClient(baseUrl: 'http://example.invalid')..token = 'x';
    asked = [];
    started = [];
    gates = {};
    intos = {};
    useThisClientInstead(MockClient((r) async {
      asked.add(r.url.path);
      if (r.url.path.contains('/stream-key')) {
        return http.Response('{"key": "k", "expires_at": 99999999999}', 200);
      }
      if (r.url.path.contains('/stem/')) return http.Response('', 202);
      return http.Response('{}', 200);
    }));
  });

  tearDown(() {
    PartsStore.bestHere = null;
    forgetHere();
    debugDefaultTargetPlatformOverride = null;
    renderer = defaultRenderer;
    separationHouse = null;
    separatorProgramForTesting = null;
    separatorOffForTesting = null;
    useThisClientInstead(http.Client());
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('one at a time, in the order asked, and each says where it is', () async {
    holding();
    for (final id in [1, 2, 3]) {
      expect((await partHere('song.m4a', id, 'drums', track: song(id))).$1, Here.making);
    }
    await settle();
    expect(started, [1]);
    expect(partsJobs.of(1)!.stage, PartsStage.separating);
    expect(partsJobs.of(1)!.title, 'Song 1');
    expect(stageLine(partsJobs.of(2)!), 'Next');
    expect(stageLine(partsJobs.of(3)!), 'Waiting · 2 in line');
    expect(partsJobs.busy, isTrue);

    letGo(1);
    await settle();
    expect(partsJobs.of(1)!.stage, PartsStage.ready);
    expect(stageLine(partsJobs.of(1)!), startsWith('Ready '));
    expect(started, [1, 2]);
    expect(stageLine(partsJobs.of(3)!), 'Next');

    letGo(2);
    letGo(3);
    await settle();
    expect(started, [1, 2, 3]);
    expect(partsJobs.ready.map((j) => j.trackId), [3, 2, 1], reason: 'newest first');
    expect(partsJobs.busy, isFalse);
  });

  test('one put first is taken next', () async {
    holding();
    for (final id in [1, 2, 3]) {
      await partHere('song.m4a', id, 'drums', track: song(id));
    }
    await settle();
    promoteHere(3);
    expect(stageLine(partsJobs.of(3)!), 'Next');
    letGo(1);
    await settle();
    expect(started, [1, 3]);
  });

  test('a waiting record cancelled leaves the line, and the automix does not put it back',
      () async {
    holding();
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    await parts.want(song(1), 'drums');
    await parts.want(song(2), 'drums');
    await settle();
    expect(started, [1]);

    partsJobs.onCancel!(2);
    final askedBefore = asked.where((p) => p.contains('/stem/')).length;
    expect(partsJobs.of(2)!.stage, PartsStage.cancelled);
    expect(makingHere(2, 'drums'), isFalse);
    letGo(1);
    await settle();
    expect(started, [1], reason: 'the cancelled one never started');

    expect(await parts.want(song(2), 'drums'), Stem.never,
        reason: 'asked for again from ahead, it stays off the list');
    expect(asked.where((p) => p.contains('/stem/')).length, askedBefore,
        reason: 'nor is the house asked');
    expect(await parts.want(song(2), 'drums', byHand: true), Stem.beingMade,
        reason: 'but a hand asking for it puts it back');
    await settle();
    expect(started, [1, 2]);
  });

  test('the one being taken apart can be stopped, and the next one starts', () async {
    holding();
    await partHere('song.m4a', 1, 'drums', track: song(1));
    await partHere('song.m4a', 2, 'drums', track: song(2));
    await settle();
    // What a stopped run leaves half-written.
    final half = File(intos[1]!['drums']!.replaceFirst('.m4a', '.tmp.m4a'))..writeAsBytesSync([1]);

    cancelHere(1);
    expect(partsJobs.of(1)!.stage, PartsStage.cancelled);
    await settle();
    expect(started, [1, 2], reason: 'the line moves on without waiting for it');
    expect(partsJobs.of(2)!.stage, PartsStage.separating);
    expect(half.existsSync(), isFalse, reason: 'and nothing half-made is left');
    expect(partsJobs.of(1)!.stage, PartsStage.cancelled);
    letGo(2);
  });

  test('a failure says why, and trying again tries again', () async {
    var fail = true;
    renderer = (audio, name, into) async {
      if (fail) throw StateError('ffmpeg could not read it');
      for (final f in into.values) {
        File(f).writeAsBytesSync([1]);
      }
    };
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    expect(await parts.want(song(4), 'drums'), Stem.beingMade);
    await settle();
    final j = partsJobs.of(4)!;
    expect(j.stage, PartsStage.failed);
    expect(j.error, 'ffmpeg could not read it');
    expect(stageLine(j), 'Failed · ffmpeg could not read it');
    expect(partsJobs.failed.single.trackId, 4);

    fail = false;
    partsJobs.onRetry!(4);
    // The retry runs on its own; on a slow machine (the iPhone build's runner) the
    // parts are still being moved into place thirty milliseconds on. Given a moment,
    // not a deadline: the claim is that it becomes ready, not how fast.
    var state = Stem.beingMade;
    for (var i = 0; i < 100 && state != Stem.ready; i++) {
      await settle();
      state = await parts.want(song(4), 'drums');
    }
    expect(partsJobs.of(4)!.stage, PartsStage.ready);
    expect(state, Stem.ready);
  });

  test('the voice alone comes only from the separator', () async {
    holding();
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);

    // With it, one pass makes the voice with the rest.
    expect(await parts.want(song(5), 'vocals'), Stem.beingMade);
    await settle();
    expect(intos[5]!.keys.toSet(), {'instrumental', 'drums', 'music', 'vocals', 'stems'});
    expect(partsJobs.of(5)!.parts, contains('vocals'));
    letGo(5);
    await settle();
    expect(await parts.want(song(5), 'vocals'), Stem.ready);

    // Without it here, the pool makes it: the house is asked, and it is on its list.
    forgetHere();
    separatorOffForTesting = true;
    expect(await parts.want(song(6), 'vocals'), Stem.beingMade);
    expect(asked.any((p) => p.contains('/stem/vocals')), isTrue);
    expect(partsJobs.of(6)?.stage, PartsStage.pooled, reason: 'waiting on the pool');
  });

  test('only the parts not made yet go in the one pass', () async {
    holding();
    File('${dir.path}/7-drums-v$partsVersion.m4a').writeAsBytesSync([1]);
    File('${dir.path}/7-music-v$partsVersion.m4a').writeAsBytesSync([1]);
    await partHere('song.m4a', 7, 'vocals', track: song(7));
    await settle();
    expect(intos[7]!.keys.toSet(), {'instrumental', 'vocals', 'stems'});
    letGo(7);
  });

  test('parts made before are found without fetching the record', () async {
    File('${dir.path}/8-drums-v$partsVersion.m4a').writeAsBytesSync([1]);
    // No record kept here: had it been needed, it would have had to be fetched.
    final parts = PartsStore(api, offlinePath: (id) => null);
    expect(await parts.want(song(8), 'drums'), Stem.ready);
    expect(parts.pathFor(8, 'drums'), endsWith('8-drums-v$partsVersion.m4a'));
    expect(partsJobs.of(8), isNull, reason: 'no fetch, so nothing on the list');
    expect(asked.any((p) => p.contains('stream')), isFalse);
  });

  group('fetching the record', () {
    late HttpServer server;
    const size = 64 * 1024;
    var slow = false;
    setUp(() async {
      slow = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        r.response.contentLength = size;
        for (var i = 0; i < 16; i++) {
          r.response.add(List<int>.filled(size ~/ 16, i));
          await r.response.flush();
          if (slow) await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        await r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    Uri at() => Uri.parse('http://127.0.0.1:${server.port}/tracks/9/stream');

    test('says how much has come, of how much', () async {
      final heard = <(int, int?)>[];
      final got = await HttpOverrides.runWithHttpOverrides(
          () => borrowRecord(at(), {}, 9, progress: (g, t) => heard.add((g, t))), _RealNetwork());
      expect(File(got!).lengthSync(), size);
      expect(heard, isNotEmpty);
      expect(heard.last, (size, size));
      expect(heard.every((h) => h.$2 == size), isTrue);
    });

    test('a record the booth has to fetch shows as fetching, then joins the line', () async {
      holding();
      final house = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}')..token = 'x';
      final parts = PartsStore(house, offlinePath: (id) => null);
      final seen = <PartsStage>[];
      void heard() {
        final j = partsJobs.of(9);
        if (j != null && (seen.isEmpty || seen.last != j.stage)) seen.add(j.stage);
      }

      partsJobs.addListener(heard);
      addTearDown(() => partsJobs.removeListener(heard));
      final answer = await HttpOverrides.runWithHttpOverrides(
          () => parts.want(song(9), 'drums'), _RealNetwork());
      expect(answer, Stem.beingMade);
      await settle();
      expect(seen, [PartsStage.fetching, PartsStage.waiting, PartsStage.separating]);
      expect(partsJobs.of(9)!.track!.displayTitle, 'Song 9');
      letGo(9);
    });

    test('stops when cancelled, and leaves nothing behind', () async {
      slow = true;
      var first = true;
      final fetching = HttpOverrides.runWithHttpOverrides(
          () => borrowRecord(at(), {}, 10, progress: (g, t) {
                if (first) cancelHere(10);
                first = false;
              }),
          _RealNetwork());
      await expectLater(fetching, throwsA(anything));
      expect(dir.listSync().where((f) => f.path.contains('borrowed-10')), isEmpty);
    });
  });

  test('the booth says when a record starts, is ready, or could not be done', () async {
    JustAudioPlatform.instance = FakeJustAudio();
    final booth = Booth(api);
    addTearDown(booth.dispose);
    partsJobs.add(11, track: song(11));
    partsJobs.stage(11, PartsStage.waiting);
    partsJobs.stage(11, PartsStage.separating);
    partsJobs.stage(11, PartsStage.gettingSeparator);
    partsJobs.stage(11, PartsStage.separating);
    partsJobs.progress(11, 0.5);
    partsJobs.stage(11, PartsStage.ready);
    partsJobs.add(12, track: song(12));
    partsJobs.stage(12, PartsStage.separating);
    partsJobs.stage(12, PartsStage.failed, error: 'no');
    expect([for (final e in booth.events) (e.kind, e.text)], [
      (BoothEventKind.parts, 'Taking apart: Song 11'),
      (BoothEventKind.parts, 'Parts ready: Song 11'),
      (BoothEventKind.parts, 'Taking apart: Song 12'),
      (BoothEventKind.trouble, 'Could not take apart: Song 12'),
    ]);
  });

  test('a desk that cannot make the voice waits for the pool rather than giving up',
      () async {
    separatorOffForTesting = true;
    final audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final booth = Booth(api, offlinePath: (id) => kept.path);
    addTearDown(booth.dispose);
    await booth.init();
    await booth.load(booth.a, song(13));
    expect(await booth.a.swapTo('vocals', byHand: true), isFalse, reason: 'not yet');
    expect(booth.a.neverParts, isEmpty, reason: 'the pool will make it');
    await booth.load(booth.a, song(14));
    expect(booth.a.neverParts, isEmpty, reason: 'a new record starts with a clean slate');
  });

  group('the list', () {
    test('a second part of a waiting record keeps its place', () {
      partsJobs.add(1, parts: ['drums', 'music']);
      partsJobs.stage(1, PartsStage.waiting);
      partsJobs.add(2, parts: ['drums', 'music']);
      partsJobs.stage(2, PartsStage.waiting);
      partsJobs.add(1, parts: ['instrumental']);
      expect(partsJobs.placeOf(1), 1);
      expect(partsJobs.of(1)!.parts, ['drums', 'music', 'instrumental']);
      partsJobs.first(2);
      expect(partsJobs.placeOf(2), 1);
    });

    test('a split says how far and how long, and how long it took', () {
      final j = partsJobs.add(3, track: song(3));
      partsJobs.stage(3, PartsStage.waiting);
      partsJobs.stage(3, PartsStage.separating);
      j.stageStarted = DateTime.now().subtract(const Duration(seconds: 30));
      partsJobs.progress(3, 0.25);
      expect(stageLine(j), matches(RegExp(r'^Taking apart · 25% · 1:(29|30|31) left$')));
      j.started = DateTime.now().subtract(const Duration(seconds: 102));
      partsJobs.stage(3, PartsStage.ready);
      expect(stageLine(j), matches(RegExp(r'^Ready \d\d:\d\d · took 1:4[12]$')));
    });

    test('fetches say how many megabytes of how many', () {
      final j = partsJobs.add(4);
      partsJobs.stage(4, PartsStage.fetching);
      partsJobs.progress(4, 0.5, bytes: 3 * 1048576 + 104858, total: 8 * 1048576);
      expect(stageLine(j), 'Fetching the record · 3.1 of 8.0 MB');
      partsJobs.stage(4, PartsStage.gettingSeparator);
      partsJobs.progress(4, null, bytes: 12 * 1048576);
      expect(stageLine(j), 'Getting the separator · 12 MB');
    });
  });
}
