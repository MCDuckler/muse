import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'browse_page.dart';
import 'found_row.dart';
import 'selection_bar.dart';
import 'snack.dart';

/// One search across everything, in one list.
///
/// It used to be four lists one under another — your library, then YouTube Music, then
/// SoundCloud, then Bandcamp — and on a phone the third of those is off the bottom of
/// the screen, which is the same as not being there. The question somebody is actually
/// asking is "where is this song", not "what does SoundCloud have", so the answer is
/// one ranked list where every row is the same shape and a coloured dot says where it
/// came from. Narrowing to one service is still a tap away.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  List<Found> _found = const [];
  Map<String, String> _notes = const {};
  AlbumPreview? _album;
  bool _importing = false;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  String _lastQuery = '';
  Timer? _debounce;

  /// Which service the list is narrowed to, or 'all'.
  String _where = 'all';

  /// Songs, records, artists — or all three.
  String _kind = 'all';

  /// Asking the other question: not what is this called, but what are the words.
  bool _lyrics = false;

  static const _places = <String, String>{
    'all': 'Everywhere',
    'library': 'Library',
    'ytmusic': 'YouTube Music',
    'spotify': 'Spotify',
    'soundcloud': 'SoundCloud',
    'bandcamp': 'Bandcamp',
  };

  static const _kinds = <String, String>{
    'all': 'All',
    'song': 'Songs',
    'album': 'Albums',
    'artist': 'Artists',
  };

  /// Long enough not to fire on every keystroke, short enough that the results feel
  /// like they are following you. Four services are behind it, so this is also what
  /// keeps them from being hammered.
  static const _debounceDelay = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTyped() {
    setState(() {});                       // the clear button appears and disappears
    _debounce?.cancel();
    final q = _controller.text.trim();
    if (q.isEmpty) {
      setState(() {
        _found = const [];
        _notes = const {};
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
          _found = const [];
          _searched = true;
        });
        return;
      }

      final res = await api.searchEverything(
        q,
        where: _where,
        kind: _lyrics ? 'song' : _kind,
        lyrics: _lyrics,
        limit: _where == 'all' ? 40 : 50,
      );
      if (!mounted || _lastQuery != q) return;   // a newer query already went out
      setState(() {
        _album = null;
        _found = res.items;
        _notes = res.notes;
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

  void _again() {
    if (_lastQuery.isEmpty) return;
    final q = _lastQuery;
    _lastQuery = '';
    _run(q);
  }

  /// Tapping a row. What that means is the one thing that differs between them.
  Future<void> _open(Found found, {String mode = 'end'}) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    if (found.kind == 'artist') {
      if (found.place == 'library') {
        navigator.push(MaterialPageRoute(
            builder: (_) => ArtistPage(
                artist: ArtistSummary(
                    name: found.title, tracks: found.tracks ?? 0))));
      } else {
        // Somebody else's artist page is not something this app has; what it can do
        // is show everything of theirs that service has, which is the same search
        // narrowed to them.
        _controller.text = found.title;
        setState(() {
          _where = found.place;
          _kind = 'all';
        });
        _again();
      }
      return;
    }

    if (found.kind == 'album') {
      if (found.place == 'library') {
        navigator.push(MaterialPageRoute(
            builder: (_) => AlbumPage(
                album: AlbumSummary(
                    name: found.title,
                    artist: found.subtitle,
                    tracks: found.tracks ?? 0))));
        return;
      }
      await showFoundAlbum(context, found);
      return;
    }

    // A song: either it is here, or it is fetched.
    try {
      if (found.track != null) {
        await app.addTrack(found.track!, mode: mode);
        return;
      }
      final track = await app.api.addFound(found);
      await app.addTrack(track, mode: mode);
      if (mounted) saidAdded(context, found);
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final libraryTracks = [
      for (final f in _found)
        if (f.place == 'library' && f.track != null) f.track!,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _run(),
            focusNode: _focus,
            decoration: InputDecoration(
              hintText: _lyrics
                  ? 'Some of the words'
                  : 'Search, or paste a Bandcamp album link',
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
        // Where to look, and what to look for. Above the results rather than in a
        // menu, because the answer to "why is there nothing from Bandcamp" should be
        // one tap away.
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final entry in _places.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: entry.key == 'all'
                        ? null
                        : PlaceDot(entry.key, size: 8),
                    label: Text(entry.value),
                    selected: _where == entry.key,
                    onSelected: (_) {
                      setState(() => _where = entry.key);
                      _again();
                    },
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              // The other question: the words rather than the name. Songs only —
              // a record has no lyrics.
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilterChip(
                  avatar: const Icon(Icons.format_quote, size: 16),
                  label: const Text('Lyrics'),
                  selected: _lyrics,
                  onSelected: (on) {
                    setState(() => _lyrics = on);
                    _again();
                  },
                ),
              ),
              if (!_lyrics)
                for (final entry in _kinds.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: _kind == entry.key,
                      onSelected: (_) {
                        setState(() => _kind = entry.key);
                        _again();
                      },
                    ),
                  ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        // One service being unreachable is not a failed search, and it is not silence
        // either: the difference between "nothing there" and "nobody answered" is the
        // difference between trying another spelling and trying again in a minute.
        for (final note in _notes.entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                PlaceDot(note.key, size: 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(note.value,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline)),
                ),
              ],
            ),
          ),
        Expanded(
          child: SelectionOver(
            bar: SelectionBar(where: 'search', tracks: libraryTracks),
            child: _album != null
                ? ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
                    children: _albumRows(context.read<AppState>()),
                  )
                : _searched && !_busy && _found.isEmpty
                    ? _NothingFound(query: _lastQuery, lyrics: _lyrics)
                    : !_searched && !_busy
                        ? const _SearchPrompt()
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
                            itemCount: _found.length,
                            itemBuilder: (context, i) => FoundRow(
                              found: _found[i],
                              onTap: () => _open(_found[i]),
                              onPlayNext: () => _open(_found[i], mode: 'next'),
                            ),
                          ),
          ),
        ),
      ],
    );
  }

  /// A pasted album link: the whole record, in order, as the artist typed it.
  List<Widget> _albumRows(AppState app) {
    final album = _album!;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('${album.artist ?? 'Album'} · ${album.album ?? ''}',
            style: Theme.of(context).textTheme.titleSmall),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                [
                  '${album.tracks.length} tracks',
                  if (album.unavailable > 0) '${album.unavailable} sold only',
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            FilledButton.icon(
              icon: _importing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
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
          trailing:
              t.known ? const Icon(Icons.check_circle_outline, size: 18) : null,
        ),
    ];
  }

  Future<void> _importAlbum(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = true);
    try {
      final r = await app.api.importAlbum(_lastQuery);
      await app.refreshPlaylists();
      messenger.showSnackBar(
          snack(Text('Added "${r['name']}" — ${r['added']} tracks')));
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}

/// What is on a record found somewhere else, and a way to take it.
Future<void> showFoundAlbum(BuildContext context, Found found) async {
  final app = context.read<AppState>();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => _FoundAlbumSheet(
          found: found, app: app, controller: scroll),
    ),
  );
}

class _FoundAlbumSheet extends StatefulWidget {
  const _FoundAlbumSheet(
      {required this.found, required this.app, required this.controller});
  final Found found;
  final AppState app;
  final ScrollController controller;

  @override
  State<_FoundAlbumSheet> createState() => _FoundAlbumSheetState();
}

class _FoundAlbumSheetState extends State<_FoundAlbumSheet> {
  FoundAlbum? _album;
  String? _error;
  bool _taking = false;

  @override
  void initState() {
    super.initState();
    widget.app.api
        .foundAlbum(widget.found.place, widget.found.id)
        .then((a) => mounted ? setState(() => _album = a) : null)
        .catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  /// The whole record, in order. One request each, because each one is a download
  /// somewhere else and the server queues them as they arrive.
  Future<void> _takeAll() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _taking = true);
    var added = 0;
    try {
      for (final t in _album!.tracks) {
        try {
          await widget.app.api.addFound(t);
          added++;
        } catch (_) {
          // One song of a record being unavailable is not a failed record.
        }
      }
      messenger.showSnackBar(snack(
          Text('Added $added of ${_album!.tracks.length} from "${_album!.title}"')));
    } finally {
      if (mounted) setState(() => _taking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    if (_error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (album == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        ListTile(
          leading: PlaceDot(widget.found.place, size: 12),
          title: Text(album.title,
              style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text([
            album.artist ?? '',
            if (album.year != null) album.year!,
            '${album.tracks.length} songs',
          ].where((s) => s.isNotEmpty).join(' · ')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FilledButton.icon(
            icon: _taking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, size: 18),
            label: const Text('Add the record'),
            onPressed: _taking ? null : _takeAll,
          ),
        ),
        for (final t in album.tracks)
          FoundRow(
            found: t,
            onTap: () async {
              try {
                final track = await widget.app.api.addFound(t);
                await widget.app.addTrack(track);
                if (context.mounted) saidAdded(context, t);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(snack(Text('$e')));
                }
              }
            },
          ),
      ],
    );
  }
}

class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.outline);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search, size: 40),
            const SizedBox(height: 12),
            Text(
              'Songs, records and artists, from your library and from every service '
              'this server can reach — in one list.',
              textAlign: TextAlign.center,
              style: style,
            ),
            const SizedBox(height: 10),
            Text(
              'Or turn on Lyrics and type some of the words.',
              textAlign: TextAlign.center,
              style: style,
            ),
          ],
        ),
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  const _NothingFound({required this.query, required this.lyrics});
  final String query;
  final bool lyrics;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            lyrics
                ? 'Nothing with those words in it. Try a longer line, or one from '
                    'the chorus.'
                : 'Nothing for "$query" anywhere.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
}
