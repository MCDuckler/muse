import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../feel.dart';
import 'arm_geometry.dart';

/// Where the song is, as the arm needs to know it.
@immutable
class ArmReading {
  const ArmReading({this.position = Duration.zero, this.length, this.playing = false});

  final Duration position;
  final Duration? length;
  final bool playing;

  /// How far through the side the needle is, 0 to 1.
  double get groove {
    final total = length?.inMilliseconds ?? 0;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is ArmReading &&
      other.position == position &&
      other.length == length &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(position, length, playing);
}

/// What a hand on the arm can do, and what it needs to know to do it.
class ArmHand {
  const ArmHand({required this.reading, required this.onPlace, required this.onPark});

  /// Where the song is now, as it changes.
  final ValueListenable<ArmReading> reading;

  /// The needle has been put down here: play from this point.
  final void Function(Duration at) onPlace;

  /// The arm has been lifted off and put back on its rest: stop.
  final VoidCallback onPark;
}

/// A tonearm that can be picked up.
///
/// Take hold of it anywhere along its length and it lifts — the shadow falls further
/// away and softens — and follows the finger round its post, as far as the rest on one
/// side and the end of the side on the other. Where it is let go is where the music
/// plays from: on the record it drops the needle there, and off the edge it goes back
/// on its rest and the music stops. A tap does what a tap on a real arm's lift does:
/// lifts it off if it is playing, sets it down where it was if it is not.
///
/// The rest of the stage still works around it. Only a finger that lands *on* the arm
/// is taken; one on the record or the sleeves beside it goes where it always went. And
/// a finger that is on the arm is claimed the moment it lands, before the shelf's own
/// sideways drag or the player's pull-down can decide it was meant for them.
class ArmGrip extends StatefulWidget {
  const ArmGrip({
    super.key,
    required this.hand,
    required this.reading,
    required this.radius,
    required this.drop,
    required this.label,
    required this.landed,
    required this.paint,
  });

  final ArmHand hand;
  final ArmReading reading;
  final double radius;
  final double drop;
  final double label;

  /// How far down the stage has lowered the arm: 0 parked, 1 on the record.
  final double landed;

  /// Draw the arm at this angle, or where the song says it is when [held] is null.
  final Widget Function(double? held, double lift) paint;

  @override
  State<ArmGrip> createState() => _ArmGripState();
}

class _ArmGripState extends State<ArmGrip> with TickerProviderStateMixin {
  /// The angle the hand has put it at. Null while the song is steering it.
  double? _held;

  /// While a finger is on it.
  bool _holding = false;

  /// Where the finger went down, and how far it has been since: a tap is a hold that
  /// never went anywhere.
  Offset _downAt = Offset.zero;
  double _travelled = 0;

  /// The angle between the finger and the arm at the moment it was taken hold of, so
  /// the arm does not jump to put itself under the fingertip.
  double _grab = 0;

  /// After letting go: what the hand did, so the arm can stay where it was put until
  /// the music has caught up with it rather than swinging back for a frame.
  _Put? _put;
  Timer? _giveUp;

  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  /// Swinging to the rest after being let go off the record.
  late final AnimationController _swing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  double _swingFrom = 0;
  double _swingTo = 0;

  ArmGeometry _geometry(Size size) => ArmGeometry.of(size,
      radius: widget.radius, drop: widget.drop, label: widget.label);

  Size _size = Size.zero;

  double get _songAngle => _geometry(_size)
      .angle(landed: widget.landed, groove: widget.reading.groove);

  double get _shown => _held ?? _songAngle;

  _ArmReachState? _reach;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reach = ArmReach._of(context);
    if (reach != _reach) {
      _reach?._leave(this);
      _reach = reach?.._join(this);
    }
  }

  @override
  void didUpdateWidget(ArmGrip old) {
    super.didUpdateWidget(old);
    _maybeLetGo();
  }

  /// Hand the arm back to the song once the song has got to where it was put.
  void _maybeLetGo() {
    final put = _put;
    if (put == null || _holding) return;
    final caughtUp = put.parked
        ? widget.landed <= 0.02
        : widget.landed >= 0.98 && (widget.reading.groove - put.groove).abs() < 0.02;
    if (caughtUp) _release();
  }

  void _release() {
    _giveUp?.cancel();
    _put = null;
    if (!mounted) return;
    // After this frame: this is reached from didUpdateWidget, which is in the middle
    // of one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _put == null && !_holding) setState(() => _held = null);
    });
  }

  @override
  void dispose() {
    _reach?._leave(this);
    _giveUp?.cancel();
    _lift.dispose();
    _swing.dispose();
    super.dispose();
  }

  bool _onArm(Size size, Offset p) {
    final g = _geometry(size);
    // Generous where it is thin: a tube a few pixels wide is not something a thumb
    // can find, and the headshell is where a hand actually goes.
    final slack = (widget.radius * 0.07).clamp(18.0, 44.0);
    final angle = _held ?? g.angle(landed: widget.landed, groove: widget.reading.groove);
    if (g.distanceToArm(p, angle) <= slack) return true;
    return (p - g.needleAt(angle)).distance <= widget.radius * 0.20;
  }

  /// A point on the screen, in this arm's own box — which is where the geometry is,
  /// even when the point is outside the box, as most of the arm is on a phone.
  Offset? _local(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  /// Whether a finger at this point on the screen is on the arm.
  bool _hits(Offset global) {
    final at = _local(global);
    return at != null && _onArm(_size, at);
  }

  void _start(Offset global) {
    final g = _geometry(_size);
    final at = _local(global) ?? Offset.zero;
    _swing.stop();
    _put = null;
    _giveUp?.cancel();
    final now = _shown;
    _grab = ArmGeometry.turn(g.bearing(at), now);
    _downAt = at;
    _travelled = 0;
    setState(() {
      _holding = true;
      _held = now;
    });
    _lift.forward();
    Haptics.of(Feel.pick);
  }

  void _update(Offset global) {
    final g = _geometry(_size);
    final at = _local(global);
    if (at == null) return;
    _travelled = (at - _downAt).distance;
    final wanted = g.clamp(g.bearing(at) + _grab);
    final before = _held ?? wanted;
    // A tick as the needle crosses the rim, one way or the other: the moment the
    // arm goes from being over the record to being over nothing.
    if (g.offRecord(before) != g.offRecord(wanted)) Haptics.of(Feel.edge);
    setState(() => _held = wanted);
  }

  void _cancel() {
    _lift.reverse();
    setState(() {
      _holding = false;
      _held = null;
    });
  }

  void _end() {
    final g = _geometry(_size);
    final at = _held ?? _shown;
    _lift.reverse();
    setState(() => _holding = false);

    final tapped = _travelled < 8;
    final playing = widget.reading.playing;

    if ((tapped && playing) || (!tapped && g.offRecord(at))) {
      _park(g, at);
      return;
    }
    // Down on the record: where it was put, or — for a tap on a parked arm — where the
    // song was when it stopped.
    final groove = tapped ? widget.reading.groove : g.grooveOf(at);
    final length = widget.reading.length;
    final target = length == null
        ? Duration.zero
        : Duration(milliseconds: (length.inMilliseconds * groove).round());
    setState(() => _held = g.playing(groove));
    _put = _Put(groove: groove, parked: false);
    _giveUp = Timer(const Duration(milliseconds: 2500), _release);
    Haptics.of(Feel.commit);
    widget.hand.onPlace(target);
  }

  void _park(ArmGeometry g, double from) {
    _swingFrom = from;
    _swingTo = g.parked;
    _swing
      ..value = 0
      ..forward();
    _put = const _Put(groove: 0, parked: true);
    _giveUp = Timer(const Duration(milliseconds: 2500), _release);
    Haptics.of(Feel.pick);
    if (widget.reading.playing) widget.hand.onPark();
  }

  String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    _maybeLetGo();
    final length = widget.reading.length;
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      final g = _geometry(_size);
      return AnimatedBuilder(
        animation: Listenable.merge([_lift, _swing]),
        builder: (context, _) {
          final swinging = _swing.isAnimating || (_put?.parked ?? false);
          final angle = swinging && !_holding
              ? _swingFrom + ArmGeometry.turn(_swingFrom, _swingTo) *
                  Curves.easeOutCubic.transform(_swing.value)
              : _held;
          final shownAngle = angle ?? _songAngle;
          final lift = Curves.easeOut.transform(_lift.value);
          final off = g.offRecord(shownAngle);
          final groove = g.grooveOf(shownAngle);

          // Said to a screen reader as what it is: a slider for where the song is.
          final at = length == null
              ? null
              : Duration(milliseconds: (length.inMilliseconds * widget.reading.groove).round());
          void nudge(double by) {
            if (length == null) return;
            final to = (widget.reading.groove + by).clamp(0.0, 1.0);
            widget.hand.onPlace(
                Duration(milliseconds: (length.inMilliseconds * to).round()));
          }

          // What a swipe up or down would move it to, said before it is done: a
          // screen reader announces the value an adjustment will land on.
          String? stepped(double by) {
            if (length == null) return null;
            final to = (widget.reading.groove + by).clamp(0.0, 1.0);
            return _clock(Duration(milliseconds: (length.inMilliseconds * to).round()));
          }

          return Semantics(
            slider: true,
            label: 'Tonearm',
            value: at == null ? 'Parked' : '${_clock(at)} of ${_clock(length!)}',
            increasedValue: stepped(0.05),
            decreasedValue: stepped(-0.05),
            onIncrease: length == null ? null : () => nudge(0.05),
            onDecrease: length == null ? null : () => nudge(-0.05),
            onTap: () => widget.reading.playing ? widget.hand.onPark() : nudge(0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: _reach != null
                      // Taken hold of from further up: see ArmReach. The drawing
                      // itself takes nothing, or its whole box would swallow the
                      // touches meant for whatever is under it.
                      ? IgnorePointer(
                          child: RepaintBoundary(child: widget.paint(angle, lift)))
                      : MouseRegion(
                          opaque: false,
                          cursor: _holding
                              ? SystemMouseCursors.grabbing
                              : SystemMouseCursors.grab,
                          child: RawGestureDetector(
                            behavior: HitTestBehavior.deferToChild,
                            gestures: {
                              _Eager: GestureRecognizerFactoryWithHandlers<_Eager>(
                                () => _Eager(null),
                                (r) => r
                                  ..onStart = ((d) => _start(d.globalPosition))
                                  ..onUpdate = ((d) => _update(d.globalPosition))
                                  ..onEnd = ((_) => _end())
                                  ..onCancel = _cancel,
                              ),
                            },
                            child: _OnlyOn(
                              test: _onArm,
                              child: RepaintBoundary(child: widget.paint(angle, lift)),
                            ),
                          ),
                        ),
                ),
                // Where it will play from, while it is held: the one number worth
                // knowing with a needle in the air.
                if (_holding && length != null)
                  Positioned(
                    left: g.needleAt(shownAngle).dx - 40,
                    top: g.needleAt(shownAngle).dy - widget.radius * 0.30 - 18,
                    width: 80,
                    child: IgnorePointer(
                      child: Center(
                        child: _Pill(
                          text: off
                              ? 'Lift off'
                              : _clock(Duration(
                                  milliseconds: (length.inMilliseconds * groove).round())),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    });
  }
}

/// What was done with the arm when it was let go.
class _Put {
  const _Put({required this.groove, required this.parked});
  final double groove;
  final bool parked;
}

/// A pan that is decided the moment the finger lands.
///
/// An ordinary pan waits for the finger to move far enough to be sure it is a drag,
/// and by then the shelf's own sideways drag — which needs less movement to be sure —
/// has already taken it. A finger that came down on the arm meant the arm.
class _Eager extends PanGestureRecognizer {
  _Eager(this.wants);

  /// Whether a pointer that landed here is one this is for. Null: every one that
  /// reaches it, which is only ever one on the arm.
  final bool Function(Offset global)? wants;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (wants?.call(event.position) ?? true) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Hit only where [test] says: the arm, not the whole box it is drawn in.
class _OnlyOn extends SingleChildRenderObjectWidget {
  const _OnlyOn({required this.test, super.child});

  final bool Function(Size size, Offset point) test;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderOnlyOn(test);

  @override
  void updateRenderObject(BuildContext context, _RenderOnlyOn renderObject) {
    renderObject.test = test;
  }
}

class _RenderOnlyOn extends RenderProxyBox {
  _RenderOnlyOn(this.test);

  bool Function(Size size, Offset point) test;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || !test(size, position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onInverseSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}


/// The part of the screen a tonearm can be picked up from.
///
/// Flutter only hands a touch to a widget whose own box it landed in, and the box the
/// record stage is given is the cover's square — while the record leans up out of it
/// into the empty middle of the header, and the arm lies across the top of the record.
/// On a phone almost none of the arm is inside the box it belongs to, so a gesture
/// detector on the arm never heard a thing.
///
/// So the finger is caught further up, by something the size of the whole player, and
/// the arm is asked whether it is on it. A touch that is not on the arm is not taken:
/// it goes on to whatever it would have gone to without this.
class ArmReach extends StatefulWidget {
  const ArmReach({super.key, required this.child});

  final Widget child;

  static _ArmReachState? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ReachScope>()?.reach;

  @override
  State<ArmReach> createState() => _ArmReachState();
}

class _ArmReachState extends State<ArmReach> {
  _ArmGripState? _arm;
  MouseCursor _cursor = MouseCursor.defer;

  void _join(_ArmGripState arm) => _arm = arm;

  void _leave(_ArmGripState arm) {
    if (_arm == arm) _arm = null;
  }

  bool _wants(Offset global) {
    final arm = _arm;
    return arm != null && arm.mounted && arm._hits(global);
  }

  void _hover(PointerHoverEvent e) {
    final next = _wants(e.position) ? SystemMouseCursors.grab : MouseCursor.defer;
    if (next != _cursor) setState(() => _cursor = next);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        opaque: false,
        cursor: _cursor,
        onHover: _hover,
        child: RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            _Eager: GestureRecognizerFactoryWithHandlers<_Eager>(
              () => _Eager(_wants),
              (r) => r
                ..onStart = ((d) => _arm?._start(d.globalPosition))
                ..onUpdate = ((d) => _arm?._update(d.globalPosition))
                ..onEnd = ((_) => _arm?._end())
                ..onCancel = (() => _arm?._cancel()),
            ),
          },
          child: _ReachScope(reach: this, child: widget.child),
        ),
      );
}

class _ReachScope extends InheritedWidget {
  const _ReachScope({required this.reach, required super.child});

  final _ArmReachState reach;

  @override
  bool updateShouldNotify(_ReachScope old) => old.reach != reach;
}
