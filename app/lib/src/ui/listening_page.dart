import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'browse_page.dart';
import 'dialogs.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'snack.dart';
import 'skeleton.dart';
import 'theme.dart';
import 'record_refresh.dart';

/// The charts: what was actually listened to, ranked.
///
/// Every play has been written down since the first day, and the question people ask
/// of that is a chart question — what is at the top this week, what went up, what is
/// new. So it is set as a chart page: a number one with its sticker, positions in big
/// numerals, an arrow for what moved since the last chart, NEW for what was not on it,
/// and how many weeks each song has been charting.
///
/// Still about an account rather than the app, because four people share this box and
/// what Joe has worn out this month is a fair question.
class ListeningPage extends StatefulWidget {
  const ListeningPage({super.key});

  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  static const _periods = {
    'week': 'Weekly',
    'month': 'Monthly',
    'year': 'Yearly',
    'all': 'All time',
  };

  // Weekly by default: a chart is a weekly thing, and it is the one with movement.
  String _since = 'week';
  int? _who;
  Future<Listening>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // A block, not an arrow: `() => _future = …` hands the Future back to setState,
  // which refuses it.
  void _load() => setState(() {
        _future = context.read<AppState>().api.listening(since: _since, who: _who);
      });

  String _when() {
    final now = DateTime.now();
    return switch (_since) {
      'week' => 'Week ${issueNumber(now)}',
      'month' => 'The last 30 days',
      'year' => 'The last 12 months',
      _ => 'Since the first play',
    };
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(title: const Text('The charts')),
      body: FutureBuilder<Listening>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const SongsComing(rows: 6);
          final d = snap.data!;
          final scheme = Theme.of(context).colorScheme;
          final mine = d.whoId == 0 || d.people.length < 2;
          return RecordRefresh(
            onRefresh: () async => _load(),
            child: ListView(
              padding: EdgeInsets.fromLTRB(14, 4, 14, bottomForPlayer(context)),
              children: [
                // Which chart first: it changes everything under it.
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in _periods.entries)
                      _Tab(
                        label: e.value,
                        on: e.key == _since,
                        onTap: () {
                          feel(Feel.pick);
                          _since = e.key;
                          _load();
                        },
                      ),
                  ],
                ),
                if (d.people.length > 1) ...[
                  const SizedBox(height: 10),
                  // Whose chart. One account is the usual answer, so it is a row of
                  // names rather than a screen of its own.
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final p in d.people)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(p.name),
                              selected: p.id == d.whoId,
                              onSelected: (_) {
                                _who = p.id;
                                _load();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _Masthead(
                  when: _when(),
                  whose: mine ? null : d.whoName,
                ),
                if (d.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      _since == 'all'
                          ? 'Nothing played yet. The first play makes the first chart.'
                          : 'Nothing played in this stretch, so no chart to print.',
                      style: Mag.typewriter(13, color: scheme.onSurfaceVariant),
                    ),
                  )
                else ...[
                  _Totals(d: d),
                  if (d.started > d.plays)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${d.started - d.plays} more started and not finished',
                        style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (d.songs.isNotEmpty) _NumberOne(song: d.songs.first, since: _since),
                  for (var i = 1; i < d.songs.length; i++)
                    _ChartRow(song: d.songs[i], position: i + 1, since: _since),
                  if (d.artists.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const SectionFlag('Top artists'),
                    const SizedBox(height: 4),
                    for (var i = 0; i < d.artists.length; i++)
                      _Ranked(
                        position: i + 1,
                        title: d.artists[i].name,
                        count: d.artists[i].plays,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ArtistPage(
                              artist: ArtistSummary(name: d.artists[i].name, tracks: 0)),
                        )),
                      ),
                  ],
                  if (d.albums.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const SectionFlag('Top records'),
                    const SizedBox(height: 4),
                    for (var i = 0; i < d.albums.length; i++)
                      _Ranked(
                        position: i + 1,
                        title: d.albums[i].name,
                        subtitle: d.albums[i].subtitle,
                        count: d.albums[i].plays,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => AlbumPage(
                              album: AlbumSummary(
                                  name: d.albums[i].name,
                                  artist: d.albums[i].subtitle ?? '',
                                  tracks: 0)),
                        )),
                      ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One of the chart tabs: weekly, monthly, yearly, all time.
class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: on,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
          decoration: BoxDecoration(
            color: on ? scheme.onSurface : null,
            border: Border.all(color: scheme.onSurface, width: 1.5),
          ),
          child: Text(label.toUpperCase(),
              style: Mag.flag(10.5, color: on ? scheme.surface : scheme.onSurface)),
        ),
      ),
    );
  }
}

/// The head of the page: THE CHARTS, and which chart this is.
class _Masthead extends StatelessWidget {
  const _Masthead({required this.when, this.whose});

  final String when;
  final String? whose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.onSurface, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(text: whose == null ? 'THE ' : '${whose!.toUpperCase()}\'S '),
              TextSpan(text: 'CHARTS', style: TextStyle(color: scheme.primary)),
            ]),
            style: Mag.headline(56, color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(when.toUpperCase(),
                    style: Mag.typewriter(11, color: scheme.onSurface, bold: true)),
              ),
              Text('▲ UP  ▼ DOWN',
                  style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The week in three numbers.
class _Totals extends StatelessWidget {
  const _Totals({required this.d});

  final Listening d;

  static String _hours(int minutes) {
    if (minutes < 90) return '$minutes';
    final hours = minutes / 60;
    return hours < 10 ? hours.toStringAsFixed(1) : '${hours.round()}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget fact(String number, String what) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(number, style: Mag.numerals(30, color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(what.toUpperCase(),
                    style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant, bold: true)),
              ],
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.3))),
      ),
      child: Row(
        children: [
          fact('${d.plays}', d.plays == 1 ? 'play' : 'plays'),
          fact(_hours(d.minutes), d.minutes < 90 ? 'minutes' : 'hours'),
          fact('${d.tracks}', d.tracks == 1 ? 'song' : 'songs'),
        ],
      ),
    );
  }
}

/// How a song moved since the last chart.
({String text, bool isNew, int direction}) _movement(PlayedOften s, String since) {
  // No rank at all is a server from before charts moved: say nothing rather than
  // calling every song on it new.
  if (since == 'all' || s.rank == null) return (text: '', isNew: false, direction: 0);
  final now = s.rank!;
  final before = s.lastRank;
  if (before == null) return (text: 'NEW', isNew: true, direction: 0);
  if (before > now) return (text: '▲${before - now}', isNew: false, direction: 1);
  if (before < now) return (text: '▼${now - before}', isNew: false, direction: -1);
  return (text: '=', isNew: false, direction: 0);
}

/// "3 wks", "2 mths": how long a song has been charting.
String _run(PlayedOften s, String since) {
  final unit = switch (since) {
    'week' => s.charts == 1 ? 'wk' : 'wks',
    'month' => s.charts == 1 ? 'mth' : 'mths',
    'year' => s.charts == 1 ? 'yr' : 'yrs',
    _ => '',
  };
  return unit.isEmpty ? '' : '${s.charts} $unit';
}

Future<void> _play(BuildContext context, PlayedOften song) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  feel(Feel.commit);
  try {
    await app.playNow([await app.api.track(song.id)]);
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// The number one: cut out, pasted up, with its sticker.
class _NumberOne extends StatelessWidget {
  const _NumberOne({required this.song, required this.since});

  final PlayedOften song;
  final String since;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final move = _movement(song, since);
    final run = _run(song, since);
    return Semantics(
      button: true,
      label: 'Number one: ${song.title} by ${song.artistLine}, '
          '${song.plays} plays. Play it.',
      child: InkWell(
        onTap: () => _play(context, song),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.onSurface)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 50,
                child: Text('1',
                    textAlign: TextAlign.center,
                    style: Mag.numerals(52, color: scheme.onSurface)),
              ),
              const SizedBox(width: 6),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CutOut(
                    turn: -0.04,
                    child: CoverByPath(
                        id: song.id, title: song.title, coverPath: song.coverPath, size: 92),
                  ),
                  Positioned(
                    right: -18,
                    top: -16,
                    child: Starburst(
                      size: 48,
                      colour: MuseTheme.masthead,
                      points: 14,
                      turn: -0.2,
                      child: const StickerText('No.1', colour: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (move.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _Move(move: move),
                      ),
                    Text(song.title.toUpperCase(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.headline(26, color: scheme.onSurface)),
                    const SizedBox(height: 3),
                    Text(
                      [
                        song.artistLine,
                        '${song.plays} ${song.plays == 1 ? 'play' : 'plays'}',
                        if (run.isNotEmpty) run,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
                    ),
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

/// A place below number one.
class _ChartRow extends StatelessWidget {
  const _ChartRow({required this.song, required this.position, required this.since});

  final PlayedOften song;

  /// Where it is in the list, for a server that does not say.
  final int position;
  final String since;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final move = _movement(song, since);
    final run = _run(song, since);
    return InkWell(
      onTap: () => _play(context, song),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.18))),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: Text('${song.rank ?? position}',
                  textAlign: TextAlign.center,
                  style: Mag.numerals(24, color: scheme.onSurface)),
            ),
            SizedBox(width: 40, child: Center(child: _Move(move: move))),
            const SizedBox(width: 6),
            CoverByPath(id: song.id, title: song.title, coverPath: song.coverPath, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                  Text(song.artistLine,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${song.plays}×',
                    style: Mag.typewriter(12, color: scheme.onSurface, bold: true)),
                if (run.isNotEmpty)
                  Text(run, style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ▲3, ▼2, =, or NEW on a yellow slip.
class _Move extends StatelessWidget {
  const _Move({required this.move});

  final ({String text, bool isNew, int direction}) move;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (move.text.isEmpty) return const SizedBox.shrink();
    if (move.isNew) {
      return Container(
        padding: const EdgeInsets.fromLTRB(5, 2, 5, 1),
        color: MuseTheme.highlighter,
        child: Text('NEW', style: Mag.headline(12, color: MuseTheme.ink, width: 75)),
      );
    }
    final colour = switch (move.direction) {
      1 => scheme.onSurface,
      -1 => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    return Text(
      move.text,
      semanticsLabel: switch (move.direction) {
        1 => 'up ${move.text.substring(1)}',
        -1 => 'down ${move.text.substring(1)}',
        _ => 'no change',
      },
      style: Mag.typewriter(12, color: colour, bold: true),
    );
  }
}

/// A ranked artist or record: a numeral, a name, a count.
class _Ranked extends StatelessWidget {
  const _Ranked({
    required this.position,
    required this.title,
    required this.count,
    required this.onTap,
    this.subtitle,
  });

  final int position;
  final String title;
  final String? subtitle;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: Text('$position',
                  textAlign: TextAlign.center,
                  style: Mag.numerals(20, color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                  if (subtitle != null)
                    Text(subtitle!,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                ],
              ),
            ),
            Text('$count×', style: Mag.typewriter(12, color: scheme.onSurface, bold: true)),
          ],
        ),
      ),
    );
  }
}
