import 'package:flutter/material.dart';

import '../worker/parts_jobs.dart';
import 'artwork.dart';

/// Records being taken apart on this computer, on the downloads page. It is the same
/// sort of waiting as a download — slow, in a line, something to watch arrive — so it
/// is shown the same way: the one being done now with how far it has got, the line
/// behind it, what is ready and when, and what failed and why.
///
/// Nothing at all where nothing has been asked for, which is always on a phone.
class PartsJobsSection extends StatelessWidget {
  const PartsJobsSection({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: partsJobs,
        builder: (context, _) {
          final now = partsJobs.running;
          final waiting = partsJobs.waiting;
          final ready = partsJobs.ready;
          final failed = partsJobs.failed;
          if (now.isEmpty && waiting.isEmpty && ready.isEmpty && failed.isEmpty) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (now.isNotEmpty) ...[
                const _Label('Taking apart on this computer'),
                for (final j in now) _JobTile(job: j),
              ],
              if (waiting.isNotEmpty) ...[
                _Label('Waiting to be taken apart · ${waiting.length}'),
                for (final j in waiting) _JobTile(job: j),
              ],
              if (ready.isNotEmpty) ...[
                _Label('Parts ready · ${ready.length}'),
                for (final j in ready.take(12)) _JobTile(job: j),
              ],
              if (failed.isNotEmpty) ...[
                _Label('Could not take apart · ${failed.length}'),
                for (final j in failed) _JobTile(job: j),
              ],
            ],
          );
        },
      );
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});
  final PartsJob job;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final j = job;
    final t = j.track;
    final failed = j.stage == PartsStage.failed;
    final place = partsJobs.placeOf(j.trackId);
    final Widget? trailing;
    if (j.active) {
      trailing = IconButton(
        icon: const Icon(Icons.close, size: 20),
        tooltip: 'Stop',
        onPressed: () => partsJobs.onCancel?.call(j.trackId),
      );
    } else if (j.stage == PartsStage.waiting) {
      trailing = PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (v) => v == 'first'
            ? partsJobs.onPromote?.call(j.trackId)
            : partsJobs.onCancel?.call(j.trackId),
        itemBuilder: (context) => [
          if (place != null && place > 1)
            const PopupMenuItem(value: 'first', child: Text('Take apart next')),
          const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
        ],
      );
    } else if (failed) {
      trailing = IconButton(
        icon: const Icon(Icons.refresh, size: 20),
        tooltip: 'Try again',
        onPressed: () => partsJobs.onRetry?.call(j.trackId),
      );
    } else if (j.stage == PartsStage.ready) {
      trailing = Icon(Icons.check, size: 20, color: scheme.primary);
    } else {
      trailing = null;
    }
    // A fetch the house did not give a length for, and a split not yet reporting, are
    // the only times the bar cannot say how far.
    final p = j.stage == PartsStage.fetching && j.total == null
        ? null
        : j.progress ?? (j.stage == PartsStage.separating ? 0.0 : null);
    return ListTile(
      leading: t == null ? const Icon(Icons.call_split) : Artwork(track: t, size: 40),
      title: Text(j.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(stageLine(j),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: failed ? TextStyle(color: scheme.error) : null),
          if (j.active) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: p, minHeight: 3),
            ),
          ],
        ],
      ),
      trailing: trailing,
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
