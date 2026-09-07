import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';

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
            children: [
              if (_local.isNotEmpty) const _SectionHeader('In your library'),
              for (final t in _local)
                ListTile(
                  leading: const Icon(Icons.library_music_outlined),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _addButton(context, () => app.addTrack(t)),
                  onTap: () => app.addTrack(t, mode: 'next'),
                ),
              if (_remote.isNotEmpty) const _SectionHeader('On YouTube Music'),
              for (final hit in _remote)
                ListTile(
                  leading: Icon(hit.known ? Icons.check_circle_outline : Icons.cloud_download_outlined),
                  title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(hit.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _addButton(context, () => _fetch(hit)),
                  onTap: () => _fetch(hit),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _addButton(BuildContext context, VoidCallback onTap) =>
      IconButton(icon: const Icon(Icons.playlist_add), onPressed: onTap);

  Future<void> _fetch(RemoteHit hit) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final track = await app.api.resolve(videoId: hit.videoId);
      await app.addTrack(track);
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
