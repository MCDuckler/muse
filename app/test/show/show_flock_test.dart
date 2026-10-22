// The murmuration's arithmetic: the flights, looks and cameras are the same for the
// same record and slot and fit their moods; the flock itself stays in the room, at
// its speed, never a number that is not a number; the kick pulls it in, a drop
// bursts it, the formations form.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_tune.dart' show treatmentFxMode;
import 'package:muse/src/ui/show/show_flock.dart';
import 'package:muse/src/ui/show/show_meme_bank.dart' show MemeMood;

FlockSteer steer({
  required double beats,
  Flight flight = Flight.murmur,
  Flight? flightWas,
  double flightK = 1,
  double speed = 2.2,
  int want = 700,
  double kick = 0,
  double snare = 0,
  double burst = 0,
  double beatDecay = 0,
}) =>
    FlockSteer(
      dt: 1 / 60,
      beats: beats,
      beatsPerSecond: 2,
      speed: speed,
      want: want,
      flight: flight,
      flightWas: flightWas,
      flightK: flightK,
      kick: kick,
      snare: snare,
      burst: burst,
      beatDecay: beatDecay,
      barSaw: (beats / 4) % 1,
      phraseSaw: (beats / 16) % 1,
      waySalt: 42,
    );

/// [n] frames of [flight] at 60 a second from [from] beats on, at two beats a second.
double run(FlockModel m, int n, {required double from, Flight flight = Flight.murmur, double speed = 2.2, int want = 700}) {
  var beats = from;
  for (var i = 0; i < n; i++) {
    m.step(steer(beats: beats, flight: flight, speed: speed, want: want));
    beats += 2 / 60;
  }
  return beats;
}

/// The mean distance of the flying birds from the flock's middle.
double spread(FlockModel m) {
  var s = 0.0, n = 0;
  for (var i = 0; i < FlockModel.most; i++) {
    if (m.alpha[i] <= 0) continue;
    final dx = m.px[i] - m.cx, dy = m.py[i] - m.cy, dz = m.pz[i] - m.cz;
    s += math.sqrt(dx * dx + dy * dy + dz * dz);
    n++;
  }
  return n == 0 ? 0 : s / n;
}

void main() {
  test('the choices are the record\'s own, and never the same twice in a row', () {
    for (final mood in MemeMood.values) {
      for (var n = 0; n < 12; n++) {
        expect(FlockClock.flight(mood, 7, n), FlockClock.flight(mood, 7, n));
        expect(FlockClock.look(mood, 7, n), FlockClock.look(mood, 7, n));
        final f = FlockClock.flight(mood, 7, n);
        expect(FlockClock.flight(mood, 7, n + 1, not: f), isNot(f));
        final l = FlockClock.look(mood, 7, n);
        expect(FlockClock.look(mood, 7, n + 1, not: l), isNot(l));
      }
    }
    // Another record chooses otherwise, somewhere in a dozen slots.
    expect([for (var n = 0; n < 12; n++) FlockClock.look(MemeMood.vibe, 7, n)], isNot([for (var n = 0; n < 12; n++) FlockClock.look(MemeMood.vibe, 8, n)]));
  });

  test('the moods pick what suits them: skeins asleep, no skeins in a drop; the sky never in a drop', () {
    final asleep = {for (var n = 0; n < 60; n++) FlockClock.flight(MemeMood.sleep, 3, n)};
    expect(asleep, contains(Flight.vee));
    expect(asleep, isNot(contains(Flight.sphere)));
    final raging = {for (var n = 0; n < 60; n++) FlockClock.flight(MemeMood.rage, 3, n)};
    expect(raging, isNot(contains(Flight.vee)));
    expect(raging, containsAll([Flight.vortex, Flight.sphere, Flight.twin]));
    final rageLooks = {for (var n = 0; n < 60; n++) FlockClock.look(MemeMood.rage, 3, n)};
    expect(rageLooks, isNot(contains(FlockLook.sky)));
    expect(rageLooks, containsAll([FlockLook.embers, FlockLook.neon, FlockLook.chrono]));
    final sleepLooks = {for (var n = 0; n < 60; n++) FlockClock.look(MemeMood.sleep, 3, n)};
    expect(sleepLooks, isNot(contains(FlockLook.chrono)));
    expect(sleepLooks, contains(FlockLook.sky));
    // Every look is reachable somewhere.
    // Every look of the flock's own; the image treatments are the conductor's.
    expect({for (var n = 0; n < 200; n++) FlockClock.look(MemeMood.vibe, 3, n)}, {for (final l in FlockLook.values) if (!treatmentFxMode.containsKey(l.name)) l});
  });

  test('the camera: the sky from below or wide, the radar from above, the rest in front; held long', () {
    for (var c = 0; c < 20; c++) {
      expect(FlockClock.shot(MemeMood.vibe, 5, c, FlockLook.sky), isIn([FlockShot.low, FlockShot.wide, FlockShot.front]));
      expect(FlockClock.shot(MemeMood.vibe, 5, c, FlockLook.radar), isIn([FlockShot.high, FlockShot.wide]));
    }
    expect({for (var c = 0; c < 60; c++) FlockClock.shot(MemeMood.rage, 5, c, FlockLook.embers)}, contains(FlockShot.fish));
    expect({for (var c = 0; c < 60; c++) FlockClock.shot(MemeMood.sleep, 5, c, FlockLook.embers)}, isNot(contains(FlockShot.fish)));
    // Weighed by the camera's rules: the fisheyes off, never one; every one the look
    // allows off, another; all off, wide.
    final fishOff = {for (var c = 0; c < 60; c++) FlockClock.shot(MemeMood.rage, 5, c, FlockLook.embers, weight: (s) => s == FlockShot.fish || s == FlockShot.fishLow ? 0 : 1)};
    expect(fishOff.intersection({FlockShot.fish, FlockShot.fishLow}), isEmpty);
    expect(FlockClock.shot(MemeMood.vibe, 5, 3, FlockLook.radar, weight: (s) => s == FlockShot.low ? 1 : 0), FlockShot.low);
    expect(FlockClock.shot(MemeMood.vibe, 5, 3, FlockLook.embers, weight: (_) => 0), FlockShot.wide);
    expect(FlockClock.hold(MemeMood.rage), lessThan(FlockClock.hold(MemeMood.sleep)));
    expect(FlockClock.speed(MemeMood.sleep), lessThan(FlockClock.speed(MemeMood.rage)));
    expect(FlockClock.speed(MemeMood.wake, wakeK: 1), greaterThan(FlockClock.speed(MemeMood.wake, wakeK: 0)));
    expect(FlockClock.count(Flight.vee, MemeMood.sleep, 0.5), lessThan(FlockClock.count(Flight.murmur, MemeMood.rage, 1)));
    expect(FlockClock.kickPull(MemeMood.sleep), 0);
  });

  test('a murmuration stays in the room at its speed, every number a number', () {
    final m = FlockModel(seed: 1);
    run(m, 600, from: 0, speed: 2.2, want: 700);
    expect(m.flying, 700);
    for (var i = 0; i < 700; i++) {
      expect(m.px[i].isFinite && m.py[i].isFinite && m.pz[i].isFinite, isTrue, reason: 'bird $i');
      expect(m.px[i], inInclusiveRange(-6.7, 6.7), reason: 'bird $i x');
      expect(m.py[i], inInclusiveRange(-3.2, 5), reason: 'bird $i y');
      expect(m.pz[i], inInclusiveRange(0.5, 7.5), reason: 'bird $i z');
      final sp = math.sqrt(m.vx[i] * m.vx[i] + m.vy[i] * m.vy[i] + m.vz[i] * m.vz[i]);
      expect(sp, inInclusiveRange(0.3, 3.9), reason: 'bird $i speed $sp');
    }
    // One flock, more or less: its middle in the room, its spread a few metres.
    expect(m.cx, inInclusiveRange(-4, 4));
    expect(m.cz, inInclusiveRange(2, 4.6), reason: 'not against the ceiling or the floor');
    expect(spread(m), lessThan(4.5));
  });

  test('the birds come and go as the flight wants: skeins are a few hundred', () {
    final m = FlockModel(seed: 2);
    run(m, 120, from: 0, flight: Flight.vee, want: 270);
    expect(m.flying, 270);
    for (var i = 270; i < FlockModel.most; i++) {
      expect(m.alpha[i], 0);
    }
    run(m, 120, from: 4, flight: Flight.murmur, want: 900);
    expect(m.flying, 900);
    expect(m.alpha[899], 1);
  });

  test('the kick pulls the flock in; a drop bursts it', () {
    final m = FlockModel(seed: 3);
    var beats = run(m, 300, from: 0, speed: 3.0, want: 800);
    final before = spread(m);
    m.step(steer(beats: beats, speed: 3.0, want: 800, kick: 0.6));
    var pulled = before;
    for (var i = 0; i < 24; i++) {
      beats += 2 / 60;
      m.step(steer(beats: beats, speed: 3.0, want: 800));
      pulled = math.min(pulled, spread(m));
    }
    expect(pulled, lessThan(before * 0.9), reason: 'before $before, after the kick $pulled');
    m.step(steer(beats: beats, speed: 3.0, want: 800, burst: 1));
    for (var i = 0; i < 20; i++) {
      beats += 2 / 60;
      m.step(steer(beats: beats, speed: 3.0, want: 800));
    }
    final burst = spread(m);
    expect(burst, greaterThan(pulled * 1.25), reason: 'pulled $pulled, after the burst $burst');
    // and everyone is still a number, in the room
    for (var i = 0; i < 800; i++) {
      expect(m.px[i].isFinite && m.pz[i].isFinite, isTrue);
      expect(m.pz[i], greaterThanOrEqualTo(-0.3));
    }
  });

  test('a sphere forms: the birds settle a radius from its middle; a sheet spreads wide', () {
    final m = FlockModel(seed: 4);
    run(m, 100, from: 0, speed: 2.5, want: 900);
    run(m, 900, from: 4, flight: Flight.sphere, speed: 3.6, want: 900);
    var near = 0;
    for (var i = 0; i < 900; i++) {
      final dx = m.px[i] - FlockModel.centre.x, dy = (m.py[i] - FlockModel.centre.y) / 0.7, dz = m.pz[i] - FlockModel.centre.z - 0.2;
      final r = math.sqrt(dx * dx + dy * dy + dz * dz);
      if ((r - 2.5).abs() < 0.9) near++;
    }
    expect(near, greaterThan(540), reason: '$near of 900 on the globe');
    run(m, 900, from: 40, flight: Flight.sheet, speed: 3.0, want: 800);
    var xs = 0.0, xs2 = 0.0;
    for (var i = 0; i < 800; i++) {
      xs += m.px[i];
      xs2 += m.px[i] * m.px[i];
    }
    final sd = math.sqrt(xs2 / 800 - (xs / 800) * (xs / 800));
    expect(sd, greaterThan(2.4), reason: 'a sheet is wide: sd $sd');
  });

  test('the cost: a frame of the whole flock', () {
    final m = FlockModel(seed: 9);
    run(m, 120, from: 0, want: FlockModel.most);
    final sw = Stopwatch()..start();
    run(m, 300, from: 4, want: FlockModel.most);
    sw.stop();
    // ignore: avoid_print
    print('FLOCK step ${(sw.elapsedMicroseconds / 300 / 1000).toStringAsFixed(2)} ms for ${m.flying} birds (JIT)');
    expect(sw.elapsedMilliseconds / 300, lessThan(12));
  });

  test('seeded along a dancer\'s bones, the birds are her shape, then let go they spread', () {
    final m = FlockModel(seed: 8);
    // a stick figure: five segments up a line at x 0.5, y 0, from the floor to 1.8
    final seg = Float32List.fromList([
      for (var k = 0; k < 5; k++) ...[0.5, 0.0, k * 0.36, 0.5, 0.0, (k + 1) * 0.36],
    ]);
    m.seedAlong(seg, 5, 600);
    for (var i = 0; i < 600; i++) {
      expect(m.px[i], inInclusiveRange(0.3, 0.7), reason: 'bird $i x');
      expect(m.pz[i], inInclusiveRange(-0.1, 1.9), reason: 'bird $i z');
    }
    // frozen: a step of no time moves nothing
    m.step(FlockSteer(dt: 0, beats: 0, beatsPerSecond: 2, speed: 2.0, want: 600, flight: Flight.murmur, roomK: 0));
    expect(m.px[3], inInclusiveRange(0.3, 0.7));
    // let go, the room not yet pulling: they spread from the line but stay low
    var beats = 1.0;
    for (var i = 0; i < 90; i++) {
      m.step(FlockSteer(dt: 1 / 60, beats: beats, beatsPerSecond: 2, speed: 2.0, want: 600, flight: Flight.murmur, waySalt: 42, roomK: 0, burst: i == 0 ? 0.45 : 0));
      beats += 2 / 60;
    }
    expect(spread(m), greaterThan(0.6));
    expect(m.cz, lessThan(3.0), reason: 'no room pull yet: still near the dancer');
    // and with the room's pull they rise to it
    for (var i = 0; i < 400; i++) {
      m.step(FlockSteer(dt: 1 / 60, beats: beats, beatsPerSecond: 2, speed: 2.5, want: 600, flight: Flight.murmur, waySalt: 42, roomK: 1));
      beats += 2 / 60;
    }
    expect(m.cz, greaterThan(1.8));
  });

  test('a blend between flights is a number too', () {
    final m = FlockModel(seed: 6);
    var beats = run(m, 60, from: 0, flight: Flight.vortex);
    for (var i = 0; i < 120; i++) {
      m.step(steer(beats: beats, flight: Flight.ribbon, flightWas: Flight.vortex, flightK: i / 120));
      beats += 2 / 60;
    }
    for (var i = 0; i < 700; i++) {
      expect(m.px[i].isFinite && m.py[i].isFinite && m.pz[i].isFinite, isTrue);
    }
    final w = m.wing(0, 1.25, 1, 0.75, false);
    expect(w, inInclusiveRange(-1.1, 0.5));
  });
  test('the beat pushes the flock along its way and it drifts before the next, as far in all', () {
    for (final mood in MemeMood.values) {
      var sum = 0.0;
      const n = 1000;
      for (var i = 0; i < n; i++) {
        sum += FlockClock.surge(mood, (i + 0.5) / n);
      }
      expect(sum / n, closeTo(1, 0.01), reason: '$mood: no further than without it');
      expect(FlockClock.surge(mood, 0), greaterThan(1.3));
      expect(FlockClock.surge(mood, 0.9), lessThan(1));
      expect(FlockClock.surge(mood, 0.9), greaterThan(0.4));
    }
  });
}
