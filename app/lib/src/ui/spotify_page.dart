import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'snack.dart';
import 'widths.dart';

/// Connecting a Spotify account. What it holds is listed in the Library, under From
/// your services, beside the playlists it becomes.
class SpotifyPage extends StatefulWidget {
  const SpotifyPage({super.key});

  @override
  State<SpotifyPage> createState() => _SpotifyPageState();
}

class _SpotifyPageState extends State<SpotifyPage> {
  Future<Map<String, dynamic>>? _account;

  /// Spotify's sign-in address, fetched *before* it is needed.
  ///
  /// A browser only opens a window while it can still see the tap that asked for one.
  /// Fetching the address first — one request, a few hundred milliseconds — spends that
  /// permission, and the popup is then blocked with nothing shown: the button appeared
  /// to do nothing at all. So the address is kept ready and the tap opens it straight
  /// away. The server's half of it expires after ten minutes, hence the refresh.
  String? _authUrl;
  DateTime? _authUrlAt;
  Timer? _authRefresh;
  AppLifecycleListener? _lifecycle;

  bool get _authUrlUsable =>
      _authUrl != null &&
      DateTime.now().difference(_authUrlAt!) < const Duration(minutes: 4);

  @override
  void initState() {
    super.initState();
    _load();
    // Coming back from Spotify's tab should just work, rather than needing Refresh.
    _lifecycle = AppLifecycleListener(onResume: _load);
  }

  void _load() {
    final account = context.read<AppState>().api.spotifyAccount();
    setState(() => _account = account);
    account.then((a) {
      final linked = a['account'] as Map<String, dynamic>?;
      if (mounted && (linked == null || (linked['expired'] ?? false) == true)) {
        _armAuthUrl();
      }
    }, onError: (_) {});
  }

  /// Keep a sign-in address in hand for as long as this screen is not connected.
  void _armAuthUrl() {
    _authRefresh ??= Timer.periodic(const Duration(minutes: 4), (_) => _fetchAuthUrl());
    if (!_authUrlUsable) unawaited(_fetchAuthUrl());
  }

  Future<void> _fetchAuthUrl() async {
    try {
      final url = await context.read<AppState>().api.spotifyAuthorizeUrl();
      if (!mounted) return;
      _authUrl = url;
      _authUrlAt = DateTime.now();
    } catch (_) {
      // Not fatal: the button falls back to fetching one on the spot.
    }
  }

  @override
  void dispose() {
    _authRefresh?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Deliberately not async before the launch: see [_authUrl].
  ///
  /// Sign-in happens on Spotify's own page, in a real browser tab — never inside the
  /// app, which is the whole point of OAuth.
  void _connect() {
    final messenger = ScaffoldMessenger.of(context);
    if (_authUrlUsable) {
      final url = _authUrl!;
      _authUrl = null;                       // one address, one sign-in
      unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
      unawaited(_fetchAuthUrl());
      messenger.say(snack(Text('Finish signing in on the Spotify tab — this page picks it up '
            'when you come back'),
      ));
      return;
    }
    unawaited(_connectTheSlowWay(messenger));
  }

  /// When there is no address ready — the first tap after opening the screen, or the
  /// server was slow — fetch one and put it behind a button. Tapping that button is a
  /// fresh interaction, which is what a browser needs to open the tab.
  Future<void> _connectTheSlowWay(ScaffoldMessengerState messenger) async {
    try {
      await _fetchAuthUrl();
      final url = _authUrl;
      if (!mounted || url == null) {
        messenger.say(
            snack(Text('Spotify sign-in is not available right now')));
        return;
      }
      _authUrl = null;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connect to Spotify'),
          content: const Text('Sign in on Spotify, then come back here.'),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Copy link'),
            ),
            FilledButton(
              onPressed: () {
                unawaited(
                    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
                Navigator.pop(context);
              },
              child: const Text('Open Spotify'),
            ),
          ],
        ),
      );
      unawaited(_fetchAuthUrl());
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return PlayerScaffold(
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
            padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
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
                    ? 'Sign in to see your Spotify playlists in the Library'
                    : ((account['expired'] ?? false) as bool)
                        ? 'The sign-in expired — connect again'
                        : 'Its playlists are in the Library, under From your '
                            'services, to mirror there'),
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
                      // Expired is the one state where connecting again is the fix.
                      if ((account['expired'] ?? false) as bool) ...[
                        FilledButton.icon(
                          icon: const Icon(Icons.link),
                          label: const Text('Connect again'),
                          onPressed: _connect,
                        ),
                        const SizedBox(width: 8),
                      ],
                      TextButton(
                        onPressed: () async {
                          final ok = await confirm(context, 'Disconnect Spotify?',
                              'Its playlists disappear from your library. Anything '
                              'you cloned stays.',
                    action: 'Disconnect');
                          if (!ok || !context.mounted) return;
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await app.api.unlinkSpotify();
                            await app.refreshPlaylists();
                          } catch (e) {
                            messenger.say(problem(e));
                          }
                          _load();
                        },
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ],
                ),
              ),
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

    await ask<void>(
      context,
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
    return PlayerScaffold(
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
