import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/booth/deck.dart' as engine;
import '../dialogs.dart';
import '../feel.dart';
import '../mag.dart';
import '../mag_parts.dart';
import '../snack.dart';
import 'meters.dart';

/// What sits between the decks: the faders, the bands, and the one button that mixes
/// for you.
///
/// On a phone it is a strip under the first deck — the crossfader, the transition and
/// GO. On a desk it is the middle of the room, laid out the way a mixer is: a channel
/// each side with its own fader, meter and three bands, the crossfader across the
/// foot, and under that the transition by hand and the booth's own mixing.
class MixerStrip extends StatefulWidget {
  const MixerStrip({super.key, required this.booth, this.wide = false});
  final Booth booth;
  final bool wide;

  @override
  State<MixerStrip> createState() => _MixerStripState();
}

class _MixerStripState extends State<MixerStrip> {
  Transition _kind = Transition.blend;
  int _bars = 16;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(12, widget.wide ? 10 : 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: widget.wide ? _desk(context) : _phone(context),
    );
  }

  // ------------------------------------------------------------------ a desk
  Widget _desk(BuildContext context) {
    final b = widget.booth;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Channel(booth: b, deck: b.a),
            _Channel(booth: b, deck: b.b),
          ],
        ),
        if (b.mixer.canFilter) ...[
          const SizedBox(height: 8),
          _Filter(booth: b, deck: b.a),
          _Filter(booth: b, deck: b.b),
        ],
        const SizedBox(height: 8),
        _crossfader(context),
        const SizedBox(height: 8),
        _transition(context, wide: true),
        const SizedBox(height: 10),
        Divider(height: 1, color: scheme.onSurface.withValues(alpha: 0.15)),
        const SizedBox(height: 8),
        _AutoPanel(booth: b),
      ],
    );
  }

  // ------------------------------------------------------------------ a phone
  Widget _phone(BuildContext context) {
    final b = widget.booth;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _crossfader(context),
        const SizedBox(height: 8),
        _transition(context),
        const SizedBox(height: 8),
        _AutoPanel(booth: b),
        if (!b.mixer.canKill)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('No kills on this device: the fader alone.',
                style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
          ),
      ],
    );
  }

  Widget _crossfader(BuildContext context) {
    final b = widget.booth;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text('A',
            style: Mag.numerals(20,
                color: b.crossfader < 0.5 ? scheme.primary : scheme.onSurface)),
        const SizedBox(width: 10),
        Expanded(
          child: _Fader(
            value: b.crossfader,
            onChanged: (v) => unawaited(b.setCrossfader(v)),
          ),
        ),
        const SizedBox(width: 10),
        Text('B',
            style: Mag.numerals(20,
                color: b.crossfader > 0.5 ? scheme.primary : scheme.onSurface)),
      ],
    );
  }

  Widget _transition(BuildContext context, {bool wide = false}) {
    final b = widget.booth;
    final scheme = Theme.of(context).colorScheme;
    final ready = b.a.loaded && b.b.loaded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('by hand · ${b.master.name} into ${b.other(b.master).name}',
                style: Mag.flag(8, color: scheme.onSurfaceVariant)),
          ),
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
              label: b.inTransition ? 'Stop' : 'Go',
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
      ],
    );
  }
}

/// One channel of the mixer: its three bands, its fader, its meter.
class _Channel extends StatelessWidget {
  const _Channel({required this.booth, required this.deck});
  final Booth booth;
  final engine.Deck deck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final eq = booth.eqOf(deck);
    final t = deck.track;
    final level = identical(deck, booth.a) ? booth.levels.a : booth.levels.b;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(deck.name,
            style: Mag.numerals(16,
                color:
                    identical(booth.master, deck) ? scheme.primary : scheme.onSurface)),
        const SizedBox(height: 6),
        if (booth.mixer.canKill)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, label, db) in [
                (0, 'LOW', eq.low),
                (1, 'MID', eq.mid),
                (2, 'HIGH', eq.high),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: EqKnob(
                    label: label,
                    db: db,
                    onChanged: t == null
                        ? (_) {}
                        : (v) => booth.setEq(
                            deck,
                            switch (i) {
                              0 => eq.withLow(v),
                              1 => eq.withMid(v),
                              _ => eq.withHigh(v),
                            }),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChannelFader(
              value: booth.gainOf(deck),
              onChanged: (v) => booth.setGain(deck, v),
              height: 96,
            ),
            const SizedBox(width: 4),
            LevelMeter(
              deck: deck,
              bands: t == null ? null : booth.bands[t.id],
              level: level,
              height: 96,
            ),
          ],
        ),
      ],
    );
  }
}

/// A deck's filter: closed to the left, open in the middle, closed to the right.
class _Filter extends StatelessWidget {
  const _Filter({required this.booth, required this.deck});
  final Booth booth;
  final engine.Deck deck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = booth.filters[deck] ?? 0;
    return Row(
      children: [
        SizedBox(
          width: 54,
          child: Text('FILTER ${deck.name}',
              style: Mag.flag(7.5, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: CentreSlider(
            value: v,
            onChanged: deck.track == null ? null : (x) => booth.setFilter(deck, x),
          ),
        ),
      ],
    );
  }
}

/// The booth mixing the queue on its own: what it has decided, how long there is,
/// and the three things a hand does about it — go now, not that one, stop.
class _AutoPanel extends StatelessWidget {
  const _AutoPanel({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auto = booth.auto;
    final app = context.watch<AppState>();
    final items = app.player?.items ?? const <Track>[];
    final plan = auto.plan;
    final next = auto.next;
    final left = auto.timeToGo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('the booth mixes', style: Mag.flag(8, color: scheme.onSurfaceVariant)),
            const Spacer(),
            if (booth.taken.isNotEmpty)
              PressButton(label: 'Keep this mix', onTap: () => _keep(context)),
          ],
        ),
        const SizedBox(height: 4),
        // Whether it takes the queue as it stands or picks what follows best.
        Row(
          children: [
            _Pick(
              label: auto.pickBest ? 'ITS OWN ORDER' : 'THE QUEUE\'S ORDER',
              on: auto.pickBest,
              onTap: () {
                feel(Feel.pick);
                auto.chooseForYourself(!auto.pickBest);
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                auto.pickBest
                    ? 'Of what is left, whichever follows best.'
                    : 'In the order they are queued.',
                style: Mag.typewriter(10, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        if (!auto.running)
          Row(
            children: [
              PressButton(
                label: 'Let the booth mix',
                loud: items.isNotEmpty,
                onTap: items.isEmpty
                    ? null
                    : () {
                        feel(Feel.commit);
                        final on = booth.master.track;
                        final at = on == null
                            ? 0
                            : items
                                .indexWhere((t) => t.id == on.id)
                                .clamp(0, items.length - 1);
                        unawaited(auto.start(items, at: at));
                      },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  items.isEmpty
                      ? 'Queue some records and the booth can mix them for you.'
                      : 'The queue, record into record: each transition chosen from '
                          'the two songs and landed on the phrase.',
                  style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      next == null
                          ? 'The last record. It plays out.'
                          : 'Next · ${next.displayTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.title(13, color: scheme.onSurface),
                    ),
                    if (next != null)
                      Text(
                        [
                          '${plan?.kind.name ?? '…'} over ${plan?.bars ?? '…'} bars',
                          if (auto.replaying) 'as it was kept',
                          if (auto.after != null) 'then ${auto.after!.displayTitle}',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (next != null && left != null)
                Text(
                  left.isNegative ? 'GOING' : _countdown(left),
                  style: Mag.numerals(22,
                      color: left.isNegative || left.inSeconds < 16
                          ? scheme.primary
                          : scheme.onSurface),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // The run up to it, as a rule that fills.
          ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: LinearProgressIndicator(
              value: auto.toGo,
              minHeight: 4,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              PressButton(
                label: 'Mix now',
                loud: true,
                onTap: next == null || booth.inTransition
                    ? null
                    : () {
                        feel(Feel.commit);
                        unawaited(auto.mixNow());
                      },
              ),
              PressButton(
                label: 'Not that one',
                onTap: next == null || booth.inTransition
                    ? null
                    : () {
                        feel(Feel.pick);
                        unawaited(auto.dropNext());
                      },
              ),
              PressButton(
                label: 'Stop mixing',
                onTap: () {
                  feel(Feel.warn);
                  auto.stop();
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _countdown(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '${s}s';
  }

  Future<void> _keep(BuildContext context) async {
    final app = context.read<AppState>();
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
  }
}

String _today() {
  final d = DateTime.now();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${d.day} ${months[d.month - 1]}';
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
            painter: _FaderPainter(
                value: value,
                ink: scheme.onSurface,
                accent: scheme.primary,
                paper: scheme.surface),
          ),
        ),
      );
    });
  }
}

class _FaderPainter extends CustomPainter {
  const _FaderPainter(
      {required this.value,
      required this.ink,
      required this.accent,
      required this.paper});
  final double value;
  final Color ink, accent, paper;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
        Offset(0, y), Offset(size.width, y), Paint()..color = ink..strokeWidth = 2);
    for (var i = 0; i <= 10; i++) {
      final x = size.width * i / 10;
      final mid = i == 5;
      canvas.drawLine(Offset(x, y - (mid ? 9 : 5)), Offset(x, y + (mid ? 9 : 5)),
          Paint()
            ..color = ink.withValues(alpha: mid ? 1 : 0.5)
            ..strokeWidth = mid ? 2 : 1);
    }
    final x = size.width * value;
    final knob = Rect.fromCenter(center: Offset(x, y), width: 18, height: 30);
    canvas.drawRect(knob.shift(const Offset(2, 2)), Paint()..color = ink);
    canvas.drawRect(knob, Paint()..color = paper);
    canvas.drawRect(knob,
        Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 1.5);
    canvas.drawLine(Offset(x, knob.top + 6), Offset(x, knob.bottom - 6),
        Paint()..color = accent..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      old.value != value || old.ink != ink || old.accent != accent;
}
