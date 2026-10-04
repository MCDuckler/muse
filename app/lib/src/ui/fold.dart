import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'mag_parts.dart';
import 'motion.dart';

/// A section of the library that can be made smaller: shrunk to a line a row, or
/// closed down to its head.
///
/// The head is the black flag every section already had. Tapping it opens and closes
/// the section, and the two small buttons beside it say which is which for anybody who
/// would not think to tap a heading. How each section was left is remembered per
/// device — see [AppState.closedSections].
class LibraryFold extends StatelessWidget {
  const LibraryFold({
    super.key,
    required this.id,
    required this.title,
    required this.builder,
    this.actions = const [],
    this.top = 24,
    this.canShrink = true,
  });

  /// What the fold is remembered under. Stable: renaming a section must not open it.
  final String id;
  final String title;

  /// The section's body, told whether it is shrunk. Only built while it is open, so a
  /// closed section that asks a server for something does not ask.
  final Widget Function(BuildContext context, bool shrunk) builder;

  /// Buttons of the section's own, next to the fold's. Hidden while it is closed: a
  /// "New" beside a closed list makes something you cannot see.
  final List<Widget> actions;
  final double top;
  final bool canShrink;

  @override
  Widget build(BuildContext context) {
    final closed = context.select<AppState, bool>((a) => a.closedSections.contains(id));
    final shrunk = context.select<AppState, bool>((a) => a.shrunkSections.contains(id));
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

    Widget button(IconData icon, String tip, VoidCallback onTap) => IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          color: scheme.onSurfaceVariant,
          onPressed: onTap,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(8, top, 0, closed ? 0 : 4),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  expanded: !closed,
                  child: InkWell(
                    onTap: () => app.setSectionClosed(id, !closed),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SectionFlag(title),
                    ),
                  ),
                ),
              ),
              if (!closed) ...[
                for (final a in actions) ...[const SizedBox(width: 6), a],
                if (canShrink)
                  button(
                    shrunk ? Icons.open_in_full : Icons.close_fullscreen,
                    shrunk ? 'Show it in full' : 'Shrink it',
                    () => app.setSectionShrunk(id, !shrunk),
                  ),
              ],
              button(
                closed ? Icons.expand_more : Icons.expand_less,
                closed ? 'Open' : 'Close',
                () => app.setSectionClosed(id, !closed),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: moving(context, Motion.base),
          curve: Motion.enter,
          alignment: Alignment.topCenter,
          child: closed ? const SizedBox(height: 0) : builder(context, shrunk),
        ),
      ],
    );
  }
}
