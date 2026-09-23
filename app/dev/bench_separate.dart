// How long a record takes to take apart, in a build like the one that ships.
//   dart compile exe dev/bench_separate.dart -o /tmp/bench && /tmp/bench
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:muse/src/worker/separate.dart';

void main() {
  const seconds = 240;
  final n = rate * seconds;
  final stereo = Float32List(n * 2);
  final r = math.Random(1);
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    final v = 0.3 * math.sin(2 * math.pi * 440 * t) +
        0.2 * math.sin(2 * math.pi * 90 * t) +
        0.05 * (r.nextDouble() * 2 - 1);
    stereo[i * 2] = v;
    stereo[i * 2 + 1] = v * 0.8;
  }
  for (final name in ['instrumental', 'drums']) {
    final began = DateTime.now();
    separate(stereo, name);
    final took = DateTime.now().difference(began).inMilliseconds;
    print('  $name: $took ms for a $seconds s record');
  }
}
