import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../desk/console.dart';
import '../desk/console_set.dart' show Verdict, clockOf, countOf;
import '../desk/set_planner_page.dart';

/// The Auto DJ on a phone: the switch, what is coming and in how long, the hands on
/// it — go now, not that one — and the ways into the set, the plan and the planner,
/// which open over the room.
class PhoneAutoCard extends StatelessWidget {
  const PhoneAutoCard({super.key, required this.booth, required this.onSet, required this.onPlan});
  final Booth booth;
  final VoidCallback onSet, onPlan;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final items = context.watch<AppState>().player?.items ?? const <Track>[];
    final trouble = booth.wouldNotPlay;
    final next = auto.next;
    final plan = auto.planned;
    final left = auto.timeToGo;
    final soon = left != null && (left.isNegative || left.inSeconds < 16);
    final total = items.fold<int>(0, (a, t) => a + (t.durationMs ?? 0));

    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Pad(
                label: 'AUTO DJ',
                icon: auto.running ? Icons.stop : Icons.play_arrow,
                colour: accent,
                lit: auto.running,
                height: 34,
                tooltip: auto.running ? 'Stop mixing' : items.isEmpty ? 'Queue some records first' : 'Mix the queue, record into record',
                onTap: auto.running
                    ? auto.stop
                    : items.isEmpty
                        ? null
                        : () {
                            final on = booth.master.track;
                            final at = on == null ? 0 : items.indexWhere((t) => t.id == on.id).clamp(0, items.length - 1);
                            unawaited(auto.start(items, at: at));
                          },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: !auto.running
                    ? Text(
                        items.isEmpty ? 'NOTHING QUEUED' : '${items.length} ${items.length == 1 ? 'RECORD' : 'RECORDS'} · ${clockOf(Duration(milliseconds: total))}',
                        style: Console.label(8.5))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(next == null ? 'LAST RECORD' : 'NEXT', style: Console.label(8, color: accent)),
                            const SizedBox(width: 6),
                            if (next != null)
                              Expanded(
                                child: Text(next.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
                              ),
                          ]),
                          if (plan != null)
                            Row(children: [
                              Icon(transitionIcon(plan.kind), size: 12, color: auto.steered ? accent : Console.quiet),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text('${plan.kind.label} · ${plan.bars}${auto.steered ? ' · by hand' : ''}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.quiet)),
                              ),
                            ])
                          else if (auto.working != null)
                            Text(auto.working!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.faint)),
                        ],
                      ),
              ),
              if (auto.running) ...[
                const SizedBox(width: 8),
                Text(
                  booth.busy || (left?.isNegative ?? false) ? 'NOW' : left == null ? '' : countOf(left),
                  style: Mag.numerals(20, color: soon ? accent : Console.ink),
                ),
              ],
            ],
          ),
          if (trouble != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                const Icon(Icons.error_outline, size: 14, color: Console.a),
                const SizedBox(width: 6),
                Expanded(child: Text(trouble, maxLines: 2, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.a))),
                Pad(label: 'OK', height: 24, onTap: booth.forgetTrouble),
              ]),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (auto.running) ...[
                Expanded(
                  child: Pad(
                    icon: Icons.fast_forward,
                    label: 'NOW',
                    height: 30,
                    tooltip: 'Mix now',
                    onTap: booth.inTransition || next == null
                        ? null
                        : () {
                            feel(Feel.commit);
                            unawaited(auto.mixNow());
                          },
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Pad(
                    icon: Icons.skip_next,
                    label: 'NOT THAT',
                    height: 30,
                    tooltip: 'Not that one',
                    onTap: booth.inTransition || next == null ? null : () => unawaited(auto.dropNext()),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Pad(icon: Icons.view_week_outlined, label: 'SET', height: 30, tooltip: 'The set: every record to come', onTap: onSet),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Pad(icon: Icons.insights, label: 'PLAN', height: 30, tooltip: 'The next move, drawn out', onTap: auto.running ? onPlan : null),
              ),
              if (!auto.running) ...[
                const SizedBox(width: 4),
                Expanded(
                  child: Pad(
                    icon: Icons.auto_awesome,
                    label: 'PLAN A SET',
                    height: 30,
                    tooltip: 'Order the queue, choose the moves, then start',
                    onTap: items.length < 2 ? null : () => openSetPlanner(context, booth),
                  ),
                ),
              ],
            ],
          ),
          if (auto.running && auto.lastMix != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(alignment: Alignment.centerRight, child: Verdict(booth: booth, compact: true)),
            ),
        ],
      ),
    );
  }
}
