import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../state/booth/booth.dart';
import '../../state/booth/deck.dart';
import '../motion.dart';

/// The room's clock: one ticker for both records.
///
/// Everything in the booth moves with the music — the platters turn, the waveforms
/// run under their needles, the phase meter swings, the countdown counts — and each
/// of those reading the engine on a ticker of its own is four tickers doing the same
/// arithmetic. This is the one, at the top of the room: it carries each deck's
/// position forward between the engine's reports and turns each platter at that
/// deck's tempo, and everything below reads whichever notifier it needs.
class BoothClock extends StatefulWidget {
  const BoothClock({super.key, required this.booth, required this.child});

  final Booth booth;
  final Widget child;

  static BoothClockReader of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Ticking>()!.state;

  /// [child], under the clock [from] is under — for a sheet or a dialog opened from the
  /// room, whose route sits above the clock rather than inside it.
  static Widget carriedFrom(BuildContext from, Widget child) {
    final ticking = from.getInheritedWidgetOfExactType<_Ticking>();
    return ticking == null ? child : _Ticking(state: ticking.state, child: child);
  }

  @override
  State<BoothClock> createState() => _BoothClockState();
}

/// What the room's clock offers whatever is drawn from it.
abstract class BoothClockReader {
  /// Where a record is now, between the engine's reports.
  ValueNotifier<Duration> positionOf(Deck deck);

  /// How far round a platter has turned, in turns.
  AnimationController turnOf(Deck deck);
}

class _BoothClockState extends State<BoothClock>
    with TickerProviderStateMixin
    implements BoothClockReader {
  late final Ticker _ticker = createTicker(_tick);
  final _positions = <String, ValueNotifier<Duration>>{};
  final _turns = <String, AnimationController>{};
  final _speeds = <String, double>{};
  Duration? _last;

  /// The wall clock at the ticker's nought: a frame's time is this plus the frame's
  /// own timestamp. See [_tick].
  DateTime? _epoch;

  /// While nothing moves, the ticker rests and this looks in a few times a second
  /// instead: for a record started, or moved while parked.
  Timer? _resting;
  int _still = 0;

  /// 33⅓: one turn every 1.8 s, the speed the record would really run.
  static const _fullSpeed = 1 / 1.8;

  @override
  ValueNotifier<Duration> positionOf(Deck deck) =>
      _positions.putIfAbsent(deck.name, () => ValueNotifier(deck.position));

  /// An animation rather than a plain number, because that is what the record is
  /// drawn from — see Disc.spinning.
  @override
  AnimationController turnOf(Deck deck) => _turns.putIfAbsent(
      deck.name, () => AnimationController.unbounded(vsync: this));

  @override
  void initState() {
    super.initState();
    widget.booth.addListener(_wake);
    _ticker.start();
  }

  @override
  void didUpdateWidget(BoothClock old) {
    super.didUpdateWidget(old);
    if (!identical(old.booth, widget.booth)) {
      old.booth.removeListener(_wake);
      widget.booth.addListener(_wake);
    }
  }

  /// Ticking again, if it was resting: something in the booth changed.
  void _wake() {
    if (!mounted || _ticker.isActive) return;
    _resting?.cancel();
    _resting = null;
    _still = 0;
    _last = null;
    _ticker.start();
  }

  /// Resting: nothing has moved for a while. A frame asked for sixty times a second
  /// with nothing to show is still sixty frames drawn — the whole room composited
  /// again each time — so the ticker stops, and a timer looks in instead in case a
  /// record moved without the booth saying so.
  void _rest() {
    _ticker.stop();
    _last = null;
    _resting ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      var moved = false;
      for (final deck in [widget.booth.a, widget.booth.b]) {
        final now = deck.position;
        final n = positionOf(deck);
        if (n.value != now) {
          n.value = now;
          moved = true;
        }
        if (deck.playing) moved = true;
      }
      if (moved) _wake();
    });
  }

  @override
  void dispose() {
    widget.booth.removeListener(_wake);
    _resting?.cancel();
    _ticker.dispose();
    for (final n in _positions.values) {
      n.dispose();
    }
    for (final n in _turns.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    if (last == null) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    final still = stillness(context);
    // The time this frame is *for*, not the time this callback happened to run. The
    // ticker's elapsed is counted in frames — vsync to vsync — while the wall clock
    // read inside the callback lands wherever the frame's work let it, a few
    // milliseconds early or late each time. Read off the wall clock, a strip moving a
    // steady 100 pixels a second moved 1, then 2, then 1, then 3 pixels a frame, which
    // is a judder the eye reads as lag. Kept to the wall clock over the long run, so
    // positions still mean what the engine means by them.
    final wall = DateTime.now();
    var now = _epoch?.add(elapsed);
    if (now == null || (wall.difference(now).inMicroseconds).abs() > 40000) {
      _epoch = wall.subtract(elapsed);
      now = wall;
    }
    var moving = false;
    for (final deck in [widget.booth.a, widget.booth.b]) {
      final p = positionOf(deck);
      final at = deck.positionAt(now);
      if (p.value != at) moving = true;
      p.value = at;
      if (deck.playing) moving = true;
      // Up over a third of a second, down over half: a platter has weight. A phone
      // asked to keep still gets the record at rest rather than a still one turning.
      final want = deck.playing && !still ? _fullSpeed * deck.tempo : 0.0;
      final was = _speeds[deck.name] ?? 0;
      final tau = want > was ? 0.33 : 0.5;
      final speed = was + (want - was) * (1 - _decay(dt / tau));
      _speeds[deck.name] = speed;
      if (speed.abs() > 1e-4) {
        moving = true;
        final turn = turnOf(deck);
        turn.value = (turn.value + speed * dt) % 1024;
      }
    }
    // Half a second of nothing moving, and the ticker rests.
    _still = moving ? 0 : _still + 1;
    if (_still > 30) _rest();
  }

  /// e^-x, near enough for a platter's inertia.
  static double _decay(double x) {
    if (x > 20) return 0;
    var sum = 1.0, term = 1.0;
    for (var i = 1; i < 12; i++) {
      term *= x / i;
      sum += term;
    }
    return 1 / sum;
  }

  @override
  Widget build(BuildContext context) => _Ticking(state: this, child: widget.child);
}

class _Ticking extends InheritedWidget {
  const _Ticking({required this.state, required super.child});
  final _BoothClockState state;

  @override
  bool updateShouldNotify(_Ticking old) => false;
}
