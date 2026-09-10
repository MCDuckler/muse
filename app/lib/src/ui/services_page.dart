import '../api/client.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'spotify_page.dart';
import 'youtube_sign_in.dart';

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

  bool _importing = false;

  /// Playlists from another player's backup file.
  ///
  /// The lists people build are the part of a music app that takes years and cannot be
  /// re-derived from anything: a backup file is the only way they leave the app that
  /// holds them. bcplayer's is the format asked for, and the ids in it are Bandcamp's
  /// own — which is why most of an import lands instantly.
  Future<void> _importBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<AppState>().api;
    final file = await FilePicker.pickFile(
        type: FileType.custom, allowedExtensions: ['json'], dialogTitle: 'Backup file');
    if (file == null || !mounted) return;

    setState(() => _importing = true);
    try {
      // Bytes rather than a path: the web build never has one.
      final text = utf8.decode(await file.readAsBytes());
      final backup = jsonDecode(text);
      if (backup is! Map<String, dynamic>) {
        throw const FormatException('that file is not a playlist backup');
      }
      final result = await api.importPlaylists(backup);
      final lists = (result['playlists'] as List?) ?? const [];
      final missing = (result['missing'] ?? 0) as int;
      if (!mounted) return;
      await context.read<AppState>().refresh();
      messenger.showSnackBar(SnackBar(
        content: Text([
          '${lists.length} ${lists.length == 1 ? 'playlist' : 'playlists'}',
          '${result['tracks']} songs',
          if (missing > 0) '$missing not in the file',
          if (result['audio'] == 'on play') 'audio fetched when played',
        ].join(' · ')),
      ));
    } on FormatException {
      messenger.showSnackBar(const SnackBar(
          content: Text('That file is not a playlist backup.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Mirror a YouTube Music playlist from a link.
  ///
  /// A playlist somebody sends you is public, and public needs no sign-in — so this
  /// works whether or not an account is linked here.
  Future<void> _importYoutubeLink() async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final link = await promptForName(
        context,
        'YouTube Music playlist',
        '',
        'https://music.youtube.com/playlist?list=…',
        'Paste a link to a playlist. Public ones need no account.');
    if (link == null) return;
    try {
      await api.syncServiceList('youtube', link);
      messenger.showSnackBar(const SnackBar(
          content: Text('Copying it now — it will appear in your playlists.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Signing in to YouTube Music with a code, the way a television does it.
  Future<void> _signInWithCode(LinkedService service) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    ({String deviceCode, String userCode, String url, int interval}) code;
    try {
      code = await api.startYoutubeSignIn();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;

    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => _CodeDialog(code: code, api: api),
    );
    if (done == true) {
      await _load();
      messenger.showSnackBar(
          const SnackBar(content: Text('YouTube Music is linked')));
    }
  }

  Future<void> _link(LinkedService service) async {
    // Both captured before the dialog: it can sit open for a while, and a context used
    // afterwards may no longer be in the tree.
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final youtube = service.provider == 'youtube';

    // Google refuses to sign anybody in inside an app's own browser — "this browser or
    // app may not be secure" — and no amount of pretending to be Chrome gets past it,
    // because that is what the check is for. What Google does support is a code: it is
    // shown here and typed into a browser the person already trusts.
    if (youtube && service.signIn == 'code') {
      await _signInWithCode(service);
      return;
    }

    // Failing that, the app's own browser is still worth offering: it works for
    // accounts Google is relaxed about, and it is better than nothing on a phone.
    if (youtube && canSignInToYouTube) {
      final captured = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const YouTubeSignInPage()));
      if (captured == null) return;
      try {
        await api.linkService(service.provider, captured);
        await _load();
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }

    final handle = await promptForName(
      context,
      'Link ${service.label}',
      '',
      youtube ? 'Paste the headers here' : 'Name',
      youtube
          ? 'Nothing about a YouTube account is public, so this one needs a '
              'sign-in rather than a name. On a computer: open '
              'music.youtube.com signed in, open the developer tools, Network tab, '
              'click any request to music.youtube.com, and copy the request headers '
              '(the block that includes "cookie:"). Paste the whole block.'
          : service.hint,
      youtube,
    );
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
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Connected services')),
      body: _error != null && services == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : services == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, bottomForPlayer),
                    children: [
                      Text(
                        'Most of these are read by name rather than by signing in — a '
                        'profile id or a username is enough, and only what is public '
                        'is read. Spotify and YouTube Music need a sign-in, because '
                        'nothing about those accounts is public.',
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
                      // Spotify is here too, even though it works differently: it is
                      // one of the places your music is, and asking "where is Spotify"
                      // should not be answered by a different part of the settings.
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: const Icon(Icons.music_note_outlined),
                          title: const Text('Spotify'),
                          subtitle: const Text(
                              'Signs in properly — everything about a Spotify '
                              'account is private'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const SpotifyPage())),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Divider(),
                      Text('From a link',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        'A YouTube Music playlist somebody sent you. Public playlists '
                        'need no account here.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: _importYoutubeLink,
                          icon: const Icon(Icons.link),
                          label: const Text('Copy a playlist from a link'),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Divider(),
                      Text('From a file',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        'A backup exported by bcplayer. The playlists come across with '
                        'their names, and songs already here are recognised rather '
                        'than fetched again.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: _importing ? null : _importBackup,
                          icon: _importing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.upload_file),
                          label: Text(_importing
                              ? 'Importing…'
                              : 'Import playlists from a backup'),
                        ),
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
    return PlayerScaffold(
      appBar: AppBar(title: Text(widget.service.label)),
      body: _error != null && lists == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : lists == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: bottomForPlayer),
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


/// The code, and the waiting.
///
/// It polls rather than asking the person to come back and press something: they are
/// on another device typing, and the moment it goes through is the moment this should
/// close.
class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.code, required this.api});
  final ({String deviceCode, String userCode, String url, int interval}) code;
  final ApiClient api;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  Timer? _poll;
  String? _trouble;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(
        Duration(seconds: widget.code.interval.clamp(2, 15)), (_) => _ask());
  }

  Future<void> _ask() async {
    try {
      await widget.api.finishYoutubeSignIn(widget.code.deviceCode);
      _poll?.cancel();
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      // 409 is "they have not finished yet", which is the normal state of this dialog.
      if (e.status != 409 && mounted) setState(() => _trouble = e.message);
    } catch (_) {
      // A dropped request is not worth reporting: the next tick asks again.
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Sign in to YouTube Music'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('On any device, open ${widget.code.url} and enter this code:',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          Center(
            child: SelectableText(
              widget.code.userCode,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  letterSpacing: 4, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Waiting for you to finish…',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          if (_trouble != null) ...[
            const SizedBox(height: 10),
            Text(_trouble!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(
              ClipboardData(text: widget.code.userCode)),
          child: const Text('Copy code'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
