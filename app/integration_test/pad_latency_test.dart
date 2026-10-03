// How long a board pad takes to go from the press to mpv's clock moving, on the
// real engine (libmpv, its output set to null so nothing is heard) — the number the
// Engine check shows, measured where it can be read back.
//
//   WETOWL_NON_UNIQUE=1 flutter drive -d linux --driver=test_driver/integration_test.dart \
//     --target=integration_test/pad_latency_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/sampler.dart';
import 'package:muse/src/state/booth/board/samples.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: true);

  testWidgets('a pad press reaches mpv within a few tens of milliseconds', (tester) async {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('pad latency')))));
    final sampler = Sampler(library: SampleLibrary(), playerVolume: (x) => x);
    final times = <double>[];
    String buffer = '?';
    try {
      final v = await sampler.warm(
        'check',
        SampleKit.byId(SampleKit.impact)!,
        const PadSpec(sampleId: SampleKit.impact, name: 'CHECK'),
        level: 0.3,
      );
      expect(v, isNotNull);
      final native = JustAudioMediaKit.instanceIfRegistered?.playerFor(v!.player.platformId!)?.raw.platform;
      expect(native, isA<NativePlayer>());
      final mpv = native as NativePlayer;
      await mpv.setProperty('ao', 'null');
      buffer = await mpv.getProperty('audio-buffer');
      await sampler.fire('check');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      for (var i = 0; i < 10; i++) {
        await sampler.stop(key: 'check');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final sw = Stopwatch()..start();
        unawaited(sampler.fire('check'));
        while (sw.elapsedMilliseconds < 500) {
          final pos = double.tryParse(await mpv.getProperty('time-pos')) ?? 0;
          if (pos > 0.001) break;
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        times.add(sw.elapsedMicroseconds / 1000);
      }
      await sampler.stop(key: 'check');
    } finally {
      await sampler.dispose();
    }
    times.sort();
    final median = times[times.length ~/ 2];
    debugPrint('[pad] press→mpv moving: median ${median.toStringAsFixed(1)} ms, '
        'best ${times.first.toStringAsFixed(1)}, worst ${times.last.toStringAsFixed(1)} · audio-buffer=$buffer');
    binding.reportData = {'median_ms': median, 'times': times, 'audio_buffer': buffer};
    expect(median, lessThan(100), reason: 'a pad that lands later than this is not a pad');
  });
}
