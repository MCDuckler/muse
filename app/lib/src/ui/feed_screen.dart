import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artist_choice.dart';
import 'artwork.dart';
import 'browse_page.dart' show AlbumPage;
import 'dialogs.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'skeleton.dart';
import 'snack.dart';
import 'song_row.dart' show FavouriteButton;
import 'station.dart';
import 'track_menu.dart' show addAndSay, sayDisliked;

/// The feed: one song at a time, as big as the screen allows.
///
/// The Discover page is a magazine's contents; this is turning its pages. Each card is
/// a record's art nearly the width of the screen, the song and who it is by, the three
/// things anybody does with a song they like — put it on a list, heart it, pass it on —
/// then the genres it is filed under where it came from, each of which can be followed
/// from here, and then two or three of what people said about it: Bandcamp's
/// "supported by" box, SoundCloud's comments. One list, scrolled: a page view with
/// a scroller inside each page gave the inside one every drag, and nothing moved.
///
/// Opened from the button on the Discover page, and by tapping the Discover tab twice.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final _cards = <FeedCard>[];
  final _details = <int, CardDetails?>{};
  final _asked = <int>{};
  Set<String> _following = {};
  int _total = 0;
  bool _loading = false;
  Object? _error;

  /// Only the songs from one service, or null for all of them. Kept for the session,
  /// so the feed opened again is the one that was being read.
  static String? _lastService;
  String? _service = _lastService;

  /// How many songs each service has in the whole feed, unfiltered.
  Map<String, int> _services = const {};

  /// Bumped when the filter changes, so a page asked for under the old one is dropped.
  int _round = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
    unawaited(_loadGenres());
  }

  Future<void> _loadGenres() async {
    try {
      final got = await context.read<AppState>().api.genres();
      if (mounted) setState(() => _following = got.following.toSet());
    } catch (_) {}
  }

  Future<void> _more() async {
    if (_loading || (_cards.isNotEmpty && _cards.length >= _total)) return;
    _loading = true;
    final round = _round;
    try {
      final got = await context.read<AppState>().api
          .feedCards(offset: _cards.length, limit: 20, service: _service);
      if (!mounted || round != _round) return;
      setState(() {
        _cards.addAll(got.items);
        _total = got.total;
        _services = got.services;
        _error = null;
      });
    } catch (e) {
      if (mounted && round == _round) setState(() => _error = e);
    } finally {
      if (round == _round) _loading = false;
    }
  }

  /// Play the card at [i], and the feed with it: one queue of every song in it, in the
  /// feed's order, playing from that song — the way a song tapped in a playlist plays
  /// the playlist. What has not been scrolled to yet is fetched and put on the end once
  /// the music has started, rather than kept waiting for.
  Future<void> _play(int i) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final service = _service;
    final name = service == null
        ? 'The feed'
        : 'The feed · ${_serviceNames[service] ?? service}';
    final loaded = [for (final c in _cards) c.track];
    final total = _total;
    try {
      await app.playNow(loaded, startAt: i, named: name);
    } catch (e) {
      messenger.say(problem(e));
      return;
    }
    if (total <= loaded.length) return;
    final queueId = app.activeQueue?.id;
    final have = {for (final t in loaded) t.id};
    final rest = <Track>[];
    try {
      for (var offset = loaded.length; offset < total; offset += 50) {
        final got = await app.api.feedCards(offset: offset, limit: 50, service: service);
        for (final c in got.items) {
          if (have.add(c.track.id)) rest.add(c.track);
        }
      }
    } catch (_) {
      // The songs already on are the feed as far as it was read; that is still a queue.
    }
    // Only onto the queue it started: somebody who has put something else on since
    // does not want the rest of the feed on the end of that.
    if (rest.isEmpty || app.activeQueue?.id != queueId) return;
    try {
      await app.addTracks(rest);
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  void _only(String? service) {
    if (service == _service) return;
    setState(() {
      _service = _lastService = service;
      _round++;
      _loading = false;
      _cards.clear();
      _total = 0;
      _error = null;
    });
    unawaited(_more());
  }

  /// A card's genres and comments arrive as it comes into view, not all at once.
  void _detail(int trackId) {
    if (_asked.contains(trackId)) return;
    _asked.add(trackId);
    unawaited(() async {
      try {
        final d = await context.read<AppState>().api.cardDetails(trackId);
        if (mounted) setState(() => _details[trackId] = d);
      } catch (_) {
        if (mounted) setState(() => _details[trackId] = const CardDetails());
      }
    }());
  }

  Future<void> _toggleGenre(String genre) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final was = _following.contains(genre);
    setState(() => was ? _following.remove(genre) : _following.add(genre));
    try {
      if (was) {
        await api.unfollowGenre(genre);
      } else {
        await api.followGenre(genre);
        messenger.say(snack(Text('Following $genre — its new records and what is trending in it '
            'come to Discover')));
      }
    } catch (e) {
      setState(() => was ? _following.add(genre) : _following.remove(genre));
      messenger.say(problem(e));
    }
  }

  /// Said no to: the card goes at once, and Undo puts it back where it was.
  void _dislike(FeedCard card) {
    final at = _cards.indexOf(card);
    if (at < 0) return;
    setState(() {
      _cards.removeAt(at);
      _total = (_total - 1).clamp(0, 1 << 30);
    });
    unawaited(sayDisliked(context, card.track, true, onUndo: () {
      if (!mounted || _cards.contains(card)) return;
        setState(() {
        _cards.insert(at.clamp(0, _cards.length), card);
        _total += 1;
      });
    }));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlayerScaffold(
      appBar: AppBar(
        title: Text('The feed', style: Mag.title(20, color: scheme.onSurface)),
        actions: [
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text('$_total songs',
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant))),
            ),
        ],
        // Which service the songs came from, to read only one of them. Offered once
        // there are two to choose between, or while one is chosen.
        bottom: _offered.length > 1 || _service != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(44),
                child: SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    children: [
                      _ServiceChip(
                        label: 'All',
                        count: _services.values.fold(0, (a, b) => a + b),
                        on: _service == null,
                        onTap: () => _only(null),
                      ),
                      for (final s in _offered)
                        _ServiceChip(
                          label: _serviceNames[s] ?? s,
                          count: _services[s] ?? 0,
                          on: _service == s,
                          onTap: () => _only(_service == s ? null : s),
                        ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: _cards.isEmpty
          ? _error != null
              ? ErrorRetry(error: _error!, onRetry: _more)
              : _loading || _total == 0 && _error == null && _asked.isEmpty && _cards.isEmpty && _loading
                  ? const SongsComing(rows: 3)
                  : _total == 0 && !_loading
                      ? _service != null
                          ? EmptyHint(
                              icon: Icons.filter_alt_off_outlined,
                              title: 'Nothing from ${_serviceNames[_service] ?? _service} now',
                              body: 'Tap All to read the whole feed.')
                          : const EmptyHint(
                              icon: Icons.auto_awesome_outlined,
                              title: 'Nothing in the feed yet',
                              body: 'It is made of the lists on the Discover page and what is '
                                  'trending in the genres you follow. Play a few songs, follow a '
                                  'genre or two, and come back after the overnight build.')
                      : const SongsComing(rows: 3)
          : ListView.builder(
              padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
              itemCount: _cards.length,
              itemBuilder: (context, i) {
                final card = _cards[i];
                _detail(card.track.id);
                if (i >= _cards.length - 4) unawaited(_more());
                return _Card(
                  card: card,
                  details: _details[card.track.id],
                  following: _following,
                  onGenre: _toggleGenre,
                  onPlay: () => _play(i),
                  onDislike: () => _dislike(card),
                  index: i,
                  count: _total,
                );
              },
            ),
    );
  }
}

const _serviceNames = {
  'bandcamp': 'Bandcamp',
  'soundcloud': 'SoundCloud',
  'youtube': 'YouTube',
};

extension on _FeedScreenState {
  /// The services with songs in the feed, plus the one chosen even when it has none.
  List<String> get _offered => [
        for (final s in _serviceNames.keys)
          if ((_services[s] ?? 0) > 0 || _service == s) s,
      ];
}

class _ServiceChip extends StatelessWidget {
  const _ServiceChip(
      {required this.label, required this.count, required this.on, required this.onTap});
  final String label;
  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = on ? scheme.surface : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: on,
        label: '$label, $count songs',
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
              decoration: BoxDecoration(
                color: on ? scheme.onSurface : null,
                border: Border.all(color: scheme.onSurface, width: 1.2),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label.toUpperCase(), style: Mag.flag(10.5, color: ink)),
                const SizedBox(width: 6),
                Text('$count', style: Mag.typewriter(10.5, color: ink)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.card,
    required this.details,
    required this.following,
    required this.onGenre,
    required this.onPlay,
    required this.onDislike,
    required this.index,
    required this.count,
  });

  final FeedCard card;

  /// Not for me: out of the feed now, and held against its artist from here on.
  final VoidCallback onDislike;
  final CardDetails? details;
  final Set<String> following;
  final ValueChanged<String> onGenre;

  /// Plays the feed from this card.
  final VoidCallback onPlay;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    final t = card.track;
    final screen = MediaQuery.sizeOf(context);
    // Nearly the width of the screen, and never more than half its height, so the
    // words and the first comment are in view with the picture on a phone held upright.
    final side = (screen.width - 32).clamp(120.0, screen.height * 0.52);
    return Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.5), width: 1.5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Kicker(card.why.isEmpty ? card.listName : card.why)),
              Text('${index + 1} / $count',
                  style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 8),
            Center(
              child: Semantics(
                button: true,
                label: 'Play ${t.displayTitle}',
                child: GestureDetector(
                  onTap: () {
                    feel(Feel.commit);
                    onPlay();
                  },
                  child: Stack(
                    alignment: Alignment.bottomLeft,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.onSurface, width: 1.2),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 14,
                                offset: const Offset(0, 6)),
                          ],
                        ),
                        child: Artwork(track: t, size: side, radius: 0, small: false),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Container(
                          width: 56,
                          height: 56,
                          color: scheme.onSurface,
                          child: Icon(Icons.play_arrow, color: scheme.surface, size: 36),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(t.displayTitle.toUpperCase(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Mag.headline(26, color: scheme.onSurface).copyWith(height: 0.98)),
            const SizedBox(height: 2),
            Builder(builder: (line) => GestureDetector(
              onTap: artistsOf(t).isEmpty ? null : () => openArtistOf(context, t, anchor: line),
              child: Text(
                [if (t.artists.isNotEmpty) 'by ${t.artistLine}', if ((t.album ?? '').isNotEmpty) t.album!]
                    .join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Mag.typewriter(12, color: scheme.onSurfaceVariant),
              ),
            )),
            const SizedBox(height: 10),
            // The things done with a song — on a list, in the queue, hearted — and the
            // way on to who made it and the record it is from, the arrow at the end.
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.5)),
                  bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.5)),
                ),
              ),
              child: Row(children: [
                // An icon like the rest: six to a row leaves a small phone no room for
                // a word.
                Expanded(
                  child: IconButton(
                    tooltip: 'Add to a playlist',
                    onPressed: () => addToPlaylistSheet(context, app, t),
                    icon: Icon(Icons.playlist_add, size: 23, color: scheme.primary),
                  ),
                ),
                _rule(scheme),
                // Onto the end of whatever is playing; held, it plays next. Not an
                // IconButton: its tooltip takes the long press on a phone.
                Expanded(
                  child: Tooltip(
                    message: 'Add to queue',
                    triggerMode: TooltipTriggerMode.manual,
                    child: Semantics(
                      button: true,
                      label: 'Add to queue',
                      hint: 'Long press to play it next',
                      child: InkResponse(
                        radius: 22,
                        onTap: () => addAndSay(context, t),
                        onLongPress: () => addAndSay(context, t, mode: 'next'),
                        child: const SizedBox(
                            height: 40, child: Icon(Icons.queue_music, size: 22)),
                      ),
                    ),
                  ),
                ),
                _rule(scheme),
                Expanded(child: Center(child: FavouriteButton(trackId: t.id, size: 24))),
                _rule(scheme),
                Expanded(
                  child: IconButton(
                    tooltip: 'Not for me',
                    onPressed: onDislike,
                    icon: const Icon(Icons.thumb_down_outlined, size: 21),
                  ),
                ),
                _rule(scheme),
                // Who made it; by several, a menu of them.
                Expanded(
                  child: Builder(builder: (button) {
                    final names = artistsOf(t);
                    return IconButton(
                      tooltip: names.length > 1 ? 'The artists' : 'The artist',
                      onPressed: names.isEmpty
                          ? null
                          : () => openArtistOf(context, t, anchor: button),
                      icon: Icon(names.length > 1 ? Icons.people_outline : Icons.person_outline,
                          size: 22),
                    );
                  }),
                ),
                _rule(scheme),
                // The record it is from.
                Expanded(
                  child: IconButton(
                    tooltip: (t.album ?? '').isEmpty ? 'Not on a record' : 'The record',
                    onPressed: (t.album ?? '').isEmpty
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => AlbumPage(
                                album: AlbumSummary(
                                    name: t.album!,
                                    artist: t.artists.isEmpty ? '' : t.artists.first,
                                    tracks: 0)))),
                    icon: const Icon(Icons.arrow_forward, size: 22),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            if (details == null)
              Row(children: const [Bone(width: 70, height: 22), SizedBox(width: 8), Bone(width: 90, height: 22)])
            else ...[
              if (details!.genres.isNotEmpty) ...[
                Text('FILED UNDER', style: Mag.flag(10, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in details!.genres)
                      _GenreChip(
                        genre: g,
                        following: following.contains(g),
                        onTap: () => onGenre(g),
                        onLongPress: () => startStation(context, genre: g),
                      ),
                  ],
                ),
              ],
              if (details!.comments.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(details!.source == 'soundcloud' ? 'SAID ON SOUNDCLOUD' : 'SUPPORTED BY',
                    style: Mag.flag(10, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                for (final c in _shown(details!.comments)) _Comment(comment: c),
              ],
              if (details!.genres.isEmpty && details!.comments.isEmpty && (details!.about ?? '').isNotEmpty)
                Text(details!.about!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.quote(14, color: scheme.onSurface)),
            ],
          ],
        ),
      );
  }

  Widget _rule(ColorScheme scheme) =>
      Container(width: 1, height: 36, color: scheme.onSurface.withValues(alpha: 0.35));

  /// Two or three, by how long they are: three short ones read as a chorus, three long
  /// ones push the next song off the page.
  static List<SongComment> _shown(List<SongComment> all) {
    if (all.length <= 2) return all;
    final three = all.take(3).toList();
    final letters = three.fold<int>(0, (n, c) => n + c.text.length);
    return letters <= 260 ? three : three.take(2).toList();
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({required this.genre, required this.following, required this.onTap, required this.onLongPress});
  final String genre;
  final bool following;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: following,
      label: '${following ? 'Following' : 'Follow'} $genre',
      hint: 'Long press for a station',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 5, 9, 4),
          decoration: BoxDecoration(
            color: following ? scheme.onSurface : null,
            border: Border.all(color: scheme.onSurface, width: 1.1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(following ? Icons.check : Icons.add, size: 12, color: following ? scheme.surface : scheme.onSurface),
            const SizedBox(width: 5),
            Text(genre.toUpperCase(), style: Mag.flag(10.5, color: following ? scheme.surface : scheme.onSurface)),
          ]),
        ),
      ),
    );
  }
}

class _Comment extends StatelessWidget {
  const _Comment({required this.comment});
  final SongComment comment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: comment.avatar != null
                ? Artwork(url: comment.avatar, size: 44, radius: 3)
                : Container(
                    width: 44,
                    height: 44,
                    color: scheme.surfaceContainerHighest,
                    child: Icon(Icons.person_outline, color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.name, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(comment.text,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.quote(15, color: scheme.onSurface).copyWith(fontStyle: FontStyle.italic, height: 1.25)),
                if ((comment.favourite ?? '').isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text('Favourite track: ${comment.favourite}',
                      style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
