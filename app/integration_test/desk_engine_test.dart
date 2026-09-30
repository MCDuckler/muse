// The desk's sound engine, on the machine it is built on: libmpv loads, plays, and
// takes the booth's filter chains — the booth's Engine check without a person or a
// library. Run by .github/workflows/desktop.yml on the Mac, which nobody here has in
// front of them:
//
//   flutter test integration_test/desk_engine_test.dart -d macos
//
// A build machine has no speakers, so mpv is given its null output: everything up to
// the sound card — the decoders, the filters, the clock the booth steers by — is the
// real thing.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:muse/src/state/booth/mixer_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('libmpv plays and takes the desk\'s chains', (tester) async {
    // As main() sets it up on a desk.
    JustAudioMediaKit.pitch = false;
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: true);
    expect(JustAudioMediaKit.instanceIfRegistered, isNotNull, reason: 'libmpv did not start');

    final dir = await Directory.systemTemp.createTemp('wetowl-engine-');
    addTearDown(() => dir.delete(recursive: true));
    final clicks = File('${dir.path}/clicks.wav')..writeAsBytesSync(_wav(seconds: 30, channels: 2));
    final six = File('${dir.path}/six.wav')..writeAsBytesSync(_wav(seconds: 10, channels: 6));

    final player = AudioPlayer();
    addTearDown(player.dispose);
    await player.setVolume(0.25);
    await player.setFilePath(clicks.path);
    final mpv = _native(player);
    expect(mpv, isNotNull, reason: 'the player is not on libmpv');
    await mpv!.setProperty('ao', 'null');
    // ignore: avoid_print
    print('mpv ${await mpv.getProperty('mpv-version')} · ffmpeg ${await mpv.getProperty('ffmpeg-version')}');

    // What the booth's stems are: Opus, in Ogg.
    final decoders = await mpv.getProperty('decoder-list');
    expect(decoders, contains('opus'), reason: 'no Opus decoder: the stems will not play');

    unawaited(player.play());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final from = player.position;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final moved = player.position - from;
    expect(moved.inMilliseconds, greaterThan(1000), reason: 'it is not playing: moved $moved');

    // The desk's chains, in the order it tries them. The first one that goes on is
    // what a deck plays through: a Mac has no Rubber Band, so it should be the ceiling
    // with scaletempo2.
    String? took;
    for (final chain in DesktopMixer.standingFor(500)) {
      try {
        await mpv.setProperty('af', chain);
        if ((await mpv.getProperty('af')).contains('wetowl')) {
          took = chain;
          break;
        }
      } catch (_) {}
    }
    expect(took, isNotNull, reason: 'none of the desk\'s chains went on');
    // ignore: avoid_print
    print('chain: $took');
    expect(took, contains('alimiter'), reason: 'the chain that went on has no ceiling');

    // Turned while it plays, as the kills and the filter are.
    for (final (target, value) in const [
      ('volume@low', '0.01'),
      ('volume@low', '1'),
      ('volume@es', '0.5'),
    ]) {
      await mpv.command(['af-command', 'wetowl', 'volume', value, target]);
    }
    await mpv.command(['af-command', 'wetowl', 'f', '400', 'highpass@hp']);

    // Tempo held while synced to a faster record.
    await player.setSpeed(1.04);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final at = player.position;
    final clock = Stopwatch()..start();
    await Future<void>.delayed(const Duration(seconds: 4));
    final ratio = (player.position - at).inMicroseconds / clock.elapsedMicroseconds;
    // ignore: avoid_print
    print('at 1.04×: ${ratio.toStringAsFixed(4)}×');
    expect(ratio, closeTo(1.04, 0.03));
    await player.setSpeed(1);
    await player.stop();

    // Six channels, as a record's stems are, and the stem chain on them.
    await player.setFilePath(six.path);
    final mpv2 = _native(player)!;
    await mpv2.setProperty('ao', 'null');
    await mpv2.setProperty('ad-lavc-downmix', 'no');
    unawaited(player.play());
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await mpv2.getProperty('audio-params/channel-count'), '6');
    var stems = false;
    for (final chain in DesktopMixer.stemStandingFor(500)) {
      try {
        await mpv2.setProperty('af', chain);
        if ((await mpv2.getProperty('af')).contains('wetowl')) {
          stems = true;
          break;
        }
      } catch (_) {}
    }
    expect(stems, isTrue, reason: 'none of the stem chains went on');
    await mpv2.command(['af-command', 'wetowl', 'volume', '0', 'volume@v']);
    await player.stop();
  });
}

NativePlayer? _native(AudioPlayer p) {
  final id = p.platformId;
  final raw = id == null ? null : JustAudioMediaKit.instanceIfRegistered?.playerFor(id)?.raw;
  final platform = raw?.platform;
  return platform is NativePlayer ? platform : null;
}

/// A click every half second in every channel, as 16-bit PCM.
Uint8List _wav({required int seconds, required int channels}) {
  const rate = 44100;
  final frames = rate * seconds;
  final pcm = Int16List(frames * channels);
  const every = rate ~/ 2;
  for (var i = 0; i < frames; i++) {
    final at = i % every;
    if (at >= 220) continue;
    final v = (math.sin(2 * math.pi * 1000 * at / rate) * 20000 * (1 - at / 220)).round();
    for (var c = 0; c < channels; c++) {
      pcm[i * channels + c] = v;
    }
  }
  final data = pcm.buffer.asUint8List();
  final b = BytesBuilder();
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  b.add('RIFF'.codeUnits);
  u32(36 + data.length);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(channels);
  u32(rate);
  u32(rate * channels * 2);
  u16(channels * 2);
  u16(16);
  b.add('data'.codeUnits);
  u32(data.length);
  b.add(data);
  return b.toBytes();
}
