import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'selection_bar.dart';
import 'song_row.dart';

/// What is on the phone.
///
/// The rest of the app is a window onto a server; this is the part that is not. It
/// lists what was chosen, what it costs in space, and what is being fetched right now
/// — and it is the screen to open before getting on a plane, which is why it says the
/// size in a place nobody has to look for.
class KeptPage extends StatelessWidget {
  const KeptPage({super.key});

  static String size(int bytes) {
    if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
    if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
    return '${(bytes / 1e3).toStringAsFixed(0)} kB';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final offline = app.offline;
    final kept = offline.kept.toList()
      ..sort((a, b) => b.keptAt.compareTo(a.keptAt));

    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('Kept on this device'),
        actions: [
          if (kept.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Stop keeping everything',
              onPressed: () async {
                final sure = await confirm(
                    context,
                    'Stop keeping all ${kept.length} songs?',
                    'They stay in your library and stream as before; the '
                        '${size(offline.bytes)} on this device is freed.');
                if (sure) await offline.forgetAll();
              },
            ),
        ],
      ),
      body: SelectionOver(
        bar: SelectionBar(
          where: 'kept',
          tracks: [for (final e in kept) e.asTrack],
          removeLabel: 'Stop keeping here',
          onRemove: (picked) async {
            for (final t in picked) {
              await offline.forget(t.id);
            }
          },
        ),
        child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, bottomForPlayer),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Text(
              kept.isEmpty
                  ? 'Nothing is kept here yet. Anything you keep plays with no signal '
                      'at all — from a song\'s menu, from a selection, or from the '
                      'menu on a playlist or a record.'
                  : '${kept.length} songs · ${size(offline.bytes)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (offline.downloading != null || offline.waiting > 0)
            Card(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: ListTile(
                leading: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: offline.progress == 0 ? null : offline.progress),
                ),
                title: Text(offline.downloading == null
                    ? 'Waiting'
                    : 'Keeping ${offline.waiting + 1} more'),
                subtitle: Text(offline.waiting == 0
                    ? 'Almost done'
                    : '${offline.waiting} still to fetch'),
                trailing: TextButton(
                  onPressed: offline.stopWaiting,
                  child: const Text('Stop'),
                ),
              ),
            ),
          if (offline.lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(offline.lastError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          for (final entry in kept)
            SongRow(
              track: entry.asTrack,
              selectable: 'kept',
              swipeToPlayNext: false,
              trailing: Text(size(entry.bytes),
                  style: Theme.of(context).textTheme.bodySmall),
              onSwipeAway: () => offline.forget(entry.id),
              onTap: () => app.playNow(
                  [for (final e in kept) e.asTrack],
                  startAt: kept.indexOf(entry),
                  named: 'Kept here'),
              onRemove: () => offline.forget(entry.id),
            ),
        ],
        ),
      ),
    );
  }
}
