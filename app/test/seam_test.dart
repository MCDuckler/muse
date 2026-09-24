// A loop's seam spliced where the two sides agree.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/render_parts.dart';
import 'package:muse/src/worker/tools.dart';

void main() {
  test('the ends of a loop move together to where the waveform agrees', () async {
    final ffmpeg = (await Tools.find()).ffmpeg;
    if (ffmpeg == null) {
      markTestSkipped('needs ffmpeg');
      return;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Something like music: noise, smoothed, a different sound at each end of the loop.
    final dir = Directory.systemTemp.createTempSync('seam');
    addTearDown(() => dir.deleteSync(recursive: true));
    const rate = 44100;
    const n = rate * 4;
    final r = math.Random(4);
    final pcm = Float32List(n * 2);
    var l = 0.0, rr = 0.0;
    for (var i = 0; i < n; i++) {
      l = 0.9 * l + 0.1 * (r.nextDouble() * 2 - 1);
      rr = 0.9 * rr + 0.1 * (r.nextDouble() * 2 - 1);
      pcm[2 * i] = l * 3;
      pcm[2 * i + 1] = rr * 3;
    }
    final raw = File('${dir.path}/noise.f32')..writeAsBytesSync(pcm.buffer.asUint8List());
    final wav = '${dir.path}/noise.wav';
    final made = await Process.run(ffmpeg,
        ['-v', 'error', '-y', '-f', 'f32le', '-ar', '$rate', '-ac', '2', '-i', raw.path, '-c:a', 'pcm_f32le', wav]);
    expect(made.exitCode, 0);
    const a = Duration(milliseconds: 1000), b = Duration(microseconds: 2653100);
    final quiet = await quietSeam(wav, a, b);
    expect(quiet, isNotNull);
    // The engine carries on from the first sample at or after the start, having played
    // up to the one before the end: so [sb] is the sample that would have come next.
    final sa = (quiet!.$1.inMicroseconds * rate / 1e6).ceil();
    final sb = (quiet.$2.inMicroseconds * rate / 1e6).floor();
    expect(((sa - rate) / rate * 1e6).abs(), lessThanOrEqualTo(1600), reason: 'moved at most 1.5 ms');
    final asked = ((b.inMicroseconds - a.inMicroseconds) * rate / 1e6).round();
    expect((sb - sa - asked).abs(), lessThanOrEqualTo(1), reason: 'as long as it was, to a sample');
    // The jump the splice makes: the sample the loop goes back to, against the one that
    // would have come next — both channels, and the sample before each.
    double jump(int ia, int ib) =>
        (pcm[2 * ib] - pcm[2 * ia]).abs() + (pcm[2 * ib + 1] - pcm[2 * ia + 1]).abs() +
        (pcm[2 * ib - 2] - pcm[2 * ia - 2]).abs() + (pcm[2 * ib - 1] - pcm[2 * ia - 1]).abs();
    final plainA = (a.inMicroseconds * rate / 1e6).round(), plainB = (b.inMicroseconds * rate / 1e6).round();
    // Noise is a harder case than a record — nothing in it repeats — and still the jump
    // at least halves; on real records it fell five-fold.
    expect(jump(sa, sb), lessThan(jump(plainA, plainB) / 2),
        reason: '${jump(sa, sb)} against ${jump(plainA, plainB)}');
  });
}
