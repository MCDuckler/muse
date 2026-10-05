import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'browse_page.dart' show AlbumPage, ArtistPage;
import 'dialogs.dart';
import 'feed_page.dart';
import 'feed_screen.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'pane.dart';
import 'record_refresh.dart';
import 'services_page.dart';
import 'skeleton.dart';
import 'sleeve_art.dart';
import 'snack.dart';
import 'song_row.dart';
import 'library_page.dart' show PlaylistPage;
import 'station.dart';
import 'track_list.dart';

/// Discover: something to put on before you know what you want.
///
/// Four departments on one page, each with its own well. The lists made for you —
/// this week's finds, the daily mixes, the release radar, on repeat, the time capsule,
/// the house blend, the sleep mix — are built overnight on the server and kept, so the
/// list in the evening is the list from the morning. At night the sleep mix is first. Stations: the ones you made before, and the
/// acts and genres to start one from. New releases, by the artists *and the genres*
/// you follow. And acts to try, which is the one thing the house's own data can never
/// say and the world's listening can.
///
/// Each department draws what it has and is left out when it has nothing, as the
/// cover does. The first time, the lists take a minute or two to make; the page says
/// so and re-reads when the server says they are done.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  Discover? _page;
  Object? _error;
  DateTime? _read;
  bool _reading = false;
  int _built = 0;
  Timer? _again;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _again?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_reading) return;
    _reading = true;
    _again?.cancel();
    final api = context.read<AppState>().api;
    try {
      final page = await api.discover();
      if (!mounted) return;
      setState(() {
        _page = page;
        _error = null;
        _read = DateTime.now();
      });
      // Being made: look again in a little while, in case the word that they are
      // done does not reach us (the events stream drops out on a bad connection).
      if (page.building) {
        _again = Timer(const Duration(seconds: 12), () {
          if (mounted) unawaited(_load());
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The server said the lists were made: read the page again, once per word.
    final built = context.select<AppState, int>((a) => a.discoverBuilt);
    if (built != _built) {
      _built = built;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    // Back after a while: this morning's page is this morning's. Re-read quietly.
    final looking = context.select<AppState, bool>((a) => a.homeTab == Tabs.discover);
    final stale = _read != null && DateTime.now().difference(_read!) > const Duration(minutes: 10);
    if (looking && stale && !_reading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    final page = _page;
    if (page == null && _error != null) {
      return ErrorRetry(error: _error!, onRetry: _load);
    }
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();

    return RecordRefresh(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Kicker('Discover'),
                      Text('SOMETHING NEW ON',
                          style: Mag.headline(34, color: scheme.onSurface).copyWith(height: 0.95)),
                    ],
                  ),
                ),
                Text(coverDate(now).toUpperCase(),
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: ThickAndThin(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              PressButton(
                  label: 'Open the feed',
                  loud: true,
                  onTap: () {
                    feel(Feel.commit);
                    openPage(context, (_) => const FeedScreen());
                  }),
              const SizedBox(width: 12),
              Expanded(
                child: Text('One song at a time, big — or tap Discover twice.',
                    style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
              ),
            ]),
          ),
          if (page == null)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: SizedBox(height: 240, child: RecordsComing(tiles: 3, extent: 200)),
            )
          else ...[
            _MadeForYou(page: page, onChanged: _load),
            _Stations(page: page, onChanged: _load),
            _Releases(page: page, onChanged: _load),
            if (page.artists.isNotEmpty) _ArtistsToTry(artists: page.artists),
            _Folio(page: page),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- made for you

/// What time the shelf thinks it is. A test sets it: the order depends on the hour,
/// and a test that only passes at night fails every build made in the day.
@visibleForTesting
DateTime Function() shelfClock = DateTime.now;

/// The lists in the order the shelf shows them: from eight in the evening to five in
/// the morning the sleep mix comes first.
List<MadeList> bedtimeOrder(List<MadeList> lists, DateTime now) {
  if (now.hour >= 5 && now.hour < 20) return lists;
  return [for (final l in lists) if (l.isSleep) l, for (final l in lists) if (!l.isSleep) l];
}

/// Play the sleep mix and set the sleep timer to its length, so it fades out where it
/// ends — whatever the queue would have done after.
Future<void> lightsOut(BuildContext context, MadeList list) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  feel(Feel.commit);
  await app.playNow(list.tracks, named: list.name);
  final length = list.length;
  if (length > Duration.zero) {
    app.setSleepTimer(length);
    messenger.say(snack(Text('Lights out — it fades out in ${length.inMinutes} min')));
  }
}

class _MadeForYou extends StatelessWidget {
  const _MadeForYou({required this.page, required this.onChanged});
  final Discover page;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lists = bedtimeOrder(page.lists, shelfClock());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 22, 16, 4),
          child: SectionFlag('Made for you'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            page.lists.isEmpty
                ? page.building
                    ? 'Being made out of what you play — a minute or two, the first time.'
                    : 'Play a few songs and come back: the lists are made out of what you play.'
                : 'Made overnight out of what you play. Kept as they are until tomorrow.',
            style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
          ),
        ),
        if (page.lists.isEmpty && page.building)
          const SizedBox(height: 200, child: RecordsComing(tiles: 3, extent: 180))
        else if (page.lists.isNotEmpty)
          SizedBox(
            height: 236,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              itemCount: lists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, i) => _ListCard(list: lists[i], onChanged: onChanged),
            ),
          ),
      ],
    );
  }
}

/// A made list as a card: four of its covers under a name band, the count, a play.
class _ListCard extends StatelessWidget {
  const _ListCard({required this.list, required this.onChanged});
  final MadeList list;
  final Future<void> Function() onChanged;

  static const _side = 148.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    final covers = list.tracks.take(4).toList();
    return Semantics(
      button: true,
      label: '${list.name}, ${list.count} songs. ${list.blurb}',
      child: InkWell(
        onTap: () {
          feel(Feel.pick);
          openPage(context, (_) => MadeListPage(slug: list.slug, first: list));
        },
        child: SizedBox(
          width: _side,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: _side,
                height: _side,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  border: Border.all(color: scheme.onSurface, width: 1.2),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (covers.isEmpty)
                      PrintedSleeve(seed: PrintedSleeve.seedOf(list.slug), title: list.name, size: _side)
                    else
                      GridView.count(
                        crossAxisCount: 2,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        children: [
                          for (final t in covers) Artwork(track: t, size: _side / 2, radius: 0),
                          for (var n = covers.length; n < 4; n++)
                            ColoredBox(color: scheme.surfaceContainerHighest),
                        ],
                      ),
                    // The sleep mix's wind-down along the foot of it: how much each
                    // song drives, from the first to the stillest.
                    if (list.isSleep && list.energy.length > 1)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 30,
                          color: scheme.surface.withValues(alpha: 0.92),
                          padding: const EdgeInsets.fromLTRB(6, 5, 48, 5),
                          child: Row(children: [
                            Icon(Icons.bedtime_outlined, size: 14, color: scheme.onSurface),
                            const SizedBox(width: 6),
                            Expanded(
                              child: CustomPaint(
                                  painter: WindDown(list.energy, color: scheme.onSurface),
                                  size: Size.infinite),
                            ),
                          ]),
                        ),
                      ),
                    // The band with the name on it: ink across the picture, the way a
                    // cover line goes over the photograph.
                    Positioned(
                      left: 0,
                      right: 22,
                      top: 10,
                      child: Container(
                        color: _bandColour(scheme),
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 3),
                        child: Text(list.name.toUpperCase(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.headline(15, color: scheme.surface).copyWith(height: 1.0)),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Material(
                        color: scheme.primary,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Play ${list.name}',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.play_arrow, color: scheme.onPrimary),
                          onPressed: list.tracks.isEmpty
                              ? null
                              : () {
                                  feel(Feel.commit);
                                  unawaited(app.playNow(list.tracks, named: list.name));
                                },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(list.blurb,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                  '${list.count} songs'
                  '${list.isSleep && list.minutes != null ? ' · ${list.minutes} min' : ''}'
                  '${_when(list.builtAt)}',
                  style: Mag.typewriter(10, color: scheme.onSurfaceVariant.withValues(alpha: 0.8))),
            ],
          ),
        ),
      ),
    );
  }

  /// The weekly list is the red one; the rest are ink.
  Color _bandColour(ColorScheme scheme) =>
      list.kind == 'weekly' ? scheme.primary : scheme.onSurface;

  static String _when(DateTime? at) {
    if (at == null) return '';
    final days = DateTime.now().difference(at.toLocal()).inDays;
    if (days <= 0) return ' · today';
    if (days == 1) return ' · yesterday';
    return ' · $days days ago';
  }
}

/// One made list, whole: play it, keep it as a playlist, have it made again.
class MadeListPage extends StatefulWidget {
  const MadeListPage({super.key, required this.slug, this.first});
  final String slug;

  /// What the Discover page already had, so the list is on screen at once.
  final MadeList? first;

  @override
  State<MadeListPage> createState() => _MadeListPageState();
}

class _MadeListPageState extends State<MadeListPage> {
  late Future<MadeList> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = widget.first != null
        ? Future.value(widget.first)
        : context.read<AppState>().api.madeList(widget.slug);
  }

  void _reload() => setState(() {
        _future = context.read<AppState>().api.madeList(widget.slug);
      });

  Future<void> _keep() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await app.api.keepMadeList(widget.slug);
      await app.refreshPlaylists();
      messenger.say(snack(const Text('Kept — it is in your library as a playlist')));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _again() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    messenger.say(snack(const Text('Making it again…')));
    try {
      await app.api.rebuildMadeLists(force: widget.slug == 'weekly');
      _reload();
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlayerScaffold(
      appBar: AppBar(
        title: Text(widget.first?.name ?? 'Made for you'),
        actions: [
          IconButton(
            tooltip: 'Keep as a playlist',
            icon: const Icon(Icons.playlist_add),
            onPressed: _busy ? null : _keep,
          ),
          IconButton(
            tooltip: 'Make it again',
            icon: const Icon(Icons.autorenew),
            onPressed: _busy ? null : _again,
          ),
        ],
      ),
      body: FutureBuilder<MadeList>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _reload);
          if (!snap.hasData) return const SongsComing();
          final list = snap.data!;
          if (list.tracks.isEmpty) {
            return EmptyHint(
              icon: Icons.auto_awesome_outlined,
              title: 'Nothing in it just now',
              body: list.blurb,
            );
          }
          context.read<AppState>().keepCoversFor(list.tracks);
          // A list that can say why each song is there says it under the song; the
          // others are a plain list with the usual head.
          if (list.why.isEmpty) {
            return RecordRefresh(
              onRefresh: () async => _reload(),
              child: TrackList(
                tracks: list.tracks,
                header: '${list.tracks.length} songs · ${list.blurb}',
                named: list.name,
                selectable: 'made:${list.slug}',
              ),
            );
          }
          final app = context.read<AppState>();
          return RecordRefresh(
            onRefresh: () async => _reload(),
            child: ListView.builder(
              padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
              itemCount: list.tracks.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(list.blurb, style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                        if (list.isSleep && list.energy.length > 1) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 34,
                            child: CustomPaint(
                                painter: WindDown(list.energy, color: scheme.onSurface),
                                size: Size.infinite),
                          ),
                        ],
                        const SizedBox(height: 10),
                        // A sleep mix is laid out to wind down: played in its order, and
                        // to the end with the timer set, never shuffled.
                        Wrap(spacing: 10, runSpacing: 8, children: [
                          if (list.isSleep) ...[
                            PressButton(
                                label: 'Lights out', loud: true, onTap: () => lightsOut(context, list)),
                            PressButton(
                                label: 'Just play',
                                onTap: () => app.playNow(list.tracks, named: list.name)),
                          ] else ...[
                            PressButton(
                                label: 'Play all',
                                loud: true,
                                onTap: () => app.playNow(list.tracks, named: list.name)),
                            PressButton(
                                label: 'Shuffle',
                                onTap: () => app.playNow(list.tracks, shuffle: true, named: list.name)),
                          ],
                        ]),
                      ],
                    ),
                  );
                }
                final t = list.tracks[i - 1];
                final why = list.whyFor(t);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SongRow(
                      track: t,
                      selectable: 'made:${list.slug}',
                      onTap: () => app.playNow(list.tracks, startAt: i - 1, named: list.name),
                    ),
                    if (why.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(66, 0, 12, 6),
                        child: Text(why,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.typewriter(10, color: scheme.onSurfaceVariant.withValues(alpha: 0.8))),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// A list's energy, song by song, as one line falling to the right: the sleep mix's
/// shape. Scaled to its own most driving song, so the line fills the height it has.
class WindDown extends CustomPainter {
  WindDown(this.energy, {required this.color});
  final List<double> energy;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (energy.length < 2 || size.isEmpty) return;
    final top = math.max(0.05, energy.reduce(math.max));
    final line = Path();
    for (var i = 0; i < energy.length; i++) {
      final x = size.width * i / (energy.length - 1);
      final y = size.height * (1 - (energy[i] / top).clamp(0.0, 1.0)) * 0.85 + size.height * 0.075;
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(WindDown old) => old.color != color || old.energy != energy;
}

// ---------------------------------------------------------------- stations

class _Stations extends StatelessWidget {
  const _Stations({required this.page, required this.onChanged});
  final Discover page;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    final nothing = page.stations.isEmpty && page.startArtists.isEmpty && page.startGenres.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 26, 16, 4),
          child: SectionFlag('Stations'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            nothing
                ? 'A station is a playlist the machine writes and keeps writing. Start one '
                    'from any song\'s menu, a record or an artist — the ones you make come back here.'
                : 'Point at an act or a genre and it writes a list of what belongs next to it.',
            style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
          ),
        ),
        if (page.stations.isNotEmpty)
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              itemCount: page.stations.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) => _StationCard(
                station: page.stations[i],
                onTap: () {
                  feel(Feel.commit);
                  final s = page.stations[i];
                  // A station is a playlist: its page, to look through and put on
                  // from anywhere. One of the old shape (a queue) is still opened.
                  if (s.playlistId != null) {
                    unawaited(openPage(context,
                        (_) => PlaylistPage(playlistId: s.playlistId!, name: s.name)));
                  } else {
                    unawaited(app.openQueue(s.queueId));
                  }
                },
              ),
            ),
          ),
        if (page.startArtists.isNotEmpty || page.startGenres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Kicker(page.stations.isEmpty ? 'Start one from' : 'Or start one from'),
          ),
        if (page.startArtists.isNotEmpty)
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              itemCount: page.startArtists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, i) => _ArtistStart(artist: page.startArtists[i]),
            ),
          ),
        if (page.startGenres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in page.startGenres)
                  _GenreStart(genre: g, onTap: () => startStation(context, genre: g.genre)),
                _MoreGenres(onChanged: onChanged),
              ],
            ),
          ),
      ],
    );
  }
}

class _StationCard extends StatelessWidget {
  const _StationCard({required this.station, required this.onTap});
  final YourStation station;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (station.kind) {
      'artist' => Icons.person_outline,
      'album' => Icons.album_outlined,
      'genre' => Icons.tag,
      _ => Icons.music_note_outlined,
    };
    return Semantics(
      button: true,
      label: '${station.name}, ${station.count} songs',
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.55)),
          ),
          child: Row(
            children: [
              if (station.coverTrack != null)
                CoverByPath(
                    id: station.coverTrack!,
                    title: station.name,
                    coverPath: '/tracks/${station.coverTrack}/cover',
                    size: 56)
              else
                SizedBox.square(
                    dimension: 56,
                    child: Center(child: Icon(Icons.radio, color: scheme.primary, size: 30))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(station.name.toUpperCase(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.headline(14, color: scheme.onSurface).copyWith(height: 1.0)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Icon(icon, size: 12, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text('${station.count} songs',
                          style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistStart extends StatelessWidget {
  const _ArtistStart({required this.artist});
  final StationArtist artist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Start a station from ${artist.name}',
      child: InkWell(
        onTap: () => startStation(context, artist: artist.name),
        onLongPress: () => openPage(
            context, (_) => ArtistPage(artist: ArtistSummary(name: artist.name, tracks: 0))),
        child: SizedBox(
          width: 84,
          child: Column(
            children: [
              ClipOval(
                child: artist.coverTrack != null
                    ? CoverByPath(
                        id: artist.coverTrack!,
                        title: artist.name,
                        coverPath: '/tracks/${artist.coverTrack}/cover',
                        size: 68)
                    : PrintedSleeve(seed: PrintedSleeve.seedOf(artist.name), title: artist.name, size: 68),
              ),
              const SizedBox(height: 6),
              Text(artist.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: Mag.typewriter(10, color: scheme.onSurface, bold: true)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GenreStart extends StatelessWidget {
  const _GenreStart({required this.genre, required this.onTap});
  final GenreChip genre;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: genre.following ? 'A station of ${genre.genre}' : '${genre.genre} — you play a lot of it',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
          decoration: BoxDecoration(
            color: genre.following ? scheme.onSurface : null,
            border: Border.all(color: scheme.onSurface, width: 1.2),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.radio, size: 13, color: genre.following ? scheme.surface : scheme.onSurface),
            const SizedBox(width: 6),
            Text(genre.genre.toUpperCase(),
                style: Mag.flag(11, color: genre.following ? scheme.surface : scheme.onSurface)),
          ]),
        ),
      ),
    );
  }
}

class _MoreGenres extends StatelessWidget {
  const _MoreGenres({required this.onChanged});
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () async {
        await openPage(context, (_) => const GenresPage());
        await onChanged();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.4), width: 1.2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('GENRES', style: Mag.flag(11, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- new releases

class _Releases extends StatelessWidget {
  const _Releases({required this.page, required this.onChanged});
  final Discover page;
  final Future<void> Function() onChanged;

  static const _shown = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final following = [
      if (page.following > 0) '${page.following} artist${page.following == 1 ? '' : 's'}',
      if (page.genresFollowed > 0) '${page.genresFollowed} genre${page.genresFollowed == 1 ? '' : 's'}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 26, 16, 4),
          child: Row(children: [
            const Expanded(child: SectionFlag('New releases')),
            if (page.unseen > 0) ...[
              const SizedBox(width: 10),
              Starburst(
                size: 44,
                child: StickerText('${page.unseen}', small: 'new'),
              ),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              Text(
                following.isEmpty
                    ? 'Follow an artist or a genre and what they put out lands here.'
                    : 'Following ${following.join(' and ')}.',
                style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
              ),
              TextButton(
                onPressed: () async {
                  await openPage(context, (_) => const FollowingPage());
                  await onChanged();
                },
                child: const Text('Artists'),
              ),
              TextButton(
                onPressed: () async {
                  await openPage(context, (_) => const GenresPage());
                  await onChanged();
                },
                child: const Text('Genres'),
              ),
              // Importing lives with the linked accounts it reads, in Connected
              // services; this is the way there from where the follows are used.
              TextButton.icon(
                onPressed: () async {
                  await openPage(context, (_) => const ServicesPage());
                  await onChanged();
                },
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Import follows'),
              ),
            ],
          ),
        ),
        for (final r in page.releases.take(_shown)) _ReleaseRow(release: r, onOpened: onChanged),
        if (page.releases.length > _shown)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PressButton(
                label: 'All ${page.releases.length} releases',
                onTap: () async {
                  await openPage(context, (_) => const FeedPage());
                  await onChanged();
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({required this.release, required this.onOpened});
  final Release release;
  final Future<void> Function() onOpened;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = release;
    final subtitle = [
      r.artist,
      if (r.via != null) 'on ${r.via}',
      if (r.releaseDate != null) r.releaseDate!,
      if (r.recordType != null) r.recordType!,
    ].join(' · ');
    return ListTile(
      leading: Stack(
        children: [
          r.cover != null
              ? Artwork(url: r.cover, size: 48, radius: 0)
              : PrintedSleeve(seed: PrintedSleeve.seedOf('${r.artist}·${r.title}'), title: r.title, size: 48),
          if (r.unseen)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: r.genre != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: scheme.onSurface.withValues(alpha: 0.5))),
              child: Text(r.genre!.toUpperCase(), style: Mag.flag(9, color: scheme.onSurfaceVariant)),
            )
          : r.inLibrary
              ? Icon(Icons.check, size: 18, color: scheme.outline)
              : null,
      onTap: () async {
        final app = context.read<AppState>();
        final messenger = ScaffoldMessenger.of(context);
        unawaited(app.api.markReleasesSeen([r]).catchError((_) {}));
        if (r.opens && r.provider == 'bandcamp') {
          await openPage(context, (_) => BandcampRecordPage(url: r.albumId!, title: r.title));
        } else if (r.opens) {
          await openPage(context, (_) => AlbumPage(remoteId: r.albumId, title: r.title));
        } else {
          // Known only to the music database so far: the record page needs a Deezer
          // id, which the overnight pass looks up. Until then the artist is the way in.
          messenger.say(snack(Text('${r.title} — not looked up yet; opening ${r.artist}')));
          await openPage(context, (_) => ArtistPage(artist: ArtistSummary(name: r.artist, tracks: 0)));
        }
        await onOpened();
      },
    );
  }
}

// ---------------------------------------------------------------- artists to try

class _ArtistsToTry extends StatelessWidget {
  const _ArtistsToTry({required this.artists});
  final List<ArtistToTry> artists;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 26, 16, 4),
          child: SectionFlag('Acts to try'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Nobody here has played them. People who play what you play do.',
              style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
        ),
        SizedBox(
          height: 172,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            itemCount: artists.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final a = artists[i];
              return Semantics(
                button: true,
                label: '${a.name}. ${a.because}',
                child: InkWell(
                  onTap: () {
                    feel(Feel.pick);
                    openPage(context, (_) => ArtistPage(artist: ArtistSummary(name: a.name, tracks: 0)));
                  },
                  child: SizedBox(
                    width: 112,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CutOut(
                          turn: (i.isEven ? 1 : -1) * 0.025,
                          child: PrintedSleeve(seed: PrintedSleeve.seedOf(a.name), title: a.name, size: 92),
                        ),
                        const SizedBox(height: 8),
                        Text(a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge),
                        Text(a.because,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.typewriter(9.5, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Folio extends StatelessWidget {
  const _Folio({required this.page});
  final Discover page;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final songs = page.lists.fold<int>(0, (n, l) => n + l.count);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
      child: Column(children: [
        Container(height: 1, color: scheme.onSurface.withValues(alpha: 0.3)),
        const SizedBox(height: 6),
        Text(
          [
            'WETOWL · DISCOVER',
            if (songs > 0) '$songs SONGS MADE FOR YOU',
            if (page.stations.isNotEmpty) '${page.stations.length} STATIONS',
          ].join(' · '),
          style: Mag.typewriter(9.5, color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- genres

/// The genres you follow, the ones you seem to play, and the register to pick from.
class GenresPage extends StatefulWidget {
  const GenresPage({super.key});

  @override
  State<GenresPage> createState() => _GenresPageState();
}

class _GenresPageState extends State<GenresPage> {
  final _field = TextEditingController();
  Timer? _debounce;
  List<String> _following = const [];
  List<GenreChip> _suggested = const [];
  List<String> _found = const [];
  Object? _error;
  bool _loading = true;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final got = await api.genres(q: _field.text.trim());
      if (!mounted) return;
      setState(() {
        _following = got.following;
        if (_field.text.trim().isEmpty) _suggested = got.suggested;
        _found = got.found;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _typed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  Future<void> _toggle(String genre) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final was = _following.contains(genre);
    setState(() {
      _busy.add(genre);
      _following = was ? [for (final g in _following) if (g != genre) g] : [..._following, genre]..sort();
    });
    try {
      if (was) {
        await api.unfollowGenre(genre);
      } else {
        await api.followGenre(genre);
        messenger.say(snack(Text('Following $genre — new records in it show up in Discover')));
      }
    } catch (e) {
      messenger.say(problem(e));
      await _load();
    } finally {
      if (mounted) setState(() => _busy.remove(genre));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typing = _field.text.trim().isNotEmpty;
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Genres')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomForPlayer(context)),
        children: [
          TextField(
            controller: _field,
            onChanged: _typed,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Find a genre — techno, shoegaze, bossa nova…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: typing
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _field.clear();
                        _load();
                      })
                  : null,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            ErrorRetry(error: _error!, onRetry: _load),
          ] else if (_loading) ...[
            const SizedBox(height: 16),
            const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          ] else ...[
            if (!typing) ...[
              const SizedBox(height: 18),
              const SectionFlag('Following'),
              const SizedBox(height: 8),
              if (_following.isEmpty)
                Text('Nothing yet. A followed genre puts its new records in Discover and gives '
                    'you a station to start.',
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant))
              else
                _chips(_following, on: true),
              if (_suggested.isNotEmpty) ...[
                const SizedBox(height: 22),
                const SectionFlag('You seem to play'),
                const SizedBox(height: 4),
                Text('From the acts you play most, as the music database files them.',
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final g in _suggested)
                    Tooltip(message: g.why, child: _chip(g.genre, on: _following.contains(g.genre))),
                ]),
              ],
            ],
            const SizedBox(height: 22),
            SectionFlag(typing ? 'Found' : 'Common ones'),
            const SizedBox(height: 8),
            if (_found.isEmpty)
              Text('Nothing by that name.', style: Mag.typewriter(11, color: scheme.onSurfaceVariant))
            else
              _chips(_found, on: null),
          ],
        ],
      ),
    );
  }

  Widget _chips(List<String> names, {required bool? on}) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final g in names) _chip(g, on: on ?? _following.contains(g))],
      );

  Widget _chip(String genre, {required bool on}) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _busy.contains(genre);
    return Semantics(
      button: true,
      selected: on,
      label: '${on ? 'Following' : 'Follow'} $genre',
      child: InkWell(
        onTap: busy ? null : () => _toggle(genre),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
          decoration: BoxDecoration(
            color: on ? scheme.onSurface : null,
            border: Border.all(color: scheme.onSurface, width: 1.2),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.check : Icons.add, size: 13, color: on ? scheme.surface : scheme.onSurface),
            const SizedBox(width: 6),
            Text(genre.toUpperCase(), style: Mag.flag(11, color: on ? scheme.surface : scheme.onSurface)),
          ]),
        ),
      ),
    );
  }
}
