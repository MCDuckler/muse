import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../mag.dart';
import '../mag_parts.dart';
import '../song_row.dart';

/// The queue, as a crate: what could go on next, with what a DJ wants to know about
/// each — its tempo and its key, and whether it mixes with what is on the master.
///
/// Mixable first: within eight per cent of the master's tempo (half and double time
/// count) and a step or less away on the wheel. Tapping a record puts it on
/// whichever deck is not the master.
class Crate extends StatelessWidget {
  const Crate({super.key, required this.booth, required this.onPick});
  final Booth booth;
  final void Function(Track track) onPick;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final items = [for (final t in app.player?.items ?? const <Track>[]) if (t.isReady) t];
    final master = booth.master.timing;

    // Sorted by what is known now; a timing still on its way sorts as unknown and the
    // list settles as answers land.
    int score(Track t) {
      final tm = booth.timing.peek(t.id);
      if (tm == null || master == null) return 2;
      final tempoOk = tm.bpm != null && master.bpm != null && Booth.syncRatio(tm.bpm!, master.bpm!) != null;
      final keyOk = tm.inKeyWith(master);
      return tempoOk && keyOk ? 0 : tempoOk || keyOk ? 1 : 3;
    }

    final sorted = [...items]..sort((a, b) => score(a).compareTo(score(b)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: SectionFlag('The crate'),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Text('Nothing in the queue that is here to play. Queue some records first.',
                style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: sorted.length,
            itemBuilder: (context, i) {
              final t = sorted[i];
              return SongRow(
                track: t,
                dense: true,
                showAlbum: false,
                showMenu: false,
                showDuration: false,
                swipeToPlayNext: false,
                plays: false,
                trailing: _Facts(booth: booth, track: t),
                onTap: () => onPick(t),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A record's tempo and key, once known, and whether it sits with the master.
class _Facts extends StatelessWidget {
  const _Facts({required this.booth, required this.track});
  final Booth booth;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<TrackTiming?>(
      future: booth.timing.of(track),
      initialData: booth.timing.peek(track.id),
      builder: (context, snap) {
        final tm = snap.data;
        if (tm == null) return const SizedBox(width: 40);
        final master = booth.master.timing;
        final tempoOk = tm.bpm != null && master?.bpm != null && Booth.syncRatio(tm.bpm!, master!.bpm!) != null;
        final keyOk = master != null && tm.inKeyWith(master);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tm.bpm != null)
              Text(tm.bpm!.toStringAsFixed(0),
                  style: Mag.numerals(13, color: tempoOk ? scheme.primary : scheme.onSurfaceVariant)),
            if (tm.camelot != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.fromLTRB(4, 1, 4, 0),
                decoration: BoxDecoration(
                  border: Border.all(color: (keyOk ? scheme.primary : scheme.outline).withValues(alpha: 0.8)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(tm.camelot!,
                    style: Mag.typewriter(9.5, color: keyOk ? scheme.primary : scheme.onSurfaceVariant, bold: true)),
              ),
            ],
          ],
        );
      },
    );
  }
}
