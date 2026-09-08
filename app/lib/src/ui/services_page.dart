import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';

/// Services linked by typing a name.
///
/// Spotify needs a consent screen because everything about a Spotify account is
/// private. These three are public reads: a Deezer profile id, a SoundCloud username, a
/// Bandcamp fan name. Nothing here can post, follow or spend anything — it reads what
/// anyone with the link could read.
class ServicesPage extends StatefulWidget {
  const ServicesPage({super.key});

  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<ServicesPage> {
  List<LinkedService>? _services;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<AppState>().api.linkedServices();
      if (mounted) setState(() { _services = s; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _link(LinkedService service) async {
    // Both captured before the dialog: it can sit open for a while, and a context used
    // afterwards may no longer be in the tree.
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final handle = await promptForName(context, 'Link ${service.label}');
    if (handle == null || handle.trim().isEmpty) return;
    try {
      await api.linkService(service.provider, handle.trim());
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    return Scaffold(
      appBar: AppBar(title: const Text('Connected services')),
      body: _error != null && services == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : services == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                    children: [
                      Text(
                        'These are read by name rather than by signing in — a profile '
                        'id or a username is enough, and only what is public is read.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      for (final s in services) _ServiceTile(
                        service: s,
                        onLink: () => _link(s),
                        onUnlink: () async {
                          await context.read<AppState>().api
                              .unlinkService(s.provider);
                          await _load();
                        },
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service, required this.onLink,
      required this.onUnlink});

  final LinkedService service;
  final VoidCallback onLink;
  final Future<void> Function() onUnlink;

  IconData get _icon => switch (service.provider) {
        'bandcamp' => Icons.album_outlined,
        'soundcloud' => Icons.cloud_outlined,
        _ => Icons.library_music_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(_icon),
        title: Text(service.label),
        subtitle: Text(service.isLinked
            ? [
                service.displayName ?? service.handle!,
                if (!service.plays) 'playlists only — Deezer cannot be played',
              ].join(' · ')
            : service.hint),
        trailing: service.isLinked
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _ServiceLists(service: service))),
                    child: const Text('Lists'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link_off, size: 20),
                    tooltip: 'Unlink',
                    onPressed: onUnlink,
                  ),
                ],
              )
            : FilledButton(onPressed: onLink, child: const Text('Link')),
      ),
    );
  }
}

/// What a linked account holds, and which of it to keep a copy of.
class _ServiceLists extends StatefulWidget {
  const _ServiceLists({required this.service});
  final LinkedService service;

  @override
  State<_ServiceLists> createState() => _ServiceListsState();
}

class _ServiceListsState extends State<_ServiceLists> {
  List<RemoteList>? _lists;
  Object? _error;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await context.read<AppState>().api.serviceLists(widget.service.provider);
      if (mounted) setState(() { _lists = l; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = _lists;
    return Scaffold(
      appBar: AppBar(title: Text(widget.service.label)),
      body: _error != null && lists == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : lists == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 40),
                  children: [
                    for (final l in lists)
                      ListTile(
                        title: Text(l.name, maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          if (l.count != null) '${l.count} items',
                          if (l.mirrored) 'copied · ${l.mirroredItems} here',
                        ].join(' · ')),
                        trailing: _busy.contains(l.remoteId)
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : TextButton(
                                onPressed: () => _mirror(l),
                                child: Text(l.mirrored ? 'Refresh' : 'Copy'),
                              ),
                      ),
                  ],
                ),
    );
  }

  Future<void> _mirror(RemoteList list) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(list.remoteId));
    try {
      await app.api.mirrorList(widget.service.provider, list);
      messenger.showSnackBar(SnackBar(
          content: Text('Copying "${list.name}" — it will appear in your playlists')));
      await app.refreshPlaylists();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy.remove(list.remoteId));
    }
  }
}
