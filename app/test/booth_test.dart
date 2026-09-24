import 'dart:async';
// Two records on the deck: the sums a mixer does, checked against a fake engine.
//
// The screen for this is not here yet; what is here is the engine — the fader's
// curve, sync, where the next downbeat is, what a transition does and when — and
// those are the parts that are hard to hear wrong and easy to prove right.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/automix.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/booth/mixer_desktop.dart';

import 'fake_audio.dart';

/// A pulse: a beat every [ms] milliseconds for a minute, bars starting on the first.
TrackTiming grid(int ms, {int barStartsOn = 0}) => TrackTiming(
      durationMs: 60000,
      bpm: 60000 / ms,
      beats: [for (var t = 0; t < 60000; t += ms) t],
      barStartsOn: barStartsOn,
    );

Track song(int id) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'duration_ms': 60000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

/// A mixer that only writes down what it was told.
class NotedMixer extends Mixer {
  /// Which deck said it was about to make its player, in the order they said it.
  final claims = <String>[];
  final levels = <Map<String, double>>[];
  final kills = <(String, EqSet)>[];
  @override
  bool get canKill => true;
  @override
  bool get canFilter => false;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    this.levels.add({for (final e in levels.entries) e.key.name: e.value});
  }

  @override
  void expecting(String deck) => claims.add(deck);

  @override
  Future<void> setEq(Deck deck, EqSet eq) async {
    kills.add((deck.name, eq));
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

void main() {
  analysisModel();
  autoMixRules();
  test('a desk\'s kills and filter are one mpv chain', () {
    const off = EqSet.flat;
    expect(DesktopMixer.chain(eq: off, filter: 0), '', reason: 'nothing wanted: no filters');
    expect(DesktopMixer.chain(eq: const EqSet(low: EqSet.killed), filter: 0),
        'lavfi=[lowshelf=f=250:g=-40.0]');
    expect(
        DesktopMixer.chain(
            eq: const EqSet(low: EqSet.killed, mid: EqSet.killed, high: EqSet.killed),
            filter: 0),
        contains('equalizer=f=1000'));
    expect(DesktopMixer.chain(eq: const EqSet(mid: -6), filter: 0),
        'lavfi=[equalizer=f=1000:width_type=o:width=2:g=-6.0]',
        reason: 'a knob turned down a little, not a kill');
    expect(DesktopMixer.chain(eq: off, filter: -1), 'lavfi=[lowpass=f=60]');
    expect(DesktopMixer.chain(eq: off, filter: 1), 'lavfi=[highpass=f=8000]');
    expect(DesktopMixer.chain(eq: off, filter: -0.5), contains('lowpass=f='));
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (c) async => null);

  test('the fader is equal power: neither end louder, the middle not quieter', () {
    final ends = Booth.levelsFor(0);
    expect(ends.a, closeTo(1, 1e-9));
    expect(ends.b, closeTo(0, 1e-9));
    final mid = Booth.levelsFor(0.5);
    expect(mid.a, closeTo(0.7071, 1e-3));
    expect(mid.b, closeTo(0.7071, 1e-3));
    // The energy adds up to the same everywhere along the travel.
    for (final x in [0.1, 0.3, 0.5, 0.8]) {
      final l = Booth.levelsFor(x);
      expect(l.a * l.a + l.b * l.b, closeTo(1, 1e-9));
    }
  });

  test('sync closes a small gap, halves or doubles a big one, refuses a wrong one', () {
    expect(Booth.syncRatio(120, 126), closeTo(1.05, 1e-9));
    expect(Booth.syncRatio(126, 120), closeTo(120 / 126, 1e-9));
    // 70 against 140 is the same tempo said twice.
    expect(Booth.syncRatio(140, 70), closeTo(1, 1e-9));
    expect(Booth.syncRatio(72, 140), closeTo(140 / 2 / 72, 1e-9));
    // Nine per cent is a different record.
    expect(Booth.syncRatio(120, 131), isNull);
    expect(Booth.syncRatio(0, 120), isNull);
  });

  group('with a fake engine', () {
    late FakeJustAudio audio;
    late ApiClient api;
    late NotedMixer mixer;
    late Booth booth;

    setUp(() async {
      audio = FakeJustAudio();
      JustAudioPlatform.instance = audio;
      api = ApiClient(baseUrl: 'http://example.invalid')..token = 'x';
      mixer = NotedMixer();
      booth = Booth(api, mixer: mixer);
      await booth.init();
    });

    tearDown(() => booth.dispose());

    test('each deck says which it is as its record goes on, never before', () async {
      // A browser makes the thing that plays a record when the record is handed to
      // it, so a claim made any earlier is a claim for an element that does not
      // exist — and the next one made is claimed by the wrong deck.
      expect(mixer.claims, isEmpty, reason: 'nothing has been loaded yet');
      await booth.load(booth.a, song(1));
      expect(mixer.claims, ['A']);
      await booth.load(booth.b, song(2));
      expect(mixer.claims, ['A', 'B']);
    });

    test('a part goes on the platter in the record\'s place, or says it is being made',
        () async {
      // The server makes a part the first time anybody asks and answers 202 until it
      // has. A deck told to swap to one that is not made yet keeps playing the record
      // — going quiet would be the worst of the three possible answers.
      bool? made = false;   // false: being made. true: there. null: never.
      useThisClientInstead(MockClient((r) async {
        if (r.url.path.contains('/stream-key')) {
          return http.Response(
              '{"key": "signed", "expires_at": 99999999999}', 200);
        }
        if (r.url.path.contains('/stem/')) {
          if (made == null) return http.Response('too long to take apart', 404);
          return made ? http.Response('x', 206) : http.Response('', 202);
        }
        return http.Response('{}', 200);
      }));
      addTearDown(() => useThisClientInstead(http.Client()));

      await booth.load(booth.a, song(1));
      await booth.a.play();
      expect(await booth.a.swapTo('drums'), isFalse, reason: 'not made yet');
      expect(booth.a.part, isNull, reason: 'the record is still on');
      expect(booth.a.playing, isTrue, reason: 'and still playing');

      made = true;
      expect(await booth.a.swapTo('drums'), isTrue);
      expect(booth.a.part, 'drums');
      expect(audio.players.values.expand((p) => p.sources),
          contains(contains('/tracks/1/stem/drums')));
      expect(booth.a.playing, isTrue, reason: 'a swap is not a stop');

      // A record too long to take apart says so once, and keeps saying so rather
      // than promising a part in a minute for ever.
      made = null;
      expect(await booth.a.swapTo('music'), isFalse);
      expect(booth.a.noParts, isTrue);
      expect(booth.a.part, 'drums', reason: 'what was on stays on');

      // And back to the record it was made from.
      expect(await booth.a.swapTo(null), isTrue);
      expect(audio.players.values.expand((p) => p.sources),
          contains(contains('/tracks/1/stream')));
    });

    test('two records going on at once do not claim each other\'s player', () async {
      // Started together, finished in order: the claim and the load it belongs to
      // are never separated by the other deck's.
      await Future.wait([
        booth.load(booth.a, song(1)),
        booth.load(booth.b, song(2)),
      ]);
      expect(mixer.claims, ['A', 'B']);
      expect(booth.a.track?.id, 1);
      expect(booth.b.track?.id, 2);
    });

    test('a record nobody has analysed is still mixed out of', () async {
      // No timing at all: the booth used to wait for a moment it could not work out,
      // which is a queue that plays one record and stops.
      await booth.auto.start([song(1), song(2)]);
      expect(booth.auto.goesAt, isNotNull,
          reason: 'its own length, less the transition');
      expect(booth.auto.plan?.kind, Transition.fade, reason: 'no grid, no blend');
      booth.auto.stop();
    });

    test('two records are two players', () async {
      expect(booth.master.name, 'A', reason: 'nothing playing: A leads');
      await booth.load(booth.a, song(1));
      await booth.load(booth.b, song(2));
      expect(audio.players.length, 2, reason: 'a deck each');
      expect(booth.a.loaded && booth.b.loaded, isTrue);
    });

    test('a deck keeps its own clock between the engine\'s reports', () async {
      final deck = booth.a;
      await deck.load(song(1), timing: grid(500));
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      deck.anchor(const Duration(seconds: 10), t0);
      expect(deck.positionAt(t0.add(const Duration(seconds: 2))), const Duration(seconds: 10),
          reason: 'parked: nothing moves');
      await deck.play();
      deck.anchor(const Duration(seconds: 10), t0);
      expect(deck.positionAt(t0.add(const Duration(seconds: 2))), const Duration(seconds: 12));
      await deck.setTempo(1.05);
      deck.anchor(const Duration(seconds: 10), t0);
      expect(deck.positionAt(t0.add(const Duration(seconds: 2))).inMilliseconds,
          closeTo(12100, 2), reason: 'faster tempo, further along');
    });

    test('the next downbeat is counted from where the bar starts', () async {
      final deck = booth.a;
      await deck.load(song(1), timing: grid(500, barStartsOn: 1));
      // Beats at 0, 500, 1000, 1500…; bars start on beat 1, so downbeats are at
      // 500, 2500, 4500…
      expect(deck.nextBeat(const Duration(milliseconds: 1200)), const Duration(milliseconds: 1500));
      expect(deck.nextBeat(const Duration(milliseconds: 1200), every: 4),
          const Duration(milliseconds: 2500));
      expect(deck.nextBeat(const Duration(milliseconds: 2500), every: 4),
          const Duration(milliseconds: 2500), reason: 'on it already');
    });

    test('how long until the master\'s next bar, by the clock, at its tempo', () async {
      final deck = booth.a;
      await deck.load(song(1), timing: grid(500));
      await deck.play();
      await deck.setTempo(2.0);
      final t0 = DateTime(2026, 1, 1, 12);
      deck.anchor(const Duration(milliseconds: 1200), t0);
      // Next downbeat at 2000 in the file: 800 ms of record, 400 ms of clock.
      expect(deck.untilNextBeat(t0, every: 4), const Duration(milliseconds: 400));
      await deck.pause();
      expect(deck.untilNextBeat(t0, every: 4), isNull, reason: 'a parked record has no next beat');
    });

    test('sync sets the other deck\'s tempo to the master\'s', () async {
      await booth.load(booth.a, song(1));
      booth.a.timing = grid(500);          // 120
      await booth.load(booth.b, song(2));
      booth.b.timing = grid(480);          // 125
      await booth.a.play();
      expect(await booth.sync(booth.b), isTrue);
      expect(booth.b.tempo, closeTo(120 / 125, 1e-9));
      expect(booth.b.bpm, closeTo(120, 1e-6));
    });

    test('a blend is written down: bass swapped half way, the fader crossed by the end',
        () {
      final steps = Booth.plan(Transition.blend, from: 'A', to: 'B');
      expect(steps.first.decks['B']?.eq?.lowKilled, isTrue,
          reason: 'the incoming enters without bass');
      final half = steps.firstWhere((s) => s.at == 0.5);
      expect(half.decks['B']?.eq?.lowKilled, isFalse);
      expect(half.decks['A']?.eq?.lowKilled, isTrue,
          reason: 'the bass swaps at the middle');
      expect(steps.last.crossfader, 1);
      expect(steps.last.decks['A']?.eq?.isFlat, isTrue,
          reason: 'the outgoing is left clean for next time');
    });

    test('a cut hands over and the other deck becomes the master', () async {
      await booth.load(booth.a, song(1));
      await booth.load(booth.b, song(2));
      await booth.a.play();
      await booth.go(Transition.cut);
      expect(booth.master.name, 'B');
      expect(booth.crossfader, 1);
      expect(booth.b.playing, isTrue);
      expect(booth.a.playing, isFalse);
      expect(mixer.levels.last, {'A': closeTo(0, 1e-9), 'B': closeTo(1, 1e-9)});
    });

    test('the booth mixes a queue on its own: out at the outro, the next one loaded',
        () async {
      // A fast grid so a four-bar fade is a moment: 1200 bpm, a bar is 200 ms.
      TrackTiming quick(int id) => TrackTiming(
            durationMs: 60000,
            bpm: 1200,
            beats: [for (var i = 0; i < 1200; i++) i * 50],
            downbeats: [for (var i = 0; i < 1200; i += 4) i * 50],
            // Sections every four bars from the fourth: the outro cue is on one.
            fourBars: [for (var i = 12; i < 1200; i += 16) i * 50],
            ends: 'fade',
            cues: const MixCues(firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 3000, soundEndMs: 59000),
          );
      // The timing store is asked for each; the API is not there, so hand them in.
      final tracks = [song(1), song(2), song(3)];
      for (final t in tracks) {
        booth.timing.put(t.id, quick(t.id));
      }
      await booth.auto.start(tracks);
      expect(booth.auto.running, isTrue);
      expect(booth.master.track?.id, 1);
      expect(booth.other(booth.master).track?.id, 2, reason: 'the next is on the free deck');
      expect(booth.auto.plan?.kind, Transition.fade, reason: 'a record that fades itself');
      expect(booth.auto.goesAt, const Duration(seconds: 3));

      // The outgoing reaches its outro.
      await booth.master.seek(const Duration(milliseconds: 3100));
      for (var i = 0; i < 40 && booth.master.track?.id == 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(booth.master.track?.id, 2, reason: 'the transition ran and handed over');
      expect(booth.other(booth.master).track?.id, 3, reason: 'and the one after is loaded');
      booth.auto.stop();
      expect(booth.auto.running, isFalse);
    });

    test('what the booth does is written down, and a kept mix is done again', () async {
      await booth.load(booth.a, song(1));
      await booth.load(booth.b, song(2));
      await booth.a.play();
      await booth.b.seek(const Duration(seconds: 5));
      await booth.go(Transition.cut);
      expect(booth.taken.length, 1);
      final move = booth.taken.single;
      expect((move.from, move.to, move.kind), (1, 2, Transition.cut));
      expect(move.inMs, 5000, reason: 'where the incoming was parked');
      expect(booth.takenTrackIds, [1, 2]);
      // Round trip through what a playlist carries.
      final again = MixMove.allIn({'version': 1, 'transitions': [move.toJson()]});
      expect(again.single.toJson(), move.toJson());

      // Done again: the kept move is followed rather than decided.
      TrackTiming quick() => TrackTiming(
            durationMs: 60000, bpm: 1200,
            beats: [for (var i = 0; i < 1200; i++) i * 50],
            downbeats: [for (var i = 0; i < 1200; i += 4) i * 50],
            cues: const MixCues(firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 30000, soundEndMs: 59000),
          );
      booth.timing.put(1, quick());
      booth.timing.put(2, quick());
      final kept = [
        const MixMove(from: 1, to: 2, kind: Transition.fade, bars: 4, outMs: 4000, inMs: 7000, tempo: 1.03),
      ];
      await booth.auto.start([song(1), song(2)], kept: kept);
      expect(booth.auto.replaying, isTrue);
      expect(booth.auto.plan, (kind: Transition.fade, bars: 4), reason: 'as kept, not as the rules say');
      expect(booth.auto.goesAt, const Duration(seconds: 4));
      expect(booth.other(booth.master).position, const Duration(seconds: 7));
      expect(booth.other(booth.master).tempo, closeTo(1.03, 1e-9));
      booth.auto.stop();
    });

    test('choosing for itself brings the best of what is left forward', () async {
      TrackTiming at(double bpm, String camelot) => TrackTiming(
            durationMs: 60000,
            bpm: bpm,
            beats: [for (var i = 0; i < 1200; i++) i * 50],
            downbeats: [for (var i = 0; i < 1200; i += 4) i * 50],
            camelot: camelot,
            cues: const MixCues(
                firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 40000, soundEndMs: 59000),
          );
      booth.timing.put(1, at(124, '8A'));
      booth.timing.put(2, at(150, '3B'));      // neither in tempo nor in key
      booth.timing.put(3, at(125, '9A'));      // both
      await booth.auto.start([song(1), song(2), song(3)]);
      expect(booth.auto.next?.id, 2, reason: 'the queue as it stands');

      booth.auto.chooseForYourself(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(booth.auto.next?.id, 3, reason: 'the one that follows best');
      expect(booth.auto.after?.id, 2, reason: 'and nothing is dropped');
      booth.auto.stop();
    });

    test('a queue changing under the automix loads the free deck once, with the last word',
        () async {
      for (final id in [1, 2, 3, 4, 5]) {
        booth.timing.put(id, grid(500));
      }
      // A house slow to answer, as it is when it is busy: every question takes a while.
      useThisClientInstead(MockClient((r) async {
        if (r.url.path.contains('/stream-key')) {
          return http.Response('{"key": "signed", "expires_at": 99999999999}', 200);
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (r.url.path.contains('/stem/')) return http.Response('', 202);
        return http.Response('{}', 200);
      }));
      addTearDown(() => useThisClientInstead(http.Client()));
      await booth.auto.start([song(1), song(2)]);
      final free = booth.other(booth.master);
      final loadsBefore = audio.players.values.expand((p) => p.sources).length;
      // Records arriving one after another, each a new "next", before any preparation
      // has had time to finish.
      final asked = [
        for (final next in [3, 4, 5]) booth.auto..follow([song(1), song(next), song(2)]),
      ];
      expect(asked, hasLength(3));
      for (var i = 0; i < 200 && free.track?.id != 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(booth.auto.next?.id, 5);
      expect(free.track?.id, 5, reason: 'the last word is what is on the deck');
      final loads = audio.players.values.expand((p) => p.sources).length - loadsBefore;
      expect(loads, lessThanOrEqualTo(2),
          reason: 'not a load for every change: the one in hand, then the last');
      booth.auto.stop();
    });

    test('a preparation stuck on the house does not stop the mix going', () async {
      TrackTiming quick() => TrackTiming(
            durationMs: 60000,
            bpm: 1200,
            beats: [for (var i = 0; i < 1200; i++) i * 50],
            downbeats: [for (var i = 0; i < 1200; i += 4) i * 50],
            cues: const MixCues(
                firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 40000, soundEndMs: 59000),
          );
      for (final id in [1, 2, 3]) {
        booth.timing.put(id, quick());
      }
      var stuck = false;
      final never = Completer<http.Response>();
      useThisClientInstead(MockClient((r) async {
        if (r.url.path.contains('/stream-key')) {
          return http.Response('{"key": "signed", "expires_at": 99999999999}', 200);
        }
        if (stuck && r.url.path.contains('/stem/')) return never.future;
        if (r.url.path.contains('/stem/')) return http.Response('', 202);
        return http.Response('{}', 200);
      }));
      addTearDown(() => useThisClientInstead(http.Client()));
      await booth.auto.start([song(1), song(2), song(3)]);
      expect(booth.auto.next?.id, 2);
      // The house stops answering, and the queue changes: a preparation that hangs.
      stuck = true;
      booth.auto.follow([song(1), song(3), song(2)]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await booth.auto.mixNow();
      for (var i = 0; i < 60 && booth.master.track?.id == 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.master.track?.id, isNot(1), reason: 'it went all the same');
      booth.auto.stop();
      never.complete(http.Response('', 202));
    });

    test('a hand steers the plan: another move, longer, later, and back to the Auto DJ',
        () async {
      // Two records of four minutes at 128, a phrase grid and a drop in the second.
      TrackTiming record({List<int> drops = const []}) {
        const beat = 469;
        final beats = [for (var i = 0; i < 480; i++) i * beat];
        final downs = [for (var i = 0; i < beats.length; i += 4) beats[i]];
        return TrackTiming(
          durationMs: 240000,
          bpm: 60000 / beat,
          beats: beats,
          downbeats: downs,
          camelot: '8A',
          drops: [for (final d in drops) downs[d]],
          energy: [for (var i = 0; i < 120; i++) 200],
          cues: MixCues(
              firstDownbeatMs: 0, mixInMs: downs[32], mixOutMs: downs[88], soundEndMs: downs[119]),
        );
      }

      Track long(int id) => Track.fromJson({
            'id': id,
            'title': 'Long $id',
            'artists': ['Someone'],
            'duration_ms': 240000,
            'state': 'ready',
            'stream_url': '/tracks/$id/stream',
            'source': 'youtube',
          });
      final was = FakeAudioPlayer.trackLength;
      FakeAudioPlayer.trackLength = const Duration(minutes: 4);
      addTearDown(() => FakeAudioPlayer.trackLength = was);
      booth.timing.put(1, record());
      booth.timing.put(2, record(drops: [48]));
      booth.timing.put(3, record());
      final auto = booth.auto;
      await auto.start([long(1), long(2), long(3)]);
      for (var i = 0; i < 100 && auto.planned == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(auto.planned, isNotNull, reason: 'a plan to show');
      expect(auto.options.length, greaterThan(1), reason: 'and what else it weighed');
      expect(auto.canSteer, isTrue);
      expect(auto.steered, isFalse);

      // Another of the moves it weighed.
      final other = auto.options.firstWhere((o) => o.kind != auto.planned!.kind);
      await auto.steer(other);
      expect(auto.plan?.kind, other.kind);
      expect(auto.steered, isTrue);

      // Longer.
      await auto.lengthen(32);
      expect(auto.plan?.bars, 32);
      expect(auto.planned?.kind, other.kind, reason: 'the same move, longer');

      // A phrase later out of the old record.
      final out = auto.goesAt!;
      await auto.nudgeOut(1);
      final bar = booth.master.timing!.bar!;
      expect(auto.goesAt! - out, bar * 4);

      // The queue moving does not undo the hand: the same pair, the same choice.
      auto.follow([long(1), long(2), long(3)]);
      auto.mixLike(MixStyle.bold);
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(auto.plan?.kind, other.kind);
      expect(auto.plan?.bars, 32);
      expect(auto.goesAt! - out, bar * 4);

      // Back to the Auto DJ's own choice.
      await auto.letThePlannerChoose();
      expect(auto.steered, isFalse);
      auto.stop();
    });

    test('choosing for itself, a queue that keeps refreshing does not unmake its choice',
        () async {
      TrackTiming at(double bpm, String camelot) => TrackTiming(
            durationMs: 60000,
            bpm: bpm,
            beats: [for (var i = 0; i < 1200; i++) i * 50],
            downbeats: [for (var i = 0; i < 1200; i += 4) i * 50],
            camelot: camelot,
            cues: const MixCues(
                firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 40000, soundEndMs: 59000),
          );
      booth.timing.put(1, at(124, '8A'));
      booth.timing.put(2, at(150, '3B'));
      booth.timing.put(3, at(125, '9A'));
      await booth.auto.start([song(1), song(2), song(3)]);
      booth.auto.chooseForYourself(true);
      for (var i = 0; i < 50 && booth.auto.next?.id != 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(booth.auto.next?.id, 3);
      int picks() => booth.events.where((e) => e.text.startsWith('Picked')).length;
      final picked = picks();
      // The queue refreshed again and again, in its own order, as the server sends it.
      for (var i = 0; i < 10; i++) {
        booth.auto.follow([song(1), song(2), song(3)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (var i = 0; i < 100 && booth.auto.working != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(booth.auto.next?.id, 3, reason: 'still the one it chose');
      expect(picks(), picked, reason: 'not chosen again — and planned again — every refresh');
      expect(booth.auto.working, isNull, reason: 'and the plan for it finished');
      expect(booth.auto.plan, isNotNull);
      booth.auto.stop();
    });

    TrackTiming quickAt(double bpm) {
      final ms = 60000 / bpm;
      return TrackTiming(
        durationMs: 60000,
        bpm: bpm,
        beats: [for (var i = 0; i < 1000; i++) (i * ms).round()],
        downbeats: [for (var i = 0; i < 1000; i += 4) (i * ms).round()],
        cues: const MixCues(firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 40000, soundEndMs: 59000),
      );
    }

    test('after a mix the new master eases back to its own tempo', () async {
      // Twelve hundred and twelve hundred and sixty a minute: five percent apart, a
      // bar a fifth of a second. Bold: the glide is eight bars, under two seconds.
      booth.timing.put(1, quickAt(1200));
      booth.timing.put(2, quickAt(1260));
      final auto = booth.auto;
      auto.mixLike(MixStyle.bold);
      await auto.start([song(1), song(2)]);
      final incoming = booth.other(booth.master);
      expect(incoming.pitch, closeTo(1200 / 1260, 0.002), reason: 'matched to the master');
      await auto.mixNow();
      for (var i = 0; i < 100 && booth.master.track?.id != 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.master.track?.id, 2);
      expect(auto.gliding, isTrue, reason: 'on its way back');
      expect(booth.master.pitch, lessThan(1.0));
      for (var i = 0; i < 100 && auto.gliding; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(auto.gliding, isFalse);
      expect(booth.master.pitch, 1.0, reason: 'its own tempo again');
      auto.stop();
    });

    test('the next record is matched to where the master will settle, not where it is',
        () async {
      booth.timing.put(1, quickAt(1200));
      booth.timing.put(2, quickAt(1260));
      booth.timing.put(3, quickAt(1200));
      final auto = booth.auto;
      auto.mixLike(MixStyle.easy); // a long glide: the next record is laid out during it
      await auto.start([song(1), song(2), song(3)]);
      await auto.mixNow();
      for (var i = 0; i < 100 && booth.master.track?.id != 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.master.track?.id, 2);
      final free = booth.other(booth.master);
      for (var i = 0; i < 100 && (free.track?.id != 3 || auto.goesAt == null); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(auto.gliding, isTrue, reason: 'still gliding while the next is laid out');
      // Record 3 at 1200 must meet record 2's own 1260, so it is pitched up 5 % —
      // not left at 1.0 to meet the 1200 the master is only passing through.
      expect(free.pitch, closeTo(1260 / 1200, 0.002));
      auto.stop();
    });

    test('the moves made lately are the booth\'s own log, by hand or not', () async {
      booth.timing.put(1, quickAt(1200));
      booth.timing.put(2, quickAt(1200));
      await booth.load(booth.a, song(1));
      await booth.load(booth.b, song(2));
      await booth.a.play();
      await booth.go(Transition.roll, bars: 1);
      for (var i = 0; i < 60 && booth.master.track?.id != 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.auto.recent, [Transition.roll], reason: 'a mix by hand counts');
    });

    test('a hand can go now, or drop what is coming', () async {
      TrackTiming quick() => TrackTiming(
            durationMs: 60000,
            bpm: 1200,
            beats: [for (var i = 0; i < 1200; i++) i * 50],
            downbeats: [for (var i = 0; i < 1200; i += 4) i * 50],
            cues: const MixCues(
                firstDownbeatMs: 0, mixInMs: 2000, mixOutMs: 40000, soundEndMs: 59000),
          );
      for (final id in [1, 2, 3]) {
        booth.timing.put(id, quick());
      }
      await booth.auto.start([song(1), song(2), song(3)]);
      expect(booth.auto.next?.id, 2);
      expect(booth.auto.after?.id, 3);
      expect(booth.auto.timeToGo, isNotNull, reason: 'there is a countdown to draw');

      // Not that one: three follows one, and what was next is gone.
      await booth.auto.dropNext();
      expect(booth.auto.next?.id, 3);
      expect(booth.other(booth.master).track?.id, 3, reason: 'and it is on the deck');

      // Now, wherever the record had got to.
      await booth.auto.mixNow();
      for (var i = 0; i < 40 && booth.master.track?.id == 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.master.track?.id, 3, reason: 'it went without waiting for the outro');
      booth.auto.stop();
    });

    test('handing the booth a record it is already playing does not start it again',
        () async {
      booth.timing.put(1, grid(500));
      await booth.load(booth.a, song(1));
      await booth.a.play();
      await booth.a.seek(const Duration(seconds: 20));
      await booth.auto.start([song(1), song(2)], at: 0);
      expect(booth.master.position.inSeconds, greaterThanOrEqualTo(19),
          reason: 'the booth took over mid-song rather than starting it again');
      booth.auto.stop();
    });

    test('the booth carries on from where the first record was', () async {
      booth.timing.put(1, grid(500));
      await booth.auto.start([song(1), song(2)], from: const Duration(seconds: 42));
      expect(booth.master.position.inSeconds, greaterThanOrEqualTo(42));
      booth.auto.stop();
    });

    test('a fade over the bars moves the fader and ends with the other deck', () async {
      await booth.load(booth.a, song(1));
      booth.a.timing = grid(50);           // 1200 bpm: a bar is 200 ms, for a quick test
      await booth.load(booth.b, song(2));
      await booth.a.play();
      await booth.go(Transition.fade, bars: 1);
      expect(booth.master.name, 'B');
      expect(booth.crossfader, 1);
      expect(mixer.levels.length, greaterThan(3), reason: 'the fader moved, not jumped');
      expect(booth.a.playing, isFalse);
    });
  });
}

/// The second half of the analysis, as the app reads it.
void analysisModel() {
  test('a song\'s key, bars, phrases and cues come through', () {
    final t = TrackTiming.fromJson({
      'duration_ms': 200000,
      'bpm': 128.0,
      'beats': [for (var i = 0; i < 64; i++) i * 469],
      'bar_starts_on': 1,
      'key': 'A minor',
      'camelot': '8A',
      'key_confidence': 0.7,
      'downbeats': [469, 2345, 4221],
      'energy': [40, 200, 255],
      'phrases': [469, 4221],
      'cues': {'first_downbeat_ms': 469, 'mix_in_ms': 4221, 'mix_out_ms': 150000, 'sound_end_ms': 198000},
    });
    expect(t.key, 'A minor');
    expect(t.camelot, '8A');
    expect(t.downbeats.length, 3);
    expect(t.cues?.mixIn, const Duration(milliseconds: 4221));
    expect(t.cues?.mixOut, const Duration(milliseconds: 150000));
  });

  test('records a step apart on the wheel are in key; across it they are not', () {
    TrackTiming at(String c) => TrackTiming(camelot: c);
    expect(at('8A').inKeyWith(at('8A')), isTrue);
    expect(at('8A').inKeyWith(at('9A')), isTrue, reason: 'a fifth up');
    expect(at('8A').inKeyWith(at('7A')), isTrue, reason: 'a fifth down');
    expect(at('8A').inKeyWith(at('8B')), isTrue, reason: 'the relative major');
    expect(at('12A').inKeyWith(at('1A')), isTrue, reason: 'the wheel goes round');
    expect(at('8A').inKeyWith(at('2A')), isFalse);
    expect(at('8A').inKeyWith(TrackTiming()), isFalse, reason: 'no key, no claim');
  });
}


/// What the booth decides on its own.
void autoMixRules() {
  TrackTiming t({double? bpm, String ends = '', String? camelot, bool beats = true}) => TrackTiming(
        durationMs: 200000,
        bpm: bpm,
        beats: beats ? [for (var i = 0; i < 400; i++) i * 469] : const [],
        ends: ends,
        camelot: camelot,
        downbeats: beats ? [for (var i = 0; i < 400; i += 4) i * 469] : const [],
        cues: const MixCues(firstDownbeatMs: 469, mixInMs: 15000, mixOutMs: 160000, soundEndMs: 198000),
      );

  test('every move of every way out lands on a bar', () {
    for (final kind in Transition.values) {
      for (final bars in [4, 8, 12, 16, 32]) {
        final steps = MixStep.onBars(Booth.plan(kind, from: 'A', to: 'B'), bars);
        for (final s in steps) {
          final bar = s.at * bars;
          expect((bar - bar.round()).abs(), lessThan(1e-9),
              reason: '${kind.name} over $bars bars: a step at bar $bar');
        }
        // Still in order, first to last.
        for (var i = 1; i < steps.length; i++) {
          expect(steps[i].at, greaterThanOrEqualTo(steps[i - 1].at));
        }
      }
    }
  });

  test('the loud ways out say what they do', () {
    final sweep = Booth.plan(Transition.sweep, from: 'A', to: 'B');
    final climb = [for (final s in sweep) s.decks['A']?.filter].whereType<double>();
    expect(climb.first, 0, reason: 'the filter starts open');
    expect(climb.last, 0, reason: 'and is left open for next time');
    expect(climb.reduce((a, b) => a > b ? a : b), greaterThan(0.7),
        reason: 'and closes right up in between');

    final roll = Booth.plan(Transition.roll, from: 'A', to: 'B');
    final loops = [for (final s in roll) s.decks['A']?.loopBars].whereType<int>().toList();
    expect(loops.first, 2, reason: 'caught at two bars');
    expect(loops.where((b) => b == -1).length, 2, reason: 'halved twice');
    expect(loops.last, 0, reason: 'and let go at the end');

    final brake = Booth.plan(Transition.brake, from: 'A', to: 'B');
    expect(brake.any((s) => s.decks['A']?.brake ?? false), isTrue);
    final stops = brake.firstWhere((s) => s.decks['A']?.brake ?? false);
    expect(stops.crossfader, 1,
        reason: 'the new record is already across before the old one is stopped');
  });

  test('how hard it mixes decides what it reaches for', () {
    TrackTiming t({double bpm = 124, String? camelot, String ends = '', List<int> drops = const []}) =>
        TrackTiming(
          durationMs: 200000,
          bpm: bpm,
          beats: [for (var i = 0; i < 400; i++) i * 469],
          camelot: camelot,
          ends: ends,
          drops: drops,
        );
    final on = t(camelot: '8A');
    // Gentle: long where they agree, and never a loop or a brake.
    expect(AutoMix.choose(on, t(camelot: '9A'), style: MixStyle.easy),
        (kind: Transition.blend, bars: 32));
    expect(AutoMix.choose(on, t(camelot: '3B'), style: MixStyle.easy).kind,
        Transition.fade);
    // Ordinary: a clash goes out through the filter.
    expect(AutoMix.choose(on, t(camelot: '3B')).kind, Transition.sweep);
    expect(AutoMix.choose(on, t(camelot: '9A')).kind, Transition.blend);
    // Bold: something to land on is caught and tightened.
    expect(AutoMix.choose(on, t(camelot: '9A', drops: [40000]), style: MixStyle.bold),
        (kind: Transition.roll, bars: 8));
    expect(AutoMix.choose(on, t(camelot: '3B', drops: [40000]), style: MixStyle.bold).kind,
        Transition.sweep);
    expect(AutoMix.choose(t(camelot: '8A', ends: 'cold'), t(camelot: '3B'),
            style: MixStyle.bold).kind,
        Transition.brake);
    // And a record with no grid is still only ever faded, however bold it is told.
    expect(AutoMix.choose(const TrackTiming(), on, style: MixStyle.bold).kind,
        Transition.fade);

    // With both records in parts, the bold style has the drums change hands: the
    // boldest thing there is. Not the ordinary one: each change of part is a new file
    // on a deck, a gap in the sound on a desk, and a clash is what the filter is for.
    expect(AutoMix.choose(on, t(camelot: '9A', drops: [40000]), style: MixStyle.bold, parts: true),
        (kind: Transition.swap, bars: 16));
    expect(AutoMix.choose(on, t(camelot: '3B'), parts: true).kind, Transition.sweep);
    expect(AutoMix.choose(on, t(camelot: '9A'), parts: true).kind, Transition.blend,
        reason: 'two records that already agree do not need taking apart');
    expect(AutoMix.choose(on, t(camelot: '3B'), style: MixStyle.easy, parts: true).kind,
        Transition.fade, reason: 'gentle is gentle, parts or no parts');
    expect(AutoMix.choose(const TrackTiming(), on, style: MixStyle.bold, parts: true).kind,
        Transition.fade, reason: 'no grid, no swap: there is nothing to line up');
  });

  test('the drums change hands once, and never two sets at a time', () {
    final steps = Booth.plan(Transition.swap, from: 'A', to: 'B');
    String? partAt(double at, String deck) {
      String? part;
      for (final s in steps.where((s) => s.at <= at)) {
        final want = s.decks[deck]?.part;
        if (want != null) part = want;
      }
      return part;
    }

    // B arrives on its drums alone, under A whole.
    expect(partAt(0, 'B'), 'drums');
    expect(partAt(0, 'A'), isNull, reason: 'the record on is the record on');
    // A gives its drums up before B becomes whole, so there is one kick throughout.
    final aLoses = steps.firstWhere((s) => s.decks['A']?.part == 'music').at;
    final bWhole =
        steps.firstWhere((s) => s.decks['B']?.part == DeckStep.whole).at;
    expect(aLoses, lessThan(bWhole));
    expect(partAt(0.5, 'A'), 'music');
    expect(partAt(0.5, 'B'), 'drums');
    expect(partAt(1, 'B'), DeckStep.whole);
    // And each swap happens with the other record over it, never in the clear.
    double faderAt(double at) {
      var x = 0.0;
      for (final s in steps.where((s) => s.at <= at)) {
        if (s.crossfader != null) x = s.crossfader!;
      }
      return x;
    }

    for (final at in [aLoses, bWhole]) {
      expect(faderAt(at), greaterThan(0.2), reason: 'not at the very start');
      expect(faderAt(at), lessThan(0.95), reason: 'not alone at the end');
    }
  });

  test('the incoming is parked so its drop lands where the fader finishes', () {
    // 120 bpm: a bar is 2000 ms. A drop at 60 s, a transition of 8 bars — 16 s — so
    // the record starts at 44 s and its drop arrives exactly on the last beat of it.
    // Its four-bar markers run from its second bar, where its sections start: 4 s,
    // 12 s, 20 s … 44 s, 52 s, 60 s.
    TrackTiming to({bool markers = true}) => TrackTiming(
          durationMs: 200000,
          bpm: 120,
          beats: [for (var i = 0; i < 400; i++) i * 500],
          downbeats: [for (var i = 0; i < 400; i += 4) i * 500],
          fourBars: markers ? [for (var i = 8; i < 400; i += 16) i * 500] : const [],
          drops: const [60000],
          cues: const MixCues(
              firstDownbeatMs: 0, mixInMs: 20000, mixOutMs: 150000, soundEndMs: 190000),
        );
    expect(AutoMix.inPoint(to(), bars: 8, onTheDrop: true),
        const Duration(seconds: 44));
    // Not aiming at it: the old behaviour, before the intro ends.
    expect(AutoMix.inPoint(to(), bars: 8), const Duration(seconds: 4));
    // A drop off the four-bar grid: parked on the marker before, where a phrase
    // starts, rather than two bars into one — the drop comes two bars after the fader.
    expect(AutoMix.inPoint(to(markers: false), bars: 8, onTheDrop: true),
        const Duration(seconds: 40));
  });

  test('a transition does not run over the outgoing record\'s own drop', () {
    final from = TrackTiming(
      durationMs: 200000,
      bpm: 120,
      beats: [for (var i = 0; i < 400; i++) i * 500],
      // Its sections start every four bars from the third: 4 s, 12 s … 84 s, 92 s, 100 s.
      fourBars: [for (var i = 8; i < 400; i += 16) i * 500],
      drops: const [100000],
    );
    // A mix starting at 90 s over 16 s would play the run-up and then the drop
    // underneath the new record: it is brought forward to finish on the drop, so the
    // old record never drops and the new one drops in its place.
    expect(
        AutoMix.clearOfDrops(from, const Duration(seconds: 90),
            length: const Duration(seconds: 16)),
        const Duration(seconds: 84));
    // Nowhere near one: left alone.
    expect(
        AutoMix.clearOfDrops(from, const Duration(seconds: 30),
            length: const Duration(seconds: 16)),
        const Duration(seconds: 30));
  });

  test('the transition is chosen from what is known about the two records', () {
    expect(AutoMix.choose(t(bpm: 128, camelot: '8A'), t(bpm: 130, camelot: '9A')),
        (kind: Transition.blend, bars: 16), reason: 'in key, in tempo: the long blend');
    expect(AutoMix.choose(t(bpm: 128, camelot: '8A'), t(bpm: 130, camelot: '3B')),
        (kind: Transition.sweep, bars: 12),
        reason: 'a clash goes out through the filter, and is shorter');
    expect(AutoMix.choose(t(bpm: 128), t(bpm: 150)).kind, isNot(Transition.fade),
        reason: 'far, but not past meeting in the middle: mixed in step');
    expect(AutoMix.choose(t(bpm: 128), t(bpm: 165)),
        (kind: Transition.fade, bars: 2),
        reason: 'too far apart to put in step: handed over quickly, not laid on top');
    expect(AutoMix.choose(t(bpm: 128, ends: 'cold'), t(bpm: 165)).kind, Transition.cut,
        reason: 'and on the downbeat where the old one stops dead');
    expect(AutoMix.choose(t(bpm: 128, ends: 'fade'), t(bpm: 128)).kind, Transition.fade,
        reason: 'a record that fades itself has made its own exit');
    expect(AutoMix.choose(t(bpm: 128, ends: 'cold', camelot: '8A'), t(bpm: 128, camelot: '8A')).kind,
        Transition.cut, reason: 'a cold ending in key: on the one');
    expect(AutoMix.choose(t(beats: false), t(bpm: 128)).kind, Transition.fade,
        reason: 'no grid, no blend');
    expect(AutoMix.choose(null, t(bpm: 128)).kind, Transition.fade);
  });

  test('a loud record is turned down so the two sit level', () {
    // The server measures each song against -14 LUFS; the booth takes the loud ones
    // down so a blend does not duck one under the other. Never up: that is clipping.
    Track at(double? db) => Track.fromJson({
          'id': 1, 'title': 'x', 'artists': ['y'], 'state': 'ready',
          'stream_url': '/s', 'source': 'youtube',
          if (db != null) 'gain_db': db,
        });
    expect(Booth.trimOf(at(null)), 1.0, reason: 'nothing measured, nothing taken off');
    expect(Booth.trimOf(at(0)), 1.0);
    expect(Booth.trimOf(at(2)), 1.0, reason: 'a quiet record is not turned up');
    expect(Booth.trimOf(at(-6)), closeTo(0.501, 0.002));
    expect(Booth.trimOf(at(-60)), 0.05, reason: 'and never all the way to nothing');
  });

  test('the booth can pick what follows best rather than what is next', () {
    TrackTiming t({double? bpm, String? camelot, List<int> energy = const []}) =>
        TrackTiming(
          durationMs: 200000,
          bpm: bpm,
          beats: [for (var i = 0; i < 400; i++) i * 469],
          camelot: camelot,
          keyConfidence: camelot == null ? 0 : 0.8,
          energy: energy,
        );
    final on = t(bpm: 124, camelot: '8A', energy: [200, 220, 240]);
    // In key and in tempo beats out of key, which beats unsyncable.
    final good = AutoMix.howWell(on, t(bpm: 125, camelot: '9A', energy: [210, 230, 240]));
    final clash = AutoMix.howWell(on, t(bpm: 125, camelot: '3B', energy: [210, 230, 240]));
    final far = AutoMix.howWell(on, t(bpm: 150, camelot: '8A'));
    expect(good, greaterThan(clash));
    expect(clash, greaterThan(far));
    expect(AutoMix.howWell(on, null), 0, reason: 'nothing known, nothing claimed');
  });

  test('a place in a record is a bar of its four-bar phrase', () {
    // 120 bpm, a bar every 2 s. Markers at 4, 12 and 20 s, then a section three bars
    // long — the next at 26 s — and every eight seconds from there.
    final t = TrackTiming(
      durationMs: 200000,
      bpm: 120,
      beats: [for (var i = 0; i < 400; i++) i * 500],
      downbeats: [for (var i = 0; i < 400; i += 4) i * 500],
      fourBars: const [4000, 12000, 20000, 26000, 34000, 42000],
    );
    expect(t.placeInPhrase(const Duration(seconds: 2)), isNull, reason: 'before the first');
    expect(t.placeInPhrase(const Duration(seconds: 4)), (bar: 0, of: 4));
    expect(t.placeInPhrase(const Duration(seconds: 9)), (bar: 2, of: 4));
    expect(t.placeInPhrase(const Duration(seconds: 21)), (bar: 0, of: 3));
    expect(t.placeInPhrase(const Duration(milliseconds: 25000)), (bar: 2, of: 3));
    expect(t.placeInPhrase(const Duration(milliseconds: 25999)), (bar: 0, of: 4),
        reason: 'a hair before a marker is that marker');
    expect(t.placeInPhrase(const Duration(seconds: 50)), (bar: 0, of: 4),
        reason: 'past the last, on in fours');
    expect(t.onMarker(const Duration(seconds: 24)).inMilliseconds, 26000);
    expect(t.markerAtOrBefore(const Duration(seconds: 23))?.inMilliseconds, 20000);
    // An analysis from before the markers: every fourth downbeat from the first.
    final old = TrackTiming(
      durationMs: 200000,
      bpm: 120,
      beats: [for (var i = 0; i < 400; i++) i * 500],
    );
    expect(old.markers.take(3), [0, 8000, 16000]);
  });

  test('a step that says nothing of the fader leaves it on its way', () {
    // The stem blend holds the fader in the middle until its last step; read as 0
    // and 1, its stem steps once sent the fader sawing up and down.
    for (final kind in [Transition.stemBlend, Transition.announce, Transition.acapellaOut, Transition.dropSwap]) {
      final steps = Booth.plan(kind, from: 'A', to: 'B');
      final withFader = [for (final s in steps) if (s.crossfader != null) s];
      // What the booth's own reading gives at every hundredth, against a straight
      // reading between the steps that set the fader.
      for (var i = 0; i <= 100; i++) {
        final k = i / 100;
        MixStep? before, after;
        for (final s in withFader) {
          if (s.at <= k) {
            before = s;
          } else {
            after ??= s;
          }
        }
        final expected = before == null
            ? after!.crossfader!
            : after == null
                ? before.crossfader!
                : before.crossfader! + (after.crossfader! - before.crossfader!) * ((k - before.at) / (after.at - before.at));
        expect(Booth.faderOf(steps, k), closeTo(expected, 1e-9), reason: '${kind.name} at $k');
      }
    }
    // And nothing doubled for long: over a stem blend, the two drums are never both
    // above half for more than a tenth of the move.
    final steps = Booth.plan(Transition.stemBlend, from: 'A', to: 'B');
    var both = 0;
    for (var i = 0; i <= 100; i++) {
      final k = i / 100;
      final a = Booth.stemsOf(steps, 'A', k), b = Booth.stemsOf(steps, 'B', k);
      if (a != null && b != null && a.drums > 0.5 && b.drums > 0.5) both++;
    }
    expect(both, lessThanOrEqualTo(10), reason: 'hundredths with both drums up: $both');
  });

  test('a record with a long quiet intro is not parked in the silence', () {
    // 120 bpm, bars of 2 s; the intro ends at bar 32, but its first 24 bars are near
    // silence and only the last 8 are heard.
    final beats = [for (var i = 0; i < 480; i++) i * 500];
    final downs = [for (var i = 0; i < 480; i += 4) beats[i]];
    TrackTiming timed(List<double> mixDb) => TrackTiming(
          durationMs: 240000,
          bpm: 120,
          beats: beats,
          downbeats: downs,
          cues: MixCues(firstDownbeatMs: 0, mixInMs: downs[32], mixOutMs: downs[100], soundEndMs: 239000),
          structure: TrackStructure(barsMs: downs, mixDb: mixDb),
        );
    final thin = timed([for (var i = 0; i < 120; i++) i < 24 ? -45.0 : i < 32 ? -14.0 : -10.0]);
    final full = timed([for (var i = 0; i < 120; i++) i < 32 ? -12.0 : -10.0]);
    expect(AutoMix.inPoint(full, bars: 16), Duration(milliseconds: downs[16]), reason: 'the ordinary place');
    expect(AutoMix.inPoint(thin, bars: 16), Duration(milliseconds: downs[24]), reason: 'half way: where it is heard');
    final silent = timed([for (var i = 0; i < 120; i++) i < 32 ? -50.0 : -10.0]);
    expect(AutoMix.inPoint(silent, bars: 16), Duration(milliseconds: downs[32]), reason: 'already on');
  });

  test('the mix is moved to the phrase it is nearest', () {
    // 128 bpm: a bar is 1875 ms, a phrase 30 s. Phrases at 0, 30, 60, 90 s.
    final t = TrackTiming(
      durationMs: 200000,
      bpm: 128,
      beats: [for (var i = 0; i < 400; i++) (i * 468.75).round()],
      phrases: [0, 30000, 60000, 90000],
    );
    // On the grid, to a millisecond.
    expect(AutoMix.onPhrase(t, const Duration(seconds: 62)).inMilliseconds, 60000,
        reason: 'a mix four bars into a phrase lands four bars into the next');
    expect(AutoMix.onPhrase(t, const Duration(seconds: 88)).inMilliseconds, 90000);
    // Nowhere near one: not dragged half a minute, but not left in the middle of a
    // phrase either — onto the nearest four-bar marker (every 7.5 s here).
    expect(AutoMix.onPhrase(t, const Duration(seconds: 120)).inMilliseconds, 120000);
    expect(AutoMix.onPhrase(t, const Duration(seconds: 124)).inMilliseconds, 127500);
    expect(AutoMix.onPhrase(const TrackTiming(), const Duration(seconds: 5)),
        const Duration(seconds: 5), reason: 'no phrases, nothing to move it to');
  });

  test('the outgoing goes at its outro; the incoming is parked before its intro ends', () {
    final from = t(bpm: 128);
    // The outro cue, on the four-bar marker nearest it: every sixteenth beat of 469 ms.
    expect(AutoMix.outPoint(from, length: const Duration(seconds: 30)),
        const Duration(milliseconds: 21 * 16 * 469));
    final none = TrackTiming(durationMs: 100000, tailMs: 2000);
    expect(AutoMix.outPoint(none, length: const Duration(seconds: 30)), const Duration(seconds: 68),
        reason: 'no outro read: the bars before the sound ends');
    // 128 bpm: a bar is 1875 ms; 8 bars before 15 s is a shade under 0, so the first
    // downbeat; 4 bars before is 7.5 s, on the grid at the downbeat before it.
    expect(AutoMix.inPoint(t(bpm: 128), bars: 8), const Duration(milliseconds: 469));
    final four = AutoMix.inPoint(t(bpm: 128), bars: 4);
    expect(four.inMilliseconds, lessThanOrEqualTo(7500));
    expect(four.inMilliseconds % 469, 0, reason: 'on a downbeat of its own');
  });
}
