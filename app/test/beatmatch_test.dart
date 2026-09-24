// Two records held together: the tempo read where a record is, the beat it is on,
// how far apart two of them are, and the booth keeping them there.
//
// A mix that starts together and drifts is the thing anybody hears first, and the
// engines underneath guarantee neither when a record starts nor that two tempo
// figures agree. So this checks the measuring (on grids as rough as the analysis
// really produces) and the holding (on the fake engine, whose clock is the wall's).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/automix.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/booth/mixer_desktop.dart';
import 'package:muse/src/state/booth/deck.dart';

import 'fake_audio.dart';

/// Beats every [ms] from [from], each moved by up to [jitter] ms the way a frame of
/// analysis moves it, with bars starting on the first.
TrackTiming beatsEvery(double ms,
    {int count = 400, double from = 0, double jitter = 0, int seed = 1, String? camelot}) {
  final r = math.Random(seed);
  final beats = [
    for (var i = 0; i < count; i++)
      (from + i * ms + (r.nextDouble() * 2 - 1) * jitter).round(),
  ];
  return TrackTiming(
    durationMs: (from + count * ms).round() + 1000,
    bpm: double.parse((60000 / ms).toStringAsFixed(1)),
    beats: beats,
    downbeats: [for (var i = 0; i < count; i += 4) beats[i]],
    camelot: camelot,
    // A key the house is sure of: a guess at one says nothing (SetPlanner.keyMove).
    keyConfidence: camelot == null ? 0 : 0.8,
  );
}

Track song(int id) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'duration_ms': 600000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

class QuietMixer extends Mixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => false;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {}
  @override
  void expecting(String deck) {}
  @override
  Future<void> setEq(Deck deck, EqSet eq) async {}
  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (c) async => null);
  group('reading the grid', () {
    test('the tempo here, through beats as rough as the analysis leaves them', () {
      final t = beatsEvery(60000 / 125.37, jitter: 6);
      expect(t.tempoAround(const Duration(seconds: 60))!, closeTo(125.37, 0.08));
    });

    test('a record that speeds up has a tempo of its own in each place', () {
      // A live drummer: 120 at the start, 126 by the end.
      final beats = <int>[];
      var at = 0.0;
      for (var i = 0; i < 400; i++) {
        beats.add(at.round());
        at += 60000 / (120 + 6 * i / 400);
      }
      final t = TrackTiming(durationMs: at.round() + 1000, bpm: 123, beats: beats);
      expect(t.tempoAround(Duration(milliseconds: beats[20]))!, closeTo(120.3, 0.3));
      expect(t.tempoAround(Duration(milliseconds: beats[380]))!, closeTo(125.7, 0.3));
    });

    test('the beat and how far through it, steadier than the beats themselves', () {
      const period = 480.0;
      final t = beatsEvery(period, from: 100, jitter: 6);
      var worst = 0.0;
      for (var ms = 20000; ms < 40000; ms += 37) {
        final b = t.smoothBeatAt(Duration(milliseconds: ms))!;
        final truth = (ms - 100) / period;
        final got = b.index + b.phase;
        worst = math.max(worst, (got - truth).abs() * period);
      }
      expect(worst, lessThan(4), reason: 'within 4 ms, where one beat can be 6 out');
    });

    test('steps on the wheel', () {
      TrackTiming k(String c) => TrackTiming(camelot: c);
      expect(k('8A').keyStepsTo(k('8A')), 0);
      expect(k('8A').keyStepsTo(k('9A')), 1);
      expect(k('8A').keyStepsTo(k('8B')), 1, reason: 'the relative major');
      expect(k('12A').keyStepsTo(k('1A')), 1, reason: 'round the top of the wheel');
      expect(k('8A').keyStepsTo(k('10A')), 2);
      expect(k('8A').keyStepsTo(k('9B')), 2, reason: 'a diagonal');
      expect(k('8A').keyStepsTo(k('2A')), 6);
      expect(k('8A').keyStepsTo(const TrackTiming()), isNull);
    });
  });

  group('how far apart', () {
    final grid = beatsEvery(500);
    Duration? err(Duration f, Duration m,
            {TrackTiming? follower, double fr = 1, double mr = 1}) =>
        Booth.beatError(
            follower: follower ?? grid, followerAt: f, followerRate: fr,
            master: grid, masterAt: m, masterRate: mr);

    test('ahead is ahead, behind is behind, by the clock', () {
      expect(err(const Duration(milliseconds: 10020), const Duration(milliseconds: 10000))!
          .inMilliseconds, 20);
      expect(err(const Duration(milliseconds: 9985), const Duration(milliseconds: 10000))!
          .inMilliseconds, -15);
      // At twice the rate a file's 20 ms are the clock's 10.
      expect(err(const Duration(milliseconds: 10020), const Duration(milliseconds: 10000),
              fr: 2, follower: beatsEvery(1000))!
          .inMilliseconds, 10);
    });

    test('the short way round: never more than half a beat', () {
      // 480 ms ahead of a 500 ms beat is 20 ms behind the next one.
      expect(err(const Duration(milliseconds: 10480), const Duration(milliseconds: 10000))!
          .inMilliseconds, -20);
    });

    test('a record at twice the beats lines up with the pulse, not every other beat', () {
      final double = beatsEvery(250); // 240 against 120
      // On a beat, but the off one of its pair: half of the master's beat out.
      final off = err(const Duration(milliseconds: 250), const Duration(milliseconds: 10000),
          follower: double)!;
      expect(off.inMilliseconds.abs(), 250);
      final on = err(const Duration(milliseconds: 500), const Duration(milliseconds: 10000),
          follower: double)!;
      expect(on.inMilliseconds, 0);
    });

    test('a bend closes the gap, and never by more than it should', () {
      expect(Booth.bendFor(const Duration(milliseconds: 20)), lessThan(1));
      expect(Booth.bendFor(const Duration(milliseconds: -20)), greaterThan(1));
      // A flam that can be heard is bent out quickly, but never by more than 6 %;
      // inside 8 ms, gently — over four seconds, and never by more than 3 %.
      expect(Booth.bendFor(const Duration(seconds: 5)), 0.94);
      expect(Booth.bendFor(const Duration(milliseconds: 21)), closeTo(0.97, 1e-9));
      expect(Booth.bendFor(const Duration(milliseconds: 6)), closeTo(1 - 6 / 4000, 1e-9));
      expect(Booth.bendFor(Duration.zero), 1);
    });
  });

  test('the incoming starts on the four-bar marker nearest the plan, or the next bar', () {
    final t = beatsEvery(500); // a bar every 2 s, a marker every 8
    expect(AutoMix.startFor(t, const Duration(milliseconds: 30100), const Duration(seconds: 28)),
        const Duration(seconds: 32), reason: 'the marker, not the downbeat nearer the sums');
    expect(AutoMix.startFor(t, const Duration(milliseconds: 32100), const Duration(seconds: 20)),
        const Duration(seconds: 32));
    expect(AutoMix.startFor(t, const Duration(seconds: 28), const Duration(milliseconds: 29000)),
        const Duration(seconds: 30), reason: 'the moment has gone: the next bar');
    expect(AutoMix.startFor(const TrackTiming(), const Duration(seconds: 3), Duration.zero),
        isNull, reason: 'no grid, no bar to wait for');
  });

  group('on the fake engine', () {
    late Booth booth;

    setUp(() async {
      JustAudioPlatform.instance = FakeJustAudio();
      booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x',
          mixer: QuietMixer());
      await booth.init();
      await booth.load(booth.a, song(1));
      await booth.load(booth.b, song(2));
      booth.a.timing = beatsEvery(500, count: 1200);
      booth.b.timing = beatsEvery(500, count: 1200);
      await booth.a.seek(const Duration(seconds: 30));
      await booth.a.play();
      booth.master = booth.a;
    });

    tearDown(() => booth.dispose());

    Duration apart() => Booth.beatError(
          follower: booth.b.timing!,
          followerAt: booth.b.position,
          followerRate: booth.b.tempo,
          master: booth.a.timing!,
          masterAt: booth.a.position,
          masterRate: booth.a.tempo,
        )!;

    test('a record started out of step is put in step while it cannot be heard', () async {
      await booth.setCrossfader(0); // B silent
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 90));
      await booth.b.play();
      expect(apart().inMilliseconds.abs(), greaterThan(60));
      booth.holdOnBeat(booth.b);
      // It waits for the start to settle before it measures (600 ms), then reads a few.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(apart().inMilliseconds.abs(), lessThan(8));
      await booth.letGo();
    });

    test('an audible record is bent into step, not jumped', () async {
      await booth.setCrossfader(0.5);
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 25));
      await booth.b.play();
      final seeks = <Duration>[];
      booth.b.addListener(() {});
      booth.holdOnBeat(booth.b);
      var tempoMoved = false;
      // Gently: over seconds, not at once — on the real engine anything quicker swung.
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (booth.b.tempo != 1.0) tempoMoved = true;
        seeks.add(booth.b.position);
      }
      expect(tempoMoved, isTrue, reason: 'it was bent');
      expect(apart().inMilliseconds.abs(), lessThan(10));
      await booth.letGo();
    });

    test('a tempo that does not quite match is held anyway', () async {
      await booth.setCrossfader(0.5);
      await booth.b.seek(booth.a.position);
      // 0.2 % fast — four times what the grids are usually out by: 1 ms more a beat.
      await booth.b.setTempo(1.002);
      await booth.b.play();
      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(seconds: 12));
      expect(apart().inMilliseconds.abs(), lessThan(12),
          reason: 'left alone it would be 24 ms out by now and growing');
      await booth.letGo();
      expect(booth.b.tempo, lessThanOrEqualTo(1.002), reason: 'never let go faster than it was');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('the incoming starts on the beat the plan chose', () async {
      final startAt = booth.a.position + const Duration(milliseconds: 600);
      Duration? masterWhenItStarted;
      booth.b.addListener(() {
        if (booth.b.playing && masterWhenItStarted == null) {
          masterWhenItStarted = booth.a.position;
        }
      });
      await booth.go(Transition.cut, startAt: startAt);
      expect(masterWhenItStarted, isNotNull);
      expect((masterWhenItStarted! - startAt).inMilliseconds.abs(), lessThan(25));
      expect(booth.master.name, 'B');
    });

    test('SYNC by hand matches a pitched deck to a tempo a few tenths away', () async {
      // A was left at -12.2 % by an earlier mix: 170.8 made, 150.0 on show. B is 147.
      // Two tempos 2 % apart on screen — and SYNC used to refuse, because A would end
      // up more than 8 % from its own speed.
      booth.a.timing = beatsEvery(60000 / 170.8, count: 1200);
      booth.b.timing = beatsEvery(60000 / 147.0, count: 1200);
      await booth.a.setTempo(150.0 / 170.8);
      expect(booth.a.bpm!.toStringAsFixed(1), '150.0');
      expect(booth.whyNotSync(booth.a), isNull);
      expect(await booth.sync(booth.a), isTrue);
      expect(booth.a.bpm!.toStringAsFixed(1), '147.0');
    });

    test('SYNC by hand goes as far as it is asked, the nearer way round', () async {
      booth.a.timing = beatsEvery(60000 / 128.0, count: 1200);
      booth.b.timing = beatsEvery(60000 / 140.0, count: 1200);
      expect(await booth.sync(booth.b), isTrue, reason: '9.4 % apart: a DJ would sync it');
      expect(booth.b.bpm!.toStringAsFixed(1), '128.0');
      // 100 against 145: halved to 72.5 (27 % off) rather than stretched 45 %.
      expect(Booth.syncRatio(100, 145, reach: Booth.handReach), closeTo(0.725, 1e-9));
      expect(Booth.syncRatio(84.5, 169, reach: Booth.handReach), closeTo(1.0, 1e-9),
          reason: 'double time is the same tempo');
    });

    test('SYNC says what is missing, rather than that two tempos are too far apart', () async {
      booth.b.timing = null;
      expect(booth.whyNotSync(booth.a), 'No beat grid for B yet');
      expect(booth.whyNotSync(booth.b), 'No beat grid for B yet');
      booth.b.timing = const TrackTiming(bpm: null, beats: []);
      expect(booth.whyNotSync(booth.a), 'No steady beat on B');
      expect(await booth.sync(booth.a), isFalse);
    });

    test('a new record starts at its own speed; the same one keeps its pitch', () async {
      await booth.b.setTempo(0.9);
      await booth.b.load(song(2), timing: beatsEvery(500, count: 1200));
      expect(booth.b.pitch, 0.9, reason: 'the same record, reloaded: still pitched');
      await booth.b.load(song(3), timing: beatsEvery(480, count: 1200));
      expect(booth.b.pitch, 1.0);
      expect(booth.b.tempo, 1.0);
      expect(booth.b.bpm, closeTo(125, 0.01), reason: 'its own tempo on show');
    });

    test('pressing MIX again while it waits for the bar is not a second mix', () async {
      await booth.setCrossfader(0);
      for (var i = 0; i < 5; i++) {
        unawaited(booth.go(Transition.fade, bars: 1));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(booth.busy, isTrue);
      for (var i = 0; i < 100 && booth.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.taken, hasLength(1), reason: 'one mix, not five on top of each other');
      expect(booth.master.name, 'B');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a mix goes phrase to phrase: the incoming is moved to meet the outgoing\'s', () async {
      // Four-bar markers every 8 s on both. A goes at 32 s, on one of its markers; B
      // is cued a bar into one of its own phrases, so it is moved back the bar.
      await booth.setCrossfader(0);
      await booth.b.seek(const Duration(seconds: 42));
      final going = booth.go(Transition.blend, bars: 4, startAt: const Duration(seconds: 32));
      for (var i = 0; i < 80 && booth.taken.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.taken, hasLength(1));
      expect(booth.taken.single.inMs, 40000, reason: 'on its marker, as A is on its own');
      booth.stopTransition();
      await going.timeout(const Duration(seconds: 2));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a mix the automix lined up on two markers is not moved', () async {
      await booth.setCrossfader(0);
      await booth.b.seek(const Duration(seconds: 40));
      final going = booth.go(Transition.blend, bars: 4, startAt: const Duration(seconds: 32));
      for (var i = 0; i < 80 && booth.taken.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.taken.single.inMs, 40000);
      booth.stopTransition();
      await going.timeout(const Duration(seconds: 2));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a mix called off while it waits never starts', () async {
      final waiting = booth.go(Transition.blend, bars: 1,
          startAt: booth.a.position + const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(booth.arming, isNotNull, reason: 'it says it is waiting, and for what');
      booth.stopTransition();
      await waiting.timeout(const Duration(seconds: 5));
      expect(booth.b.playing, isFalse);
      expect(booth.taken, isEmpty);
      expect(booth.master.name, 'A');
      expect(booth.busy, isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('stopping a running mix lets whoever waits on it go', () async {
      final running = booth.go(Transition.blend, bars: 4);
      for (var i = 0; i < 80 && !booth.inTransition; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(booth.inTransition, isTrue);
      booth.stopTransition();
      await running.timeout(const Duration(seconds: 2),
          onTimeout: () => fail('the automix would have waited for ever'));
      expect(booth.busy, isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('held through the master\'s last bars, where its analysis wanders', () async {
      // The shape of a real mix that fell apart: the master's analysis wobbles ±20 ms
      // beat to beat and its last eighteen beats sit 45 ms late, where the tracker lost
      // them in the fade — which is exactly where a mix out of it happens. Held to the
      // beats nearby, the incoming followed them there.
      FakeAudioPlayer.trackLength = const Duration(minutes: 5);
      addTearDown(() => FakeAudioPlayer.trackLength = const Duration(minutes: 1));
      const ms = 60000 / 145.3;
      final r = math.Random(5);
      final beats = [
        for (var i = 0; i < 412; i++)
          (1700 + i * ms + (r.nextDouble() * 2 - 1) * 20 + (i >= 394 ? 45 : 0)).round(),
      ];
      booth.a.timing = TrackTiming(durationMs: beats.last + 1000, bpm: 145.3, beats: beats);
      booth.b.timing = beatsEvery(60000 / 136.0, count: 400, from: 600, jitter: 10, seed: 9);
      await booth.a.seek(const Duration(milliseconds: 158000));
      await booth.a.play();
      expect(await booth.sync(booth.b), isTrue);
      await booth.b.seek(booth.b.timing!.onGrid(const Duration(seconds: 2)));
      await booth.setCrossfader(0.5);
      await booth.b.play();
      booth.holdOnBeat(booth.b, snap: true);
      // Against where the master's beats really are: the line it was made to.
      double trulyApart() {
        final xa = (booth.a.position.inMicroseconds / 1000 - 1700) / ms;
        final s = booth.b.timing!.steady!;
        final xb = (booth.b.position.inMicroseconds / 1000 - s.origin) / s.period;
        var d = (xb - xb.floor()) - (xa - xa.floor());
        d -= d.roundToDouble();
        return d * ms;
      }

      final worst = <double>[];
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (i > 30) worst.add(trulyApart().abs());
      }
      worst.sort();
      expect(worst.last, lessThan(10), reason: 'not dragged 45 ms off by the analysis');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 30)));

    group('SYNC by hand', () {
      setUp(() async {
        // A slightly different tempo, and beats as rough as the analysis gives them.
        booth.b.timing = beatsEvery(60000 / 123, count: 1200, jitter: 8, seed: 3);
        await booth.setCrossfader(0.5);
      });

      test('a synced deck started by hand lands on the beat, and stays there', () async {
        expect(await booth.setSync(booth.b, true), isTrue);
        expect(booth.b.synced, isTrue);
        expect(identical(booth.master, booth.a), isTrue);
        expect(booth.b.bpm!.toStringAsFixed(2), booth.a.bpm!.toStringAsFixed(2));
        // Parked anywhere at all, as a hand parks it.
        await booth.b.seek(const Duration(milliseconds: 10230));
        await booth.play(booth.b);
        expect(booth.b.playing, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(apart().inMilliseconds.abs(), lessThan(10), reason: 'started in step');
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(apart().inMilliseconds.abs(), lessThan(10), reason: 'and held there');
        expect(booth.holding, isTrue);
      });

      test('pressed with both playing, it puts them in step at once', () async {
        await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 150));
        await booth.b.play();
        await booth.setSync(booth.b, true);
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        expect(apart().inMilliseconds.abs(), lessThan(10),
            reason: 'one jump, not five seconds of bending with the flam audible');
      });

      test('the leader\'s tempo moving takes the follower with it, quietly', () async {
        await booth.setSync(booth.b, true);
        final said = booth.events.length;
        for (final r in [1.01, 1.02, 1.03, 1.04]) {
          await booth.pitchByHand(booth.a, r);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(booth.b.synced, isTrue);
        expect(booth.b.bpm!.toStringAsFixed(2), booth.a.bpm!.toStringAsFixed(2));
        expect(booth.events.length, said, reason: 'a fader dragged is not four lines in the log');
      });

      test('moving the follower\'s own fader lets go', () async {
        await booth.setSync(booth.b, true);
        await booth.pitchByHand(booth.b, 1.02);
        expect(booth.b.synced, isFalse);
        expect(booth.b.pitch, 1.02);
      });

      test('a nudge with SYNC on moves where it is held, and it stays moved', () async {
        await booth.setSync(booth.b, true);
        await booth.b.seek(const Duration(seconds: 12));
        await booth.play(booth.b);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await booth.nudge(booth.b, const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(apart().inMilliseconds, inInclusiveRange(12, 28),
            reason: 'held 20 ms ahead, as nudged — not pulled straight back');
        expect(booth.b.syncTrim, const Duration(milliseconds: 20));
      });

      test('pausing either lets go, and playing again holds again', () async {
        await booth.setSync(booth.b, true);
        await booth.play(booth.b);
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(booth.holding, isTrue);
        await booth.a.pause();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(booth.holding, isFalse);
        expect(booth.b.tempo, booth.b.pitch, reason: 'back at its own pitch, not left bent');
        await booth.play(booth.a);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(booth.holding, isTrue);
        expect(apart().inMilliseconds.abs(), lessThan(12));
      });

      test('a mix takes SYNC over', () async {
        await booth.setSync(booth.b, true);
        await booth.go(Transition.cut);
        expect(booth.b.synced, isFalse);
        expect(booth.a.synced, isFalse);
      });
    });

    test('after SYNC the two decks read the same, and keep reading it while held', () async {
      // B's grid runs 2 % fast in the bars where it is parked — the kind of intro the
      // analysis reads faster than the song — so its local tempo and its own figure
      // disagree. What is on show must not.
      final fastIntro = <int>[];
      var at = 0.0;
      for (var i = 0; i < 1200; i++) {
        fastIntro.add(at.round());
        at += i < 64 ? 60000 / 153.0 : 60000 / 150.0;
      }
      booth.b.timing = TrackTiming(durationMs: at.round() + 1000, bpm: 150.0, beats: fastIntro);
      booth.a.timing = beatsEvery(60000 / 147.0, count: 1200);
      await booth.b.seek(const Duration(seconds: 2));
      expect(await booth.sync(booth.b), isTrue);
      expect(booth.b.bpm!.toStringAsFixed(1), booth.a.bpm!.toStringAsFixed(1));

      await booth.setCrossfader(0.5);
      await booth.b.play();
      booth.holdOnBeat(booth.b);
      final shownA = <double>{}, shownB = <double>{}, pitchB = <double>{};
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        shownA.add(booth.a.bpm!);
        shownB.add(booth.b.bpm!);
        pitchB.add(booth.b.pitch);
      }
      expect(shownA, hasLength(1), reason: 'the master never moves');
      expect(shownB, hasLength(1), reason: 'the beat-holding bends the engine, not the number');
      expect(pitchB, hasLength(1));
      await booth.letGo();
      expect(booth.b.tempo, booth.b.pitch, reason: 'let go at exactly the pitch it was synced to');
    });
  });

  test('picking what follows prefers a neighbour on the wheel to a clash', () {
    final now = beatsEvery(500, camelot: '8A');
    final near = beatsEvery(500, camelot: '9A');
    final two = beatsEvery(500, camelot: '10A');
    final far = beatsEvery(500, camelot: '2B');
    final a = AutoMix.howWell(now, near), b = AutoMix.howWell(now, two);
    final c = AutoMix.howWell(now, far);
    expect(a, greaterThan(b));
    expect(b, greaterThan(c));
  });

  test('the automix pulls the incoming all the way, and never moves the master', () {
    // 154 into 169 (the analysis said 84.5): 9.7 %, past what a hand would sync, inside
    // what the automix will.
    expect(Booth.syncRatio(84.5, 154), isNull);
    expect(Booth.syncRatio(84.5, 154, reach: Booth.bridgeReach), closeTo(154 / 169, 1e-9));
    expect(Booth.syncRatio(103.5, 150, reach: Booth.bridgeReach), isNull, reason: 'past even that');
  });

  test('your queue: every pair that can be put in step is', () {
    // The records that were mixed without a single one in step (2026-09-23).
    TrackTiming r(double bpm, String ends) => TrackTiming(
        bpm: bpm, ends: ends, beats: [for (var i = 0; i < 64; i++) i * 400]);
    final glamorous = r(147, 'fade'), euro = r(154, 'fade'), solo = r(84.5, 'fade');
    final baron = r(103.5, 'cold'), whatcha = r(149.9, 'cold');
    expect(Booth.syncRatio(euro.bpm!, glamorous.bpm!, reach: Booth.bridgeReach), isNotNull,
        reason: 'a fade out of a record that fades itself is still in step');
    expect(Booth.syncRatio(solo.bpm!, euro.bpm!, reach: Booth.bridgeReach), isNotNull,
        reason: '154 into 169 meets in the middle');
    expect(AutoMix.choose(solo, baron), (kind: Transition.fade, bars: 2),
        reason: '84.5 against 103.5 cannot be one tempo: a quick handover');
    expect(AutoMix.choose(baron, whatcha).kind, Transition.cut,
        reason: 'a cold ending into a different speed: on the downbeat');
  });

  group('the desk\'s filter chain is turned, never rebuilt', () {
    Map<String, String> said(EqSet eq, double filter) => {
          for (final (target, command, value) in DesktopMixer.commands(eq: eq, filter: filter))
            '$target $command': value,
        };

    test('a kill is a gain on the one band', () {
      final c = said(const EqSet(low: EqSet.killed), 0);
      expect(c['lowshelf@low g'], '-40.0');
      expect(c['equalizer@mid g'], '0.0');
      expect(c['highpass@hp m'], '0', reason: 'the passes are out of the sound');
      expect(c['lowpass@lp m'], '0');
    });

    test('the filter knob mixes one pass in and moves it', () {
      final up = said(EqSet.flat, 0.5);
      expect(up['highpass@hp m'], '1');
      expect(int.parse(up['highpass@hp f']!), closeTo(283, 2));
      expect(up['lowpass@lp m'], '0');
      final down = said(EqSet.flat, -0.3);
      expect(down['lowpass@lp m'], '1');
      expect(int.parse(down['lowpass@lp f']!), lessThanOrEqualTo(15000),
          reason: 'never past what a 32 kHz part can carry: ffmpeg refuses it');
    });

    test('the standing chain names every filter it will be told about', () {
      for (final (target, _, _) in DesktopMixer.commands(eq: EqSet.flat, filter: 0)) {
        expect(DesktopMixer.bands, contains(target));
      }
      expect(DesktopMixer.standing.first, endsWith('rubberband'),
          reason: 'the stretcher that keeps beats where they belong, first');
      expect(DesktopMixer.standing.last, endsWith('scaletempo2'),
          reason: 'and a stretcher always there, so a tempo change never changes the chain');
    });
  });

  test('a deck\'s clock does not twitch with every report the engine gives', () async {
    final audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    final deck = Deck('A', api: ApiClient(baseUrl: 'http://example.invalid'));
    addTearDown(deck.dispose);
    await deck.load(song(1), timing: beatsEvery(500, count: 1200), at: const Duration(seconds: 10));
    final engine = audio.players[deck.player.platformId]!;
    await deck.play();
    final r = math.Random(4);
    final began = DateTime.now();
    const start = Duration(seconds: 10);
    final errors = <double>[];
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final truth = start + DateTime.now().difference(began);
      // What mpv reports: the truth, give or take a dozen milliseconds.
      engine.tick(truth + Duration(microseconds: ((r.nextDouble() * 2 - 1) * 20000).round()));
      if (i > 30) errors.add((deck.position - (start + DateTime.now().difference(began))).inMicroseconds / 1000);
    }
    final mean = errors.reduce((a, b) => a + b) / errors.length;
    final sd = math.sqrt(errors.map((e) => (e - mean) * (e - mean)).reduce((a, b) => a + b) / errors.length);
    expect(sd, lessThan(5), reason: 'reports scattered ±20 ms; the clock should not be');
  });

  test('the automix judges tempo as far as it will pull, and half time as another feel', () {
    TrackTiming at(double bpm) => TrackTiming(
        durationMs: 60000, bpm: bpm, beats: [for (var i = 0; i < 200; i++) (i * 60000 / bpm).round()]);
    final same = AutoMix.howWell(at(120), at(121));
    final twelve = AutoMix.howWell(at(120), at(134));
    final far = AutoMix.howWell(at(120), at(150));
    final half = AutoMix.howWell(at(120), at(60));
    expect(twelve, greaterThan(0.1), reason: 'twelve percent is within the automix\'s reach');
    expect(twelve, lessThan(same));
    expect(far, lessThan(twelve), reason: 'out of reach: no tempo points at all');
    expect(half, lessThan(same), reason: 'half time is in step, but not the same record');
    expect(half, greaterThan(far));
  });

  test('the automix judges the next record against the tempo on show', () {
    // The master was made at 170.8 and is playing at 150.0. The next is 147: 2 % from
    // what is on show, 16.2 % from what the master was made at.
    final master = beatsEvery(60000 / 170.8, count: 400);
    final next = beatsEvery(60000 / 147.0, count: 400);
    const pitch = 150.0 / 170.8;
    expect(AutoMix.choose(master, next, fromPitch: pitch).kind, isNot(Transition.fade),
        reason: 'in step: blended, not handed over');
    expect(AutoMix.choose(master, next), (kind: Transition.fade, bars: 2),
        reason: 'judged by the made tempo it would have been a handover');
    expect(AutoMix.howWell(master, next, fromPitch: pitch),
        greaterThan(AutoMix.howWell(master, next)));
  });
}
