// What a song is made of in time, on this side of the wire.
//
// Which beat the music is on and how far through it; where the sound ends, when that is
// worth knowing; and that a song's timing is asked for once — but asked for again after
// a failure, because "the network was down" is not something to remember about a song.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/timing.dart';

void main() {
  test('which beat the music is on, and how far through it', () {
    final t = TrackTiming(
        durationMs: 10000, beats: [for (var i = 0; i < 12; i++) 1000 + i * 500]);
    expect(t.beatAt(const Duration(milliseconds: 500)), isNull, reason: 'before the first');
    expect(t.beatAt(const Duration(milliseconds: 1000))!.index, 0);
    expect(t.beatAt(const Duration(milliseconds: 1000))!.phase, 0);
    final mid = t.beatAt(const Duration(milliseconds: 2750))!;
    expect(mid.index, 3);
    expect(mid.phase, closeTo(0.5, 1e-9));
    expect(t.beatAt(const Duration(milliseconds: 6500)), isNull, reason: 'after the last');

    // A song with no pulse has no beat to be on.
    expect(const TrackTiming(durationMs: 10000).beatAt(const Duration(seconds: 3)), isNull);
  });

  test('where the sound ends, when there is dead air after it', () {
    expect(const TrackTiming(durationMs: 200000, tailMs: 2200).soundEnds,
        const Duration(milliseconds: 197800));
    expect(const TrackTiming(durationMs: 200000).soundEnds, isNull,
        reason: 'nothing to skip: the file is played to its end');
    expect(const TrackTiming(tailMs: 2200).soundEnds, isNull, reason: 'length not known');
  });

  test('read as the server sends it', () {
    final t = TrackTiming.fromJson({
      'duration_ms': 221000, 'lead_ms': 0, 'tail_ms': 750, 'bpm': 120.0,
      'beats': [480, 980, 1480, 1980, 2480, 2980, 3480, 3980],
      'bar_starts_on': 2, 'ends': 'fade',
    });
    expect(t.bpm, 120);
    expect(t.hasBeats, isTrue);
    expect(t.barStartsOn, 2);
    expect(t.lead, Duration.zero);
  });

  test('asked for once, and asked again after a failure', () async {
    var asked = 0, broken = true;
    useThisClientInstead(MockClient((request) async {
      asked++;
      if (broken) return http.Response('nope', 503);
      return http.Response(jsonEncode({'duration_ms': 60000, 'tail_ms': 1200}), 200,
          headers: {'content-type': 'application/json'});
    }));
    addTearDown(() => useThisClientInstead(http.Client()));
    final store = TimingStore(ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    const song = Track(
        id: 5,
        title: 'A',
        artists: ['B'],
        state: 'ready',
        source: 'youtube',
        displayTitle: 'A',
        streamPath: '/tracks/5/stream');

    expect(await store.of(song), isNull);
    expect(store.peek(5), isNull);
    broken = false;
    // Two at once are one request.
    final both = await Future.wait([store.of(song), store.of(song)]);
    expect(both.first!.tailMs, 1200);
    expect(asked, 2, reason: 'the failure, then one for the pair');
    await store.of(song);
    expect(asked, 2, reason: 'and never again');
    expect(store.peek(5)!.soundEnds, const Duration(milliseconds: 58800));

    // A song that is not here yet has no timing to ask for.
    const pending = Track(
        id: 6, title: 'A', artists: ['B'], state: 'pending', source: 'youtube', displayTitle: 'A');
    expect(await store.of(pending), isNull);
    expect(asked, 2);
  });

  test('a crate waits its turn behind a busy house, two at a time, and asks again', () async {
    var inFlight = 0, most = 0, asked = 0;
    final busyOnce = <int>{};
    useThisClientInstead(MockClient((request) async {
      final id = int.parse(request.url.pathSegments[1]);
      asked++;
      inFlight++;
      if (inFlight > most) most = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      inFlight--;
      if (id.isOdd && busyOnce.add(id)) {
        return http.Response(jsonEncode({'detail': 'busy: try again shortly'}), 503,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode({'duration_ms': 60000, 'bpm': 120 + id}), 200,
          headers: {'content-type': 'application/json'});
    }));
    addTearDown(() => useThisClientInstead(http.Client()));
    final store = TimingStore(ApiClient(baseUrl: 'http://example.invalid')..token = 'x',
        busyWait: const Duration(milliseconds: 10));
    final crate = [
      for (var i = 1; i <= 8; i++)
        Track(id: i, title: 'A', artists: const ['B'], state: 'ready', source: 'youtube',
            displayTitle: 'A', streamPath: '/tracks/$i/stream'),
    ];
    final got = await Future.wait([for (final t in crate) store.later(t)]);
    expect([for (final g in got) g?.bpm], [for (var i = 1; i <= 8; i++) 120.0 + i],
        reason: 'every record, the busy ones asked again');
    expect(most, lessThanOrEqualTo(2), reason: 'never more than two asks at once');
    expect(asked, 12, reason: 'eight, and the four told to come back once more');
  });

  test("a crate's tempo and key come in one ask", () async {
    final asks = <String>[];
    useThisClientInstead(MockClient((request) async {
      asks.add(request.url.queryParameters['ids'] ?? '');
      return http.Response(jsonEncode({'traits': {
        '1': {'bpm': 124.0, 'camelot': '8A', 'key_confidence': 0.8},
        '2': {'bpm': 96.0, 'camelot': null, 'key_confidence': 0.0},
      }}), 200, headers: {'content-type': 'application/json'});
    }));
    addTearDown(() => useThisClientInstead(http.Client()));
    final store = FactsStore(ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    Track t(int id) => Track(id: id, title: 'A', artists: const ['B'], state: 'ready',
        source: 'youtube', displayTitle: 'A', streamPath: '/tracks/$id/stream');
    final got = await Future.wait([store.of(t(1)), store.of(t(2)), store.of(t(3))]);
    expect(asks, ['1,2,3'], reason: 'one ask for the lot');
    expect(got[0]!.camelot, '8A');
    expect(got[1]!.bpm, 96.0);
    expect(got[2], isNull, reason: 'one the house has not measured');
    await store.of(t(1));
    await store.of(t(3));
    expect(asks.length, 1, reason: 'known, and an unmeasured one not asked again at once');
    expect(camelotNear('8A', '9A'), isTrue);
    expect(camelotNear('12A', '1A'), isTrue);
    expect(camelotNear('8A', '8B'), isTrue);
    expect(camelotNear('8A', '2B'), isFalse);
    expect(camelotNear(null, '8A'), isFalse);
  });
}
