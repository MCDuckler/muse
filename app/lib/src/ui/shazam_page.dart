import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'mini_player.dart';
import 'selection_bar.dart';
import 'song_row.dart';

/// Songs Shazam recognised, in the order they were recognised.
///
/// A list of tags is a record of where somebody has been as much as what they like —
/// the useful thing to do with it is not to play it but to go through it and keep the
/// ones worth keeping. So it is a list you pick from: hold a row, take the ones you
/// want, put them on a playlist. What cannot be matched is still shown, because the
/// name of a song heard in a bar at two in the morning is worth having whether or not
/// anything here can play it.
class ShazamPage extends StatefulWidget {
  const ShazamPage({super.key});

  @override
  State<ShazamPage> createState() => _ShazamPageState();
}

class _ShazamPageState extends State<ShazamPage> {
  Future<Shazams>? _future;
  bool _busy = false;
  bool _onlyUnmatched = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final pending = context
        .read<AppState>()
        .api
        .shazams(unmatched: _onlyUnmatched);
    setState(() => _future = pending);
  }

  /// The CSV from shazam.com.
  ///
  /// There is no way to ask Shazam for somebody's library — it has no API for your own
  /// tags — so the file is the whole of the interface, and the instructions have to be
  /// on the screen rather than somewhere else.
  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<AppState>().api;
    final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        dialogTitle: 'Shazam library');
    if (file == null || !mounted) return;

    setState(() => _busy = true);
    try {
      // Bytes rather than a path: the web build never has one.
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      final out = await api.importShazams(text);
      final added = (out['added'] ?? 0) as int;
      final already = (out['already_here'] ?? 0) as int;
      messenger.showSnackBar(SnackBar(
          content: Text(added == 0
              ? 'Nothing new — all $already were already here'
              : 'Added $added, looking them up now')));
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _when(DateTime? at) {
    if (at == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final ago = today.difference(day).inDays;
    final time = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    if (ago == 0) return 'Today $time';
    if (ago == 1) return 'Yesterday $time';
    if (ago < 7) return '$ago days ago, $time';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('Shazams'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Import a Shazam library',
            onPressed: _busy ? null : _import,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Look again for the ones that found nothing',
            onPressed: _busy
                ? null
                : () async {
                    await app.api.matchShazams();
                    if (mounted) _load();
                  },
          ),
        ],
      ),
      body: FutureBuilder<Shazams>(
        future: _future,
        builder: (context, snap) {
          if (_busy || !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          if (data.total == 0) return const _Nothing();

          final rows = data.items;
          final where = 'shazams';
          return Column(
            children: [
              SelectionBar(
                where: where,
                tracks: [
                  for (final s in rows)
                    if (s.track != null) s.track!
                ],
              ),
              _Summary(
                data: data,
                onlyUnmatched: _onlyUnmatched,
                onFilter: (v) {
                  setState(() => _onlyUnmatched = v);
                  _load();
                },
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async => _load(),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, bottomForPlayer),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final tag = rows[i];
                      final track = tag.track;
                      if (track == null) {
                        return _Unmatched(tag: tag, when: _when(tag.taggedAt));
                      }
                      return SongRow(
                        key: ValueKey('shazam-${tag.id}'),
                        track: track,
                        selectable: where,
                        showAlbum: false,
                        trailing: Text(_when(tag.taggedAt),
                            style: Theme.of(context).textTheme.labelSmall),
                        onTap: () => app.playNow([track], named: 'Shazams'),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// How many there are, how many were found, and a way to see only the ones that were
/// not — which is the list worth going through by hand.
class _Summary extends StatelessWidget {
  const _Summary(
      {required this.data, required this.onlyUnmatched, required this.onFilter});
  final Shazams data;
  final bool onlyUnmatched;
  final ValueChanged<bool> onFilter;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              data.waiting > 0
                  ? '${data.total} tags · ${data.waiting} still being looked up'
                  : '${data.total} tags · ${data.matched} here',
              style: text.bodySmall,
            ),
          ),
          FilterChip(
            label: const Text('Not found'),
            selected: onlyUnmatched,
            onSelected: onFilter,
          ),
        ],
      ),
    );
  }
}

/// A tag nothing here answers to.
///
/// Shown rather than hidden. The name of a song heard once in a bar is worth having
/// whether or not the library can play it — and the link goes back to Shazam, which
/// still knows what it was.
class _Unmatched extends StatelessWidget {
  const _Unmatched({required this.tag, required this.when});
  final Shazam tag;
  final String when;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: Icon(
            tag.waiting ? Icons.hourglass_empty : Icons.help_outline,
            size: 20,
            color: scheme.outline,
          ),
        ),
      ),
      title: Text(tag.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurfaceVariant)),
      subtitle: Text(
        [
          if (tag.artist != null) tag.artist!,
          tag.waiting ? 'looking…' : 'not in the library',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(when, style: Theme.of(context).textTheme.labelSmall),
      onTap: tag.url == null
          ? null
          // Back to Shazam, which still knows what it was even when nothing here
          // does.
          : () => unawaited(launchUrl(Uri.parse(tag.url!),
              mode: LaunchMode.externalApplication)),
    );
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, size: 44),
            const SizedBox(height: 14),
            Text('Nothing from Shazam yet', style: text.titleMedium),
            const SizedBox(height: 10),
            // Said here because there is nowhere else to say it: Shazam has no way of
            // being asked what somebody has tagged, so the file is the whole interface
            // and the steps have to be on the screen that needs them.
            Text(
              'Shazam has no way of being asked what you have tagged, but it will '
              'hand the lot over:\n\n'
              '1.  Open shazam.com and sign in\n'
              '2.  My Shazam → the ⋯ menu → Export as CSV\n'
              '3.  Bring that file here with the button above\n\n'
              'Everything in it gets looked up in your library. What is found you can '
              'put on a playlist; what is not is kept anyway, with the night you '
              'heard it.',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
