import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'arm_geometry.dart';

/// The classic deck: a matte black S-arm on a charcoal plinth.
///
/// Drawn after a photograph of one seen from straight above: a round tube that
/// leaves its bearing straight and curves into the headshell at the far end; a flat
/// headshell with a finger lift, two slots and three screws; a boxy bearing block on
/// the post with a long counterweight behind it; and a slab of a plinth under all of
/// it, which the record overlaps at its edge.
///
/// Matte, not polished: the light is a soft band along the top of each round part and
/// a darker underside, and the shadow falls down and to the right, soft, and further
/// the higher the arm is lifted. Its colours are its own rather than the palette's —
/// it is a black object in every theme, the way a real one is.
///
/// Two painters because it is two things at two depths. The plinth sits *under* the
/// record, so it is painted before it; the arm lies *on* the record, so after.

// The materials.
const _tube = Color(0xFF17171A);
const _tubeUnder = Color(0xFF09090B);
const _shell = Color(0xFF2C2D31);
const _shellDark = Color(0xFF1C1D20);
const _hole = Color(0xFF0A0A0C);
const _screwLit = Color(0xFF7A7D84);
const _block = Color(0xFF26272B);
const _blockDark = Color(0xFF121214);
const _weight = Color(0xFF3B3D42);
const _weightLit = Color(0xFF6C6F76);
const _weightDark = Color(0xFF0F1012);
const _plinth = Color(0xFF2A2B2F);
const _plinthDark = Color(0xFF1B1C1F);
const _silver = Color(0xFFC3C7CE);
const _silverDark = Color(0xFF7B7F87);

Color _dim(Color c, double dim) => c.withValues(alpha: c.a * dim);

/// The slab the arm is mounted on. Painted under the record.
class ClassicPlinthPainter extends CustomPainter {
  ClassicPlinthPainter({
    required this.radius,
    required this.drop,
    required this.label,
    this.dim = 1,
  });

  final double radius;
  final double drop;
  final double label;
  final double dim;

  /// The plinth's outline, in the box's coordinates. Shared with the arm painter so
  /// the cue lever lands on the slab.
  static RRect slab(ArmGeometry g) {
    final r = g.radius;
    final p = g.pivot;
    return RRect.fromRectAndRadius(
      Rect.fromLTRB(p.dx - r * 0.24, p.dy - r * 0.26, p.dx + r * 0.36, p.dy + r * 0.30),
      Radius.circular(r * 0.05),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = ArmGeometry.of(size, radius: radius, drop: drop, label: label);
    final r = g.radius;
    final s = slab(g);

    // Its shadow on whatever it stands on: soft, down and to the right.
    canvas.drawRRect(
      s.shift(Offset(r * 0.02, r * 0.035)),
      Paint()
        ..color = _dim(const Color(0x59000000), dim)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.03),
    );
    // The top face: lit a little from the top left, falling off to the far corner.
    canvas.drawRRect(
      s,
      Paint()
        ..shader = ui.Gradient.linear(
          s.outerRect.topLeft,
          s.outerRect.bottomRight,
          [_dim(_plinth, dim), _dim(_plinthDark, dim)],
        ),
    );
    // The machined edge catching the light along the top and the left.
    canvas.drawRRect(
      s.deflate(r * 0.004),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.006
        ..shader = ui.Gradient.linear(
          s.outerRect.topLeft,
          s.outerRect.bottomRight,
          [_dim(const Color(0x33FFFFFF), dim), _dim(const Color(0x00FFFFFF), dim)],
          const [0.0, 0.55],
        ),
    );
    // The recessed mounting board the bearing stands in.
    final seat = RRect.fromRectAndRadius(
      Rect.fromCircle(center: g.pivot, radius: r * 0.13),
      Radius.circular(r * 0.03),
    );
    canvas.drawRRect(seat, Paint()..color = _dim(const Color(0xFF151618), dim));
    canvas.drawRRect(
      seat,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.004
        ..color = _dim(const Color(0x1FFFFFFF), dim),
    );

    // The cue lever: a small black bar on a round boss, pointing down the slab.
    final boss = g.pivot + Offset(r * 0.20, r * 0.16);
    canvas.drawCircle(boss, r * 0.028, Paint()..color = _dim(_blockDark, dim));
    canvas.drawCircle(
      boss,
      r * 0.028,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.004
        ..color = _dim(const Color(0x40FFFFFF), dim),
    );
    final leverEnd = boss + Offset(-r * 0.03, r * 0.10);
    canvas.drawLine(
      boss,
      leverEnd,
      Paint()
        ..color = _dim(_tube, dim)
        ..strokeWidth = r * 0.016
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(leverEnd, r * 0.016, Paint()..color = _dim(_tubeUnder, dim));
  }

  @override
  bool shouldRepaint(ClassicPlinthPainter old) =>
      old.radius != radius || old.drop != drop || old.label != label || old.dim != dim;
}

/// The arm itself, at [angle], lifted [lift] (0 resting, 1 held up by a finger).
void paintClassicArm(
  Canvas canvas,
  ArmGeometry g, {
  required double angle,
  double lift = 0,
  double dim = 1,
}) {
  final r = g.radius;
  final length = g.length;

  // Sizes, as fractions of the record: read off the photograph it is drawn after.
  final tubeWide = r * 0.074;
  final tubeNarrow = r * 0.062;
  final headLength = r * 0.36;
  final headWidth = r * 0.15;
  final blockLong = r * 0.21;
  final blockWide = r * 0.17;

  // The arm's own frame: the post at the origin, the needle at (length, 0).
  //
  // The headshell is not in line with the tube. It is turned away from the middle of
  // the record — which is what puts the cartridge across the groove, and what gives a
  // real S-arm its curve — so the tube bends to meet it.
  final middleLocal = _toLocal(g.middle, g.pivot, angle);
  final away = middleLocal.dy >= 0 ? -1.0 : 1.0;
  const offsetAngle = 0.46;                       // about 26 degrees
  final forward = Offset(math.cos(away * offsetAngle), math.sin(away * offsetAngle));
  final needle = Offset(length, 0);
  final headCentre = needle - forward * (headLength * 0.10);
  final headRear = headCentre - forward * (headLength * 0.50);
  final collarEnd = headRear - forward * (r * 0.030);

  final start = Offset(blockLong * 0.42, 0);
  final reach = (collarEnd - start).distance;
  final tubePath = Path()
    ..moveTo(start.dx, start.dy)
    ..cubicTo(
      start.dx + reach * 0.40, start.dy,
      collarEnd.dx - forward.dx * reach * 0.36, collarEnd.dy - forward.dy * reach * 0.36,
      collarEnd.dx, collarEnd.dy,
    );

  // The light comes from the top left of the screen; in the arm's frame that is
  // wherever that direction has been turned to.
  final lightScreen = const Offset(-0.55, -0.83);
  final light = Offset(
    lightScreen.dx * math.cos(-angle) - lightScreen.dy * math.sin(-angle),
    lightScreen.dx * math.sin(-angle) + lightScreen.dy * math.cos(-angle),
  );

  final headRect = RRect.fromRectAndRadius(
    Rect.fromCenter(center: Offset.zero, width: headLength, height: headWidth),
    Radius.circular(headWidth * 0.22),
  );
  final headAngle = math.atan2(forward.dy, forward.dx);

  void inHead(void Function() draw) {
    canvas.save();
    canvas.translate(headCentre.dx, headCentre.dy);
    canvas.rotate(headAngle);
    draw();
    canvas.restore();
  }

  // ---- The shadow: the whole silhouette once, soft, falling down and right. ----
  final shadowOffset = Offset(r * (0.022 + 0.05 * lift), r * (0.034 + 0.07 * lift));
  final shadowPaint = Paint()
    ..color = _dim(Color.fromRGBO(0, 0, 0, 0.42 - 0.14 * lift), dim)
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * (0.014 + 0.03 * lift));
  canvas.save();
  canvas.translate(g.pivot.dx + shadowOffset.dx, g.pivot.dy + shadowOffset.dy);
  canvas.rotate(angle);
  canvas.drawPath(
    tubePath,
    Paint()
      ..color = shadowPaint.color
      ..maskFilter = shadowPaint.maskFilter
      ..style = PaintingStyle.stroke
      ..strokeWidth = tubeWide
      ..strokeCap = StrokeCap.round,
  );
  inHead(() => canvas.drawRRect(headRect, shadowPaint));
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(-r * 0.40, -r * 0.075, blockLong / 2, r * 0.075),
      Radius.circular(r * 0.04),
    ),
    shadowPaint,
  );
  canvas.restore();

  // Lifted, the whole arm comes a hair towards you.
  canvas.save();
  canvas.translate(g.pivot.dx, g.pivot.dy);
  canvas.rotate(angle);
  if (lift > 0) {
    final grow = 1 + 0.025 * lift;
    canvas.scale(grow, grow);
  }

  // ---- The counterweight: a turned cylinder behind the post. ----
  final weightRect = Rect.fromLTRB(-r * 0.40, -r * 0.075, -r * 0.13, r * 0.075);
  final cylinder = ui.Gradient.linear(
    Offset(0, weightRect.top),
    Offset(0, weightRect.bottom),
    [
      _dim(_weightDark, dim),
      _dim(light.dy < 0 ? _weightLit : _weight, dim),
      _dim(_weight, dim),
      _dim(_weightDark, dim),
    ],
    light.dy < 0 ? const [0.0, 0.22, 0.55, 1.0] : const [0.0, 0.45, 0.78, 1.0],
  );
  // The stub it rides on.
  canvas.drawRect(
    Rect.fromLTRB(-r * 0.14, -r * 0.022, 0, r * 0.022),
    Paint()..color = _dim(_tube, dim),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(weightRect, Radius.circular(r * 0.018)),
    Paint()..shader = cylinder,
  );
  // Knurled grip rings, and the end face.
  for (var i = 0; i < 4; i++) {
    final x = weightRect.left + r * 0.035 + i * r * 0.012;
    canvas.drawLine(
      Offset(x, weightRect.top + r * 0.006),
      Offset(x, weightRect.bottom - r * 0.006),
      Paint()
        ..color = _dim(const Color(0x66000000), dim)
        ..strokeWidth = r * 0.004,
    );
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(weightRect.left, weightRect.top, weightRect.left + r * 0.018,
          weightRect.bottom),
      Radius.circular(r * 0.009),
    ),
    Paint()..color = _dim(const Color(0xFF55585E), dim),
  );

  // ---- The bearing block on the post. ----
  final block = RRect.fromRectAndRadius(
    Rect.fromCenter(center: Offset.zero, width: blockLong, height: blockWide),
    Radius.circular(r * 0.03),
  );
  canvas.drawRRect(
    block,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(-blockLong / 2 * light.dx.sign, -blockWide / 2 * light.dy.sign),
        Offset(blockLong / 2 * light.dx.sign, blockWide / 2 * light.dy.sign),
        [_dim(const Color(0xFF3A3B40), dim), _dim(_block, dim), _dim(_blockDark, dim)],
        const [0.0, 0.35, 1.0],
      ),
  );
  canvas.drawRRect(
    block.deflate(r * 0.006),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.004
      ..color = _dim(const Color(0x22FFFFFF), dim),
  );

  // ---- The tube: black, round, lit softly along the side facing the light. ----
  Paint stroke(Color c, double w) => Paint()
    ..color = _dim(c, dim)
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round;
  canvas.drawPath(tubePath, stroke(_tubeUnder, tubeWide));
  canvas.drawPath(tubePath, stroke(_tube, tubeWide * 0.78));
  canvas.save();
  canvas.translate(light.dx * tubeWide * 0.20, light.dy * tubeWide * 0.20);
  canvas.drawPath(tubePath, stroke(const Color(0x33FFFFFF), tubeWide * 0.30));
  canvas.drawPath(tubePath, stroke(const Color(0x2EFFFFFF), tubeWide * 0.10));
  canvas.restore();

  // The collar where the tube goes into the headshell.
  canvas.drawLine(
    collarEnd - forward * (r * 0.004),
    headRear + forward * (r * 0.004),
    stroke(_shellDark, tubeNarrow * 1.25)..strokeCap = StrokeCap.butt,
  );

  // ---- The headshell. ----
  inHead(() {
    canvas.drawRRect(
      headRect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, -headWidth / 2),
          Offset(0, headWidth / 2),
          [_dim(const Color(0xFF3B3C41), dim), _dim(_shell, dim), _dim(_shellDark, dim)],
          const [0.0, 0.35, 1.0],
        ),
    );
    canvas.drawRRect(
      headRect.deflate(r * 0.004),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.004
        ..color = _dim(const Color(0x26FFFFFF), dim),
    );
    // Two slots running along it, where the cartridge is bolted through.
    for (final y in [-headWidth * 0.20, headWidth * 0.20]) {
      final slot = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(headLength * 0.14, y),
            width: headLength * 0.34,
            height: headWidth * 0.16),
        Radius.circular(headWidth * 0.08),
      );
      canvas.drawRRect(slot, Paint()..color = _dim(_hole, dim));
      canvas.drawLine(
        Offset(slot.left + slot.blRadiusX, slot.bottom),
        Offset(slot.right - slot.brRadiusX, slot.bottom),
        Paint()
          ..color = _dim(const Color(0x30FFFFFF), dim)
          ..strokeWidth = r * 0.003,
      );
    }
    // Three screws in a row, nearer the tube.
    for (var i = -1; i <= 1; i++) {
      final c = Offset(-headLength * 0.22, i * headWidth * 0.26);
      canvas.drawCircle(c, headWidth * 0.075, Paint()..color = _dim(_hole, dim));
      canvas.drawCircle(
        c + Offset(-headWidth * 0.018, -headWidth * 0.018),
        headWidth * 0.028,
        Paint()..color = _dim(_screwLit, dim),
      );
    }
    // The finger lift: a small rounded tab standing off the front corner, away from
    // the middle of the record, where a finger goes.
    final tab = RRect.fromRectAndRadius(
      Rect.fromLTWH(headLength * 0.30, away < 0 ? -headWidth * 0.86 : headWidth * 0.44,
          headLength * 0.16, headWidth * 0.42),
      Radius.circular(headWidth * 0.12),
    );
    canvas.drawRRect(tab, Paint()..color = _dim(_shell, dim));
    canvas.drawRRect(
      tab,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.004
        ..color = _dim(const Color(0x22FFFFFF), dim),
    );
  });
  canvas.restore();

  // ---- The pivot cap, which does not turn with the arm. ----
  final cap = g.pivot;
  canvas.drawCircle(
    cap,
    r * 0.046,
    Paint()
      ..shader = ui.Gradient.radial(
        cap + Offset(-r * 0.015, -r * 0.015),
        r * 0.06,
        [_dim(_silver, dim), _dim(_silverDark, dim)],
      ),
  );
  canvas.drawCircle(cap, r * 0.016, Paint()..color = _dim(_blockDark, dim));
}

Offset _toLocal(Offset point, Offset pivot, double angle) {
  final v = point - pivot;
  final c = math.cos(-angle);
  final s = math.sin(-angle);
  return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
}
