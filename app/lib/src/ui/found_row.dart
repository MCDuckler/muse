import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'snack.dart';
import 'song_row.dart';
import 'track_menu.dart';

/// Which service a row came from, as a colour.
///
/// A dot rather than a heading: the list is ranked by how well each row answers the
/// question, so grouping it by service would be sorting it by the one thing nobody
/// asked about. The colours are the services' own, near enough to be recognised and
/// dull enough to sit in a list all day.
const Map<String, Color> placeColours = {
  'library': Color(0xFF7BAF7B),
  'ytmusic': Color(0xFFE05C4B),
  'spotify': Color(0xFF4BB463),
  'soundcloud': Color(0xFFE8833A),
  'bandcamp': Color(0xFF4A9DB5),
};

const Map<String, String> placeNames = {
  'library': 'In your library',
  'ytmusic': 'YouTube Music',
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
    final colour = placeColours[place] ?? Theme.of(context).colorScheme.outline;
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
    this.onPlayNext,
    this.trailing,
  });

  final Found found;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

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

    final art = found.coverUrl == null
        ? null
        : app.api.remoteCoverUrl(
            found.coverUrl!.contains('?')
                ? found.coverUrl!
                : '${found.coverUrl!}?size=sm');

    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Artwork(
              url: art,
              size: 44,
              // Round for a person, square for a thing — which is the one piece of
              // shape in this list that carries meaning.
              radius: found.kind == 'artist' ? 22 : 6,
            ),
            Positioned(left: -4, bottom: -4, child: PlaceDot(found.place)),
          ],
        ),
      ),
      title: Text(found.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              found.subtitle,
              if (found.kind == 'album' && found.year != null) found.year!,
              if (found.kind == 'album' && found.tracks != null)
                '${found.tracks} songs',
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Why this is a result, when the question was about words rather than names.
          if (found.lyric != null)
            Text(
              '“${found.lyric}”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic, color: scheme.primary),
            ),
        ],
      ),
      trailing: trailing ??
          (found.kind != 'song'
              ? const Icon(Icons.chevron_right)
              : found.known && found.track != null
                  ? IconButton(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'Track actions',
                      onPressed: () => showTrackSheet(context, found.track!),
                    )
                  : PopupMenuButton<String>(
                      tooltip: 'Add',
                      icon: Icon(found.known
                          ? Icons.check_circle_outline
                          : Icons.add_circle_outline),
                      onSelected: (what) =>
                          what == 'next' ? onPlayNext?.call() : onTap(),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'next', child: Text('Play next')),
                        PopupMenuItem(value: 'end', child: Text('Add to the queue')),
                      ],
                    )),
      onTap: onTap,
    );
  }
}

/// Said when something was taken from a service that has to fetch it first.
void saidAdded(BuildContext context, Found found) {
  ScaffoldMessenger.of(context).showSnackBar(snack(Text(found.known
      ? 'Added "${found.title}"'
      : 'Fetching "${found.title}" from ${placeNames[found.place] ?? found.place}')));
}
