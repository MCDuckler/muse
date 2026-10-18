// The dancer's body for a live render: the scan as a skinned mesh, its skeleton, and
// every move as poses sampled on the beat (tools/show-dance/dance_export3d.py).
//
// Coordinates are the capture's: metres, z up, the dancer facing -y on average. A
// pose is a rotation per bone — the hips' in the world, every other bone's against
// its parent — and where the hips are. Poses blend bone by bone, so one move turns
// into the next as a body would, not as two pictures dissolving.
//
// Nothing here draws; show_dance_draw.dart does. This file is plain arithmetic, so
// it is tested without a canvas.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum DanceTier { low, mid, high }

/// What kind of dancing a move is, from its capture.
enum DanceStyle { groove, party, toon, swing, latin, folk, calm }

class DanceMove {
  DanceMove({
    required this.id,
    required this.style,
    required this.tier,
    required this.energy,
    required this.bpm,
    this.beats = 8,
    this.handsUp = 0,
    this.offset = 0,
    this.duo,
    this.part = 0,
  });
  final String id;
  final DanceStyle style;
  final DanceTier tier;

  /// How much the body moves (the capture's joint speed), and the capture's tempo.
  final double energy, bpm;

  /// Capture beats in the loop: 8, or 4 for a short one (danced twice a slot).
  final int beats;
  final double handsUp;

  /// Where its samples start in moves.bin.
  final int offset;

  /// A duet's: the couple it is half of (two people captured dancing together), and
  /// which half — 0 the lead, 1 the partner. Both halves stand where they stood in
  /// the capture, round the couple's middle; neither is danced alone.
  final String? duo;
  final int part;

  /// How much it pumps on the beat, 0..1: the hips' rise and fall once a beat,
  /// against all their rising and falling (DanceRig works it out on loading).
  double pulse = 0;

  factory DanceMove.fromJson(Map<String, dynamic> j) => DanceMove(
        id: '${j['id']}',
        style: DanceStyle.values.asNameMap()['${j['style']}'] ?? DanceStyle.groove,
        tier: DanceTier.values.byName('${j['tier']}'),
        energy: (j['energy'] as num).toDouble(),
        bpm: (j['bpm'] as num).toDouble(),
        beats: (j['beats'] as num?)?.toInt() ?? 8,
        handsUp: (j['handsUp'] as num?)?.toDouble() ?? 0,
        offset: (j['offset'] as num?)?.toInt() ?? 0,
        duo: j['duo'] as String?,
        part: (j['part'] as num?)?.toInt() ?? 0,
      );
}

/// A body's pose: per bone a quaternion (w, x, y, z), and the hips' place.
class DancePose {
  DancePose(int bones) : q = Float64List(bones * 4), hips = Float64List(3);
  final Float64List q, hips;
  int get bones => q.length ~/ 4;

  void copyFrom(DancePose o) {
    q.setAll(0, o.q);
    hips.setAll(0, o.hips);
  }

  /// This pose eased toward [o] by [w], bone by bone (normalised lerp, the short way).
  void blendToward(DancePose o, double w) {
    if (w <= 0) return;
    if (w >= 1) return copyFrom(o);
    for (var b = 0; b < q.length; b += 4) {
      final dot = q[b] * o.q[b] + q[b + 1] * o.q[b + 1] + q[b + 2] * o.q[b + 2] + q[b + 3] * o.q[b + 3];
      final s = dot < 0 ? -1.0 : 1.0;
      var n = 0.0;
      for (var k = 0; k < 4; k++) {
        q[b + k] = q[b + k] * (1 - w) + o.q[b + k] * s * w;
        n += q[b + k] * q[b + k];
      }
      n = 1 / math.sqrt(n);
      for (var k = 0; k < 4; k++) {
        q[b + k] *= n;
      }
    }
    for (var k = 0; k < 3; k++) {
      hips[k] = hips[k] * (1 - w) + o.hips[k] * w;
    }
  }
}

/// A mesh of the scan. Skinned per position — where it is and its normal in the rest
/// pose, four bones and weights — and drawn per corner: a position split where the
/// skin's islands meet, each corner with its skin coordinate (0..1) and the position
/// it is ([src]). Triangles count corners; [trisAt] the same by position.
class DanceMesh {
  DanceMesh({required this.pos, required this.nrm, required this.bone, required this.weight, required this.uv, required this.src, required this.tris})
      : trisAt = Uint16List.fromList([for (final i in tris) src[i]]);
  final Float32List pos, nrm, uv;
  final Uint8List bone, weight;
  final Uint16List src, tris, trisAt;

  /// Positions (skinned) and corners (drawn).
  int get positions => pos.length ~/ 3;
  int get verts => uv.length ~/ 2;
  int get triangles => tris.length ~/ 3;
}

/// The skeleton, the meshes and the moves, read once.
class DanceRig {
  DanceRig({required this.names, required this.parent, required this.rest, required this.meshes, required this.moves, required ByteData samples, this.fpb = 8})
      : _samples = samples {
    final n = names.length;
    _inv = Float64List(n * 12);
    _rel = Float64List(n * 12);
    for (var i = 0; i < n; i++) {
      _invert(rest, i * 12, _inv, i * 12);
    }
    for (var i = 0; i < n; i++) {
      final p = parent[i];
      if (p < 0) {
        _identity(_rel, i * 12);
      } else {
        _mul(_inv, p * 12, rest, i * 12, _rel, i * 12);
      }
    }
    _hipsIx = names.indexOf('Hips');
    _byId = {for (final m in moves) m.id: m};
    for (final m in moves) {
      if (m.duo != null) (_duos[m.duo!] ??= [m, m])[m.part.clamp(0, 1)] = m;
    }
    for (final m in moves) {
      m.pulse = _pulse(m);
    }
    for (final m in meshes) {
      _smooth(m);
      for (var v = 0; v < m.positions; v++) {
        if (m.pos[v * 3 + 2] > height) height = m.pos[v * 3 + 2];
      }
    }
  }

  late final Map<String, DanceMove> _byId;

  double _pulse(DanceMove m) {
    final n = m.beats * fpb;
    final z = Float64List(n);
    var mean = 0.0;
    for (var j = 0; j < n; j++) {
      z[j] = _samples.getInt16(m.offset + j * _stride + bones * 8 + 4, Endian.little) / 1000.0;
      mean += z[j] / n;
    }
    var re = 0.0, im = 0.0, varz = 0.0;
    for (var j = 0; j < n; j++) {
      final d = z[j] - mean, a = 2 * math.pi * j / fpb;
      re += d * math.cos(a);
      im += d * math.sin(a);
      varz += d * d / n;
    }
    final amp = 2 / n * math.sqrt(re * re + im * im);
    final share = amp / (math.sqrt(2 * varz) + 0.004);
    return (share * (amp / 0.025).clamp(0.0, 1.0)).clamp(0.0, 1.0);
  }

  /// This rig's own [id] move (every model dances the same table).
  DanceMove? move(String id) => _byId[id];

  final _duos = <String, List<DanceMove>>{};

  /// The other half of [m]'s duet (itself when it is not one).
  DanceMove partnerOf(DanceMove m) {
    final d = m.duo == null ? null : _duos[m.duo!];
    return d == null ? m : d[1 - m.part.clamp(0, 1)];
  }

  bool get hasDuets => _duos.isNotEmpty;

  /// How tall the body stands at rest, metres.
  double height = 0;

  /// The rest normals evened out with their neighbours' twice: a scan's surface is
  /// lumpy, and lumps catch the light.
  static void _smooth(DanceMesh m) {
    final n = m.positions, t = m.trisAt;
    final acc = Float64List(n * 3);
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < n * 3; i++) {
        acc[i] = m.nrm[i];
      }
      for (var k = 0; k < t.length; k += 3) {
        final a = t[k], b = t[k + 1], c = t[k + 2];
        for (var j = 0; j < 3; j++) {
          final s = m.nrm[a * 3 + j] + m.nrm[b * 3 + j] + m.nrm[c * 3 + j];
          acc[a * 3 + j] += s * 0.25;
          acc[b * 3 + j] += s * 0.25;
          acc[c * 3 + j] += s * 0.25;
        }
      }
      for (var v = 0; v < n; v++) {
        final x = acc[v * 3], y = acc[v * 3 + 1], z = acc[v * 3 + 2];
        final l = 1 / math.sqrt(x * x + y * y + z * z + 1e-12);
        m.nrm[v * 3] = x * l;
        m.nrm[v * 3 + 1] = y * l;
        m.nrm[v * 3 + 2] = z * l;
      }
    }
  }

  final List<String> names;
  final List<int> parent;

  /// Each bone's rest in the world, 3×4 row-major.
  final Float64List rest;
  final List<DanceMesh> meshes;
  final List<DanceMove> moves;
  final ByteData _samples;
  final int fpb;
  late final Float64List _inv, _rel;
  late final int _hipsIx;

  int get bones => names.length;
  int get _stride => bones * 8 + 6;

  int bone(String name) => names.indexOf(name);

  static Future<DanceRig> load(AssetBundle bundle, String dir) async {
    final j = jsonDecode(await bundle.loadString('${dir}dancer.json')) as Map<String, dynamic>;
    final mesh = await bundle.load('${dir}dancer.bin');
    final moves = await bundle.load('${dir}moves.bin');
    return DanceRig.parse(j, mesh, moves);
  }

  factory DanceRig.parse(Map<String, dynamic> j, ByteData mesh, ByteData moves) {
    final bones = (j['bones'] as List).cast<Map<String, dynamic>>();
    final rest = Float64List(bones.length * 12);
    for (var i = 0; i < bones.length; i++) {
      final r = (bones[i]['rest'] as List).cast<num>();
      for (var k = 0; k < 12; k++) {
        rest[i * 12 + k] = r[k].toDouble();
      }
    }
    final bytes = mesh.buffer.asUint8List(mesh.offsetInBytes, mesh.lengthInBytes);
    final meshes = <DanceMesh>[];
    for (final m in (j['meshes'] as List).cast<Map<String, dynamic>>()) {
      final n = (m['positions'] as num).toInt(), corners = (m['verts'] as num).toInt(), t = (m['tris'] as num).toInt();
      var o = (m['offset'] as num).toInt();
      Float32List f32(int count) {
        final out = Float32List(count);
        final bd = ByteData.sublistView(bytes, o, o + count * 4);
        for (var i = 0; i < count; i++) {
          out[i] = bd.getFloat32(i * 4, Endian.little);
        }
        o += count * 4;
        return out;
      }

      Uint8List u8(int count) {
        final out = Uint8List.fromList(bytes.sublist(o, o + count));
        o += count;
        return out;
      }

      Uint16List u16(int count) {
        final out = Uint16List(count);
        final bd = ByteData.sublistView(bytes, o, o + count * 2);
        for (var i = 0; i < count; i++) {
          out[i] = bd.getUint16(i * 2, Endian.little);
        }
        o += count * 2;
        return out;
      }

      final pos = f32(n * 3), nrm = f32(n * 3);
      final bone = u8(n * 4), weight = u8(n * 4);
      final uv = f32(corners * 2);
      final src = u16(corners);
      final tris = u16(t * 3);
      meshes.add(DanceMesh(pos: pos, nrm: nrm, bone: bone, weight: weight, uv: uv, src: src, tris: tris));
    }
    return DanceRig(
      names: [for (final b in bones) '${b['name']}'],
      parent: [for (final b in bones) (b['parent'] as num).toInt()],
      rest: rest,
      meshes: meshes,
      moves: [for (final m in (j['moves'] as List)) DanceMove.fromJson((m as Map).cast())],
      samples: moves,
      fpb: (j['fpb'] as num?)?.toInt() ?? 8,
    );
  }

  /// [move]'s pose [beat] capture beats in (wrapping round its loop), into [out].
  void sample(DanceMove move, double beat, DancePose out) {
    final n = move.beats * fpb;
    var s = (beat % move.beats) * fpb;
    if (s < 0) s += n;
    final i = s.floor().clamp(0, n - 1);
    final f = s - i;
    final a = move.offset + i * _stride, b = a + _stride;
    final d = _samples;
    for (var k = 0; k < bones; k++) {
      double q0 = d.getInt16(a + k * 8, Endian.little) / 32767.0;
      double q1 = d.getInt16(a + k * 8 + 2, Endian.little) / 32767.0;
      double q2 = d.getInt16(a + k * 8 + 4, Endian.little) / 32767.0;
      double q3 = d.getInt16(a + k * 8 + 6, Endian.little) / 32767.0;
      if (f > 0) {
        var r0 = d.getInt16(b + k * 8, Endian.little) / 32767.0;
        var r1 = d.getInt16(b + k * 8 + 2, Endian.little) / 32767.0;
        var r2 = d.getInt16(b + k * 8 + 4, Endian.little) / 32767.0;
        var r3 = d.getInt16(b + k * 8 + 6, Endian.little) / 32767.0;
        if (q0 * r0 + q1 * r1 + q2 * r2 + q3 * r3 < 0) {
          r0 = -r0;
          r1 = -r1;
          r2 = -r2;
          r3 = -r3;
        }
        q0 += (r0 - q0) * f;
        q1 += (r1 - q1) * f;
        q2 += (r2 - q2) * f;
        q3 += (r3 - q3) * f;
      }
      final len = 1 / math.sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3);
      out.q[k * 4] = q0 * len;
      out.q[k * 4 + 1] = q1 * len;
      out.q[k * 4 + 2] = q2 * len;
      out.q[k * 4 + 3] = q3 * len;
    }
    final ha = a + bones * 8, hb = b + bones * 8;
    for (var k = 0; k < 3; k++) {
      final x0 = d.getInt16(ha + k * 2, Endian.little) / 1000.0;
      final x1 = f > 0 ? d.getInt16(hb + k * 2, Endian.little) / 1000.0 : x0;
      out.hips[k] = x0 + (x1 - x0) * f;
    }
  }

  /// Each bone's place in the world for [pose] (3×4 each), into [out].
  void solve(DancePose pose, Float64List out) {
    final m = _m, t = _t;
    for (var i = 0; i < bones; i++) {
      _fromQuat(pose.q, i * 4, m);
      final p = parent[i];
      if (p < 0) {
        m[3] = pose.hips[0];
        m[7] = pose.hips[1];
        m[11] = pose.hips[2];
        out.setRange(i * 12, i * 12 + 12, m);
      } else {
        _mul(out, p * 12, _rel, i * 12, t, 0);
        _mul(t, 0, m, 0, out, i * 12);
      }
    }
  }

  final _m = Float64List(12), _t = Float64List(12);

  /// Where bone [bone] of [world] (from [solve]) is, [tip] metres along it from its
  /// head (a hand's fingertips, the top of the head), into [out] (x, y, z).
  static void jointAt(Float64List world, int bone, double tip, Float64List out) {
    final o = bone * 12;
    out[0] = world[o + 3] + world[o + 1] * tip;
    out[1] = world[o + 7] + world[o + 5] * tip;
    out[2] = world[o + 11] + world[o + 9] * tip;
  }

  /// The skinning matrices: [world] (from [solve]) against the rest, into [out].
  void skinning(Float64List world, Float64List out) {
    for (var i = 0; i < bones; i++) {
      _mul(world, i * 12, _inv, i * 12, out, i * 12);
    }
  }

  /// [mesh] put in [pose] by [skin] (from [skinning]): positions and normals, into
  /// [pos] and [nrm] (3 a position).
  static void deform(DanceMesh mesh, Float64List skin, Float32List pos, Float32List nrm) {
    final n = mesh.positions;
    final p = mesh.pos, nn = mesh.nrm, bi = mesh.bone, bw = mesh.weight;
    final m = Float64List(12);
    for (var v = 0; v < n; v++) {
      for (var k = 0; k < 12; k++) {
        m[k] = 0;
      }
      for (var j = 0; j < 4; j++) {
        final w = bw[v * 4 + j];
        if (w == 0) continue;
        final wf = w / 255.0, o = bi[v * 4 + j] * 12;
        for (var k = 0; k < 12; k++) {
          m[k] += skin[o + k] * wf;
        }
      }
      final x = p[v * 3], y = p[v * 3 + 1], z = p[v * 3 + 2];
      pos[v * 3] = m[0] * x + m[1] * y + m[2] * z + m[3];
      pos[v * 3 + 1] = m[4] * x + m[5] * y + m[6] * z + m[7];
      pos[v * 3 + 2] = m[8] * x + m[9] * y + m[10] * z + m[11];
      final a = nn[v * 3], b = nn[v * 3 + 1], c = nn[v * 3 + 2];
      final nx = m[0] * a + m[1] * b + m[2] * c, ny = m[4] * a + m[5] * b + m[6] * c, nz = m[8] * a + m[9] * b + m[10] * c;
      final l = 1 / math.sqrt(nx * nx + ny * ny + nz * nz + 1e-12);
      nrm[v * 3] = nx * l;
      nrm[v * 3 + 1] = ny * l;
      nrm[v * 3 + 2] = nz * l;
    }
  }

  /// Where the joints that read a pose are, against the hips (x, y, z each): the head,
  /// hands, elbows, feet, knees. For matching one pose to another.
  late final List<int> _keys = [for (final n in const ['Head', 'Hand_L', 'Hand_R', 'LowerArm_L', 'LowerArm_R', 'Foot_L', 'Foot_R', 'LowerLeg_L', 'LowerLeg_R']) bone(n)];

  Float64List keyJoints(DancePose pose) {
    final w = Float64List(bones * 12);
    solve(pose, w);
    final out = Float64List(_keys.length * 3);
    final h = _hipsIx * 12;
    for (var i = 0; i < _keys.length; i++) {
      final o = _keys[i] * 12;
      out[i * 3] = w[o + 3] - w[h + 3];
      out[i * 3 + 1] = w[o + 7] - w[h + 7];
      out[i * 3 + 2] = w[o + 11] - w[h + 11];
    }
    return out;
  }

  /// How far apart two poses look: the mean distance of their key joints, metres.
  static double poseDistance(Float64List a, Float64List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i += 3) {
      final dx = a[i] - b[i], dy = a[i + 1] - b[i + 1], dz = a[i + 2] - b[i + 2];
      s += math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    return s / (a.length / 3);
  }

  /// How differently two poses' key joints are moving: [a] and [aWas] a moment
  /// apart, [b] and [bWas] the same moment apart — the mean distance between the
  /// joints' two displacements, metres.
  static double motionDistance(Float64List a, Float64List aWas, Float64List b, Float64List bWas) {
    var s = 0.0;
    for (var i = 0; i < a.length; i += 3) {
      final dx = (a[i] - aWas[i]) - (b[i] - bWas[i]);
      final dy = (a[i + 1] - aWas[i + 1]) - (b[i + 1] - bWas[i + 1]);
      final dz = (a[i + 2] - aWas[i + 2]) - (b[i + 2] - bWas[i + 2]);
      s += math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    return s / (a.length / 3);
  }

  @visibleForTesting
  static void mul34(Float64List a, int ao, Float64List b, int bo, Float64List out, int oo) => _mul(a, ao, b, bo, out, oo);
}

/// What is left of the pose a dancer was in when it stepped into a new move: per bone
/// the turn from the new move's rotation to the old one (as an axis times an angle)
/// and the hips' shift, each with how fast it was changing, faded to nothing over a
/// few beats on a quintic that leaves no kink (inertialisation, Bollo 2016). The new
/// move plays whole underneath — its own timing, its own steps — rather than two
/// moves dissolving into each other, and the body carries its momentum across.
class DanceCarry {
  DanceCarry(int bones)
      : _x = Float64List(bones * 3 + 3),
        _a = Float64List(bones * 3 + 3),
        _b = Float64List(bones * 3 + 3),
        _c = Float64List(bones * 3 + 3),
        _d = Float64List(bones * 3 + 3),
        _v = Float64List(bones * 3 + 3);
  final Float64List _x, _v, _a, _b, _c, _d;

  /// Beats it fades over; 0 none.
  double len = 0;

  /// From [from] (the old pose now) and [fromWas] (it [h] beats ago) to [to] and
  /// [toWas] (the new move at its entry, and [h] before it).
  void start(DancePose from, DancePose fromWas, DancePose to, DancePose toWas, double h, double len) {
    this.len = len;
    if (len <= 0) return;
    final n = from.bones;
    final r0 = Float64List(3), r1 = Float64List(3);
    for (var b = 0; b < n; b++) {
      _logDiff(from.q, to.q, b * 4, r0);
      _logDiff(fromWas.q, toWas.q, b * 4, r1);
      for (var k = 0; k < 3; k++) {
        _x[b * 3 + k] = r0[k];
        _v[b * 3 + k] = (r0[k] - r1[k]) / h;
      }
    }
    for (var k = 0; k < 3; k++) {
      final x0 = from.hips[k] - to.hips[k], x1 = fromWas.hips[k] - toWas.hips[k];
      _x[n * 3 + k] = x0;
      _v[n * 3 + k] = (x0 - x1) / h;
    }
    // The fade's coefficients, a quintic each: from x0 at speed v0 to rest at len. A
    // speed far beyond what the gap explains (a fast swing met at a near pose) is held
    // in, or the offset would overshoot past the new move.
    final t1 = len;
    for (var i = 0; i < _x.length; i++) {
      final x0 = _x[i];
      final cap = 4 * x0.abs() / t1 + 0.6;
      final v0 = _v[i].clamp(-cap, cap);
      _v[i] = v0;
      final a0 = (-8 * v0 * t1 - 20 * x0) / (t1 * t1);
      _a[i] = -(a0 * t1 * t1 + 6 * v0 * t1 + 12 * x0) / (2 * math.pow(t1, 5));
      _b[i] = (3 * a0 * t1 * t1 + 16 * v0 * t1 + 30 * x0) / (2 * math.pow(t1, 4));
      _c[i] = -(3 * a0 * t1 * t1 + 12 * v0 * t1 + 20 * x0) / (2 * t1 * t1 * t1);
      _d[i] = a0 / 2;
    }
  }

  /// [pose] (the new move's) with what is left of the old one [t] beats after the step.
  void apply(DancePose pose, double t) {
    if (len <= 0 || t >= len || t < 0) return;
    final n = pose.bones;
    final t2 = t * t, t3 = t2 * t, t4 = t3 * t, t5 = t4 * t;
    double at(int i) => _a[i] * t5 + _b[i] * t4 + _c[i] * t3 + _d[i] * t2 + _v[i] * t + _x[i];
    for (var b = 0; b < n; b++) {
      final x = at(b * 3), y = at(b * 3 + 1), z = at(b * 3 + 2);
      final ang = math.sqrt(x * x + y * y + z * z);
      if (ang < 1e-6) continue;
      final s = math.sin(ang / 2) / ang;
      final dw = math.cos(ang / 2), dx = x * s, dy = y * s, dz = z * s;
      final o = b * 4;
      final w = pose.q[o], qx = pose.q[o + 1], qy = pose.q[o + 2], qz = pose.q[o + 3];
      // d · q
      pose.q[o] = dw * w - dx * qx - dy * qy - dz * qz;
      pose.q[o + 1] = dw * qx + dx * w + dy * qz - dz * qy;
      pose.q[o + 2] = dw * qy - dx * qz + dy * w + dz * qx;
      pose.q[o + 3] = dw * qz + dx * qy - dy * qx + dz * w;
    }
    for (var k = 0; k < 3; k++) {
      pose.hips[k] += at(n * 3 + k);
    }
  }

  /// The turn taking bone [o]'s rotation in [b] to its rotation in [a] (a · b⁻¹, the
  /// short way), as an axis times its angle, into [out].
  static void _logDiff(Float64List a, Float64List b, int o, Float64List out) {
    final aw = a[o], ax = a[o + 1], ay = a[o + 2], az = a[o + 3];
    final bw = b[o], bx = -b[o + 1], by = -b[o + 2], bz = -b[o + 3];
    var w = aw * bw - ax * bx - ay * by - az * bz;
    var x = aw * bx + ax * bw + ay * bz - az * by;
    var y = aw * by - ax * bz + ay * bw + az * bx;
    var z = aw * bz + ax * by - ay * bx + az * bw;
    if (w < 0) {
      w = -w;
      x = -x;
      y = -y;
      z = -z;
    }
    final sn = math.sqrt(x * x + y * y + z * z);
    if (sn < 1e-9) {
      out[0] = out[1] = out[2] = 0;
      return;
    }
    final ang = 2 * math.atan2(sn, w);
    out[0] = x / sn * ang;
    out[1] = y / sn * ang;
    out[2] = z / sn * ang;
  }
}

void _identity(Float64List m, int o) {
  for (var k = 0; k < 12; k++) {
    m[o + k] = (k == 0 || k == 5 || k == 10) ? 1 : 0;
  }
}

/// out = a · b, 3×4 affine (the fourth row 0 0 0 1 implied).
void _mul(Float64List a, int ao, Float64List b, int bo, Float64List out, int oo) {
  final r = Float64List(12);
  for (var i = 0; i < 3; i++) {
    final a0 = a[ao + i * 4], a1 = a[ao + i * 4 + 1], a2 = a[ao + i * 4 + 2], a3 = a[ao + i * 4 + 3];
    for (var j = 0; j < 4; j++) {
      r[i * 4 + j] = a0 * b[bo + j] + a1 * b[bo + 4 + j] + a2 * b[bo + 8 + j] + (j == 3 ? a3 : 0);
    }
  }
  out.setRange(oo, oo + 12, r);
}

/// The inverse of a rotation with a uniform scale and a translation.
void _invert(Float64List m, int o, Float64List out, int oo) {
  final s2 = m[o] * m[o] + m[o + 4] * m[o + 4] + m[o + 8] * m[o + 8];
  final r = Float64List(12);
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      r[i * 4 + j] = m[o + j * 4 + i] / s2;
    }
  }
  for (var i = 0; i < 3; i++) {
    r[i * 4 + 3] = -(r[i * 4] * m[o + 3] + r[i * 4 + 1] * m[o + 7] + r[i * 4 + 2] * m[o + 11]);
  }
  out.setRange(oo, oo + 12, r);
}

void _fromQuat(Float64List q, int o, Float64List m) {
  final w = q[o], x = q[o + 1], y = q[o + 2], z = q[o + 3];
  m[0] = 1 - 2 * (y * y + z * z);
  m[1] = 2 * (x * y - z * w);
  m[2] = 2 * (x * z + y * w);
  m[3] = 0;
  m[4] = 2 * (x * y + z * w);
  m[5] = 1 - 2 * (x * x + z * z);
  m[6] = 2 * (y * z - x * w);
  m[7] = 0;
  m[8] = 2 * (x * z - y * w);
  m[9] = 2 * (y * z + x * w);
  m[10] = 1 - 2 * (x * x + y * y);
  m[11] = 0;
}
