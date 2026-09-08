import 'dart:async';

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
  final _focus = FocusNode();
  List<Track> _local = const [];
  List<RemoteHit> _remote = const [];
  bool _busy = false;
  bool _searched = false;
  String? _error;
  String _lastQuery = '';
  Timer? _debounce;

  /// Long enough not to fire on every keystroke, short enough that it feels like the
  /// results are following you. The remote leg goes out to YouTube Music, so this is
  /// also what keeps that from being hammered.
  static const _debounceDelay = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
  }

  void _onTyped() {
    setState(() {});                       // the clear button appears and disappears
    _debounce?.cancel();
    final q = _controller.text.trim();
    if (q.isEmpty) {
      setState(() {
        _local = const [];
        _remote = const [];
        _searched = false;
      });
      return;
    }
    if (q == _lastQuery) return;
    _debounce = Timer(_debounceDelay, () => _run(q));
  }

  Future<void> _run([String? query]) async {
    final q = (query ?? _controller.text).trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    _lastQuery = q;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await context.read<AppState>().api.search(q);
      if (!mounted || _lastQuery != q) return;   // a newer query already went out
      setState(() {
        _local = res.local;
        _remote = res.remote;
        _searched = true;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
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
            focusNode: _focus,
            decoration: InputDecoration(
              hintText: 'Search your library and YouTube Music',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : (_controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Clear',
                          onPressed: () {
                            _controller.clear();
                            _focus.requestFocus();
                          },
                        )),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: _searched && _local.isEmpty && _remote.isEmpty && !_busy
              ? _NothingFound(query: _lastQuery)
              : !_searched && !_busy
                  ? const _SearchPrompt()
                  : ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
            children: [
              if (_local.isNotEmpty)
                _SectionHeader('In your library · ${_local.length}'),
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
              if (_remote.isNotEmpty)
                _SectionHeader('On YouTube Music · ${_remote.length}'),
              for (final hit in _remote)
                ListTile(
                  leading: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Artwork(
                          url: app.api.remoteCoverUrl(hit.coverPath), size: 40),
                      if (hit.known)
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.check_circle,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary),
                        ),
                    ],
                  ),
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
    _debounce?.cancel();
    _controller.removeListener(_onTyped);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }
}

/// Before the first search. An empty list here would look like a failed search.
class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search,
                  size: 44, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('Find something to play',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Your library first, then YouTube Music.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}

/// And after one that found nothing — which used to look identical to never having
/// searched at all.
class _NothingFound extends StatelessWidget {
  const _NothingFound({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off,
                  size: 44, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('Nothing found for “$query”',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Try a different spelling, or add the artist’s name.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
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
