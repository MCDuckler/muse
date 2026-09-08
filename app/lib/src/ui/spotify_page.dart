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
  bool _syncing = false;
  List<Map<String, dynamic>>? _lastSync;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() =>
      setState(() => _account = context.read<AppState>().api.spotifyAccount());

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

  Future<void> _sync() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncing = true);
    try {
      final results = await app.api.syncSpotify();
      await app.refreshPlaylists();
      if (!mounted) return;
      setState(() => _lastSync = results);
      final missing = results.fold<int>(
          0, (sum, r) => sum + ((r['missing'] ?? 0) as int));
      messenger.showSnackBar(SnackBar(
        content: Text(missing == 0
            ? 'Brought over ${results.length} playlists'
            : '${results.length} playlists · $missing songs could not be matched'),
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
                        label: const Text('Refresh playlists'),
                        onPressed: _syncing ? null : _sync,
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
              if (_lastSync != null) ...[
                const Divider(),
                for (final r in _lastSync!)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      (r['missing'] ?? 0) == 0
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: (r['missing'] ?? 0) == 0
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text('${r['name'] ?? r['error'] ?? 'Unknown'}'),
                    subtitle: r['error'] != null
                        ? Text('${r['error']}')
                        : Text('${r['matched']} of ${r['total']} songs'
                            '${(r['missing'] ?? 0) == 0 ? '' : ' · ${r['missing']} not matched'}'),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
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
