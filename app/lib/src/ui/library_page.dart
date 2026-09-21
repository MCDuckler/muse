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


class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return RefreshIndicator(
      onRefresh: app.refresh,
      child: ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // The library itself, which until now could not be browsed at all.
        ListTile(
          leading: const Icon(Icons.library_music_outlined),
          title: const Text('All tracks'),
          subtitle: const Text('Everything, sortable'),
          onTap: () => openPage(context, (_) => const AllTracksPage()),
        ),
        ListTile(
          leading: const Icon(Icons.album_outlined),
          title: const Text('Albums'),
          onTap: () => openPage(context, (_) => const AlbumsPage()),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Artists'),
          onTap: () => openPage(context, (_) => const ArtistsPage()),
        ),
        // Up here with the rest of the ways in, not under the last playlist: with
        // twenty playlists it was a screen and a half of scrolling away.
        ListTile(
          leading: const Icon(Icons.bar_chart),
          title: const Text('The charts'),
          subtitle: const Text('Your top songs, and what moved this week'),
          onTap: () => openPage(context, (_) => const ListeningPage()),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Recently played'),
          onTap: () => openPage(context, (_) => const _HistoryPage()),
        ),
        const _FeedRow(),
        // What will play with no signal is part of the library, not a setting: it was
        // only reachable from the settings page, which is not where anybody looks on
        // the way to a plane.
        if (OfflineStore.supported)
          ListTile(
            leading: const Icon(Icons.download_done_outlined),
            title: const Text('On this device'),
            subtitle: Text(app.offline.count == 0
                ? 'Keep songs here to play them with no signal'
                : '${app.offline.count} songs · ${KeptPage.size(app.offline.bytes)}'),
            onTap: () => openPage(context, (_) => const KeptPage()),
          ),
        const Divider(),
        const _SectionLabel('Playlists'),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('New playlist'),
          onTap: () async {
            final name = await promptForName(context, 'New playlist');
            if (name == null) return;
            await app.api.createPlaylist(name);
            await app.refreshPlaylists();
          },
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
            child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ReorderableListView.builder(
            padding: EdgeInsets.fromLTRB(8, 4, 8, bottomForPlayer(context)),
            physics: const AlwaysScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            header: _PlaylistHeader(
                items: items, playlist: snap.data!, onChanged: _reload),
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
            child: RefreshIndicator(
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

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader(
      {required this.items, required this.playlist, required this.onChanged});
  final List<Track> items;
  final Playlist playlist;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (playlist.isMirror)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Row(
                children: [
                  _SourceTag(kind: playlist.kind),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      playlist.unmatched > 0
                          ? 'Read-only · ${playlist.unmatched} songs could not be matched'
                          : 'Read-only mirror',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final name = await promptForName(
                          context, 'Copy playlist', '${playlist.name} (copy)');
                      if (name == null) return;
                      await app.api.clonePlaylist(playlist.id, name: name);
                      await app.refreshPlaylists();
                      onChanged();
                    },
                    child: const Text('Copy'),
                  ),
                ],
              ),
            ),
      // Offered whenever songs here have no audio, not only when the playlist was
      // *marked* fetch-on-play. An import that found its songs already in the catalog
      // is marked "download everything" and has nothing queued, which is exactly the
      // case that needs this button most.
      if (playlist.hasHoles)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.cloud_queue, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  playlist.fetchesOnPlay
                      ? 'Songs download when you play them — this library is too big '
                          'to fetch all at once.'
                      : '${playlist.waiting} of these are not downloaded yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final n = await app.api.downloadPlaylist(playlist.id);
                  messenger.say(snack(Text(n == 0
                          ? 'Everything here is already downloaded'
                          : 'Queued $n songs')));
                  onChanged();
                },
                child: const Text('Get all'),
              ),
            ],
          ),
        ),
      Row(
        children: [
          PlaylistArt(playlist: playlist, size: 108, radius: 10, small: false),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The name is already in the app bar; repeating it here would just
                // push the art down.
                Text('${items.length} tracks',
                    style: Theme.of(context).textTheme.titleMedium),
                if (playlist.unmatched > 0)
                  Text('${playlist.unmatched} could not be matched',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Play'),
            onPressed: () => app.playNow(items),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.shuffle, size: 18),
            label: const Text('Shuffle'),
            onPressed: () => app.playNow(items, shuffle: true),
          ),
        ],
      ),
        ],
      ),
    );
  }
}


/// The feed row, with what is waiting in it.
///
/// The count is the point: a feed you have to open to find out whether it is worth
/// opening is a feed nobody opens.
class _FeedRow extends StatefulWidget {
  const _FeedRow();

  @override
  State<_FeedRow> createState() => _FeedRowState();
}

class _FeedRowState extends State<_FeedRow> {
  int _unseen = 0;
  int _following = 0;

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    try {
      final f = await context.read<AppState>().api.feed(limit: 60);
      if (!mounted) return;
      setState(() {
        _unseen = f.unseen;
        _following = f.following;
      });
    } catch (_) {
      // A row that cannot count is still a row that opens.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.notifications_none),
      title: const Text('New releases'),
      subtitle: Text(_following == 0
          ? 'Follow an artist to hear about their next record'
          : '$_following followed'),
      trailing: _unseen == 0
          ? null
          : Badge(label: Text('$_unseen'), backgroundColor:
              Theme.of(context).colorScheme.primary),
      onTap: () async {
        await openPage(context, (_) => const FeedPage());
        _count();
      },
    );
  }
}
