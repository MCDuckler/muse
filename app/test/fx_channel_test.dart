// The third voice: that a plan's sounds are rendered and loaded before the move runs,
// that firing one plays it from its first sample, and that a platform which can put a
// rendered sound nowhere says so rather than going quiet half way through a mix.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/state/booth/fx_channel.dart';
import 'package:muse/src/state/booth/fx_sounds.dart';

import 'fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio engine;

  setUp(() {
    engine = FakeJustAudio();
    JustAudioPlatform.instance = engine;
  });

  test('every shot in a plan gets a player of its own, loaded', () async {
    final fx = FxChannel();
    final loaded = await fx.load(const [
      (shot: FxShot(FxSound.riser, span: 1), seconds: 2.0),
      (shot: FxShot(FxSound.impact, beats: 4), seconds: 1.0),
    ], beat: 0.5);
    expect(loaded, 2);
    expect(engine.players.length, 2, reason: 'one sound cannot be played by half a player');
    for (final p in engine.players.values) {
      expect(p.sources, isNotEmpty);
    }
    await fx.dispose();
  });

  test('a shot with no length is not loaded at all', () async {
    final fx = FxChannel();
    final loaded = await fx.load(const [
      (shot: FxShot(FxSound.sweepUp, span: 0.5), seconds: 0.0),
    ], beat: 0.5);
    expect(loaded, 0);
    await fx.dispose();
  });

  test('the same sound twice over is rendered once', () async {
    final fx = FxChannel();
    await fx.load(const [(shot: FxShot(FxSound.hydrant, span: 1), seconds: 1.0)], beat: 0.5);
    final first = engine.players.values.last.sources.last;
    await fx.load(const [(shot: FxShot(FxSound.hydrant, span: 1), seconds: 1.0)], beat: 0.5);
    expect(engine.players.values.last.sources.last, first,
        reason: 'a set of eleven risers should render one');
    await fx.dispose();
  });

  test('a shot fires from its first sample, and silence stops it', () async {
    final fx = FxChannel();
    await fx.load(const [(shot: FxShot(FxSound.impact, beats: 4), seconds: 0.5)], beat: 0.5);
    final player = engine.players.values.last;
    player.calls.clear();
    await fx.fire(0);
    await Future<void>.delayed(Duration.zero);
    expect(player.calls, contains('seek 0s'), reason: 'a shot plays from its first sample');
    await fx.silence();
    await fx.dispose();
  });

  test('firing a slot nothing was loaded into does nothing', () async {
    final fx = FxChannel();
    await expectLater(fx.fire(2), completes);
    await fx.dispose();
  });

  test('the gain is what the engine is told, through the engine\'s own law', () async {
    final fx = FxChannel();
    await fx.load(const [(shot: FxShot(FxSound.riser, span: 1, gainDb: -12), seconds: 1.0)],
        beat: 0.5, volume: (g) => g * g);
    // -12 dB is a gain of 0.251; squared, as a cube-law engine would want it, 0.063.
    expect(engine.players.values.last.volume, closeTo(0.063, 0.002));
    await fx.dispose();
  });

  test('a player that will not take a sound does not stop the mix', () async {
    final fx = FxChannel(newPlayer: () => throw StateError('no engine here'));
    await expectLater(
        fx.load(const [(shot: FxShot(FxSound.riser, span: 1), seconds: 1.0)], beat: 0.5),
        completion(0));
    await fx.dispose();
  });
}
