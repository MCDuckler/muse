import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'browse_page.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'snack.dart';

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

  void _load() => setState(() => _future = context.read<AppState>().api.feed());

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
      messenger.showSnackBar(snack(Text('$e')));
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
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
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
          return RefreshIndicator(
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
        await context.read<AppState>().api.markFeedSeen([item.albumId]);
        if (!context.mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AlbumPage(remoteId: item.albumId, title: item.title),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() => _future = context.read<AppState>().api.follows());

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
      final r = await api.importFollows(provider);
      final missed = (r['not_found'] as List?) ?? const [];
      final line = StringBuffer('${r['followed']} new')
        ..write(' · ${r['already']} already')
        ..write(' of ${r['found']} on $provider');
      if (missed.isNotEmpty) line.write(' · not found: ${missed.take(3).join(', ')}');
      messenger.showSnackBar(snack(Text(line.toString())));
      _load();
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
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
      messenger.showSnackBar(snack(Text('$e')));
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
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'spotify', child: Text('Import from Spotify')),
                PopupMenuItem(
                    value: 'soundcloud', child: Text('Import from SoundCloud')),
                PopupMenuItem(value: 'deezer', child: Text('Import from Deezer')),
                PopupMenuItem(value: 'bandcamp', child: Text('Import from Bandcamp')),
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
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
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
              title: Text(items[i].name),
              subtitle: Text('${items[i].releases} records known'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Stop following',
                onPressed: () async {
                  await context.read<AppState>().api.unfollow(items[i].remoteId);
                  _load();
                },
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    ArtistPage(artist: ArtistSummary(name: items[i].name, tracks: 0)),
              )),
            ),
          );
        },
      ),
    );
  }
}
