import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'fold.dart';
import 'library_page.dart' show PlaylistPage;
import 'mag.dart';
import 'mag_parts.dart';
import 'motion.dart';
import 'pane.dart';
import 'services_page.dart';
import 'snack.dart';

/// The icon a service is drawn with, wherever it is named.
IconData serviceIcon(String provider) => switch (provider) {
      'spotify' => Icons.music_note_outlined,
      'youtube' => Icons.smart_display_outlined,
      'bandcamp' => Icons.album_outlined,
      'soundcloud' => Icons.cloud_outlined,
      _ => Icons.library_music_outlined,
    };

/// A service's name as it would print it.
String serviceLabel(String provider) => switch (provider) {
      'spotify' => 'Spotify',
      'youtube' || 'ytmusic' => 'YouTube Music',
      'deezer' => 'Deezer',
      'soundcloud' => 'SoundCloud',
      'bandcamp' => 'Bandcamp',
      _ => provider,
    };

/// A connected account, whichever kind of connecting it took.
class _Source {
  const _Source(this.provider, this.account);
  final String provider;
  final String? account;
}

/// One list on another service. Spotify answers in a shape of its own; this is the
/// part of both that the shelf needs.
class _Remote {
  const _Remote({
    required this.remoteId,
    required this.name,
    required this.owner,
    required this.count,
    required this.playlistId,
    required this.here,
    required this.unmatched,
    required this.shazam,
    required this.image,
  });

  _Remote.spotify(SpotifyPlaylist p)
      : this(
          remoteId: p.remoteId,
          name: p.name,
          owner: p.owner,
          count: p.count,
          playlistId: p.playlistId,
          here: p.mirroredTracks,
          unmatched: p.unmatched,
          shazam: p.isShazam,
          // Spotify's listing carries no picture in development mode; the server
          // asks the playlist itself when it mirrors one.
          image: null,
        );

  _Remote.linked(RemoteList l)
      : this(
          remoteId: l.remoteId,
          name: l.name,
          owner: l.owner,
          count: l.count,
          // A mirror from before the server said which playlist it is still counts
          // as mirrored; it just cannot be opened from here.
          playlistId: l.playlistId ?? (l.mirrored ? -1 : null),
          here: l.mirroredItems,
          unmatched: 0,
          shazam: false,
          image: l.image,
        );

  final String remoteId;
  final String name;
  final String? owner;
  final int? count;
  final int? playlistId;
  final int here;
  final int unmatched;
  final bool shazam;
  final String? image;

  bool get mirrored => playlistId != null;
  RemoteList get asList =>
      RemoteList(remoteId: remoteId, name: name, count: count, image: image);
}

/// The playlists on every service connected here, and which of them to mirror.
///
/// This used to be two screens deep in the settings — one for Spotify, one for the
/// rest — which is not where anybody looks for their playlists. It lives under the
/// playlists now, and asks the services nothing while it is closed: a Spotify account
/// can hold four hundred lists, and each service is a request to somebody else.
class ServiceShelf extends StatefulWidget {
  const ServiceShelf({super.key});

  /// Pulled to refresh: everything asked again rather than kept.
  static final again = ValueNotifier<int>(0);

  @override
  State<ServiceShelf> createState() => _ServiceShelfState();
}

class _ServiceShelfState extends State<ServiceShelf> {
  List<_Source>? _sources;
  Object? _sourcesError;
  bool _askingSources = false;

  final _lists = <String, List<_Remote>>{};
  final _errors = <String, Object>{};
  final _asking = <String>{};
  final _filters = <String, TextEditingController>{};

  /// How many of each service's lists are drawn: a dozen to begin with, more on asking.
  final _cap = <String, int>{};

  /// Lists being mirrored now, as provider:remoteId.
  final _busy = <String>{};

  /// Lists handed to the worker that have not turned up yet. A mirror from one of the
  /// linked services is a job, not an answer, so "copying" is all there is to say.
  final _queued = <String>{};
  final _refreshing = <String>{};

  /// Bumped whenever everything is thrown away, so an answer to a question asked
  /// before that does not land on top of the fresh one.
  int _round = 0;

  @override
  void initState() {
    super.initState();
    ServiceShelf.again.addListener(_forget);
  }

  @override
  void dispose() {
    ServiceShelf.again.removeListener(_forget);
    for (final f in _filters.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _forget() {
    if (!mounted) return;
    setState(() {
      _round++;
      _sources = null;
      _sourcesError = null;
      _askingSources = false;
      _lists.clear();
      _errors.clear();
      _asking.clear();
      _queued.clear();
    });
  }

  Future<void> _askSources() async {
    _askingSources = true;
    final round = _round;
    final api = context.read<AppState>().api;
    try {
      final linked = await api.linkedServices();
      Map<String, dynamic>? spotify;
      try {
        spotify = await api.spotifyAccount();
      } catch (_) {
        // A server with no Spotify set up says so as an error; that is "not
        // connected", not a reason to lose the rest of the shelf.
      }
      final account = spotify?['account'] as Map<String, dynamic>?;
      final sources = [
        if ((spotify?['configured'] ?? false) == true && account != null)
          _Source('spotify', account['display_name'] as String?),
        for (final s in linked)
          if (s.isLinked)
            _Source(s.provider, s.displayName ?? s.handle),
      ];
      if (!mounted || round != _round) return;
      setState(() {
        _sources = sources;
        _sourcesError = null;
        _askingSources = false;
      });
    } catch (e) {
      if (!mounted || round != _round) return;
      setState(() {
        _sourcesError = e;
        _askingSources = false;
      });
    }
  }

  Future<void> _askLists(String provider) async {
    _asking.add(provider);
    final round = _round;
    final api = context.read<AppState>().api;
    try {
      final lists = provider == 'spotify'
          ? [for (final p in await api.spotifyPlaylists()) _Remote.spotify(p)]
          : [for (final l in await api.serviceLists(provider)) _Remote.linked(l)];
      lists.sort((a, b) {
        if (a.mirrored != b.mirrored) return a.mirrored ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted || round != _round) return;
      setState(() {
        _lists[provider] = lists;
        _errors.remove(provider);
        _asking.remove(provider);
        // Whatever the worker has finished is mirrored now, and says so itself.
        _queued.removeWhere((k) =>
            k.startsWith('$provider:') &&
            lists.any((l) => l.mirrored && k == '$provider:${l.remoteId}'));
      });
    } catch (e) {
      if (!mounted || round != _round) return;
      setState(() {
        _errors[provider] = e;
        _asking.remove(provider);
      });
    }
  }

  void _again(String provider) => setState(() {
        _lists.remove(provider);
        _errors.remove(provider);
      });

  Future<void> _mirror(String provider, _Remote list) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final key = '$provider:${list.remoteId}';
    setState(() => _busy.add(key));
    try {
      if (provider == 'spotify') {
        // Spotify mirrors while you wait, and says how it went.
        final results = await app.api.syncSpotify(remoteId: list.remoteId);
        final r = results.isEmpty ? null : results.first;
        messenger.say(snack(Text(r == null
            ? 'Nothing came back for ${list.name}'
            : r['error'] != null
                ? '${list.name}: ${r['error']}'
                : '${list.name} · ${r['matched']} of ${r['total']} songs'
                    '${(r['missing'] ?? 0) == 0 ? '' : ', ${r['missing']} not matched'}')));
      } else {
        await app.api.mirrorList(provider, list.asList);
        if (!list.mirrored) _queued.add(key);
        messenger.say(snack(Text(
            'Copying "${list.name}" — it will appear in your playlists')));
      }
      await app.refreshPlaylists();
      if (mounted) _again(provider);
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _stop(String provider, _Remote list) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirm(
        context,
        'Stop mirroring ${list.name}?',
        'It disappears from your playlists here. Nothing changes on '
            '${serviceLabel(provider)}.',
        action: 'Stop');
    if (!ok) return;
    try {
      await app.api.deletePlaylist(list.playlistId!);
      await app.refreshPlaylists();
    } catch (e) {
      messenger.say(problem(e));
    }
    if (mounted) _again(provider);
  }

  /// Every Spotify mirror asked again — never every Spotify list.
  Future<void> _refreshSpotify() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _refreshing.add('spotify'));
    try {
      final results = await app.api.syncSpotify();
      await app.refreshPlaylists();
      final missing =
          results.fold<int>(0, (sum, r) => sum + ((r['missing'] ?? 0) as int));
      messenger.say(snack(Text(results.isEmpty
          ? 'Nothing from Spotify is mirrored yet'
          : '${results.length} refreshed'
              '${missing == 0 ? '' : ' · $missing songs not matched'}')));
      if (mounted) _again('spotify');
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _refreshing.remove('spotify'));
    }
  }

  Future<void> _openServices() async {
    await openPage(context, (_) => const ServicesPage());
    _forget();
  }

  @override
  Widget build(BuildContext context) => LibraryFold(
        id: 'services',
        title: 'From your services',
        builder: _body,
      );

  Widget _body(BuildContext context, bool shrunk) {
    // Asked the first time the shelf is open, and not before.
    if (_sources == null && _sourcesError == null && !_askingSources) {
      unawaited(_askSources());
    }
    final scheme = Theme.of(context).colorScheme;
    final sources = _sources;
    if (sources == null) {
      return _sourcesError != null
          ? _Trouble(error: _sourcesError!, onRetry: _forget)
          : const _Waiting();
    }
    final more = PressButton(label: 'Connect a service', onTap: _openServices);
    if (sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Connect Spotify, YouTube Music, Deezer, SoundCloud or Bandcamp and '
                'their playlists are listed here, ready to mirror.',
                style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            more,
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in sources) _group(context, s, shrunk),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PressButton(label: 'Services…', onTap: _openServices),
          ),
        ),
      ],
    );
  }

  /// One service: a head that opens and closes like a section, and its lists.
  Widget _group(BuildContext context, _Source source, bool shrunk) {
    final provider = source.provider;
    final foldId = 'services:$provider';
    final closed =
        context.select<AppState, bool>((a) => a.closedSections.contains(foldId));
    final here = context.select<AppState, int>(
        (a) => a.playlists.where((p) => p.kind == provider).length);
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final lists = _lists[provider];
    if (!closed && lists == null && !_errors.containsKey(provider) &&
        !_asking.contains(provider)) {
      unawaited(_askLists(provider));
    }

    final facts = [
      if (source.account != null) 'as ${source.account}',
      if (lists != null) '${lists.length} ${lists.length == 1 ? 'list' : 'lists'}',
      '$here mirrored here',
    ].join(' · ');

    final head = InkWell(
      onTap: () => app.setSectionClosed(foldId, !closed),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, shrunk ? 4 : 8, 4, shrunk ? 4 : 8),
        child: Row(
          children: [
            Icon(serviceIcon(provider), size: shrunk ? 18 : 22, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(serviceLabel(provider).toUpperCase(),
                      style: Mag.headline(shrunk ? 16 : 20, color: scheme.onSurface)),
                  if (!shrunk)
                    Text(facts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (!closed && provider == 'spotify' && here > 0)
              _refreshing.contains('spotify')
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      icon: const Icon(Icons.sync, size: 20),
                      tooltip: 'Refresh everything mirrored from Spotify',
                      visualDensity: VisualDensity.compact,
                      onPressed: _refreshSpotify,
                    ),
            Icon(closed ? Icons.expand_more : Icons.expand_less,
                size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.16))),
          ),
          child: Semantics(button: true, expanded: !closed, child: head),
        ),
        AnimatedSize(
          duration: moving(context, Motion.base),
          curve: Motion.enter,
          alignment: Alignment.topCenter,
          child: closed
              ? const SizedBox(height: 0)
              : _listsOf(context, provider, shrunk),
        ),
      ],
    );
  }

  Widget _listsOf(BuildContext context, String provider, bool shrunk) {
    final error = _errors[provider];
    if (error != null) {
      return _Trouble(error: error, onRetry: () => _again(provider));
    }
    final all = _lists[provider];
    if (all == null) return const _Waiting();
    if (all.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Text('${serviceLabel(provider)} has no playlists for this account.',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }

    // A filter only where there is something to look through.
    final filter = all.length > 12
        ? _filters.putIfAbsent(provider, TextEditingController.new)
        : null;
    final query = filter?.text.trim().toLowerCase() ?? '';
    final shown = query.isEmpty
        ? all
        : [for (final l in all) if (l.name.toLowerCase().contains(query)) l];
    // Only so many are built: an account can hold hundreds, and this is one section
    // of a page that has others. A search shows what it finds, up to the same cap.
    final cap = _cap[provider] ?? 12;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: filter,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Find one of ${all.length}',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: filter.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Clear',
                        onPressed: () => setState(filter.clear),
                      ),
              ),
            ),
          ),
        for (final l in shown.take(cap)) _row(context, provider, l, shrunk),
        if (shown.length > cap)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                PressButton(
                  label: 'Show ${(shown.length - cap).clamp(0, 30)} more',
                  onTap: () => setState(() => _cap[provider] = cap + 30),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('${shown.length - cap} not shown',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Nothing called that.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, String provider, _Remote l, bool shrunk) {
    final scheme = Theme.of(context).colorScheme;
    final key = '$provider:${l.remoteId}';
    final busy = _busy.contains(key);
    final queued = _queued.contains(key);
    final subtitle = [
      // Shazam cannot be asked what somebody has tagged, but connected to Spotify it
      // keeps this list up to date for ever — so mirroring it is the whole of "sync my
      // Shazams", and saying so is the only way anybody would find it among hundreds.
      if (l.shazam) 'Everything you have Shazammed',
      if (queued)
        'copying…'
      else if (l.mirrored) ...[
        '${l.here} here',
        if (l.unmatched > 0) '${l.unmatched} not matched',
      ] else ...[
        if (l.owner != null && l.owner != 'you') 'by ${l.owner}',
        if (l.count != null) '${l.count} songs',
      ],
    ].join(' · ');

    final Widget trailing;
    if (busy) {
      trailing = const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (l.mirrored) {
      trailing = PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        tooltip: 'Mirror',
        onSelected: (v) => v == 'stop' ? _stop(provider, l) : _mirror(provider, l),
        itemBuilder: (context) => [
          PopupMenuItem(
              value: 'refresh',
              child: Text('Refresh from ${serviceLabel(provider)}')),
          if (l.playlistId! > 0)
            const PopupMenuItem(value: 'stop', child: Text('Stop mirroring')),
        ],
      );
    } else {
      trailing = TextButton(
        onPressed: queued ? null : () => _mirror(provider, l),
        child: Text(queued ? 'Copying' : 'Mirror'),
      );
    }

    return ListTile(
      dense: shrunk,
      visualDensity: shrunk ? VisualDensity.compact : null,
      leading: Icon(
        l.shazam
            ? Icons.graphic_eq
            : l.mirrored
                ? Icons.cloud_done_outlined
                : Icons.cloud_outlined,
        size: shrunk ? 18 : 22,
        color: l.mirrored || l.shazam ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: shrunk || subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      // A mirror opens like any other playlist. One that is not mirrored yet does
      // nothing on a tap: every song mirrored is a lookup somewhere else, and that is
      // worth a button rather than a brush of the screen.
      onTap: l.mirrored && l.playlistId! > 0
          ? () => openPage(context,
              (_) => PlaylistPage(playlistId: l.playlistId!, name: l.name))
          : null,
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(18),
        child: Center(
          child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
}

/// A service that would not answer, said in a line rather than a page: the rest of
/// the library is still there around it.
class _Trouble extends StatelessWidget {
  const _Trouble({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(e is ApiException ? e.message : 'Could not load that',
                style: Mag.typewriter(11.5, color: scheme.error)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
