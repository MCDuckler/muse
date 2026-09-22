import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'browse_page.dart' show AlbumPage, ArtistPage;
import 'dialogs.dart';
import 'widths.dart';
import 'feel.dart';
import 'snack.dart';
import 'song_row.dart';
import 'station.dart';

/// Which service a row came from, as a colour.
///
/// A dot rather than a heading: the list is ranked by how well each row answers the
/// question, so grouping it by service would be sorting it by the one thing nobody
/// asked about. The colours are the services' own, near enough to be recognised and
/// dull enough to sit in a list all day.
const Map<String, Color> placeColours = {
  // The library's own dot is ink, set at build time: it was a green a shade off
  // Spotify's, and a note beside "the green dot" could have been either.
  'ytmusic': Color(0xFFE05C4B),
  'youtube': Color(0xFFB3261E),
  'spotify': Color(0xFF4BB463),
  'soundcloud': Color(0xFFE8833A),
  'bandcamp': Color(0xFF4A9DB5),
};

const Map<String, String> placeNames = {
  'library': 'In your library',
  'ytmusic': 'YouTube Music',
  'youtube': 'YouTube',
  'spotify': 'Spotify',
  'soundcloud': 'SoundCloud',
  'bandcamp': 'Bandcamp',
};

/// The dot itself, drawn where a row's artwork corner is.
class PlaceDot extends StatelessWidget {
  const PlaceDot(this.place, {super.key, this.size = 10});
  final String place;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = place == 'library'
        ? scheme.onSurface
        : placeColours[place] ?? scheme.outline;
    return Tooltip(
      message: placeNames[place] ?? place,
      child: Container(
        width: size + 4,
        height: size + 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

/// One row of a search: a song, a record or an artist, from anywhere.
///
/// Everything is drawn the same way — picture, name, who it is by, and a dot saying
/// where it came from — because the list is one list. What changes between them is
/// what tapping does, and that is the only thing that should.
class FoundRow extends StatelessWidget {
  const FoundRow({
    super.key,
    required this.found,
    required this.onTap,
    this.onAdd,
    this.onPlayNext,
    this.onMore,
    this.trailing,
  });

  final Found found;

  /// A tap on the row: play it, or open it.
  final VoidCallback onTap;

  /// The plus: on to the end of the queue, without playing it.
  final VoidCallback? onAdd;
  final VoidCallback? onPlayNext;

  /// The three dots, a hold, a right-click: everything else that can be done with it.
  final VoidCallback? onMore;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // A library song keeps the row it has everywhere else in the app: the same menu,
    // the same swipe, the same way of being picked out along with others. Dressing it
    // up as something new here would mean losing all of that to make it look uniform,
    // which is the wrong way round — so the dot goes on that row instead.
    if (found.kind == 'song' && found.place == 'library' && found.track != null) {
      return SongRow(
        track: found.track!,
        selectable: 'search',
        corner: const PlaceDot('library'),
        onTap: onTap,
      );
    }

    // Everything else is drawn on the same frame as that row — the same picture at
    // the same size, the same two lines, the same give under a finger and the same
    // push to play it next — because the list is one list. It was a ListTile: a
    // bigger picture, a different height, nothing under the finger and no swipe,
    // so a search read as two kinds of row, and only one of them could be pushed.
    final art = found.coverUrl == null
        ? null
        : app.api.remoteCoverUrl(
            found.coverUrl!.contains('?')
                ? found.coverUrl!
                : '${found.coverUrl!}?size=sm');
    final person = found.kind == 'artist';
    // Only for something that plays: a record's length is not a fact about it
    // anybody reads in a list.
    final duration = found.durationMs == null || !found.plays
        ? ''
        : SongRow.formatDuration(Duration(milliseconds: found.durationMs!));
    final more = onMore;

    return RowChrome(
      onTap: felt(Feel.tap, onTap),
      onLongPress: more == null ? null : felt(Feel.commit, more),
      onSecondaryTap: more,
      onSwipe: found.plays ? (onPlayNext ?? onAdd) : null,
      builder: (context, hovering) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                ArtMark(
                  // Round for a person, square for a thing — which is the one
                  // piece of shape in this list that carries meaning.
                  radius: person ? 20 : 5,
                  mark: hovering && found.plays
                      ? const Icon(Icons.play_arrow_rounded,
                          key: ValueKey('hover'), size: 24, color: Colors.white)
                      : null,
                  child: Artwork(url: art, size: 40, radius: person ? 20 : 5),
                ),
                Positioned(left: -4, bottom: -4, child: PlaceDot(found.place)),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(found.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium),
                  Text(
                    [
                      found.subtitle,
                      if (found.kind == 'album' && found.year != null) found.year!,
                      if (found.kind == 'album' && found.tracks != null)
                        '${found.tracks} songs',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  // Why this is a result, when the question was about words rather
                  // than names.
                  if (found.lyric != null)
                    Text(
                      '“${found.lyric}”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic, color: scheme.primary),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing!],
            // How long it is, set as it is on every other row of songs: for a video
            // it is half of what you want to know, the difference between a song
            // and a two-hour set.
            if (duration.isNotEmpty &&
                MediaQuery.textScalerOf(context).scale(14) / 14 < 1.4) ...[
              const SizedBox(width: 6),
              Text(duration,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (!found.plays)
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 8),
                child: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
              )
            else ...[
              // Two things to do with something that plays, and both are on the
              // row: tap it to hear it, or the plus to put it on the queue for
              // later. Held, it goes next rather than last.
              GestureDetector(
                onLongPress: onPlayNext,
                child: IconButton(
                  icon: Icon(
                      found.known
                          ? Icons.playlist_add_check
                          : Icons.add_circle_outline,
                      size: 20),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  tooltip: 'Add to the queue (hold: play next)',
                  onPressed: onAdd ?? onTap,
                ),
              ),
              if (more != null)
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  tooltip: 'More',
                  onPressed: more,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Everything that can be done with a search hit that is not a song of the library's.
///
/// A library song opens the track sheet, which does everything. A hit from a service
/// had a tap and a plus and nothing else: no way to put it in a playlist, start a
/// station on it, or go to the artist without searching again. Everything here that
/// needs a track in the library — a playlist, a station — brings the song in first,
/// which is what the plus does anyway, and then does the thing.
///
/// [open] is the search page's own way of playing or queueing a hit, so the sheet
/// does exactly what the row would.
Future<void> showFoundSheet(
  BuildContext context,
  Found found, {
  required Future<void> Function(String? mode) open,
}) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final artist = found.kind == 'artist'
      ? found.title
      : found.subtitle.split(',').first.trim();

  /// The hit, as a song of the library's — fetched from its service if it has to be.
  Future<Track?> brought() async {
    if (found.track != null) return found.track;
    try {
      messenger.say(snack(Text('Adding "${found.title}"…')));
      return await app.api.addFound(found);
    } catch (e) {
      messenger.say(problem(e));
      return null;
    }
  }

  Widget item(BuildContext sheet, IconData icon, String label, VoidCallback action,
          {bool close = true}) =>
      ListTile(
        leading: Icon(icon),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () {
          if (close) Navigator.of(sheet).pop();
          action();
        },
      );

  await ask<void>(
    context,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(found.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheet).textTheme.titleMedium),
                Text(found.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheet).textTheme.bodySmall),
                const SizedBox(height: 6),
                Row(children: [
                  PlaceDot(found.place, size: 8),
                  const SizedBox(width: 6),
                  Text(placeNames[found.place] ?? found.place,
                      style: Theme.of(sheet).textTheme.bodySmall?.copyWith(
                          color: Theme.of(sheet).colorScheme.onSurfaceVariant)),
                ]),
              ],
            ),
          ),
          const Divider(height: 1),
          if (found.plays) ...[
            item(sheet, Icons.play_arrow, 'Play now', () => open(null)),
            item(sheet, Icons.playlist_play, 'Play next', () => open('next')),
            item(sheet, Icons.playlist_add, 'Add to queue', () => open('end')),
            item(sheet, Icons.library_add, 'Add to playlist…', () async {
              final track = await brought();
              if (track != null && context.mounted) {
                await addToPlaylistSheet(context, app, track);
              }
            }),
            item(sheet, Icons.radio, 'Start a station', () async {
              final track = await brought();
              if (track != null && context.mounted) {
                await startStation(context, seed: track);
              }
            }),
            item(sheet, Icons.radio_outlined, 'Make a station, without playing it',
                () async {
              final track = await brought();
              if (track != null && context.mounted) {
                await startStation(context, seed: track, play: false);
              }
            }),
            if (!found.known)
              item(sheet, Icons.cloud_download_outlined, 'Add to the library',
                  () async {
                final track = await brought();
                if (track != null) {
                  messenger.say(snack(Text(
                      'Fetching "${track.displayTitle}" from '
                      '${placeNames[found.place] ?? found.place}')));
                }
              }),
          ],
          if (found.kind == 'album')
            item(sheet, Icons.album_outlined, 'Open the record', () => open(null)),
          if (found.kind != 'album' && found.album != null)
            item(sheet, Icons.album_outlined, 'Go to ${found.album}', () {
              navigator.push(MaterialPageRoute(
                  builder: (_) => AlbumPage(
                      album: AlbumSummary(
                          name: found.album!, artist: artist, tracks: 0))));
            }),
          if (artist.isNotEmpty && found.kind != 'artist')
            item(sheet, Icons.person_outline, 'Go to $artist', () {
              navigator.push(MaterialPageRoute(
                  builder: (_) =>
                      ArtistPage(artist: ArtistSummary(name: artist, tracks: 0))));
            }),
          if (found.kind == 'artist')
            item(sheet, Icons.person_outline, 'Open the artist', () => open(null)),
          if (found.url != null)
            item(sheet, Icons.link, 'Copy the link', () {
              Clipboard.setData(ClipboardData(text: found.url!));
              messenger.say(snack(const Text('Link copied')));
            }),
        ],
      ),
    ),
  );
}

/// Said when something was taken from a service that has to fetch it first.
void saidAdded(BuildContext context, Found found) {
  ScaffoldMessenger.of(context).say(snack(Text(found.known
      ? 'Added "${found.title}"'
      : 'Fetching "${found.title}" from ${placeNames[found.place] ?? found.place}')));
}
