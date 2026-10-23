// The camera's hand on the 3D scenes (the dancers, the birds, the turntable, the 3D
// text): the finished picture moved with the music — only as much as the record is
// intense, so a quiet part keeps the still camera it always had (show_director.dart's
// intensityFor, past its middle). On the kick a punch in; on the snare a tick of the
// horizon, one way then the other; through a build a slow push in; on the drop a
// harder punch and a shake that settles over a few beats. The picture is scaled to
// cover what the shake and the tilt would show of its edges.
//
// And the scenes' own cameras travel through their shots in a loud part (CameraSweep):
// round the figure, in at it, back and up from it, spiralling in, in low over a crowd.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../state/show/show_director.dart';
import '../../state/show/show_feed.dart';
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';

/// The camera's moves for one frame: a scale about the middle, a shift (a share of
/// the picture's size) and a roll (radians).
typedef CameraMove = ({double zoom, double dx, double dy, double roll});

class StageCamera {
  double? _dropAt;
  double? _awayWas;
  double _push = 0;

  /// Whether [kind]'s picture is a camera's (a scene shot in 3D).
  static bool shot(Figure kind) =>
      kind == Figure.dancers || kind == Figure.birds || kind == Figure.turntable || kind == Figure.type3d;

  /// How hard the camera works now, 0 (still: a quiet part) to 1 (a drop).
  static double drive(ShowDeck m) => ShowDirector.drive(m);

  CameraMove move(ShowState st, double dt) {
    const none = (zoom: 1.0, dx: 0.0, dy: 0.0, roll: 0.0);
    if (!shot(st.rig.figure.kind)) {
      _dropAt = null;
      _push = 0;
      return none;
    }
    final m = st.master;
    if (!m.playing || m.beatIndex == null) return none;
    final beats = m.beatIndex! + m.beatPhase;
    final drive = StageCamera.drive(m);
    final kick = st['kick'].clamp(0.0, 1.0);
    final snare = st['snare'].clamp(0.0, 1.0);

    // The drop: when it lands (the deck says how far it is), remembered a few beats.
    final away = m.dropBeatsAway;
    if (away != null && away <= 0 && away > -2.5 && (_awayWas == null || _awayWas! > 0)) _dropAt = beats + away;
    _awayWas = away;
    if (_dropAt != null && (beats - _dropAt! > 12 || beats < _dropAt! - 1)) _dropAt = null;
    final burst = _dropAt == null ? 0.0 : math.exp(-(beats - _dropAt!) / 2.2);

    // A build: in slowly as it climbs; let go of at once on the drop.
    final building = !m.breakdown && (m.section == 'build' || (away != null && away > 0 && away < 32));
    final want = building ? m.buildK.clamp(0.0, 1.0) : 0.0;
    _push = burst > 0.5 ? 0 : _push + (want - _push) * math.min(1.0, dt * (want > _push ? 0.8 : 3));

    // The shake: two drifting sines a few times a beat, settling with the burst.
    final s = beats * math.pi * 2;
    final shake = burst * 0.012;
    final dx = shake * (math.sin(s * 1.7) + 0.6 * math.sin(s * 4.3 + 1.1));
    final dy = shake * (math.cos(s * 2.1) + 0.5 * math.sin(s * 3.7 + 2.3));
    final side = (m.beatIndex! % 2 == 0) ? 1.0 : -1.0;
    final roll = 0.014 * snare * drive * side + 0.02 * burst * math.sin(s * 1.3);
    final zoom = 1 + 0.045 * kick * drive + 0.1 * burst + 0.07 * _push;
    // Scaled to cover the corners the tilt and the shake would bare.
    final cover = 1 + 1.9 * roll.abs() + 2.2 * math.max(dx.abs(), dy.abs());
    return (zoom: zoom * cover, dx: dx, dy: dy, roll: roll);
  }
}

/// How many beats a figure's camera holds a framing, its own [hold] shortened by the
/// camera's [drive]: a bar in a drop, two in a loud part, as it was in a quiet one.
int cutHold(int hold, double drive) => drive > 0.75 ? math.min(hold, 4) : (drive > 0.4 ? math.min(hold, 8) : hold);

/// What a sweep does to a shot this frame: turned round what it looks at by [yaw]
/// (radians), its distance times [dist], raised by [rise] (a share of its distance;
/// what it looks at stays, so a rise tilts it down), its horizon tipped by [roll].
typedef SweepMove = ({double yaw, double dist, double rise, double roll});

/// The ways a shot travels: round what it looks at, in at it, back from it (rising
/// as it goes), up or down past it, spiralling in, and in low over a crowd.
enum SweepKind { arc, push, pull, crane, spiral, fly }

/// The camera on the move through a shot, in a loud part: each cut starts a travel
/// that runs the whole of the shot — slow and short in a chorus, a long spiral or a
/// fly-in over the crowd in a drop, whipped into on the drop's own cut. A quiet part's
/// shot has none: the still camera it always had.
class CameraSweep {
  static const none = (yaw: 0.0, dist: 1.0, rise: 0.0, roll: 0.0);

  SweepKind? _kind;
  double _at = 0, _hold = 16, _side = 1, _amount = 0, _k = 0;
  bool _close = false, _whip = false;

  /// The kind the shot now travels (null: still).
  SweepKind? get kind => _kind;

  /// Whether the camera is moving at all (what was drawn the frame before is stale).
  bool get moving => _kind != null && _amount * _k > 0.01;

  /// A new shot at [beats], held about [hold] beats: its travel by the dice [d], as
  /// far as the [drive] then. [close]: a shot already up at the figure (it never
  /// pushes in past it). [over]: a shot over a crowd (it may fly in over them).
  /// [drop]: the drop's own cut, whipped into.
  void cut(double beats, int hold, double drive, double d, {bool close = false, bool over = false, bool drop = false}) {
    _at = beats;
    _hold = math.max(2, hold).toDouble();
    _close = close;
    _whip = drop;
    _side = ((d * 7919).floor().isEven) ? 1 : -1;
    _amount = drive < 0.12 ? 0 : math.pow(drive, 0.8).toDouble();
    if (_amount == 0) {
      _kind = null;
      return;
    }
    final w = <(SweepKind, double)>[
      (SweepKind.arc, 1),
      (SweepKind.push, close ? 0 : 1),
      (SweepKind.pull, 0.7),
      (SweepKind.crane, 0.8),
      (SweepKind.spiral, drive > 0.6 ? 1.2 : 0.2),
      (SweepKind.fly, over && !close ? 0.6 + drive : 0),
    ];
    var at = d * w.fold(0.0, (s, x) => s + x.$2);
    _kind = w.last.$1;
    for (final (k, x) in w) {
      if (at < x) {
        _kind = k;
        break;
      }
      at -= x;
    }
    // A cut is a cut: as far as the music says at once (eased only through the shot).
    _k = math.min(drive * 1.2, 1.0);
  }

  /// Where the shot has travelled at [beats]: as far as the [drive] now, eased to.
  SweepMove at(double beats, double drive, double dt) {
    final kind = _kind;
    if (kind == null) return none;
    _k += (math.min(drive * 1.2, 1.0) - _k) * math.min(1.0, dt * 1.5);
    // A short shot travels less (a bar's sweep a part of a long one's).
    final a = _amount * _k * math.sqrt(math.min(1.0, _hold / 8)), s = _side;
    final p = ((beats - _at) / _hold).clamp(0.0, 1.0);
    // Steady through the middle, eased at the ends.
    final e = 0.5 * p + 0.5 * p * p * (3 - 2 * p);
    final c = 2 * e - 1;
    var yaw = 0.0, dist = 1.0, rise = 0.0, roll = 0.0;
    switch (kind) {
      case SweepKind.arc:
        yaw = s * 0.5 * a * c;
        dist = 1 - 0.08 * a * math.sin(math.pi * e);
      case SweepKind.push:
        dist = 1 + a * (0.3 - 0.55 * e);
        rise = -0.05 * a * e;
        yaw = s * 0.08 * a * c;
      case SweepKind.pull:
        dist = 1 + a * (-0.15 + 0.5 * e);
        rise = 0.16 * a * e;
        yaw = s * 0.12 * a * e;
      case SweepKind.crane:
        rise = a * (s > 0 ? -0.1 + 0.34 * e : 0.24 - 0.34 * e);
        yaw = s * 0.15 * a * c;
      case SweepKind.spiral:
        yaw = s * 0.95 * a * c;
        dist = 1 + a * (0.25 - 0.45 * e);
        roll = s * 0.05 * a * c;
      case SweepKind.fly:
        dist = 1 - 0.55 * a * e;
        rise = -0.3 * a * e;
        yaw = s * 0.2 * a * c;
    }
    // The drop's cut: swung in from the side, settling into the travel in a beat or two.
    if (_whip) yaw += s * 0.8 * a * math.exp(-(beats - _at).clamp(0.0, 99.0) * 1.6);
    if (_close) dist = math.max(dist, 1);
    return (yaw: yaw, dist: dist, rise: rise, roll: roll);
  }
}

/// [child] (the stage's picture) moved by a [StageCamera] every frame of [feed].
class StageCameraView extends StatefulWidget {
  const StageCameraView({super.key, required this.feed, required this.child});
  final ShowFeed feed;
  final Widget child;

  @override
  State<StageCameraView> createState() => _StageCameraViewState();
}

class _StageCameraViewState extends State<StageCameraView> {
  final _camera = StageCamera();

  // Always the same widgets round the picture (a Transform at rest when the camera
  // is), so the stage under it is never built again.
  @override
  Widget build(BuildContext context) => ClipRect(
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: widget.feed,
            child: widget.child,
            builder: (context, child) {
              final st = widget.feed.state;
              final c = _camera.move(st, st.dt);
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translateByDouble(c.dx * box.maxWidth, c.dy * box.maxHeight, 0, 1)
                  ..rotateZ(c.roll)
                  ..scaleByDouble(c.zoom, c.zoom, 1, 1),
                child: child,
              );
            },
          ),
        ),
      );
}
