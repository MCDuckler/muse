// The board's voices: that a warmed pad is a player parked at its start, that a
// press is a seek and a play, that the four modes do what they say, that a choke
// group is one at a time, and that a bank turned away from keeps only what sounds.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/sampler.dart';
import 'package:muse/src/state/booth/board/samples.dart';

import 'fake_audio.dart';

/// A library whose kit renders to a name rather than a file.
SampleLibrary library() => SampleLibrary(sink: (Uint8List wav, String key) async => '/sounds/$key.wav');

const impact = PadSpec(sampleId: SampleKit.impact, name: 'IMPACT');
const hold = PadSpec(sampleId: SampleKit.hydrant, name: 'HYDRANT', mode: PadMode.hold);
const loop = PadSpec(
    sampleId: SampleKit.sweepUp, name: 'LOOP', mode: PadMode.loop, trimOut: Duration(milliseconds: 60));
const short = PadSpec(sampleId: SampleKit.impact, name: 'SHORT', trimOut: Duration(milliseconds: 40));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio engine;

  setUp(() {
    engine = FakeJustAudio();
    JustAudioPlatform.instance = engine;
  });

  Sampler sampler({int most = 20}) => Sampler(library: library(), most: most);

  FakeAudioPlayer playerOf(Voice v) => engine.players.values.firstWhere((p) => p.sources.isNotEmpty);

  test('a warmed pad is a player with the sound in it, parked, at its level', () async {
    final s = sampler();
    final v = await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 0.5);
    expect(v, isNotNull);
    expect(engine.players.length, 1);
    final p = engine.players.values.single;
    expect(p.sources.single, contains('kit-impact'));
    expect(p.playing, isFalse);
    expect(p.volume, 0.5);
    expect(v!.sounding, isFalse);
    await s.dispose();
  });

  test('warming the same sound again keeps the player; a different one loads over it', () async {
    final s = sampler();
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    final p = engine.players.values.single;
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact.copyWith(gain: 0.5), level: 0.5);
    expect(engine.players.length, 1);
    int loads() => p.calls.where((c) => c.startsWith('load')).length;
    expect(loads(), 1, reason: 'the same sound is not loaded twice');
    await s.warm('A:1', SampleKit.byId(SampleKit.sweepUp)!, impact.copyWith(sampleId: SampleKit.sweepUp), level: 1);
    expect(loads(), 2);
    expect(p.sources.last, contains('sweepUp'));
    await s.dispose();
  });

  test('a press is a seek to the start and a play; the voice sounds until the engine says it ended', () async {
    final s = sampler();
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    var pings = 0;
    s.changed.addListener(() => pings++);
    await s.fire('A:1');
    // play() is let go of, not waited for: just_audio's play completes when the
    // sound is over, which for a riser is sixteen seconds.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final p = engine.players.values.single;
    expect(p.playing, isTrue);
    expect(p.calls.last, 'play');
    expect(s.voices['A:1']!.sounding, isTrue);
    expect(pings, 1);
    p.reachEnd();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.voices['A:1']!.sounding, isFalse);
    expect(pings, 2);
    expect(p.position, Duration.zero, reason: 'parked at the start again for the next press');
    await s.dispose();
  });

  test('a one-shot pressed again starts over', () async {
    final s = sampler();
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    await s.fire('A:1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final p = engine.players.values.single;
    p.tick(const Duration(milliseconds: 300));
    await s.fire('A:1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // just_audio says nothing to an engine that already plays: the restart is the seek.
    expect(p.calls.where((c) => c.startsWith('seek')).length, greaterThanOrEqualTo(3),
        reason: 'parked, fired, fired again');
    expect(p.playing, isTrue);
    expect(p.position, Duration.zero);
    await s.dispose();
  });

  test('a hold let go fades in steps and parks; pressed again it is loud again', () async {
    final s = sampler();
    await s.warm('A:5', SampleKit.byId(SampleKit.hydrant)!, hold, level: 0.9);
    await s.fire('A:5');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final v = s.voices['A:5']!;
    expect(v.held, isTrue);
    final p = engine.players.values.single;
    final before = p.calls.length;
    await s.release('A:5');
    expect(v.sounding, isFalse);
    expect(v.held, isFalse);
    expect(p.playing, isFalse);
    expect(p.volume, 0.9, reason: 'back up after the fade, ready for the next press');
    expect(p.calls.sublist(before), containsAllInOrder(['pause', 'seek 0s']),
        reason: 'paused and parked — a stopped player gives its engine up');
    expect(p.calls.sublist(before), isNot(contains('stop')));
    await s.fire('A:5');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(p.playing, isTrue);
    await s.dispose();
  });

  test('a sound the engine finished is paused before it is parked, so it does not play itself again',
      () async {
    final s = sampler();
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    await s.fire('A:1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final p = engine.players.values.single;
    final before = p.calls.length;
    // The file is a few frames shorter than its length says: the engine ends first.
    p.reachEnd();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(s.voices['A:1']!.sounding, isFalse);
    expect(p.playing, isFalse, reason: 'just_audio keeps playing past the end; a seek on it plays');
    expect(p.calls.sublist(before), containsAllInOrder(['pause', 'seek 0s']));
    expect(p.position, Duration.zero);
    await s.dispose();
  });

  test('a press during a fade wins: the fade stops touching the player', () async {
    final s = sampler();
    await s.warm('A:5', SampleKit.byId(SampleKit.hydrant)!, hold, level: 0.9);
    await s.fire('A:5');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final v = s.voices['A:5']!;
    final p = engine.players.values.single;
    // Let go, and pressed again 5 ms into the 30 ms fade.
    final letGo = s.release('A:5');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final before = p.calls.length;
    await s.fire('A:5');
    await letGo;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(v.sounding, isTrue);
    expect(p.playing, isTrue, reason: 'the stale fade used to pause the new sound');
    expect(p.volume, 0.9, reason: 'back up to its level before it sounded');
    expect(p.calls.sublist(before), isNot(contains('pause')));
    await s.dispose();
  });

  test('a press while the sound is still loading waits for it', () async {
    final s = sampler();
    engine.slowness = const Duration(milliseconds: 60);
    final warming = s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.voices['A:1'], isNotNull, reason: 'the voice exists before its sound is in');
    final fired = s.fire('A:1');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final p = engine.players.values.single;
    expect(p.calls.where((c) => c == 'play'), isEmpty, reason: 'nothing to play yet');
    await warming;
    await fired;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(p.calls, contains('play'));
    expect(s.voices['A:1']!.sounding, isTrue);
    expect(p.calls.indexOf('play'), greaterThan(p.calls.indexWhere((c) => c.startsWith('load'))));
    await s.dispose();
  });

  test('a trim-out before the end stops the sound there; a loop goes round', () async {
    final s = sampler();
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, short, level: 1);
    await s.fire('A:1');
    expect(s.voices['A:1']!.sounding, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(s.voices['A:1']!.sounding, isFalse);

    await s.warm('A:2', SampleKit.byId(SampleKit.sweepUp)!, loop, level: 1);
    await s.fire('A:2');
    final p = playerOf(s.voices['A:2']!);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(s.voices['A:2']!.sounding, isTrue, reason: 'a loop keeps going');
    expect(p.calls.where((c) => c.startsWith('seek')).length, greaterThanOrEqualTo(3),
        reason: 'parked, fired, and round at least once');
    await s.stop(key: 'A:2');
    expect(s.voices['A:2']!.sounding, isFalse);
    await s.dispose();
  });

  test('a choke group is one at a time', () async {
    final s = sampler();
    const g = PadSpec(sampleId: SampleKit.impact, name: 'X', choke: 2);
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, g, level: 1);
    await s.warm('A:2', SampleKit.byId(SampleKit.sweepUp)!, g.copyWith(sampleId: SampleKit.sweepUp), level: 1);
    await s.warm('A:3', SampleKit.byId(SampleKit.hydrant)!, g.copyWith(sampleId: SampleKit.hydrant, choke: 1), level: 1);
    await s.fire('A:1');
    await s.fire('A:3');
    await s.choke(2, except: 'A:2');
    await s.fire('A:2');
    expect(s.voices['A:1']!.sounding, isFalse, reason: 'the same group');
    expect(s.voices['A:2']!.sounding, isTrue);
    expect(s.voices['A:3']!.sounding, isTrue, reason: 'another group');
    await s.dispose();
  });

  test('cooling keeps what sounds and what is asked for, and lets the rest go', () async {
    final s = sampler();
    for (final (k, id) in [('A:1', SampleKit.impact), ('A:2', SampleKit.sweepUp), ('B:1', SampleKit.hydrant)]) {
      await s.warm(k, SampleKit.byId(id)!, impact.copyWith(sampleId: id), level: 1);
    }
    await s.fire('A:2');
    await s.cool({'B:1'});
    expect(s.voices.keys, unorderedEquals(['A:2', 'B:1']));
    expect(engine.players.length, 2);
    await s.dispose();
  });

  test('past its most, the quiet voice pressed longest ago gives up its player', () async {
    final s = sampler(most: 2);
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    await s.warm('A:2', SampleKit.byId(SampleKit.sweepUp)!, impact.copyWith(sampleId: SampleKit.sweepUp), level: 1);
    await s.fire('A:1');
    await s.warm('A:3', SampleKit.byId(SampleKit.hydrant)!, impact.copyWith(sampleId: SampleKit.hydrant), level: 1);
    expect(s.voices.keys, unorderedEquals(['A:1', 'A:3']), reason: 'A:2 was quiet, A:1 sounds');
    await s.dispose();
  });

  test('the level goes to the engine through its own law', () async {
    final s = Sampler(library: library(), playerVolume: (x) => x * x);
    await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 0.5);
    expect(engine.players.values.single.volume, closeTo(0.25, 1e-9));
    await s.setLevel('A:1', 1.0);
    expect(engine.players.values.single.volume, 1.0);
    await s.dispose();
  });

  test('a sound that can be put nowhere is no voice, and not a crash', () async {
    final s = Sampler(library: SampleLibrary(sink: (Uint8List wav, String key) async => null));
    final v = await s.warm('A:1', SampleKit.byId(SampleKit.impact)!, impact, level: 1);
    expect(v, isNull);
    expect(s.voices, isEmpty);
    expect(s.can, isFalse);
    await s.fire('A:1');
    await s.dispose();
  });
}
