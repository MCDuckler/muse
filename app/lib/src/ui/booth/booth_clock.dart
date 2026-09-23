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

  static _BoothClockState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Ticking>()!.state;

  @override
  State<BoothClock> createState() => _BoothClockState();
}

class _BoothClockState extends State<BoothClock> with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _positions = <String, ValueNotifier<Duration>>{};
  final _turns = <String, AnimationController>{};
  final _speeds = <String, double>{};
  Duration? _last;

  /// 33⅓: one turn every 1.8 s, the speed the record would really run.
  static const _fullSpeed = 1 / 1.8;

  /// Where a record is now, between the engine's reports.
  ValueNotifier<Duration> positionOf(Deck deck) =>
      _positions.putIfAbsent(deck.name, () => ValueNotifier(deck.position));

  /// How far round a platter has turned, in turns. An animation rather than a plain
  /// number because that is what the record is drawn from — see Disc.spinning.
  AnimationController turnOf(Deck deck) => _turns.putIfAbsent(
      deck.name, () => AnimationController.unbounded(vsync: this));

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
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
    for (final deck in widget.booth.decks) {
      positionOf(deck).value = deck.position;
      // Up over a third of a second, down over half: a platter has weight. A phone
      // asked to keep still gets the record at rest rather than a still one turning.
      final want = deck.playing && !still ? _fullSpeed * deck.tempo : 0.0;
      final was = _speeds[deck.name] ?? 0;
      final tau = want > was ? 0.33 : 0.5;
      final now = was + (want - was) * (1 - _decay(dt / tau));
      _speeds[deck.name] = now;
      if (now.abs() > 1e-4) {
        final turn = turnOf(deck);
        turn.value = (turn.value + now * dt) % 1024;
      }
    }
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
