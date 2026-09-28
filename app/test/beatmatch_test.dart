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
  /// Every time a record going on this deck made the mixer put its bands back.
  final loadedAgain = <String>[];

  @override
  Future<void> loaded(Deck deck) async => loadedAgain.add(deck.name);

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
      // A flam that can be heard is pulled out over about 1.8 s and never by more
      // than 3 %; inside 8 ms, gently — over four seconds.
      //
      // The pull used to be 700 ms and 6 %, which is more gain than a loop with half
      // a second of delay in it can carry: it overshot, turned round, overshot the
      // other way, and never settled. Gross errors are a jump's job now, so the bend
      // only has to hold a record that is already close.
      expect(Booth.bendFor(const Duration(seconds: 5)), closeTo(0.97, 1e-9),
          reason: 'the stop');
      expect(Booth.bendFor(const Duration(milliseconds: 21)), closeTo(1 - 21 / 1800, 1e-9));
      expect(Booth.bendFor(const Duration(milliseconds: 6)), closeTo(1 - 6 / 4000, 1e-9));
      expect(Booth.bendFor(Duration.zero), 1);
      // Gentler than it was, everywhere it is not at the stop: that is the point.
      expect(Booth.bendFor(const Duration(milliseconds: 30)),
          greaterThan(Booth.bendFor(const Duration(milliseconds: 30), quick: const Duration(milliseconds: 700))),
          reason: 'a 30 ms flam is pulled less hard than the old loop pulled it');
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

    test('an audible record far out of step is put back, not crawled back', () async {
      // The regression this pins: forbidding a jump while the deck could be heard
      // left the bend as the only way back, and the bend clears 60 ms a second at
      // its 6% stop. A record 220 ms out took four seconds of crawling — on a phone,
      // where the engines are looser, it often never arrived at all. Two jumps are
      // allowed out loud now; after that the bend is left to it.
      await booth.setCrossfader(0.5); // B is heard
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 220));
      await booth.b.play();
      expect(apart().inMilliseconds.abs(), greaterThan(150));
      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect(apart().inMilliseconds.abs(), lessThan(25),
          reason: 'still ${apart().inMilliseconds} ms out');
      await booth.letGo();
    });

    test('SYNC on a running record does not sit out the start it never had', () async {
      await booth.setCrossfader(0.5);
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 60));
      await booth.b.play();
      booth.holdOnBeat(booth.b, snap: true);
      // Six hundred milliseconds of the hold used to go on waiting for a start that
      // had already happened, before the first reading was even taken.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(apart().inMilliseconds.abs(), lessThan(25),
          reason: 'still ${apart().inMilliseconds} ms out after 700 ms');
      await booth.letGo();
    });

    test('a record one beat into the phrase is put on the one', () async {
      // The case both measurements were blind to: a beat late is *on* a beat, so the
      // beat error reads nil, and it is the same bar, so a phrase counted in bars
      // read nil too. The record then played its one against the master's two.
      await booth.setCrossfader(0);
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 500));
      await booth.b.play();
      expect(apart().inMilliseconds.abs(), lessThan(20),
          reason: 'the beat error is blind to it: a beat late is still on a beat');
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), 1, reason: 'one beat in');

      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), 0, reason: 'still off the one');
      expect(apart().inMilliseconds.abs(), lessThan(12));
      await booth.letGo();
    });

    test('a record on the wrong bar of the phrase is put on the right one', () async {
      // The fault this is for: beatError wraps at half a beat, so two records a whole
      // two bars apart read as perfectly in step. Held by it they stay that way —
      // stable, in time, and with bar one of the one against bar three of the other.
      await booth.setCrossfader(0); // B silent, so it can be moved
      // Two bars on, exactly: a whole number of beats, so the beat error is nil.
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 4000));
      await booth.b.play();
      expect(apart().inMilliseconds.abs(), lessThan(5),
          reason: 'the beat error cannot see this at all');
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), isNot(0),
          reason: 'but the phrase can');

      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), 0,
          reason: 'still out of the phrase');
      expect(apart().inMilliseconds.abs(), lessThan(12),
          reason: 'and the beat is still held');
      await booth.letGo();
    });

    test('a record half a beat out is put right, and stays', () async {
      // Where a phone leaves records: its engine takes a hundred-odd milliseconds to
      // make a sound and never the same twice, so a record started on the beat sounds
      // somewhere between the beats. Right at the boundary of what a wrapped phase
      // can say, which is where the reading is worth least.
      //
      // (This one passes on the old measurements too — a clean engine gives a steady
      // sign and one jump settles it. It is here to hold the ground, not to prove
      // anything; the case the old pair could not do is the next test down.)
      await booth.setCrossfader(0.5); // heard, so this cannot be a quiet shuffle
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 240));
      await booth.b.play();
      expect(apart().inMilliseconds.abs(), greaterThan(200),
          reason: 'at the boundary, where the wrapped reading gives out');
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), 0,
          reason: 'and where whole beats say there is nothing to fix');

      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(seconds: 6));
      // Put right, and then left alone: sampled over two seconds, because a record
      // that crosses zero and comes back is the fault, not the cure.
      final worst = <int>[];
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        worst.add(apart().inMilliseconds.abs());
      }
      worst.sort();
      expect(worst.last, lessThan(15), reason: 'worst of forty readings: ${worst.last} ms');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a record out by more than half a beat, in the room, is put right', () async {
      // The one that sounds like "it snaps to the wrong thing", and the reason the
      // two old measurements were replaced by one.
      //
      // A beat and a half out, and audible. The wrapped phase reads half a beat of
      // that — it cannot say more, being wrapped — so the loop moves it half a beat
      // and stops, satisfied: the phase now reads nil and the record is beautifully
      // in time on the wrong beat. The whole-beat count can see the beat that is
      // left, but it is only ever acted on while nothing can hear it, so in the room
      // it is never acted on at all. The hold then reports itself as excellent while
      // bar one of the one plays against bar two of the other.
      //
      // Read as one continuous number it is a beat and a half, with a sign, and one
      // move is the whole of it.
      await booth.setCrossfader(0.5); // heard: the quiet shuffle is not available
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 750));
      await booth.b.play();
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), isNot(0),
          reason: 'a beat and a half out to start with');

      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), 0,
          reason: 'in time on the wrong beat: the fault, not the cure');
      expect(apart().inMilliseconds.abs(), lessThan(15),
          reason: 'and on the beat as well as on the right one');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a loop on an engine with no loop of its own learns what its wrap costs', () async {
      // "Looping still audible." Every phone and every browser loops this way: a timer
      // watches the record reach the end and seeks it back. The seek stops the sound
      // while the decoder restarts, so each time round is long by whatever that costs
      // — the same twenty or thirty milliseconds, every bar, for as long as the loop
      // is on. Only the engine's own loop ever measured that; this path never did, and
      // so never corrected for it.
      //
      // What is checked is the learning rather than the clock. Timing wraps against
      // the wall to the millisecond is a test that fails when the machine is busy,
      // which on a box running the rest of this suite it always is. What cannot be
      // hand-waved is whether anything measured the cost at all: on the old path this
      // stays at nought for ever.
      Deck.loopLate = Duration.zero;
      addTearDown(() => Deck.loopLate = Duration.zero);
      final engine = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.b.player.platformId!]!;
      const cost = Duration(milliseconds: 30);
      engine.seekCost = cost;
      engine.reportEvery = const Duration(milliseconds: 100);
      await booth.b.seek(const Duration(seconds: 10));
      await booth.b.play();
      booth.b.loop(2); // half a bar, a second at this tempo — several times round
      addTearDown(booth.b.unloop);

      final began = DateTime.now();
      var wraps = 0;
      var last = booth.b.position;
      final span = booth.b.loopEnd! - booth.b.loopStart!;
      while (DateTime.now().difference(began) < const Duration(seconds: 13)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final p = booth.b.position;
        if (p < last - span ~/ 2) wraps++;
        last = p;
      }
      // Enough times round for it to have something worth averaging: the cost is
      // judged over several, not one (see Deck._watchTheWrap).
      expect(wraps, greaterThan(7), reason: 'it barely looped: $wraps times round');
      // Eased into a quarter at a time, so a handful of wraps gets most of the way
      // there rather than all of it. Nought is the fault.
      expect(Deck.loopLate.inMilliseconds, greaterThan(8),
          reason: 'nothing measured what the wrap cost over $wraps times round');
      expect(Deck.loopLate, lessThanOrEqualTo(cost + const Duration(milliseconds: 15)),
          reason: 'it learned more than the wrap can possibly cost: ${Deck.loopLate}');
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a record that has just gone on gets its bands put back on it', () async {
      // "EQ knobs don't work when the song has changed and need to be reset manually
      // every time."
      //
      // A desk's equalizer lives in the engine's filter graph, and mpv builds that
      // graph afresh for every file, at a moment of its own choosing which is not the
      // moment setAudioSource returns. The bands were put on then and only then — so
      // they landed on a graph about to be thrown away, or on no graph at all, and the
      // new record played flat with the knobs still sitting where they were left.
      // Moving one by hand was the only thing that ever put them back, because that is
      // the one path that does not go through the mixer's "nothing changed" check.
      final mixer = booth.mixer as QuietMixer;
      await booth.setEq(booth.b, EqSet.flat.killing(0, true));
      expect(booth.eqOf(booth.b).low, lessThan(-20), reason: 'the low is killed');

      mixer.loadedAgain.clear();
      await booth.load(booth.b, song(7));
      // On load, as before — and that is the one that can be too early.
      expect(mixer.loadedAgain, contains('B'));

      mixer.loadedAgain.clear();
      await booth.b.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(mixer.loadedAgain, contains('B'),
          reason: 'nothing put the bands back when the record actually started');
      // And the booth still thinks the low is killed, so what goes back on is right.
      expect(booth.eqOf(booth.b).low, lessThan(-20));

      // Only for a record that has just gone on: playing again after a pause must not
      // keep re-sending a whole chain of commands for nothing.
      await booth.b.pause();
      mixer.loadedAgain.clear();
      await booth.b.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(mixer.loadedAgain, isEmpty,
          reason: 'it put them back again for a record that never went anywhere');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('once it is matched the rate stops moving, and the beat stays put', () async {
      // "The timing should be kept the same without any fluctuations or correction
      // loops. As precise and reliable as a normal DJ program."
      //
      // What a DJ deck does is not chase the phase. Two records on one sound card
      // advance on one clock, so if the follower runs at exactly the right ratio of
      // the master's tempo the gap between them never changes — place it once and it
      // is held, with the rate never touched again. The only reason this booth bent
      // anything is that the ratio comes off two fitted grids, through a stretcher
      // that does not run at precisely the speed it is asked for, into two resamplers
      // on one card. A tenth of a percent out is 6 ms every ten seconds.
      //
      // So the rate is learned from the drift and then left alone, and that is what
      // this asks: that the engine stops being told new speeds, that it settled on the
      // *right* one, and that the beat holds while nothing is being sent.
      final engine = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.b.player.platformId!]!;
      engine.reportEvery = const Duration(milliseconds: 100);
      engine.clockSkew = 0.001;
      await booth.setCrossfader(0.5);
      await booth.b.seek(booth.a.position);
      await booth.b.play();
      booth.holdOnBeat(booth.b, snap: true);

      await Future<void>.delayed(const Duration(seconds: 20));
      final rates = <double>{};
      final seenFor = <double, int>{};
      final worst = <int>[];
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        rates.add(engine.speed);
        seenFor[engine.speed] = (seenFor[engine.speed] ?? 0) + 1;
        worst.add(apart().inMilliseconds.abs());
      }
      worst.sort();
      // The rate it is *at*, which is the one it spends its time at: a one-shot lean
      // closing a standing offset is a speed too, and reading the engine in the middle
      // of one says less than the truth.
      final settledAt =
          seenFor.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

      expect(rates.length, lessThan(4),
          reason: 'the rate was still moving: ${rates.length} different speeds in ten '
              'seconds, and it sits at $settledAt');
      expect(worst.last, lessThan(14),
          reason: 'and it did not hold: worst ${worst.last} ms');
      // On the *right* rate, not merely a quiet one: an engine running a tenth of a
      // percent fast has to be asked for a tenth less.
      expect(settledAt, closeTo(1 / 1.001, 0.0004),
          reason: 'it stopped moving without ever learning the drift: $settledAt');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('what the wrap costs settles instead of swinging about', () async {
      // Straight off the desk it went wrong on: +29, -11, +13, -1, +78, -25, -23,
      // +97, -33 ms, and an end pulled 7, 0, 7, 0, 19, 13, 1, 24, 15 ms early after
      // them. Never settling — and a loop end that moves by twenty milliseconds is a
      // loop musically short by twenty milliseconds, which at a couple of seconds a
      // time is ten milliseconds a second of drift against the other deck. "Timing
      // off" and "collides phase wise" were one fault.
      //
      // The cause was reading a thirty-millisecond effect off the clock of the
      // position reports, which arrive a couple of hundred milliseconds apart.
      //
      // Said plainly: this cannot reproduce that. The noisy path is the engine's own
      // loop — mpv's ab-loop, seen only through position reports — and on this fake
      // the engine has no loop, so the deck's own watcher runs and times its wraps
      // from the moment it asks for the seek, which is exact. What this pins is that
      // the averaging works and that the answer stops moving; the evidence that it
      // needed to is the log from the desk it went wrong on, quoted above.
      Deck.loopLate = Duration.zero;
      addTearDown(() => Deck.loopLate = Duration.zero);
      final engine = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.b.player.platformId!]!;
      engine.seekCost = const Duration(milliseconds: 25);
      engine.reportEvery = const Duration(milliseconds: 200);
      await booth.b.seek(const Duration(seconds: 10));
      await booth.b.play();
      booth.b.loop(2);
      addTearDown(booth.b.unloop);

      // Watched over a long run: what is asked is that the answer stops moving.
      final seenAt = <int>[];
      final began = DateTime.now();
      while (DateTime.now().difference(began) < const Duration(seconds: 24)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final ms = Deck.loopLate.inMilliseconds;
        if (seenAt.isEmpty || seenAt.last != ms) seenAt.add(ms);
      }
      expect(seenAt.length, greaterThan(1),
          reason: 'it never measured anything at all: $seenAt');
      // The swings are what this is about: once it has a figure it must not keep
      // throwing it away. Every answer after the first two is close to the last.
      var lurches = 0;
      for (var i = 2; i < seenAt.length; i++) {
        if ((seenAt[i] - seenAt[i - 1]).abs() > 12) lurches++;
      }
      expect(lurches, lessThan(2),
          reason: 'it swung about instead of settling: $seenAt');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a slow drift is caught, not leaned against for ever', () async {
      // "Sync sometimes drifts over time and doesn't catch itself." Not loops — this
      // is a record whose rate is only slightly wrong.
      //
      // Two hundredths of a percent: 0.2 ms a second, 12 ms a minute. Nothing over ten
      // seconds; a flam by the end of a record. What is asked is that it is found and
      // taken off the rate rather than leaned against again and again.
      //
      // Said plainly: this passes against the code it was written for as well. The
      // fault it was aimed at — a lean throwing away the window the slope is fitted
      // over, so the rate is never trimmed — needs the lean to fire before the window
      // is long enough to trim, and with drift alone the trim always wins that race.
      // It is kept because a drift this slow being caught at all is worth pinning, and
      // the change it went with (keeping the window across a lean, and fitting over
      // three quarters of a minute rather than sixteen seconds) stands on its own:
      // evidence should not be thrown away to close an offset.
      final engine = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.b.player.platformId!]!;
      engine.reportEvery = const Duration(milliseconds: 100);
      engine.clockSkew = 0.0002;
      await booth.setCrossfader(0.5);
      await booth.b.seek(booth.a.position);
      await booth.b.play();
      booth.holdOnBeat(booth.b, snap: true);

      // Long enough for a slope that slow to be worth reading.
      await Future<void>.delayed(const Duration(seconds: 55));
      final settled = engine.speed;
      // It found the drift and took it off the rate, rather than sitting at the rate
      // it started with and leaning against the same gap over and over.
      expect((settled - 1.0).abs(), greaterThan(0.00008),
          reason: 'the rate was never trimmed at all: $settled');
      expect(settled, closeTo(1 / 1.0002, 0.00025),
          reason: 'it trimmed, but not to the drift it actually had: $settled');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a master going round a loop is still something to be held to', () async {
      // "Beat match still needs work, especially when looping one track." The hold
      // used to stop dead for as long as the master had a loop on — a loop was lumped
      // in with braking, where the tempo really is running away — so the follower
      // free-ran at whatever rate it happened to have for the whole of it. A record
      // going round four bars is still perfectly on the beat and is exactly the thing
      // a follower has to be held to.
      await booth.setCrossfader(0.5);
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 40));
      await booth.b.play();
      booth.holdOnBeat(booth.b);

      /// Waited for rather than timed, and it has to *stay* settled: six readings
      /// running inside twelve milliseconds.
      ///
      /// One reading is not enough. A master coming round its loop moves by a whole
      /// phrase, and a reading taken across that jump jumps with it — asking for a
      /// single dip near nought made this test pass against the very fault it was
      /// written for. A fixed deadline is no good either: settling is no longer a
      /// chase, it is a measured lean over a couple of seconds, and on a busy machine
      /// the timers behind that are late by however busy it is.
      Future<int> settles() async {
        var best = 999, running = 0;
        for (var i = 0; i < 260; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final ms = apart().inMilliseconds.abs();
          running = ms < 12 ? running + 1 : 0;
          if (running >= 6) return ms;
          if (i > 20 && ms < best) best = ms;
        }
        return best;
      }

      final held = await settles();
      expect(held, lessThan(15), reason: 'never settled before the loop: $held ms');

      // Four bars, from the master's next downbeat.
      booth.a.loop(16);
      addTearDown(booth.a.unloop);
      // Knocked off the beat while the loop runs. Before, nothing would have pulled
      // it back for as long as the loop was on.
      await booth.b.nudge(const Duration(milliseconds: 55));
      // Where it ends up, not how fast it gets there. Before, nothing pulled it back
      // at all for as long as the loop was on: it simply stayed 55 ms out.
      final after = await settles();
      expect(after, lessThan(20),
          reason: 'left adrift while the master looped: $after ms');
      final worst = <int>[];
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        worst.add(apart().inMilliseconds.abs());
      }
      worst.sort();
      expect(worst.last, lessThan(26),
          reason: 'it went through rather than settling: worst ${worst.last} ms');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a short loop does not have its phrase corrected out from under it', () async {
      // The other half of the same rule, and a fault of this booth's own making: a
      // one-bar loop puts the record back four beats every bar, so where it sits in
      // the sixteen cycles by design. Measured through the phrase that reads as four
      // beats out and the hold moves the record to "fix" it — every bar, for as long
      // as the loop is on. While either deck is looping, the beat is held and the
      // phrase is left alone.
      await booth.setCrossfader(0);
      await booth.b.seek(booth.a.position);
      await booth.b.play();
      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(seconds: 2));
      booth.b.loop(4); // one bar
      addTearDown(booth.b.unloop);
      final was = booth.b.loopStart;
      var moved = 0;
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // The loop's own bounds must not wander, and the record must stay inside them.
        if (booth.b.loopStart != was) moved++;
      }
      expect(moved, 0, reason: 'the loop was moved under the record $moved times');
      final p = booth.b.position;
      expect(p >= booth.b.loopStart! - const Duration(milliseconds: 60), isTrue,
          reason: 'the record was pushed out of its own loop');
      expect(p <= booth.b.loopEnd! + const Duration(milliseconds: 60), isTrue,
          reason: 'the record was pushed out of its own loop');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a record already on the phrase is left where it is', () async {
      await booth.setCrossfader(0);
      await booth.b.seek(booth.a.position);
      await booth.b.play();
      final was = booth.b.position;
      booth.holdOnBeat(booth.b);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(Booth.beatsOutOfPhrase(booth.b, booth.a), 0);
      // Not shoved a phrase sideways for nothing: whatever it moved is small.
      final moved = (booth.b.position - was).inMilliseconds.abs();
      expect(moved, lessThan(1400), reason: 'moved $moved ms');
      await booth.letGo();
    });

    // What the phone actually gave the booth to work with, and what it gives it now.
    //
    // just_audio tells Dart where a record is when something happens to it and at no
    // other time; between those, Dart carries the position forward itself at the speed
    // it asked for. For a seek bar that is plenty. For holding two records on one beat
    // it means the loop is measuring its own arithmetic: the engine takes a couple of
    // hundred milliseconds to actually play at a rate it has been told, the deck
    // believes the new rate at once, and nothing ever arrives to say otherwise. Every
    // bend therefore lands as a lie the loop cannot catch, and they add up.
    //
    // These two are the same fault and the same loop, with the engine speaking and
    // not speaking. The fix is not in this file: it is the positionWatcher in the
    // Android plugin and tellThePosition in the iOS one, which is what reportEvery
    // stands for here.
    Future<({int worst, int crossings})> holdWith(
        {required Duration reportEvery}) async {
      final engine = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.b.player.platformId!]!;
      engine.speedLag = const Duration(milliseconds: 250);
      engine.reportEvery = reportEvery;
      await booth.setCrossfader(0.5); // heard, so only the bend may act
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 45));
      await booth.b.play();
      booth.holdOnBeat(booth.b);
      final other = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.a.player.platformId!]!;
      // Measured off the two engines, not off the two decks: see truePosition.
      double heard() => Booth.beatError(
            follower: booth.b.timing!,
            followerAt: engine.truePosition,
            followerRate: booth.b.tempo,
            master: booth.a.timing!,
            masterAt: other.truePosition,
            masterRate: booth.a.tempo,
          )!.inMicroseconds / 1000;
      var crossings = 0, last = 0, worst = 0;
      for (var i = 0; i < 160; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final ms = heard().round();
        final side = ms > 4 ? 1 : (ms < -4 ? -1 : 0);
        if (side != 0) {
          if (last != 0 && side != last) crossings++;
          last = side;
        }
        if (i > 100 && ms.abs() > worst) worst = ms.abs();
      }
      await booth.letGo();
      return (worst: worst, crossings: crossings);
    }

    // Said plainly, because the next person to read this will want to know: an engine
    // that says nothing also passes, in this model. Everything the fake gets wrong
    // between reports — the rate taking hold late — it gets wrong for a fraction of a
    // second and then stops, and a loop can ride that out blind. What a real engine
    // also does, and this does not, is run on a clock that is not the system's at all.
    // So the plugin change is not justified by this test and is not claimed to be: it
    // is justified by the loop having had no measurement to work from, which is not a
    // thing a loop can be asked to do. This test holds the other end — that the engine
    // speaking does not upset anything.
    test('an engine that says where it is, is held', () async {
      final r = await holdWith(reportEvery: const Duration(milliseconds: 100));
      expect(r.worst, lessThan(20),
          reason: 'never settled: still ${r.worst} ms out after four seconds');
      expect(r.crossings, lessThan(6), reason: 'it hunted: ${r.crossings} swings either side');
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('an engine that is slow to take a rate does not make it hunt', () async {
      // The fault: "sync drifts heavily, might be overcompensating, never stays at
      // the optimal point". A phone's engine plays what it has already buffered at
      // the old rate for a couple of hundred milliseconds after being told a new one,
      // while the deck has already started reckoning its position at the new one. So
      // the error looks like it is closing before any of it has happened, the pull is
      // eased off, the real correction lands late, and it sails past — over and over.
      final engine = (JustAudioPlatform.instance as FakeJustAudio)
          .players[booth.b.player.platformId!]!;
      engine.speedLag = const Duration(milliseconds: 250);

      await booth.setCrossfader(0.5); // heard, so only the bend may act
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 45));
      await booth.b.play();
      booth.holdOnBeat(booth.b);

      // Watched for long enough that a hunting loop would have shown it.
      var crossings = 0, last = 0, worstAfterSettling = 0;
      for (var i = 0; i < 160; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final ms = apart().inMilliseconds;
        final side = ms > 4 ? 1 : (ms < -4 ? -1 : 0);
        if (side != 0) {
          if (last != 0 && side != last) crossings++;
          last = side;
        }
        // After five seconds it should be settled and staying settled. The error is
        // put inside the proportional band on purpose — above it the pull is at its
        // stop and what is being measured is how fast it closes, not whether it
        // hunts, and hunting is the fault here.
        if (i > 100 && ms.abs() > worstAfterSettling) worstAfterSettling = ms.abs();
      }
      expect(worstAfterSettling, lessThan(20),
          reason: 'never settled: still $worstAfterSettling ms out after 4 s');
      expect(crossings, lessThan(6), reason: 'it hunted: $crossings swings either side');
      await booth.letGo();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('SYNC places the record at once, the way a DJ deck does', () async {
      // A deck's SYNC is instant: it works out the offset from the two grids and
      // *puts* the record there, then holds the rate ratio. It does not ease the
      // record into place over seconds, and neither should this.
      await booth.setCrossfader(0.5); // audible, as a hand pressing SYNC usually is
      await booth.b.seek(Duration(milliseconds: booth.a.position.inMilliseconds + 200));
      await booth.b.play();
      expect(apart().inMilliseconds.abs(), greaterThan(150));

      booth.holdOnBeat(booth.b, snap: true);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(apart().inMilliseconds.abs(), lessThan(15),
          reason: 'still ${apart().inMilliseconds} ms out after 450 ms');
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
    expect(AutoMix.choose(solo, baron), (kind: Transition.fade, bars: 4),
        reason: '84.5 against 103.5 cannot be one tempo: a quick handover');
    expect(AutoMix.choose(baron, whatcha).kind, Transition.cut,
        reason: 'a cold ending into a different speed: on the downbeat');
  });

  group('the desk\'s filter chain is turned, never rebuilt', () {
    Map<String, String> said(EqSet eq, double filter) => {
          for (final (target, command, value) in DesktopMixer.commands(eq: eq, filter: filter))
            '$target $command': value,
        };

    test('a kill is the one band turned off, not a shelf leaned on', () {
      // The bands are split and each has a level of its own now, so a kill is that
      // band's level and nothing else's — where a shelf's gain took the neighbouring
      // bands down with it (measured: killing LOW cost 7 dB at 700 Hz).
      final c = said(const EqSet(low: EqSet.killed), 0);
      expect(c['volume@low volume'], '-40.0dB');
      expect(c['volume@mid volume'], '0.0dB');
      expect(c['volume@high volume'], '0.0dB');
      expect(c['highpass@hp m'], '0', reason: 'the passes are out of the sound');
      expect(c['lowpass@lp m'], '0');
    });

    test('the split is a Linkwitz-Riley pair, which is what sums flat', () {
      // Two cascaded Butterworths a side at each crossover: one alone leaves a dip
      // where the bands meet, and the bands have to add back up to the record.
      final chain = DesktopMixer.bands;
      expect('lowpass=f=${DesktopMixer.lowCross}:p=2'.allMatches(chain).length, 2);
      expect('highpass=f=${DesktopMixer.lowCross}:p=2'.allMatches(chain).length, 2);
      expect('lowpass=f=${DesktopMixer.highCross}:p=2'.allMatches(chain).length, 2);
      expect('highpass=f=${DesktopMixer.highCross}:p=2'.allMatches(chain).length, 2);
      expect(chain, contains('amix=inputs=3:normalize=0'),
          reason: 'added back at unity, not averaged');
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
      // Rubber Band first and asked for the most, scaletempo2 last — with the
      // plainer asks in between, so an mpv that does not know one of the words falls
      // to a lesser Rubber Band rather than all the way to the one that moves the
      // beat about.
      expect(DesktopMixer.standing.first, contains('rubberband'),
          reason: 'the stretcher that keeps beats where they belong, first');
      expect(DesktopMixer.standing.first, contains('channels=together'),
          reason: 'the two sides stretched as one, or the stereo swims');
      expect(DesktopMixer.standing.last, endsWith('scaletempo2'),
          reason: 'and a stretcher always there, so a tempo change never changes the chain');
      expect(DesktopMixer.standing.any((c) => c.endsWith('@rb:rubberband')), isTrue,
          reason: 'plain Rubber Band is tried before scaletempo2');
      // Every tier carries the bands, and every Rubber Band tier is labelled so its
      // pitch can still be spoken to.
      for (final c in DesktopMixer.standing) {
        expect(c, contains('@wetowl:lavfi=['));
        if (c.contains('rubberband')) expect(c, contains('@rb:rubberband'));
      }
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
    expect(AutoMix.choose(master, next), (kind: Transition.fade, bars: 4),
        reason: 'judged by the made tempo it would have been a handover');
    expect(AutoMix.howWell(master, next, fromPitch: pitch),
        greaterThan(AutoMix.howWell(master, next)));
  });
}
