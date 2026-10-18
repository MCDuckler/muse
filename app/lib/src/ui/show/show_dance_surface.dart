// What the dancer's stages draw on: a canvas (the Flutter stage, as it always has),
// or a list of commands for the native stage (native/stage/src/dance.h), which draws
// the bodies on the GPU — skinned there, with a depth buffer, lit per pixel — and the
// rest as the triangles the stages make.
//
// The stages (show_dance.dart) draw only these: a filled rectangle, coloured
// triangles already on the picture, round points, a clip, and a body's passes (the
// body, an outline, a shadow on the floor or a wall). So both surfaces draw every
// stage and every rendering the same way.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'show_dance_draw.dart';

abstract class DanceSurface {
  void fill(Rect r, Color color, {BlendMode blend = BlendMode.srcOver});

  /// Triangles on the picture: x, y per corner, and an ARGB colour per corner.
  void tris(Float32List pos, Int32List argb, {BlendMode blend = BlendMode.srcOver});

  /// Round points [width] across at x, y.
  void points(Float32List xy, double width, Color color, {BlendMode blend = BlendMode.plus});

  /// Drawing kept inside [r] from here, or anywhere again (null).
  void clip(Rect? r);

  /// The camera the bodies are seen by from here (a canvas is told it with each body).
  void camera(DanceCam cam);

  void body(DanceBody b, DanceCam cam, DanceLook3 look, {bool underFloor = false, bool twoSided = false, BlendMode blend = BlendMode.srcOver});
  void outline(DanceBody b, DanceCam cam, double width, Color color, {BlendMode blend = BlendMode.srcOver});
  void floorShadow(DanceBody b, DanceCam cam, V3 toLight, Color color);
  void wallShadow(DanceBody b, DanceCam cam, V3 lamp, double wallY, Color color);
}

/// The Flutter stage's: a canvas, the bodies drawn by DanceBody on the CPU.
class CanvasDanceSurface implements DanceSurface {
  CanvasDanceSurface(this.c);
  final Canvas c;
  bool _clipped = false;

  @override
  void fill(Rect r, Color color, {BlendMode blend = BlendMode.srcOver}) => c.drawRect(
      r,
      Paint()
        ..color = color
        ..blendMode = blend);

  @override
  void tris(Float32List pos, Int32List argb, {BlendMode blend = BlendMode.srcOver}) {
    final v = ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: argb);
    c.drawVertices(v, BlendMode.dst, Paint()..blendMode = blend);
    v.dispose();
  }

  @override
  void points(Float32List xy, double width, Color color, {BlendMode blend = BlendMode.plus}) => c.drawRawPoints(
      ui.PointMode.points,
      xy,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..blendMode = blend);

  @override
  void clip(Rect? r) {
    if (_clipped) {
      c.restore();
      _clipped = false;
    }
    if (r != null) {
      c.save();
      c.clipRect(r);
      _clipped = true;
    }
  }

  @override
  void camera(DanceCam cam) {}

  @override
  void body(DanceBody b, DanceCam cam, DanceLook3 look, {bool underFloor = false, bool twoSided = false, BlendMode blend = BlendMode.srcOver}) =>
      b.draw(c, cam, look, underFloor: underFloor, twoSided: twoSided, blend: blend);

  @override
  void outline(DanceBody b, DanceCam cam, double width, Color color, {BlendMode blend = BlendMode.srcOver}) =>
      b.outline(c, cam, width, color, blend: blend);

  @override
  void floorShadow(DanceBody b, DanceCam cam, V3 toLight, Color color) => b.floorShadow(c, cam, toLight, color);

  @override
  void wallShadow(DanceBody b, DanceCam cam, V3 lamp, double wallY, Color color) => b.wallShadow(c, cam, lamp, wallY, color);
}

/// The native stage's: every call a command in a list of floats (dance.h's ops),
/// the bodies as their skinning matrices and spot, posed once a frame each.
class NativeDanceSurface implements DanceSurface {
  /// [meshId] says the native stage's id for a body's mesh (registering it, and its
  /// skin, the first time).
  NativeDanceSurface(this.meshId);
  final int Function(DanceBody body) meshId;

  final _out = <double>[];
  final _slots = <DanceBody, (int, int)>{}; // body → (slot, the version it was posed at)

  static const _fill = 1, _tris = 2, _points = 3, _clip = 4, _camera = 5, _pose = 6, _body = 7, _outline = 8;
  static const _floorShadow = 9, _wallShadow = 10, _post = 11, _fluid = 13;

  static int blendOf(BlendMode b) => switch (b) {
        BlendMode.plus => 1,
        BlendMode.src => 2,
        BlendMode.darken => 3,
        _ => 0,
      };

  void _colour(Color c) => _out.addAll([c.r, c.g, c.b, c.a]);

  /// The camera the stage's 3D is seen by, and the picture's size every 2D position
  /// is in. First, each frame (and again for each viewport of the viewports).
  @override
  void camera(DanceCam cam) => _out.addAll([
        _camera.toDouble(),
        cam.eye.x, cam.eye.y, cam.eye.z,
        cam.target.x, cam.target.y, cam.target.z,
        cam.fov, cam.roll, cam.shift.dx, cam.shift.dy,
        cam.size.width, cam.size.height,
      ]);

  /// The ascii or dither finish (dance_fx.frag) over what is drawn so far.
  void post({required int mode, required double cell, required Color ink, required Color paper, required double tint, required int glyphs,
      required double pop, required Offset popAt, required double time}) {
    _out.addAll([_post.toDouble(), mode.toDouble(), cell, ink.r, ink.g, ink.b, paper.r, paper.g, paper.b, tint, glyphs.toDouble(), pop, popAt.dx, popAt.dy, time]);
  }

  /// A coloured fluid round [bodies] (which hold it back), pushed by [splats] — x, y,
  /// velocity x, y (pixels a second), radius — dyed by [dye]'s three colours; [kick]
  /// a burst, [strength] how much it moves.
  void fluid(List<(double, double, double, double, double)> splats, List<DanceBody> bodies, List<Color> dye, double kick, double strength) {
    final slots = [for (final b in bodies) _slot(b)];
    _out.addAll([_fluid.toDouble(), splats.length.toDouble(), slots.length.toDouble(), kick, strength]);
    for (final c in dye.take(3)) {
      _out.addAll([c.r, c.g, c.b]);
    }
    for (final (x, y, vx, vy, r) in splats) {
      _out.addAll([x, y, vx, vy, r]);
    }
    for (final sl in slots) {
      _out.add(sl.toDouble());
    }
  }

  Float32List finish() => Float32List.fromList(_out);

  @override
  void fill(Rect r, Color color, {BlendMode blend = BlendMode.srcOver}) {
    _out.addAll([_fill.toDouble(), r.left, r.top, r.right, r.bottom]);
    _colour(color);
    _out.add(blendOf(blend).toDouble());
  }

  @override
  void tris(Float32List pos, Int32List argb, {BlendMode blend = BlendMode.srcOver}) {
    final n = argb.length;
    _out.addAll([_tris.toDouble(), n.toDouble(), blendOf(blend).toDouble()]);
    for (var i = 0; i < n; i++) {
      final c = argb[i];
      _out.addAll([pos[i * 2], pos[i * 2 + 1], ((c >> 16) & 0xff) / 255, ((c >> 8) & 0xff) / 255, (c & 0xff) / 255, ((c >> 24) & 0xff) / 255]);
    }
  }

  @override
  void points(Float32List xy, double width, Color color, {BlendMode blend = BlendMode.plus}) {
    _out.addAll([_points.toDouble(), (xy.length ~/ 2).toDouble(), width / 2]);
    _colour(color);
    _out.add(blendOf(blend).toDouble());
    _out.addAll(xy);
  }

  @override
  void clip(Rect? r) => _out.addAll(r == null ? [_clip.toDouble(), -1, -1, -1, -1] : [_clip.toDouble(), r.left, r.top, r.right, r.bottom]);

  /// The body's slot this frame, posed (its skinning and spot sent) the first time it
  /// is drawn, and again if it was posed or placed since.
  int _slot(DanceBody b) {
    final had = _slots[b];
    if (had != null && had.$2 == b.version) return had.$1;
    final slot = had?.$1 ?? _slots.length;
    _slots[b] = (slot, b.version);
    final s = b.spot;
    final bones = b.bones;
    _out.addAll([_pose.toDouble(), slot.toDouble(), meshId(b).toDouble(), bones.toDouble(), s.x, s.y, s.yaw, s.mirror ? 1 : 0, s.scale, s.lift]);
    final m = b.skinMatrices;
    for (var i = 0; i < bones * 12; i++) {
      _out.add(m[i]);
    }
    return slot;
  }

  @override
  void body(DanceBody b, DanceCam cam, DanceLook3 look, {bool underFloor = false, bool twoSided = false, BlendMode blend = BlendMode.srcOver}) {
    final textured = look.textured && look.flat == null && b.hasSkin;
    // As DanceBody.draw: a textured body's rim is a glow behind its silhouette.
    if (textured && look.rimK > 0.01 && !underFloor) {
      outline(b, cam, 0.009, look.rim.withValues(alpha: 0.6 * look.rimK.clamp(0.0, 1.0)), blend: BlendMode.plus);
    }
    final slot = _slot(b);
    final shade = look.chrome ? 3 : (look.flat != null ? 1 : 0);
    final flat = look.flat ?? const Color(0x00000000);
    final k = look.key;
    _out.addAll([
      _body.toDouble(), slot.toDouble(), shade.toDouble(), underFloor ? 1 : 0, twoSided ? 1 : 0, blendOf(blend).toDouble(),
      k.x, k.y, k.z, look.keyColor.r, look.keyColor.g, look.keyColor.b, look.keyK,
      look.fill.r, look.fill.g, look.fill.b, look.fillK, look.ambient,
      look.rim.r, look.rim.g, look.rim.b, textured ? 0 : look.rimK, look.rimPower,
      flat.r, flat.g, flat.b, flat.a, look.shadeFlat ? 1 : 0, look.toon.toDouble(), look.alpha, look.dim, textured ? 1 : 0,
    ]);
  }

  @override
  void outline(DanceBody b, DanceCam cam, double width, Color color, {BlendMode blend = BlendMode.srcOver}) {
    final slot = _slot(b);
    _out.addAll([_outline.toDouble(), slot.toDouble(), width]);
    _colour(color);
    _out.add(blendOf(blend).toDouble());
  }

  @override
  void floorShadow(DanceBody b, DanceCam cam, V3 toLight, Color color) {
    final slot = _slot(b);
    final l = toLight.unit;
    _out.addAll([_floorShadow.toDouble(), slot.toDouble(), l.x, l.y, l.z, color.r, color.g, color.b]);
  }

  @override
  void wallShadow(DanceBody b, DanceCam cam, V3 lamp, double wallY, Color color) {
    final slot = _slot(b);
    _out.addAll([_wallShadow.toDouble(), slot.toDouble(), lamp.x, lamp.y, lamp.z, wallY, color.r, color.g, color.b]);
  }
}
