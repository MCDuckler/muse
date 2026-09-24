import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/automix.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/planner.dart';
import '../../../state/booth/set_planner.dart';
import '../../artwork.dart';
import '../../feel.dart';
import '../../mag.dart';
import 'console.dart';
import 'data_marks.dart';
import 'set_planner_page.dart';

/// Asked for from the set: the plan view for this pair of records (by id). Null is
/// the pair coming. The room listens and opens the plan view.
final planPair = ValueNotifier<(int, int)?>(null);

/// The middle of the booth shows one of three things.
enum BoothView { waves, set, plan }

// ------------------------------------------------------------------ the bar
/// The Auto DJ in the booth's top bar, kept small: the switch; what is coming, how
/// and in how long; go now, not that one; and, just after a mix, whether it was any
/// good. Everything else about the set is in the SET view (ConsoleSetView).
class ConsoleAutoBar extends StatelessWidget {
  const ConsoleAutoBar({super.key, required this.booth, required this.onSetView});
  final Booth booth;
  final VoidCallback onSetView;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final items = context.watch<AppState>().player?.items ?? const <Track>[];
    final trouble = booth.wouldNotPlay;

    final power = Pad(
      label: 'AUTO DJ',
      icon: auto.running ? Icons.stop : Icons.play_arrow,
      colour: accent,
      lit: auto.running,
      height: 36,
      tooltip: auto.running
          ? 'Stop mixing'
          : items.isEmpty
              ? 'Queue some records first'
              : 'Mix the queue, record into record',
      onTap: auto.running
          ? auto.stop
          : items.isEmpty
              ? null
              : () {
                  final on = booth.master.track;
                  final at = on == null ? 0 : items.indexWhere((t) => t.id == on.id).clamp(0, items.length - 1);
                  unawaited(auto.start(items, at: at));
                },
    );

    Widget middle;
    if (trouble != null) {
      middle = _Trouble(text: trouble, onDismiss: booth.forgetTrouble);
    } else if (!auto.running) {
      final total = items.fold<int>(0, (a, t) => a + (t.durationMs ?? 0));
      middle = Row(children: [
        Expanded(
          child: Text(
              items.isEmpty
                  ? 'NOTHING QUEUED'
                  : '${items.length} ${items.length == 1 ? 'RECORD' : 'RECORDS'} · ${clockOf(Duration(milliseconds: total))}',
              style: Console.label(8.5)),
        ),
        Pad(
          label: 'PLAN A SET',
          icon: Icons.auto_awesome,
          height: 28,
          colour: Console.ink,
          tooltip: 'Order the queue, choose the moves, then start',
          onTap: items.length < 2 ? null : () => openSetPlanner(context, booth),
        ),
      ]);
    } else {
      middle = _NextLine(booth: booth, accent: accent, onSetView: onSetView);
    }
    return Row(children: [power, const SizedBox(width: 12), Expanded(child: middle)]);
  }
}

String clockOf(Duration d) {
  final m = d.inMinutes;
  return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '$m min';
}

String countOf(Duration d) {
  final s = d.inSeconds;
  return s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '$s';
}

/// What is coming, in one line, and the hands on it.
class _NextLine extends StatelessWidget {
  const _NextLine({required this.booth, required this.accent, required this.onSetView});
  final Booth booth;
  final Color accent;
  final VoidCallback onSetView;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final next = auto.next;
    final plan = auto.planned;
    final left = auto.timeToGo;
    final soon = left != null && (left.isNegative || left.inSeconds < 16);
    return Row(
      children: [
        InkWell(
          onTap: onSetView,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(next == null ? 'LAST RECORD' : 'NEXT', style: Console.label(8.5, color: accent)),
              const SizedBox(width: 10),
              if (next != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(next.displayTitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(15, color: Console.ink)),
                ),
              if (plan != null) ...[
                const SizedBox(width: 12),
                Icon(transitionIcon(plan.kind), size: 15, color: auto.steered ? accent : Console.quiet),
                const SizedBox(width: 5),
                Text('${plan.kind.label} · ${plan.bars}${auto.steered ? ' · by hand' : ''}',
                    style: Mag.typewriter(11, color: Console.quiet)),
              ] else if (auto.working != null) ...[
                const SizedBox(width: 12),
                Text(auto.working!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11, color: Console.faint)),
              ],
            ]),
          ),
        ),
        const Spacer(),
        Verdict(booth: booth, compact: true),
        const SizedBox(width: 10),
        SizedBox(
          width: 58,
          child: Text(
            booth.busy || (left?.isNegative ?? false) ? 'NOW' : left == null ? '' : countOf(left),
            textAlign: TextAlign.right,
            style: Mag.numerals(20, color: soon ? accent : Console.ink),
          ),
        ),
        const SizedBox(width: 8),
        Pad(
          icon: Icons.fast_forward,
          height: 30,
          width: 38,
          tooltip: 'Mix now (M)',
          onTap: booth.inTransition || next == null
              ? null
              : () {
                  feel(Feel.commit);
                  unawaited(auto.mixNow());
                },
        ),
        const SizedBox(width: 4),
        Pad(
          icon: Icons.skip_next,
          height: 30,
          width: 38,
          tooltip: 'Not that one (N)',
          onTap: booth.inTransition || next == null ? null : () => unawaited(auto.dropNext()),
        ),
      ],
    );
  }
}

/// Just after a mix: was it any good? A thumb up, a thumb down, or hear it again.
/// Shown for a while after each mix, or until it is judged.
class Verdict extends StatelessWidget {
  const Verdict({super.key, required this.booth, this.compact = false});
  final Booth booth;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final m = auto.lastMix;
    if (m == null || !auto.running) return const SizedBox.shrink();
    final age = DateTime.now().difference(m.at);
    if (m.rating != null && age > const Duration(seconds: 8)) return const SizedBox.shrink();
    if (m.rating == null && age > const Duration(minutes: 3)) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    final rated = m.rating != null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: Text(
            rated
                ? (m.rating! > 0 ? 'GOOD ONE' : m.rating! < 0 ? 'NOTED' : 'SO-SO')
                : compact
                    ? 'THAT MIX?'
                    : 'HOW WAS ${m.plan.kind.label.toUpperCase()} INTO ${m.to.displayTitle.toUpperCase()}?',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Console.label(8, color: rated ? accent : Console.quiet)),
      ),
      const SizedBox(width: 6),
      Pad(
        icon: Icons.thumb_up_outlined,
        height: 26,
        width: 32,
        lit: m.rating == 1,
        colour: accent,
        tooltip: 'Good',
        onTap: () {
          feel(Feel.pick);
          unawaited(auto.rate(1));
        },
      ),
      const SizedBox(width: 2),
      Pad(
        icon: Icons.thumb_down_outlined,
        height: 26,
        width: 32,
        lit: m.rating == -1,
        colour: Console.a,
        tooltip: 'Not good',
        onTap: () {
          feel(Feel.pick);
          unawaited(auto.rate(-1));
        },
      ),
      const SizedBox(width: 2),
      Pad(
        icon: Icons.replay,
        height: 26,
        width: 32,
        colour: Console.ink,
        tooltip: 'Hear that mix again (R)',
        onTap: booth.busy ? null : () => unawaited(auto.replayLast()),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ the set view
/// The set, in the middle of the booth: how the booth is told to mix and to order
/// (the words, the dials, the arc, the planner); then every record still to play as
/// a card — art, title, key and tempo, what the house has on it, how loud it is,
/// pinned or not — the one on now first with the playhead through it, and between
/// each pair the move the booth means to make and why. A card is pinned or unpinned,
/// or put next; a move opens in the plan view and is steered there.
class ConsoleSetView extends StatefulWidget {
  const ConsoleSetView({super.key, required this.booth});
  final Booth booth;

  @override
  State<ConsoleSetView> createState() => _ConsoleSetViewState();
}

class _ConsoleSetViewState extends State<ConsoleSetView> {
  Timer? _tick;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final booth = widget.booth;
    return ListenableBuilder(
      listenable: Listenable.merge([booth, booth.auto]),
      builder: (context, _) => Plate(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Controls(booth: booth),
            const SizedBox(height: 10),
            Expanded(child: _cards(context)),
          ],
        ),
      ),
    );
  }

  Widget _cards(BuildContext context) {
    final booth = widget.booth;
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final items = context.watch<AppState>().player?.items ?? const <Track>[];
    final records = auto.running ? [if (auto.current != null) auto.current!, ...auto.upcoming] : items;
    if (records.isEmpty) {
      return Center(child: Text('NOTHING QUEUED — ADD FROM LIBRARY OR SEARCH', style: Console.label(9)));
    }
    return LayoutBuilder(builder: (context, c) {
      // A card is as tall as a card, not as tall as the room: the strip in it wants
      // sixty pixels, not two hundred of nothing.
      final height = math.min(c.maxHeight - 10, 176.0);
      return Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 10),
          itemCount: records.length * 2 - 1,
          itemBuilder: (context, i) {
            final Widget item;
            if (i.isOdd) {
              final a = records[i ~/ 2], b = records[i ~/ 2 + 1];
              item = _MoveChip(booth: booth, from: a, to: b, isNext: auto.running && i == 1, accent: accent);
            } else {
              final t = records[i ~/ 2];
              item = _Card(
                booth: booth,
                track: t,
                on: auto.running && i == 0,
                index: i ~/ 2,
                accent: accent,
              );
            }
            return Align(alignment: Alignment.topCenter, child: SizedBox(height: height, child: item));
          },
        ),
      );
    });
  }
}

/// How the booth mixes and orders, in one row.
class _Controls extends StatelessWidget {
  const _Controls({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final items = context.watch<AppState>().player?.items ?? const <Track>[];
    final total = (auto.running ? auto.upcoming : items).fold<int>(0, (a, t) => a + (t.durationMs ?? 0));
    final order = [
      Text('ORDER', style: Console.label(8)),
      const SizedBox(width: 6),
      Pad(
        label: 'AS QUEUED',
        height: 26,
        lit: !auto.pickBest,
        colour: Console.ink,
        tooltip: "The queue's own order",
        onTap: () => auto.chooseForYourself(false),
      ),
      for (final arc in EnergyArc.values) ...[
        const SizedBox(width: 3),
        Pad(
          label: arc.label.toUpperCase(),
          height: 26,
          lit: auto.pickBest && auto.arc == arc,
          colour: Console.ink,
          tooltip: switch (arc) {
            EnergyArc.flat => 'The booth orders: each record about as loud as the last',
            EnergyArc.build => 'The booth orders: up all the way',
            EnergyArc.peakLate => 'The booth orders: up to a peak three quarters through, then easing off',
            EnergyArc.coolDown => 'The booth orders: down',
          },
          onTap: () {
            auto.setArc(arc);
            if (!auto.pickBest) auto.chooseForYourself(true);
          },
        ),
      ],
    ];
    final style = [
      Text('STYLE', style: Console.label(8)),
      const SizedBox(width: 6),
      for (final (i, how) in MixStyle.values.indexed) ...[
        if (i > 0) const SizedBox(width: 3),
        Pad(
          label: how.name.toUpperCase(),
          lit: !auto.dialsByHand && auto.style == how,
          colour: Console.ink,
          height: 26,
          tooltip: switch (how) {
            MixStyle.easy => 'Long and level',
            MixStyle.normal => 'Blends, and the filter for clashes',
            MixStyle.bold => 'Short, loops, drops, the drums changing hands',
          },
          onTap: () => auto.mixLike(how),
        ),
      ],
      const SizedBox(width: 3),
      Pad(
        icon: Icons.tune,
        label: auto.dialsByHand ? 'DIALS ·' : 'DIALS',
        lit: auto.dialsByHand,
        colour: Console.ink,
        height: 26,
        tooltip: 'Length, risk and voices, as dials',
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            backgroundColor: Console.panel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Console.line)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: StyleDials(auto: auto)),
            ),
          ),
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Text('SET', style: Console.label(9, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(width: 12),
          Text(
              auto.running
                  ? '${auto.upcoming.length} TO COME · ${clockOf(Duration(milliseconds: total))}'
                  : '${items.length} QUEUED · ${clockOf(Duration(milliseconds: total))}',
              style: Console.label(8.5)),
          const SizedBox(width: 18),
          ...order,
          const Spacer(),
          Pad(
            label: 'PLAN A SET',
            icon: Icons.auto_awesome,
            height: 26,
            colour: Console.ink,
            tooltip: 'Lay the whole set out and start it',
            onTap: items.length < 2 ? null : () => openSetPlanner(context, booth),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          ...style,
          const SizedBox(width: 18),
          Expanded(child: Align(alignment: Alignment.centerRight, child: Verdict(booth: booth))),
        ]),
      ],
    );
  }
}

/// One record of the set.
class _Card extends StatelessWidget {
  const _Card({required this.booth, required this.track, required this.on, required this.index, required this.accent});
  final Booth booth;
  final Track track;
  final bool on;
  final int index;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final timing = booth.timing.peek(track.id);
    final energy = SetPlanner.energyOf(track, timing);
    final locked = auto.locked.contains(track.id);
    final d = track.durationMs;
    final length = d == null ? '' : '${d ~/ 60000}:${(d ~/ 1000 % 60).toString().padLeft(2, '0')}';
    double progress = 0;
    if (on) {
      final total = booth.master.duration?.inMilliseconds ?? d ?? 1;
      progress = (booth.master.position.inMilliseconds / (total == 0 ? 1 : total)).clamp(0.0, 1.0);
    }
    final fit = !on && auto.running && auto.current != null ? auto.fitOf(track) : null;
    return SizedBox(
      width: 196,
      child: Tooltip(
        message: fit == null || fit.why.isEmpty ? track.displayTitle : '${track.displayTitle}\n${fit.why}',
        waitDuration: const Duration(milliseconds: 700),
        child: InkWell(
          onTap: () => _menu(context),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: on ? accent.withValues(alpha: 0.12) : Console.raised,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: on ? accent : Console.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Artwork(track: track, size: 40, radius: 3),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(track.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
                      Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.quiet)),
                    ]),
                  ),
                  if (locked) const Icon(Icons.push_pin, size: 12, color: Console.quiet),
                ]),
                const SizedBox(height: 10),
                Expanded(
                  child: _StructureStrip(
                    timing: timing,
                    bands: booth.bands[track.id],
                    accent: accent,
                    outAt: on ? auto.goesAt : null,
                    inAt: !on && index == 1 && auto.running ? auto.comesInAt : null,
                    playhead: on ? booth.master.position : null,
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  if (on)
                    Text('ON ${booth.master.name}', style: Console.label(8, color: accent))
                  else
                    Text('${index + 1}', style: Mag.numerals(13, color: Console.faint)),
                  const SizedBox(width: 8),
                  DataMarks(booth: booth, track: track, timing: timing, size: 5),
                  const Spacer(),
                  if (timing?.camelot != null) Text(timing!.camelot!, style: Mag.typewriter(10.5, color: Console.quiet, bold: true)),
                  const SizedBox(width: 6),
                  if (timing?.gridBpm != null) Text(timing!.gridBpm!.toStringAsFixed(0), style: Mag.numerals(14, color: Console.quiet)),
                  const SizedBox(width: 6),
                  Text(length, style: Mag.typewriter(10, color: Console.faint)),
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: on ? progress : (energy ?? 0),
                    minHeight: 3,
                    color: on ? accent : Console.quiet.withValues(alpha: energy == null ? 0 : 0.8),
                    backgroundColor: Console.line,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final auto = booth.auto;
    final box = context.findRenderObject() as RenderBox?;
    final at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final locked = auto.locked.contains(track.id);
    final choice = await showMenu<String>(
      context: context,
      color: Console.raised,
      position: RelativeRect.fromLTRB(at.dx, at.dy + 40, at.dx, at.dy),
      items: [
        if (!on && auto.running)
          PopupMenuItem(
              value: 'lock',
              child: Text(locked ? 'Unpin: let the booth move it' : 'Pin it here', style: Mag.typewriter(12, color: Console.ink))),
        if (index == 1 && auto.running)
          PopupMenuItem(value: 'drop', child: Text('Not that one', style: Mag.typewriter(12, color: Console.ink))),
        if (index > 1 && auto.running)
          PopupMenuItem(value: 'next', child: Text('Play it next', style: Mag.typewriter(12, color: Console.ink))),
        if (index > 0 && auto.running)
          PopupMenuItem(value: 'plan', child: Text('The move into it', style: Mag.typewriter(12, color: Console.ink))),
      ],
    );
    switch (choice) {
      case 'lock':
        auto.setLocked(track.id, !locked);
      case 'drop':
        unawaited(auto.dropNext());
      case 'next':
        unawaited(auto.swapNext(track));
      case 'plan':
        final records = [if (auto.current != null) auto.current!, ...auto.upcoming];
        if (index > 0 && index < records.length) planPair.value = (records[index - 1].id, track.id);
    }
  }
}

/// The move between two records: what it is, in how long, why — tap to steer.
class _MoveChip extends StatelessWidget {
  const _MoveChip({required this.booth, required this.from, required this.to, required this.isNext, required this.accent});
  final Booth booth;
  final Track from, to;
  final bool isNext;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final MixPlan? move = isNext ? auto.planned : (auto.running ? auto.previewOf(from, to) : null);
    final byHand = auto.steers.containsKey((from.id, to.id));
    final fit = auto.running ? auto.fitBetween(from, to) : Fit.nothing;
    final left = isNext ? auto.timeToGo : null;
    final soon = left != null && (left.isNegative || left.inSeconds < 16);
    return SizedBox(
      width: 118,
      child: InkWell(
        onTap: auto.running ? () => planPair.value = (from.id, to.id) : null,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isNext)
                Text(
                    booth.busy || (left?.isNegative ?? false) ? 'NOW' : left == null ? '' : countOf(left),
                    style: Mag.numerals(18, color: soon ? accent : Console.ink)),
              Icon(move == null ? Icons.more_horiz : transitionIcon(move.kind), size: 20, color: byHand ? accent : Console.quiet),
              const SizedBox(height: 4),
              Text(
                  move == null
                      ? (auto.running ? 'working it out' : '')
                      : '${move.kind.label} · ${move.bars}${move.shift == 0 ? '' : ' · ${move.shift > 0 ? '+' : ''}${move.shift.round()} st'}',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: Mag.typewriter(10, color: byHand ? accent : Console.quiet)),
              if (fit.why.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(fit.why, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: Mag.typewriter(9, color: Console.faint)),
              ],
              if (byHand) Text('BY HAND', style: Console.label(8, color: accent)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dials, as a widget of their own: in the set view's dialog and on the planner page.
class StyleDials extends StatefulWidget {
  const StyleDials({super.key, required this.auto});
  final AutoMix auto;

  @override
  State<StyleDials> createState() => _StyleDialsState();
}

class _StyleDialsState extends State<StyleDials> {
  late StyleAxes _axes = widget.auto.axes;

  void _set(StyleAxes a) {
    setState(() => _axes = a);
    widget.auto.setAxes(a);
  }

  @override
  Widget build(BuildContext context) {
    final auto = widget.auto;
    // Each on a line of its own, with room for the thumbs between them.
    Widget dial(String name, String low, String high, double value, void Function(double) on) => SizedBox(
          height: 30,
          child: Row(children: [
            SizedBox(width: 56, child: Text(name, style: Console.label(8.5, color: Console.ink))),
            SizedBox(width: 74, child: Text(low, maxLines: 1, overflow: TextOverflow.clip, style: Console.label(8))),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                    trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
                child: Slider(value: value, onChanged: on, activeColor: Theme.of(context).colorScheme.primary, inactiveColor: Console.line),
              ),
            ),
            SizedBox(width: 74, child: Text(high, maxLines: 1, overflow: TextOverflow.clip, textAlign: TextAlign.right, style: Console.label(8))),
          ]),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('HOW IT MIXES', style: Console.label(10, color: Console.ink)),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final (i, how) in MixStyle.values.indexed) ...[
              if (i > 0) const SizedBox(width: 4),
              Pad(
                label: how.name.toUpperCase(),
                lit: !auto.dialsByHand && auto.style == how,
                colour: Console.ink,
                height: 26,
                tooltip: switch (how) {
                  MixStyle.easy => 'Long and level',
                  MixStyle.normal => 'Blends, and the filter for clashes',
                  MixStyle.bold => 'Short, loops, drops, the drums changing hands',
                },
                onTap: () {
                  auto.mixLike(how);
                  setState(() => _axes = auto.axes);
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        dial('LENGTH', 'SHORT', 'LONG', _axes.length, (v) => _set(StyleAxes(length: v, risk: _axes.risk, vocals: _axes.vocals))),
        dial('RISK', 'SAFE', 'WILD', _axes.risk, (v) => _set(StyleAxes(length: _axes.length, risk: v, vocals: _axes.vocals))),
        dial('VOICES', 'NEVER TWO', 'LET THEM', _axes.vocals, (v) => _set(StyleAxes(length: _axes.length, risk: _axes.risk, vocals: v))),
      ],
    );
  }
}

class _Trouble extends StatelessWidget {
  const _Trouble({required this.text, required this.onDismiss});
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Console.a),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11, color: Console.a)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: Console.quiet),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
          ),
        ],
      );
}


/// The record's shape, as the house read it: its sections as bands named where
/// there is room, breakdowns hollow, drops as ticks; where the mix goes out of it or
/// comes into it; the playhead. Bar loudness as a faint skyline behind.
class _StructureStrip extends StatelessWidget {
  const _StructureStrip({required this.timing, required this.accent, this.bands, this.outAt, this.inAt, this.playhead});
  final TrackTiming? timing;

  /// The record's loudness, as the waves' overview has it: the skyline where the
  /// house has not read the record's bars.
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final Color accent;
  final Duration? outAt, inAt, playhead;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _StructurePainter(this));
}

class _StructurePainter extends CustomPainter {
  _StructurePainter(this.w);
  final _StructureStrip w;

  static const _colours = {
    'intro': Color(0xFF55524C),
    'outro': Color(0xFF55524C),
    'verse': Color(0xFF6E8CA8),
    'chorus': Color(0xFFB98CFF),
    'inst': Color(0xFF7A8A7A),
    'drop': Color(0xFFFF7AC6),
    'build': Color(0xFFD9A441),
    'breakdown': Color(0xFF2A2A30),
    'break': Color(0xFF2A2A30),
    'on': Color(0xFF7A8A7A),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final t = w.timing;
    final total = (t?.durationMs ?? 0).toDouble();
    final base = size.height;
    // The floor: a timeline even before there is anything on it.
    canvas.drawLine(Offset(0, base - 0.5), Offset(size.width, base - 0.5), Paint()..color = Console.line);
    if (t == null || total <= 0) return;
    double x(int ms) => (ms / total * size.width).clamp(0.0, size.width);
    final s = t.structure;
    final b = w.bands;
    // The skyline: the house's bars, or the record's own loudness where it has none.
    if ((s == null || s.mixDb.isEmpty || s.barsMs.isEmpty) && b != null && b.low.isNotEmpty) {
      final n = b.low.length;
      for (var px = 0.0; px < size.width; px += 2) {
        final i = (px / size.width * n).floor().clamp(0, n - 1);
        final v = math.max(b.low[i], math.max(b.mid[i], b.high[i]));
        final h = (size.height - 12) * v / 255;
        canvas.drawRect(Rect.fromLTWH(px, base - h, 1.4, h), Paint()..color = Console.ink.withValues(alpha: 0.10));
      }
    } else if (s != null && s.mixDb.isNotEmpty && s.barsMs.isNotEmpty) {
      final heard = [for (final v in s.mixDb) if (v > -90) v];
      final top = heard.isEmpty ? 0.0 : heard.reduce(math.max);
      for (var i = 0; i < s.barsMs.length && i < s.mixDb.length; i++) {
        final x0 = x(s.barsMs[i]);
        final x1 = i + 1 < s.barsMs.length ? x(s.barsMs[i + 1]) : size.width;
        final db = s.mixDb[i];
        final h = db <= -90 ? 0.0 : (1 - (top - db).clamp(0.0, 30.0) / 30.0) * (size.height - 12);
        canvas.drawRect(Rect.fromLTRB(x0, base - h, x1, base), Paint()..color = Console.ink.withValues(alpha: 0.10));
      }
    }
    // The sections.
    if (s != null && s.sections.isNotEmpty) {
      for (final sec in s.sections) {
        final x0 = x(sec.startMs), x1 = x(sec.endMs);
        final c = _colours[sec.label] ?? Console.faint;
        final hollow = sec.label == 'breakdown' || sec.label == 'break';
        final r = Rect.fromLTRB(x0, 0, x1, 10);
        canvas.drawRect(r, Paint()..color = hollow ? Colors.transparent : c.withValues(alpha: 0.55));
        canvas.drawRect(r, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = c.withValues(alpha: hollow ? 0.8 : 0.3));
        if (x1 - x0 > 30) {
          final tp = TextPainter(
            text: TextSpan(text: sec.label.toUpperCase(), style: Console.label(6.5, color: Console.ink.withValues(alpha: 0.85))),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '',
          )..layout(maxWidth: x1 - x0 - 4);
          tp.paint(canvas, Offset(x0 + 2, 1));
        }
      }
      for (final d in s.dropsMs) {
        canvas.drawLine(Offset(x(d), 0), Offset(x(d), size.height), Paint()..color = Console.ink.withValues(alpha: 0.7)..strokeWidth = 1.2);
      }
    } else {
      // Only the cues: the intro and the outro hollow, the record between them a band.
      final cues = t.cues;
      if (cues != null) {
        canvas.drawRect(Rect.fromLTRB(x(cues.mixInMs), 0, x(cues.mixOutMs), 10), Paint()..color = Console.quiet.withValues(alpha: 0.35));
        canvas.drawRect(Rect.fromLTRB(x(cues.firstDownbeatMs), 0.5, x(cues.soundEndMs), 9.5), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Console.quiet.withValues(alpha: 0.4));
      }
    }
    void mark(Duration at, Color c, String label, {bool left = true}) {
      final px = x(at.inMilliseconds);
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), Paint()..color = c..strokeWidth = 1.5);
      final tp = TextPainter(
        text: TextSpan(text: label, style: Console.label(7, color: c)),
        textDirection: TextDirection.ltr,
      )..layout();
      // Inside the strip whichever side it was asked for, at its edges.
      var lx = left ? px + 3 : px - tp.width - 3;
      lx = lx.clamp(0.0, math.max(0.0, size.width - tp.width));
      tp.paint(canvas, Offset(lx, size.height - 11));
    }
    if (w.outAt != null) mark(w.outAt!, w.accent, 'OUT', left: false);
    if (w.inAt != null) mark(w.inAt!, w.accent, 'IN');
    if (w.playhead != null) {
      final px = x(w.playhead!.inMilliseconds);
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), Paint()..color = Console.ink..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_StructurePainter old) => true;
}
