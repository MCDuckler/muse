// Paintings kept as pictures of themselves, for the renderer's sake.
//
// Impeller draws the whole frame again every frame — it has no raster cache, so a
// painting that did not change is drawn from its commands like one that did — and
// on its OpenGL ES backend (Linux, and Windows through ANGLE) every gradient fill
// costs three render passes of its own and a blur several more. The booth drew
// fifty-nine passes a frame: forty-four of them a lamp's sheen on the two records,
// which never moves, and the tonearms, which creep a degree a minute
// (integration_test/booth_perf_test.dart, PERF_PARTS). Drawn once into an image and
// the image drawn after, each is one textured quad and no pass at all; the booth
// draws three.
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// One painting, drawn into an image the first time and again only when its key
/// changes.
class Baked {
  ui.Image? _image;
  Object? _key;
  double? _angle;

  static double get _dpr => ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;

  void _bake(Size size, Object key, void Function(Canvas c) paint) {
    final dpr = _dpr;
    final r = ui.PictureRecorder();
    final c = Canvas(r)..scale(dpr);
    paint(c);
    _image?.dispose();
    _image = r.endRecording().toImageSync((size.width * dpr).ceil(), (size.height * dpr).ceil());
    _key = key;
  }

  void _put(Canvas canvas, Size size) {
    final img = _image!;
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, img.width / _dpr, img.height / _dpr), Paint()..filterQuality = FilterQuality.low);
  }

  /// [paint] (into a canvas the size of [size]) as an image, made again when [key]
  /// changes.
  void draw(Canvas canvas, Size size, Object key, void Function(Canvas c) paint) {
    final k = (key, size, _dpr);
    if (_image == null || _key != k) _bake(size, k, paint);
    _put(canvas, size);
  }

  /// [paint] at [angle], for something that turns about [about]: made again when
  /// [key] changes or the angle has gone more than [slack] from the one it was made
  /// at, and turned by the difference in between — which is exact for the outline
  /// and leaves only the light on it (and its shadow) a fraction of a degree behind.
  void drawTurning(Canvas canvas, Size size, Object key,
      {required double angle, required Offset about, double slack = 0.017, required void Function(Canvas c, double angle) paint}) {
    final k = (key, size, _dpr);
    final had = _angle;
    if (_image == null || _key != k || had == null || (angle - had).abs() > slack) {
      _bake(size, k, (c) => paint(c, angle));
      _angle = angle;
    }
    final by = angle - _angle!;
    if (by == 0) {
      _put(canvas, size);
      return;
    }
    canvas.save();
    canvas.translate(about.dx, about.dy);
    canvas.rotate(by);
    canvas.translate(-about.dx, -about.dy);
    _put(canvas, size);
    canvas.restore();
  }

  void dispose() {
    _image?.dispose();
    _image = null;
    _key = null;
  }
}

/// Bakeds by slot, the least recently used let go past [keep]: for painters made
/// afresh every frame, which have nowhere of their own to keep one.
class BakedShelf {
  BakedShelf(this.keep);
  final int keep;
  final _bySlot = <Object, Baked>{};

  Baked of(Object slot) {
    final had = _bySlot.remove(slot);
    final b = had ?? Baked();
    _bySlot[slot] = b;
    while (_bySlot.length > keep) {
      _bySlot.remove(_bySlot.keys.first)!.dispose();
    }
    return b;
  }
}
