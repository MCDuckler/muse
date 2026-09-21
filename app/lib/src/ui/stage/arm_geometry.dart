import 'dart:math' as math;
import 'dart:ui' show Offset, Size, lerpDouble;

/// Where the tonearm is, and where it can go.
///
/// A tonearm is a stick on a post: its needle can only ever be somewhere on one circle,
/// the one its own length draws around the post. A groove is a circle around the middle
/// of the record. Where the needle plays is where the two meet — so "how far through
/// the song" is a distance from the middle of the record, and that distance is an angle
/// of the arm. This is that arithmetic, kept on its own so it can be checked without a
/// screen, and shared by every arm style so they all agree about where the music is.
///
/// Angles are measured from the line between the post and the middle of the record
/// rather than from the screen's own zero. The arm points left, and "left" is exactly
/// where an angle wraps from π round to -π; every comparison made near there would be
/// wrong half the time.
class ArmGeometry {
  ArmGeometry._({
    required this.middle,
    required this.pivot,
    required this.radius,
    required this.length,
    required this.label,
    required double base,
    required double side,
  })  : _base = base,
        _side = side;

  /// The arm for a record of this [radius], whose middle has dropped [drop] below the
  /// middle of the [box] it is drawn in, with a picture label [label] of the radius
  /// across.
  factory ArmGeometry.of(Size box,
      {required double radius, required double drop, double label = 0.31}) {
    final middle = Offset(box.width / 2, box.height / 2 + drop);
    // The post: out at the top right, where the part of the record that is not behind
    // a sleeve is.
    final pivot = middle + Offset(radius * 0.91, -radius * 0.90);
    // A real arm is about one and a half times a record's radius from its post to its
    // needle; this one was barely one, which is what made it look like a toy's. It
    // cannot simply be made as long as a real one: the post has to stay on the screen,
    // and the needle has to come down on the part of the record that shows above its
    // sleeve. A quarter longer, from a post a little further out, keeps the needle on
    // the upper left of the record from the first groove to the last — worked out for
    // every radius it plays at, not guessed.
    final reference = middle + Offset(-radius * 0.12, -radius * 0.72);
    final length = radius * 1.27;
    final toMiddle = middle - pivot;
    final base = math.atan2(toMiddle.dy, toMiddle.dx);
    // Which side of the post-to-middle line the needle swings on: the side the old
    // resting place was on.
    final towardsRef = reference - pivot;
    final side = _wrap(math.atan2(towardsRef.dy, towardsRef.dx) - base) >= 0 ? 1.0 : -1.0;
    return ArmGeometry._(
      middle: middle,
      pivot: pivot,
      radius: radius,
      length: length,
      label: label,
      base: base,
      side: side,
    );
  }

  final Offset middle;
  final Offset pivot;
  final double radius;
  final double length;
  final double label;
  final double _base;
  final double _side;

  /// Where the needle rests when the arm is parked: just past the rim. A real rest is
  /// further out, but on a phone the record already leans up into the header, and an
  /// arm swung any further is an arm swung off the top of the screen.
  static const restsAt = 1.05;

  /// Where a side starts: in from the rim, where the lead-in groove would be.
  double get outer => radius * 0.86;

  /// Where it ends: just outside the picture in the middle, however big that is.
  double get inner =>
      (radius * (label + 0.07)).clamp(radius * 0.24, outer).toDouble();

  /// The arm's angle, relative to the post-to-middle line, that puts the needle [r]
  /// from the middle of the record.
  double _relFor(double r) {
    final d = (middle - pivot).distance;
    final c = ((length * length + d * d - r * r) / (2 * length * d)).clamp(-1.0, 1.0);
    return _side * math.acos(c);
  }

  /// The relative angle for a point [g] of the way through the side, 0 to 1.
  double _relAt(double g) => _relFor(lerpDouble(outer, inner, g.clamp(0.0, 1.0))!);

  /// Parked: swung out past the rim, on the same side of the post as the record.
  double get _relParked => _relFor(radius * restsAt);

  /// The arm's angle on the screen for a needle [landed] of the way down (0 parked,
  /// 1 on the record) at [groove] of the way through the side.
  double angle({required double landed, required double groove}) =>
      _base + lerpDouble(_relParked, _relAt(groove), landed.clamp(0.0, 1.0))!;

  /// The angle on the screen that plays [groove] of the way through the side.
  double playing(double groove) => _base + _relAt(groove);

  /// The angle on the screen of the arm parked on its rest.
  double get parked => _base + _relParked;

  /// The arm's reference angle and needle point: where it sits at the start of a side.
  /// The headshell is bolted on at the angle that suits this point, once, the way a
  /// real one is.
  double get referenceAngle => playing(0);
  Offset get referencePoint => needleAt(referenceAngle);

  /// Where the needle is when the arm is at [angle].
  Offset needleAt(double angle) =>
      pivot + Offset(math.cos(angle), math.sin(angle)) * length;

  /// An angle on the screen, kept inside what the arm can reach: from its rest to the
  /// end of the side, and no further either way.
  double clamp(double angle) {
    final rel = _wrap(angle - _base);
    final a = _relParked;
    final b = _relAt(1);
    return _base + rel.clamp(math.min(a, b), math.max(a, b)).toDouble();
  }

  /// Whether the needle at [angle] is off the record, out past its rim.
  bool offRecord(double angle) =>
      (needleAt(angle) - middle).distance > radius * 0.965;

  /// How far through the side the needle at [angle] is, 0 to 1.
  double grooveOf(double angle) {
    final r = (needleAt(angle) - middle).distance;
    final span = outer - inner;
    if (span <= 0) return 0;
    return ((outer - r) / span).clamp(0.0, 1.0).toDouble();
  }

  /// The angle from the post to a point on the screen.
  double bearing(Offset point) {
    final v = point - pivot;
    return math.atan2(v.dy, v.dx);
  }

  /// How far [point] is from the arm at [angle]: from the post to the needle, as a
  /// line. Used to tell a finger on the arm from a finger on the record under it.
  double distanceToArm(Offset point, double angle) {
    final a = pivot;
    final b = needleAt(angle);
    final ab = b - a;
    final t = (((point - a).dx * ab.dx + (point - a).dy * ab.dy) /
            (ab.dx * ab.dx + ab.dy * ab.dy))
        .clamp(0.0, 1.0);
    return (point - (a + ab * t)).distance;
  }

  /// The difference between two angles, the short way round.
  static double turn(double from, double to) => _wrap(to - from);

  static double _wrap(double a) {
    var x = a;
    while (x > math.pi) {
      x -= 2 * math.pi;
    }
    while (x < -math.pi) {
      x += 2 * math.pi;
    }
    return x;
  }
}
