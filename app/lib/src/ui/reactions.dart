import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'mag.dart';
import 'motion.dart';

/// Over everything, on every page: a reaction is about the music, and the music goes
/// on whichever page is open.
class ReactionLayer extends StatefulWidget {
  const ReactionLayer({super.key, required this.child});
  final Widget child;

  @override
  State<ReactionLayer> createState() => _ReactionLayerState();
}

class _Floating {
  _Floating(this.reaction, this.across, this.sway, this.key);
  final Reaction reaction;
  final double across;   // where along the bottom it starts, 0 to 1
  final double sway;     // which way it leans as it rises
  final Key key;
}

class _ReactionLayerState extends State<ReactionLayer> {
  StreamSubscription<Reaction>? _sub;
  final _up = <_Floating>[];
  final _chance = math.Random();
  var _count = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= context.read<AppState>().reactions.listen((r) {
      if (!mounted) return;
      setState(() {
        // A dozen at once is a celebration; any more is a screen nobody can use.
        if (_up.length >= 12) _up.removeAt(0);
        _up.add(_Floating(r, 0.18 + _chance.nextDouble() * 0.64,
            _chance.nextDouble() * 2 - 1, ValueKey(_count++)));
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_up.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  children: [
                    for (final f in _up)
                      _Rising(
                        key: f.key,
                        floating: f,
                        onGone: () {
                          if (mounted) setState(() => _up.remove(f));
                        },
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
}

class _Rising extends StatefulWidget {
  const _Rising({super.key, required this.floating, required this.onGone});
  final _Floating floating;
  final VoidCallback onGone;

  @override
  State<_Rising> createState() => _RisingState();
}

class _RisingState extends State<_Rising> with SingleTickerProviderStateMixin {
  late final AnimationController _life = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3000))
    ..forward().whenComplete(widget.onGone);

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.floating;
    final scheme = Theme.of(context).colorScheme;
    final still = stillness(context);
    return Positioned.fill(child: LayoutBuilder(builder: (context, box) {
      return AnimatedBuilder(
        animation: _life,
        builder: (context, child) {
          final t = _life.value;
          // Asked not to animate: it appears in place, stays, and goes.
          final rise = still ? 0.35 : Curves.easeOutCubic.transform(t);
          final x = box.maxWidth * f.across +
              (still ? 0 : math.sin(t * math.pi * 2.2) * 14 * f.sway);
          final y = box.maxHeight * (0.86 - 0.52 * rise);
          final pop = still ? 1.0 : Curves.easeOutBack.transform((t / 0.18).clamp(0.0, 1.0));
          final fade = t < 0.72 ? 1.0 : (1 - (t - 0.72) / 0.28).clamp(0.0, 1.0);
          return Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: Offset(x - 60, y - 40),
              child: SizedBox(
                width: 120,
                child: Opacity(
                  opacity: fade,
                  child: Transform.scale(scale: 0.4 + 0.6 * pop, child: child),
                ),
              ),
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(f.reaction.emoji,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(fontSize: 46, height: 1.1)),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              color: scheme.onSurface,
              child: Text(
                f.reaction.sent
                    ? 'to ${f.reaction.who}'.toUpperCase()
                    : f.reaction.who.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: Mag.flag(10, color: scheme.surface),
              ),
            ),
          ],
        ),
      );
    }));
  }
}

/// The row of things to say, under somebody who is playing something.
class ReactionRow extends StatelessWidget {
  const ReactionRow({super.key, required this.personId, required this.name, this.trackId});

  final int personId;
  final String name;
  final int? trackId;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Wrap(
      spacing: 2,
      children: [
        for (final emoji in reactionEmoji)
          Semantics(
            button: true,
            label: 'Send $emoji to $name',
            excludeSemantics: true,
            child: InkResponse(
              radius: 22,
              onTap: () => app.react(personId, name, emoji, trackId: trackId),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Text(emoji,
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(fontSize: 22, height: 1.1)),
              ),
            ),
          ),
      ],
    );
  }
}
