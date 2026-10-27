// The flock's pigeon: the shipped asset reads into three levels of detail with wings
// on both sides and a body; a batch of hundreds draws (into a picture) with every
// number a number; and what a frame of them costs.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/show/show_dance_draw.dart';
import 'package:muse/src/ui/show/show_flock_bird.dart';
import 'package:muse/src/ui/show/show_flock_surface.dart';

BirdMesh shipped() {
  final j = jsonDecode(File('assets/show/flock/pigeon/pigeon.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = Uint8List.fromList(File('assets/show/flock/pigeon/pigeon.bin').readAsBytesSync());
  return BirdMesh.parse(j, ByteData.sublistView(bytes));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final mesh = shipped();

  test('the shipped pigeon: three levels, a body and two wings each, a pigeon\'s size', () {
    expect(mesh.lods, hasLength(3));
    expect(mesh.near.triangles, greaterThan(mesh.lods[1].triangles));
    expect(mesh.lods[1].triangles, greaterThan(mesh.far.triangles));
    expect(mesh.wingspan, inInclusiveRange(0.55, 0.8));
    for (final l in mesh.lods) {
      expect(l.tris.reduce(math.max), lessThan(l.verts), reason: l.name);
      expect(l.bodyTris, isNotEmpty, reason: l.name);
      expect(l.leftTris, isNotEmpty, reason: l.name);
      expect(l.rightTris, isNotEmpty, reason: l.name);
      expect(l.bodyTris.length + l.leftTris.length + l.rightTris.length, l.tris.length, reason: l.name);
      var lo = 9.0, hi = -9.0, tipL = 0.0, tipR = 0.0;
      for (var v = 0; v < l.verts; v++) {
        expect(l.pos[v * 3].isFinite && l.nrm[v * 3].isFinite && l.uv[v * 2].isFinite, isTrue);
        lo = math.min(lo, l.pos[v * 3]);
        hi = math.max(hi, l.pos[v * 3]);
        if (l.wing[v] < 0) tipL = math.min(tipL, l.pos[v * 3 + 1]);
        if (l.wing[v] > 0) tipR = math.max(tipR, l.pos[v * 3 + 1]);
      }
      // the body about a pigeon's length along x; the wings out to the span either side
      expect(hi - lo, inInclusiveRange(0.3, 0.42), reason: '${l.name} length');
      expect(tipR, inInclusiveRange(0.26, 0.4), reason: '${l.name} right tip');
      expect(-tipL, inInclusiveRange(0.26, 0.4), reason: '${l.name} left tip');
      expect(File('assets/show/flock/pigeon/skin.webp').existsSync(), isTrue);
    }
    expect(mesh.pick(120, 0), mesh.near);
    expect(mesh.pick(120, 40), mesh.lods[1]);
    expect(mesh.pick(10, 0), mesh.far);
  });

  test('a flock of pigeons draws, in every shade, the wings flapping; and the cost of a frame', () {
    final skin = (() {
      final r = ui.PictureRecorder();
      Canvas(r).drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = Colors.white);
      final p = r.endRecording();
      final img = p.toImageSync(4, 4);
      p.dispose();
      return img;
    })();
    final batch = BirdBatch()..setSkin(skin);
    final cam = DanceCam(eye: const V3(0, -10, 3), target: const V3(0, 1, 3), size: const Size(1280, 720));
    final rng = math.Random(1);
    const n = 400;
    final xs = [for (var i = 0; i < n; i++) (rng.nextDouble() - 0.5) * 8];
    final ys = [for (var i = 0; i < n; i++) (rng.nextDouble() - 0.5) * 4 + 1];
    final zs = [for (var i = 0; i < n; i++) rng.nextDouble() * 4 + 1];
    void frame(BirdShade shade, {bool textured = true}) {
      final r = ui.PictureRecorder();
      final c = CanvasFlockSurface(Canvas(r));
      batch.begin();
      for (var i = 0; i < n; i++) {
        final lod = mesh.pick(60, i);
        batch.bird(c, mesh, lod, cam, xs[i], ys[i], zs[i], 1, 0, 0, 1, math.sin(i * 0.3) * 0.6, shade, const BirdLight(rimK: 0.5), textured: textured);
      }
      batch.flush(c);
      r.endRecording().dispose();
    }

    for (final shade in BirdShade.values) {
      frame(shade);
      expect(batch.birdsDrawn, n);
      expect(batch.vertsDrawn, greaterThan(n * mesh.far.verts));
    }
    // warm, then time
    for (var k = 0; k < 10; k++) {
      frame(BirdShade.lit);
    }
    final sw = Stopwatch()..start();
    for (var k = 0; k < 30; k++) {
      frame(BirdShade.lit);
    }
    sw.stop();
    // ignore: avoid_print
    print('BIRDS ${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms a frame for $n pigeons, ${batch.vertsDrawn} vertices (JIT)');
    expect(sw.elapsedMilliseconds / 30, lessThan(40));
    // a stamp keeps the shapes
    final r = ui.PictureRecorder();
    final c = CanvasFlockSurface(Canvas(r));
    batch.begin();
    batch.beginStamp();
    for (var i = 0; i < 50; i++) {
      batch.bird(c, mesh, mesh.far, cam, xs[i], ys[i], zs[i], 1, 0, 0, 1, 0.3, BirdShade.flat, const BirdLight());
    }
    final stamp = batch.endStamp(c);
    stamp.draw(c, Colors.white);
    r.endRecording().dispose();
    skin.dispose();
  });
}
