// What the murmuration draws on (show_flock.dart): a canvas on the Flutter stage, the
// dancers' command list on the native one (show_dance_surface.dart, dance.h) — the
// same few things either way: a fill, coloured triangles (indexed, textured by the
// pigeon's skin), soft sprites, lines, round dots.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'show_dance_surface.dart';

abstract class FlockSurface {
  void fill(Rect r, Color color);

  /// Triangles: x, y per corner, an ARGB colour per corner; [indices] into the
  /// corners where given. Textured by [texture] where given — [uv] in its pixels, the
  /// colour multiplying it.
  void vertices(Float32List pos, Int32List argb, {Uint16List? indices, ui.Image? texture, Float32List? uv, BlendMode blend = BlendMode.srcOver});

  /// [sprite]'s [rects], each placed by its [at] and multiplied by its colour.
  void sprites(ui.Image sprite, List<RSTransform> at, List<Rect> rects, List<Color> colors, {BlendMode blend = BlendMode.plus});

  /// Lines — x0, y0, x1, y1 each in [seg] — [width] across, in one colour.
  void lines(Float32List seg, double width, Color color, {BlendMode blend = BlendMode.srcOver});

  /// Round dots [width] across at x, y.
  void dots(Float32List xy, double width, Color color, {BlendMode blend = BlendMode.plus});
}

/// The Flutter stage's.
class CanvasFlockSurface implements FlockSurface {
  CanvasFlockSurface(this.c);
  final Canvas c;

  static final _shaders = Expando<ui.ImageShader>();

  @override
  void fill(Rect r, Color color) => c.drawRect(r, Paint()..color = color);

  @override
  void vertices(Float32List pos, Int32List argb, {Uint16List? indices, ui.Image? texture, Float32List? uv, BlendMode blend = BlendMode.srcOver}) {
    final textured = texture != null && uv != null;
    final v = ui.Vertices.raw(ui.VertexMode.triangles, pos, textureCoordinates: textured ? uv : null, colors: argb, indices: indices);
    final paint = Paint()
      ..blendMode = blend
      ..filterQuality = FilterQuality.low;
    if (textured) {
      paint.shader = _shaders[texture] ??=
          ui.ImageShader(texture, TileMode.clamp, TileMode.clamp, Float64List.fromList(const [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]));
    }
    c.drawVertices(v, textured ? BlendMode.modulate : BlendMode.dst, paint);
    v.dispose();
  }

  @override
  void sprites(ui.Image sprite, List<RSTransform> at, List<Rect> rects, List<Color> colors, {BlendMode blend = BlendMode.plus}) =>
      c.drawAtlas(sprite, at, rects, colors, BlendMode.modulate, null, Paint()..blendMode = blend);

  @override
  void lines(Float32List seg, double width, Color color, {BlendMode blend = BlendMode.srcOver}) => c.drawRawPoints(
      ui.PointMode.lines,
      seg,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..blendMode = blend);

  @override
  void dots(Float32List xy, double width, Color color, {BlendMode blend = BlendMode.plus}) => c.drawRawPoints(
      ui.PointMode.points,
      xy,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..blendMode = blend);
}

/// The native stage's: the dancers' command list ([d]), the pictures it draws with
/// (the skin, the sprite, the finish's glyphs) up to the stage once each, by number
/// (`mesh.<n>`), through [upload]. A picture not up yet: its triangles in their
/// colours alone for the frame or two it takes.
class NativeFlockSurface implements FlockSurface {
  NativeFlockSurface(this.d, this.upload);
  final NativeDanceSurface d;
  final void Function(String name, int w, int h, Uint8List rgba) upload;

  static final _ids = Expando<int>();
  static final _up = <int>{};
  static var _next = 0;

  /// The stage's number for [img], once it is up there (null until then).
  int? texture(ui.Image img) {
    var id = _ids[img];
    if (id == null) {
      final n = id = _next++;
      _ids[img] = n;
      final up = upload;
      // Straight colour: the stage's blend is by the alpha, as the canvas's modulate is.
      unawaited(img.toByteData(format: ui.ImageByteFormat.rawStraightRgba).then((b) {
        if (b == null) return;
        up('mesh.$n', img.width, img.height, b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
        _up.add(n);
      }, onError: (Object _) {}));
    }
    return _up.contains(id) ? id : null;
  }

  @override
  void fill(Rect r, Color color) => d.fill(r, color);

  @override
  void vertices(Float32List pos, Int32List argb, {Uint16List? indices, ui.Image? texture, Float32List? uv, BlendMode blend = BlendMode.srcOver}) {
    final id = texture == null || uv == null ? null : this.texture(texture);
    if (id == null) {
      d.mesh(pos, argb, indices: indices, blend: blend);
      return;
    }
    final w = texture!.width.toDouble(), h = texture.height.toDouble();
    final n = argb.length;
    final st = Float32List(n * 2);
    for (var i = 0; i < n; i++) {
      st[i * 2] = uv![i * 2] / w;
      st[i * 2 + 1] = uv[i * 2 + 1] / h;
    }
    d.mesh(pos, argb, indices: indices, texture: id, uv: st, blend: blend);
  }

  @override
  void sprites(ui.Image sprite, List<RSTransform> at, List<Rect> rects, List<Color> colors, {BlendMode blend = BlendMode.plus}) {
    final id = texture(sprite);
    if (id == null || at.isEmpty) return;
    final n = at.length;
    final pos = Float32List(n * 8), st = Float32List(n * 8), argb = Int32List(n * 4), idx = Uint16List(n * 6);
    final iw = sprite.width.toDouble(), ih = sprite.height.toDouble();
    for (var k = 0; k < n; k++) {
      final t = at[k], r = rects[k];
      final corners = [(0.0, 0.0), (r.width, 0.0), (r.width, r.height), (0.0, r.height)];
      for (var q = 0; q < 4; q++) {
        final (x, y) = corners[q];
        pos[k * 8 + q * 2] = t.scos * x - t.ssin * y + t.tx;
        pos[k * 8 + q * 2 + 1] = t.ssin * x + t.scos * y + t.ty;
        st[k * 8 + q * 2] = (r.left + x) / iw;
        st[k * 8 + q * 2 + 1] = (r.top + y) / ih;
        argb[k * 4 + q] = colors[k].toARGB32();
      }
      // Counted in sixteen bits from each part's first corner (the parts below).
      final b = (k * 4) & 0xffff;
      idx.setAll(k * 6, [b, b + 1, b + 2, b, b + 2, b + 3]);
    }
    // In parts of at most 16384 sprites: a part's corners fit sixteen bits.
    const most = 16384;
    for (var a = 0; a < n; a += most) {
      final e = a + most < n ? a + most : n;
      d.mesh(Float32List.sublistView(pos, a * 8, e * 8), Int32List.sublistView(argb, a * 4, e * 4),
          indices: Uint16List.sublistView(idx, a * 6, e * 6), texture: id, uv: Float32List.sublistView(st, a * 8, e * 8), blend: blend);
    }
  }

  @override
  void lines(Float32List seg, double width, Color color, {BlendMode blend = BlendMode.srcOver}) {
    final n = seg.length ~/ 4;
    if (n == 0) return;
    final pos = Float32List(n * 12), col = Int32List(n * 6)..fillRange(0, n * 6, color.toARGB32());
    final hw = width / 2;
    for (var i = 0; i < n; i++) {
      final x0 = seg[i * 4], y0 = seg[i * 4 + 1], x1 = seg[i * 4 + 2], y1 = seg[i * 4 + 3];
      final dx = x1 - x0, dy = y1 - y0, l = math.sqrt(dx * dx + dy * dy);
      if (l < 1e-6) continue; // left at nothing: two triangles of no size
      final nx = -dy / l * hw, ny = dx / l * hw;
      pos.setAll(i * 12, [x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 + nx, y0 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny]);
    }
    d.tris(pos, col, blend: blend);
  }

  @override
  void dots(Float32List xy, double width, Color color, {BlendMode blend = BlendMode.plus}) => d.points(xy, width, color, blend: blend);
}
