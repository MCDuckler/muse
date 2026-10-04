import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'bandcamp_page.dart';
import 'browse_page.dart';
import 'dialogs.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'snack.dart';
import 'widths.dart';
import 'skeleton.dart';
import 'record_refresh.dart';

/// What the artists you follow have put out.
///
/// Not a recommendation engine and not a chart: a list of records by people you asked
/// to hear about, newest first, with the ones you have not looked at yet marked. Tap a
/// record to open it — from there it is the same page as any album, so getting it is
/// the same button.
class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  Future<({List<FeedItem> items, int unseen, int following})>? _future;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() {
        _future = context.read<AppState>().api.feed();
      });

  /// Marking as read is deliberate rather than automatic on scroll: something you
  /// glanced past on a train is exactly what you wanted to still be marked later.
  Future<void> _markAllSeen(List<FeedItem> items) async {
    final ids = [for (final i in items) if (i.unseen) i.albumId];
    if (ids.isEmpty) return;
    await context.read<AppState>().api.markFeedSeen(ids);
    _load();
  }

  Future<void> _checkNow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      await context.read<AppState>().api.refreshFeed();
      _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('New releases'),
        actions: [
          IconButton(
            icon: _checking
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Check now',
            onPressed: _checking ? null : _checkNow,
          ),
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: 'Following',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const FollowingPage()));
              _load();
            },
          ),
        ],
      ),
      body: FutureBuilder<({List<FeedItem> items, int unseen, int following})>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const SongsComing();
          final data = snap.data!;
          if (data.following == 0) {
            return const EmptyHint(
              icon: Icons.notifications_none,
              title: 'Nobody followed yet',
              body: 'Open an artist and tap Follow. New records they put out '
                  'show up here.',
            );
          }
          if (data.items.isEmpty) {
            return const EmptyHint(
              icon: Icons.album_outlined,
              title: 'Nothing new',
              body: 'Nothing has come out since you started following.',
            );
          }
          return RecordRefresh(
            onRefresh: () async => _load(),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
              itemCount: data.items.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            data.unseen == 0
                                ? '${data.following} followed'
                                : '${data.unseen} new · ${data.following} followed',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        if (data.unseen > 0)
                          TextButton(
                            onPressed: () => _markAllSeen(data.items),
                            child: const Text('Mark all read'),
                          ),
                      ],
                    ),
                  );
                }
                return _FeedRow(item: data.items[i - 1], onOpened: _load);
              },
            ),
          );
        },
      ),
    );
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.item, required this.onOpened});
  final FeedItem item;
  final VoidCallback onOpened;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [
      item.artist,
      if (item.via != null) 'on ${item.via}',
      if (item.releaseDate != null) item.releaseDate!,
      if (item.recordType != null) item.recordType!,
    ].join(' · ');

    return ListTile(
      leading: Stack(
        children: [
          Artwork(url: item.cover, size: 48, radius: 6),
          if (item.unseen)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: item.inLibrary
          ? Icon(Icons.check, size: 18, color: scheme.outline)
          : null,
      onTap: () async {
        // Opened at once, and marked on the way. Waiting for the mark first put a
        // round trip between the tap and the page — and a mark that failed opened
        // nothing at all.
        unawaited(context
            .read<AppState>()
            .api
            .markFeedSeen([item.albumId]).catchError((_) {}));
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => item.provider == 'bandcamp'
              ? BandcampRecordPage(url: item.albumId, title: item.title)
              : AlbumPage(remoteId: item.albumId, title: item.title),
        ));
        onOpened();
      },
    );
  }
}

/// Who you follow, and the way to stop.
class FollowingPage extends StatefulWidget {
  const FollowingPage({super.key});

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage> {
  Future<List<FollowedArtist>>? _future;

  /// Which service is being imported from right now, if any.
  String? _importing;

  /// The services this account has linked — the ones follows can come from.
  List<FollowSource> _sources = const [];

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_loadSources());
  }

  void _load() => setState(() {
        _future = context.read<AppState>().api.follows();
      });

  Future<void> _loadSources() async {
    try {
      final got = await context.read<AppState>().api.followSources();
      if (mounted) setState(() => _sources = got);
    } catch (_) {
      // An older server: the menu offers every service and the server says which.
    }
  }

  /// Bring over the artists this person already follows elsewhere.
  ///
  /// Every service names artists slightly differently and some of what they call an
  /// artist is not one, so the answer is reported rather than assumed: what was found,
  /// what was already here, and the names that could not be placed.
  Future<void> _import(String provider) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = provider);
    try {
      messenger.say(snack(Text('Reading who you follow on $provider — a label is '
          'opened into its acts, so this can take a minute…')));
      final r = await api.importFollowsFrom(provider);
      _load();
      if (!mounted) return;
      await showImportResult(context, r);
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  Future<void> _add() async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final name = await promptForName(context, 'Follow an artist');
    if (name == null || name.trim().isEmpty) return;
    try {
      await api.follow(name: name.trim());
      _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('Following'),
        actions: [
          if (_importing != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else
            PopupMenuButton<String>(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Import who you follow',
              onSelected: _import,
              itemBuilder: (context) => _sources.isEmpty
                  ? const [
                      PopupMenuItem(value: 'spotify', child: Text('Import from Spotify')),
                      PopupMenuItem(value: 'soundcloud', child: Text('Import from SoundCloud')),
                      PopupMenuItem(value: 'deezer', child: Text('Import from Deezer')),
                      PopupMenuItem(value: 'bandcamp', child: Text('Import from Bandcamp')),
                    ]
                  : [
                      for (final s in _sources)
                        PopupMenuItem(
                            value: s.provider,
                            child: Text('Import from ${s.label}'
                                '${s.handle != null ? ' (${s.handle})' : ''}')),
                    ],
            ),
          IconButton(
              icon: const Icon(Icons.add), tooltip: 'Follow', onPressed: _add),
        ],
      ),
      body: FutureBuilder<List<FollowedArtist>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const PeopleComing();
          final items = snap.data!;
          if (items.isEmpty) {
            return const EmptyHint(
              icon: Icons.people_outline,
              title: 'Following nobody',
              body: 'Follow an artist from their page, with the + above, or bring '
                  'over who you already follow on Spotify, SoundCloud or Deezer.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
            itemCount: items.length,
            itemBuilder: (context, i) => ListTile(
              leading: ClipOval(child: Artwork(url: items[i].image, size: 44, radius: 22)),
              title: Row(children: [
                Flexible(child: Text(items[i].name, overflow: TextOverflow.ellipsis)),
                if (items[i].isLabel) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).colorScheme.outline)),
                    child: Text('LABEL',
                        style: Mag.flag(8, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                ],
              ]),
              subtitle: Text('${items[i].releases} records known'
                  '${items[i].provider == 'bandcamp' ? ' · Bandcamp' : ''}'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Stop following',
                onPressed: () async {
                  await context.read<AppState>().api.unfollow(items[i].remoteId,
                      provider: items[i].provider);
                  _load();
                },
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => items[i].provider == 'bandcamp'
                    ? BandcampBandPage(url: items[i].remoteId, name: items[i].name)
                    : ArtistPage(artist: ArtistSummary(name: items[i].name, tracks: 0)),
              )),
            ),
          );
        },
      ),
    );
  }
}


/// What an import did, said in full: an import that touches a hundred follows and a
/// few labels deserves more than one line that scrolls away.
Future<void> showImportResult(BuildContext context, FollowImport r) => ask<void>(
      context,
      scrollable: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final lines = <String>[
          '${r.followed} newly followed',
          '${r.already} already followed — kept as they were',
          if (r.labels > 0)
            '${r.labels} label${r.labels == 1 ? '' : 's'} opened into ${r.fromLabels} acts',
          '${r.found} read from ${r.from}',
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SectionFlag('Imported'),
              const SizedBox(height: 12),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(l, style: Mag.typewriter(12, color: scheme.onSurface)),
                ),
              if (r.notFound.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Could not be placed anywhere:',
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true)),
                const SizedBox(height: 4),
                Text(r.notFound.join(' · '),
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
        );
      },
    );

/// A record on Bandcamp, as its page lists it, with one button to bring it in.
///
/// A followed Bandcamp act's new record is a page there, not an entry anywhere else:
/// this is that page, read, with the same "add the album" the search offers for a
/// pasted link.
class BandcampRecordPage extends StatefulWidget {
  const BandcampRecordPage({super.key, required this.url, this.title});
  final String url;
  final String? title;

  @override
  State<BandcampRecordPage> createState() => _BandcampRecordPageState();
}

class _BandcampRecordPageState extends State<BandcampRecordPage> {
  late Future<AlbumPreview> _future;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.previewAlbum(widget.url);
  }

  Future<void> _import() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = true);
    try {
      final r = await app.api.importAlbum(widget.url);
      await app.refreshPlaylists();
      messenger.say(snack(Text('Added "${r['name']}" — ${r['added']} tracks')));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlayerScaffold(
      appBar: AppBar(title: Text(widget.title ?? 'On Bandcamp')),
      body: FutureBuilder<AlbumPreview>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(
                error: snap.error!,
                onRetry: () => setState(() {
                      _future = context.read<AppState>().api.previewAlbum(widget.url);
                    }));
          }
          if (!snap.hasData) return const SongsComing(rows: 6);
          final album = snap.data!;
          return ListView(
            padding: EdgeInsets.fromLTRB(0, 8, 0, bottomForPlayer(context)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                child: Text((album.album ?? widget.title ?? '').toUpperCase(),
                    style: Mag.headline(26, color: scheme.onSurface).copyWith(height: 0.98)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                    [
                      if (album.artist != null) album.artist!,
                      '${album.tracks.length} tracks',
                      if (album.unavailable > 0) '${album.unavailable} sold only',
                      'Bandcamp',
                    ].join(' · '),
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PressButton(
                      label: _importing ? 'Adding…' : 'Add the album',
                      loud: true,
                      onTap: _importing ? null : _import),
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
            ],
          );
        },
      ),
    );
  }
}
