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
import '../../feel.dart';
import '../../mag.dart';
import 'console.dart';
import 'set_planner_page.dart';

/// Asked for from the strip: the plan view for this pair of records (by id). Null is
/// the pair coming. The room listens and opens the plan view.
final planPair = ValueNotifier<(int, int)?>(null);

/// The set, as one strip across the top of the booth: the Auto DJ's switch; every
/// record still to play as a block, the one on now lit and the playhead moving
/// through it, each pair joined by the move the booth means to make between them;
/// the loudness of the set drawn over the blocks as a line, and each record's key
/// under it; the countdown to the next mix; the dials (STYLE) and the order
/// (ORDER). A record can be pinned where it is; a move can be opened in the plan view
/// and steered.
class ConsoleSet extends StatelessWidget {
  const ConsoleSet({super.key, required this.booth});
  final Booth booth;

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

    return Row(
      children: [
        power,
        const SizedBox(width: 12),
        Expanded(
          child: trouble != null
              ? _Trouble(text: trouble, onDismiss: booth.forgetTrouble)
              : auto.running
                  ? _Timeline(booth: booth, accent: accent)
                  : _Idle(booth: booth, items: items),
        ),
        const SizedBox(width: 10),
        _Style(booth: booth),
        const SizedBox(width: 4),
        _Order(booth: booth),
      ],
    );
  }
}

/// Before the Auto DJ is on: what the queue holds, and the way to plan it.
class _Idle extends StatelessWidget {
  const _Idle({required this.booth, required this.items});
  final Booth booth;
  final List<Track> items;

  @override
  Widget build(BuildContext context) {
    final total = items.fold<int>(0, (a, t) => a + (t.durationMs ?? 0));
    return Row(
      children: [
        Expanded(
          child: Text(
              items.isEmpty
                  ? 'NOTHING QUEUED'
                  : '${items.length} ${items.length == 1 ? 'RECORD' : 'RECORDS'} · ${_clock(Duration(milliseconds: total))}',
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
      ],
    );
  }
}

String _clock(Duration d) {
  final m = d.inMinutes;
  return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '$m min';
}

/// The set while it plays.
class _Timeline extends StatefulWidget {
  const _Timeline({required this.booth, required this.accent});
  final Booth booth;
  final Color accent;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  final _scroll = ScrollController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
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
    final auto = booth.auto;
    final on = auto.current;
    final rest = auto.upcoming;
    final left = auto.timeToGo;
    final soon = left != null && (left.isNegative || left.inSeconds < 16);
    final plan = auto.plan;
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final records = [if (on != null) on, ...rest];
            final layout = _layout(records, c.maxWidth);
            return SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: layout.width,
                height: c.maxHeight,
                child: GestureDetector(
                  onTapUp: (d) => _tapped(context, layout, d.localPosition.dx),
                  child: CustomPaint(
                    painter: _SetPainter(
                      booth: booth,
                      records: records,
                      layout: layout,
                      accent: widget.accent,
                      icon: (k) => transitionIcon(k),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(width: 10),
        if (plan != null)
          Tooltip(
            message: '${plan.kind.label} over ${plan.bars} bars'
                '${auto.replaying ? ', as it was kept' : auto.why == null ? '' : ' — ${auto.why}'}'
                '${auto.steered ? ' (by hand)' : ''}',
            child: Icon(transitionIcon(plan.kind), size: 18, color: auto.steered ? widget.accent : Console.quiet),
          ),
        const SizedBox(width: 8),
        SizedBox(
          width: 58,
          child: Text(
            booth.busy || (left?.isNegative ?? false) ? 'NOW' : left == null ? '' : _count(left),
            textAlign: TextAlign.right,
            style: Mag.numerals(20, color: soon ? widget.accent : Console.ink),
          ),
        ),
        const SizedBox(width: 8),
        Pad(
          icon: Icons.fast_forward,
          height: 30,
          width: 38,
          tooltip: 'Mix now (M)',
          onTap: booth.inTransition || auto.next == null
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
          onTap: booth.inTransition || auto.next == null ? null : () => unawaited(auto.dropNext()),
        ),
      ],
    );
  }

  static String _count(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '$s';
  }

  /// The blocks, each as wide as its record is long — no narrower than a title fits —
  /// with a gap for the move between each pair.
  _Layout _layout(List<Track> records, double width) {
    const gap = 22.0, least = 44.0;
    final total = records.fold<int>(0, (a, t) => a + (t.durationMs ?? 240000));
    final room = math.max(width, records.length * (least + gap));
    final scale = (room - gap * math.max(0, records.length - 1)) / math.max(1, total);
    final blocks = <Rect>[];
    var x = 0.0;
    for (final t in records) {
      final w = math.max(least, (t.durationMs ?? 240000) * scale);
      blocks.add(Rect.fromLTWH(x, 0, w, 1));
      x += w + gap;
    }
    return _Layout(blocks: blocks, gap: gap, width: math.max(width, x - gap));
  }

  void _tapped(BuildContext context, _Layout layout, double x) {
    final auto = widget.booth.auto;
    final records = [if (auto.current != null) auto.current!, ...auto.upcoming];
    for (var i = 0; i < layout.blocks.length; i++) {
      final b = layout.blocks[i];
      if (x >= b.left && x <= b.right) {
        _recordMenu(context, records[i], i);
        return;
      }
      if (i + 1 < layout.blocks.length && x > b.right && x < layout.blocks[i + 1].left) {
        feel(Feel.pick);
        planPair.value = (records[i].id, records[i + 1].id);
        return;
      }
    }
  }

  Future<void> _recordMenu(BuildContext context, Track t, int i) async {
    final auto = widget.booth.auto;
    final box = context.findRenderObject() as RenderBox?;
    final at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final locked = auto.locked.contains(t.id);
    final choice = await showMenu<String>(
      context: context,
      color: Console.raised,
      position: RelativeRect.fromLTRB(at.dx + 40, at.dy + 40, at.dx + 40, at.dy),
      items: [
        PopupMenuItem(enabled: false, child: Text(t.displayTitle, style: Mag.title(13, color: Console.ink))),
        if (i > 0)
          PopupMenuItem(
              value: 'lock',
              child: Text(locked ? 'Unpin: let the booth move it' : 'Pin it here',
                  style: Mag.typewriter(12, color: Console.ink))),
        if (i == 1)
          PopupMenuItem(value: 'drop', child: Text('Not that one', style: Mag.typewriter(12, color: Console.ink))),
        if (i > 0)
          PopupMenuItem(value: 'plan', child: Text('The move into it', style: Mag.typewriter(12, color: Console.ink))),
      ],
    );
    switch (choice) {
      case 'lock':
        auto.setLocked(t.id, !locked);
      case 'drop':
        unawaited(auto.dropNext());
      case 'plan':
        final records = [if (auto.current != null) auto.current!, ...auto.upcoming];
        if (i > 0) planPair.value = (records[i - 1].id, t.id);
    }
  }
}

class _Layout {
  const _Layout({required this.blocks, required this.gap, required this.width});
  final List<Rect> blocks;
  final double gap, width;
}

class _SetPainter extends CustomPainter {
  _SetPainter({required this.booth, required this.records, required this.layout, required this.accent, required this.icon});
  final Booth booth;
  final List<Track> records;
  final _Layout layout;
  final Color accent;
  final IconData Function(Transition) icon;

  @override
  void paint(Canvas canvas, Size size) {
    final auto = booth.auto;
    final h = size.height;
    const top = 9.0; // room for the loudness line
    final blockTop = top + 2, blockBottom = h - 2;
    // The loudness of the set, as a line over the blocks.
    final energies = [for (final t in records) SetPlanner.energyOf(t, booth.timing.peek(t.id))];
    final line = Path();
    var drawn = false;
    for (var i = 0; i < records.length; i++) {
      final e = energies[i];
      if (e == null) continue;
      final b = layout.blocks[i];
      final y = top - 1 - (top - 3) * e;
      if (!drawn) {
        line.moveTo(b.left, y);
        drawn = true;
      } else {
        line.lineTo(b.left, y);
      }
      line.lineTo(b.right, y);
    }
    if (drawn) {
      canvas.drawPath(line, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Console.quiet.withValues(alpha: 0.8));
    }
    for (var i = 0; i < records.length; i++) {
      final t = records[i];
      final b = Rect.fromLTRB(layout.blocks[i].left, blockTop, layout.blocks[i].right, blockBottom);
      final on = i == 0;
      final rr = RRect.fromRectAndRadius(b, const Radius.circular(4));
      canvas.drawRRect(rr, Paint()..color = on ? accent.withValues(alpha: 0.18) : Console.raised);
      canvas.drawRRect(rr, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = on ? accent : Console.line);
      // The playhead through the record on now, and where it goes out.
      if (on) {
        final d = booth.master;
        final total = d.duration?.inMilliseconds ?? t.durationMs ?? 1;
        final k = (d.position.inMilliseconds / math.max(1, total)).clamp(0.0, 1.0);
        canvas.drawRect(Rect.fromLTRB(b.left, b.top, b.left + b.width * k, b.bottom),
            Paint()..color = accent.withValues(alpha: 0.22));
        final go = auto.goesAt;
        if (go != null) {
          final gx = b.left + b.width * (go.inMilliseconds / math.max(1, total)).clamp(0.0, 1.0);
          canvas.drawLine(Offset(gx, b.top), Offset(gx, b.bottom), Paint()
            ..color = accent
            ..strokeWidth = 1.5);
        }
      }
      final timing = booth.timing.peek(t.id);
      final key = timing?.camelot;
      final bpm = timing?.gridBpm;
      final locked = auto.locked.contains(t.id);
      final label = _fit(t.displayTitle, b.width - 8);
      _text(canvas, label, Offset(b.left + 4, b.top + 2), Mag.title(11, color: on ? Console.ink : Console.quiet), b.width - 8);
      final under = [
        if (key != null) key,
        if (bpm != null) bpm.toStringAsFixed(0),
      ].join(' ');
      if (under.isNotEmpty && b.width >= 44) {
        _text(canvas, under, Offset(b.left + 4, b.bottom - 12), Mag.typewriter(8.5, color: Console.faint), b.width - 8);
      }
      if (locked) _icon(canvas, Icons.push_pin, Offset(b.right - 13, b.top + 2), 10, Console.quiet);
      // The move into the next one.
      if (i + 1 < records.length) {
        final nxt = records[i + 1];
        final MixPlan? move = i == 0 ? auto.planned : auto.previewOf(t, nxt);
        final byHand = auto.steers.containsKey((t.id, nxt.id));
        final cx = b.right + layout.gap / 2, cy = (blockTop + blockBottom) / 2;
        if (move != null) {
          _icon(canvas, icon(move.kind), Offset(cx - 8, cy - 8), 16, byHand ? accent : Console.quiet);
        } else {
          canvas.drawCircle(Offset(cx, cy), 2, Paint()..color = Console.faint);
        }
      }
    }
  }

  static String _fit(String s, double width) {
    final max = (width / 6.2).floor();
    return s.length <= max ? s : max <= 2 ? s.substring(0, math.max(1, max)) : '${s.substring(0, max - 1)}…';
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style, double width) {
    final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')
      ..layout(maxWidth: math.max(4, width));
    tp.paint(canvas, at);
  }

  void _icon(Canvas canvas, IconData i, Offset at, double size, Color colour) {
    final tp = TextPainter(
      text: TextSpan(
          text: String.fromCharCode(i.codePoint),
          style: TextStyle(fontSize: size, fontFamily: i.fontFamily, package: i.fontPackage, color: colour)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_SetPainter old) => true;
}

/// The dials: the three words, and under them the three sliders.
class _Style extends StatelessWidget {
  const _Style({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    return Pad(
      label: auto.dialsByHand ? 'STYLE ·' : auto.style.name.toUpperCase(),
      icon: Icons.tune,
      height: 28,
      colour: Console.ink,
      tooltip: 'How the booth mixes: the words, or the dials',
      onTap: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    final auto = booth.auto;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Console.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Console.line)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: StyleDials(auto: auto)),
        ),
      ),
    );
  }
}

/// The dials, as a widget of their own: in the strip's dialog and on the planner page.
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
    Widget dial(String name, String low, String high, double value, void Function(double) on) => Row(
          children: [
            SizedBox(width: 56, child: Text(name, style: Console.label(8.5, color: Console.ink))),
            SizedBox(width: 62, child: Text(low, style: Console.label(7.5))),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                    trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
                child: Slider(value: value, onChanged: on, activeColor: Theme.of(context).colorScheme.primary, inactiveColor: Console.line),
              ),
            ),
            SizedBox(width: 62, child: Text(high, textAlign: TextAlign.right, style: Console.label(7.5))),
          ],
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

/// The order: the queue's own, or the booth's, heading somewhere.
class _Order extends StatelessWidget {
  const _Order({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    return PopupMenuButton<String>(
      tooltip: 'The order of the set',
      color: Console.raised,
      onSelected: (v) {
        if (v == 'queue') {
          auto.chooseForYourself(false);
        } else if (v == 'plan') {
          openSetPlanner(context, booth);
        } else {
          auto.setArc(EnergyArc.values.byName(v));
          if (!auto.pickBest) auto.chooseForYourself(true);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'queue', child: _item('The queue\'s order', !auto.pickBest)),
        for (final arc in EnergyArc.values)
          PopupMenuItem(value: arc.name, child: _item('Its own: ${arc.label}', auto.pickBest && auto.arc == arc)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'plan', child: _item('Plan the set…', false)),
      ],
      child: Pad(
        label: auto.pickBest ? auto.arc.label.toUpperCase() : 'IN ORDER',
        icon: auto.pickBest ? Icons.auto_awesome : Icons.format_list_numbered,
        height: 28,
        colour: Console.ink,
        lit: auto.pickBest,
        onTap: null,
      ),
    );
  }

  Widget _item(String s, bool on) => Row(children: [
        Icon(on ? Icons.radio_button_checked : Icons.radio_button_off, size: 14, color: on ? Console.ink : Console.faint),
        const SizedBox(width: 8),
        Text(s, style: Mag.typewriter(12, color: Console.ink)),
      ]);
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
