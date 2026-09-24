import 'package:flutter/material.dart';

import '../../../state/booth/booth.dart';
import '../../mag.dart';
import 'console.dart';

/// What the booth has been doing, newest at the top: the automix thinking out loud,
/// and anything done by hand that it has to work around.
class ConsoleLog extends StatelessWidget {
  const ConsoleLog({super.key, required this.booth});
  final Booth booth;

  static IconData iconOf(BoothEventKind k) => switch (k) {
        BoothEventKind.auto => Icons.power_settings_new,
        BoothEventKind.next => Icons.queue_music,
        BoothEventKind.sync => Icons.speed,
        BoothEventKind.cue => Icons.place_outlined,
        BoothEventKind.plan => Icons.route,
        BoothEventKind.mix => Icons.merge,
        BoothEventKind.held => Icons.graphic_eq,
        BoothEventKind.done => Icons.check,
        BoothEventKind.skip => Icons.skip_next,
        BoothEventKind.parts => Icons.call_split,
        BoothEventKind.trouble => Icons.error_outline,
      };

  @override
  Widget build(BuildContext context) {
    final events = booth.events;
    final accent = Theme.of(context).colorScheme.primary;
    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('LOG', style: Console.label(9, color: Console.ink)),
              const SizedBox(width: 8),
              if (booth.auto.running) _Live(colour: accent),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: events.isEmpty
                ? const Center(child: Icon(Icons.notes, size: 22, color: Console.faint))
                : ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (context, i) {
                      final e = events[events.length - 1 - i];
                      return _Line(key: ObjectKey(e), event: e, accent: accent);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.event, required this.accent});
  final BoothEvent event;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final c = e.kind == BoothEventKind.trouble
        ? Console.a
        : e.deck != null
            ? Console.deck(e.deck!)
            : e.kind == BoothEventKind.auto
                ? accent
                : Console.quiet;
    final t = e.at;
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    // A new line arrives lit and settles: the eye finds what just happened.
    final fresh = DateTime.now().difference(e.at) < const Duration(seconds: 3);
    return TweenAnimationBuilder<double>(
      key: ValueKey(e.at),
      tween: Tween(begin: fresh ? 1 : 0, end: 0),
      duration: const Duration(milliseconds: 2400),
      builder: (context, glow, child) => Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: Color.lerp(Colors.transparent, c.withValues(alpha: 0.16), glow),
          borderRadius: BorderRadius.circular(5),
        ),
        child: child,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(ConsoleLog.iconOf(e.kind), size: 13, color: c),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(e.text, style: Mag.typewriter(11, color: Console.ink)),
          ),
          const SizedBox(width: 6),
          Text(time, style: Mag.typewriter(9.5, color: Console.faint)),
        ],
      ),
    );
  }
}

/// A slow pulse: the booth is mixing on its own.
class _Live extends StatefulWidget {
  const _Live({required this.colour});
  final Color colour;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: widget.colour, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text('AUTO', style: Console.label(8, color: widget.colour)),
          ],
        ),
      );
}
