import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'browse_page.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'snack.dart';

/// What was actually listened to, and how much of it.
///
/// Every play has been written down since the first day, one row per listen, and the
/// only things ever read back out were "recently played" and one lifetime number. The
/// question people actually ask is smaller and harder: what have I been playing *this
/// month* — so the stretch of time is the first control on the screen.
///
/// And it asks about an account rather than about the app, because this box has four
/// of them sharing one catalog: what Joe has worn out this year is a fair question and
/// the People screen already answers a cruder version of it.
class ListeningPage extends StatefulWidget {
  const ListeningPage({super.key});

  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  static const _periods = {
    'week': 'Week',
    'month': 'Month',
    'year': 'Year',
    'all': 'All time',
  };

  String _since = 'month';
  int? _who;
  Future<Listening>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() => _future =
      context.read<AppState>().api.listening(since: _since, who: _who));

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Listening')),
      body: FutureBuilder<Listening>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final d = snap.data!;
          final text = Theme.of(context).textTheme;
          return RefreshIndicator(
            onRefresh: () async => _load(),
            child: ListView(
              padding: EdgeInsets.fromLTRB(12, 8, 12, bottomForPlayer(context)),
              children: [
                // The stretch of time first: it changes every number under it.
                SegmentedButton<String>(
                  segments: [
                    for (final e in _periods.entries)
                      ButtonSegment(value: e.key, label: Text(e.value)),
                  ],
                  selected: {_since},
                  showSelectedIcon: false,
                  onSelectionChanged: (picked) {
                    _since = picked.first;
                    _load();
                  },
                ),
                if (d.people.length > 1) ...[
                  const SizedBox(height: 10),
                  // Whose listening this is. One account is the usual answer, so it is
                  // a row of names rather than a screen of its own.
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
                if (d.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text(
                        'Nothing played ${_periods[_since]!.toLowerCase() == 'all time' ? 'yet' : 'in that ${_periods[_since]!.toLowerCase()}'}.',
                        style: text.bodyMedium,
                      ),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      _Total(number: '${d.plays}', what: 'plays'),
                      _Total(number: _hours(d.minutes), what: 'listened'),
                      _Total(number: '${d.tracks}', what: 'songs'),
                    ],
                  ),
                  if (d.started > d.plays)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(
                        '${d.started - d.plays} more started and not finished',
                        style: text.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 18),
                  _Heading('Songs'),
                  for (final song in d.songs) _SongRow(song: song),
                  if (d.artists.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _Heading('Artists'),
                    for (final a in d.artists)
                      ListTile(
                        dense: true,
                        title: Text(a.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text(_plays(a.plays),
                            style: text.labelMedium),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ArtistPage(
                              artist: ArtistSummary(name: a.name, tracks: 0)),
                        )),
                      ),
                  ],
                  if (d.albums.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _Heading('Records'),
                    for (final a in d.albums)
                      ListTile(
                        dense: true,
                        title: Text(a.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: a.subtitle == null ? null : Text(a.subtitle!),
                        trailing: Text(_plays(a.plays), style: text.labelMedium),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => AlbumPage(
                              album: AlbumSummary(
                                  name: a.name,
                                  artist: a.subtitle ?? '',
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

  static String _plays(int n) => n == 1 ? '1 play' : '$n plays';

  /// Minutes are the wrong unit for anything longer than an afternoon.
  static String _hours(int minutes) {
    if (minutes < 90) return '$minutes min';
    final hours = minutes / 60;
    return hours < 10
        ? '${hours.toStringAsFixed(1)} h'
        : '${hours.round()} h';
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.number, required this.what});
  final String number;
  final String what;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Card(
        margin: const EdgeInsets.only(right: 8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(number, style: text.headlineSmall),
              Text(what, style: text.bodySmall),
            ],
          ),
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
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// A song with its count. Not a SongRow: that one is about playing the song, and this
/// list is about how often it was played — the number is the point of the row.
class _SongRow extends StatelessWidget {
  const _SongRow({required this.song});
  final PlayedOften song;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final text = Theme.of(context).textTheme;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      leading: Artwork(
        url: app.api.coverUrlForPath(song.coverPath),
        size: 40,
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${song.plays}', style: text.titleSmall),
          Text(song.plays == 1 ? 'play' : 'plays', style: text.bodySmall),
        ],
      ),
      // Tapping one plays it: this is a list of songs somebody likes enough to have
      // played twenty times, which makes it a good list to play from.
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await app.playNow([await app.api.track(song.id)]);
        } catch (e) {
          messenger.say(problem(e));
        }
      },
    );
  }
}
