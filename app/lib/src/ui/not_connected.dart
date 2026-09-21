import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/connection.dart';
import '../state/app_state.dart';
import 'motion.dart';

/// One line, when the server cannot be reached.
///
/// The symptom used to be spread across whichever screen you were on: a list that
/// spun forever, an error in one page's own words, a snack bar that had already gone
/// by the time you read it. None of them said the thing that was true — the phone
/// cannot get to the box — and none of them said when it came back, so the only way
/// to find out was to tap something and see.
///
/// This sits above the player, where it is visible from every page, and it clears
/// itself: while it is up it quietly asks the server if it is there yet, so coming
/// back onto wifi takes the bar away without anybody pressing anything.
class NotConnected extends StatefulWidget {
  const NotConnected({super.key});

  @override
  State<NotConnected> createState() => _NotConnectedState();
}

class _NotConnectedState extends State<NotConnected> {
  Timer? _asking;
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    serverIsThere.addListener(_changed);
    if (!serverIsThere.value) _startAsking();
  }

  @override
  void dispose() {
    serverIsThere.removeListener(_changed);
    _asking?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (serverIsThere.value) {
      _asking?.cancel();
      _asking = null;
    } else {
      _startAsking();
    }
  }

  void _startAsking() {
    _asking?.cancel();
    // Five seconds: often enough that walking back into wifi feels immediate, rare
    // enough that a box which is actually down is not being hammered by every device
    // in the house.
    _asking = Timer.periodic(const Duration(seconds: 5), (_) => _ask());
  }

  Future<void> _ask() async {
    if (_inFlight || !mounted) return;
    final app = context.read<AppState>();
    if (app.user == null) return;       // nothing to check with, and nothing to show
    _inFlight = true;
    try {
      // The cheapest authenticated call there is. Success flips the flag inside the
      // client itself, so there is nothing to do with the answer.
      await app.api.me();
      if (mounted) await app.backOnline();
    } catch (_) {
      // Still away. The next tick will try again.
    } finally {
      _inFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kept = context.select<AppState, int>((a) => a.offline.count);
    return AnimatedSize(
      duration: stillness(context) ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: serverIsThere.value
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              child: LayoutBuilder(builder: (context, box) {
                final say = Text(
                  // What is true *and* what can still be done: on a train with kept
                  // music, "no connection" is a very different sentence depending on
                  // whether anything will still play.
                  kept > 0
                      ? "Can't reach the server — $kept kept songs still play"
                      : "Can't reach the server",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                );
                final retry = TextButton(
                  onPressed: _inFlight ? null : _ask,
                  style: TextButton.styleFrom(foregroundColor: scheme.onErrorContainer),
                  child: const Text('Try again'),
                );
                final icon =
                    Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer);
                // Side by side where there is room. With the type made large on a small
                // phone the button took most of the row and squeezed the sentence into a
                // column one word wide, so there the button goes underneath instead.
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                if (box.maxWidth >= 300 * scale) {
                  return Row(children: [
                    icon,
                    const SizedBox(width: 10),
                    Expanded(child: say),
                    retry,
                  ]);
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(padding: const EdgeInsets.only(top: 2), child: icon),
                      const SizedBox(width: 10),
                      Expanded(child: say),
                    ]),
                    Align(alignment: Alignment.centerRight, child: retry),
                  ],
                );
              }),
            ),
    );
  }
}
