import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/planner.dart';
import '../../../state/booth/set_planner.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../../theme.dart';
import 'console.dart';
import 'console_set.dart' show StyleDials;
import 'data_marks.dart';

/// Into the planner, over the booth.
Future<void> openSetPlanner(BuildContext context, Booth booth) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => SetPlannerPage(booth: booth), fullscreenDialog: true));

/// Before a set: the queue laid out as the booth would play it — ordered for an arc,
/// each pair joined by the move the booth means to make, each record's key, tempo and
/// loudness beside it — with a hand on all of it: pin a record where it is, drag one
/// elsewhere, pick another move for a pair, turn the dials, and start.
class SetPlannerPage extends StatefulWidget {
  const SetPlannerPage({super.key, required this.booth});
  final Booth booth;

  @override
  State<SetPlannerPage> createState() => _SetPlannerPageState();
}

class _SetPlannerPageState extends State<SetPlannerPage> {
  List<Track> _order = const [];
  final _locked = <int>{};
  final _moves = <(int, int), MixPlan>{};
  EnergyArc _arc = EnergyArc.flat;
  int _known = 0;
  bool _reading = true;

  Booth get _b => widget.booth;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _order = [for (final t in app.player?.items ?? const <Track>[]) if (t.isReady) t];
    _arc = _b.auto.arc;
    _b.auto.addListener(_changed);
    unawaited(_read());
  }

  @override
  void dispose() {
    _b.auto.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// What the house knows of every record, then the first order.
  Future<void> _read() async {
    for (final t in _order) {
      await _b.timing.of(t).timeout(const Duration(seconds: 15), onTimeout: () => null);
      _known++;
      if (mounted) setState(() {});
    }
    _reading = false;
    _plan();
  }

  void _plan() {
    if (_order.length < 2) return;
    final from = _b.master.track;
    final on = from != null && _order.any((t) => t.id == from.id) ? from : null;
    final rest = on == null ? _order : [for (final t in _order) if (t.id != on.id) t];
    final start = on ?? rest.first;
    final ordered = SetPlanner.order(
      on == null ? rest.sublist(1) : rest,
      from: start,
      timingOf: _b.timing.peek,
      arc: _arc,
      locked: _locked,
    );
    setState(() => _order = [start, ...ordered]);
  }

  Future<void> _start() async {
    final app = context.read<AppState>();
    final auto = _b.auto;
    feel(Feel.commit);
    // The queue put in this order, so the crate shows what the booth plays.
    final items = app.player?.items ?? const <Track>[];
    for (var i = 0; i < _order.length; i++) {
      final now = app.player?.items ?? items;
      final at = now.indexWhere((t) => t.id == _order[i].id);
      if (at >= 0 && at != i) await app.moveInQueue(at, i);
    }
    auto.chooseForYourself(false);
    auto.setArc(_arc);
    auto.steers.addAll(_moves);
    for (final id in _locked) {
      auto.locked.add(id);
    }
    final on = _b.master.track;
    final at = on == null ? 0 : _order.indexWhere((t) => t.id == on.id).clamp(0, _order.length - 1);
    if (!mounted) return;
    Navigator.of(context).pop();
    unawaited(auto.start(_order, at: at));
  }

  /// The dials and the words about the set, beside the list on a desk and in a
  /// dialog on a phone.
  Widget _how(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          StyleDials(auto: _b.auto),
          const SizedBox(height: 18),
          Text('THE SET', style: Console.label(10, color: Console.ink)),
          const SizedBox(height: 8),
          Text(
            'Drag a record to move it; pin one to keep it where it is when '
            'the rest is planned again. Tap the move between two records to '
            'choose another. The booth eases each record back to its own '
            'tempo after every mix, so the set may climb.',
            style: Mag.typewriter(11, color: Console.quiet),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final total = _order.fold<int>(0, (a, t) => a + (t.durationMs ?? 0));
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final arcs = [
      for (final arc in EnergyArc.values) ...[
        Pad(
          label: arc.label.toUpperCase(),
          lit: _arc == arc,
          colour: Console.ink,
          height: 26,
          tooltip: switch (arc) {
            EnergyArc.flat => 'Each record about as loud as the last',
            EnergyArc.build => 'Up all the way',
            EnergyArc.peakLate => 'Up to a peak three quarters through, then easing off',
            EnergyArc.coolDown => 'Down: an ending',
          },
          onTap: () {
            _arc = arc;
            _plan();
          },
        ),
        const SizedBox(width: 4),
      ],
    ];
    final again = Pad(
      label: 'PLAN AGAIN',
      icon: Icons.auto_awesome,
      height: 28,
      colour: Console.ink,
      tooltip: 'Order the rest again, around what is pinned',
      onTap: _reading ? null : _plan,
    );
    final start = Pad(
      label: 'START',
      icon: Icons.play_arrow,
      height: 30,
      colour: Theme.of(context).colorScheme.primary,
      lit: true,
      onTap: _order.length < 2 ? null : () => unawaited(_start()),
    );
    final dials = Pad(
      icon: Icons.tune,
      label: 'DIALS',
      height: 28,
      colour: Console.ink,
      tooltip: 'How it mixes',
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Console.panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Console.line)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: _how(context)),
          ),
        ),
      ),
    );
    return Theme(
      data: MuseTheme.dark(app.palette),
      child: Scaffold(
        backgroundColor: Console.ground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Console.quiet),
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 6),
                    Text('PLAN A SET', style: Console.label(11, color: Console.ink)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                          '${_order.length} RECORDS · ${_clock(total)}'
                          '${_reading ? ' · READING $_known OF ${_order.length}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Console.label(8.5)),
                    ),
                    if (!narrow) ...[...arcs, const SizedBox(width: 10), again, const SizedBox(width: 8)],
                    start,
                  ],
                ),
                if (narrow) ...[
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [...arcs, const SizedBox(width: 6), again, const SizedBox(width: 6), dials]),
                  ),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: Plate(padding: const EdgeInsets.all(8), child: _list())),
                      if (!narrow) ...[
                        const SizedBox(width: 12),
                        SizedBox(width: 340, child: Plate(child: _how(context))),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _list() => ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: _order.length,
        proxyDecorator: (child, i, a) => Material(color: Colors.transparent, child: child),
        onReorderItem: (from, to) {
          setState(() {
            final t = _order.removeAt(from);
            _order.insert(to > from ? to - 1 : to, t);
          });
        },
        itemBuilder: (context, i) {
          final t = _order[i];
          final timing = _b.timing.peek(t.id);
          final energy = SetPlanner.energyOf(t, timing);
          final locked = _locked.contains(t.id);
          final prev = i > 0 ? _order[i - 1] : null;
          return Column(
            key: ValueKey(t.id),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (prev != null) _MoveRow(booth: _b, from: prev, to: t, chosen: _moves[(prev.id, t.id)],
                  onPick: (p) => setState(() {
                        if (p == null) {
                          _moves.remove((prev.id, t.id));
                        } else {
                          _moves[(prev.id, t.id)] = p;
                        }
                      })),
              Row(
                children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.drag_indicator, size: 16, color: Console.faint),
                    ),
                  ),
                  SizedBox(
                      width: 22,
                      child: Text('${i + 1}', style: Mag.numerals(13, color: Console.quiet))),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(14, color: Console.ink)),
                        Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10.5, color: Console.quiet)),
                      ],
                    ),
                  ),
                  if (MediaQuery.sizeOf(context).width >= 700) ...[
                    DataMarks(booth: _b, track: t, timing: timing),
                    const SizedBox(width: 10),
                  ],
                  SizedBox(
                    width: 42,
                    child: Text(timing?.camelot ?? '', textAlign: TextAlign.center, style: Mag.typewriter(11, color: Console.quiet)),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(timing?.gridBpm?.toStringAsFixed(0) ?? '', textAlign: TextAlign.right, style: Mag.numerals(14, color: Console.quiet)),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 60,
                    child: energy == null
                        ? const SizedBox()
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(value: energy, minHeight: 4, color: Console.quiet, backgroundColor: Console.line),
                          ),
                  ),
                  IconButton(
                    icon: Icon(locked ? Icons.push_pin : Icons.push_pin_outlined, size: 16, color: locked ? Console.ink : Console.faint),
                    tooltip: locked ? 'Unpin' : 'Pin it here',
                    onPressed: () => setState(() => locked ? _locked.remove(t.id) : _locked.add(t.id)),
                  ),
                ],
              ),
            ],
          );
        },
      );

  static String _clock(int ms) {
    final m = ms ~/ 60000;
    return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '$m min';
  }
}

/// The move between two records: what the booth would do, why, and a way to choose.
class _MoveRow extends StatelessWidget {
  const _MoveRow({required this.booth, required this.from, required this.to, required this.chosen, required this.onPick});
  final Booth booth;
  final Track from, to;
  final MixPlan? chosen;
  final void Function(MixPlan?) onPick;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final fit = auto.fitBetween(from, to);
    final move = chosen ?? auto.previewOf(from, to);
    return InkWell(
      onTap: () => _pick(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 2, 8, 2),
        child: Row(
          children: [
            Icon(move == null ? Icons.more_horiz : transitionIcon(move.kind), size: 14, color: chosen != null ? accent : Console.quiet),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  if (move != null) '${move.kind.label} · ${move.bars} bars',
                  if (fit.why.isNotEmpty) fit.why,
                ].join(' — '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Mag.typewriter(10.5, color: chosen != null ? accent : Console.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final options = await booth.auto.optionsFor(from, to);
    if (!context.mounted || options.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final picked = await showMenu<MixPlan?>(
      context: context,
      color: Console.raised,
      position: RelativeRect.fromLTRB(at.dx + 40, at.dy + 24, at.dx + 40, at.dy),
      items: [
        for (final o in options)
          PopupMenuItem(
            value: o,
            child: Row(children: [
              Icon(transitionIcon(o.kind), size: 14, color: Console.quiet),
              const SizedBox(width: 8),
              Text('${o.kind.label} · ${o.bars}  ', style: Mag.typewriter(12, color: Console.ink)),
              Flexible(child: Text(o.why, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10.5, color: Console.quiet))),
            ]),
          ),
        if (chosen != null)
          PopupMenuItem(value: null, child: Text('Let the booth choose', style: Mag.typewriter(12, color: Console.ink))),
      ],
    );
    if (picked != null || chosen != null) onPick(picked);
  }
}
