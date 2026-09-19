import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'jam_page.dart';
import 'library_page.dart';
import 'mini_player.dart';
import 'snack.dart';
import 'dialogs.dart';
import 'song_row.dart';
import 'track_menu.dart';

/// Everybody else on this server.
///
/// The catalog has always been shared — one library on one box, and whatever anybody
/// fetches is there for everyone — but there was no way to see that. This is the part
/// of it you can look at: who else is here, what they have kept, and the fact that one
/// of them has a jam going right now, which is the thing that has to be visible without
/// being gone looking for.
class SocialPage extends StatefulWidget {
  const SocialPage({super.key});

  @override
  State<SocialPage> createState() => _SocialPageState();
}

class _SocialPageState extends State<SocialPage> {
  List<Person>? _people;
  int _you = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final said = await context.read<AppState>().api.people();
      if (!mounted) return;
      setState(() {
        _people = said.people;
        _you = said.you;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    if (_error != null && people == null) {
      // A way back, rather than an exception's text in the middle of a tab.
      return ErrorRetry(
          error: _error!,
          onRetry: () {
            setState(() => _error = null);
            _load();
          });
    }
    if (people == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Whoever has a jam going, first. Then everybody else by name — a list of people
    // sorted by how much they have listened to is a leaderboard, which this is not.
    final sorted = [...people]..sort((a, b) {
        if ((a.jam != null) != (b.jam != null)) return a.jam != null ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 160),
        children: [
          for (final person in sorted)
            _PersonRow(
              person: person,
              you: person.id == _you,
              onOpen: () => Navigator.of(context)
                  .push(MaterialPageRoute(
                      builder: (_) => PersonPage(person: person)))
                  .then((_) => _load()),
            ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow(
      {required this.person, required this.you, required this.onOpen});
  final Person person;
  final bool you;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final scheme = Theme.of(context).colorScheme;
    final jam = person.jam;
    final on = person.playing;
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Artwork(
            url: person.avatarUrl == null
                ? null
                : api.avatarUrl(person.id, version: person.avatarVersion),
            size: 46,
            radius: 23,
          ),
          // A jam is happening now. Nothing on this row matters as much.
          if (jam != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                    color: scheme.surface, shape: BoxShape.circle),
                child: Icon(Icons.graphic_eq, size: 15, color: scheme.primary),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
              child: Text(person.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (you)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('you',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.outline)),
            ),
        ],
      ),
      subtitle: on != null
          // What somebody has on says more about them than how many songs they have,
          // and it is the one thing on this screen that changes while you watch it.
          ? Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 2),
                  child: Artwork(track: on.track, size: 22, radius: 3),
                ),
                if (on.now)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child:
                        Icon(Icons.graphic_eq, size: 13, color: scheme.primary),
                  ),
                Expanded(
                  child: Text(
                    '${on.track.displayTitle} · ${on.track.artistLine}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: on.now ? TextStyle(color: scheme.primary) : null,
                  ),
                ),
              ],
            )
          : Text(
              jam != null
                  ? 'In a jam · ${jam.people} listening'
                  : [
                      '${person.songs} songs',
                      if (person.playlists > 0) '${person.playlists} playlists',
                    ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: jam != null ? TextStyle(color: scheme.primary) : null,
            ),
      trailing: jam == null
          ? const Icon(Icons.chevron_right)
          : FilledButton.tonal(
              onPressed: () async {
                final app = context.read<AppState>();
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await app.joinJam(jam.code);
                  messenger.say(
                      snack(Text('Listening with ${person.name}')));
                } catch (e) {
                  messenger.say(snack(Text('$e')));
                }
              },
              child: const Text('Join'),
            ),
      onTap: onOpen,
    );
  }
}

/// One person: what they are in the middle of, what they have made, what they have
/// kept. Their library is the shared catalog seen from where they are standing, so
/// anything on it is a tap from being in your queue as well.
class PersonPage extends StatefulWidget {
  const PersonPage({super.key, required this.person});
  final Person person;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  Person? _them;
  List<Playlist>? _playlists;
  List<Track> _library = const [];
  int _total = 0;
  bool _more = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _them = widget.person;
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      // Three questions with nothing to do with each other, asked together: one after
      // another was three round trips of an empty page.
      final asking = api.person(widget.person.id);
      final listing = api.personPlaylists(widget.person.id);
      final holding = api.personLibrary(widget.person.id);
      final them = await asking;
      final lists = await listing;
      final library = await holding;
      if (!mounted) return;
      setState(() {
        _them = them;
        _playlists = lists;
        _library = library.items;
        _total = library.total;
        _more = library.items.length < library.total;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _moreLibrary() async {
    final api = context.read<AppState>().api;
    final next = await api.personLibrary(widget.person.id,
        offset: _library.length, limit: 60);
    if (!mounted) return;
    setState(() {
      _library = [..._library, ...next.items];
      _more = _library.length < next.total;
    });
  }

  Future<void> _save(Playlist list) async {
    final api = context.read<AppState>().api;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (list.saved) {
        await api.unsavePlaylist(list.id);
      } else {
        await api.savePlaylist(list.id);
      }
      await app.refreshPlaylists();
      await _load();
      messenger.say(snack(Text(list.saved
          ? 'Removed "${list.name}" from your library'
          : 'Saved "${list.name}" to your library')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final them = _them!;
    final api = context.read<AppState>().api;
    final scheme = Theme.of(context).colorScheme;
    final jam = them.jam;
    return PlayerScaffold(
      appBar: AppBar(title: Text(them.name)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(8, 8, 8, bottomForPlayer(context)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
              child: Row(
                children: [
                  Artwork(
                    url: them.avatarUrl == null
                        ? null
                        : api.avatarUrl(them.id,
                            version: them.avatarVersion, small: false),
                    size: 72,
                    radius: 36,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(them.name,
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 4),
                        Text(
                          [
                            '${them.songs} songs',
                            if (them.playlists > 0)
                              '${them.playlists} playlists',
                            if (them.played > 0) '${them.played} played',
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (jam != null)
              Card(
                color: scheme.primaryContainer,
                child: ListTile(
                  leading: Icon(Icons.graphic_eq, color: scheme.onPrimaryContainer),
                  title: Text('${them.name} has a jam going',
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                  subtitle: Text('${jam.people} listening',
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                  trailing: FilledButton(
                    onPressed: () async {
                      final app = context.read<AppState>();
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await app.joinJam(jam.code);
                        if (context.mounted) await showJam(context);
                      } catch (e) {
                        messenger.say(snack(Text('$e')));
                      }
                    },
                    child: const Text('Join'),
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            if ((_playlists ?? const []).isNotEmpty) ...[
              const _Heading('Their playlists'),
              for (final list in _playlists!)
                ListTile(
                  leading: Artwork(
                      url: api.coverUrlForPath(list.coverPath), size: 44, radius: 6),
                  title: Text(list.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    '${list.itemCount} songs',
                    if (list.openEdit) 'anyone can add',
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: Icon(list.saved
                        ? Icons.bookmark
                        : Icons.bookmark_add_outlined),
                    tooltip: list.saved
                        ? 'In your library'
                        : 'Save to your library',
                    onPressed: () => _save(list),
                  ),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) =>
                          PlaylistPage(playlistId: list.id, name: list.name)))
                      .then((_) => _load()),
                ),
            ],
            if (them.recent.isNotEmpty) ...[
              const _Heading('What they have been playing'),
              for (final t in them.recent)
                SongRow(track: t, onTap: () => addAndSay(context, t)),
            ],
            const _Heading('Their library'),
            if (_library.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Nothing kept yet.'),
              ),
            for (final t in _library)
              SongRow(track: t, onTap: () => addAndSay(context, t)),
            if (_more)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: TextButton(
                    onPressed: _moreLibrary,
                    child: Text('Show more of ${_total - _library.length}'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}
