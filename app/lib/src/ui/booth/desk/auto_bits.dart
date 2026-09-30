import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/automix.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/dj_set.dart';
import '../../../state/booth/set_planner.dart';
import '../../artwork.dart';
import '../../feel.dart';
import '../../mag.dart';
import 'console.dart';

/// The Auto DJ's parts that the desk's top bar, the SET view and the phone's card
/// all show the same way: what it is doing in one word, the room's word on the set
/// (more, less, like this, something different), KEEP GOING and where from, the
/// order and the curve, the UNDO after anything it changed by itself.

// ------------------------------------------------------------------ in one word
/// What the Auto DJ is doing, as the bars say it: a word, a line, and the colour
/// they are drawn in.
({String word, String line, Color colour}) autoSays(Booth booth, Color accent) {
  final auto = booth.auto;
  final next = auto.next;
  final mix = booth.mixing;
  switch (auto.state) {
    case AutoState.off:
      return (word: 'OFF', line: '', colour: Console.faint);
    case AutoState.mixing:
      if (mix != null) {
        final into = booth.other(booth.master).track?.displayTitle ?? mix.to;
        return (word: 'MIXING', line: '${mix.kind.label} into $into', colour: accent);
      }
      if (!booth.busy) {
        return (word: 'BY HAND', line: 'mixing into ${next?.displayTitle ?? 'the other record'}', colour: accent);
      }
      return (word: 'MIXING', line: next?.displayTitle ?? '', colour: accent);
    case AutoState.waiting:
      return (word: 'PAUSED', line: 'press play and the Auto DJ carries on', colour: Console.b);
    case AutoState.holding:
      return (
        word: 'HOLDING',
        line: 'the last bars go round until ${next?.displayTitle ?? 'the next record'} is ready',
        colour: Console.b,
      );
    case AutoState.preparing:
      return (
        word: 'NEXT',
        line: next == null ? '' : next.displayTitle,
        colour: Console.quiet,
      );
    case AutoState.ready:
      return (word: 'NEXT', line: next?.displayTitle ?? '', colour: accent);
    case AutoState.last:
      return (
        word: 'LAST',
        line: auto.fill ? 'keeping going — finding the next one' : 'nothing after this one',
        colour: Console.quiet,
      );
  }
}

/// The word and the line, with what the automix is working on under them.
class AutoStateLine extends StatelessWidget {
  const AutoStateLine({super.key, required this.booth, this.onTap, this.titleSize = 15});
  final Booth booth;
  final VoidCallback? onTap;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final says = autoSays(booth, accent);
    final plan = auto.planned;
    final title = auto.state == AutoState.ready || auto.state == AutoState.preparing;
    final under = switch (auto.state) {
      AutoState.preparing => auto.working ?? 'getting it ready',
      AutoState.ready when plan != null =>
        '${plan.kind.label} · ${plan.bars} bars${auto.steered ? ' · by hand' : ''}',
      _ => null,
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              _Word(says.word, says.colour),
              const SizedBox(width: 8),
              Flexible(
                child: Text(says.line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: title ? Mag.title(titleSize, color: Console.ink) : Mag.typewriter(11, color: Console.quiet)),
              ),
            ]),
            if (under != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (plan != null && auto.state == AutoState.ready) ...[
                    Icon(transitionIcon(plan.kind), size: 12, color: auto.steered ? accent : Console.quiet),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(under,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.faint)),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _Word extends StatelessWidget {
  const _Word(this.word, this.colour);
  final String word;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: colour.withValues(alpha: 0.8)),
          color: colour.withValues(alpha: 0.12),
        ),
        child: Text(word, style: Console.label(8, color: colour)),
      );
}

/// The countdown to the next transition — NOW while one runs or is due.
class AutoCountdown extends StatelessWidget {
  const AutoCountdown({super.key, required this.booth, this.size = 20});
  final Booth booth;
  final double size;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final left = auto.timeToGo;
    final soon = left != null && (left.isNegative || left.inSeconds < 16);
    final text = !auto.running
        ? ''
        : booth.busy || (left?.isNegative ?? false)
            ? 'NOW'
            : auto.state == AutoState.waiting || auto.state == AutoState.holding || left == null
                ? '—'
                : _count(left);
    return Text(text, textAlign: TextAlign.right, style: Mag.numerals(size, color: soon ? accent : Console.ink));
  }

  static String _count(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '$s';
  }
}

// ------------------------------------------------------------------ the hands on it
/// SKIP, MIX NOW, NOT NOW, and a phrase longer or shorter — the hands on the next
/// transition.
class AutoHands extends StatelessWidget {
  const AutoHands({super.key, required this.booth, this.height = 30, this.labels = false, this.phrases = true});
  final Booth booth;
  final double height;
  final bool labels;
  final bool phrases;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final next = auto.next;
    final can = auto.running && !booth.inTransition && next != null;
    Widget pad(IconData icon, String label, String tip, VoidCallback? on) => Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Pad(
            icon: icon,
            label: labels ? label : null,
            height: height,
            width: labels ? null : 36,
            tooltip: tip,
            onTap: on,
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      pad(Icons.skip_next, 'SKIP', 'Skip: into the next record at the next bar, over a few (S)',
          can
              ? () {
                  feel(Feel.commit);
                  unawaited(auto.skip());
                }
              : null),
      pad(Icons.fast_forward, 'NOW', 'Mix now, the planned way (M)',
          can
              ? () {
                  feel(Feel.commit);
                  unawaited(auto.mixNow());
                }
              : null),
      pad(Icons.low_priority, 'NOT NOW', 'Not that one: it goes to the end of the queue (N)',
          can ? () => unawaited(auto.dropNext()) : null),
      if (phrases) ...[
        pad(Icons.remove, 'SOONER', 'Eight bars sooner (D)', can ? () => auto.extend(-2) : null),
        pad(Icons.add, 'LONGER', 'Eight bars more of this one (E)', can ? () => auto.extend(2) : null),
      ],
    ]);
  }
}

/// The room's word: less energy, more, more like this, something different — and
/// back to the plan. The needle between the arrows is where the room has put it.
class RoomPads extends StatelessWidget {
  const RoomPads({super.key, required this.auto, this.height = 26, this.words = true});
  final AutoMix auto;
  final double height;
  final bool words;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final off = auto.energyOffset;
    final steered = off != 0 || auto.likeThis != null || auto.different;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (words) ...[Text('ROOM', style: Console.label(8)), const SizedBox(width: 6)],
      Pad(
        icon: Icons.south,
        height: height,
        width: 30,
        tooltip: 'Less energy from here (Alt+↓)',
        lit: off < 0,
        colour: accent,
        onTap: auto.running ? () => auto.nudgeEnergy(-1) : null,
      ),
      SizedBox(
        width: 34,
        child: Text(
          off == 0 ? '±0' : '${off > 0 ? '+' : '−'}${(off.abs() * 100).round()}',
          textAlign: TextAlign.center,
          style: Mag.typewriter(10, color: off == 0 ? Console.faint : accent, bold: off != 0),
        ),
      ),
      Pad(
        icon: Icons.north,
        height: height,
        width: 30,
        tooltip: 'More energy from here (Alt+↑)',
        lit: off > 0,
        colour: accent,
        onTap: auto.running ? () => auto.nudgeEnergy(1) : null,
      ),
      const SizedBox(width: 4),
      Pad(
        icon: Icons.graphic_eq,
        label: words ? 'LIKE THIS' : null,
        height: height,
        lit: auto.likeThis != null,
        colour: accent,
        tooltip: 'More like the record on now',
        onTap: auto.running ? auto.moreLikeThis : null,
      ),
      const SizedBox(width: 4),
      Pad(
        icon: Icons.call_split,
        label: words ? 'DIFFERENT' : null,
        height: height,
        lit: auto.different,
        colour: accent,
        tooltip: 'Something different from here',
        onTap: auto.running ? auto.somethingDifferent : null,
      ),
      if (steered) ...[
        const SizedBox(width: 4),
        Pad(
          icon: Icons.restart_alt,
          height: height,
          width: 30,
          tooltip: 'Back to the plan: the room\'s word taken back',
          onTap: auto.steerNeutral,
        ),
      ],
    ]);
  }
}

/// KEEP GOING, and where it keeps going from — a tap switches it, the arrow picks
/// the pool: the set's own, the whole library, a playlist.
class KeepGoingPad extends StatelessWidget {
  const KeepGoingPad({super.key, required this.auto, this.height = 26, this.showSource = true});
  final AutoMix auto;
  final double height;
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Pad(
        icon: Icons.all_inclusive,
        label: showSource ? 'KEEP GOING · ${auto.fillSource.label}' : 'KEEP GOING',
        height: height,
        lit: auto.fill,
        colour: accent,
        tooltip: auto.fill
            ? 'Keeping going from ${auto.fillSource.label.toLowerCase()}: two records always lined up'
            : 'At the end of the queue, keep going from ${auto.fillSource.label.toLowerCase()}',
        onTap: () {
          feel(Feel.pick);
          auto.keepGoing(!auto.fill);
        },
      ),
      const SizedBox(width: 2),
      Pad(
        icon: Icons.arrow_drop_down,
        height: height,
        width: 26,
        tooltip: 'Where to keep going from',
        onTap: () => pickFillSource(context, auto),
      ),
    ]);
  }
}

/// Where KEEP GOING takes its records from.
Future<void> pickFillSource(BuildContext context, AutoMix auto) async {
  final app = context.read<AppState>();
  final box = context.findRenderObject() as RenderBox?;
  final at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
  final lists = [for (final p in app.playlists) if (p.kind != 'favourites') p].take(14).toList();
  final choice = await showMenu<Object>(
    context: context,
    color: Console.raised,
    position: RelativeRect.fromLTRB(at.dx, at.dy + 30, at.dx, at.dy),
    items: [
      if (auto.set != null)
        PopupMenuItem(value: 'set', child: Text('The set\'s own pool — ${auto.set!.source.label.toLowerCase()}', style: Mag.typewriter(12, color: Console.ink))),
      PopupMenuItem(value: 'library', child: Text('The whole library', style: Mag.typewriter(12, color: Console.ink))),
      for (final p in lists)
        PopupMenuItem(value: p, child: Text(p.name, style: Mag.typewriter(12, color: Console.ink))),
    ],
  );
  if (choice == null) return;
  if (choice == 'set') {
    auto.fillFromSource(null);
  } else if (choice == 'library') {
    auto.fillFromSource(SetSource.wholeLibrary);
  } else if (choice is Playlist) {
    auto.fillFromSource(SetSource(playlists: [(id: choice.id, name: choice.name)]));
  }
}

/// How the booth orders: the queue as it is, the best order, the set.
class OrderPads extends StatelessWidget {
  const OrderPads({super.key, required this.auto, this.height = 26});
  final AutoMix auto;
  final double height;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('ORDER', style: Console.label(8)),
        const SizedBox(width: 6),
        for (final (i, m) in SetMode.values.indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Pad(
            label: m == SetMode.set && auto.set != null ? 'THE SET' : m.label.toUpperCase(),
            height: height,
            lit: auto.mode == m,
            colour: Console.ink,
            tooltip: switch (m) {
              SetMode.asQueued => 'The queue\'s own order: changes by hand are followed, nothing is reordered',
              SetMode.bestOrder => 'What is queued, in the order that mixes best and follows the curve',
              SetMode.set => auto.set == null
                  ? 'Plan a set first'
                  : 'The set from ${auto.set!.source.label.toLowerCase()}, re-routed as things change',
            },
            onTap: m == SetMode.set && auto.set == null ? null : () => auto.setMode(m),
          ),
        ],
      ]);
}

/// The curves a set's energy can follow, each drawn on its pad.
class CurvePads extends StatelessWidget {
  const CurvePads({super.key, required this.selected, required this.onPick, this.height = 26, this.enabled = true});
  final EnergyPreset? selected;
  final void Function(EnergyPreset p) onPick;
  final double height;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final p in EnergyPreset.values)
        if (p != EnergyPreset.custom)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Tooltip(
              message: p.label,
              child: InkWell(
                onTap: enabled ? () => onPick(p) : null,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 38,
                  height: height,
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: selected == p ? accent.withValues(alpha: 0.16) : Console.raised,
                    border: Border.all(color: selected == p ? accent : Console.line),
                  ),
                  child: CustomPaint(painter: CurvePainter(p.points, selected == p ? accent : Console.quiet)),
                ),
              ),
            ),
          ),
    ]);
  }
}

/// A curve's points drawn as a line in the box.
class CurvePainter extends CustomPainter {
  CurvePainter(this.points, this.colour, {this.width = 1.6});
  final List<(double, double)> points;
  final Color colour;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final path = Path();
    for (final (i, (k, e)) in points.indexed) {
      final o = Offset(k * size.width, (1 - e) * size.height);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..color = colour);
  }

  @override
  bool shouldRepaint(CurvePainter old) => old.points != points || old.colour != colour;
}

// ------------------------------------------------------------------ undo
/// What the booth just changed by itself (or on a hand's word), and a way back — for
/// fifteen seconds.
class UndoChip extends StatefulWidget {
  const UndoChip({super.key, required this.auto, this.maxWidth = 260});
  final AutoMix auto;
  final double maxWidth;

  @override
  State<UndoChip> createState() => _UndoChipState();
}

class _UndoChipState extends State<UndoChip> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.auto.change;
    if (c == null) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: InkWell(
        onTap: () {
          feel(Feel.pick);
          unawaited(widget.auto.undoLast());
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Console.line),
            color: Console.raised,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.undo, size: 13, color: Console.ink),
            const SizedBox(width: 5),
            Text('UNDO', style: Console.label(8, color: Console.ink)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(c.what, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.quiet)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ the energy lane
/// The set's energy, record by record: where the booth means it to be (the line) and
/// where each record is (the dots) — played ones faint, the one on now ringed — and
/// each record's tempo as a thin second line. The curve made visible, redrawn as the
/// set is re-routed.
class EnergyLane extends StatelessWidget {
  const EnergyLane({super.key, required this.booth, required this.records, this.played = 0, this.height = 46});
  final Booth booth;
  final List<Track> records;

  /// How many of [records] have been played already (drawn faint, before the one on).
  final int played;
  final double height;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final auto = booth.auto;
    final targets = auto.targetsFor(records.sublist(math.min(played, records.length)));
    final energies = [
      for (final t in records) SetPlanner.energyOf(t, booth.timing.peek(t.id)),
    ];
    final tempos = [for (final t in records) booth.timing.peek(t.id)?.gridBpm];
    // Nothing to draw — no loudness known, no line wanted: no lane.
    if (energies.every((e) => e == null) && targets.every((t) => t == null)) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 54,
          child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ENERGY', style: Console.label(7.5, color: Console.ink)),
            Text('TEMPO', style: Console.label(7, color: Console.faint)),
          ]),
        ),
        Expanded(
          child: CustomPaint(
            painter: _LanePainter(
              energies: energies,
              targets: [for (var i = 0; i < played; i++) null, ...targets],
              tempos: tempos,
              played: played,
              accent: accent,
            ),
          ),
        ),
      ]),
    );
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter({required this.energies, required this.targets, required this.tempos, required this.played, required this.accent});
  final List<double?> energies, targets, tempos;
  final int played;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final n = energies.length;
    if (n == 0) return;
    double x(int i) => n == 1 ? size.width / 2 : 8 + i * (size.width - 16) / (n - 1);
    double y(double e) => 4 + (1 - e.clamp(0.0, 1.0)) * (size.height - 8);
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = Console.line);
    // Tempo: its own scale, the lane's span.
    final known = [for (final t in tempos) if (t != null) t];
    if (known.length >= 2) {
      final lo = known.reduce(math.min) - 2, hi = known.reduce(math.max) + 2;
      final path = Path();
      var started = false;
      for (var i = 0; i < n; i++) {
        final t = tempos[i];
        if (t == null) continue;
        final o = Offset(x(i), 4 + (1 - (t - lo) / (hi - lo)) * (size.height - 8));
        started ? path.lineTo(o.dx, o.dy) : path.moveTo(o.dx, o.dy);
        started = true;
      }
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Console.faint.withValues(alpha: 0.6));
    }
    // The line the booth means the set to follow.
    final path = Path();
    var started = false;
    for (var i = 0; i < n && i < targets.length; i++) {
      final t = targets[i];
      if (t == null) continue;
      final o = Offset(x(i), y(t));
      started ? path.lineTo(o.dx, o.dy) : path.moveTo(o.dx, o.dy);
      started = true;
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.55));
    // Each record.
    for (var i = 0; i < n; i++) {
      final e = energies[i];
      if (e == null) continue;
      final o = Offset(x(i), y(e));
      final on = i == played;
      final c = i < played ? Console.faint : on ? accent : Console.ink;
      canvas.drawCircle(o, on ? 4.5 : 3, Paint()..color = c);
      if (on) {
        canvas.drawCircle(o, 7.5, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = accent);
      }
      // How far off the line, as a thin stalk.
      final t = i < targets.length ? targets[i] : null;
      if (t != null && (t - e).abs() > 0.08) {
        canvas.drawLine(o, Offset(o.dx, y(t)), Paint()
          ..strokeWidth = 1
          ..color = c.withValues(alpha: 0.35));
      }
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) => true;
}

// ------------------------------------------------------------------ alternatives
/// Other records for [track]'s place in the set, from the set's pool (or KEEP
/// GOING's): what fits after the one before it and into the one after — tap one to
/// put it there.
Future<void> showAlternatives(BuildContext context, Booth booth, Track track) async {
  final auto = booth.auto;
  final records = [if (auto.current != null) auto.current!, ...auto.upcoming];
  final i = records.indexWhere((t) => t.id == track.id);
  if (i <= 0) return;
  final prev = records[i - 1];
  final next = i + 1 < records.length ? records[i + 1] : null;
  final source = auto.mode == SetMode.set && auto.set != null ? auto.set!.source : auto.fillSource;
  final shape = auto.set?.shape ?? const SetShape(preset: EnergyPreset.plateau);
  final choices = auto.house.choices(
    source: source,
    shape: shape.copyWith(offset: auto.energyOffset),
    prev: prev,
    next: next,
    k: auto.set == null ? 0.5 : auto.setAt,
    exclude: [for (final t in records) t.id],
    limit: 8,
  );
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Console.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Console.line)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('INSTEAD OF ${track.displayTitle.toUpperCase()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Console.label(9.5, color: Console.ink)),
              const SizedBox(height: 4),
              Text('after ${prev.displayTitle}${next == null ? '' : ', before ${next.displayTitle}'} — from ${source.label.toLowerCase()}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10.5, color: Console.quiet)),
              const SizedBox(height: 10),
              Flexible(
                child: FutureBuilder<List<SlotChoice>>(
                  future: choices,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('The house could not say: ${snap.error}', style: Mag.typewriter(11, color: Console.a)),
                      );
                    }
                    final got = snap.data;
                    if (got == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                    if (got.isEmpty) return Padding(padding: const EdgeInsets.all(12), child: Text('Nothing else fits here.', style: Mag.typewriter(11, color: Console.quiet)));
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: got.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: Console.line),
                      itemBuilder: (context, k) {
                        final c = got[k];
                        return InkWell(
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(auto.replaceUpcoming(track, c.track));
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(children: [
                              Artwork(track: c.track, size: 34, radius: 3),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(c.track.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
                                  Text(c.why.isEmpty ? c.track.artistLine : c.why,
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(9.5, color: Console.quiet)),
                                ]),
                              ),
                              if (c.camelot != null) Text(c.camelot!, style: Mag.typewriter(10, color: Console.quiet, bold: true)),
                              const SizedBox(width: 8),
                              if (c.bpm != null) Text(c.bpm!.toStringAsFixed(0), style: Mag.numerals(13, color: Console.quiet)),
                              const SizedBox(width: 10),
                              FitMeter(fit: c.fit / 2, width: 34),
                            ]),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('CLOSE', style: Console.label(9, color: Console.ink))),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// How well one record follows another, as a short bar: empty to full over the
/// planner's 0 to 1.2.
class FitMeter extends StatelessWidget {
  const FitMeter({super.key, required this.fit, this.width = 40, this.height = 4});
  final double? fit;
  final double width, height;

  @override
  Widget build(BuildContext context) {
    final f = fit;
    final k = f == null ? 0.0 : (f / 1.2).clamp(0.0, 1.0);
    final c = f == null
        ? Console.faint
        : k > 0.75
            ? const Color(0xFF3FBF7F)
            : k > 0.5
                ? Console.ink
                : Console.a;
    return Tooltip(
      message: f == null ? 'not judged yet' : 'fit ${f.toStringAsFixed(2)}',
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(height), color: Console.line),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: k,
          child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(height), color: c)),
        ),
      ),
    );
  }
}
