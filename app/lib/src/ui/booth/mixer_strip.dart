import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../dialogs.dart';
import '../feel.dart';
import '../mag.dart';
import '../mag_parts.dart';
import '../snack.dart';

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
          const SizedBox(height: 8),
          // Or let the booth do it: the queue, record into record, each transition
          // chosen from what is known about the two and landed on the phrase.
          _AutoRow(booth: b),
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


/// The booth mixing the queue on its own, and what it has decided about the next one.
class _AutoRow extends StatelessWidget {
  const _AutoRow({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auto = booth.auto;
    final app = context.read<AppState>();
    final items = app.player?.items ?? const <Track>[];
    final plan = auto.plan;
    final next = auto.next;
    String said;
    if (!auto.running) {
      said = items.isEmpty ? 'Queue some records and the booth can mix them for you.' : 'The queue, record into record.';
    } else if (next == null) {
      said = 'The last record. It plays out.';
    } else {
      final at = auto.goesAt;
      final left = at == null ? null : at - booth.master.position;
      said = 'Next: ${next.displayTitle} · ${plan?.kind.name ?? '…'} over ${plan?.bars ?? '…'} bars'
          '${left == null ? '' : left.isNegative ? ' · going' : ' · in ${left.inSeconds}s'}';
    }
    return Row(
      children: [
        // What this session did, kept: a playlist of the records that carries the
        // moves, and plays them again.
        if (booth.taken.isNotEmpty) ...[
          PressButton(
            label: 'Keep this mix',
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final name = await promptForName(context, 'Keep this mix', 'Mix · ${_today()}');
              if (name == null || name.trim().isEmpty) return;
              try {
                final made = await booth.keepMix(name.trim());
                await app.refreshPlaylists();
                messenger.say(snack(Text('"${made.name}" is in your library, with its moves')));
              } catch (e) {
                messenger.say(problem(e));
              }
            },
          ),
          const SizedBox(width: 6),
        ],
        PressButton(
          label: auto.running ? 'Stop mixing' : 'Let the booth mix',
          loud: !auto.running && items.isNotEmpty,
          onTap: items.isEmpty
              ? null
              : () {
                  feel(Feel.commit);
                  if (auto.running) {
                    auto.stop();
                  } else {
                    // From the record on the master, if it is in the queue; the top otherwise.
                    final on = booth.master.track;
                    final at = on == null ? 0 : items.indexWhere((t) => t.id == on.id).clamp(0, items.length - 1);
                    unawaited(auto.start(items, at: at));
                  }
                },
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(said,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Mag.typewriter(10.5, color: auto.running ? scheme.onSurface : scheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}


String _today() {
  final d = DateTime.now();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]}';
}
