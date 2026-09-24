// The booth on the real desktop engine, heard rather than believed.
//
// Two click tracks — 124 a minute clicking at 1 kHz, 127 clicking at 3 kHz, each over
// a quiet tone of its own — mixed one into the other by the automix, with every deck
// sent to a private null sink that tools/booth_probe.sh records. What comes out is
// then measured: where each 3 kHz click fell against the nearest 1 kHz one while both
// were playing, and whether either tone ever dropped out. Linux only, and only with
// the probe's --dart-define=PROBE_DIR=… set; otherwise it says so and does nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/worker/render_parts.dart';

const probeDir = String.fromEnvironment('PROBE_DIR');
const device = String.fromEnvironment('PROBE_DEVICE', defaultValue: 'pipewire/wetowl_probe');
const pitch = String.fromEnvironment('PROBE_PITCH', defaultValue: '1');

TrackTiming grid(Map<String, dynamic> g) => TrackTiming(
      durationMs: g['duration_ms'] as int,
      bpm: (g['bpm'] as num).toDouble(),
      beats: [for (final b in g['beats'] as List) b as int],
      downbeats: [for (final b in g['downbeats'] as List) b as int],
      camelot: '8A',
      cues: const MixCues(firstDownbeatMs: 0, mixInMs: 0, mixOutMs: 14000, soundEndMs: 69000),
    );

Track track(int id) => Track.fromJson({
      'id': id,
      'title': 'probe $id',
      'artists': ['probe'],
      'duration_ms': 70000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

Future<String> mpvSays(Deck d) async {
  final native = JustAudioMediaKit.instanceIfRegistered?.playerFor(d.player.platformId!)?.raw.platform;
  if (native is! NativePlayer) return '(no mpv)';
  final out = <String>[];
  for (final p in ['speed', 'audio-pitch-correction', 'af', 'time-pos', 'pause']) {
    out.add('$p=${await native.getProperty(p)}');
  }
  return out.join(' ');
}

Future<void> toProbe(Deck d) async {
  final id = d.player.platformId;
  final native = JustAudioMediaKit.instanceIfRegistered?.playerFor(id!)?.raw.platform;
  if (native is NativePlayer) await native.setProperty('audio-device', device);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.pitch = false;
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  testWidgets('two records mixed on the real engine stay on the beat', (tester) async {
    if (probeDir.isEmpty || !Platform.isLinux) {
      markTestSkipped('run through tools/booth_probe.sh');
      return;
    }
    final grids = jsonDecode(File('$probeDir/grids.json').readAsStringSync()) as Map;
    // A, B, and A again: two mixes, so the second shows what the first taught it.
    final a = track(990001), b = track(990002), again = track(990003);
    final files = {a.id: '$probeDir/a.wav', b.id: '$probeDir/b.wav', again.id: '$probeDir/a.wav'};
    partsDirForTesting = Directory.systemTemp.createTempSync('probe-parts').path;
    final booth = Booth(ApiClient(baseUrl: 'http://127.0.0.1:9'), offlinePath: (id) => files[id]);
    await tester.runAsync(() async {
      await booth.init();
      booth.timing.put(a.id, grid((grids['a'] as Map).cast()));
      booth.timing.put(b.id, grid((grids['b'] as Map).cast()));
      booth.timing.put(again.id, grid((grids['a'] as Map).cast()));
      // Both players made and pointed at the probe before a sound is made.
      await booth.load(booth.a, a);
      await booth.load(booth.b, b);
      await toProbe(booth.a);
      await toProbe(booth.b);
      // A master left at a pitch by an earlier mix, where the probe asks for one.
      await booth.a.setTempo(double.parse(pitch));
      final log = File('$probeDir/events.txt').openWrite();
      final t0 = DateTime.now();
      void note(String s) => log.writeln('${DateTime.now().difference(t0).inMilliseconds} $s');
      await booth.auto.start([a, b, again]);
      note('started; plan ${booth.auto.plan} goes at ${booth.auto.goesAt}; '
          'A on show ${booth.a.bpm?.toStringAsFixed(2)}, B ${booth.b.bpm?.toStringAsFixed(2)}');
      // Until the transition has run and B is the master on its own.
      final shown = <String>{};
      for (var i = 0; i < 1400 && !(booth.master.track?.id == again.id && !booth.busy); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (booth.inTransition) {
          shown.add('A ${booth.a.bpm?.toStringAsFixed(2)} · B ${booth.b.bpm?.toStringAsFixed(2)}');
        }
        if (i % 10 == 0) {
          note('A ${booth.a.position.inMilliseconds} @${booth.a.tempo.toStringAsFixed(4)} '
              'B ${booth.b.position.inMilliseconds} @${booth.b.tempo.toStringAsFixed(4)} '
              'x ${booth.crossfader.toStringAsFixed(2)}');
        }
        if (i % 50 == 0) {
          note('mpv A: ${await mpvSays(booth.a)}');
          note('mpv B: ${await mpvSays(booth.b)}');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      note('bpm on show during the transition: $shown');
      note('done; master ${booth.master.name}');
      await log.close();
      booth.auto.stop();
      await booth.a.pause();
      await booth.b.pause();
    });
    expect(booth.master.track?.id, 990003);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
