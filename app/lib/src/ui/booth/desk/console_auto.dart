import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/automix.dart';
import '../../../state/booth/booth.dart';
import '../../feel.dart';
import '../../mag.dart';
import 'console.dart';

/// The booth mixing on its own, as one strip: off, a button; on, what is next, how,
/// and how long until.
class ConsoleAuto extends StatelessWidget {
  const ConsoleAuto({super.key, required this.booth});
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

    final style = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, how) in MixStyle.values.indexed) ...[
          if (i > 0) const SizedBox(width: 4),
          Pad(
            label: how.name.toUpperCase(),
            lit: auto.style == how,
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
        const SizedBox(width: 8),
        Pad(
          icon: Icons.auto_awesome,
          lit: auto.pickBest,
          colour: Console.ink,
          height: 26,
          width: 34,
          tooltip: auto.pickBest ? 'Picking what follows best' : 'Playing the queue in order',
          onTap: () => auto.chooseForYourself(!auto.pickBest),
        ),
      ],
    );

    return Row(
      children: [
        power,
        const SizedBox(width: 14),
        Expanded(
          child: trouble != null
              ? _Trouble(text: trouble, onDismiss: booth.forgetTrouble)
              : auto.running
                  ? _Next(booth: booth, accent: accent)
                  : const SizedBox(),
        ),
        const SizedBox(width: 14),
        style,
      ],
    );
  }
}

class _Next extends StatelessWidget {
  const _Next({required this.booth, required this.accent});
  final Booth booth;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final next = auto.next;
    final plan = auto.plan;
    final left = auto.timeToGo;
    if (next == null) {
      return Text('LAST RECORD', style: Console.label(9));
    }
    final soon = left != null && (left.isNegative || left.inSeconds < 16);
    return Row(
      children: [
        Text('NEXT', style: Console.label(8.5, color: accent)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(next.displayTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(15, color: Console.ink)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(next.artistLine,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11, color: Console.quiet)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: booth.inTransition ? null : auto.toGo,
                  minHeight: 3,
                  color: accent,
                  backgroundColor: Console.line,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (plan != null)
          Tooltip(
            message: '${plan.kind.name} over ${plan.bars} bars${auto.replaying ? ', as it was kept' : ''}',
            child: Icon(transitionIcon(plan.kind), size: 18, color: Console.quiet),
          ),
        const SizedBox(width: 10),
        SizedBox(
          width: 58,
          child: Text(
            booth.busy || (left?.isNegative ?? false) ? 'NOW' : left == null ? '' : _count(left),
            textAlign: TextAlign.right,
            style: Mag.numerals(20, color: soon ? accent : Console.ink),
          ),
        ),
        const SizedBox(width: 10),
        Pad(
          icon: Icons.fast_forward,
          height: 30,
          width: 38,
          tooltip: 'Mix now',
          onTap: booth.inTransition
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
          tooltip: 'Not that one',
          onTap: booth.inTransition ? null : () => unawaited(auto.dropNext()),
        ),
      ],
    );
  }

  static String _count(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '$s';
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
