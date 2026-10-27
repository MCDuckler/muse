// The flock's bird: a pigeon scanned (a museum study skin, assets/show/flock/pigeon,
// made by tools/show-flock/pigeon_build.py), with wings modelled onto it and hinged at
// the shoulders, at three levels of detail; and the drawing of a few hundred of them
// a frame on a plain canvas, as the dancer is drawn (show_dance_draw.dart): moved,
// flapped, projected and lit per vertex on the CPU, then one drawVertices for every
// level of detail — textured for the nearest, in the scan's colours per vertex for
// the rest.
//
// The bird's own frame: x forward (the beak), y right, z up, metres, the body's middle
// at the origin. A vertex's `wing` is 0 on the body, else its side (the sign) and how
// far out along the wing it is (0 at the hinge, 1 at the tip): the flap turns it round
// the hinge, the tips a little more than the roots.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'show_dance_draw.dart' show DanceCam, chromeEnv;
import 'show_flock_surface.dart';

/// One level of detail of the bird.
class BirdLod {
  BirdLod({required this.name, required this.pos, required this.nrm, required this.uv, required this.wing, required this.col, required this.tris}) {
    // The parts: the body's triangles, the left wing's and the right wing's, so a
    // bird can be drawn far part first.
    final body = <int>[], left = <int>[], right = <int>[];
    for (var t = 0; t < triangles; t++) {
      final a = tris[t * 3], b = tris[t * 3 + 1], c = tris[t * 3 + 2];
      final w = wing[a] != 0 ? wing[a] : (wing[b] != 0 ? wing[b] : wing[c]);
      (w == 0 ? body : (w < 0 ? left : right)).addAll([a, b, c]);
    }
    bodyTris = Uint16List.fromList(body);
    leftTris = Uint16List.fromList(left);
    rightTris = Uint16List.fromList(right);
  }

  final String name;
  final Float32List pos, nrm, uv, wing;

  /// The scan's colour at each vertex, 0xffRRGGBB.
  final Int32List col;
  final Uint16List tris;
  late final Uint16List bodyTris, leftTris, rightTris;

  /// The scan's mean colour over the level, 0..1.
  late final double meanR = _mean(16), meanG = _mean(8), meanB = _mean(0);
  double _mean(int shift) {
    var s = 0;
    for (final c in col) {
      s += (c >> shift) & 0xff;
    }
    return col.isEmpty ? 1 : s / col.length / 255;
  }

  int get verts => wing.length;
  int get triangles => tris.length ~/ 3;
}

/// The bird: its levels of detail, nearest first, and where its wings hinge.
class BirdMesh {
  BirdMesh({required this.lods, required this.hingeX, required this.hingeY, required this.hingeZ, required this.wingspan});
  final List<BirdLod> lods;
  final double hingeX, hingeY, hingeZ, wingspan;

  BirdLod get near => lods.first;
  BirdLod get far => lods.last;

  /// The level for a bird whose wingspan is [px] pixels on the picture, by rank among
  /// the flock ([rank] 0 the nearest): the nearest few at full detail, a good many at
  /// the middle, the rest the roughest.
  BirdLod pick(double px, int rank, {int nearMost = 10, int midMost = 80}) {
    if (lods.length == 1) return lods.first;
    if (rank < nearMost && px > 70) return lods[0];
    if (rank < nearMost + midMost && px > 22) return lods[math.min(1, lods.length - 1)];
    return lods.last;
  }

  static BirdMesh parse(Map<String, dynamic> j, ByteData bin) {
    final hinge = (j['hinge'] as List).cast<num>();
    final lods = <BirdLod>[];
    for (final l in (j['lods'] as List).cast<Map<String, dynamic>>()) {
      final n = (l['verts'] as num).toInt(), t = (l['tris'] as num).toInt();
      var o = (l['offset'] as num).toInt();
      // Read value by value: a level's offset need not be aligned.
      Float32List f32(int count) {
        final a = Float32List(count);
        for (var i = 0; i < count; i++) {
          a[i] = bin.getFloat32(o + i * 4, Endian.little);
        }
        o += count * 4;
        return a;
      }

      final pos = f32(n * 3), nrm = f32(n * 3), uv = f32(n * 2), wing = f32(n);
      final col = Int32List(n);
      for (var i = 0; i < n; i++) {
        col[i] = 0xff000000 | (bin.getUint8(o + i * 3) << 16) | (bin.getUint8(o + i * 3 + 1) << 8) | bin.getUint8(o + i * 3 + 2);
      }
      o += n * 3;
      final tris = Uint16List(t * 3);
      for (var i = 0; i < t * 3; i++) {
        tris[i] = bin.getUint16(o + i * 2, Endian.little);
      }
      o += t * 6;
      lods.add(BirdLod(name: '${l['name']}', pos: pos, nrm: nrm, uv: uv, wing: wing, col: col, tris: tris));
    }
    return BirdMesh(
      lods: lods,
      hingeX: hinge[0].toDouble(),
      hingeY: hinge[1].toDouble(),
      hingeZ: hinge[2].toDouble(),
      wingspan: (j['wingspan'] as num?)?.toDouble() ?? 0.66,
    );
  }

  static Future<BirdMesh> load(AssetBundle bundle, String dir) async {
    final j = jsonDecode(await bundle.loadString('${dir}pigeon.json')) as Map<String, dynamic>;
    final bin = await bundle.load('${dir}pigeon.bin');
    return parse(j, bin);
  }
}

/// The mesh and the skin of one bird, read once per process.
class BirdAssets {
  BirdAssets._(this.name);
  final String name;
  static final _all = <String, BirdAssets>{};

  static BirdAssets of(String name) => _all.putIfAbsent(name, () {
        final a = BirdAssets._(name);
        a.loaded = a._load();
        return a;
      });

  @visibleForTesting
  static void put(String name, BirdMesh mesh, ui.Image skin) => _all[name] = BirdAssets._(name)
    ..mesh = mesh
    ..skin = skin;

  Future<void> loaded = Future.value();
  BirdMesh? mesh;
  ui.Image? skin;
  bool get ready => mesh != null && skin != null;
  String get dir => 'assets/show/flock/$name/';

  Future<void> _load() async {
    try {
      mesh = await BirdMesh.load(rootBundle, dir);
      final data = await rootBundle.load('${dir}skin.webp');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      skin = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (e) {
      // ignore: avoid_print
      print('bird $name: $e');
    }
  }
}

/// How the birds are coloured: lit (the scan's colours under a key light and a rim),
/// chrome (the studio reflected, as the dancer's), or flat (a silhouette, one colour).
enum BirdShade { lit, chrome, flat }

/// What the birds are lit with: the key's direction (world, need not be a unit), its
/// strength, the ambient, a tint over the scan's colours, and a rim at the edges.
class BirdLight {
  const BirdLight({
    this.keyX = -0.4,
    this.keyY = -0.6,
    this.keyZ = 0.7,
    this.keyK = 0.7,
    this.ambient = 0.45,
    this.tint = const Color(0xffffffff),
    this.rim = const Color(0xffffffff),
    this.rimK = 0,
    this.alpha = 1,
    this.flat = const Color(0xff000000),
  });
  final double keyX, keyY, keyZ, keyK, ambient, rimK, alpha;
  final Color tint, rim, flat;
}

/// A frame's birds, batched: every vertex of every bird appended to one buffer per
/// level of detail and drawn in one go when the level is done (or the buffer is
/// full — indices are sixteen bits).
class BirdBatch {
  BirdBatch({this.maxVerts = 65000, this.maxIndices = 240000})
      : _pos = Float32List(maxVerts * 2),
        _uv = Float32List(maxVerts * 2),
        _col = Int32List(maxVerts),
        _idx = Uint16List(maxIndices);

  final int maxVerts, maxIndices;
  final Float32List _pos, _uv;
  final Int32List _col;
  final Uint16List _idx;
  int _nv = 0, _ni = 0;
  bool _textured = false;
  ui.Image? _skin;
  double _skinW = 1, _skinH = 1;
  BlendMode _blend = BlendMode.srcOver;

  /// How many birds and vertices the last frame drew (for a cost line).
  int birdsDrawn = 0, vertsDrawn = 0;

  BirdStamp? _recording;

  /// From here the birds are kept as shapes, not drawn: for a stamp of the flock
  /// (the chronophotograph) to draw later, in any colour. [endStamp] gives it.
  void beginStamp() {
    _recording = BirdStamp._();
  }

  BirdStamp endStamp(FlockSurface c) {
    flush(c);
    final s = _recording!;
    _recording = null;
    return s;
  }

  /// The skin the textured level samples.
  void setSkin(ui.Image? skin) {
    if (identical(skin, _skin)) return;
    _skin = skin;
    _skinW = skin?.width.toDouble() ?? 1;
    _skinH = skin?.height.toDouble() ?? 1;
  }

  /// A frame's start.
  void begin() {
    _nv = 0;
    _ni = 0;
    birdsDrawn = 0;
    vertsDrawn = 0;
  }

  /// What is buffered, drawn — or kept, while recording a stamp.
  void flush(FlockSurface c) {
    if (_ni == 0) {
      _nv = 0;
      return;
    }
    final rec = _recording;
    if (rec != null) {
      rec._parts.add((Float32List.fromList(Float32List.sublistView(_pos, 0, _nv * 2)), Uint16List.fromList(Uint16List.sublistView(_idx, 0, _ni))));
      _nv = 0;
      _ni = 0;
      return;
    }
    final textured = _textured && _skin != null;
    c.vertices(Float32List.sublistView(_pos, 0, _nv * 2), Int32List.sublistView(_col, 0, _nv),
        indices: Uint16List.sublistView(_idx, 0, _ni),
        texture: textured ? _skin : null,
        uv: textured ? Float32List.sublistView(_uv, 0, _nv * 2) : null,
        blend: _blend);
    _nv = 0;
    _ni = 0;
  }

  // scratch for one bird
  final _wx = Float32List(4096), _wy = Float32List(4096), _wz = Float32List(4096);
  final _nx = Float32List(4096), _ny = Float32List(4096), _nz = Float32List(4096);
  final _depth = Float32List(4096);

  /// One bird of [lod] at [x],[y],[z], flying along ([fx],[fy],[fz]) (a unit), [scale]
  /// times its size, its wings at [flap] radians (up positive), coloured by [shade]
  /// and [light], seen by [cam], drawn with [blend]. [textured] draws the skin where
  /// the level has one (the nearest).
  void bird(FlockSurface c, BirdMesh mesh, BirdLod lod, DanceCam cam, double x, double y, double z, double fx, double fy, double fz, double scale, double flap,
      BirdShade shade, BirdLight light,
      {bool textured = false, BlendMode blend = BlendMode.srcOver, double roll = 0, double? alpha}) {
    final n = lod.verts;
    if (n > 4096) return;
    final wantTex = textured && identical(lod, mesh.near) && _skin != null;
    if (_nv + n > maxVerts || _ni + lod.tris.length > maxIndices || wantTex != _textured || blend != _blend) flush(c);
    _textured = wantTex;
    _blend = blend;
    // The bird's frame: forward, right (level), up — and banked by roll round forward.
    var rx = fy, ry = -fx, rz = 0.0;
    var rl = math.sqrt(rx * rx + ry * ry);
    if (rl < 1e-4) {
      rx = 1;
      ry = 0;
      rl = 1;
    }
    rx /= rl;
    ry /= rl;
    var ux = ry * fz - rz * fy, uy = rz * fx - rx * fz, uz = rx * fy - ry * fx;
    if (roll != 0) {
      final cr = math.cos(roll), sr = math.sin(roll);
      final rx2 = rx * cr + ux * sr, ry2 = ry * cr + uy * sr, rz2 = rz * cr + uz * sr;
      ux = ux * cr - rx * sr;
      uy = uy * cr - ry * sr;
      uz = uz * cr - rz * sr;
      rx = rx2;
      ry = ry2;
      rz = rz2;
    }
    final hy = mesh.hingeY, hz = mesh.hingeZ;
    final pos = lod.pos, nrm = lod.nrm, wing = lod.wing;
    // 1. the vertices into the world, the wings flapped
    for (var v = 0; v < n; v++) {
      var lx = pos[v * 3], ly = pos[v * 3 + 1], lz = pos[v * 3 + 2];
      var nlx = nrm[v * 3], nly = nrm[v * 3 + 1], nlz = nrm[v * 3 + 2];
      final w = wing[v];
      if (w != 0) {
        final side = w > 0 ? 1.0 : -1.0;
        final a = side * flap * (1 + 0.25 * w.abs());
        final ca = math.cos(a), sa = math.sin(a);
        final dy = ly - hy * side, dz = lz - hz;
        ly = hy * side + dy * ca - dz * sa;
        lz = hz + dy * sa + dz * ca;
        final ny0 = nly, nz0 = nlz;
        nly = ny0 * ca - nz0 * sa;
        nlz = ny0 * sa + nz0 * ca;
      }
      lx *= scale;
      ly *= scale;
      lz *= scale;
      _wx[v] = x + fx * lx + rx * ly + ux * lz;
      _wy[v] = y + fy * lx + ry * ly + uy * lz;
      _wz[v] = z + fz * lx + rz * ly + uz * lz;
      _nx[v] = fx * nlx + rx * nly + ux * nlz;
      _ny[v] = fy * nlx + ry * nly + uy * nlz;
      _nz[v] = fz * nlx + rz * nly + uz * nlz;
    }
    // 2. projected and coloured
    final e = cam.eye, cf = cam.f, cr = cam.right, cu = cam.up;
    final focal = cam.focal, cx = cam.cx, cy = cam.cy;
    final base = _nv;
    var klx = light.keyX, kly = light.keyY, klz = light.keyZ;
    final kl = math.sqrt(klx * klx + kly * kly + klz * klz) + 1e-9;
    klx /= kl;
    kly /= kl;
    klz /= kl;
    final a8 = ((alpha ?? light.alpha).clamp(0.0, 1.0) * 255).round() << 24;
    final tr = light.tint.r, tg = light.tint.g, tb = light.tint.b;
    final rr = light.rim.r, rg = light.rim.g, rb = light.rim.b;
    final flatCol = a8 | (light.flat.toARGB32() & 0xffffff);
    final col = lod.col;
    final texW = _skinW, texH = _skinH;
    // The roughest level is a few pixels: lit once, by the bird's own up, in the
    // scan's mean colour, rather than vertex by vertex.
    final once = shade == BirdShade.lit && identical(lod, mesh.far);
    var onceCol = 0;
    if (once) {
      var diff = ux * klx + uy * kly + uz * klz;
      if (diff < 0) diff = -diff * 0.5;
      final k = light.ambient + light.keyK * diff;
      onceCol = a8 | (_c(tr * k * lod.meanR) << 16) | (_c(tg * k * lod.meanG) << 8) | _c(tb * k * lod.meanB);
    }
    for (var v = 0; v < n; v++) {
      final dx = _wx[v] - e.x, dy = _wy[v] - e.y, dz = _wz[v] - e.z;
      final d = dx * cf.x + dy * cf.y + dz * cf.z;
      _depth[v] = d;
      final iz = 1 / math.max(d, DanceCam.near);
      final o = (base + v) * 2;
      _pos[o] = cx + focal * (dx * cr.x + dy * cr.y + dz * cr.z) * iz;
      _pos[o + 1] = cy - focal * (dx * cu.x + dy * cu.y + dz * cu.z) * iz;
      if (wantTex) {
        _uv[o] = lod.uv[v * 2] * texW;
        _uv[o + 1] = lod.uv[v * 2 + 1] * texH;
      }
      if (once) {
        _col[base + v] = onceCol;
        continue;
      }
      switch (shade) {
        case BirdShade.flat:
          _col[base + v] = flatCol;
        case BirdShade.lit:
          final nx = _nx[v], ny = _ny[v], nz = _nz[v];
          var diff = nx * klx + ny * kly + nz * klz;
          // A sheet lit from either side: the wings have one face.
          if (wing[v] != 0) diff = diff.abs();
          if (diff < 0) diff = 0;
          final k = light.ambient + light.keyK * diff;
          var r = tr * k, g = tg * k, b = tb * k;
          if (!wantTex) {
            final cc = col[v];
            r *= ((cc >> 16) & 0xff) / 255;
            g *= ((cc >> 8) & 0xff) / 255;
            b *= (cc & 0xff) / 255;
          }
          if (light.rimK > 0) {
            final il = 1 / math.sqrt(dx * dx + dy * dy + dz * dz + 1e-9);
            var fr = 1 - (nx * dx + ny * dy + nz * dz).abs() * il;
            if (fr < 0) fr = 0;
            final q = fr * fr * fr * light.rimK;
            r += rr * q;
            g += rg * q;
            b += rb * q;
          }
          _col[base + v] = a8 | (_c(r) << 16) | (_c(g) << 8) | _c(b);
        case BirdShade.chrome:
          // The normal as the camera sees it (z toward the eye); the studio it
          // reflects from the table.
          final nx = _nx[v], ny = _ny[v], nz = _nz[v];
          final vx = nx * cr.x + ny * cr.y + nz * cr.z, vy = nx * cu.x + ny * cu.y + nz * cu.z, vz = -(nx * cf.x + ny * cf.y + nz * cf.z);
          final o3 = _chrome.at(vx, vy);
          final er = _chrome.r[o3], eg = _chrome.r[o3 + 1], eb = _chrome.r[o3 + 2];
          final edge = 1 - vz.abs();
          final fres = 0.78 + 0.22 * edge * edge;
          final q = edge * edge * edge * light.rimK;
          _col[base + v] = a8 | (_c(er * fres * tr + rr * q) << 16) | (_c(eg * fres * tg + rg * q) << 8) | _c(eb * fres * tb + rb * q);
      }
    }
    // 3. the triangles: the parts far to near; the body's back faces left out (a
    //    silhouette keeps every face — its holes would show)
    final cull = shade != BirdShade.flat;
    final hingeDx = rx * hy * scale, hingeDy = ry * hy * scale, hingeDz = rz * hy * scale;
    final dBody = (x - e.x) * cf.x + (y - e.y) * cf.y + (z - e.z) * cf.z;
    final dRight = (x + hingeDx * 4 - e.x) * cf.x + (y + hingeDy * 4 - e.y) * cf.y + (z + hingeDz * 4 - e.z) * cf.z;
    final dLeft = (x - hingeDx * 4 - e.x) * cf.x + (y - hingeDy * 4 - e.y) * cf.y + (z - hingeDz * 4 - e.z) * cf.z;
    final parts = [(dBody, lod.bodyTris, cull), (dLeft, lod.leftTris, false), (dRight, lod.rightTris, false)];
    parts.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, tris, doCull) in parts) {
      final m = tris.length;
      for (var t = 0; t < m; t += 3) {
        final a = tris[t], b = tris[t + 1], cc = tris[t + 2];
        if (_depth[a] < DanceCam.near || _depth[b] < DanceCam.near || _depth[cc] < DanceCam.near) continue;
        if (doCull) {
          final ax = _pos[(base + a) * 2], ay = _pos[(base + a) * 2 + 1];
          final cross = (_pos[(base + b) * 2] - ax) * (_pos[(base + cc) * 2 + 1] - ay) - (_pos[(base + b) * 2 + 1] - ay) * (_pos[(base + cc) * 2] - ax);
          // Screen y runs down, so a face toward us winds clockwise there.
          if (cross > 0) continue;
        }
        _idx[_ni++] = base + a;
        _idx[_ni++] = base + b;
        _idx[_ni++] = base + cc;
      }
    }
    _nv += n;
    birdsDrawn++;
    vertsDrawn += n;
  }
}

int _c(double x) => x <= 0 ? 0 : (x >= 1 ? 255 : (x * 255).round());

/// The studio a chrome bird reflects (show_dance_draw.dart's chromeEnv), looked up
/// by the normal as the camera sees it: 64 × 64 cells over its x and y, worked out
/// once. A frame of four hundred birds asked for it forty thousand times, each with
/// two exponentials.
class _ChromeTable {
  _ChromeTable() {
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final vx = (i + 0.5) / n * 2 - 1, vy = (j + 0.5) / n * 2 - 1;
        final l2 = vx * vx + vy * vy;
        final vz = l2 >= 1 ? 0.0 : math.sqrt(1 - l2);
        final (er, eg, eb) = chromeEnv(2 * vz * vx, 2 * vz * vy, -1 + 2 * vz * vz);
        final o = (j * n + i) * 3;
        r[o] = er;
        r[o + 1] = eg;
        r[o + 2] = eb;
      }
    }
  }
  static const n = 64;
  final r = Float32List(n * n * 3);

  /// The cell of a normal with these screen components.
  int at(double vx, double vy) {
    var i = ((vx + 1) * 0.5 * n).toInt(), j = ((vy + 1) * 0.5 * n).toInt();
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    if (j < 0) j = 0;
    if (j >= n) j = n - 1;
    return (j * n + i) * 3;
  }
}

final _chrome = _ChromeTable();

/// The flock's shapes at one moment, kept: drawn later in one colour (the
/// chronophotograph's older exposures).
class BirdStamp {
  BirdStamp._();
  final _parts = <(Float32List, Uint16List)>[];

  void draw(FlockSurface c, Color color, {BlendMode blend = BlendMode.plus}) {
    final argb = color.toARGB32();
    for (final (pos, idx) in _parts) {
      final cols = Int32List(pos.length ~/ 2);
      cols.fillRange(0, cols.length, argb);
      c.vertices(pos, cols, indices: idx, blend: blend);
    }
  }
}
