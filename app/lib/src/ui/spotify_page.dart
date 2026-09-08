import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';

/// Connecting a Spotify account, and seeing what came across.
class SpotifyPage extends StatefulWidget {
  const SpotifyPage({super.key});

  @override
  State<SpotifyPage> createState() => _SpotifyPageState();
}

class _SpotifyPageState extends State<SpotifyPage> {
  Future<Map<String, dynamic>>? _account;
  Future<List<SpotifyPlaylist>>? _playlists;
  final _filter = TextEditingController();
  final _busy = <String>{};
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AppState>().api;
    setState(() {
      _account = api.spotifyAccount();
      _playlists = api.spotifyAccount().then((a) =>
          (a['account'] == null) ? <SpotifyPlaylist>[] : api.spotifyPlaylists());
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Mirror or refresh one playlist. Everything is per playlist: this account has
  /// hundreds, and each song mirrored costs a lookup on the other side.
  Future<void> _mirror(SpotifyPlaylist p) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(p.remoteId));
    try {
      final results = await app.api.syncSpotify(remoteId: p.remoteId);
      await app.refreshPlaylists();
      final r = results.isEmpty ? null : results.first;
      if (!mounted) return;
      _load();
      messenger.showSnackBar(SnackBar(
        content: Text(r == null
            ? 'Nothing came back for ${p.name}'
            : r['error'] != null
                ? '${p.name}: ${r['error']}'
                : '${p.name} · ${r['matched']} of ${r['total']} songs'
                    '${(r['missing'] ?? 0) == 0 ? '' : ', ${r['missing']} not matched'}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy.remove(p.remoteId));
    }
  }

  Future<void> _stopMirroring(SpotifyPlaylist p) async {
    final app = context.read<AppState>();
    final ok = await confirm(context, 'Stop mirroring ${p.name}?',
        'It disappears from your playlists here. Nothing changes on Spotify.');
    if (!ok) return;
    await app.api.deletePlaylist(p.playlistId!);
    await app.refreshPlaylists();
    _load();
  }

  Future<void> _connect() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await app.api.spotifyAuthorizeUrl();
      // Sign-in happens on Spotify's own page, in a real browser tab — never inside
      // the app, which is the whole point of OAuth.
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Finish signing in, then come back and tap Refresh'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Refresh what is already mirrored — never everything.
  Future<void> _refreshMirrors() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncing = true);
    try {
      final results = await app.api.syncSpotify();
      await app.refreshPlaylists();
      if (!mounted) return;
      _load();
      final missing = results.fold<int>(
          0, (sum, r) => sum + ((r['missing'] ?? 0) as int));
      messenger.showSnackBar(SnackBar(
        content: Text(results.isEmpty
            ? 'Nothing is mirrored yet — choose a playlist below'
            : '${results.length} refreshed'
                '${missing == 0 ? '' : ' · $missing songs not matched'}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Spotify')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _account,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          final configured = (data['configured'] ?? false) as bool;
          final account = data['account'] as Map<String, dynamic>?;

          if (!configured) {
            return _NotConfigured(reason: (data['reason'] ?? '') as String);
          }

          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              ListTile(
                leading: Icon(account == null ? Icons.link_off : Icons.link,
                    color: account == null
                        ? null
                        : Theme.of(context).colorScheme.primary),
                title: Text(account == null
                    ? 'No account connected'
                    : 'Connected as ${account['display_name'] ?? 'your account'}'),
                subtitle: Text(account == null
                    ? 'Sign in to see your Spotify playlists here'
                    : ((account['expired'] ?? false) as bool)
                        ? 'The sign-in expired — connect again'
                        : 'Playlists are read-only, and playable'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    if (account == null)
                      FilledButton.icon(
                        icon: const Icon(Icons.link),
                        label: const Text('Connect Spotify'),
                        onPressed: _connect,
                      )
                    else ...[
                      FilledButton.icon(
                        icon: _syncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.sync),
                        label: const Text('Refresh mirrored'),
                        onPressed: _syncing ? null : _refreshMirrors,
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          final ok = await confirm(context, 'Disconnect Spotify?',
                              'Its playlists disappear from your library. Anything '
                              'you cloned stays.');
                          if (!ok) return;
                          await app.api.unlinkSpotify();
                          await app.refreshPlaylists();
                          _load();
                        },
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ],
                ),
              ),
              if (account != null) _picker(),
            ],
          );
        },
      ),
    );
  }

  Widget _picker() => FutureBuilder<List<SpotifyPlaylist>>(
        future: _playlists,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(error: snap.error!, onRetry: _load);
          }
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(28),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final all = snap.data!;
          final query = _filter.text.trim().toLowerCase();
          final shown = query.isEmpty
              ? all
              : all.where((p) => p.name.toLowerCase().contains(query)).toList();
          shown.sort((a, b) {
            if (a.isMirrored != b.isMirrored) return a.isMirrored ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  '${all.length} playlists on Spotify · '
                  '${all.where((p) => p.isMirrored).length} mirrored here',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: TextField(
                  controller: _filter,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Find a playlist',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _filter.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(_filter.clear),
                          ),
                  ),
                ),
              ),
              // Only what is on screen is built: this account has 460 playlists.
              for (final p in shown.take(60))
                ListTile(
                  leading: Icon(p.isMirrored
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_outlined),
                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(p.subtitle),
                  trailing: _busy.contains(p.remoteId)
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : PopupMenuButton<String>(
                          onSelected: (v) =>
                              v == 'stop' ? _stopMirroring(p) : _mirror(p),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                                value: 'mirror',
                                child: Text(p.isMirrored
                                    ? 'Refresh from Spotify'
                                    : 'Add to my playlists')),
                            if (p.isMirrored)
                              const PopupMenuItem(
                                  value: 'stop', child: Text('Stop mirroring')),
                          ],
                        ),
                  onTap: _busy.contains(p.remoteId) ? null : () => _mirror(p),
                ),
              if (shown.length > 60)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      '${shown.length - 60} more — search to narrow it down',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          );
        },
      );
}


class _NotConfigured extends StatelessWidget {
  const _NotConfigured({required this.reason});
  final String reason;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.settings_ethernet,
                size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text('Spotify is not set up on this server',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(reason,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}

/// The songs a mirrored playlist could not bring across, and a way to fix each one.
class UnmatchedPage extends StatefulWidget {
  const UnmatchedPage({super.key, required this.playlistId, required this.name});
  final int playlistId;
  final String name;

  @override
  State<UnmatchedPage> createState() => _UnmatchedPageState();
}

class _UnmatchedPageState extends State<UnmatchedPage> {
  Future<List<UnmatchedTrack>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(
      () => _future = context.read<AppState>().api.unmatched(widget.playlistId));

  Future<void> _pick(UnmatchedTrack item) async {
    final app = context.read<AppState>();
    final suggestions =
        await app.api.unmatchedSuggestions(widget.playlistId, item.pos);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Which one is “${item.title}”?',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(item.artistLine,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const Divider(height: 1),
            if (suggestions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('YouTube Music has nothing close to this one.'),
              ),
            for (final s in suggestions)
              ListTile(
                leading: Artwork(
                    url: app.api.remoteCoverUrl(s.coverPath), size: 40),
                title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.artistLine,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  await app.api.resolveUnmatched(widget.playlistId, item.pos,
                      videoId: s.videoId);
                  await app.refreshPlaylists();
                  _load();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Not matched · ${widget.name}')),
      body: FutureBuilder<List<UnmatchedTrack>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const EmptyHint(
              icon: Icons.check_circle_outline,
              title: 'Everything came across',
              body: 'Every song in this playlist has something to play.',
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => ListTile(
              leading: const Icon(Icons.help_outline),
              title: Text(items[i].title),
              subtitle: Text('${items[i].artistLine}\n${items[i].reason}'),
              isThreeLine: true,
              trailing: TextButton(
                onPressed: () => _pick(items[i]),
                child: const Text('Choose'),
              ),
            ),
          );
        },
      ),
    );
  }
}
