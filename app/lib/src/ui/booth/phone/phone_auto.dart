
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../mag.dart';
import '../desk/auto_bits.dart';
import '../desk/console.dart';
import '../desk/console_set.dart' show Verdict, clockOf, startAuto;
import '../desk/set_planner_page.dart';

/// The Auto DJ on a phone, as the desk's bar says it: the switch, what it is doing
/// in a word and what is coming, the countdown; the hands on the next transition
/// (skip, now, not now, sooner, longer); the room's word; KEEP GOING; UNDO after
/// anything it changed; and the ways into the set, the plan and PLAN A SET.
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
                onTap: auto.running ? auto.stop : items.isEmpty ? null : () => startAuto(booth, items),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: !auto.running
                    ? Text(
                        items.isEmpty ? 'NOTHING QUEUED' : '${items.length} ${items.length == 1 ? 'RECORD' : 'RECORDS'} · ${clockOf(Duration(milliseconds: total))}',
                        style: Console.label(8.5))
                    : AutoStateLine(booth: booth, onTap: onSet, titleSize: 13),
              ),
              if (auto.running) ...[
                const SizedBox(width: 6),
                AutoCountdown(booth: booth),
              ],
            ],
          ),
          if (trouble != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(Icons.error_outline, size: 14, color: Console.a),
                const SizedBox(width: 6),
                Expanded(child: Text(trouble, maxLines: 2, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.a))),
                Pad(label: 'OK', height: 24, onTap: booth.forgetTrouble),
              ]),
            ),
          if (auto.running) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: AutoHands(booth: booth, labels: true, height: 30),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                RoomPads(auto: auto, words: false, height: 28),
                const SizedBox(width: 8),
                KeepGoingPad(auto: auto, height: 28, showSource: false),
              ]),
            ),
          ] else ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                OrderPads(auto: auto, height: 28),
                const SizedBox(width: 8),
                KeepGoingPad(auto: auto, height: 28, showSource: false),
              ]),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Pad(icon: Icons.view_week_outlined, label: 'SET', height: 30, tooltip: 'The set: every record to come', onTap: onSet),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Pad(icon: Icons.insights, label: 'PLAN', height: 30, tooltip: 'The next move, drawn out', onTap: onPlan),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 2,
                child: Pad(
                  icon: Icons.auto_awesome,
                  label: 'PLAN A SET',
                  height: 30,
                  tooltip: 'Build a set from the library, playlists or the queue',
                  onTap: () => openSetPlanner(context, booth),
                ),
              ),
            ],
          ),
          if (auto.running && (auto.change != null || auto.lastMix != null))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: auto.change != null ? UndoChip(auto: auto) : Verdict(booth: booth, compact: true),
              ),
            ),
        ],
      ),
    );
  }
}
