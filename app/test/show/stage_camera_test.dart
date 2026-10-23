import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/show/stage_camera.dart';

void main() {
  // A shot played through at 60 frames a second, 128 beats a minute.
  List<SweepMove> run(CameraSweep s, double drive, {int beats = 8}) {
    const dt = 1 / 60, perFrame = 128 / 60 * dt;
    return [for (var b = 0.0; b < beats; b += perFrame) s.at(b, drive, dt)];
  }

  test('a quiet part holds the camera still', () {
    final s = CameraSweep()..cut(0, 16, 0.05, 0.4);
    expect(s.kind, isNull);
    expect(run(s, 0.05).every((x) => x == CameraSweep.none), isTrue);
    expect(s.moving, isFalse);
  });

  test('a loud part travels through the shot, smoothly and within bounds', () {
    for (var i = 0; i < 40; i++) {
      final s = CameraSweep()..cut(0, 8, 1, i / 40, over: true);
      expect(s.kind, isNotNull);
      final moves = run(s, 1);
      expect(s.moving, isTrue);
      var travelled = 0.0;
      for (var j = 1; j < moves.length; j++) {
        final a = moves[j - 1], b = moves[j];
        // No jumps from frame to frame: a camera moving, not cutting.
        expect((b.yaw - a.yaw).abs(), lessThan(0.05), reason: '${s.kind}');
        expect((b.dist - a.dist).abs(), lessThan(0.03), reason: '${s.kind}');
        travelled += (b.yaw - a.yaw).abs() + (b.dist - a.dist).abs() + (b.rise - a.rise).abs();
      }
      expect(travelled, greaterThan(0.05), reason: '${s.kind}');
      for (final m in moves) {
        expect(m.yaw.abs(), lessThan(1.1));
        expect(m.dist, inInclusiveRange(0.4, 1.4));
        expect(m.rise.abs(), lessThan(0.35));
      }
    }
  });

  test('a close shot never pushes in past the figure', () {
    for (var i = 0; i < 40; i++) {
      final s = CameraSweep()..cut(0, 8, 1, i / 40, close: true, over: true);
      expect(s.kind, isNot(SweepKind.fly));
      expect(run(s, 1).every((m) => m.dist >= 1), isTrue);
    }
  });

  test('the drop cut swings in from the side and settles', () {
    final s = CameraSweep()..cut(0, 8, 1, 0.1, drop: true);
    final moves = run(s, 1);
    final plain = CameraSweep()..cut(0, 8, 1, 0.1);
    final calm = run(plain, 1);
    // A third of a beat in the whip is still on; by the end it has settled into the travel.
    expect((moves[10].yaw - calm[10].yaw).abs(), greaterThan(0.3));
    expect((moves.last.yaw - calm.last.yaw).abs(), lessThan(0.01));
  });

  test('loud cuts hold shorter, quiet ones as they were', () {
    expect(cutHold(16, 0.1), 16);
    expect(cutHold(16, 0.5), 8);
    expect(cutHold(16, 0.9), 4);
  });
}
