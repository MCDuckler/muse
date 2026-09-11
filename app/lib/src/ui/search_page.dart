import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'selection_bar.dart';
import 'song_row.dart';
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
  List<SourceHit> _soundcloud = const [];
  List<SourceHit> _bandcamp = const [];
  AlbumPreview? _album;
  bool _importing = false;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  /// YouTube would not answer. Not the same as finding nothing, and the difference
  /// matters: one means try another spelling, the other means try again in a minute.
  String? _remoteError;
  String _lastQuery = '';
  Timer? _debounce;

  /// Which source the results are narrowed to, or 'all'.
  ///
  /// Everything used to be one list with YouTube Music in the middle of it, and the two
  /// the server fetches itself — SoundCloud and Bandcamp, the ones that actually sound
  /// good — underneath however many YouTube results there were. On a phone that is off
  /// the bottom of the screen, which is the same as not being there.
  String _only = 'all';

  static const _sources = <String, String>{
    'all': 'Everywhere',
    'library': 'Library',
    'ytmusic': 'YouTube Music',
    'soundcloud': 'SoundCloud',
    'bandcamp': 'Bandcamp',
  };

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
        _remoteError = null;
        _soundcloud = const [];
        _bandcamp = const [];
        _album = null;
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
    final api = context.read<AppState>().api;
    try {
      // A pasted album link is not a search: the page knows what is on the record, so
      // ask it rather than guessing from the words in the URL.
      if (q.startsWith('http') && q.contains('bandcamp.com')) {
        final preview = await api.previewAlbum(q);
        if (!mounted || _lastQuery != q) return;
        setState(() {
          _album = preview;
          _local = const [];
          _remote = const [];
          _remoteError = null;
          _soundcloud = const [];
          _bandcamp = const [];
          _searched = true;
        });
        return;
      }

      final res = await api.search(q);
      if (!mounted || _lastQuery != q) return;   // a newer query already went out
      setState(() {
        _album = null;
        _local = res.local;
        _remote = res.remote;
        _remoteError = res.remoteError;
        _searched = true;
      });

      // The other two are asked separately so a slow one never holds up the rest.
      for (final source in const ['soundcloud', 'bandcamp']) {
        api.searchSource(source, q, limit: _only == source ? 15 : 6).then((hits) {
          if (!mounted || _lastQuery != q) return;
          setState(() {
            if (source == 'soundcloud') {
              _soundcloud = hits;
            } else {
              _bandcamp = hits;
            }
          });
        }).catchError((_) {
          // One source being unreachable is not a failed search.
        });
      }
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
              hintText: 'Search, or paste a Bandcamp album link',
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
        // Where to look. Sitting above the results rather than in a menu, because the
        // answer to "why is there nothing from Bandcamp" should be one tap away.
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final entry in _sources.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _only == entry.key,
                    onSelected: (_) {
                      setState(() => _only = entry.key);
                      // A narrowed search asks that source for more than the handful
                      // it contributes to the mixed list.
                      if (_lastQuery.isNotEmpty) {
                        final q = _lastQuery;
                        _lastQuery = '';
                        _run(q);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: SelectionOver(
            bar: SelectionBar(where: 'search', tracks: _local),
            child: _searched && !_busy && _nothingAtAll
              ? _NothingFound(query: _lastQuery)
              : !_searched && !_busy
                  ? const _SearchPrompt()
                  : ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
            children: [
              if (_shows('library') && _local.isNotEmpty)
                _SectionHeader('In your library · ${_local.length}'),
              if (_shows('library'))
                for (final t in _local)
                SongRow(
                  track: t,
                  selectable: 'search',
                  onTap: () => app.addTrack(t),
                  trailing: _queueMenu(
                    onNext: () => app.addTrack(t, mode: 'next'),
                    onEnd: () => app.addTrack(t),
                    onPlaylist: () => addToPlaylistSheet(context, app, t),
                  ),
                  showMenu: false,
                ),
              if (_album != null) ..._albumRows(app),
              if (_shows('ytmusic') && _remoteError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(_remoteError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ),
              if (_shows('ytmusic') && _remote.isNotEmpty)
                _SectionHeader('On YouTube Music · ${_remote.length}'),
              if (_shows('ytmusic'))
                for (final hit in _youtubeShown)
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
              if (_shows('soundcloud')) ..._sourceRows(app, 'SoundCloud', _soundcloud),
              if (_shows('bandcamp')) ..._sourceRows(app, 'Bandcamp', _bandcamp),
              if (_shows('ytmusic') && _only == 'all' && _remote.length > _mixedCap)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextButton(
                    onPressed: () => setState(() => _only = 'ytmusic'),
                    child: Text(
                        'All ${_remote.length} YouTube Music results'),
                  ),
                ),
            ],
          ),
          ),
        ),
      ],
    );
  }

  /// How many YouTube results the mixed list shows before the other sources.
  ///
  /// Not a limit on the search — the rest are one tap away — but on how much of the
  /// screen one source may take before the others get a look in.
  static const _mixedCap = 6;

  List<RemoteHit> get _youtubeShown =>
      _only == 'all' && _remote.length > _mixedCap
          ? _remote.sublist(0, _mixedCap)
          : _remote;

  bool _shows(String source) => _only == 'all' || _only == source;

  bool get _nothingAtAll =>
      (!_shows('library') || _local.isEmpty) &&
      (!_shows('ytmusic') || _remote.isEmpty) &&
      (!_shows('soundcloud') || _soundcloud.isEmpty) &&
      (!_shows('bandcamp') || _bandcamp.isEmpty) &&
      _album == null;

  /// Hits from a source the server fetches itself. Kept below YouTube Music on purpose:
  /// SoundCloud is full of remixes, edits and thirty-second previews, so these are for
  /// when you have looked at them and chosen, not for a machine to pick from.
  List<Widget> _sourceRows(AppState app, String label, List<SourceHit> hits) {
    if (hits.isEmpty) return const [];
    return [
      _SectionHeader('On $label · ${hits.length}'),
      for (final hit in hits)
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(
                hit.provider == 'bandcamp' ? Icons.album_outlined : Icons.cloud_outlined,
                size: 18),
          ),
          title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              [hit.artistLine, hit.lengthLine].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: hit.known
              ? const Icon(Icons.check_circle_outline, size: 20)
              : _queueMenu(
                  onNext: () => _addSource(app, hit, mode: 'next'),
                  onEnd: () => _addSource(app, hit),
                ),
          onTap: () => _addSource(app, hit),
        ),
    ];
  }

  /// A pasted album link: the whole record, in order, as the artist typed it.
  List<Widget> _albumRows(AppState app) {
    final album = _album!;
    return [
      _SectionHeader('${album.artist ?? 'Album'} · ${album.album ?? ''}'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                [
                  '${album.tracks.length} tracks',
                  if (album.unavailable > 0)
                    '${album.unavailable} sold only',
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            FilledButton.icon(
              icon: _importing
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download, size: 18),
              label: const Text('Add the album'),
              onPressed: _importing ? null : () => _importAlbum(app),
            ),
          ],
        ),
      ),
      for (final t in album.tracks)
        ListTile(
          dense: true,
          leading: const Icon(Icons.music_note, size: 20),
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(t.lengthLine),
          trailing: t.known ? const Icon(Icons.check_circle_outline, size: 18) : null,
        ),
    ];
  }

  Future<void> _addSource(AppState app, SourceHit hit, {String mode = 'end'}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final track = await app.api.addFromSource(hit);
      await app.addTrack(track, mode: mode);
      messenger.showSnackBar(SnackBar(
          content: Text('Added "${hit.title}" from ${hit.sourceLabel}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _importAlbum(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = true);
    try {
      final r = await app.api.importAlbum(_lastQuery);
      await app.refreshPlaylists();
      messenger.showSnackBar(SnackBar(
          content: Text('Added "${r['name']}" — ${r['added']} tracks')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
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
