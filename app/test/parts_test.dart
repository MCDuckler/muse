// Which machine takes a record apart.
//
// Two can: this computer, where there is a computer, and the server, which does it
// for everybody. A desk should use its own — it is quicker than the box and never
// queues behind the rest of the house — and everything else has to ask. What is
// checked here is the choosing, the falling back when a desk cannot after all, and
// that a part made here is played from the disk rather than fetched again.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ApiClient api;
  late List<String> asked;

  setUp(() {
    // A desk with a graphics card: it takes its own records apart (PartsStore).
    PartsStore.bestHere = () => true;
    forgetHere();
    dir = Directory.systemTemp.createTempSync('muse-parts-');
    partsDirForTesting = dir.path;
    api = ApiClient(baseUrl: 'http://example.invalid')..token = 'x';
    asked = [];
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
    debugDefaultTargetPlatformOverride = null;
    renderer = defaultRenderer;
    useThisClientInstead(http.Client());
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a phone has only the server to ask', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final parts = PartsStore(api);
    expect(parts.separatesHere, isFalse);
    expect(await parts.want(song(1), 'drums'), Stem.beingMade);
    expect(asked.any((p) => p.contains('/stem/drums')), isTrue,
        reason: 'it went to the house, because there is nowhere else');
    expect(parts.pathFor(1, 'drums'), isNull);
  });

  test('a desk takes the record apart itself, and plays what it made', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    // The record is already kept on this device, so nothing is fetched to do it.
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    expect(parts.separatesHere, isTrue);

    final made = <String>[];
    renderer = (audio, name, into) async {
      made.add('$audio -> $name');
      for (final f in into.values) {
        File(f).writeAsBytesSync([1, 2, 3]);
      }
    };

    expect(await parts.want(song(1), 'drums'), Stem.beingMade,
        reason: 'it is being made here, which takes a moment');
    for (var i = 0; i < 200 && makingHere(1, 'drums'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(made, ['${kept.path} -> drums']);

    expect(await parts.want(song(1), 'drums'), Stem.ready);
    expect(parts.pathFor(1, 'drums'), isNotNull);
    expect(File(parts.pathFor(1, 'drums')!).existsSync(), isTrue);

    // And the other half came out of the same pass, so nobody waits for it twice.
    expect(await parts.want(song(1), 'music'), Stem.ready);
    expect(made.length, 1, reason: 'one pass, both halves');

    expect(asked.where((p) => p.contains('/stem/')).length, 1,
        reason: 'the house was asked once whether it had them, and did not');
  });

  test('a desk without a graphics card leaves it to the pool', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    PartsStore.bestHere = () => false;
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    var made = 0;
    renderer = (audio, name, into) async => made++;
    expect(await parts.want(song(1), 'drums'), Stem.beingMade);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(made, 0, reason: 'a computer with a card is asked first');
    expect(partsJobs.of(1)?.stage, PartsStage.pooled);
    // Handed in by another computer: ready, from the house.
    parts.partsArrived(1);
    expect(partsJobs.of(1)?.stage, PartsStage.ready);
  });

  test('a desk that cannot do it after all falls back to the house', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    // No ffmpeg on this computer, say.
    renderer = (audio, name, into) async => throw StateError('no ffmpeg here');

    // The first ask starts the render, which fails quietly in the background.
    await parts.want(song(1), 'drums');
    for (var i = 0; i < 200 && makingHere(1, 'drums'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Nothing was made, so the next ask reaches the server rather than promising
    // for ever a part that is never coming.
    expect(await parts.want(song(1), 'drums'), Stem.beingMade);
    expect(parts.pathFor(1, 'drums'), isNull);
    expect(asked.any((p) => p.contains('/stem/drums')), isTrue);
  });

  test('a set is not a record, whichever machine is asked', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final parts = PartsStore(api, offlinePath: (id) => null);
    expect(await parts.want(song(1, durationMs: (upToSeconds + 1) * 1000), 'drums'),
        Stem.never);
    expect(asked.any((p) => p.contains('/stem/')), isFalse,
        reason: 'no point asking anybody');
  });

  test('a deck plays a part this computer made, straight off the disk', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final booth = Booth(api, offlinePath: (id) => kept.path);
    addTearDown(booth.dispose);
    await booth.init();
    renderer = (a, name, into) async {
      for (final f in into.values) {
        File(f).writeAsBytesSync([1, 2, 3]);
      }
    };

    await booth.load(booth.a, song(1));
    await booth.a.swapTo('drums');           // being made
    for (var i = 0; i < 200 && makingHere(1, 'drums'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await booth.a.swapTo('drums'), isTrue);
    expect(audio.players.values.expand((p) => p.sources).last, startsWith('file://'),
        reason: 'the part is on this disk; there is nothing to fetch');
  });

  test('a record asked for ahead of time is left to the pool, asked for as "soon"', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    var made = 0;
    renderer = (audio, name, into) async => made++;
    final queries = <String>[];
    useThisClientInstead(MockClient((r) async {
      if (r.url.path.contains('/stream-key')) {
        return http.Response('{"key": "k", "expires_at": 99999999999}', 200);
      }
      if (r.url.path.contains('/stem/')) {
        queries.add(r.url.query);
        return http.Response('', 202);
      }
      return http.Response('{}', 200);
    }));
    expect(await parts.want(song(1), 'stems', soon: true), Stem.beingMade);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(made, 0, reason: "not in this computer's line ahead of what it is about to play");
    expect(partsJobs.of(1)?.stage, PartsStage.pooled);
    expect(queries.single, contains('soon=true'));
  });

  test("a deck's old record waiting in line goes back to the pool", () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final kept = File('${dir.path}/song.m4a')..writeAsBytesSync([0]);
    final parts = PartsStore(api, offlinePath: (id) => kept.path);
    final started = <int>[];
    final hold = Completer<void>();
    renderer = (audio, name, into) async {
      started.add(int.parse(into.values.first.split('/').last.split('-').first));
      await hold.future;
    };
    await parts.want(song(1), 'drums'); // in hand
    await parts.want(song(2), 'drums'); // waiting
    await parts.want(song(3), 'drums'); // waiting
    await Future<void>.delayed(const Duration(milliseconds: 20));
    parts.backToPool(song(2));
    expect(partsJobs.of(2)?.stage, PartsStage.pooled);
    // And the line is taken in the order the automix says.
    parts.inOrder([3]);
    hold.complete();
    for (var i = 0; i < 100 && started.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started, [1, 3]);
  });
}
