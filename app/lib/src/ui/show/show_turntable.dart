// The turntable: a carousel of holograms. Seven shapes stand round a ring seen from
// in front and a little above, the one at the front in focus — big, bright, dancing
// badly — the rest smaller and dimmer as they go round the back. Every few bars the
// ring turns one place on (a drop throws it three), springing past and settling, and
// the shape that went round the back is swapped for another.
//
// Nothing is textured: each shape is light. A triangle is as bright as it is edge-on
// to the eye (a hologram's look: outlines glowing, the middle almost clear), its
// colour runs round the wheel with its height, its slant, its place on the ring and
// the bar, and the triangles are added, not stacked, so nothing needs sorting. A
// floor grid and the ring's track under them, a beam up into the one in front, scan
// lines over it all; the snare tears a slice of the shape in front sideways.
//
// The shape in front is never quite itself: every few bars it is stretched into a new
// form (tall and thin, flat and wide, long), the kick squashes it like jelly and it
// springs back past where it was, the snare knocks it into a lean, the low end runs a
// wave up it, and it hops on the beat.
//
// The shapes: a dozen built here from formulas (torus knots, a shell, superformula
// solids, a Klein bottle, a coil, a double helix, gyroscope rings, an urchin, a
// gear), and every .glb and .obj under assets/show/models/ — any model off the web,
// read for its shape alone.
//
// All on the CPU and drawn with one drawVertices: one pass on Impeller.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/show/show_state.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_sims.dart';

/// A shape: a soup of triangles, x, y, z of each corner, nine to a triangle. Centred
/// on the origin, y up, its longest side two units.
class TurntableMesh {
  TurntableMesh._(this.pos, this.top);
  final Float32List pos;

  /// The highest y: the shape runs from -top to top.
  final double top;

  int get triangles => pos.length ~/ 9;

  static TurntableMesh fitted(List<double> pos, {double size = 2}) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (var i = 0; i + 2 < pos.length; i += 3) {
      minX = math.min(minX, pos[i]);
      maxX = math.max(maxX, pos[i]);
      minY = math.min(minY, pos[i + 1]);
      maxY = math.max(maxY, pos[i + 1]);
      minZ = math.min(minZ, pos[i + 2]);
      maxZ = math.max(maxZ, pos[i + 2]);
    }
    final span = math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ));
    final k = span <= 0 || !span.isFinite ? 1.0 : size / span;
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2;
    final out = Float32List(pos.length);
    for (var i = 0; i + 2 < pos.length; i += 3) {
      out[i] = (pos[i] - cx) * k;
      out[i + 1] = (pos[i + 1] - cy) * k;
      out[i + 2] = (pos[i + 2] - cz) * k;
    }
    return TurntableMesh._(out, math.max(0.05, (maxY - cy) * k));
  }
}

/// A shape as the ring has it: in full for the front, lighter for the rest.
class TurntableModel {
  TurntableModel(this.name, this.hi, {TurntableMesh? lo, this.made = false}) : lo = lo ?? hi;
  final String name;
  final TurntableMesh hi, lo;

  /// Built here from a formula, rather than read off a file.
  final bool made;
}

// ------------------------------------------------------------------ the shapes built here
typedef _P = List<double>;

class _Soup {
  final pos = <double>[];

  void tri(_P a, _P b, _P c) => pos
    ..addAll(a)
    ..addAll(b)
    ..addAll(c);

  void quad(_P a, _P b, _P c, _P d) {
    tri(a, b, c);
    tri(a, c, d);
  }

  /// A surface over (u, v) in 0..1, [nu] by [nv] cells.
  void surface(int nu, int nv, _P Function(double u, double v) f) {
    final g = [for (var j = 0; j <= nv; j++) for (var i = 0; i <= nu; i++) f(i / nu, j / nv)];
    _P at(int i, int j) => g[j * (nu + 1) + i];
    for (var j = 0; j < nv; j++) {
      for (var i = 0; i < nu; i++) {
        quad(at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1));
      }
    }
  }

  /// A tube of [radius] along [curve] (t in 0..1), its section turned with the curve:
  /// the Frenet frame, which is the same at both ends of a closed curve, so a knot
  /// meets itself without a twist. Where the curve is straight, any square frame.
  void tube(int segs, int sides, double radius, _P Function(double t) curve) {
    const e = 1e-3;
    List<_P> ring(double t) {
      final p0 = curve(t - e), p1 = curve(t), p2 = curve(t + e);
      var tx = p2[0] - p0[0], ty = p2[1] - p0[1], tz = p2[2] - p0[2];
      final tl = math.sqrt(tx * tx + ty * ty + tz * tz);
      tx /= tl;
      ty /= tl;
      tz /= tl;
      var nx = p2[0] - 2 * p1[0] + p0[0], ny = p2[1] - 2 * p1[1] + p0[1], nz = p2[2] - 2 * p1[2] + p0[2];
      final along = nx * tx + ny * ty + nz * tz;
      nx -= along * tx;
      ny -= along * ty;
      nz -= along * tz;
      var nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-9) {
        // Straight: square to the tangent and to whichever axis it is least along.
        final (ux, uy, uz) = ty.abs() < 0.9 ? (0.0, 1.0, 0.0) : (1.0, 0.0, 0.0);
        nx = ty * uz - tz * uy;
        ny = tz * ux - tx * uz;
        nz = tx * uy - ty * ux;
        nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      }
      nx /= nl;
      ny /= nl;
      nz /= nl;
      final bx = ty * nz - tz * ny, by = tz * nx - tx * nz, bz = tx * ny - ty * nx;
      return [
        for (var k = 0; k < sides; k++)
          [
            p1[0] + radius * (math.cos(k / sides * math.pi * 2) * nx + math.sin(k / sides * math.pi * 2) * bx),
            p1[1] + radius * (math.cos(k / sides * math.pi * 2) * ny + math.sin(k / sides * math.pi * 2) * by),
            p1[2] + radius * (math.cos(k / sides * math.pi * 2) * nz + math.sin(k / sides * math.pi * 2) * bz),
          ],
      ];
    }

    var prev = ring(0);
    for (var s = 1; s <= segs; s++) {
      final next = ring(s / segs);
      for (var k = 0; k < sides; k++) {
        final k1 = (k + 1) % sides;
        quad(prev[k], prev[k1], next[k1], next[k]);
      }
      prev = next;
    }
  }

  /// A torus of [r] round a circle of [big] in the plane [plane] ('xy', 'yz', 'xz').
  void torus(int nu, int nv, double big, double r, String plane) => surface(nu, nv, (u, v) {
        final a = u * math.pi * 2, b = v * math.pi * 2;
        final q = big + r * math.cos(b), h = r * math.sin(b);
        final (x, y, z) = (q * math.cos(a), q * math.sin(a), h);
        return switch (plane) { 'yz' => [h, x, y], 'xz' => [x, h, y], _ => [x, y, z] };
      });

  TurntableMesh done() => TurntableMesh.fitted(pos);
}

/// Bourke's superformula: a radius for an angle, from a symmetry [m] and three
/// exponents. Kept from running off to infinity where its terms vanish.
double _superformula(double a, double m, double n1, double n2, double n3) {
  final t = math.pow((math.cos(m * a / 4)).abs(), n2) + math.pow((math.sin(m * a / 4)).abs(), n3);
  if (t <= 1e-9) return 0;
  return math.min(4.0, math.pow(t, -1 / n1).toDouble());
}

TurntableMesh _supershape(double d, List<double> r1, List<double> r2) {
  final s = _Soup();
  s.surface(math.max(12, (56 * d).round()), math.max(8, (30 * d).round()), (u, v) {
    final th = -math.pi + u * math.pi * 2, ph = -math.pi / 2 + v * math.pi;
    final a = _superformula(th, r1[0], r1[1], r1[2], r1[3]), b = _superformula(ph, r2[0], r2[1], r2[2], r2[3]);
    return [a * math.cos(th) * b * math.cos(ph), b * math.sin(ph), a * math.sin(th) * b * math.cos(ph)];
  });
  return s.done();
}

/// An icosahedron's faces, each split in four [levels] times and pushed out onto
/// the unit sphere.
List<(_P, _P, _P)> _icosphere(int levels) {
  final t = (1 + math.sqrt(5)) / 2;
  _P unit(_P p) {
    final l = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    return [p[0] / l, p[1] / l, p[2] / l];
  }

  final v = [
    [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
    [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
  ].map((p) => unit([for (final x in p) x.toDouble()])).toList();
  const f = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
  ];
  var faces = [for (final x in f) (v[x[0]], v[x[1]], v[x[2]])];
  _P mid(_P a, _P b) => unit([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2]);
  for (var l = 0; l < levels; l++) {
    faces = [
      for (final (a, b, c) in faces) ...[
        (a, mid(a, b), mid(c, a)),
        (b, mid(b, c), mid(a, b)),
        (c, mid(c, a), mid(b, c)),
        (mid(a, b), mid(b, c), mid(c, a)),
      ],
    ];
  }
  return faces;
}

/// The shapes built here, by name, each at a level of detail [d] (1 for the one in
/// front, less for the ring).
final Map<String, TurntableMesh Function(double d)> _shapes = {
  // A trefoil: the (2, 3) torus knot, standing up to face the room.
  'knot': (d) {
    final s = _Soup();
    s.tube(math.max(24, (140 * d).round()), math.max(5, (12 * d).round()), 0.42, (t) {
      final a = t * math.pi * 2, r = 2 + math.cos(3 * a);
      return [r * math.cos(2 * a), r * math.sin(2 * a), math.sin(3 * a)];
    });
    return s.done();
  },
  // The (3, 5) torus knot: thinner, busier.
  'star knot': (d) {
    final s = _Soup();
    s.tube(math.max(40, (220 * d).round()), math.max(4, (8 * d).round()), 0.24, (t) {
      final a = t * math.pi * 2, r = 2 + math.cos(5 * a);
      return [r * math.cos(3 * a), r * math.sin(3 * a), -math.sin(5 * a)];
    });
    return s.done();
  },
  // A sea shell: a tube growing along a widening spiral, apex up.
  'shell': (d) {
    final s = _Soup();
    s.surface(math.max(6, (14 * d).round()), math.max(24, (110 * d).round()), (u, v) {
      final a = v * 3.2 * math.pi * 2, b = u * math.pi * 2;
      final r = math.exp(0.12 * a);
      final cx = r * math.cos(a), cy = -1.1 * r, cz = r * math.sin(a);
      final sec = 0.5 * r;
      return [cx + sec * math.cos(b) * math.cos(a), cy + sec * math.sin(b), cz + sec * math.cos(b) * math.sin(a)];
    });
    return s.done();
  },
  'starfish': (d) => _supershape(d, [5, 0.1, 1.7, 1.7], [1, 0.3, 0.5, 0.5]),
  'spikes': (d) => _supershape(d, [7, 0.2, 1.7, 1.7], [7, 0.2, 1.7, 1.7]),
  'pod': (d) => _supershape(d, [6, 1, 1, 1], [3, 0.5, 1.7, 1.7]),
  // A torus whose four-lobed section turns three-quarters round as it goes.
  'twist': (d) {
    final s = _Soup();
    s.surface(math.max(8, (18 * d).round()), math.max(24, (120 * d).round()), (u, v) {
      final a = v * math.pi * 2, b = u * math.pi * 2;
      final sec = 0.5 * (1 + 0.35 * math.cos(4 * b + 3 * a));
      final rx = math.cos(a), ry = math.sin(a);
      return [1.6 * rx + sec * math.cos(b) * rx, 1.6 * ry + sec * math.cos(b) * ry, sec * math.sin(b)];
    });
    return s.done();
  },
  // A Klein bottle, the figure-eight way of putting it in three dimensions.
  'klein': (d) {
    final s = _Soup();
    s.surface(math.max(16, (64 * d).round()), math.max(8, (22 * d).round()), (uu, vv) {
      final u = uu * math.pi * 2, v = vv * math.pi * 2;
      final q = 2 + math.cos(u / 2) * math.sin(v) - math.sin(u / 2) * math.sin(2 * v);
      return [q * math.cos(u), q * math.sin(u), math.sin(u / 2) * math.sin(v) + math.cos(u / 2) * math.sin(2 * v)];
    });
    return s.done();
  },
  'coil': (d) {
    final s = _Soup();
    s.tube(math.max(48, (220 * d).round()), math.max(4, (7 * d).round()), 0.16, (t) {
      final a = t * 6 * math.pi * 2;
      return [math.cos(a), -1.8 + 3.6 * t, math.sin(a)];
    });
    return s.done();
  },
  // Two strands round each other and the rungs between them.
  'helix': (d) {
    final s = _Soup();
    final segs = math.max(30, (120 * d).round()), sides = math.max(4, (7 * d).round());
    for (final phase in [0.0, math.pi]) {
      s.tube(segs, sides, 0.14, (t) {
        final a = t * 2.5 * math.pi * 2 + phase;
        return [math.cos(a), -2 + 4 * t, math.sin(a)];
      });
    }
    for (var k = 1; k < 20; k++) {
      final t = k / 20, a = t * 2.5 * math.pi * 2, y = -2 + 4 * t;
      final p = [math.cos(a), y, math.sin(a)], q = [-math.cos(a), y, -math.sin(a)];
      s.tube(1, sides, 0.06, (u) => [p[0] + (q[0] - p[0]) * u, y, p[2] + (q[2] - p[2]) * u]);
    }
    return s.done();
  },
  // Three rings, square to each other, round a ball.
  'gyro': (d) {
    final s = _Soup();
    final nu = math.max(16, (64 * d).round()), nv = math.max(4, (8 * d).round());
    s.torus(nu, nv, 1.6, 0.11, 'xy');
    s.torus(nu, nv, 1.4, 0.11, 'yz');
    s.torus(nu, nv, 1.2, 0.11, 'xz');
    for (final (a, b, c) in _icosphere(d > 0.6 ? 2 : 1)) {
      s.tri([for (final x in a) x * 0.5], [for (final x in b) x * 0.5], [for (final x in c) x * 0.5]);
    }
    return s.done();
  },
  // An urchin: a spike off every face of a ball, their lengths in waves.
  'urchin': (d) {
    final s = _Soup();
    for (final (a, b, c) in _icosphere(d > 0.6 ? 2 : 1)) {
      final cx = (a[0] + b[0] + c[0]) / 3, cy = (a[1] + b[1] + c[1]) / 3, cz = (a[2] + b[2] + c[2]) / 3;
      final cl = math.sqrt(cx * cx + cy * cy + cz * cz);
      final len = 1 + 0.35 + 0.45 * (0.5 + 0.5 * math.sin(7 * cx + 5 * cy + 3 * cz));
      final tip = [cx / cl * len, cy / cl * len, cz / cl * len];
      s.tri(a, b, tip);
      s.tri(b, c, tip);
      s.tri(c, a, tip);
    }
    return s.done();
  },
  // A gear of eighteen teeth with a hole through it, standing up.
  'gear': (d) {
    final s = _Soup();
    const teeth = 18, h = 0.22;
    final out = <(double, double)>[], hole = <(double, double)>[];
    for (var i = 0; i < teeth; i++) {
      for (final (k, r) in const [(0.0, 1.0), (0.18, 1.25), (0.5, 1.25), (0.68, 1.0)]) {
        final a = (i + k) / teeth * math.pi * 2;
        out.add((math.cos(a) * r, math.sin(a) * r));
        hole.add((math.cos(a) * 0.35, math.sin(a) * 0.35));
      }
    }
    final n = out.length;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final (ox, oy) = out[i];
      final (px, py) = out[j];
      final (hx, hy) = hole[i];
      final (qx, qy) = hole[j];
      s.quad([ox, oy, -h], [px, py, -h], [px, py, h], [ox, oy, h]);
      s.quad([hx, hy, h], [qx, qy, h], [qx, qy, -h], [hx, hy, -h]);
      s.quad([hx, hy, h], [ox, oy, h], [px, py, h], [qx, qy, h]);
      s.quad([qx, qy, -h], [px, py, -h], [ox, oy, -h], [hx, hy, -h]);
    }
    return s.done();
  },
};

// ------------------------------------------------------------------ the bank
/// Every shape there is: the ones built here, then the files as they load.
class TurntableBank {
  TurntableBank._();
  static final shared = TurntableBank._();

  static const dir = 'assets/show/models/';

  final models = <TurntableModel>[];
  Future<void>? _loading;

  /// Builds the shapes and reads the files, once, a shape at a time with a turn of
  /// the loop between them, so the stage keeps its frames while it happens. Each
  /// joins the bank as it is ready.
  Future<void> warm() => _loading ??= _load();

  Future<void> _load() async {
    for (final e in _shapes.entries) {
      models.add(TurntableModel(e.key, e.value(1), lo: e.value(0.4), made: true));
      await Future<void>.delayed(Duration.zero);
    }
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final all = manifest.listAssets().where((p) => p.startsWith(dir)).toList()..sort();
    for (final p in all) {
      final lower = p.toLowerCase();
      if (!lower.endsWith('.glb') && !lower.endsWith('.obj')) continue;
      try {
        final name = p.substring(dir.length, p.length - 4);
        final mesh = lower.endsWith('.obj')
            ? _Obj.read(await rootBundle.loadString(p))
            : _Glb.read((await rootBundle.load(p)).buffer.asUint8List());
        if (mesh != null) models.add(TurntableModel(name, mesh));
      } catch (e) {
        // One bad model is one model fewer.
        // ignore: avoid_print
        print('turntable $p: $e');
      }
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// glTF's binary form, for its shape: the meshes of the default scene with their
/// nodes' transforms, triangles only. Compressed meshes (Draco, meshopt) are not read.
class _Glb {
  /// More than this and the model is skipped: it is all done on the CPU, every frame.
  static const maxTriangles = 8000;

  static TurntableMesh? read(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 20 || data.getUint32(0, Endian.little) != 0x46546C67) return null;
    Map<String, dynamic>? json;
    Uint8List? bin;
    var at = 12;
    while (at + 8 <= bytes.length) {
      final len = data.getUint32(at, Endian.little), type = data.getUint32(at + 4, Endian.little);
      final chunk = Uint8List.sublistView(bytes, at + 8, at + 8 + len);
      if (type == 0x4E4F534A) json = jsonDecode(utf8.decode(chunk)) as Map<String, dynamic>;
      if (type == 0x004E4942) bin = chunk;
      at += 8 + len;
    }
    if (json == null) return null;
    final g = _Gltf(json, bin);
    final pos = <double>[];

    void node(int i, Float64List parent) {
      final n = g.list('nodes')[i] as Map;
      final m = _mul(parent, _local(n));
      if (n['mesh'] is int) {
        for (final prim in ((g.list('meshes')[n['mesh'] as int] as Map)['primitives'] as List? ?? const [])) {
          final pr = prim as Map;
          if ((pr['mode'] ?? 4) != 4) continue;
          final attrs = (pr['attributes'] as Map?) ?? const {};
          if (attrs['POSITION'] is! int) continue;
          final p = g.floats(attrs['POSITION'] as int);
          final idx = pr['indices'] is int ? g.ints(pr['indices'] as int) : List<int>.generate(p.length ~/ 3, (k) => k);
          for (var t = 0; t + 2 < idx.length; t += 3) {
            if (pos.length ~/ 9 >= maxTriangles) return;
            for (var k = 0; k < 3; k++) {
              final vi = idx[t + k];
              final x = p[vi * 3], y = p[vi * 3 + 1], z = p[vi * 3 + 2];
              pos
                ..add(m[0] * x + m[4] * y + m[8] * z + m[12])
                ..add(m[1] * x + m[5] * y + m[9] * z + m[13])
                ..add(m[2] * x + m[6] * y + m[10] * z + m[14]);
            }
          }
        }
      }
      for (final ch in (n['children'] as List? ?? const [])) {
        node(ch as int, m);
      }
    }

    final scenes = g.list('scenes');
    final roots = scenes.isEmpty
        ? [for (var i = 0; i < g.list('nodes').length; i++) i]
        : [for (final r in ((scenes[(json['scene'] as int?) ?? 0] as Map)['nodes'] as List? ?? const [])) r as int];
    for (final r in roots) {
      node(r, _identity());
    }
    if (pos.isEmpty || pos.length ~/ 9 >= maxTriangles) return null;
    return TurntableMesh.fitted(pos);
  }

  static Float64List _identity() => Float64List(16)
    ..[0] = 1
    ..[5] = 1
    ..[10] = 1
    ..[15] = 1;

  /// A node's own transform: its matrix, or its translation, rotation and scale.
  static Float64List _local(Map n) {
    if (n['matrix'] is List) return Float64List.fromList([for (final x in n['matrix'] as List) (x as num).toDouble()]);
    final t = [for (final x in (n['translation'] as List? ?? const [0, 0, 0])) (x as num).toDouble()];
    final q = [for (final x in (n['rotation'] as List? ?? const [0, 0, 0, 1])) (x as num).toDouble()];
    final s = [for (final x in (n['scale'] as List? ?? const [1, 1, 1])) (x as num).toDouble()];
    final x = q[0], y = q[1], z = q[2], w = q[3];
    return Float64List.fromList([
      (1 - 2 * (y * y + z * z)) * s[0], (2 * (x * y + z * w)) * s[0], (2 * (x * z - y * w)) * s[0], 0,
      (2 * (x * y - z * w)) * s[1], (1 - 2 * (x * x + z * z)) * s[1], (2 * (y * z + x * w)) * s[1], 0,
      (2 * (x * z + y * w)) * s[2], (2 * (y * z - x * w)) * s[2], (1 - 2 * (x * x + y * y)) * s[2], 0,
      t[0], t[1], t[2], 1,
    ]);
  }

  /// Column-major, as glTF writes them.
  static Float64List _mul(Float64List a, Float64List b) {
    final out = Float64List(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[k * 4 + r] * b[c * 4 + k];
        }
        out[c * 4 + r] = s;
      }
    }
    return out;
  }
}

/// Wavefront's text form, for its shape: the vertices and the faces (any number of
/// corners, fanned into triangles).
class _Obj {
  static TurntableMesh? read(String text) {
    final v = <double>[];
    final pos = <double>[];
    for (final raw in const LineSplitter().convert(text)) {
      final parts = raw.trim().split(RegExp(r'\s+'));
      switch (parts.first) {
        case 'v' when parts.length >= 4:
          v.addAll([for (final x in parts.sublist(1, 4)) double.parse(x)]);
        case 'f' when parts.length >= 4:
          final corners = [
            for (final c in parts.skip(1))
              switch (int.parse(c.split('/').first)) { final i when i < 0 => v.length ~/ 3 + i, final i => i - 1 },
          ];
          for (var k = 1; k + 1 < corners.length; k++) {
            if (pos.length ~/ 9 >= _Glb.maxTriangles) return null;
            for (final vi in [corners[0], corners[k], corners[k + 1]]) {
              pos.addAll([v[vi * 3], v[vi * 3 + 1], v[vi * 3 + 2]]);
            }
          }
      }
    }
    return pos.isEmpty ? null : TurntableMesh.fitted(pos);
  }
}

class _Gltf {
  _Gltf(this.json, this.bin);
  final Map<String, dynamic> json;
  final Uint8List? bin;

  List list(String key) => (json[key] as List?) ?? const [];

  Uint8List view(int i) {
    final v = list('bufferViews')[i] as Map;
    if (((v['buffer'] as int?) ?? 0) != 0 || bin == null) throw const FormatException('only the GLB buffer');
    final off = (v['byteOffset'] as int?) ?? 0;
    return Uint8List.sublistView(bin!, off, off + (v['byteLength'] as int));
  }

  static const _widths = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4};

  /// An accessor's numbers, as they are meant: normalised integers as 0..1.
  List<double> floats(int accessor) {
    final a = list('accessors')[accessor] as Map;
    final n = _widths[a['type']] ?? 1;
    final count = a['count'] as int;
    final type = a['componentType'] as int;
    final norm = a['normalized'] == true;
    final out = List<double>.filled(count * n, 0);
    if (a['bufferView'] is! int) return out;
    final v = list('bufferViews')[a['bufferView'] as int] as Map;
    final data = ByteData.sublistView(view(a['bufferView'] as int));
    final size = switch (type) { 5126 || 5125 => 4, 5122 || 5123 => 2, _ => 1 };
    final stride = (v['byteStride'] as int?) ?? size * n;
    final base = (a['byteOffset'] as int?) ?? 0;
    for (var i = 0; i < count; i++) {
      for (var k = 0; k < n; k++) {
        final o = base + i * stride + k * size;
        out[i * n + k] = switch (type) {
          5126 => data.getFloat32(o, Endian.little),
          5121 => data.getUint8(o) / (norm ? 255 : 1),
          5123 => data.getUint16(o, Endian.little) / (norm ? 65535 : 1),
          5120 => math.max(data.getInt8(o) / (norm ? 127 : 1), -1.0),
          5122 => math.max(data.getInt16(o, Endian.little) / (norm ? 32767 : 1), -1.0),
          _ => data.getUint32(o, Endian.little).toDouble(),
        };
      }
    }
    return out;
  }

  List<int> ints(int accessor) {
    final a = list('accessors')[accessor] as Map;
    final count = a['count'] as int;
    final type = a['componentType'] as int;
    final data = ByteData.sublistView(view(a['bufferView'] as int));
    final base = (a['byteOffset'] as int?) ?? 0;
    return List<int>.generate(count, (i) => switch (type) {
          5121 => data.getUint8(base + i),
          5123 => data.getUint16(base + i * 2, Endian.little),
          _ => data.getUint32(base + i * 4, Endian.little),
        });
  }
}

// ------------------------------------------------------------------ the sim
/// The shapes the one in front is stretched into, across (x and z) and up: itself,
/// a beanpole, a pancake, long, deep, a slab.
const _poses = [
  [1.0, 1.0, 1.0],
  [0.6, 1.7, 0.6],
  [1.45, 0.55, 1.45],
  [1.9, 0.75, 0.75],
  [0.8, 1.0, 1.8],
  [1.3, 1.3, 0.5],
];

/// A colour from hue (turns), saturation and value, as 0..1 each.
(double, double, double) _hsv(double h, double s, double v) {
  final hh = (h - h.floorToDouble()) * 6;
  final i = hh.floor(), f = hh - i;
  final p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
  return switch (i) { 0 => (v, t, p), 1 => (q, v, p), 2 => (p, v, t), 3 => (p, q, v), 4 => (t, p, v), _ => (v, p, q) };
}

int _argb(double r, double g, double b) =>
    (0xff << 24) | ((r * 255).round().clamp(0, 255) << 16) | ((g * 255).round().clamp(0, 255) << 8) | (b * 255).round().clamp(0, 255);

class TurntableSim implements SimLayer {
  TurntableSim() {
    TurntableBank.shared.warm();
  }

  @override
  String get kind => 'turntable';

  static const slots = 7, radius = 3.4, lift = 1.15;

  final _bank = TurntableBank.shared;
  // Seeded by the record (frame): the same shapes and the same tears every time it
  // plays, a recording played back included.
  var _rng = math.Random(17);
  int? _rngFor;
  final _ring = List<TurntableModel?>.filled(slots, null);

  /// Each slot's size, springing up from nothing when a new shape is put in it.
  final _pop = List<double>.filled(slots, 1), _popV = List<double>.filled(slots, 0);
  ui.Image? _picture;

  /// The ring's place, in slots, springing towards [_target] (the slot in front).
  double _at = 0, _atV = 0;
  int _target = 0;

  double _t = 0, _spin = 0, _hue = 0, _hueTo = 0;

  /// The one in front's springs: the squash (the kick), the lean (the snare).
  double _squash = 0, _squashV = 0, _lean = 0, _leanV = 0;
  final _stretch = [1.0, 1.0, 1.0];
  var _pose = 0;

  Float32List _pos = Float32List(0), _view = Float32List(0);
  Int32List _col = Int32List(0);

  /// The tear: how much is left of it, where up the shape it is, and which way.
  double _tear = 0, _tearY = 0, _tearX = 0;

  int? _barWas;
  double _kickWas = 0, _snareWas = 0, _since = 0;
  bool _dropWas = false;

  int _slot(num i) => ((i.round() % slots) + slots) % slots;

  TurntableModel? _pick() {
    final on = _ring.whereType<TurntableModel>().toSet();
    final made = [for (final m in _bank.models) if (m.made && !on.contains(m)) m];
    final found = [for (final m in _bank.models) if (!m.made && !on.contains(m)) m];
    // Mostly the shapes built here; now and then a model off the web.
    final pool = found.isEmpty || (made.isNotEmpty && _rng.nextDouble() < 0.75) ? made : found;
    if (pool.isEmpty) return _bank.models.isEmpty ? null : _bank.models[_rng.nextInt(_bank.models.length)];
    return pool[_rng.nextInt(pool.length)];
  }

  /// The ring on by [n] places; the shape that went round the back swapped.
  void _advance(int n) {
    for (var k = 0; k < n; k++) {
      _target++;
      final back = _slot(_target - 3);
      _ring[back] = _pick();
      _pop[back] = 0;
      _popV[back] = 0;
    }
    _newPose();
    _since = 0;
  }

  void _newPose() {
    var p = _pose;
    while (p == _pose) {
      p = _rng.nextInt(_poses.length);
    }
    _pose = p;
  }

  static void _spring(double dt, double x, double v, double k, double c, void Function(double x, double v) out) {
    // In small steps: a stiff spring at a long frame would fly apart.
    final n = (dt / (1 / 240)).ceil().clamp(1, 16);
    final h = dt / n;
    for (var i = 0; i < n; i++) {
      v += (-k * x - c * v) * h;
      x += v * h;
    }
    out(x, v);
  }

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    final record = st.master.trackId ?? 0;
    if (_rngFor != record) {
      _rngFor = record;
      _rng = math.Random(record * 7919 + 17);
    }
    for (var s = 0; s < slots; s++) {
      _ring[s] ??= _pick();
    }
    final f = st.flat;
    final kick = f['dyn.hit.kick'] ?? f['audio.kick'] ?? 0;
    final snare = f['dyn.hit.snare'] ?? 0;
    final energy = f['dyn.energy'] ?? f['master.energy'] ?? 0;
    final low = f['dyn.band.low'] ?? f['audio.low'] ?? 0;
    final pulse = f['dyn.beat.pulse'] ?? 0;
    final beatDecay = f['dyn.beat.decay'] ?? 0;
    final barSaw = f['dyn.bar.saw'] ?? (_t / 2 % 1);
    final drop = st.master.section == 'drop';
    _t += dt;
    _since += dt;

    // The ring on: every four bars, every two when the record is up; three places on
    // a drop. With no bars to go on (nothing playing), by the clock.
    final bar = st.master.barIndex;
    if (bar != null && _barWas != null && bar != _barWas) {
      if (bar % (energy > 0.6 ? 2 : 4) == 0) _advance(1);
      _hueTo += 0.06;
    }
    _barWas = bar;
    if (bar == null && _since > 4) {
      _advance(1);
      _hueTo += 0.15;
    }
    if (drop && !_dropWas) _advance(3);
    _dropWas = drop;

    _spring(dt, _at - _target, _atV, 26, 6.5, (x, v) {
      _at = x + _target;
      _atV = v;
    });
    for (var s = 0; s < slots; s++) {
      _spring(dt, _pop[s] - 1, _popV[s], 120, 10, (x, v) {
        _pop[s] = (x + 1).clamp(0.0, 1.6);
        _popV[s] = v;
      });
    }
    _hue += (_hueTo - _hue) * (1 - math.exp(-dt * 2));

    // The one in front: the jelly, the lean, the stretch, the tear.
    if (kick > 0.35 && kick > _kickWas + 0.15) _squashV += 4 + 6 * kick;
    _kickWas = kick;
    if (snare > 0.35 && snare > _snareWas + 0.15) {
      _leanV += (_rng.nextBool() ? 1 : -1) * (3 + 4 * snare);
      _tear = 1;
      _tearY = _rng.nextDouble() * 1.6 - 0.8;
      _tearX = (_rng.nextBool() ? 1 : -1) * (0.15 + 0.25 * snare);
    }
    _snareWas = snare;
    _tear *= math.exp(-dt * 14);
    _spring(dt, _squash, _squashV, 260, 7, (x, v) {
      _squash = x.clamp(-0.55, 0.55);
      _squashV = v;
    });
    _spring(dt, _lean, _leanV, 110, 4.5, (x, v) {
      _lean = x.clamp(-0.8, 0.8);
      _leanV = v;
    });
    final pose = _poses[_pose];
    final ease = 1 - math.exp(-dt * 5);
    for (var i = 0; i < 3; i++) {
      _stretch[i] += (pose[i] - _stretch[i]) * ease;
    }
    _spin += dt * (0.5 + 1.2 * energy + 2.2 * beatDecay * energy);

    final primary = st.palette.primary.toColor();
    final secondary = st.palette.secondary.toColor();
    final accent = st.palette.accent.withLightness(0.6).toColor();
    final baseHue = st.palette.primary.hue / 360;

    final next = _pass(w, h, (c) {
      final cam = _Camera(w.toDouble(), h.toDouble());
      _backdrop(c, cam, secondary, accent, beatDecay * energy);
      _models(c, cam, baseHue, kick, energy, low, pulse);
      _scan(c, cam, primary, barSaw);
    });
    _picture?.dispose();
    _picture = next;
    return next;
  }

  /// The dark, a glow in the record's colour, the floor's grid, the ring's track and
  /// the beam up into the one in front.
  void _backdrop(Canvas c, _Camera cam, Color glow, Color accent, double flash) {
    final w = cam.w, h = cam.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xff040409));
    // The glow: a fan of coloured triangles, not a gradient (three passes on Impeller).
    const n = 40;
    final cx = w / 2, cy = h * 0.42, r = math.max(w, h) * 0.75;
    final fan = Float32List(n * 6), fanCol = Int32List(n * 3);
    final mid = Color.lerp(Color.lerp(glow, Colors.black, 0.7), accent, (flash * 0.3).clamp(0.0, 0.3))!;
    final centre = _argb(mid.r, mid.g, mid.b);
    const edge = 0xff040409;
    for (var i = 0; i < n; i++) {
      final a0 = i / n * math.pi * 2, a1 = (i + 1) / n * math.pi * 2;
      fan.setAll(i * 6, [cx, cy, cx + math.cos(a0) * r, cy + math.sin(a0) * r * 0.8, cx + math.cos(a1) * r, cy + math.sin(a1) * r * 0.8]);
      fanCol.setAll(i * 3, [centre, edge, edge]);
    }
    c.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, fan, colors: fanCol), BlendMode.modulate, Paint()..color = Colors.white);

    // The floor: a grid of lines on y = 0, one draw.
    final grid = <double>[];
    void line(double x0, double z0, double x1, double z1) {
      final a = cam.project(x0, 0, z0), b = cam.project(x1, 0, z1);
      if (a == null || b == null) return;
      grid.addAll([a.$1, a.$2, b.$1, b.$2]);
    }

    for (var x = -12.0; x <= 12; x += 1.5) {
      line(x, -7, x, 14);
    }
    for (var z = -7.0; z <= 14; z += 1.5) {
      line(-12, z, 12, z);
    }
    c.drawRawPoints(
        ui.PointMode.lines,
        Float32List.fromList(grid),
        Paint()
          ..color = accent.withValues(alpha: 0.13)
          ..strokeWidth = 1);

    // The ring's track, and a fainter one outside it.
    for (final (rr, a) in const [(radius, 0.45), (radius + 0.35, 0.18)]) {
      final path = Path();
      var first = true;
      for (var i = 0; i <= 72; i++) {
        final an = i / 72 * math.pi * 2;
        final pt = cam.project(math.sin(an) * rr, 0, -math.cos(an) * rr);
        if (pt == null) continue;
        if (first) {
          path.moveTo(pt.$1, pt.$2);
          first = false;
        } else {
          path.lineTo(pt.$1, pt.$2);
        }
      }
      c.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = accent.withValues(alpha: a));
    }

    // The beam: from the floor under the front up into it, fading as it rises.
    final base = cam.project(0, 0, -radius);
    if (base != null) {
      const k = 24;
      final beam = Float32List(k * 6), beamCol = Int32List(k * 3);
      final foot = _argb(accent.r * 0.14, accent.g * 0.14, accent.b * 0.14);
      var m = 0;
      for (var i = 0; i < k; i++) {
        final a0 = i / k * math.pi * 2, a1 = (i + 1) / k * math.pi * 2;
        final p0 = cam.project(math.cos(a0) * 1.05, lift, -radius + math.sin(a0) * 1.05);
        final p1 = cam.project(math.cos(a1) * 1.05, lift, -radius + math.sin(a1) * 1.05);
        if (p0 == null || p1 == null) continue;
        beam.setAll(m * 6, [base.$1, base.$2, p0.$1, p0.$2, p1.$1, p1.$2]);
        beamCol.setAll(m * 3, [foot, 0xff000000, 0xff000000]);
        m++;
      }
      if (m > 0) {
        c.drawVertices(
          ui.Vertices.raw(ui.VertexMode.triangles, Float32List.sublistView(beam, 0, m * 6), colors: Int32List.sublistView(beamCol, 0, m * 3)),
          BlendMode.modulate,
          Paint()
            ..color = Colors.white
            ..blendMode = BlendMode.plus,
        );
      }
    }
  }

  /// The shapes round the ring, as light.
  void _models(Canvas c, _Camera cam, double baseHue, double kick, double energy, double low, double pulse) {
    var total = 0, most = 0;
    final meshes = List<TurntableMesh?>.filled(slots, null);
    final angles = List<double>.filled(slots, 0);
    for (var s = 0; s < slots; s++) {
      final m = _ring[s];
      if (m == null) continue;
      // Each slot's angle round the ring from the front, -π..π.
      var a = (s - _at) / slots * math.pi * 2;
      a -= (a / (math.pi * 2)).roundToDouble() * math.pi * 2;
      angles[s] = a;
      final mesh = (math.cos(a) + 1) / 2 > 0.8 ? m.hi : m.lo;
      meshes[s] = mesh;
      total += mesh.triangles;
      most = math.max(most, mesh.triangles);
    }
    if (total == 0) return;

    // Kept from frame to frame, grown when a bigger ring needs more.
    if (_pos.length < total * 6) _pos = Float32List(total * 6);
    if (_col.length < total * 3) _col = Int32List(total * 3);
    if (_view.length < most * 9) _view = Float32List(most * 9);
    final pos = _pos, col = _col, view = _view;
    final front = _slot(_at);
    final wave = 0.05 + 0.25 * low;
    final cp = _Camera.cp, sp = _Camera.sp;
    final cw = cam.w / 2, ch = cam.h * 0.5, focal = cam.focal;
    var o = 0;

    for (var s = 0; s < slots; s++) {
      final mesh = meshes[s];
      if (mesh == null) continue;
      final a = angles[s];
      final near = (math.cos(a) + 1) / 2;
      final focus = math.pow(near, 2.5).toDouble();
      final scale = (0.42 + 0.58 * focus) * _pop[s];
      final bright = 0.16 + 0.84 * math.pow(near, 1.5).toDouble();
      final px = math.sin(a) * radius, pz = -math.cos(a) * radius;
      final py = lift + 0.08 * math.sin(_t * 1.3 + s * 1.7) + 0.18 * pulse * (0.3 + energy) * focus;
      // The front's antics, as much as it is in front.
      final sx = scale * (1 + ((_stretch[0] * (1 + _squash * 0.5)) - 1) * focus);
      final sy = scale * (1 + ((_stretch[1] * (1 - _squash)) - 1) * focus);
      final sz = scale * (1 + ((_stretch[2] * (1 + _squash * 0.5)) - 1) * focus);
      final lean = _lean * focus, wv = wave * focus;
      final spin = _spin + s * 0.9, cs = math.cos(spin), ss = math.sin(spin);
      final tear = s == front ? _tear : 0.0;
      final top = mesh.top;
      final src = mesh.pos;
      final n = mesh.triangles;

      // Every corner into the camera's frame. The antics only where they show: the
      // shapes round the back are just turned and placed.
      final antics = focus > 0.03;
      for (var i = 0; i < n * 3; i++) {
        final y0 = src[i * 3 + 1];
        var x = src[i * 3] * sx, z = src[i * 3 + 2] * sz;
        final y = y0 * sy;
        var tx = x, tz = z;
        if (antics) {
          final up = (y0 / top + 1) / 2;
          x += lean * up * up * 1.2;
          x += math.sin(_t * 7 + y * 3.2) * wv * up;
          z += math.cos(_t * 5.3 + y * 2.7) * wv * 0.6 * up;
          if (tear > 0.02 && (y0 / top - _tearY).abs() < 0.12) x += _tearX * tear;
          final tw = lean * 0.6 * up, ct = math.cos(tw), sn = math.sin(tw);
          tx = x * ct - z * sn;
          tz = x * sn + z * ct;
        }
        final wx = tx * cs - tz * ss + px, wy = y + py, wz = tx * ss + tz * cs + pz;
        final dy = wy - _Camera.y, dz = wz - _Camera.z;
        view[i * 3] = wx;
        view[i * 3 + 1] = dy * cp + dz * sp;
        view[i * 3 + 2] = dz * cp - dy * sp;
      }

      final hueSlot = baseHue + _hue + s * 0.11;
      final glow = 0.85 + 0.6 * kick;
      final sat = 0.8 - 0.3 * kick * focus;
      for (var t = 0; t < n; t++) {
        final b = t * 9;
        final ax = view[b], ay = view[b + 1], az = view[b + 2];
        final bx = view[b + 3], by = view[b + 4], bz = view[b + 5];
        final qx = view[b + 6], qy = view[b + 7], qz = view[b + 8];
        if (az < 0.2 || bz < 0.2 || qz < 0.2) continue;
        final ex = bx - ax, ey = by - ay, ez = bz - az;
        final fx = qx - ax, fy = qy - ay, fz = qz - az;
        var nx = ey * fz - ez * fy, ny = ez * fx - ex * fz, nz = ex * fy - ey * fx;
        final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nl < 1e-12) continue;
        nx /= nl;
        ny /= nl;
        nz /= nl;
        final mx = (ax + bx + qx) / 3, my = (ay + by + qy) / 3, mz = (az + bz + qz) / 3;
        final ml = math.sqrt(mx * mx + my * my + mz * mz);
        // How edge-on it is to the eye, whichever side faces it: the hologram's glow.
        final rim = 1 - ((nx * mx + ny * my + nz * mz) / ml).abs();
        // A little light from above, so a shape reads as a shape.
        final above = (ny * 0.7 - nz * 0.3).abs();
        final yN = (src[b + 1] + src[b + 4] + src[b + 7]) / (3 * top);
        final hue = hueSlot + 0.3 * rim + 0.12 * yN + 0.06 * math.sin(_t * 2 + yN * 3);
        final v = bright * (0.045 + 0.95 * rim * rim * math.sqrt(rim)) * glow * (0.8 + 0.25 * above);
        final (r, g, bb) = _hsv(hue, sat, v.clamp(0.0, 1.0));
        final rgb = _argb(r, g, bb);
        pos[o * 6] = cw + ax * focal / az;
        pos[o * 6 + 1] = ch - ay * focal / az;
        pos[o * 6 + 2] = cw + bx * focal / bz;
        pos[o * 6 + 3] = ch - by * focal / bz;
        pos[o * 6 + 4] = cw + qx * focal / qz;
        pos[o * 6 + 5] = ch - qy * focal / qz;
        col[o * 3] = rgb;
        col[o * 3 + 1] = rgb;
        col[o * 3 + 2] = rgb;
        o++;
      }
    }
    if (o == 0) return;
    c.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, Float32List.sublistView(pos, 0, o * 6), colors: Int32List.sublistView(col, 0, o * 3)),
      BlendMode.modulate,
      Paint()
        ..color = Colors.white
        ..blendMode = BlendMode.plus,
    );
  }

  Float32List _scanLines = Float32List(0);
  double _scanW = 0;

  /// Scan lines over it all, and a brighter band rolling down once a bar.
  void _scan(Canvas c, _Camera cam, Color tint, double barSaw) {
    // One draw of lines, not a path of rectangles tessellated anew every frame.
    final n = (cam.h / 3).ceil();
    if (_scanLines.length != n * 4 || _scanW != cam.w) {
      _scanW = cam.w;
      _scanLines = Float32List(n * 4);
      for (var i = 0; i < n; i++) {
        _scanLines.setAll(i * 4, [0, i * 3 + 0.5, cam.w, i * 3 + 0.5]);
      }
    }
    c.drawRawPoints(
        ui.PointMode.lines,
        _scanLines,
        Paint()
          ..color = const Color(0x48000000)
          ..strokeWidth = 1);
    final y = barSaw * cam.h * 1.2 - cam.h * 0.1;
    c.drawRect(
        Rect.fromLTWH(0, y, cam.w, cam.h * 0.035),
        Paint()
          ..color = tint.withValues(alpha: 0.07)
          ..blendMode = BlendMode.plus);
  }

  @override
  void dispose() {
    _picture?.dispose();
    _picture = null;
  }
}

/// Where the ring is seen from: in front of it and a little above, looking down
/// past the front of it into the middle.
class _Camera {
  _Camera(this.w, this.h) : focal = math.min(w, h * 1.6) * 0.9;
  final double w, h, focal;
  static const y = 4.4, z = -8.6, lookY = 0.9, lookZ = -1.6;
  static final _pitch = math.atan2(y - lookY, lookZ - z);
  static final cp = math.cos(_pitch), sp = math.sin(_pitch);

  (double, double)? project(double x, double wy, double wz) {
    final dy = wy - y, dz = wz - z;
    final vy = dy * cp + dz * sp, vz = dz * cp - dy * sp;
    if (vz < 0.2) return null;
    return (w / 2 + x * focal / vz, h * 0.5 - vy * focal / vz);
  }
}

ui.Image _pass(int w, int h, void Function(Canvas c) draw) {
  final r = ui.PictureRecorder();
  draw(Canvas(r));
  final pic = r.endRecording();
  final img = pic.toImageSync(w, h);
  pic.dispose();
  return img;
}
