import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import '../state/selection.dart';
import 'artwork.dart';
import 'motion.dart';
import 'feel.dart';
import 'source_dot.dart';
import 'swipe.dart';
import 'track_menu.dart';
import 'snack.dart';

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
    this.corner,
    this.trailing,
    this.selected = false,
    this.showAlbum = true,
    this.showDuration = true,
    this.showMenu = true,
    this.onRemove,
    this.onChanged,
    this.dense = false,
    this.selectable,
    this.swipeToPlayNext = true,
    this.onSwipeAway,
    this.queuePosition,
  });

  /// Where this row sits in the queue being played, when that is the list it is in —
  /// so its menu can play or move the row itself. See showTrackSheet.
  final int? queuePosition;

  /// Pushing the row away, where the list it is in has something for that — taking it
  /// off a playlist. Bounded like the other direction: the row does not leave the
  /// frame, because it is not going anywhere until it is let go of.
  final VoidCallback? onSwipeAway;

  /// Push the row aside to put the song on next.
  ///
  /// On by default, because it is the thing most often wanted from a list you are
  /// looking at, and off in the queue: a song already in the queue has nothing to be
  /// added to, and that list uses the same gesture to take rows out.
  final bool swipeToPlayNext;

  /// Which list this row is in, when it can be picked out along with others.
  ///
  /// Given one, holding the row starts a selection and tapping adds to it — see
  /// Selection. Rows in lists that pass nothing behave as they always did.
  final String? selectable;

  final Track track;
  final VoidCallback? onTap;

  /// Replaces the artwork — a position number, a check.
  final Widget? leading;

  /// Drawn over the corner of the artwork: a small face saying who put this song
  /// here. Only worth showing where more than one person is adding to a list.
  final Widget? corner;

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
    final selection = selectable == null ? null : context.watch<Selection>();
    final picking = selection?.inside(selectable!) ?? false;
    final picked = picking && selection!.has(track.id);

    // Artist · album on one line: an album that is only in the metadata is not much
    // use, and two lines of subtitle in a list of four hundred is a lot of scrolling.
    final subtitle = <String>[
      if (failed) (track.failReason ?? 'Download failed') else track.artistLine,
      if (showAlbum && !failed && track.albumLine != null) track.albumLine!,
    ].join(' · ');

    final duration = SongRow.formatDuration(track.duration);

    // Two different things a row can be, both said by the row itself.
    //
    // The song playing used to be a ten-percent wash, which is nothing to catch on
    // while scrolling past four hundred of them; it is a chip now — filled, outlined,
    // its title in the accent colour, and a small mark on the artwork.
    //
    // A song you have picked out is the same idea, stronger, and that is all it is.
    // Picking used to replace every cover in the list with a circle: a hundred rows of
    // identical grey rings, no way to tell one record from another, and the thing you
    // were choosing between taken away at the moment of choosing. The covers stay and
    // the row is simply lit.
    final row = Material(
      color: picked
          ? scheme.primary.withValues(alpha: 0.26)
          : selected
              ? scheme.primary.withValues(alpha: 0.20)
              : Colors.transparent,
      shape: picked || selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: scheme.primary.withValues(alpha: picked ? 0.85 : 0.55),
                  width: picked ? 1.6 : 1.2),
            )
          : null,
      child: InkWell(
        // The feedback is the point: a list that does not answer a touch immediately
        // reads as broken long before anything has actually gone wrong.
        //
        // While a selection is running in this list, a tap adds to it rather than
        // playing: nobody holds a row to pick it out and then expects the next tap to
        // start the music.
        onTap: picking
            ? () {
                feel(Feel.pick);
                selection!.toggle(selectable!, track.id);
              }
            : onTap == null
                ? null
                : felt(Feel.tap, onTap),
        // A hold that turns into something has to say so under the finger: without it
        // the only way to find out whether the hold worked is to let go.
        onLongPress: selectable != null
            ? () {
                feel(Feel.commit);
                selection!.start(selectable!, track.id);
              }
            : showMenu
                ? () {
                    feel(Feel.commit);
                    showTrackSheet(context, track,
                        onRemove: onRemove,
                        onChanged: onChanged,
                        queuePosition: queuePosition);
                  }
                : null,
        child: Padding(
          padding: EdgeInsets.only(
              left: handle == null ? 8 : 0,
              right: 8,
              top: dense ? 4 : 6,
              bottom: dense ? 4 : 6),
          child: Row(
            children: [
              if (handle != null) _Grip(child: handle!),
              SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: corner == null && !selected
                      ? leading ?? Artwork(track: track, size: 40, radius: 5)
                      : Stack(
                          clipBehavior: Clip.none,
                          children: [
                            leading ?? Artwork(track: track, size: 40, radius: 5),
                            // The mark on the record itself. Held back behind a
                            // scrim so it reads against any artwork — a bright
                            // glyph on a bright cover is invisible, which is the
                            // failure this whole change is about.
                            if (selected)
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(5),
                                    color: Colors.black.withValues(alpha: 0.45),
                                  ),
                                  child: Icon(Icons.graphic_eq,
                                      size: 20, color: scheme.primary),
                                ),
                              ),
                            if (corner != null)
                              Positioned(left: -4, bottom: -4, child: corner!),
                          ],
                        ),
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
                        color: failed
                            ? scheme.error
                            : selected
                                ? scheme.primary
                                : null,
                        fontWeight: selected ? FontWeight.w700 : null,
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
              if (track.isDownloading) ...[
                const SizedBox(width: 8),
                _Downloading(track: track),
              ],
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
              TrackMark(track: track),

              // Where the file came from, immediately left of how long it is: the
              // right-hand end of the row is where the eye already goes for the
              // facts about a song, and on the artwork the mark was competing with
              // the picture it sat on.
              if (!track.isDownloading) ...[
                const SizedBox(width: 8),
                SourceDot(source: track.source),
              ],
              if (showDuration && duration.isNotEmpty && !track.isDownloading) ...[
                const SizedBox(width: 6),
                Text(duration,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              if (showMenu && !picking)
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  tooltip: 'Track actions',
                  onPressed: () => showTrackSheet(context, track,
                      onRemove: onRemove,
                      onChanged: onChanged,
                      queuePosition: queuePosition),
                )
              else
                const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );

    // Not while a selection is running: the same sideways drag would be doing two
    // things at once, and the bar at the top is how you act on a selection.
    if (picking || (!swipeToPlayNext && onSwipeAway == null)) return row;
    return SwipeAction(
      onSwipe: !swipeToPlayNext
          ? null
          : () => addAndSay(context, track, mode: 'next'),
      onSwipeAway: onSwipeAway,
      child: row,
    );
  }
}

/// The grip, which gets out of the way while the row is being pushed.
///
/// It is the one part of a row that belongs to the list rather than to the song, and
/// it sat there at full strength while the row slid sideways underneath it — two
/// gestures visible at once, neither of which was the one happening. It fades with the
/// drag rather than on a timer, so it goes as the row goes and comes back as the row
/// comes back.
class _Grip extends StatelessWidget {
  const _Grip({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Gone by a third of the way: far enough in that a tap or a scroll does not dim
    // it, early enough that it is out of sight before the row has really moved.
    final gone = (SwipingNow.of(context) * 3).clamp(0.0, 1.0);
    if (gone == 0) return child;
    return IgnorePointer(
      ignoring: gone > 0.5,
      child: Opacity(opacity: 1 - gone, child: child),
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
class FavouriteButton extends StatefulWidget {
  const FavouriteButton({super.key, required this.trackId, this.size = 20});

  final int trackId;
  final double size;

  @override
  State<FavouriteButton> createState() => _FavouriteButtonState();
}

/// The heart, which is worth a little more than the rest of the row.
///
/// It is the one control in the app whose whole job is to say "yes, this one", and it
/// used to swap one glyph for another with nothing in between. A quick swell as it
/// fills — and a tick under the finger — is the difference between a button that
/// registered and a button you have to look at to be sure of.
class _FavouriteButtonState extends State<FavouriteButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swell =
      AnimationController(vsync: this, duration: Motion.base);

  @override
  void dispose() {
    _swell.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = context.select<AppState, bool>((a) => a.isFavourite(widget.trackId));
    return IconButton(
      icon: AnimatedBuilder(
        animation: _swell,
        builder: (context, child) => Transform.scale(
          // Out and back, rather than out and stay: the heart is the same size after
          // as before, and what happened is the journey.
          scale: 1 + 0.35 * Curves.easeOut.transform(
              (1 - (_swell.value * 2 - 1).abs()).clamp(0.0, 1.0)),
          child: child,
        ),
        child: Icon(on ? Icons.favorite : Icons.favorite_border, size: widget.size),
      ),
      color: on ? Theme.of(context).colorScheme.primary : null,
      visualDensity: VisualDensity.compact,
      tooltip: on ? 'Remove from favourites' : 'Add to favourites',
      onPressed: () {
        feel(Feel.tap);
        if (!stillness(context)) _swell.forward(from: 0);
        context.read<AppState>().toggleFavourite(widget.trackId);
      },
    );
  }
}

/// Where a song *is*, in one small mark.
///
/// Four states and they matter: the audio is here and kept on this device; it is on
/// its way; it is listed but not fetched; it tried and failed. Most of this library is
/// the third — eighteen thousand of twenty-two thousand rows are a name and a place to
/// get it from — so the mark is quiet by design: a cloud rather than a spinner,
/// because a spinner is a promise that something is happening and in a mirrored
/// library that promise would be made to every row on screen.
///
/// It lives here rather than inside the row because the row is not the only place a
/// song appears: the queue beside the page, what you have played most, the songs on a
/// record. They all used to draw nothing at all, which made "why will this not play"
/// a question with no answer on the screen it was asked from.
class TrackMark extends StatelessWidget {
  const TrackMark({super.key, required this.track, this.canFetch = true});

  final Track track;

  /// Whether the cloud is a button. Where a row is only being read — a list of what
  /// somebody played most — it is not.
  final bool canFetch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Listed, and nothing on its way. Tapping it asks for this one song, which is the
    // thing the cloud has always looked like it should do.
    if (track.isNotFetched) {
      final mark = Icon(Icons.cloud_outlined,
          size: 16, color: scheme.onSurfaceVariant);
      if (!canFetch) {
        return Padding(padding: const EdgeInsets.only(left: 6), child: mark);
      }
      return _Fetch(track: track, child: mark);
    }

    if (!OfflineStore.supported) return const SizedBox.shrink();
    return Builder(builder: (context) {
      // Only this song's two facts, not the whole app: a row in a list of four hundred
      // rebuilt every time anything anywhere changed — including every download
      // progress report — to draw a 14-pixel tick that had not moved.
      final offline = context.select<AppState, ({bool here, bool coming})>((a) => (
            here: a.offline.has(track.id),
            coming: a.offline.isQueued(track.id),
          ));
      if (offline.here) {
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Icon(Icons.download_done, size: 14, color: scheme.onSurfaceVariant),
        );
      }
      if (offline.coming) {
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: SizedBox(
            width: 12,
            height: 12,
            child:
                CircularProgressIndicator(strokeWidth: 1.6, color: scheme.outline),
          ),
        );
      }
      return const SizedBox.shrink();
    });
  }
}

/// The cloud, as a button: one song, fetched.
class _Fetch extends StatefulWidget {
  const _Fetch({required this.track, required this.child});
  final Track track;
  final Widget child;

  @override
  State<_Fetch> createState() => _FetchState();
}

class _FetchState extends State<_Fetch> {
  bool _asked = false;

  @override
  Widget build(BuildContext context) {
    if (_asked) {
      return const Padding(
        padding: EdgeInsets.only(left: 6),
        child: SizedBox(
            width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
      );
    }
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.only(left: 6),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: widget.child,
      tooltip: 'Not here yet — get it',
      onPressed: () async {
        final app = context.read<AppState>();
        final messenger = ScaffoldMessenger.of(context);
        setState(() => _asked = true);
        try {
          final got = await app.api.fetchAudio(trackIds: [widget.track.id]);
          messenger.say(snack(Text(got.queued > 0
              ? 'Getting “${widget.track.displayTitle}”'
              : 'There is nowhere left to fetch that from')));
        } catch (e) {
          messenger.say(problem(e));
          if (mounted) setState(() => _asked = false);
        }
      },
    );
  }
}
