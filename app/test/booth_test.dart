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
      expect(steps.first.kills['B']?.lowKilled, isTrue,
          reason: 'the incoming enters without bass');
      final half = steps.firstWhere((s) => s.at == 0.5);
      expect(half.kills['B']?.lowKilled, isFalse);
      expect(half.kills['A']?.lowKilled, isTrue, reason: 'the bass swaps at the middle');
      expect(steps.last.crossfader, 1);
      expect(steps.last.kills['A']?.isFlat, isTrue,
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

  test('the transition is chosen from what is known about the two records', () {
    expect(AutoMix.choose(t(bpm: 128, camelot: '8A'), t(bpm: 130, camelot: '9A')),
        (kind: Transition.blend, bars: 16), reason: 'in key, in tempo: the long blend');
    expect(AutoMix.choose(t(bpm: 128, camelot: '8A'), t(bpm: 130, camelot: '3B')),
        (kind: Transition.blend, bars: 8), reason: 'a clash is shorter');
    expect(AutoMix.choose(t(bpm: 128), t(bpm: 150)).kind, Transition.fade,
        reason: 'too far apart to sync');
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

  test('the mix is moved to the phrase it is nearest', () {
    // 128 bpm: a bar is 1875 ms, a phrase 30 s. Phrases at 0, 30, 60, 90 s.
    final t = TrackTiming(
      durationMs: 200000,
      bpm: 128,
      beats: [for (var i = 0; i < 400; i++) (i * 468.75).round()],
      phrases: [0, 30000, 60000, 90000],
    );
    expect(AutoMix.onPhrase(t, const Duration(seconds: 62)), const Duration(seconds: 60),
        reason: 'a mix four bars into a phrase lands four bars into the next');
    expect(AutoMix.onPhrase(t, const Duration(seconds: 88)), const Duration(seconds: 90));
    // Nowhere near one: left where it was rather than dragged half a minute.
    expect(AutoMix.onPhrase(t, const Duration(seconds: 120)), const Duration(seconds: 120));
    expect(AutoMix.onPhrase(const TrackTiming(), const Duration(seconds: 5)),
        const Duration(seconds: 5), reason: 'no phrases, nothing to move it to');
  });

  test('the outgoing goes at its outro; the incoming is parked before its intro ends', () {
    final from = t(bpm: 128);
    expect(AutoMix.outPoint(from, length: const Duration(seconds: 30)), const Duration(milliseconds: 160000));
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
