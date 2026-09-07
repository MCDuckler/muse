import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';

/// Local catalog first, then YouTube Music. Anything already in the library is marked,
/// so you never queue a second copy of what you have.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  List<Track> _local = const [];
  List<RemoteHit> _remote = const [];
  bool _busy = false;
  String? _error;

  Future<void> _run() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await context.read<AppState>().api.search(q);
      setState(() {
        _local = res.local;
        _remote = res.remote;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _run(),
            decoration: InputDecoration(
              hintText: 'Search your library and YouTube Music',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _run),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
            children: [
              if (_local.isNotEmpty) const _SectionHeader('In your library'),
              for (final t in _local)
                ListTile(
                  leading: Artwork(track: t, size: 40),
                  title: Text(t.displayTitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _queueMenu(
                    onNext: () => app.addTrack(t, mode: 'next'),
                    onEnd: () => app.addTrack(t),
                    onPlaylist: () => addToPlaylistSheet(context, app, t),
                  ),
                  onTap: () => app.addTrack(t),
                ),
              if (_remote.isNotEmpty) const _SectionHeader('On YouTube Music'),
              for (final hit in _remote)
                ListTile(
                  leading: Icon(hit.known ? Icons.check_circle_outline : Icons.cloud_download_outlined),
                  title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(hit.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _queueMenu(
                    onNext: () => _fetch(hit, mode: 'next'),
                    onEnd: () => _fetch(hit),
                  ),
                  onTap: () => _fetch(hit),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// "Play next" and "add to end" both existed in the API but were distinguished only
  /// by tap-versus-button, which nobody would ever discover.
  Widget _queueMenu({
    required VoidCallback onNext,
    required VoidCallback onEnd,
    VoidCallback? onPlaylist,
  }) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.playlist_add),
        tooltip: 'Add to queue',
        onSelected: (v) => switch (v) {
          'next' => onNext(),
          'playlist' => onPlaylist?.call(),
          _ => onEnd(),
        },
        itemBuilder: (context) => [
          if (onPlaylist != null)
            const PopupMenuItem(
              value: 'playlist',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.library_add),
                title: Text('Add to playlist…'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ...const [
          PopupMenuItem(
            value: 'next',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.playlist_play),
              title: Text('Play next'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'end',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.playlist_add),
              title: Text('Add to end'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
        ],
      );

  Future<void> _fetch(RemoteHit hit, {String mode = 'end'}) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final track = await app.api.resolve(videoId: hit.videoId);
      await app.addTrack(track, mode: mode);
      messenger.showSnackBar(SnackBar(
        content: Text(track.isReady
            ? 'Added ${track.title}'
            : 'Queued ${track.title} — downloading'),
      ));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.message.trim().isEmpty ? 'Failed (${e.status})' : e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(letterSpacing: 1.2)),
      );
}
