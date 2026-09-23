// Two records on the deck: the sums a mixer does, checked against a fake engine.
//
// The screen for this is not here yet; what is here is the engine — the fader's
// curve, sync, where the next downbeat is, what a transition does and when — and
// those are the parts that are hard to hear wrong and easy to prove right.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';

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
  final levels = <Map<String, double>>[];
  final kills = <(String, ({bool low, bool mid, bool high}))>[];
  @override
  bool get canKill => true;
  @override
  bool get canFilter => false;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    this.levels.add({for (final e in levels.entries) e.key.name: e.value});
  }

  @override
  Future<void> setKills(Deck deck, {bool low = false, bool mid = false, bool high = false}) async {
    kills.add((deck.name, (low: low, mid: mid, high: high)));
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

void main() {
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
      expect(steps.first.kills['B']?.low, isTrue, reason: 'the incoming enters without bass');
      final half = steps.firstWhere((s) => s.at == 0.5);
      expect(half.kills['B']?.low, isFalse);
      expect(half.kills['A']?.low, isTrue, reason: 'the bass swaps at the middle');
      expect(steps.last.crossfader, 1);
      expect(steps.last.kills['A'], (low: false, mid: false, high: false),
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
