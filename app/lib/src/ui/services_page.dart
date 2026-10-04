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
import 'feed_page.dart' show showImportResult;
import 'mini_player.dart';
import 'spotify_page.dart';
import 'youtube_setup.dart';
import 'snack.dart';
import 'widths.dart';
import 'record_refresh.dart';
import 'scrobbling.dart';
import 'service_shelf.dart' show serviceIcon;

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

  /// Who this is on Spotify, when it is connected: Spotify is linked on a page of its
  /// own, but whether it is linked decides what can be imported here.
  String? _spotifyAs;
  bool _spotifyLinked = false;

  /// Where follows can be brought over from, as the server counts it: the linked
  /// accounts that say who they follow.
  List<FollowSource> _followSources = const [];

  /// Which service the followed artists are being brought over from, if any.
  String? _importingFollows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final s = await api.linkedServices();
      Map<String, dynamic>? spotify;
      try {
        spotify = await api.spotifyAccount();
      } catch (_) {
        // No Spotify on this server is "not linked", not a page that will not load.
      }
      var follows = const <FollowSource>[];
      try {
        follows = await api.followSources();
      } catch (_) {
        // A server from before it said: the section offers nothing rather than guesses.
      }
      final account = spotify?['account'] as Map<String, dynamic>?;
      if (mounted) {
        setState(() {
          _services = s;
          _error = null;
          _spotifyLinked = account != null;
          _spotifyAs = account?['display_name'] as String?;
          _followSources = follows;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Bring over the artists this person already follows elsewhere. Adds to who is
  /// followed here and never takes away; a Bandcamp label is opened into its acts.
  ///
  /// Every service names artists slightly differently and some of what they call an
  /// artist is not one, so the answer is reported in full rather than assumed: what
  /// was found, what was already here, and the names that could not be placed.
  Future<void> _importFollows(FollowSource source) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importingFollows = source.provider);
    messenger.say(snack(Text(source.provider == 'bandcamp'
        ? 'Reading who you follow on Bandcamp — a label is opened into its acts, so '
            'this can take a minute…'
        : 'Reading who you follow on ${source.label}…')));
    FollowImport r;
    try {
      r = await api.importFollowsFrom(source.provider);
    } catch (e) {
      messenger.say(problem(e));
      return;
    } finally {
      // Done before the answer is shown: the button is not still working while the
      // sheet saying what it did is open.
      if (mounted) setState(() => _importingFollows = null);
    }
    if (mounted) await showImportResult(context, r);
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
      // Ask first. A backup is somebody's whole listening history and it lands in
      // whichever account is signed in here — which is worth being sure about before
      // twenty-five playlists appear in it.
      final would = await api.importPlaylists(backup, dryRun: true);
      if (!mounted) return;
      final coming = (would['playlists'] as List?) ?? const [];
      final replaces = (would['replaces'] ?? 0) as int;
      final go = await confirm(
        context,
        'Import ${coming.length} '
            '${coming.length == 1 ? 'playlist' : 'playlists'}?',
        [
          '${would['tracks']} songs, into ${context.read<AppState>().user ?? 'this'}'
              "'s library.",
          if ((would['fetch'] ?? 0) != 0)
            '${would['fetch']} of them are not here yet and would be fetched.',
          if (replaces > 0)
            '$replaces existing '
                '${replaces == 1 ? 'playlist' : 'playlists'} of the same name would be '
                'written over.',
          if ((would['missing'] ?? 0) != 0)
            '${would['missing']} songs are named in the file but not described in it.',
        ].join('\n\n'),
        action: 'Import',
      );
      if (!go) return;

      final result = await api.importPlaylists(backup);
      final lists = (result['playlists'] as List?) ?? const [];
      final missing = (result['missing'] ?? 0) as int;
      if (!mounted) return;
      await context.read<AppState>().refresh();
      messenger.say(snack(Text([
          '${lists.length} ${lists.length == 1 ? 'playlist' : 'playlists'}',
          '${result['tracks']} songs',
          if (missing > 0) '$missing not in the file',
          if (result['audio'] == 'on play') 'audio fetched when played',
        ].join(' · ')),
      ));
    } on FormatException {
      messenger.say(snack(Text('That file is not a playlist backup.')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
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
      messenger.say(snack(Text('Copying it now — it will appear in your playlists.')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
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
      messenger.say(snack(Text('$e')));
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
      messenger.say(
          snack(Text('YouTube Music is linked')));
    }
  }

  Future<void> _link(LinkedService service) async {
    // Both captured before the dialog: it can sit open for a while, and a context used
    // afterwards may no longer be in the tree.
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final youtube = service.provider == 'youtube';

    // The code first, where this server can offer one.
    //
    // It used to be read with YouTube Music's internal API, which refuses every token
    // but its own apps' — so the cookie went first. The server now reads a code
    // sign-in with YouTube's public API, which takes it, and a code lasts where a
    // copied cookie expires or is turned away.
    if (youtube) {
      final how = await _howToSignIn(service);
      if (how == null) return;
      if (how == 'code') {
        await _signInWithCode(service);
        return;
      }
      if (how == 'setup') {
        if (!mounted) return;
        if (await youtubeCodeSignInSetup(context)) await _load();
        return;
      }
      if (!mounted) return;
    }

    final handle = await promptForName(
      context,
      'Link ${service.label}',
      '',
      youtube ? 'Paste the headers here' : 'Name',
      youtube
          ? 'Nothing about a YouTube account is public, so this one needs a '
              'sign-in rather than a name. On a computer, signed in to '
              'music.youtube.com: open the developer tools, Network tab, click any '
              'request to music.youtube.com, and copy the cookie — the long line '
              'starting with "cookie:". Pasting just the cookie is enough; the whole '
              'block of request headers works too.'
          : service.hint,
      youtube,
    );
    if (handle == null || handle.trim().isEmpty) return;
    try {
      await api.linkService(service.provider, handle.trim());
      await _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  /// Which way in, for the one service with more than one.
  ///
  /// Answers 'paste', 'code' or 'setup' — or null when nobody chose anything.
  Future<String?> _howToSignIn(LinkedService service) =>
      ask<String>(
        context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (service.signIn == 'code')
                ListTile(
                  leading: const Icon(Icons.pin_outlined),
                  title: const Text('Sign in with a code'),
                  subtitle: const Text(
                      'Recommended. Type a short code into a browser you already '
                      'use, on any device. Reads your own playlists and liked '
                      'songs, and stays signed in.'),
                  onTap: () => Navigator.of(context).pop('code'),
                )
              else
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Set up code sign-in…'),
                  subtitle: const Text(
                      'Needs a Google project, once, for the whole server. For '
                      'admins.'),
                  onTap: () => Navigator.of(context).pop('setup'),
                ),
              ListTile(
                leading: const Icon(Icons.cookie_outlined),
                title: const Text('Paste the cookie'),
                subtitle: const Text(
                    'From a signed-in music.youtube.com on a computer. Also sees '
                    'playlists you saved from others, but expires, and YouTube '
                    'often turns it away.'),
                onTap: () => Navigator.of(context).pop('paste'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final services = _services;
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Connected services')),
      body: _error != null && services == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : services == null
              ? const Center(child: CircularProgressIndicator())
              : RecordRefresh(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, bottomForPlayer(context)),
                    children: [
                      Text(
                        'Most of these are read by name rather than by signing in — a '
                        'profile id or a username is enough, and only what is public '
                        'is read. Spotify and YouTube Music need a sign-in, because '
                        'nothing about those accounts is public. Their playlists are '
                        'in the Library, under From your services.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      for (final s in services) _ServiceTile(
                        service: s,
                        onLink: () => _link(s),
                        onUnlink: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await context.read<AppState>().api
                                .unlinkService(s.provider);
                          } catch (e) {
                            messenger.say(problem(e));
                          }
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
                          subtitle: Text(_spotifyLinked
                              ? _spotifyAs ?? 'Connected'
                              : 'Signs in properly — everything about a Spotify '
                                  'account is private'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const SpotifyPage()));
                            await _load();
                          },
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Divider(),
                      // Moved here from the list of who you follow: which accounts
                      // can be read is decided on this page, so what to bring over
                      // from them is too.
                      Text('Who you follow',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        _followSources.isEmpty
                            ? 'Link Spotify, SoundCloud, Deezer or Bandcamp above to '
                                'bring over the artists you follow there.'
                            : 'Bring over the artists you already follow, so their '
                                'next records turn up in the feed and on Discover. '
                                'Nothing here is taken away, and a Bandcamp label is '
                                'opened into the acts on it.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_followSources.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final f in _followSources)
                              FilledButton.tonalIcon(
                                onPressed: _importingFollows != null
                                    ? null
                                    : () => _importFollows(f),
                                icon: _importingFollows == f.provider
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.person_add_alt_outlined),
                                label: Text('From ${f.label}'),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Divider(),
                      // The other direction: not where music comes in from, but where
                      // what was played is written down.
                      Text('A listening diary',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      const ScrobblingCard(),
                      const SizedBox(height: 8),
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

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(serviceIcon(service.provider)),
        title: Text(service.label),
        subtitle: Text(service.isLinked
            ? [
                service.displayName ?? service.handle!,
                if (!service.plays) 'playlists only — Deezer cannot be played',
              ].join(' · ')
            : service.hint),
        // What a linked account holds is listed in the Library, beside the playlists
        // it would become, rather than here.
        trailing: service.isLinked
            ? IconButton(
                icon: const Icon(Icons.link_off, size: 20),
                tooltip: 'Unlink',
                onPressed: onUnlink,
              )
            : FilledButton(onPressed: onLink, child: const Text('Link')),
      ),
    );
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
