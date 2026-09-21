import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/equalizer.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'motion.dart';
import 'theme.dart';

/// The tone controls: the front of a hi-fi separates' graphic equalizer, as the
/// magazine would have printed it in the buyer's guide.
///
/// A response curve on graph paper at the top, which is the thing being edited and the
/// only honest picture of it. Under it, two ways of drawing the curve — a pair of amp
/// knobs for somebody who wants "more bass", ten faders for somebody who wants 2 kHz —
/// which are one setting and not two: the knobs move the faders. Then the curves that
/// come with it, as stickers, and the ones you named yourself; and the pre-amplifier,
/// with the switch that stops a boosted curve from crackling.
class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = context.read<AppState>().equalizer;
    return PlayerScaffold(
      measure: 760,
      appBar: AppBar(title: const Text('Equalizer')),
      body: ListenableBuilder(
        listenable: eq,
        builder: (context, _) => _Faceplate(eq: eq),
      ),
    );
  }
}

Future<void> openEqualizer(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const EqualizerPage()));

class _Faceplate extends StatefulWidget {
  const _Faceplate({required this.eq});
  final Equalizer eq;

  @override
  State<_Faceplate> createState() => _FaceplateState();
}

class _FaceplateState extends State<_Faceplate> {
  bool _knobs = false;

  @override
  void initState() {
    super.initState();
    // Android's equalizer only answers once a song has been put on; the page may have
    // been opened before that and again after.
    if (!widget.eq.engine.available) {
      widget.eq.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final eq = widget.eq;
    final scheme = Theme.of(context).colorScheme;
    final there = eq.engine.available;
    final live = there && eq.enabled && !eq.listeningFlat;
    final bands = eq.engine.bands;
    // A phone with five bands of its own is given the curve at those five, and says so:
    // ten faders on a five-band equalizer would otherwise be a small lie.
    final fitted = there && bands.length != eqFrequencies.length;

    // The lettering on the panel is part of the drawing of it. It grows some with the
    // phone's text size and then stops: at twice the size a row of switches is wider
    // than the phone, and a panel that does not fit is no use at any size. What is
    // *read* on this page — the notes, the explanations — grows all the way.
    Widget lettering(Widget child) =>
        MediaQuery.withClampedTextScaling(maxScaleFactor: 1.25, child: child);

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomForPlayer(context)),
      children: [
        lettering(Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.end,
          runSpacing: 8,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Kicker('Hi-fi · tone controls'),
                const SizedBox(height: 2),
                Text('EQUALIZER', style: Mag.headline(40, color: scheme.onSurface)),
              ],
            ),
            _PowerSwitch(
              on: eq.enabled,
              enabled: there,
              onChanged: eq.setEnabled,
            ),
          ],
        )),
        if (!there) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 2)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NOT YET', style: Mag.flag(11, color: scheme.primary)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(eq.engine.whyNot ?? 'There is no equalizer here.',
                      style: Mag.typewriter(12, color: scheme.onSurface)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        // The curve: what all of the rest of this page is a way of drawing.
        _DrawableCurve(
          eq: eq,
          enabled: there,
          live: live,
          deviceBands: fitted ? [for (final b in bands) b.hz] : const [],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                eq.listeningFlat
                    ? 'As the record is, while you hold.'
                    : !eq.enabled
                        ? 'Switched off. Draw on the graph, or pick a curve.'
                        : eq.current != null
                            ? '“${eq.current!.name}”'
                            : 'A curve of your own.',
                style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
              ),
            ),
            lettering(_HoldToCompare(
              enabled: there && eq.enabled && !eq.isFlat,
              onHold: eq.listenFlat,
            )),
          ],
        ),
        const SizedBox(height: 18),
        lettering(Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: [
            const SectionFlag('Set it by', rule: false),
            _TwoWay(
              left: 'Faders',
              right: 'Knobs',
              onRight: _knobs,
              onChanged: (v) => setState(() => _knobs = v),
            ),
          ],
        )),
        const SizedBox(height: 10),
        Opacity(
          opacity: there ? 1 : 0.45,
          child: IgnorePointer(
            ignoring: !there,
            child: lettering(_knobs ? _Knobs(eq: eq) : _Faders(eq: eq)),
          ),
        ),
        if (fitted)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              "This phone's equalizer has ${bands.length} bands of its own "
              '(${[for (final b in bands) eqLabel(b.hz)].join(', ')} Hz). The curve is '
              'read off at those — the marks on the graph.',
              style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 22),
        const SectionFlag('Curves'),
        const SizedBox(height: 10),
        lettering(_Presets(eq: eq)),
        const SizedBox(height: 22),
        const SectionFlag('Pre-amplifier'),
        const SizedBox(height: 4),
        _Preamp(eq: eq, enabled: there),
      ],
    );
  }
}

// ---------------------------------------------------------------------------- power
/// A rocker switch, the kind with a red stripe that shows when it is on.
class _PowerSwitch extends StatelessWidget {
  const _PowerSwitch({required this.on, required this.enabled, required this.onChanged});
  final bool on;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.35);
    Widget half(String label, bool lit) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          color: lit ? (label == 'ON' ? MuseTheme.masthead : ink) : Colors.transparent,
          child: Text(label,
              textScaler: TextScaler.noScaling,
              style: Mag.flag(11,
                  color: lit
                      ? (label == 'ON' ? Colors.white : scheme.surface)
                      : ink.withValues(alpha: 0.6))),
        );
    return Semantics(
      toggled: on,
      enabled: enabled,
      label: 'Equalizer',
      child: GestureDetector(
        onTap: enabled
            ? () {
                HapticFeedback.mediumImpact();
                onChanged(!on);
              }
            : null,
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: ink, width: 2)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [half('OFF', !on), half('ON', on)],
          ),
        ),
      ),
    );
  }
}

class _TwoWay extends StatelessWidget {
  const _TwoWay(
      {required this.left, required this.right, required this.onRight, required this.onChanged});
  final String left;
  final String right;
  final bool onRight;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget side(String label, bool picked, bool value) => InkWell(
          onTap: () => onChanged(value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: picked ? scheme.onSurface : null,
            child: Text(label.toUpperCase(),
                style: Mag.flag(10, color: picked ? scheme.surface : scheme.onSurface)),
          ),
        );
    return Container(
      decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.5)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [side(left, !onRight, false), side(right, onRight, true)],
      ),
    );
  }
}

/// Held down, the record as it is; let go, the curve again. The only honest way to
/// judge an equalizer is against not having one, a second apart.
class _HoldToCompare extends StatelessWidget {
  const _HoldToCompare({required this.enabled, required this.onHold});
  final bool enabled;
  final Future<void> Function(bool) onHold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.35);
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Hold to hear it without the equalizer',
      excludeSemantics: true,
      child: Listener(
        onPointerDown: enabled ? (_) => onHold(true) : null,
        onPointerUp: (_) => onHold(false),
        onPointerCancel: (_) => onHold(false),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
          decoration: BoxDecoration(border: Border.all(color: ink, width: 1.5)),
          child: Text('HOLD: FLAT', style: Mag.flag(10, color: ink)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------- curve
/// The graph, which is also the fastest way to set the thing: put a finger on it and
/// draw the curve. The band nearest the finger goes to the height of the finger, and a
/// finger dragged across goes through each band it passes, so "less bass, more top" is
/// one stroke rather than ten faders. The faders underneath move with it; they are the
/// same ten numbers.
class _DrawableCurve extends StatefulWidget {
  const _DrawableCurve(
      {required this.eq, required this.enabled, required this.live, required this.deviceBands});
  final Equalizer eq;
  final bool enabled;
  final bool live;
  final List<double> deviceBands;

  @override
  State<_DrawableCurve> createState() => _DrawableCurveState();
}

class _DrawableCurveState extends State<_DrawableCurve> {
  int? _held;

  void _draw(Offset at, Size size) {
    final plot = _CurvePainter.plotOf(size);
    final hz = _CurvePainter.hzAt(at.dx, plot);
    var nearest = 0;
    for (var i = 1; i < eqFrequencies.length; i++) {
      if ((math.log(eqFrequencies[i]) - math.log(hz)).abs() <
          (math.log(eqFrequencies[nearest]) - math.log(hz)).abs()) {
        nearest = i;
      }
    }
    var db = _CurvePainter.dbAt(at.dy, plot).clamp(-eqRange, eqRange);
    // Half-decibel steps and a catch at level, as on the faders.
    db = (db * 2).round() / 2;
    if (db.abs() <= 0.5) db = 0;
    if (nearest != _held || (db == 0 && widget.eq.gains[nearest] != 0)) {
      HapticFeedback.selectionClick();
    }
    if (_held != nearest) setState(() => _held = nearest);
    if (widget.eq.gains[nearest] != db) {
      // Drawing a curve is asking to hear it.
      if (!widget.eq.enabled) widget.eq.setEnabled(true);
      widget.eq.setBand(nearest, db);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 2.4,
      child: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        return Semantics(
          label: 'Response curve. Drag on it to draw the curve.',
          child: Listener(
            // As the finger lands, and wherever it goes: the page underneath scrolls,
            // and a graph that waited to find out whether this was a scroll would be a
            // graph that mostly scrolled.
            onPointerDown: widget.enabled ? (e) => _draw(e.localPosition, size) : null,
            onPointerMove: widget.enabled ? (e) => _draw(e.localPosition, size) : null,
            onPointerUp: (_) => setState(() => _held = null),
            onPointerCancel: (_) => setState(() => _held = null),
            child: GestureDetector(
              // Only here to win the drag, so the list does not take it.
              onVerticalDragUpdate: widget.enabled ? (_) {} : null,
              onHorizontalDragUpdate: widget.enabled ? (_) {} : null,
              child: CustomPaint(
                size: size,
                painter: _CurvePainter(
                  gains: widget.eq.gains,
                  live: widget.live,
                  ink: scheme.onSurface,
                  accent: scheme.primary,
                  paper: scheme.surfaceContainerHighest,
                  deviceBands: widget.deviceBands,
                  held: _held,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _CurvePainter extends CustomPainter {
  const _CurvePainter({
    required this.gains,
    required this.live,
    required this.ink,
    required this.accent,
    required this.paper,
    required this.deviceBands,
    this.held,
  });

  final List<double> gains;
  final bool live;
  final Color ink;
  final Color accent;
  final Color paper;
  final List<double> deviceBands;

  /// The band under a finger, if there is one: ringed, and labelled with what it is at.
  final int? held;

  static final _lo = math.log(20.0), _hi = math.log(20000.0);

  // Where on the panel the graph itself is, and the way back from a point on it to a
  // frequency and a level — shared with whoever is putting a finger on it.
  static Rect plotOf(Size size) => Rect.fromLTRB(28, 6, size.width - 8, size.height - 16);
  static double hzAt(double x, Rect plot) => math.exp(
      _lo + (_hi - _lo) * ((x - plot.left) / plot.width).clamp(0.0, 1.0));
  static double dbAt(double y, Rect plot) =>
      (plot.center.dy - y) / (plot.height / 2) * (eqRange + 2);

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    canvas.drawRect(box, Paint()..color = paper);
    final plot = plotOf(size);
    double x(double hz) => plot.left + plot.width * (math.log(hz) - _lo) / (_hi - _lo);
    double y(double db) => plot.center.dy - plot.height / 2 * (db / (eqRange + 2));

    // Graph paper: a line for every decade and its parts, fainter for the parts.
    final fine = Paint()
      ..color = ink.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    final bold = Paint()
      ..color = ink.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    for (final decade in [10.0, 100.0, 1000.0, 10000.0]) {
      for (var n = 1; n < 10; n++) {
        final hz = decade * n;
        if (hz < 20 || hz > 20000) continue;
        canvas.drawLine(Offset(x(hz), plot.top), Offset(x(hz), plot.bottom), n == 1 ? bold : fine);
      }
    }
    for (final db in [-12.0, -6.0, 6.0, 12.0]) {
      canvas.drawLine(Offset(plot.left, y(db)), Offset(plot.right, y(db)), fine);
    }
    canvas.drawLine(Offset(plot.left, y(0)), Offset(plot.right, y(0)),
        Paint()
          ..color = ink.withValues(alpha: 0.55)
          ..strokeWidth = 1.2);

    void label(String text, Offset at, {bool right = false}) {
      final p = TextPainter(
        text: TextSpan(text: text, style: Mag.typewriter(8.5, color: ink.withValues(alpha: 0.6))),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, at - Offset(right ? p.width : p.width / 2, 0));
      p.dispose();
    }

    for (final hz in [100.0, 1000.0, 10000.0]) {
      label(eqLabel(hz), Offset(x(hz), plot.bottom + 3));
    }
    for (final db in [12.0, 0.0, -12.0]) {
      label(db > 0 ? '+${db.round()}' : '${db.round()}', Offset(plot.left - 4, y(db) - 5),
          right: true);
    }

    // The curve itself, through every point of it rather than only the ten: what the
    // ear is given is the line, not the dots.
    final line = Path();
    const steps = 96;
    for (var i = 0; i <= steps; i++) {
      final hz = math.exp(_lo + (_hi - _lo) * i / steps);
      final at = Offset(x(hz), y(eqCurveAt(gains, hz)));
      i == 0 ? line.moveTo(at.dx, at.dy) : line.lineTo(at.dx, at.dy);
    }
    if (live) {
      final under = Path.from(line)
        ..lineTo(plot.right, y(0))
        ..lineTo(plot.left, y(0))
        ..close();
      canvas.drawPath(under, Paint()..color = accent.withValues(alpha: 0.13));
    }
    canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = live ? 2.6 : 1.6
          ..strokeJoin = StrokeJoin.round
          ..color = live ? accent : ink.withValues(alpha: 0.4));

    for (var i = 0; i < eqFrequencies.length; i++) {
      canvas.drawCircle(Offset(x(eqFrequencies[i]), y(gains[i])), live ? 3 : 2.2,
          Paint()..color = live ? accent : ink.withValues(alpha: 0.45));
    }
    final h = held;
    if (h != null) {
      final at = Offset(x(eqFrequencies[h]), y(gains[h]));
      canvas.drawCircle(
          at,
          9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = ink);
      final g = gains[h];
      final said = '${eqLabel(eqFrequencies[h])}  '
          '${g.abs() < 0.05 ? '0' : '${g > 0 ? '+' : '-'}${g.abs().toStringAsFixed(1)}'} dB';
      final p = TextPainter(
        text: TextSpan(text: said, style: Mag.typewriter(11, color: paper, bold: true)),
        textDirection: TextDirection.ltr,
      )..layout();
      // Above the finger where there is room, below it where there is not, and never
      // off either side.
      final w = p.width + 12, hgt = p.height + 6;
      final left = (at.dx - w / 2).clamp(plot.left, plot.right - w);
      final top = at.dy - 16 - hgt < plot.top ? at.dy + 16 : at.dy - 16 - hgt;
      canvas.drawRect(Rect.fromLTWH(left, top, w, hgt), Paint()..color = ink);
      p.paint(canvas, Offset(left + 6, top + 3));
      p.dispose();
    }
    // Where this phone's own bands fall, when it has fewer than ten.
    for (final hz in deviceBands) {
      final at = Offset(x(hz.clamp(20.0, 20000.0)), y(eqCurveAt(gains, hz)));
      canvas.drawRect(
          Rect.fromCenter(center: at, width: 9, height: 9),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = ink);
    }
    canvas.drawRect(
        box.deflate(0.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ink);
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.live != live ||
      old.held != held ||
      old.ink != ink ||
      old.accent != accent ||
      old.deviceBands.length != deviceBands.length ||
      !_same(old.gains, gains);

  static bool _same(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

String _spoken(num db) => '${db > 0 ? '+' : ''}${db.toStringAsFixed(1)} decibels';

// ---------------------------------------------------------------------------- faders
class _Faders extends StatelessWidget {
  const _Faders({required this.eq});
  final Equalizer eq;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 236,
        child: Row(
          children: [
            for (var i = 0; i < eqFrequencies.length; i++)
              Expanded(
                child: _Fader(
                  label: eqLabel(eqFrequencies[i]),
                  value: eq.gains[i],
                  onChanged: (db) => eq.setBand(i, db),
                ),
              ),
          ],
        ),
      );
}

/// One fader: a slot, a scale beside it, a red cap with a white line across. Pulled
/// through zero it catches there, the way a real one has a detent at centre.
class _Fader extends StatefulWidget {
  const _Fader({required this.label, required this.value, required this.onChanged});
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_Fader> createState() => _FaderState();
}

class _FaderState extends State<_Fader> {
  bool _atZero = false;

  void _to(double dy, double travel) {
    var db = (eqRange - (dy / travel) * eqRange * 2).clamp(-eqRange, eqRange);
    // Half-decibel steps, and a catch at centre.
    db = (db * 2).round() / 2;
    final zero = db.abs() <= 0.5;
    if (zero) db = 0;
    if (zero && !_atZero) HapticFeedback.selectionClick();
    _atZero = zero;
    if (db != widget.value) widget.onChanged(db);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = widget.value;
    return Semantics(
      slider: true,
      label: '${widget.label} hertz',
      value: _spoken(v),
      // What one step either way would make it: a screen reader says it before it is
      // done, and a slider that can be nudged has to be able to answer.
      increasedValue: _spoken((v + 1).clamp(-eqRange, eqRange)),
      decreasedValue: _spoken((v - 1).clamp(-eqRange, eqRange)),
      onIncrease: () => widget.onChanged((v + 1).clamp(-eqRange, eqRange)),
      onDecrease: () => widget.onChanged((v - 1).clamp(-eqRange, eqRange)),
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: 16,
            child: Text(
              v.abs() < 0.05 ? '' : '${v > 0 ? '+' : '-'}${v.abs().toStringAsFixed(v % 1 == 0 ? 0 : 1)}',
              textScaler: TextScaler.noScaling,
              style: Mag.typewriter(9.5, color: scheme.primary, bold: true),
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              const cap = 22.0;
              final travel = box.maxHeight - cap;
              void at(Offset local) => _to(local.dy - cap / 2, travel);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (d) => at(d.localPosition),
                onVerticalDragUpdate: (d) => at(d.localPosition),
                onTapDown: (d) => at(d.localPosition),
                onDoubleTap: () => widget.onChanged(0),
                child: CustomPaint(
                  size: Size(box.maxWidth, box.maxHeight),
                  painter: _FaderPainter(
                    value: v,
                    cap: cap,
                    ink: scheme.onSurface,
                    capColour: MuseTheme.masthead,
                    slot: scheme.surfaceContainerHighest,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 4),
          Text(widget.label,
              textScaler: TextScaler.noScaling,
              style: Mag.flag(8.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _FaderPainter extends CustomPainter {
  const _FaderPainter({
    required this.value,
    required this.cap,
    required this.ink,
    required this.capColour,
    required this.slot,
  });
  final double value;
  final double cap;
  final Color ink;
  final Color capColour;
  final Color slot;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final top = cap / 2, bottom = size.height - cap / 2;
    // The scale: a tick a decibel... every three, with a longer one at centre.
    final tick = Paint()
      ..color = ink.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    for (var db = -12; db <= 12; db += 3) {
      final y = top + (bottom - top) * (eqRange - db) / (eqRange * 2);
      final long = db == 0;
      canvas.drawLine(Offset(cx - (long ? 11 : 7), y), Offset(cx - 4, y),
          long ? (Paint()..color = ink..strokeWidth = 1.4) : tick);
      canvas.drawLine(Offset(cx + 4, y), Offset(cx + (long ? 11 : 7), y),
          long ? (Paint()..color = ink..strokeWidth = 1.4) : tick);
    }
    // The slot.
    final groove = RRect.fromRectAndRadius(
        Rect.fromLTRB(cx - 2, top - 4, cx + 2, bottom + 4), const Radius.circular(2));
    canvas.drawRRect(groove, Paint()..color = ink.withValues(alpha: 0.85));
    // The cap, with its shadow a little down and to the right.
    final y = top + (bottom - top) * (eqRange - value) / (eqRange * 2);
    final w = math.min(size.width - 6, 24.0);
    final body = Rect.fromCenter(center: Offset(cx, y), width: w, height: cap);
    canvas.drawRect(body.shift(const Offset(1.5, 2)), Paint()..color = ink.withValues(alpha: 0.25));
    canvas.drawRect(body, Paint()..color = capColour);
    canvas.drawRect(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = ink);
    canvas.drawLine(Offset(body.left + 3, y), Offset(body.right - 3, y),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      old.value != value || old.ink != ink || old.slot != slot;
}

// ---------------------------------------------------------------------------- knobs
class _Knobs extends StatelessWidget {
  const _Knobs({required this.eq});
  final Equalizer eq;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 236,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Knob(label: 'Bass', value: eq.bass, onChanged: eq.setBass),
            _Knob(label: 'Treble', value: eq.treble, onChanged: eq.setTreble),
          ],
        ),
      );
}

/// An amplifier's knob: turned by dragging up and down, which is how every knob on a
/// touch screen that works is turned — round and round needs a finger that can see
/// through itself.
class _Knob extends StatelessWidget {
  const _Knob({required this.label, required this.value, required this.onChanged});
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      slider: true,
      label: label,
      value: _spoken(value),
      increasedValue: _spoken((value + 1).clamp(-eqRange, eqRange)),
      decreasedValue: _spoken((value - 1).clamp(-eqRange, eqRange)),
      onIncrease: () => onChanged((value + 1).clamp(-eqRange, eqRange)),
      onDecrease: () => onChanged((value - 1).clamp(-eqRange, eqRange)),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) {
          var next = (value - d.delta.dy * 0.12 + d.delta.dx * 0.06).clamp(-eqRange, eqRange);
          if (next.abs() < 0.35) {
            if (value.abs() >= 0.35) HapticFeedback.selectionClick();
            next = next.abs() < 0.15 ? 0 : next;
          }
          onChanged(next);
        },
        onDoubleTap: () => onChanged(0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CustomPaint(
              size: const Size(132, 132),
              painter: _KnobPainter(
                  value: value, ink: scheme.onSurface, paper: scheme.surface),
            ),
            const SizedBox(height: 8),
            Text(label.toUpperCase(), style: Mag.headline(20, color: scheme.onSurface)),
            Text(
              value.abs() < 0.05
                  ? 'level'
                  : '${value > 0 ? '+' : '-'}${value.abs().toStringAsFixed(1)} dB',
              style: Mag.typewriter(11, color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter({required this.value, required this.ink, required this.paper});
  final double value;
  final Color ink;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    // Three hundred degrees of travel, with the gap at the bottom.
    const sweep = math.pi * 5 / 3;
    const start = math.pi / 2 + (2 * math.pi - sweep) / 2;
    for (var i = 0; i <= 24; i++) {
      final a = start + sweep * i / 24;
      final long = i % 6 == 0;
      final from = c + Offset(math.cos(a), math.sin(a)) * (r - (long ? 12 : 8));
      final to = c + Offset(math.cos(a), math.sin(a)) * (r - 2);
      canvas.drawLine(
          from,
          to,
          Paint()
            ..color = ink.withValues(alpha: long ? 0.9 : 0.4)
            ..strokeWidth = long ? 1.8 : 1);
    }
    final body = r - 20;
    canvas.drawCircle(c + const Offset(2, 3), body, Paint()..color = ink.withValues(alpha: 0.22));
    canvas.drawCircle(c, body, Paint()..color = ink);
    canvas.drawCircle(
        c,
        body - 6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = paper.withValues(alpha: 0.25));
    final a = start + sweep * (value + eqRange) / (eqRange * 2);
    final dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(
        c + dir * (body * 0.35),
        c + dir * (body - 4),
        Paint()
          ..color = MuseTheme.masthead
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.value != value || old.ink != ink;
}

// ---------------------------------------------------------------------------- presets
class _Presets extends StatelessWidget {
  const _Presets({required this.eq});
  final Equalizer eq;

  Future<void> _saveAs(BuildContext context) async {
    final name = await showDialog<String>(
        context: context, builder: (_) => const _NameDialog());
    if (name != null && name.trim().isNotEmpty) await eq.saveAs(name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = eq.current;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (i, p) in eq.presets.indexed)
          _Sticker(
            label: p.name,
            picked: now?.name == p.name,
            custom: p.custom,
            turn: still(context) ? 0 : ((i * 37) % 5 - 2) * 0.006,
            onTap: () {
              HapticFeedback.selectionClick();
              eq.use(p);
            },
            onForget: p.custom ? () => eq.forget(p) : null,
          ),
        // Only when there is a curve that is not already one of them.
        if (now == null && !eq.isFlat)
          InkWell(
            onTap: () => _saveAs(context),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
              decoration: BoxDecoration(
                border: Border.all(
                    color: scheme.primary, width: 1.5, style: BorderStyle.solid),
              ),
              child: Text('+ KEEP THIS ONE', style: Mag.flag(10.5, color: scheme.primary)),
            ),
          ),
      ],
    );
  }

  static bool still(BuildContext context) => stillness(context);
}

class _Sticker extends StatelessWidget {
  const _Sticker({
    required this.label,
    required this.picked,
    required this.custom,
    required this.turn,
    required this.onTap,
    this.onForget,
  });
  final String label;
  final bool picked;
  final bool custom;
  final double turn;
  final VoidCallback onTap;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ground = picked
        ? MuseTheme.masthead
        : custom
            ? MuseTheme.highlighter
            : scheme.surfaceContainerHighest;
    final ink = picked
        ? Colors.white
        : custom
            ? const Color(0xFF141210)
            : scheme.onSurface;
    return Transform.rotate(
      angle: turn,
      child: Semantics(
        button: true,
        selected: picked,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: ground,
          child: InkWell(
            onTap: onTap,
            onLongPress: onForget == null
                ? null
                : () async {
                    final sure = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('Forget “$label”?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Keep it')),
                          FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('Forget')),
                        ],
                      ),
                    );
                    if (sure == true) onForget!();
                  },
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
              decoration: BoxDecoration(
                border: Border.all(
                    color: picked ? MuseTheme.masthead : scheme.onSurface, width: 1.5),
              ),
              child: Text(label.toUpperCase(), style: Mag.flag(10.5, color: ink)),
            ),
          ),
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Keep this curve'),
        content: TextField(
          controller: _name,
          autofocus: true,
          maxLength: 24,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              labelText: 'Called', hintText: 'Kitchen speaker, the car, headphones…'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(_name.text),
              child: const Text('Keep')),
        ],
      );
}

// ---------------------------------------------------------------------------- preamp
class _Preamp extends StatelessWidget {
  const _Preamp({required this.eq, required this.enabled});
  final Equalizer eq;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typed = Mag.typewriter(11, color: scheme.onSurfaceVariant);
    final total = eq.preamp + eq.headroom;
    String db(double v) =>
        v.abs() < 0.05 ? '0 dB' : '${v > 0 ? '+' : '-'}${v.abs().toStringAsFixed(1)} dB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: eq.preamp,
                min: -eqRange,
                max: eqRange,
                divisions: (eqRange * 4).round(),
                label: db(eq.preamp),
                onChanged: enabled ? eq.setPreamp : null,
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(db(eq.preamp),
                  textAlign: TextAlign.right,
                  style: Mag.typewriter(12, color: scheme.onSurface, bold: true)),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: eq.protect,
          onChanged: enabled ? eq.setProtect : null,
          title: const Text('Keep it from crackling'),
          subtitle: Text(
            eq.protect
                ? (eq.headroom < -0.05
                    ? 'Turned down ${db(-eq.headroom).substring(1)} to make room for '
                        'what the curve turns up. Going out at ${db(total)} overall.'
                    : 'Nothing is turned up, so nothing needs making room for.')
                : 'Off: a curve that turns anything up can push loud records past '
                    'what they can hold, which is heard as a crackle.',
            style: typed,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: PressButton(
            label: 'Back to flat',
            onTap: eq.isFlat
                ? null
                : () async {
                    await eq.setPreamp(0);
                    await eq.use(eqPresets.first);
                  },
          ),
        ),
      ],
    );
  }
}
