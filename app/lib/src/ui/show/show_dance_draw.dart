// Drawing the dancer in 3D on a plain canvas: the mesh skinned on the CPU
// (show_dance_rig.dart), put in the world, seen by a camera, lit per vertex,
// sorted back to front and drawn as one drawVertices with the scan's skin as the
// texture. No depth buffer: a painter's sort of the front faces, which a body's
// shape mostly forgives. On Impeller a drawVertices costs no render passes beyond
// the one it is in (project_wetowl_impeller_perf), so a few dancers, their shadows
// and an outline are cheap on the GPU; the cost is the CPU's, about a millisecond
// for the hero mesh.
//
// The passes:
//   body      textured, lit by a key, a fill, the ambient and a rim (a second,
//             additive draw of the rim alone, so it shows on black clothes too);
//   outline   the back faces of the body pushed out along the normals, one colour:
//             a cartoon's ink line, or a neon tube;
//   shadow    the body flattened onto the floor along a light, or thrown onto a
//             wall from a lamp, in one colour, darkening (so overlaps don't add up);
//   mirror    the body upside down under a glossy floor, dim.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'show_dance_rig.dart';

class V3 {
  const V3(this.x, this.y, this.z);
  final double x, y, z;
  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double k) => V3(x * k, y * k, z * k);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  V3 cross(V3 o) => V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  V3 get unit {
    final l = length;
    return l < 1e-9 ? const V3(0, 0, 1) : this * (1 / l);
  }

  static V3 lerp(V3 a, V3 b, double t) => a + (b - a) * t;
}

/// A camera: where it is, what it looks at, how wide, on a [size] picture. A roll
/// tips the horizon (a handheld lean, a whip's tilt).
class DanceCam {
  DanceCam({required this.eye, required this.target, required this.size, this.fov = 0.62, this.roll = 0, this.shift = Offset.zero}) {
    f = (target - eye).unit;
    var r = f.cross(const V3(0, 0, 1));
    if (r.length < 1e-6) r = const V3(1, 0, 0);
    r = r.unit;
    var u = r.cross(f);
    if (roll != 0) {
      final c = math.cos(roll), s = math.sin(roll);
      final r2 = r * c + u * s, u2 = u * c - r * s;
      r = r2;
      u = u2;
    }
    right = r;
    up = u;
    focal = size.height / 2 / math.tan(fov / 2);
    cx = size.width / 2 + shift.dx * size.width;
    cy = size.height / 2 + shift.dy * size.height;
  }
  final V3 eye, target;
  final Size size;

  /// The vertical field of view, radians.
  final double fov, roll;

  /// The picture's centre moved off the middle, as a share of the size.
  final Offset shift;
  late final V3 f, right, up;
  late final double focal, cx, cy;
  static const near = 0.05;

  /// The screen point of [p] and its depth; depth under [near] is behind the camera.
  (double, double, double) project(V3 p) {
    final dx = p.x - eye.x, dy = p.y - eye.y, dz = p.z - eye.z;
    final z = dx * f.x + dy * f.y + dz * f.z;
    final iz = 1 / math.max(z, near);
    return (cx + focal * (dx * right.x + dy * right.y + dz * right.z) * iz, cy - focal * (dx * up.x + dy * up.y + dz * up.z) * iz, z);
  }

  Offset at(V3 p) {
    final (x, y, _) = project(p);
    return Offset(x, y);
  }

  /// How many pixels a metre is at depth [z].
  double scaleAt(double z) => focal / math.max(z, near);
}

/// Where one dancer stands: a spot on the floor, which way it is turned, mirrored or
/// not, and how big (a giant for the shadow scene's wall, 1 otherwise).
class DanceSpot {
  const DanceSpot({this.x = 0, this.y = 0, this.yaw = 0, this.mirror = false, this.scale = 1, this.lift = 0});
  final double x, y, yaw, scale, lift;
  final bool mirror;
}

/// How a body is lit and coloured.
class DanceLook3 {
  const DanceLook3({
    this.key = const V3(-0.45, -0.75, 0.55),
    this.keyColor = const Color(0xfffff0e0),
    this.keyK = 0.6,
    this.fill = const Color(0xff8090b0),
    this.fillK = 0.25,
    this.ambient = 0.5,
    this.rim = const Color(0xffffffff),
    this.rimK = 0.0,
    this.rimPower = 2.4,
    this.textured = true,
    this.flat,
    this.toon = 0,
    this.alpha = 1,
    this.dim = 1,
    this.shadeFlat = true,
    this.matcap = false,
  });

  /// Shaded by where the normal points on the screen, a studio's lights fixed to the
  /// camera (keyColor the light, fill the shadow, rim the edge), rather than by
  /// lights in the world: porcelain.
  final bool matcap;

  /// A flat colour lit a little (a cut-out), or exactly itself (a silhouette).
  final bool shadeFlat;

  /// Toward the key light (it need not be a unit), its colour and strength.
  final V3 key;
  final Color keyColor, fill, rim;
  final double keyK, fillK, ambient, rimK, rimPower;

  /// The scan's own colours, or [flat] (a silhouette's black, a cut-out's colour).
  final bool textured;
  final Color? flat;

  /// Bands of light, a cartoon's; 0 for smooth.
  final int toon;
  final double alpha;

  /// All of it darker (the mirror under the floor).
  final double dim;
}

/// The scratch of one mesh's drawing, kept between frames.
class DanceBody {
  DanceBody(this.mesh, ui.Image skin)
      : _local = Float32List(mesh.positions * 3),
        _localN = Float32List(mesh.positions * 3),
        _wp = Float32List(mesh.positions * 3),
        _wn = Float32List(mesh.positions * 3),
        _ps = Float32List(mesh.positions * 2),
        _depth = Float32List(mesh.positions),
        _pc = Int32List(mesh.positions),
        _screen = Float32List(mesh.verts * 2),
        _colors = Int32List(mesh.verts),
        _keys = Int32List(mesh.triangles),
        _idx = Uint16List(mesh.triangles * 3),
        _uv = Float32List(mesh.verts * 2) {
    setSkin(skin);
  }

  final DanceMesh mesh;
  // per position: skinned, placed, projected, lit; per corner: what is drawn
  final Float32List _local, _localN, _wp, _wn, _ps, _depth, _screen, _uv;
  final Int32List _pc, _colors, _keys;
  final Uint16List _idx;
  ui.Image? _skin;
  ui.ImageShader? _shader;
  final _skinM = Float64List(DanceRigLimits.bones * 12);
  final _worldM = Float64List(DanceRigLimits.bones * 12);

  void setSkin(ui.Image skin) {
    if (identical(skin, _skin)) return;
    _skin = skin;
    final w = skin.width.toDouble(), h = skin.height.toDouble();
    for (var i = 0; i < mesh.verts; i++) {
      _uv[i * 2] = mesh.uv[i * 2] * w;
      _uv[i * 2 + 1] = mesh.uv[i * 2 + 1] * h;
    }
    _shader = ui.ImageShader(skin, TileMode.clamp, TileMode.clamp, Float64List.fromList(const [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]));
  }

  /// The body put in [pose] (in the capture's place, before any spot).
  void pose(DanceRig rig, DancePose pose) {
    rig.solve(pose, _worldM);
    rig.skinning(_worldM, _skinM);
    DanceRig.deform(mesh, _skinM, _local, _localN);
    final l = rig.bone('UpperLeg_L') * 12, r = rig.bone('UpperLeg_R') * 12;
    // facing = side × up, side = left hip − right hip
    final sx = _worldM[l + 3] - _worldM[r + 3], sy = _worldM[l + 7] - _worldM[r + 7];
    facing = math.atan2(-sx, sy);
  }

  /// Which way the posed body faces, radians round z from +x (−π/2 is toward −y).
  double facing = -math.pi / 2;

  /// The hips' height of the pose last put, for the camera.
  double get hipsZ => _worldM[11];

  /// The posed body moved to [spot] in the world.
  void place(DanceSpot s) {
    final c = math.cos(s.yaw), sn = math.sin(s.yaw), k = s.scale;
    final n = mesh.positions;
    for (var v = 0; v < n; v++) {
      var x = _local[v * 3], y = _local[v * 3 + 1];
      final z = _local[v * 3 + 2];
      var nx = _localN[v * 3], ny = _localN[v * 3 + 1];
      final nz = _localN[v * 3 + 2];
      if (s.mirror) {
        x = -x;
        nx = -nx;
      }
      _wp[v * 3] = s.x + (c * x - sn * y) * k;
      _wp[v * 3 + 1] = s.y + (sn * x + c * y) * k;
      _wp[v * 3 + 2] = s.lift + z * k;
      _wn[v * 3] = c * nx - sn * ny;
      _wn[v * 3 + 1] = sn * nx + c * ny;
      _wn[v * 3 + 2] = nz;
    }
    _mirrored = s.mirror;
  }

  bool _mirrored = false;

  /// Projects the placed body; flips z first for the mirror under the floor; pushes
  /// out along the normals by [inflate] metres for an outline.
  void _project(DanceCam cam, {bool flipZ = false, double inflate = 0}) {
    final n = mesh.positions;
    final e = cam.eye, f = cam.f, r = cam.right, u = cam.up;
    final fl = cam.focal, cx = cam.cx, cy = cam.cy;
    for (var v = 0; v < n; v++) {
      var x = _wp[v * 3], y = _wp[v * 3 + 1], z = _wp[v * 3 + 2];
      if (inflate != 0) {
        x += _wn[v * 3] * inflate;
        y += _wn[v * 3 + 1] * inflate;
        z += _wn[v * 3 + 2] * inflate;
      }
      if (flipZ) z = -z;
      final dx = x - e.x, dy = y - e.y, dz = z - e.z;
      final d = dx * f.x + dy * f.y + dz * f.z;
      _depth[v] = d;
      final iz = 1 / math.max(d, DanceCam.near);
      _ps[v * 2] = cx + fl * (dx * r.x + dy * r.y + dz * r.z) * iz;
      _ps[v * 2 + 1] = cy - fl * (dx * u.x + dy * u.y + dz * u.z) * iz;
    }
    _expandScreen();
  }

  void _expandScreen() {
    final src = mesh.src;
    for (var i = 0; i < mesh.verts; i++) {
      final p = src[i] * 2;
      _screen[i * 2] = _ps[p];
      _screen[i * 2 + 1] = _ps[p + 1];
    }
  }

  void _expandColors() {
    final src = mesh.src;
    for (var i = 0; i < mesh.verts; i++) {
      _colors[i] = _pc[src[i]];
    }
  }

  void _fill(Color color) {
    final col = _argb(color);
    for (var v = 0; v < mesh.verts; v++) {
      _colors[v] = col;
    }
  }

  /// Front faces (or back faces, [back]) in front of the camera, far to near, into
  /// _idx; returns how many indices.
  int _order({bool back = false, bool sort = true, bool both = false}) {
    final t = mesh.trisAt, s = _ps, d = _depth, out = mesh.tris;
    var flip = _mirrored != back;
    var count = 0;
    var dMax = 0.0;
    for (var i = 0; i < mesh.triangles; i++) {
      final a = t[i * 3], b = t[i * 3 + 1], c = t[i * 3 + 2];
      final da = d[a], db = d[b], dc = d[c];
      if (da < DanceCam.near || db < DanceCam.near || dc < DanceCam.near) continue;
      final ax = s[a * 2], ay = s[a * 2 + 1];
      final cross = (s[b * 2] - ax) * (s[c * 2 + 1] - ay) - (s[b * 2 + 1] - ay) * (s[c * 2] - ax);
      // Screen y runs down, so a face toward us winds clockwise there.
      if (!both && (cross > 0) != flip) continue;
      final depth = da + db + dc;
      if (depth > dMax) dMax = depth;
      _keys[count++] = i;
      if (sort) _depthOf[i] = depth;
    }
    if (sort && count > 1) {
      // A counting sort on the depth in 4096 steps over this body, far first:
      // linear, where a comparison sort of a few thousand faces is the frame's cost.
      const steps = 4096;
      final k = (steps - 1) / (dMax + 1e-6);
      final counts = _counts..fillRange(0, steps + 1, 0);
      for (var j = 0; j < count; j++) {
        final q = steps - 1 - (_depthOf[_keys[j]] * k).toInt().clamp(0, steps - 1);
        _bucket[j] = q;
        counts[q + 1]++;
      }
      for (var q = 0; q < steps; q++) {
        counts[q + 1] += counts[q];
      }
      for (var j = 0; j < count; j++) {
        _sorted[counts[_bucket[j]]++] = _keys[j];
      }
      _keys.setRange(0, count, _sorted);
    }
    for (var j = 0; j < count; j++) {
      final i = _keys[j];
      _idx[j * 3] = out[i * 3];
      _idx[j * 3 + 1] = out[i * 3 + 1];
      _idx[j * 3 + 2] = out[i * 3 + 2];
    }
    return count * 3;
  }

  late final Float32List _depthOf = Float32List(mesh.triangles);
  late final Int32List _bucket = Int32List(mesh.triangles), _sorted = Int32List(mesh.triangles);
  final _counts = Int32List(4097);

  /// Set by the caller for a frame: draw what this body drew last frame, as it was,
  /// without working any of it out again — a dancer at the back moved every other
  /// frame, the camera being still. Each pass (draw, outline, shadow) replays its own.
  bool hold = false;
  int _pass = 0;
  final _kept = <(ui.Vertices, BlendMode, Paint)?>[];

  /// The start of this body's passes for a frame.
  void begin() => _pass = 0;

  bool _replay(Canvas c) {
    if (!hold || _pass >= _kept.length) return false;
    final kept = _kept[_pass++];
    if (kept != null) c.drawVertices(kept.$1, kept.$2, kept.$3);
    return true;
  }

  void _keep((ui.Vertices, BlendMode, Paint)? v) {
    final k = _pass++;
    while (_kept.length <= k) {
      _kept.add(null);
    }
    _kept[k]?.$1.dispose();
    _kept[k] = v;
  }

  void _emit(Canvas c, ui.Vertices v, BlendMode mode, Paint paint) {
    c.drawVertices(v, mode, paint);
    _keep((v, mode, paint));
  }

  /// Lets go of what it kept for replaying.
  void dispose() {
    for (final k in _kept) {
      k?.$1.dispose();
    }
    _kept.clear();
  }

  /// The placed body, lit by [look], seen by [cam]. A textured body's rim is a glow
  /// behind its silhouette (an outline added before it), so the rim never shows
  /// through the body; a flat one's is in its own colours.
  ///
  /// [twoSided] draws the inside faces too, where the scan is open (the wide
  /// trousers' gaps) — for a silhouette or a clay figure, which would show holes.
  void draw(Canvas c, DanceCam cam, DanceLook3 look, {bool underFloor = false, bool twoSided = false, BlendMode blend = BlendMode.srcOver}) {
    final textured = look.textured && look.flat == null && _shader != null;
    if (textured && look.rimK > 0.01 && !underFloor) {
      outline(c, cam, 0.009, look.rim.withValues(alpha: 0.6 * look.rimK.clamp(0.0, 1.0)), blend: BlendMode.plus);
    }
    if (_replay(c)) return;
    _project(cam, flipZ: underFloor);
    final n = _order(back: underFloor, both: twoSided);
    if (n == 0) return _keep(null);
    _light(cam, look, flipZ: underFloor, rimIn: !textured);
    _expandColors();
    final idx = Uint16List.sublistView(_idx, 0, n);
    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..blendMode = blend;
    if (textured) {
      paint.shader = _shader;
      _emit(c, ui.Vertices.raw(ui.VertexMode.triangles, _screen, textureCoordinates: _uv, colors: _colors, indices: idx), BlendMode.modulate, paint);
    } else {
      _emit(c, ui.Vertices.raw(ui.VertexMode.triangles, _screen, colors: _colors, indices: idx), BlendMode.dst, paint);
    }
  }

  /// The ink line or the neon tube round the body: its back faces pushed out by
  /// [width] metres, in [color]. Drawn before the body.
  void outline(Canvas c, DanceCam cam, double width, Color color, {BlendMode blend = BlendMode.srcOver}) {
    if (_replay(c)) return;
    _project(cam, inflate: width);
    final n = _order(back: true, sort: false);
    if (n == 0) return _keep(null);
    _fill(color);
    _emit(c, ui.Vertices.raw(ui.VertexMode.triangles, _screen, colors: _colors, indices: Uint16List.sublistView(_idx, 0, n)), BlendMode.dst,
        Paint()..blendMode = blend);
  }

  /// The body's shadow on the floor (z = 0), the light coming from [toLight].
  void floorShadow(Canvas c, DanceCam cam, V3 toLight, Color color) {
    final l = toLight.unit;
    if (l.z < 0.05) return _keep(null);
    _shadow(c, cam, color, false, V3(l.x / l.z, l.y / l.z, 0), 0);
  }

  /// The body's shadow thrown on the wall y = [wallY] from a lamp at [lamp].
  void wallShadow(Canvas c, DanceCam cam, V3 lamp, double wallY, Color color) => _shadow(c, cam, color, true, lamp, wallY);

  void _shadow(Canvas c, DanceCam cam, Color color, bool wall, V3 l, double wallY) {
    if (_replay(c)) return;
    final n = mesh.positions;
    final e = cam.eye, f = cam.f, r = cam.right, u = cam.up;
    for (var v = 0; v < n; v++) {
      var x = _wp[v * 3], y = _wp[v * 3 + 1], z = _wp[v * 3 + 2];
      if (wall) {
        final dy = y - l.y;
        final t = dy.abs() < 1e-3 ? 1.0 : (wallY - l.y) / dy;
        x = l.x + (x - l.x) * t;
        z = l.z + (z - l.z) * t;
        y = wallY - 0.002;
      } else {
        // along the light down to the floor (l holds its slope)
        x -= l.x * z;
        y -= l.y * z;
        z = 0.002;
      }
      final dx = x - e.x, dy = y - e.y, dz = z - e.z;
      final d = dx * f.x + dy * f.y + dz * f.z;
      _depth[v] = d;
      final iz = 1 / math.max(d, DanceCam.near);
      _ps[v * 2] = cam.cx + cam.focal * (dx * r.x + dy * r.y + dz * r.z) * iz;
      _ps[v * 2 + 1] = cam.cy - cam.focal * (dx * u.x + dy * u.y + dz * u.z) * iz;
    }
    // Every face, both ways round, by position (no skin to carry); one colour,
    // darkening, so the overlaps agree.
    final t = mesh.trisAt;
    var k = 0;
    for (var i = 0; i < mesh.triangles; i++) {
      final a = t[i * 3], b = t[i * 3 + 1], cc = t[i * 3 + 2];
      if (_depth[a] < DanceCam.near || _depth[b] < DanceCam.near || _depth[cc] < DanceCam.near) continue;
      _idx[k++] = a;
      _idx[k++] = b;
      _idx[k++] = cc;
    }
    if (k == 0) return _keep(null);
    final col = _argb(color);
    for (var v = 0; v < n; v++) {
      _pc[v] = col;
    }
    _emit(c, ui.Vertices.raw(ui.VertexMode.triangles, _ps, colors: _pc, indices: Uint16List.sublistView(_idx, 0, k)), BlendMode.dst,
        Paint()..blendMode = BlendMode.darken);
  }

  /// Porcelain: each position's colour from its normal as the camera sees it — a
  /// wrapped key from above left, warm, falling to [DanceLook3.fill] in the
  /// shadows, a soft highlight, the rim at the edges — times [DanceLook3.dim].
  void _matcap(DanceCam cam, DanceLook3 look, {bool flipZ = false}) {
    final n = mesh.positions;
    final r = cam.right, u = cam.up, f = cam.f;
    const lx = -0.48, ly = 0.62, lz = 0.62; // toward the key, camera space (z toward the eye)
    final hx = lx, hy = ly, hz = lz + 1.0;
    final hl = 1 / math.sqrt(hx * hx + hy * hy + hz * hz);
    final kc = look.keyColor, sc = look.fill, rc = look.rim;
    final dim = look.dim, rimK = look.rimK;
    final a = (look.alpha.clamp(0.0, 1.0) * 255).round();
    for (var v = 0; v < n; v++) {
      final nx = _wn[v * 3], ny = _wn[v * 3 + 1];
      final nz = flipZ ? -_wn[v * 3 + 2] : _wn[v * 3 + 2];
      final vx = nx * r.x + ny * r.y + nz * r.z, vy = nx * u.x + ny * u.y + nz * u.z, vz = -(nx * f.x + ny * f.y + nz * f.z);
      var d = 0.5 + 0.5 * (vx * lx + vy * ly + vz * lz);
      d = d * d * (3 - 2 * d);
      d *= d;
      var sp = (vx * hx + vy * hy + vz * hz) * hl;
      sp = sp <= 0 ? 0 : math.pow(sp, 36).toDouble() * 0.22;
      var rim = 1 - vz.abs();
      rim = rim * rim * rim * rimK;
      final rr = (sc.r + (kc.r - sc.r) * d + sp + rc.r * rim) * dim;
      final gg = (sc.g + (kc.g - sc.g) * d + sp + rc.g * rim) * dim;
      final bb = (sc.b + (kc.b - sc.b) * d + sp + rc.b * rim) * dim;
      _pc[v] = (a << 24) | (_c(rr) << 16) | (_c(gg) << 8) | _c(bb);
    }
  }

  /// Vertex colours for [look], the rim in them where [rimIn].
  void _light(DanceCam cam, DanceLook3 look, {bool flipZ = false, bool rimIn = true}) {
    final n = mesh.positions;
    final kd = look.key.unit;
    final kr = look.keyColor.r, kg = look.keyColor.g, kb = look.keyColor.b;
    final fr = look.fill.r, fg = look.fill.g, fb = look.fill.b;
    final rr = look.rim.r, rg = look.rim.g, rb = look.rim.b;
    final flat = look.flat;
    final rimOn = rimIn && look.rimK > 0.001;
    final a = (look.alpha.clamp(0.0, 1.0) * 255).round();
    final e = cam.eye;
    final toon = look.toon;
    if (look.matcap) return _matcap(cam, look, flipZ: flipZ);
    for (var v = 0; v < n; v++) {
      final nx = _wn[v * 3], ny = _wn[v * 3 + 1];
      final nz = flipZ ? -_wn[v * 3 + 2] : _wn[v * 3 + 2];
      var diff = nx * kd.x + ny * kd.y + nz * kd.z;
      if (diff < 0) diff = 0;
      if (toon > 0) diff = (diff * toon).ceilToDouble() / toon;
      // the fill from the other side and below, half wrapped
      var fill = 0.5 - 0.5 * (nx * kd.x + ny * kd.y) * 0.8 - 0.2 * nz;
      if (fill < 0) fill = 0;
      final kk = look.keyK * diff, ff = look.fillK * fill, am = look.ambient;
      var r = (am + kk * kr + ff * fr) * look.dim, g = (am + kk * kg + ff * fg) * look.dim, b = (am + kk * kb + ff * fb) * look.dim;
      if (flat != null) {
        // A flat colour lit only a little: a cut-out, a silhouette.
        final k = look.shadeFlat && flat.computeLuminance() > 0.02 ? (0.75 + 0.35 * diff) : 1.0;
        r = flat.r * k * look.dim;
        g = flat.g * k * look.dim;
        b = flat.b * k * look.dim;
      }
      if (rimOn) {
        // Fresnel: grazing the eye's line, the rim lights.
        final px = _wp[v * 3] - e.x, py = _wp[v * 3 + 1] - e.y, pz = (flipZ ? -_wp[v * 3 + 2] : _wp[v * 3 + 2]) - e.z;
        final il = 1 / math.sqrt(px * px + py * py + pz * pz + 1e-9);
        var fr0 = 1 - (-(nx * px + ny * py + nz * pz) * il).abs();
        if (fr0 < 0) fr0 = 0;
        var k = math.pow(fr0, look.rimPower).toDouble() * look.rimK * look.dim;
        if (toon > 0) k = k > 0.35 ? look.rimK : 0;
        r += rr * k;
        g += rg * k;
        b += rb * k;
      }
      _pc[v] = (a << 24) | (_c(r) << 16) | (_c(g) << 8) | _c(b);
    }
  }
}

/// Draws [v] and lets it go at once: the picture keeps its own hold on the data, and
/// a few dozen of these a frame left to the collector are native memory piling up
/// between its rounds — and long rounds when it comes.
void _vertices(Canvas c, ui.Vertices v, BlendMode mode, Paint paint) {
  c.drawVertices(v, mode, paint);
  v.dispose();
}

int _c(double x) => x <= 0 ? 0 : (x >= 1 ? 255 : (x * 255).round());
int _argb(Color c) => ((c.a * 255).round() << 24) | ((c.r * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.b * 255).round();

/// The skeleton's size, for scratch.
class DanceRigLimits {
  static const bones = 32;
}

/// Floor tiles, beams, a void's grid: flat quads in the world, drawn through the
/// camera with colours per corner, in one draw. A quad behind the camera is dropped.
class DanceQuads {
  final _pos = <double>[];
  final _col = <int>[];

  void quad(DanceCam cam, V3 a, V3 b, V3 c, V3 d, Color ca, [Color? cb, Color? cc, Color? cd]) {
    final pa = cam.project(a), pb = cam.project(b), pc = cam.project(c), pd = cam.project(d);
    if (pa.$3 < DanceCam.near || pb.$3 < DanceCam.near || pc.$3 < DanceCam.near || pd.$3 < DanceCam.near) return;
    final ka = _argb(ca), kb = _argb(cb ?? ca), kc = _argb(cc ?? ca), kd = _argb(cd ?? ca);
    _pos.addAll([pa.$1, pa.$2, pb.$1, pb.$2, pc.$1, pc.$2, pa.$1, pa.$2, pc.$1, pc.$2, pd.$1, pd.$2]);
    _col.addAll([ka, kb, kc, ka, kc, kd]);
  }

  /// A triangle already on the screen.
  void tri(Offset a, Offset b, Offset c, Color ca, [Color? cb, Color? cc]) {
    _pos.addAll([a.dx, a.dy, b.dx, b.dy, c.dx, c.dy]);
    _col.addAll([_argb(ca), _argb(cb ?? ca), _argb(cc ?? ca)]);
  }

  bool get isEmpty => _pos.isEmpty;

  void draw(Canvas c, {BlendMode blend = BlendMode.srcOver}) {
    if (_pos.isEmpty) return;
    _vertices(c, ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(_pos), colors: Int32List.fromList(_col)), BlendMode.dst,
        Paint()..blendMode = blend);
    _pos.clear();
    _col.clear();
  }
}
