// The dancer: the shipped rig reads and poses into a body standing on the floor; a
// move loops without a jump; poses blend, and a step into a new move carries the old
// one's pose and motion out smoothly; duets come in couples; the choreography's
// arithmetic — tempo, tiers, the record's flavour, the pool, the troupe, couples,
// routines, formations, the camera and the stylised renderings — is the same for the
// same record and slot.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/show/show_dance.dart';
import 'package:muse/src/ui/show/show_dance_rig.dart';
import 'package:muse/src/state/show/show_state.dart' show ShowMacros;
import 'package:muse/src/ui/show/show_meme_bank.dart' show MemeMood;

DanceRig shipped([String model = 'chris']) {
  final j = jsonDecode(File('assets/show/dance/$model/dancer.json').readAsStringSync()) as Map<String, dynamic>;
  ByteData bytes(String f) => ByteData.sublistView(Uint8List.fromList(File('assets/show/dance/$model/$f').readAsBytesSync()));
  return DanceRig.parse(j, bytes('dancer.bin'), bytes('moves.bin'));
}

DanceMove move(String id, DanceTier tier, {double bpm = 120, DanceStyle style = DanceStyle.groove}) =>
    DanceMove(id: id, style: style, tier: tier, energy: 1, bpm: bpm);

void main() {
  final rig = shipped();

  test('the shipped rig: a skeleton, two meshes, moves of every tier', () {
    expect(rig.bones, greaterThan(15));
    expect(rig.meshes, hasLength(2));
    for (final m in rig.meshes) {
      expect(m.tris.reduce(math.max), lessThan(m.verts));
      expect(m.src.reduce(math.max), lessThan(m.positions));
    }
    for (final t in DanceTier.values) {
      expect(rig.moves.where((m) => m.tier == t), isNotEmpty, reason: 'no $t moves');
    }
    expect(rig.moves.map((m) => m.style).toSet().length, greaterThan(4));
  });

  test('every dancer: a bank of the same moves, a body that stands a person\'s height or so', () {
    for (final (id, _) in DanceModels.all) {
      expect(File('assets/show/dance/$id/skin.webp').existsSync(), isTrue, reason: id);
      final r = shipped(id);
      expect([for (final m in r.moves) m.id], [for (final m in rig.moves) m.id], reason: id);
      expect(r.height, inInclusiveRange(0.8, 2.6), reason: id);
      expect(r.bones, rig.bones, reason: id);
    }
  });

  test('techno: the grooves that pump on the beat lead, the party pieces hardly show', () {
    final fl = DanceClock.flavour(7, 128, MemeMood.vibe, techno: true);
    expect(fl[DanceStyle.groove]!, greaterThan(fl[DanceStyle.party]! * 50));
    expect(DanceClock.techno(128, 0.1), isTrue);
    expect(DanceClock.techno(95, 0.1), isFalse);
    final pumps = move('p', DanceTier.mid, bpm: 128)..pulse = 1;
    final sways = move('s', DanceTier.mid, bpm: 128)..pulse = 0;
    final pool = {for (final (m, w) in DanceClock.pool([pumps, sways], DanceTier.mid, fl, 128, techno: true)) m.id: w};
    expect(pool['p']!, greaterThan(pool['s']! * 3));
    // The shipped moves have a pulse worked out, and some pump.
    expect(rig.moves.where((m) => m.pulse > 0.3), isNotEmpty);
  });

  test('every move poses a body that stands on the floor, the hips at a hip\'s height', () {
    final pose = DancePose(rig.bones);
    final world = Float64List(rig.bones * 12), skin = Float64List(rig.bones * 12);
    final mesh = rig.meshes[1];
    final pos = Float32List(mesh.positions * 3), nrm = Float32List(mesh.positions * 3);
    for (final m in rig.moves) {
      for (final beat in [0.0, m.beats / 2 + 0.3]) {
        rig.sample(m, beat, pose);
        for (var b = 0; b < rig.bones; b++) {
          final q = pose.q;
          expect(q[b * 4] * q[b * 4] + q[b * 4 + 1] * q[b * 4 + 1] + q[b * 4 + 2] * q[b * 4 + 2] + q[b * 4 + 3] * q[b * 4 + 3], closeTo(1, 1e-6));
        }
        rig.solve(pose, world);
        rig.skinning(world, skin);
        DanceRig.deform(mesh, skin, pos, nrm);
        var lo = double.infinity, hi = -double.infinity;
        for (var v = 0; v < mesh.positions; v++) {
          lo = math.min(lo, pos[v * 3 + 2]);
          hi = math.max(hi, pos[v * 3 + 2]);
          expect(pos[v * 3].abs(), lessThan(3), reason: m.id);
        }
        expect(lo, closeTo(0, 0.35), reason: '${m.id} feet');
        expect(hi, inInclusiveRange(1.0, 2.3), reason: '${m.id} head');
      }
    }
  });

  test('a move loops without a jump', () {
    final a = DancePose(rig.bones), b = DancePose(rig.bones);
    for (final m in rig.moves) {
      rig.sample(m, m.beats - 0.001, a);
      rig.sample(m, 0, b);
      expect(DanceRig.poseDistance(rig.keyJoints(a), rig.keyJoints(b)), lessThan(0.03), reason: m.id);
    }
  });

  test('a blend half way is between the two, and whole at either end', () {
    final a = DancePose(rig.bones), b = DancePose(rig.bones), c = DancePose(rig.bones);
    rig.sample(rig.moves.first, 0, a);
    rig.sample(rig.moves.last, 1, b);
    c
      ..copyFrom(a)
      ..blendToward(b, 0.5);
    final ja = rig.keyJoints(a), jb = rig.keyJoints(b), jc = rig.keyJoints(c);
    final ab = DanceRig.poseDistance(ja, jb);
    expect(DanceRig.poseDistance(ja, jc), lessThan(ab));
    expect(DanceRig.poseDistance(jb, jc), lessThan(ab));
    c
      ..copyFrom(a)
      ..blendToward(b, 1);
    expect(DanceRig.poseDistance(jb, rig.keyJoints(c)), closeTo(0, 1e-9));
  });

  test('a step into a new move starts in the old pose, carries its motion, and ends in the new move', () {
    final from = DancePose(rig.bones), fromWas = DancePose(rig.bones), to = DancePose(rig.bones), toWas = DancePose(rig.bones);
    final a = rig.moves.first, b = rig.moves[rig.moves.length ~/ 2];
    rig.sample(a, 3, from);
    rig.sample(a, 3 - 1 / 16, fromWas);
    rig.sample(b, 0, to);
    rig.sample(b, -1 / 16, toWas);
    final carry = DanceCarry(rig.bones)..start(from, fromWas, to, toWas, 1 / 16, 1.5);
    final p = DancePose(rig.bones);
    DancePose at(double t) {
      rig.sample(b, t, p);
      carry.apply(p, t);
      return p;
    }

    final jFrom = rig.keyJoints(from);
    expect(DanceRig.poseDistance(rig.keyJoints(at(0)), jFrom), lessThan(1e-6));
    // Its first moment moves the way the old move was moving.
    final j1 = rig.keyJoints(at(0.02));
    rig.sample(a, 3.02, p);
    expect(DanceRig.poseDistance(j1, rig.keyJoints(p)), lessThan(0.02));
    // Whole at the end, and no jolt on the way.
    rig.sample(b, 1.5, p);
    final jEnd = rig.keyJoints(p);
    expect(DanceRig.poseDistance(rig.keyJoints(at(1.5)), jEnd), lessThan(1e-9));
    expect(DanceRig.poseDistance(rig.keyJoints(at(1.499)), jEnd), lessThan(0.01));
    var last = rig.keyJoints(at(0));
    for (var t = 0.05; t <= 1.5; t += 0.05) {
      final j = rig.keyJoints(at(t));
      expect(DanceRig.poseDistance(j, last), lessThan(0.12), reason: 'at $t');
      last = j;
    }
  });

  test('duets: two halves of one couple, standing apart, danced only as a couple', () {
    final duets = rig.moves.where((m) => m.duo != null).toList();
    expect(duets, isNotEmpty);
    expect(rig.hasDuets, isTrue);
    final a = DancePose(rig.bones), b = DancePose(rig.bones);
    for (final m in duets.where((m) => m.part == 0)) {
      final p = rig.partnerOf(m);
      expect(p.duo, m.duo);
      expect(p.part, 1);
      expect(rig.partnerOf(p), same(m));
      expect(p.beats, m.beats);
      var apart = 0.0;
      for (var t = 0.0; t < m.beats; t += 0.5) {
        rig.sample(m, t, a);
        rig.sample(p, t, b);
        apart = math.max(apart, math.sqrt(math.pow(a.hips[0] - b.hips[0], 2) + math.pow(a.hips[1] - b.hips[1], 2)));
      }
      expect(apart, inInclusiveRange(0.25, 2.2), reason: m.id);
    }
    final solo = rig.moves.firstWhere((m) => m.duo == null);
    expect(rig.partnerOf(solo), same(solo));
    final fl = DanceClock.flavour(3, 110, MemeMood.vibe);
    expect(DanceClock.pool(rig.moves, DanceTier.high, fl, 110).where((e) => e.$1.duo != null), isEmpty);
    final duo = DanceClock.pool(rig.moves, DanceTier.high, fl, 110, duo: true);
    expect(duo, isNotEmpty);
    expect(duo.every((e) => e.$1.duo != null && e.$1.part == 0), isTrue);
  });

  test('couples now and then, never asleep; routines and formations the same for the same slot', () {
    final latin = DanceClock.flavour(3, 100, MemeMood.vibe)..[DanceStyle.latin] = 6;
    final paired = [for (var n = 0; n < 200; n++) DanceClock.paired(DanceTroupe.duo, MemeMood.vibe, latin, 3, n)];
    expect(paired.where((t) => t == DanceTroupe.couple).length, greaterThan(60));
    expect({for (var n = 0; n < 50; n++) DanceClock.paired(DanceTroupe.duo, MemeMood.sleep, latin, 3, n)}, {DanceTroupe.duo});
    expect(DanceClock.paired(DanceTroupe.solo, MemeMood.rage, latin, 3, 1), DanceTroupe.solo);
    final routines = {for (var n = 0; n < 100; n++) DanceClock.routine(DanceTroupe.line, 3, n)};
    expect(routines, DanceRoutine.values.toSet());
    expect({for (var n = 0; n < 50; n++) DanceClock.routine(DanceTroupe.couple, 3, n)}, {DanceRoutine.unison});
    expect(DanceClock.routine(DanceTroupe.grid, 3, 7), DanceClock.routine(DanceTroupe.grid, 3, 7));
    final forms = [for (var n = 0; n < 100; n++) DanceClock.formation(DanceTroupe.line, 3, n)];
    expect(forms.toSet().length, greaterThan(2));
    // A formation holds for two slots at least.
    expect(DanceClock.formation(DanceTroupe.line, 3, 10), DanceClock.formation(DanceTroupe.line, 3, 11));
    expect(DanceClock.formation(DanceTroupe.grid, 3, 10), 0);
  });

  test('half time off a fast record, double off a slow one, half again asleep; the true tempo fits best', () {
    expect(DanceClock.rate(186, 93), 0.5);
    expect(DanceClock.rate(128, 93), 1);
    expect(DanceClock.rate(60, 129), 2);
    expect(DanceClock.rate(128, 129, sleep: true), 0.5);
    final m = move('a', DanceTier.mid, bpm: 124);
    expect(DanceClock.tempoFit(124, m), closeTo(1, 1e-9));
    expect(DanceClock.tempoFit(62, m), closeTo(1, 1e-9));
    expect(DanceClock.tempoFit(140, m), lessThan(DanceClock.tempoFit(128, m)));
  });

  test('the drop dances big, sleep calm, a build warms toward the drop', () {
    expect(DanceClock.tier(MemeMood.rage), DanceTier.high);
    expect(DanceClock.tier(MemeMood.sleep), DanceTier.low);
    expect(DanceClock.tier(MemeMood.wake, wakeK: 0.9), DanceTier.high);
    expect(DanceClock.tier(MemeMood.wake, wakeK: 0.4), DanceTier.mid);
  });

  test('the pool: the tier first, the last move out, the same pick for the same dice', () {
    final moves = [for (var i = 0; i < 4; i++) move('h$i', DanceTier.high), move('l0', DanceTier.low), move('m0', DanceTier.mid)];
    final fl = DanceClock.flavour(4242, 124, MemeMood.rage);
    final pool = DanceClock.pool(moves, DanceTier.high, fl, 124, recent: ['h1']);
    expect(pool.first.$1.tier, DanceTier.high);
    expect(pool.map((e) => e.$1.id), isNot(contains('h1')));
    expect(DanceClock.draw(pool, 0.37)?.id, DanceClock.draw(pool, 0.37)?.id);
    // A tier the bank lacks falls back to the others.
    expect(DanceClock.pool([moves[4]], DanceTier.high, fl, 124), isNotEmpty);
    // Asleep the calm ones lead; awake they hardly show.
    expect(DanceClock.flavour(1, 120, MemeMood.sleep)[DanceStyle.calm]!, greaterThan(DanceClock.flavour(1, 120, MemeMood.vibe)[DanceStyle.calm]! * 10));
  });

  test('troupe and camera: one for the mood, the same for the same record and slot', () {
    // Quiet: alone or with one; a drop's height: a line or a crowd as often as not.
    expect({for (var n = 0; n < 40; n++) DanceClock.troupe(MemeMood.sleep, 9, n)}, {DanceTroupe.solo, DanceTroupe.duo});
    final hot = [for (var n = 0; n < 200; n++) DanceClock.troupe(MemeMood.rage, 9, n)];
    expect(hot.where((t) => t != DanceTroupe.solo).length, greaterThan(160));
    expect(DanceClock.troupe(MemeMood.rage, 9, 3), DanceClock.troupe(MemeMood.rage, 9, 3));
    expect(DanceClock.shot(MemeMood.vibe, 9, 4, DanceTroupe.solo), DanceClock.shot(MemeMood.vibe, 9, 4, DanceTroupe.solo));
    // The camera stays in front: every framing's yaw within a third of a turn's tenth.
    for (final shot in DanceShot.values) {
      expect(DanceFrame.of(shot, DanceTroupe.solo).yaw.abs(), lessThan(0.35));
    }
    expect(DanceClock.hold(MemeMood.sleep), greaterThan(DanceClock.hold(MemeMood.rage)));
    // The stylised stage's extreme wide angles: often in a drop, never asleep, never
    // elsewhere; a lens far wider than the others, close in.
    const extremes = {DanceShot.extremeLow, DanceShot.extremeHigh, DanceShot.extremeFront, DanceShot.fisheye, DanceShot.fisheyeLow};
    final drop = [for (var n = 0; n < 200; n++) DanceClock.shot(MemeMood.rage, 9, n, DanceTroupe.solo, art: true)];
    expect(drop.where(extremes.contains).length, inInclusiveRange(50, 130));
    expect([for (var n = 0; n < 100; n++) DanceClock.shot(MemeMood.sleep, 9, n, DanceTroupe.solo, art: true)].where(extremes.contains), isEmpty);
    expect([for (var n = 0; n < 100; n++) DanceClock.shot(MemeMood.rage, 9, n, DanceTroupe.solo)].where(extremes.contains), isEmpty);
    for (final e in extremes) {
      final f = DanceFrame.of(e, DanceTroupe.grid);
      expect(f.fov, greaterThan(1.8));
      expect(f.dist, lessThan(1.0));
    }
    // The stylised stage: a rendering a section, never the same twice running.
    for (var n = 0; n < 30; n++) {
      final a = DanceClock.art(MemeMood.vibe, 5, n);
      expect(DanceClock.art(MemeMood.vibe, 5, n + 1, not: a), isNot(a));
    }
    expect([DanceArt.trails, DanceArt.chrono, DanceArt.mono, DanceArt.thermal, DanceArt.halftone, DanceArt.plain, DanceArt.disco], contains(DanceClock.art(MemeMood.rage, 5, 2)));
    // The disco is a style of the dancer, picked awake and in the heat.
    expect({for (var n = 0; n < 60; n++) DanceClock.art(MemeMood.rage, 5, n)}, contains(DanceArt.disco));
    expect(DanceClock.entries(move('x', DanceTier.mid)), [0, 2, 4, 6]);
  });

  test('dancers switched off: never in a mix, a chosen one still dances, all off is none off', () {
    const off = ['chris'];
    for (var salt = 0; salt < 400; salt++) {
      expect(DanceModels.lead(DanceModels.mix, salt, off), 'joe');
      for (var i = 0; i < 6; i++) {
        expect(DanceModels.member(DanceModels.mix, salt, i, off), 'joe');
      }
      // Both on: each record one of them leads, the other dances with it.
      final lead = DanceModels.lead(DanceModels.mix, salt);
      expect(DanceModels.member(DanceModels.mix, salt, 0), isNot(lead));
    }
    expect(DanceModels.lead('chris', 7, off), 'chris');
    final every = [for (final m in DanceModels.all) m.$1];
    expect(every, ['chris', 'joe']);
    expect(DanceModels.pool(every), every);
  });

  test('the switches travel to a stage in another window', () {
    const m = ShowMacros(dancer: 'mix', dancersOff: ['chris']);
    final back = ShowMacros.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
    expect(back.dancersOff, ['chris']);
    expect(ShowMacros.fromJson(const {}).dancersOff, isEmpty);
  });
}
