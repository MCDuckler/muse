import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'source_dot.dart';
import 'track_menu.dart';

/// One song, drawn the same way everywhere it appears.
///
/// Every screen had grown its own version of this row — different heights, different
/// subtitles, some with a menu and some without, some that showed a download failing
/// and some that just looked empty. A song is a song; the only thing that should differ
/// between a search result and a queue entry is what sits at the two ends of it.
///
/// Compact on purpose: 56 logical pixels rather than a ListTile's 72, because these
/// appear in lists of hundreds and the difference is two more songs on a phone screen.
class SongRow extends StatelessWidget {
  const SongRow({
    super.key,
    required this.track,
    this.onTap,
    this.leading,
    this.handle,
    this.trailing,
    this.selected = false,
    this.showAlbum = true,
    this.showDuration = true,
    this.showMenu = true,
    this.onRemove,
    this.onChanged,
    this.dense = false,
  });

  final Track track;
  final VoidCallback? onTap;

  /// Replaces the artwork — a position number, a check.
  final Widget? leading;

  /// A grip, at the very edge of the row and tight against the artwork. It sits
  /// *beside* the cover rather than instead of it: a row of small grey grips tells you
  /// nothing at a glance, and a row with no grip at all makes you guess that holding
  /// it does something.
  final Widget? handle;

  /// Sits before the menu button. Durations and state chips go here.
  final Widget? trailing;

  final bool selected;
  final bool showAlbum;
  final bool showDuration;
  final bool showMenu;
  final VoidCallback? onRemove;
  final VoidCallback? onChanged;

  /// Tighter still, for the queue and for lists inside a sheet.
  final bool dense;

  static String formatDuration(Duration? d) {
    if (d == null || d == Duration.zero) return '';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (minutes >= 60) {
      final hours = d.inHours;
      return '$hours:${minutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final failed = track.state == 'failed';

    // Artist · album on one line: an album that is only in the metadata is not much
    // use, and two lines of subtitle in a list of four hundred is a lot of scrolling.
    final subtitle = <String>[
      if (failed) (track.failReason ?? 'Download failed') else track.artistLine,
      if (showAlbum && !failed && track.albumLine != null) track.albumLine!,
    ].join(' · ');

    final duration = SongRow.formatDuration(track.duration);

    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
      child: InkWell(
        // The feedback is the point: a list that does not answer a touch immediately
        // reads as broken long before anything has actually gone wrong.
        onTap: onTap,
        onLongPress: showMenu
            ? () => showTrackSheet(context, track,
                onRemove: onRemove, onChanged: onChanged)
            : null,
        child: Padding(
          padding: EdgeInsets.only(
              left: handle == null ? 8 : 0,
              right: 8,
              top: dense ? 4 : 6,
              bottom: dense ? 4 : 6),
          child: Row(
            children: [
              if (handle != null) handle!,
              SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: leading ?? Artwork(track: track, size: 40, radius: 5),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: failed ? scheme.error : null,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: failed ? scheme.error : scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (track.isPending) ...[
                const SizedBox(width: 8),
                _Downloading(track: track),
              ],
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
              // Where the file came from, immediately left of how long it is: the
              // right-hand end of the row is where the eye already goes for the
              // facts about a song, and on the artwork the mark was competing with
              // the picture it sat on.
              if (!track.isPending) ...[
                const SizedBox(width: 8),
                SourceDot(source: track.source),
              ],
              if (showDuration && duration.isNotEmpty && !track.isPending) ...[
                const SizedBox(width: 6),
                Text(duration,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              if (showMenu)
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  tooltip: 'Track actions',
                  onPressed: () => showTrackSheet(context, track,
                      onRemove: onRemove, onChanged: onChanged),
                )
              else
                const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A song still coming down the wire, with however much of it has arrived.
class _Downloading extends StatelessWidget {
  const _Downloading({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final percent = (track.progress?['percent'] as num?)?.toDouble();
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        value: percent == null ? null : (percent / 100).clamp(0.0, 1.0),
      ),
    );
  }
}

/// The heart, wherever it is wanted. Reads and writes the one favourites list.
class FavouriteButton extends StatelessWidget {
  const FavouriteButton({super.key, required this.trackId, this.size = 20});

  final int trackId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final on = app.isFavourite(trackId);
    return IconButton(
      icon: Icon(on ? Icons.favorite : Icons.favorite_border, size: size),
      color: on ? Theme.of(context).colorScheme.primary : null,
      visualDensity: VisualDensity.compact,
      tooltip: on ? 'Remove from favourites' : 'Add to favourites',
      onPressed: () => app.toggleFavourite(trackId),
    );
  }
}
