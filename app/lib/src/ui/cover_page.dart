import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/connection.dart';
import '../state/offline.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'feed_page.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'pane.dart';
import 'queue_page.dart' show openQueueScreen;
import 'mini_player.dart' show bottomForPlayer;
import 'skeleton.dart';
import 'song_row.dart';
import 'snack.dart';
import 'record_refresh.dart';

/// Home: this week's issue.
///
/// The app had listening stats, new releases from the artists you follow, what
/// everybody in the house is playing right now, and the queue you stopped in the
/// middle of — and all of it was two or three taps deep, behind tabs named after the
/// machinery. This puts it on a cover. The issue number is the week of the year, the
/// cover star is the record you have played most this week, and every cover line is
/// written from something that is actually true.
///
/// Each piece loads on its own, and a piece that has nothing to say is left out rather
/// than drawn empty: a new account's first issue is a masthead and whatever it has, not
/// a page of zeros.
class CoverPage extends StatefulWidget {
  const CoverPage({super.key});

  @override
  State<CoverPage> createState() => _CoverPageState();
}

class _Issue {
  Listening? week;
  int unseen = 0;
  int following = 0;
  List<Person> playing = const [];
  int you = 0;
  List<Track> added = const [];
}

class _CoverPageState extends State<CoverPage> {
  _Issue? _issue;
  DateTime? _printed;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    serverIsThere.addListener(_connectionChanged);
    unawaited(_print());
  }

  @override
  void dispose() {
    serverIsThere.removeListener(_connectionChanged);
    super.dispose();
  }

  /// The connection went or came back: the other edition, and when it is back, a
  /// fresh printing of the real one.
  void _connectionChanged() {
    if (!mounted) return;
    setState(() {});
    if (serverIsThere.value) unawaited(_print());
  }

  /// Everything on the cover, each part asked for separately so one that fails does
  /// not take the others with it.
  Future<void> _print() async {
    if (_printing) return;
    _printing = true;
    final api = context.read<AppState>().api;
    final issue = _Issue();
    // A part that fails is simply not printed this time.
    Future<void> quietly(Future<void> Function() part) async {
      try {
        await part();
      } catch (_) {}
    }

    await Future.wait([
      quietly(() async => issue.week = await api.listening(since: 'week')),
      quietly(() async {
        final f = await api.feed(limit: 1);
        issue.unseen = f.unseen;
        issue.following = f.following;
      }),
      quietly(() async {
        final p = await api.people();
        issue.you = p.you;
        issue.playing = [
          for (final person in p.people)
            if (person.id != p.you && (person.playing?.now ?? false)) person
        ];
      }),
      quietly(() async =>
          issue.added = (await api.libraryTracks(sort: 'added', limit: 10)).items),
    ]);
    _printing = false;
    if (!mounted) return;
    setState(() {
      _issue = issue;
      _printed = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    // A cover that has sat in a tab since the morning is yesterday's news. Coming back
    // to it after a while prints it again.
    final looking = context.select<AppState, bool>((a) => a.homeTab == Tabs.home);
    final stale = _printed != null &&
        DateTime.now().difference(_printed!) > const Duration(minutes: 5);
    if (looking && stale && !_printing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _print());
    }

    // No connection, on a device that keeps music: the offline edition, which is made
    // only of what is here.
    if (!serverIsThere.value && OfflineStore.supported) return const _OfflineEdition();

    final issue = _issue;
    final now = DateTime.now();
    final scheme = Theme.of(context).colorScheme;

    return RecordRefresh(
      onRefresh: _print,
      child: ListView(
        padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Masthead(
            trailing: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('FREE', style: Mag.typewriter(11, color: Colors.white, bold: true)),
                Text('No. ${issueNumber(now)}',
                    style: Mag.typewriter(11, color: Colors.white, bold: true)),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.onSurface)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
            child: Row(
              children: [
                Expanded(
                  child: Text('YOUR RECORDS THIS WEEK',
                      style: Mag.typewriter(11, color: scheme.onSurface, bold: true)),
                ),
                Text(coverDate(now).toUpperCase(),
                    style: Mag.typewriter(11, color: scheme.onSurface, bold: true)),
              ],
            ),
          ),
          if (issue == null)
            const SizedBox(height: 520, child: RecordsComing(tiles: 4, extent: 220))
          else ...[
            _CoverStar(issue: issue),
            _CoverLines(issue: issue),
            if ((issue.week?.songs.length ?? 0) > 1) _OnRepeat(songs: issue.week!.songs),
            if (issue.added.isNotEmpty) _JustIn(tracks: issue.added),
            _Folio(issue: issue, number: issueNumber(now)),
          ],
        ],
      ),
    );
  }
}

/// The record you played most this week, pasted big on the cover.
class _CoverStar extends StatelessWidget {
  const _CoverStar({required this.issue});

  final _Issue issue;

  @override
  Widget build(BuildContext context) {
    final top = issue.week?.songs.firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    if (top == null) {
      // A first issue, before anything has been played: say so on the cover rather
      // than leave a hole where the star goes.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Kicker('First issue'),
            const SizedBox(height: 4),
            Text('NOTHING PLAYED\nTHIS WEEK — YET',
                style: Mag.headline(40, color: scheme.onSurface)),
            const SizedBox(height: 6),
            Text('Play something and it will be on next week\'s cover.',
                style: Mag.typewriter(12, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.clamp(0.0, 560.0);
      final art = width * 0.62;
      return SizedBox(
        height: art + 70,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: width * 0.22,
              top: 20,
              child: Semantics(
                button: true,
                label: 'Play ${top.title}, your most played this week',
                child: GestureDetector(
                  onTap: () async {
                    feel(Feel.commit);
                    await app.playNow([await app.api.track(top.id)]);
                  },
                  child: CutOut(
                    turn: -0.05,
                    taped: true,
                    child: CoverByPath(
                        id: top.id, title: top.title, coverPath: top.coverPath, size: art),
                  ),
                ),
              ),
            ),
            if (issue.unseen > 0)
              Positioned(
                right: 12,
                top: 10,
                child: Starburst(
                  size: 76,
                  turn: 0.2,
                  child: StickerText('${issue.unseen}', small: 'new'),
                ),
              ),
            Positioned(
              left: 14,
              bottom: 0,
              right: width * 0.3,
              child: _PastedLine(
                kicker: 'Cover star',
                headline: top.title,
                line: '${top.artists.join(', ')} · ${top.plays} '
                    '${top.plays == 1 ? 'play' : 'plays'}',
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// A cover line pasted over the picture: each piece on its own slip of paper.
class _PastedLine extends StatelessWidget {
  const _PastedLine({required this.kicker, required this.headline, required this.line});

  final String kicker;
  final String headline;
  final String line;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget slip(Widget child, {bool shadow = false}) => Container(
          padding: const EdgeInsets.fromLTRB(6, 3, 6, 2),
          decoration: BoxDecoration(
            color: scheme.surface,
            boxShadow: shadow
                ? const [BoxShadow(color: Color(0xFFFFE14D), offset: Offset(3, 3))]
                : null,
          ),
          child: child,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        slip(Kicker(kicker)),
        slip(
          Text(headline.toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Mag.headline(38, color: scheme.onSurface)),
          shadow: true,
        ),
        slip(Text(line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Mag.typewriter(11.5, color: scheme.onSurface))),
      ],
    );
  }
}

/// The lines down the cover: the queue you left, the records that are new, and who
/// in the house is listening right now.
class _CoverLines extends StatelessWidget {
  const _CoverLines({required this.issue});

  final _Issue issue;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final player = app.player;
    final queue = app.activeQueue;
    final left = player == null || player.items.isEmpty
        ? 0
        : player.items.length - player.index - 1;
    final now = player?.current;

    final lines = <Widget>[
      if (queue != null && now != null)
        _Line(
          number: '$left',
          headline: left == 1 ? 'song left in ${queue.name}' : 'songs left in ${queue.name}',
          note: app.musicIsPlaying
              ? 'Playing now: ${now.displayTitle}'
              : 'Jump back in: ${now.displayTitle}',
          // Playing, the line is about what comes next, so it opens Up next;
          // stopped, it is an offer to carry on, so it plays.
          onTap: app.musicIsPlaying
              ? () => openQueueScreen(context)
              : () => app.playPause(),
        ),
      if (issue.unseen > 0)
        _Line(
          number: '${issue.unseen}',
          headline: issue.unseen == 1 ? 'new record' : 'new records',
          note: 'From the ${issue.following} artists you follow',
          onTap: () => openPage(context, (_) => const FeedPage()),
        ),
      for (final person in issue.playing.take(3))
        _Spotted(person: person),
    ];
    if (lines.isEmpty) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(
        children: [
          for (final line in lines)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                    top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.22))),
              ),
              child: line,
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.number, required this.headline, required this.note, this.onTap});

  final String number;
  final String headline;
  final String note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52,
              child: Text(number, style: Mag.numerals(30, color: scheme.primary)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(headline.toUpperCase(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.headline(22, color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Somebody in the house, caught listening.
class _Spotted extends StatelessWidget {
  const _Spotted({required this.person});

  final Person person;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playing = person.playing!;
    final app = context.read<AppState>();
    return InkWell(
      onTap: () => app.setHomeTab(Tabs.people),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainerHighest,
                border: Border.all(color: scheme.primary, width: 2),
              ),
              child: Text(person.name.isEmpty ? '?' : person.name[0].toUpperCase(),
                  style: Mag.headline(16, color: scheme.onSurface)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'Spotted: ${person.name}, playing '),
                  TextSpan(
                    text: playing.track.displayTitle,
                    style: const TextStyle(fontStyle: FontStyle.normal),
                  ),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Mag.quote(16, color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rest of this week's chart, under the cover star.
class _OnRepeat extends StatelessWidget {
  const _OnRepeat({required this.songs});

  final List<PlayedOften> songs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    final rest = songs.skip(1).take(5).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionFlag('On repeat'),
          const SizedBox(height: 6),
          for (var i = 0; i < rest.length; i++)
            InkWell(
              onTap: () async {
                feel(Feel.commit);
                await app.playNow([await app.api.track(rest[i].id)]);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text('${i + 2}',
                          style: Mag.numerals(22, color: scheme.onSurfaceVariant)),
                    ),
                    CoverByPath(
                        id: rest[i].id,
                        title: rest[i].title,
                        coverPath: rest[i].coverPath,
                        size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(rest[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall),
                          Text(rest[i].artists.join(', '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    Text('${rest[i].plays}×',
                        style: Mag.typewriter(12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// New in the library: a row of cut-outs.
class _JustIn extends StatelessWidget {
  const _JustIn({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: SectionFlag('Just in'),
          ),
          SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
              itemCount: tracks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, i) {
                final t = tracks[i];
                return Semantics(
                  button: true,
                  label: 'Play ${t.displayTitle} by ${t.artistLine}',
                  child: GestureDetector(
                    onTap: () {
                      feel(Feel.commit);
                      app.playNow(tracks, startAt: i, named: 'Just in');
                    },
                    child: SizedBox(
                      width: 104,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CutOut(
                            // Pasted a little differently each, as a hand does.
                            turn: (i.isEven ? -1 : 1) * (0.02 + (i % 3) * 0.012),
                            child: Artwork(track: t, size: 92, radius: 0, small: true),
                          ),
                          const SizedBox(height: 8),
                          Text(t.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The foot of the page: the folio, as a magazine prints one.
class _Folio extends StatelessWidget {
  const _Folio({required this.issue, required this.number});

  final _Issue issue;
  final int number;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final week = issue.week;
    final bits = [
      'WETOWL',
      'No. $number',
      if (week != null && week.plays > 0) '${week.plays} PLAYS THIS WEEK',
      if (week != null && week.minutes > 0) '${week.minutes} MIN',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 26, 14, 8),
      child: Container(
        padding: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.onSurface))),
        child: Text(bits.join('  ·  '),
            style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant, bold: true)),
      ),
    );
  }
}

/// The front page with no connection: what is kept on this device, and nothing that
/// would need the box.
///
/// The ordinary cover is written from the server — the week's plays, the new releases,
/// who is listening — and with no server every line of it fails. Rather than a cover
/// of blanks, this is an edition of its own: it says there is no signal, says how much
/// music is here anyway, and plays it.
class _OfflineEdition extends StatelessWidget {
  const _OfflineEdition();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final kept = app.offline.kept.toList()
      ..sort((a, b) => b.keptAt.compareTo(a.keptAt));
    final tracks = [for (final e in kept) e.asTrack];

    Future<void> play({int at = 0, bool shuffle = false}) async {
      final messenger = ScaffoldMessenger.of(context);
      feel(Feel.commit);
      try {
        await app.playNow(tracks, startAt: at, shuffle: shuffle, named: 'On this device');
      } catch (e) {
        messenger.say(problem(e));
      }
    }

    return ListView(
      padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
      children: [
        Masthead(
          trailing: Text('OFFLINE\nEDITION',
              textAlign: TextAlign.end,
              style: Mag.typewriter(11, color: Colors.white, bold: true)),
        ),
        Container(
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: scheme.onSurface))),
          padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
          child: Row(
            children: [
              Expanded(
                child: Text('PRINTED ON THIS DEVICE',
                    style: Mag.typewriter(11, color: scheme.onSurface, bold: true)),
              ),
              Text(coverDate(DateTime.now()).toUpperCase(),
                  style: Mag.typewriter(11, color: scheme.onSurface, bold: true)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Kicker('No signal'),
              const SizedBox(height: 4),
              Text(
                kept.isEmpty
                    ? 'NOTHING IS KEPT\nON THIS DEVICE'
                    : '${kept.length} ${kept.length == 1 ? 'SONG' : 'SONGS'} STILL PLAY',
                style: Mag.headline(40, color: scheme.onSurface),
              ),
              const SizedBox(height: 6),
              Text(
                kept.isEmpty
                    ? 'Keep songs on this device, from any song, record or playlist, and '
                        'they play here with no connection at all.'
                    : 'The server cannot be reached. These are kept on this device and '
                        'need nothing else. Everything comes back when the connection does.',
                style: Mag.typewriter(12, color: scheme.onSurfaceVariant),
              ),
              if (kept.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PressButton(label: 'Play all', loud: true, onTap: play),
                    PressButton(label: 'Shuffle', onTap: () => play(shuffle: true)),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (kept.isNotEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 16, 14, 4),
            child: SectionFlag('On this device'),
          ),
        for (var i = 0; i < tracks.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SongRow(
              track: tracks[i],
              // Nothing in a song's menu works without the server.
              showMenu: false,
              swipeToPlayNext: false,
              onTap: () => play(at: i),
            ),
          ),
      ],
    );
  }
}
