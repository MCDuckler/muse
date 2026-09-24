// SYNC pressed by hand, on the real desktop engine, with real records — heard.
//
// Each deck plays into a private null sink of its own; tool/booth_probe/manual.sh
// joins the two into one recording, deck A on the left and deck B on the right, so
// both are on one clock and where B's beats fall against A's can be measured from the
// sound itself. What happens: A plays; SYNC on B; B started by hand wherever it was
// parked; held for half a minute; then thrown out of step, and SYNC pressed again
// with both playing. Linux only, and only with PROBE_DIR set.
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

Track track(int id, int durationMs) => Track.fromJson({
      'id': id,
      'title': 'probe $id',
      'artists': ['probe'],
      'duration_ms': durationMs,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

Future<void> toSink(Deck d, String sink) async {
  final native = JustAudioMediaKit.instanceIfRegistered?.playerFor(d.player.platformId!)?.raw.platform;
  if (native is NativePlayer) await native.setProperty('audio-device', 'pipewire/$sink');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.pitch = false;
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  testWidgets('SYNC by hand keeps two real records on the beat', (tester) async {
    if (probeDir.isEmpty || !Platform.isLinux) {
      markTestSkipped('run through tool/booth_probe/manual.sh');
      return;
    }
    final spec = jsonDecode(File('$probeDir/manual.json').readAsStringSync()) as Map<String, dynamic>;
    final ta = TrackTiming.fromJson((spec['a']['analysis'] as Map).cast());
    final tb = TrackTiming.fromJson((spec['b']['analysis'] as Map).cast());
    final a = track(990101, ta.durationMs), b = track(990102, tb.durationMs);
    final files = {a.id: spec['a']['file'] as String, b.id: spec['b']['file'] as String};
    partsDirForTesting = Directory.systemTemp.createTempSync('probe-parts').path;
    final booth = Booth(ApiClient(baseUrl: 'http://127.0.0.1:9'), offlinePath: (id) => files[id]);
    final log = File('$probeDir/events.txt').openWrite();
    void note(String s) => log.writeln('${DateTime.now().microsecondsSinceEpoch / 1e6} $s');
    await tester.runAsync(() async {
      await booth.init();
      booth.timing.put(a.id, ta);
      booth.timing.put(b.id, tb);
      await booth.load(booth.a, a, at: Duration(milliseconds: spec['a_at'] as int));
      await booth.load(booth.b, b, at: Duration(milliseconds: spec['b_at'] as int));
      await toSink(booth.a, 'wetowl_probe_a');
      await toSink(booth.b, 'wetowl_probe_b');
      await booth.setCrossfader(0.5);
      note('A ${ta.gridBpm?.toStringAsFixed(2)} steady=${ta.steady != null}; B ${tb.gridBpm?.toStringAsFixed(2)} steady=${tb.steady != null}');
      // What the engine reports in the first moments, against the wall clock: the
      // start is where a clock can be wrong.
      final reports = booth.a.player.positionStream.listen((p) => note('A reports ${p.inMilliseconds} (clock ${booth.a.position.inMilliseconds})'));
      note('A play asked');
      await booth.play(booth.a);
      note('A playing');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await reports.cancel();
      if (spec['level_check'] == true) {
        // A alone, the crossfader all its way, then in the middle: what the middle
        // costs a deck, as heard.
        await booth.setCrossfader(0);
        note('level: crossfader at A');
        await Future<void>.delayed(const Duration(seconds: 3));
        await booth.setCrossfader(0.5);
        note('level: crossfader in the middle');
        await Future<void>.delayed(const Duration(seconds: 3));
        note('level: done');
      }
      await Future<void>.delayed(const Duration(seconds: 4));
      final ok = await booth.setSync(booth.b, true);
      note('SYNC on B: $ok; B pitch ${booth.b.pitch.toStringAsFixed(4)}; shown A ${booth.a.bpm?.toStringAsFixed(2)} B ${booth.b.bpm?.toStringAsFixed(2)}');
      await Future<void>.delayed(const Duration(seconds: 1));
      // The same record on both, parked where A is about to be: then B, started on the
      // beat, plays exactly what A plays, and the two recordings can only line up one way.
      if (spec['b_follow'] == true) {
        await booth.b.seek(booth.a.position + const Duration(milliseconds: 400));
      }
      await booth.play(booth.b);
      note('B started by hand');
      await Future<void>.delayed(Duration(seconds: (spec['hold_s'] as int?) ?? 30));
      if (spec['loop_check'] == true) {
        booth.b.loop(4);
        note('B loop asked ${booth.b.loopStart?.inMicroseconds} to ${booth.b.loopEnd?.inMicroseconds}');
        await Future<void>.delayed(const Duration(seconds: 2));
        note('B loop tuned ${booth.b.loopStart?.inMicroseconds} to ${booth.b.loopEnd?.inMicroseconds}');
        await Future<void>.delayed(const Duration(seconds: 8));
        booth.b.unloop();
        note('B loop off');
      }
      if (spec['only_hold'] == true) {
        note('done');
        await booth.a.pause();
        await booth.b.pause();
        await log.close();
        return;
      }
      await booth.setSync(booth.b, false);
      await booth.b.nudge(const Duration(milliseconds: 150));
      note('B thrown 150 ms out, SYNC off');
      await Future<void>.delayed(const Duration(seconds: 4));
      await booth.setSync(booth.b, true);
      note('SYNC on B again, both playing');
      await Future<void>.delayed(const Duration(seconds: 20));
      note('done');
      await booth.a.pause();
      await booth.b.pause();
      await log.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
