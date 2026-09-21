import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import 'artwork.dart';
import 'browse_page.dart';
import 'dialogs.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'feed_page.dart';
import 'kept_page.dart';
import 'listening_page.dart';
import 'mini_player.dart';
import 'pane.dart';
import 'selection_bar.dart';
import 'spotify_page.dart' show UnmatchedPage;
import 'song_row.dart';
import 'snack.dart';
import 'skeleton.dart';
import 'theme.dart';
import 'track_list.dart';
import 'record_refresh.dart';


class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return RecordRefresh(
      onRefresh: app.refresh,
      child: ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // The contents page: every way into the library, each with a number that is
        // true about it.
        const _Contents(),
        // Lists nobody made: questions about the library, answered when asked.
        const _SmartLists(),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
          child: Row(
            children: [
              Expanded(child: SectionFlag('Playlists · ${app.playlists.length}')),
              PressButton(
                label: 'New',
                onTap: () async {
                  final name = await promptForName(context, 'New playlist');
                  if (name == null) return;
                  await app.api.createPlaylist(name);
                  await app.refreshPlaylists();
                },
              ),
            ],
          ),
        ),
        for (final p in app.playlists)
          ListTile(
            // Favourites gets the heart it is filled with rather than a cover made of
            // whatever happens to be in it first.
            leading: p.isFavourites
                ? SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.favorite,
                        color: Theme.of(context).colorScheme.primary),
                  )
                : PlaylistArt(playlist: p, size: 44),
            title: Row(
              children: [
                Flexible(
                  child: Text(p.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (p.isMirror) ...[
                  const SizedBox(width: 8),
                  _SourceTag(kind: p.kind),
                ],
              ],
            ),
            // No account name: whose Spotify a mirror came from is the same answer
            // for every mirror on the screen, and it was crowding out the counts that
            // differ. The service is already on the row as an icon.
            subtitle: Text([
              '${p.itemCount} tracks',
              // Somebody else's, kept here. Whose it is belongs on the row: a list
              // you cannot change is confusing until you can see it is not yours.
              if (p.saved) 'from ${p.ownerName ?? 'somebody'}',
              if (p.openEdit && p.mine) 'shared',
              if (p.unmatched > 0) '${p.unmatched} not matched',
            ].join(' · ')),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) async {
                if (v == 'link') {
                  await copyLink(context, '/p/${p.id}', p.name);
                } else if (v == 'export' || v == 'export-csv') {
                  // Opened rather than downloaded here: the server answers with a
                  // file and a filename, so the browser saves it and a phone hands it
                  // to whatever opens playlists.
                  await launchUrl(
                      Uri.parse(app.api.playlistExportUrl(p.id,
                          format: v == 'export' ? 'm3u' : 'csv')),
                      mode: LaunchMode.externalApplication);
                } else if (v == 'play' || v == 'shuffle') {
                  final full = await app.api.playlist(p.id);
                  await app.playNow(full.items, shuffle: v == 'shuffle');
                } else if (v == 'clone') {
                  final name = await promptForName(
                      context, 'Copy playlist', '${p.name} (copy)');
                  if (name == null) return;
                  await app.api.clonePlaylist(p.id, name: name);
                  await app.refreshPlaylists();
                } else if (v == 'unmatched') {
                  if (!context.mounted) return;
                  await openPage(context,
                      (_) => UnmatchedPage(playlistId: p.id, name: p.name));
                  await app.refreshPlaylists();
                } else if (v == 'resync') {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await app.api.syncSpotify();
                    await app.refreshPlaylists();
                    messenger.say(
                        snack(Text('Refreshed from Spotify')));
                  } catch (e) {
                    messenger.say(snack(Text('$e')));
                  }
                } else if (v == 'keep') {
                  final messenger = ScaffoldMessenger.of(context);
                  final full = await app.api.playlist(p.id);
                  final ready = [for (final t in full.items) if (t.isReady) t];
                  if (!context.mounted) return;
                  final bytes = ready.length;
                  final sure = await confirm(
                      context,
                      'Keep "${p.name}" on this device?',
                      '$bytes ${bytes == 1 ? 'song' : 'songs'} are downloaded to the '
                          'phone and play with no signal. Songs still being fetched by '
                          'the server are skipped.',
                      action: 'Keep');
                  if (!sure) return;
                  await app.keepOffline(ready);
                  messenger.say(
                      snack(Text('Keeping $bytes songs')));
                } else if (v == 'forget') {
                  final full = await app.api.playlist(p.id);
                  for (final t in full.items) {
                    await app.forgetOffline(t.id);
                  }
                } else if (v == 'cover') {
                  final messenger = ScaffoldMessenger.of(context);
                  final file = await FilePicker.pickFile(type: FileType.image);
                  if (file == null) return;
                  try {
                    await app.api
                        .setPlaylistCover(p.id, await file.readAsBytes());
                    await app.refreshPlaylists();
                  } catch (e) {
                    messenger.say(snack(Text('$e')));
                  }
                } else if (v == 'drawn-cover') {
                  await app.api.clearPlaylistCover(p.id);
                  await app.refreshPlaylists();
                } else if (v == 'rename') {
                  final name = await promptForName(context, 'Rename playlist', p.name);
                  if (name == null) return;
                  await app.api.renamePlaylist(p.id, name);
                  await app.refreshPlaylists();
                } else if (v == 'delete') {
                  final ok = await confirm(context, 'Delete "${p.name}"?',
                      'The tracks stay in your library.');
                  if (!ok) return;
                  await app.api.deletePlaylist(p.id);
                  await app.refreshPlaylists();
                } else if (v == 'queue') {
                  final messenger = ScaffoldMessenger.of(context);
                  final full = await app.api.playlist(p.id);
                  await app.addTracks(full.items);
                  messenger.say(snack(Text(
                      '${full.items.length} added to '
                      '"${app.activeQueue?.name ?? 'the queue'}"')));
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'play', child: Text('Play')),
                const PopupMenuItem(value: 'shuffle', child: Text('Shuffle')),
                const PopupMenuItem(value: 'queue', child: Text('Add all to queue')),
                if (OfflineStore.supported) ...[
                  const PopupMenuItem(
                      value: 'keep', child: Text('Keep on this device')),
                  const PopupMenuItem(
                      value: 'forget', child: Text('Stop keeping here')),
                ],
                // A playlist draws its own cover from the records in it; this is for
                // when you have a picture in mind instead.
                const PopupMenuItem(value: 'cover', child: Text('Choose a cover…')),
                // Out, for once. Everything about this library comes in and nothing
                // has ever left it.
                const PopupMenuItem(value: 'link', child: Text('Copy a link')),
                const PopupMenuItem(value: 'export', child: Text('Export as M3U')),
                const PopupMenuItem(
                    value: 'export-csv', child: Text('Export as a spreadsheet')),
                if (p.customCover)
                  const PopupMenuItem(
                      value: 'drawn-cover', child: Text('Use the drawn cover')),
                if (p.isMirror) ...[
                  const PopupMenuItem(
                      value: 'clone', child: Text('Make an editable copy')),
                  if (p.unmatched > 0)
                    PopupMenuItem(
                        value: 'unmatched',
                        child: Text('${p.unmatched} songs not matched…')),
                  // Only where there is something to refresh from: this called the
                  // Spotify sync whatever the playlist mirrored, so a YouTube Music
                  // list offered "Refresh from Spotify" and then did nothing to it.
                  if (p.kind == 'spotify')
                    const PopupMenuItem(
                        value: 'resync', child: Text('Refresh from Spotify')),
                ] else if (!p.isFavourites)
                  const PopupMenuItem(value: 'rename', child: Text('Rename…')),
                // Favourites has no delete: it is where the heart button puts things,
                // and the way to empty it is to unheart them.
                if (!p.isFavourites)
                  const PopupMenuItem(
                      value: 'delete', child: Text('Remove from WetOwl')),
              ],
            ),
            onTap: () => openPage(
                context, (_) => PlaylistPage(playlistId: p.id, name: p.name)),
          ),
        if (app.playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No playlists yet.')),
          ),
      ],
      ),
    );
  }
}

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key, required this.playlistId, required this.name});
  final int playlistId;
  final String name;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  late Future<Playlist> _future;

  /// What the last load said about whose list this is. Held rather than read off the
  /// future, because the buttons that act on it live in the app bar, which is built
  /// before the body has anything.
  Playlist? _list;

  @override
  void initState() {
    super.initState();
    _future = _ask();
  }

  Future<Playlist> _ask() async {
    final list = await context.read<AppState>().api.playlist(widget.playlistId);
    if (mounted) setState(() => _list = list);
    return list;
  }

  void _reload() => setState(() {
        _future = _ask();
      });

  /// Take a row off the list, and offer to put it back where it was.
  ///
  /// The swipe is the easiest gesture in the app to make by accident, and this was
  /// the one place it still could not be taken back.
  Future<void> _remove(Playlist list, int pos) async {
    if (pos < 0 || pos >= list.items.length) return;
    final app = context.read<AppState>();
    final track = list.items[pos];
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.removePlaylistItem(widget.playlistId, pos);
    } catch (e) {
      messenger.say(problem(e));
      return;
    }
    await app.refreshPlaylists();
    _reload();
    messenger.say(snack(
      Text('Removed ${track.displayTitle}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          try {
            // Back on the end, then walked home to where it was.
            final back = await app.api.addToPlaylist(widget.playlistId, [track.id]);
            final landed = back.items.length - 1;
            if (landed != pos && pos < back.items.length) {
              await app.api.movePlaylistItem(widget.playlistId, landed, pos);
            }
          } catch (e) {
            messenger.say(problem(e));
          }
          await app.refreshPlaylists();
          _reload();
        },
      ),
    ));
  }

  /// Keeping somebody else's list, or letting it go again.
  Future<void> _keep(Playlist list) async {
    final api = context.read<AppState>().api;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      list.saved
          ? await api.unsavePlaylist(list.id)
          : await api.savePlaylist(list.id);
      await app.refreshPlaylists();
      _reload();
      messenger.say(snack(Text(list.saved
          ? 'Removed from your library'
          : 'Saved to your library')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  /// Letting everybody else add to a list of your own.
  Future<void> _share(Playlist list, bool on) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.setPlaylistOpenEdit(list.id, on);
      _reload();
      messenger.say(snack(Text(on
          ? 'Anybody here can add to "${list.name}" now'
          : 'Only you can change "${list.name}" now')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final list = _list;
    return PlayerScaffold(
      appBar: AppBar(
        title: Text(widget.name),
        // Whose list it is, said where it matters: a list in your library that you
        // cannot change is confusing until you can see it belongs to somebody.
        bottom: list == null || list.mine
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    list.editable
                        ? '${list.ownerName ?? 'Somebody'}\'s list — they let others add'
                        : '${list.ownerName ?? 'Somebody'}\'s list',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
        actions: [
          if (list != null && !list.mine)
            IconButton(
              icon: Icon(
                  list.saved ? Icons.bookmark : Icons.bookmark_add_outlined),
              tooltip:
                  list.saved ? 'In your library' : 'Save to your library',
              onPressed: () => _keep(list),
            ),
          // Sharing is the owner's decision and nobody else's, so only they are
          // offered it — and only for a list made here, since a mirror of somebody
          // else's Spotify is not this app's to hand round.
          if (list != null && list.mine && list.kind == 'local')
            PopupMenuButton<String>(
              tooltip: 'Sharing',
              icon: Icon(list.openEdit ? Icons.group : Icons.group_outlined),
              onSelected: (_) => _share(list, !list.openEdit),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: 'open',
                  checked: list.openEdit,
                  child: const Text('Let others add to it'),
                ),
              ],
            ),
        ],
      ),
      body: FutureBuilder<Playlist>(
        future: _future,
        builder: (context, snap) {
          // A playlist that will not load used to spin for ever: the one loader in the
          // app with no answer for a server that said no.
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _reload);
          // Ask for the artwork of what just arrived, so scrolling it is not a screen
          // of grey squares filling in one at a time.
          if (snap.hasData) {
            context.read<AppState>().keepCoversFor(snap.data!.items);
          }
          if (!snap.hasData) {
            return const SongsComing(rows: 8);
          }
          final items = snap.data!.items;
          if (items.isEmpty) {
            return const Center(child: Text('Nothing in this playlist yet.'));
          }
          final where = 'playlist:${widget.playlistId}';
          return SelectionOver(
            bar: SelectionBar(
                where: where,
                tracks: items,
                removeLabel: 'Remove from playlist',
                onRemove: !snap.data!.editable
                    ? null
                    : (picked) async {
                        final at = [
                          for (var i = 0; i < items.length; i++)
                            if (picked.any((p) => p.id == items[i].id)) i
                        ];
                        // Backwards: each removal shifts everything after it up.
                        for (final i in at.reversed) {
                          await app.api.removePlaylistItem(widget.playlistId, i);
                        }
                        await app.refreshPlaylists();
                        _reload();
                      },
              ),
            child: RecordRefresh(
            onRefresh: () async => _reload(),
            child: ReorderableListView.builder(
            padding: EdgeInsets.fromLTRB(8, 4, 8, bottomForPlayer(context)),
            physics: const AlwaysScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            header: _PlaylistHeader(
                items: items, playlist: snap.data!, onChanged: _reload),
            // Only on a list that can be added to: offering songs for somebody
            // else's playlist is offering something that cannot be done.
            footer: snap.data!.editable
                ? _WouldSitWell(
                    playlistId: widget.playlistId,
                    songs: items.length,
                    onAdded: () async {
                      await app.refreshPlaylists();
                      _reload();
                    },
                  )
                : null,
            onReorderItem: (from, to) async {
              if (!snap.data!.editable) return;
              await app.api.movePlaylistItem(widget.playlistId, from, to);
              _reload();
            },
            itemCount: items.length,
            itemBuilder: (context, i) => !snap.data!.editable
                ? SongRow(
                    key: ValueKey('pl-ro-${items[i].id}-$i'),
                    track: items[i],
                    selectable: where,
                    onTap: () =>
                        app.playNow(items, startAt: i, named: widget.name),
                    onChanged: _reload,
                  )
                : SongRow(
              // Both directions live in the row itself now: towards you puts the song
              // on next, away takes it off the playlist. Neither throws the row off
              // the screen — it goes as far as it is dragged and comes back.
              key: ValueKey('pl-${items[i].id}-$i'),
              track: items[i],
              selectable: where,
              onSwipeAway: () => _remove(snap.data!, i),
              handle: ReorderableDragStartListener(
                index: i,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, right: 2),
                  child: Icon(Icons.drag_indicator,
                      size: 18, color: Theme.of(context).colorScheme.outline),
                ),
              ),
              onTap: () => app.playNow(items, startAt: i, named: widget.name),
              onRemove: () => _remove(snap.data!, i),
              onChanged: _reload,
            ),
          ),
          ),
          );
        },
      ),
    );
  }
}

class _HistoryPage extends StatefulWidget {
  const _HistoryPage();

  @override
  State<_HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<_HistoryPage> {
  Future<List<PlayedTrack>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final pending = context.read<AppState>().api.playHistory();
    setState(() { _future = pending; });
  }

  /// Grouped by day. A flat list with no sense of when is not a history.
  static String _dayLabel(DateTime? when) {
    if (when == null) return 'Earlier';
    final now = DateTime.now();
    final day = DateTime(when.year, when.month, when.day);
    final today = DateTime(now.year, now.month, now.day);
    final difference = today.difference(day).inDays;
    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';
    if (difference < 7) return '$difference days ago';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
  }

  static String _time(DateTime? when) => when == null
      ? ''
      : '${when.hour.toString().padLeft(2, '0')}:'
          '${when.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('Recently played'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear history',
            onPressed: () async {
              final ok = await confirm(context, 'Clear listening history?',
                  'The tracks stay in your library.', action: 'Clear');
              if (!ok) return;
              await app.api.clearHistory();
              _load();
            },
          ),
        ],
      ),
      body: FutureBuilder<List<PlayedTrack>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) {
            return const SongsComing(rows: 8);
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const EmptyHint(
              icon: Icons.history,
              title: 'Nothing played yet',
              body: 'What you listen to shows up here.',
            );
          }
          String? lastDay;
          // The same row as every other list — held to pick several out, swiped to
          // play next, with the full menu behind it. This screen was the last one
          // drawing its own ListTile, so a song you had just played was the one song
          // in the app you could not favourite, keep, or add to a playlist from the
          // list it was in.
          final tracks = [for (final p in items) p.track];
          return SelectionOver(
            bar: SelectionBar(where: 'history', tracks: tracks),
            child: RecordRefresh(
            onRefresh: () async => _load(),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final played = items[i];
                final day = _dayLabel(played.playedAt);
                final showDay = day != lastDay;
                if (showDay) lastDay = day;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showDay) _SectionLabel(day),
                    SongRow(
                      track: played.track,
                      selectable: 'history',
                      showAlbum: false,
                      // When it was played is the one thing this list knows that no
                      // other list does, so it keeps the place a duration would have.
                      showDuration: false,
                      trailing: Text(_time(played.playedAt),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      // Into the queue and on, not instead of the queue: tapping a
                      // song you played yesterday used to wipe today's queue and
                      // leave that one song in it.
                      onTap: () => app.playTrackNow(played.track),
                    ),
                  ],
                );
              },
            ),
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text.toUpperCase(),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(kind == 'spotify' ? 'Spotify' : kind,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: scheme.primary)),
    );
  }
}

/// The head of a playlist's page, set like a compilation's sleeve notes: the cover cut
/// out and taped down, the name as big as it goes, and a typed line of what is in it.
/// Under a playlist: what else you have that would sit well in it.
///
/// A playlist is usually half-finished — three songs by somebody put in one evening,
/// and the other nine of theirs in the library never thought of again. This is those
/// nine: from your own library, by the artists already in the list, one tap to add and
/// a tap on the row to hear it first. Nothing is shown when there is nothing to offer.
class _WouldSitWell extends StatefulWidget {
  const _WouldSitWell(
      {required this.playlistId, required this.songs, required this.onAdded});

  final int playlistId;

  /// How many songs the list has: when that changes, what suits it has changed too.
  final int songs;
  final Future<void> Function() onAdded;

  @override
  State<_WouldSitWell> createState() => _WouldSitWellState();
}

class _WouldSitWellState extends State<_WouldSitWell> {
  List<Track> _offered = const [];
  final _adding = <int>{};

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(_WouldSitWell old) {
    super.didUpdateWidget(old);
    if (old.songs != widget.songs || old.playlistId != widget.playlistId) _ask();
  }

  Future<void> _ask() async {
    try {
      final got = await context.read<AppState>().api.suggestedFor(widget.playlistId);
      if (mounted) setState(() => _offered = got);
    } catch (_) {
      // A server from before this, or no connection: the playlist is still a playlist.
    }
  }

  Future<void> _add(Track t) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding.add(t.id));
    try {
      await app.api.addToPlaylist(widget.playlistId, [t.id]);
      if (mounted) setState(() => _offered = [for (final o in _offered) if (o.id != t.id) o]);
      await widget.onAdded();
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _adding.remove(t.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_offered.isEmpty) return const SizedBox.shrink();
    final app = context.read<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 28, 8, 2),
          child: SectionFlag('Would sit well here'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
          child: Text('From your own library, by who is already in the list.',
              style: Mag.typewriter(11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        for (final t in _offered)
          SongRow(
            key: ValueKey('suits-${t.id}'),
            track: t,
            showDuration: false,
            onTap: () => app.playTrackNow(t),
            trailing: _adding.contains(t.id)
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Add to this playlist',
                    onPressed: () => _add(t),
                  ),
          ),
      ],
    );
  }
}

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader(
      {required this.items, required this.playlist, required this.onChanged});
  final List<Track> items;
  final Playlist playlist;
  final VoidCallback onChanged;

  String? _length() {
    var ms = 0;
    for (final t in items) {
      ms += t.durationMs ?? 0;
    }
    if (ms == 0) return null;
    final minutes = (ms / 60000).round();
    return minutes < 60 ? '$minutes MIN' : '${minutes ~/ 60} H ${minutes % 60} MIN';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final kicker = [
      if (playlist.isFavourites) 'Favourites' else 'Playlist',
      if (playlist.saved && playlist.ownerName != null) 'from ${playlist.ownerName}',
      if (playlist.isMirror) 'mirrored',
      if (playlist.openEdit && playlist.mine) 'shared',
    ].join(' · ');
    final facts = [
      '${items.length} ${items.length == 1 ? 'SONG' : 'SONGS'}',
      if (_length() != null) _length()!,
      if (playlist.waiting > 0) '${playlist.waiting} NOT DOWNLOADED',
      if (playlist.unmatched > 0) '${playlist.unmatched} NOT MATCHED',
    ].join(' · ');

    Widget note(String text, String action, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(text,
                    style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant)),
              ),
              const SizedBox(width: 10),
              PressButton(label: action, onTap: onTap),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: CutOut(
                  turn: -0.035,
                  taped: true,
                  child: PlaylistArt(
                      playlist: playlist, size: 112, radius: 0, small: false),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Kicker(kicker),
                    const SizedBox(height: 4),
                    Text(playlist.name.toUpperCase(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.headline(32, color: scheme.onSurface)),
                    const SizedBox(height: 6),
                    Text(facts,
                        style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PressButton(
                label: 'Play',
                loud: true,
                onTap: items.isEmpty ? null : () => app.playNow(items),
              ),
              PressButton(
                label: 'Shuffle',
                onTap: items.isEmpty ? null : () => app.playNow(items, shuffle: true),
              ),
            ],
          ),
          if (playlist.isMirror)
            note(
              playlist.unmatched > 0
                  ? 'A read-only mirror of ${_sourceName(playlist.kind)}. '
                      '${playlist.unmatched} songs could not be matched.'
                  : 'A read-only mirror of ${_sourceName(playlist.kind)}.',
              'Copy',
              () async {
                final name = await promptForName(
                    context, 'Copy playlist', '${playlist.name} (copy)');
                if (name == null) return;
                await app.api.clonePlaylist(playlist.id, name: name);
                await app.refreshPlaylists();
                onChanged();
              },
            ),
          // Offered whenever songs here have no audio, not only when the playlist
          // was *marked* fetch-on-play. An import that found its songs already in the
          // catalog is marked "download everything" and has nothing queued, which is
          // exactly the case that needs this button most.
          if (playlist.hasHoles)
            note(
              playlist.fetchesOnPlay
                  ? 'Songs download when you play them: this list is too big to '
                      'fetch all at once.'
                  : '${playlist.waiting} of these are not downloaded yet.',
              'Get all',
              () async {
                final messenger = ScaffoldMessenger.of(context);
                final n = await app.api.downloadPlaylist(playlist.id);
                messenger.say(snack(Text(n == 0
                    ? 'Everything here is already downloaded'
                    : 'Queued $n songs')));
                onChanged();
              },
            ),
        ],
      ),
    );
  }

  static String _sourceName(String kind) => switch (kind) {
        'spotify' => 'a Spotify playlist',
        'ytmusic' => 'a YouTube Music playlist',
        _ => 'a playlist elsewhere',
      };
}



/// Every way into the library, as a contents page: an index card each, with a number on
/// it that is true — how many songs, records and artists there are, which week the
/// chart is, how many new records are waiting, how many songs are kept here.
///
/// The numbers are asked for once when the page opens, a page of one row each, and a
/// card whose number has not arrived is still a card that opens.
class _Contents extends StatefulWidget {
  const _Contents();

  @override
  State<_Contents> createState() => _ContentsState();
}

class _ContentsState extends State<_Contents> {
  int? _songs;
  int? _records;
  int? _artists;
  int _unseen = 0;
  int _following = 0;

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    final api = context.read<AppState>().api;
    Future<void> quietly(Future<void> Function() part) async {
      try {
        await part();
      } catch (_) {}
    }

    await Future.wait([
      quietly(() async => _songs = (await api.libraryTracks(limit: 1)).total),
      quietly(() async => _records = (await api.albums(limit: 1)).total),
      quietly(() async => _artists = (await api.artists(limit: 1)).total),
      quietly(() async {
        final f = await api.feed(limit: 1);
        _unseen = f.unseen;
        _following = f.following;
      }),
    ]);
    if (mounted) setState(() {});
  }

  static String _n(int? n) {
    if (n == null) return '·';
    final s = '$n';
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final kept = app.offline.count;
    final cards = <Widget>[
      _IndexCard(
        number: _n(_songs),
        title: 'Songs',
        blurb: 'Everything, sortable',
        onTap: () => openPage(context, (_) => const AllTracksPage()),
      ),
      _IndexCard(
        number: _n(_records),
        title: 'Records',
        blurb: 'Every album and EP',
        onTap: () => openPage(context, (_) => const AlbumsPage()),
      ),
      _IndexCard(
        number: _n(_artists),
        title: 'Artists',
        blurb: 'Everybody on them',
        onTap: () => openPage(context, (_) => const ArtistsPage()),
      ),
      _IndexCard(
        number: 'Wk ${issueNumber(DateTime.now())}',
        title: 'The charts',
        blurb: 'Your top songs, and what moved',
        onTap: () => openPage(context, (_) => const ListeningPage()),
      ),
      _IndexCard(
        number: _unseen > 0 ? '$_unseen' : (_following > 0 ? '$_following' : ''),
        title: 'New releases',
        blurb: _following == 0
            ? 'Follow an artist to hear about their next record'
            : _unseen > 0
                ? 'New from $_following artists you follow'
                : 'From the $_following artists you follow',
        sticker: _unseen > 0,
        onTap: () async {
          await openPage(context, (_) => const FeedPage());
          _count();
        },
      ),
      _IndexCard(
        number: '',
        title: 'Recently played',
        blurb: 'Everything, in the order you heard it',
        onTap: () => openPage(context, (_) => const _HistoryPage()),
      ),
      // What will play with no signal is part of the library, not a setting: it was
      // only reachable from the settings page, which is not where anybody looks on
      // the way to a plane.
      if (OfflineStore.supported)
        _IndexCard(
          number: kept == 0 ? '' : _n(kept),
          title: 'On this device',
          blurb: kept == 0
              ? 'Keep songs here to play them with no signal'
              : KeptPage.size(app.offline.bytes),
          onTap: () => openPage(context, (_) => const KeptPage()),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionFlag('Contents'),
          const SizedBox(height: 10),
          // Two to a row, each row as tall as its tallest card, so the cards line up
          // at any text size.
          for (var i = 0; i < cards.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: cards[i]),
                    const SizedBox(width: 8),
                    Expanded(
                        child: i + 1 < cards.length ? cards[i + 1] : const SizedBox()),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One entry on the contents page: a number, a name, a line about it.
class _IndexCard extends StatelessWidget {
  const _IndexCard({
    required this.number,
    required this.title,
    required this.blurb,
    required this.onTap,
    this.sticker = false,
  });

  final String number;
  final String title;
  final String blurb;
  final VoidCallback onTap;

  /// Whether the number is news, and set on a sticker rather than in ink.
  final bool sticker;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$title${number.isEmpty || number == '·' ? '' : ', $number'}. $blurb',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.onSurface, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (number.isNotEmpty)
                  sticker
                      ? Container(
                          padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                          color: MuseTheme.highlighter,
                          child: Text('$number NEW',
                              style: Mag.headline(22, color: MuseTheme.ink)),
                        )
                      : Text(number,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Mag.numerals(26, color: scheme.primary)),
                const SizedBox(height: 4),
                Text(title.toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.headline(22, color: scheme.onSurface)),
                const SizedBox(height: 3),
                Text(blurb,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The lists that fill themselves in: never played, most played, not heard in a while.
///
/// A playlist is something somebody made and has to keep up. These are questions about
/// the library and what has been played from it, asked again each time one is opened —
/// so "never played" gets shorter as you work through it, without anybody editing it.
/// One with nothing in it is left off.
class _SmartLists extends StatefulWidget {
  const _SmartLists();

  @override
  State<_SmartLists> createState() => _SmartListsState();
}

class _SmartListsState extends State<_SmartLists> {
  List<({String id, String name, String blurb, int count})> _lists = const [];

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    try {
      final lists = await context.read<AppState>().api.smartLists();
      if (mounted) setState(() => _lists = lists);
    } catch (_) {
      // A server from before these existed, or no connection: the section is left off.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = [for (final l in _lists) if (l.count > 0) l];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionFlag('Lists that fill themselves in'),
          const SizedBox(height: 4),
          for (final l in shown)
            InkWell(
              onTap: () async {
                await openPage(context, (_) => SmartListPage(id: l.id, name: l.name, blurb: l.blurb));
                _ask();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.16))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.name.toUpperCase(),
                              style: Mag.headline(20, color: scheme.onSurface)),
                          const SizedBox(height: 2),
                          Text(l.blurb,
                              style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('${l.count}', style: Mag.numerals(22, color: scheme.primary)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One of the lists that fill themselves in, opened.
class SmartListPage extends StatefulWidget {
  const SmartListPage({super.key, required this.id, required this.name, required this.blurb});

  final String id;
  final String name;
  final String blurb;

  @override
  State<SmartListPage> createState() => _SmartListPageState();
}

class _SmartListPageState extends State<SmartListPage> {
  Future<List<Track>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() {
        _future = context.read<AppState>().api.smartList(widget.id);
      });

  @override
  Widget build(BuildContext context) => PlayerScaffold(
        appBar: AppBar(title: Text(widget.name)),
        body: FutureBuilder<List<Track>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
            if (!snap.hasData) return const SongsComing();
            final tracks = snap.data!;
            if (tracks.isEmpty) {
              return EmptyHint(
                icon: Icons.auto_awesome_outlined,
                title: 'Nothing in it just now',
                body: widget.blurb,
              );
            }
            context.read<AppState>().keepCoversFor(tracks);
            return RecordRefresh(
              onRefresh: () async => _load(),
              child: TrackList(
                tracks: tracks,
                header: '${tracks.length} songs · ${widget.blurb}',
                named: widget.name,
                selectable: 'smart:${widget.id}',
              ),
            );
          },
        ),
      );
}
