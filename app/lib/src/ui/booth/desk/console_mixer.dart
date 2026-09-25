import 'dart:async';

import 'package:flutter/material.dart';

import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../state/booth/mixer.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../meters.dart' show LevelMeter;
import 'console.dart';

/// The mixer between the decks: each channel's bands, filter and level; the
/// crossfader; and the one button that takes the room from one record to the other.
class ConsoleMixer extends StatefulWidget {
  const ConsoleMixer({super.key, required this.booth});
  final Booth booth;

  @override
  State<ConsoleMixer> createState() => _ConsoleMixerState();
}

class _ConsoleMixerState extends State<ConsoleMixer> {
  Transition _kind = Transition.blend;
  int _bars = 16;

  Booth get _b => widget.booth;

  @override
  Widget build(BuildContext context) {
    return Plate(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _Channel(booth: _b, deck: _b.a)),
                Container(width: 1, color: Console.line, margin: const EdgeInsets.symmetric(horizontal: 8)),
                Expanded(child: _Channel(booth: _b, deck: _b.b)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Crossfader(booth: _b),
          const SizedBox(height: 14),
          _mix(),
        ],
      ),
    );
  }

  Widget _mix() {
    final from = _b.master, to = _b.other(from);
    final ready = _b.a.loaded && _b.b.loaded && from.playing;
    final going = _b.inTransition;
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MixButton(
          going: going,
          arming: _b.arming?.startsAt,
          ready: ready,
          accent: accent,
          from: from.name,
          to: to.name,
          // Pressed while a mix waits for its beat or runs, it stops it: never a
          // second mix on top of the first.
          onTap: () {
            if (_b.busy) {
              _b.stopTransition();
            } else {
              unawaited(_b.go(_kind, bars: _bars));
            }
          },
        ),
        const SizedBox(height: 8),
        // How: one line, opened for the choices rather than all of them on show.
        PopupMenuButton<Object>(
          tooltip: 'How to mix',
          color: Console.raised,
          position: PopupMenuPosition.under,
          onSelected: (v) => setState(() {
            feel(Feel.pick);
            if (v is Transition) _kind = v;
            if (v is int) _bars = v;
          }),
          itemBuilder: (context) => [
            for (final k in Transition.values)
              PopupMenuItem<Object>(
                value: k,
                height: 36,
                child: Row(children: [
                  Icon(transitionIcon(k), size: 16, color: k == _kind ? accent : Console.quiet),
                  const SizedBox(width: 10),
                  Text(k.name.toUpperCase(),
                      style: Console.label(10, color: k == _kind ? accent : Console.ink)),
                ]),
              ),
            const PopupMenuDivider(),
            for (final n in const [4, 8, 16, 32])
              PopupMenuItem<Object>(
                value: n,
                height: 34,
                child: Text('$n BARS',
                    style: Console.label(10, color: n == _bars ? accent : Console.ink)),
              ),
          ],
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Console.raised,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Console.line),
            ),
            child: Row(
              children: [
                Icon(transitionIcon(_kind), size: 15, color: Console.ink),
                const SizedBox(width: 8),
                Text(_kind.label.toUpperCase(), style: Console.label(9.5, color: Console.ink)),
                const Spacer(),
                Text('$_bars', style: Mag.numerals(13, color: Console.ink)),
                const SizedBox(width: 4),
                Text('BARS', style: Console.label(8)),
                const SizedBox(width: 6),
                const Icon(Icons.expand_more, size: 16, color: Console.quiet),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MixButton extends StatefulWidget {
  const MixButton({
    super.key,
    required this.going,
    required this.arming,
    required this.ready,
    required this.accent,
    required this.from,
    required this.to,
    required this.onTap,
  });
  final bool going, ready;

  /// When a mix waiting for its beat will start, while one is.
  final DateTime? arming;
  final Color accent;
  final String from, to;
  final VoidCallback onTap;

  @override
  State<MixButton> createState() => _MixButtonState();
}

class _MixButtonState extends State<MixButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didUpdateWidget(MixButton old) {
    super.didUpdateWidget(old);
    widget.going || widget.arming != null ? _pulse.repeat(reverse: true) : _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arming = widget.arming;
    final on = widget.ready || widget.going || arming != null;
    final c = widget.accent;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: on
            ? () {
                feel(Feel.commit);
                widget.onTap();
              }
            : null,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) => Container(
            height: 54,
            decoration: BoxDecoration(
              color: !on
                  ? Console.raised
                  : arming != null
                      ? Color.lerp(Console.raised, c.withValues(alpha: 0.5), _pulse.value)
                      : widget.going
                          ? Color.lerp(c.withValues(alpha: 0.55), c, _pulse.value)
                          : c,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? c : Console.line),
              boxShadow: on && !widget.going
                  ? [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 18, spreadRadius: -4)]
                  : null,
            ),
            alignment: Alignment.center,
            child: arming != null
                ? _countdown(arming)
                : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.going ? 'STOP' : 'MIX',
                    style: Mag.headline(26, color: on ? Console.ground : Console.faint, width: 100)),
                if (!widget.going) ...[
                  const SizedBox(width: 12),
                  Text(widget.from, style: Mag.numerals(18, color: on ? Console.ground : Console.faint)),
                  Icon(Icons.arrow_forward, size: 16, color: on ? Console.ground : Console.faint),
                  Text(widget.to, style: Mag.numerals(18, color: on ? Console.ground : Console.faint)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Waiting for the beat: how long, to the tenth — and a press calls it off.
  Widget _countdown(DateTime at) => StreamBuilder<int>(
        stream: Stream.periodic(const Duration(milliseconds: 50), (i) => i),
        builder: (context, _) {
          final left = at.difference(DateTime.now());
          final s = left.isNegative ? 0.0 : left.inMilliseconds / 1000;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('ON THE ONE', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 12),
              SizedBox(
                width: 44,
                child: Text(s.toStringAsFixed(1),
                    style: Mag.numerals(22, color: widget.accent)),
              ),
            ],
          );
        },
      );
}

/// One channel: its three bands, its filter, its fader and its level.
class _Channel extends StatelessWidget {
  const _Channel({required this.booth, required this.deck});
  final Booth booth;
  final engine.Deck deck;


  @override
  Widget build(BuildContext context) {
    final c = Console.deck(deck.name);
    final eq = booth.eqOf(deck);
    final on = deck.track != null;
    final canKill = booth.mixer.canKill;
    final level = identical(deck, booth.a) ? booth.levels.a : booth.levels.b;

    Widget band(int i, String label, double db, double size) {
      final killed = db <= EqSet.killed;
      // On the knob's own travel, as a DJ mixer's: flat straight up (EqSet.knobOf).
      return Knob(
        value: EqSet.knobOf(db),
        min: 0,
        max: 1,
        rest: 0.5,
        label: killed ? 'KILL' : label,
        colour: killed ? Console.a : c,
        size: size,
        tooltip: '${killed ? 'Killed' : db.abs() < 0.05 ? 'Flat' : '${db > 0 ? '+' : ''}${db.toStringAsFixed(1)} dB'}'
            ' · all the way down kills it · double-click resets',
        onChanged: !on || !canKill
            ? null
            : (t) {
                final d = EqSet.dbOf(t);
                booth.setEq(deck, switch (i) { 0 => eq.withLow(d), 1 => eq.withMid(d), _ => eq.withHigh(d) });
              },
      );
    }

    return LayoutBuilder(builder: (context, box) {
    // On a short screen the knobs go two by two, so the fader keeps its throw: in
    // one column they left it forty pixels, its cap on the filter's name.
    final short = box.maxHeight < 440;
    final k = short ? 30.0 : 36.0;
    final gap = short ? 4.0 : 6.0;
    final filter = Knob(
      value: booth.filters[deck] ?? 0,
      label: short ? 'FLT' : 'FILTER',
      colour: c,
      size: k,
      tooltip: 'Left closes the top, right the bottom · double-click resets',
      onChanged: on && booth.mixer.canFilter ? (v) => booth.setFilter(deck, v) : null,
    );
    final knobs = short
        ? [
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [band(2, 'HI', eq.high, k), band(1, 'MID', eq.mid, k)]),
            SizedBox(height: gap),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [band(0, 'LOW', eq.low, k), filter]),
          ]
        : [
            band(2, 'HI', eq.high, k),
            SizedBox(height: gap),
            band(1, 'MID', eq.mid, k),
            SizedBox(height: gap),
            band(0, 'LOW', eq.low, k),
            SizedBox(height: gap + 4),
            filter,
          ];
    return Column(
      children: [
        Text(deck.name, style: Mag.numerals(18, color: c)),
        SizedBox(height: gap + 2),
        ...knobs,
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              VFader(
                value: booth.gainOf(deck),
                colour: c,
                width: 28,
                onChanged: (v) => booth.setGain(deck, v),
                onDoubleTap: () => booth.setGain(deck, 1),
              ),
              const SizedBox(width: 6),
              LayoutBuilder(
                builder: (context, box) => LevelMeter(
                  deck: deck,
                  bands: deck.track == null ? null : booth.bands[deck.track!.id],
                  level: level,
                  width: 8,
                  height: box.maxHeight,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    });
  }
}

class Crossfader extends StatelessWidget {
  const Crossfader({super.key, required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final x = booth.crossfader;
    return Row(
      children: [
        Text('A', style: Mag.numerals(16, color: x <= 0.5 ? Console.a : Console.faint)),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            void at(double dx) => unawaited(booth.setCrossfader(((dx - 14) / (c.maxWidth - 28)).clamp(0.0, 1.0)));
            return MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) => at(d.localPosition.dx),
                onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
                onDoubleTap: () => unawaited(booth.setCrossfader(0.5)),
                child: SizedBox(
                  height: 34,
                  child: CustomPaint(painter: _XPainter(t: x)),
                ),
              ),
            );
          }),
        ),
        const SizedBox(width: 8),
        Text('B', style: Mag.numerals(16, color: x >= 0.5 ? Console.b : Console.faint)),
      ],
    );
  }
}

class _XPainter extends CustomPainter {
  _XPainter({required this.t});
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final l = 14.0, r = size.width - 14;
    canvas.drawLine(Offset(l, y), Offset(r, y), Paint()..color = Console.ground..strokeWidth = 5..strokeCap = StrokeCap.round);
    final tick = Paint()..color = Console.line..strokeWidth = 1;
    for (var i = 0; i <= 8; i++) {
      final x = l + i / 8 * (r - l);
      canvas.drawLine(Offset(x, y + 8), Offset(x, y + (i % 4 == 0 ? 15 : 12)), tick);
    }
    final x = l + t * (r - l);
    // Each side lit by how much of it is in the room.
    canvas.drawLine(Offset(l, y), Offset(x, y), Paint()..color = Console.a.withValues(alpha: 0.35 + 0.5 * (1 - t))..strokeWidth = 3);
    canvas.drawLine(Offset(x, y), Offset(r, y), Paint()..color = Console.b.withValues(alpha: 0.35 + 0.5 * t)..strokeWidth = 3);
    final cap = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: 22, height: 28), const Radius.circular(4));
    canvas.drawRRect(cap, Paint()..color = const Color(0xFF2A2A30));
    canvas.drawRRect(cap, Paint()..style = PaintingStyle.stroke..color = Console.line);
    canvas.drawLine(Offset(x, y - 10), Offset(x, y + 10), Paint()..color = Console.ink..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_XPainter old) => old.t != t;
}
