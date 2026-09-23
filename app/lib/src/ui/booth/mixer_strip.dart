import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/booth/booth.dart';
import '../feel.dart';
import '../mag.dart';
import '../mag_parts.dart';

/// What sits between the decks: the fader, and the one button that mixes for you.
///
/// The fader is a ruled slot with a square knob and a detent at the middle — printed,
/// not moulded. Beside it the transition: which kind, over how many bars, and GO,
/// which is the one loud red thing in the room.
class MixerStrip extends StatefulWidget {
  const MixerStrip({super.key, required this.booth, this.compact = false});
  final Booth booth;
  final bool compact;

  @override
  State<MixerStrip> createState() => _MixerStripState();
}

class _MixerStripState extends State<MixerStrip> {
  Transition _kind = Transition.blend;
  int _bars = 16;

  @override
  Widget build(BuildContext context) {
    final b = widget.booth;
    final scheme = Theme.of(context).colorScheme;
    final ready = b.a.loaded && b.b.loaded;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text('A', style: Mag.numerals(20, color: b.crossfader < 0.5 ? scheme.primary : scheme.onSurface)),
              const SizedBox(width: 10),
              Expanded(
                child: _Fader(
                  value: b.crossfader,
                  onChanged: (v) => unawaited(b.setCrossfader(v)),
                ),
              ),
              const SizedBox(width: 10),
              Text('B', style: Mag.numerals(20, color: b.crossfader > 0.5 ? scheme.primary : scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final k in Transition.values)
                _Pick(
                  label: k.name.toUpperCase(),
                  on: _kind == k,
                  onTap: () => setState(() => _kind = k),
                ),
              Text('·', style: Mag.numerals(14, color: scheme.outline)),
              for (final n in const [4, 8, 16, 32])
                _Pick(
                  label: '$n',
                  on: _bars == n,
                  onTap: () => setState(() => _bars = n),
                ),
              Text('BARS', style: Mag.flag(8, color: scheme.onSurfaceVariant)),
              const SizedBox(width: 6),
              PressButton(
                label: b.inTransition ? 'Stop' : 'Go · ${_kind.name}',
                loud: !b.inTransition && ready,
                onTap: !ready
                    ? null
                    : () {
                        feel(Feel.commit);
                        if (b.inTransition) {
                          b.stopTransition();
                        } else {
                          unawaited(b.go(_kind, bars: _bars));
                        }
                      },
              ),
            ],
          ),
          if (!b.mixer.canKill)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('No kills on this device: the fader alone.',
                  style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

/// A word in a ruled box that is either pressed or not.
class _Pick extends StatelessWidget {
  const _Pick({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
        decoration: BoxDecoration(
          color: on ? scheme.onSurface : null,
          border: Border.all(color: scheme.onSurface, width: 1.5),
        ),
        child: Text(label,
            style: Mag.flag(10, color: on ? scheme.surface : scheme.onSurface)
                .copyWith(letterSpacing: 1.0)),
      ),
    );
  }
}

/// The crossfader: a slot, a knob, a detent.
class _Fader extends StatelessWidget {
  const _Fader({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      void at(double dx) {
        var v = (dx / w).clamp(0.0, 1.0);
        // The detent: the middle holds the knob for a few pixels either side.
        if ((v - 0.5).abs() < 0.03) {
          if ((value - 0.5).abs() >= 0.03) feel(Feel.edge);
          v = 0.5;
        }
        onChanged(v);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => at(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
        onTapDown: (d) => at(d.localPosition.dx),
        child: SizedBox(
          height: 40,
          child: CustomPaint(
            painter: _FaderPainter(value: value, ink: scheme.onSurface, accent: scheme.primary, paper: scheme.surface),
          ),
        ),
      );
    });
  }
}

class _FaderPainter extends CustomPainter {
  const _FaderPainter({required this.value, required this.ink, required this.accent, required this.paper});
  final double value;
  final Color ink, accent, paper;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final slot = Paint()..color = ink..strokeWidth = 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), slot);
    // Ticks every tenth, the middle one heavier: the detent.
    for (var i = 0; i <= 10; i++) {
      final x = size.width * i / 10;
      final mid = i == 5;
      canvas.drawLine(Offset(x, y - (mid ? 9 : 5)), Offset(x, y + (mid ? 9 : 5)),
          Paint()..color = ink.withValues(alpha: mid ? 1 : 0.5)..strokeWidth = mid ? 2 : 1);
    }
    // The knob: a square of paper with a hard shadow, a rule across it.
    final x = size.width * value;
    final knob = Rect.fromCenter(center: Offset(x, y), width: 18, height: 30);
    canvas.drawRect(knob.shift(const Offset(2, 2)), Paint()..color = ink);
    canvas.drawRect(knob, Paint()..color = paper);
    canvas.drawRect(knob, Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 1.5);
    canvas.drawLine(Offset(x, knob.top + 6), Offset(x, knob.bottom - 6), Paint()..color = accent..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_FaderPainter old) => old.value != value || old.ink != ink || old.accent != accent;
}
