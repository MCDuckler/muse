import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import '../state/player.dart';
import '../state/selection.dart';
import 'artwork.dart';
import 'glass.dart';
import 'mag.dart';
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
///
/// The row answers for itself. It asks the player whether it is the song playing, so
/// the one playing is lit in every list it appears in rather than only in the queue;
/// it says under the finger that a tap was taken, before the player has had time to
/// do anything about it; and while it is being pushed sideways it lifts off the page
/// as a card, so what is uncovered behind it is *behind* it rather than showing
/// through.
class SongRow extends StatefulWidget {
  const SongRow({
    super.key,
    required this.track,
    this.onTap,
    this.leading,
    this.handle,
    this.corner,
    this.trailing,
    this.selected,
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
    this.plays = true,
    this.showArtist = true,
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

  /// Whether a tap on this row starts the song, which is what a tap on a song row
  /// does nearly everywhere. Off where it does something else — a list that adds to
  /// the queue on a tap — so the row does not stand there saying "starting" about a
  /// song that was never going to start.
  final bool plays;

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

  /// Whether this is the song playing. Left null, the row asks the player itself;
  /// the queue says so explicitly, because a queue can hold the same song twice and
  /// only one of the two rows is the one being played.
  final bool? selected;
  final bool showAlbum;
  final bool showDuration;
  final bool showMenu;
  final VoidCallback? onRemove;
  final VoidCallback? onChanged;

  /// Tighter still, for the queue and for lists inside a sheet.
  final bool dense;

  /// Whether the artist is said under the title. Off on a record's own page, where
  /// every row would say the same name.
  final bool showArtist;

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
  State<SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<SongRow> {
  /// Tapped, and the player has not yet said this is the song playing.
  ///
  /// Between the tap and the first sound there is a wait — the queue is written to
  /// the server, the stream is opened — and a row that does nothing for that long
  /// reads as a row that did not hear. This is the row saying it did. Cleared the
  /// moment the player names this song, or after a while if it never does: the tap
  /// may have opened a menu, or failed, and a spinner that never stops is a lie.
  bool _starting = false;
  Timer? _giveUp;

  @override
  void dispose() {
    _giveUp?.cancel();
    super.dispose();
  }

  void _tapped(VoidCallback onTap) {
    feel(Feel.tap);
    onTap();
    if (!widget.plays || !mounted) return;
    _giveUp?.cancel();
    setState(() => _starting = true);
    _giveUp = Timer(const Duration(seconds: 6), () {
      if (mounted && _starting) setState(() => _starting = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    // Taken out of the library a moment ago: gone from every list that is open,
    // whichever one it was removed from.
    if (context.select<AppState?, bool>((a) => a?.wasRemoved(track.id) ?? false)) {
      return const SizedBox.shrink();
    }
    final selection =
        widget.selectable == null ? null : context.watch<Selection>();
    final picking = selection?.inside(widget.selectable!) ?? false;
    final picked = picking && selection!.has(track.id);

    // Only the player, not the whole app: the row wakes when what is playing
    // changes and for nothing else.
    final player = context.select<AppState?, PlayerService?>((a) => a?.player);
    if (player == null) {
      return _build(context, picking: picking, picked: picked, now: null);
    }
    return ValueListenableBuilder<PlayingNow>(
      valueListenable: player.playingNow,
      builder: (context, now, _) =>
          _build(context, picking: picking, picked: picked, now: now),
    );
  }

  Widget _build(BuildContext context,
      {required bool picking, required bool picked, required PlayingNow? now}) {
    final track = widget.track;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final failed = track.state == 'failed';

    final current = widget.selected ?? (now?.trackId == track.id);
    final playing = current && (now?.playing ?? false);
    final buffering = current && (now?.buffering ?? false);
    // The player has caught up with the tap.
    if (_starting && current) {
      _starting = false;
      _giveUp?.cancel();
    }

    // Artist · album on one line: an album that is only in the metadata is not much
    // use, and two lines of subtitle in a list of four hundred is a lot of scrolling.
    //
    // A song on its way says what it is doing instead — "Fetching 42% · 1.1 MB/s" —
    // because that is the one moment the artist is not the thing being wondered about.
    final subtitle = track.isDownloading
        ? track.statusLine
        : <String>[
            if (failed)
              (track.failReason ?? 'Download failed')
            else if (widget.showArtist)
              track.artistLine,
            if (widget.showAlbum && !failed && track.albumLine != null)
              track.albumLine!,
          ].join(' · ');

    final duration = SongRow.formatDuration(track.duration);
    final wash = parseHexColour(track.coverColor) ?? scheme.primary;

    // Three things a row can be, all said by the row itself.
    //
    // The song playing is lit: a wash of its own cover's colour, a rule down the left
    // in the accent, its title in the accent, and the sound itself over the artwork.
    // It used to be a filled, outlined chip, which was a box drawn round a row, and
    // in a list of chips it was one more box.
    //
    // A song picked out is the accent, plainer and stronger — a choice rather than
    // an event. Picking used to replace every cover in the list with a circle: a
    // hundred rows of identical grey rings, no way to tell one record from another.
    // The covers stay and the row is simply lit.
    //
    // How the row answers a hand — hover, press, the card it lifts into while it is
    // pushed — is RowChrome's, shared with every other song-shaped row in the app.
    final ground = picked
        ? scheme.primary.withValues(alpha: 0.16)
        : current
            ? wash.withValues(alpha: isDark ? 0.18 : 0.13)
            : Colors.transparent;

    return RowChrome(
      ground: ground,
      outlined: picked,
      // While a selection is running in this list, a tap adds to it rather than
      // playing: nobody holds a row to pick it out and then expects the next tap to
      // start the music.
      onTap: picking
          ? () {
              feel(Feel.pick);
              selectionOf(context)!.toggle(widget.selectable!, track.id);
            }
          : widget.onTap == null
              ? null
              : () => _tapped(widget.onTap!),
      // A hold that turns into something has to say so under the finger: without it
      // the only way to find out whether the hold worked is to let go.
      onLongPress: widget.selectable != null
          ? () {
              feel(Feel.commit);
              selectionOf(context)!.start(widget.selectable!, track.id);
            }
          : widget.showMenu
              ? () {
                  feel(Feel.commit);
                  _sheet(context);
                }
              : null,
      // A right-click is how a desk asks a row what it can do, and the answer is the
      // sheet the three dots already open: one question, one answer.
      onSecondaryTap: !widget.showMenu ? null : () => _sheet(context),
      // Not while a selection is running: the same sideways drag would be doing two
      // things at once, and the bar at the top is how you act on a selection.
      onSwipe: picking || !widget.swipeToPlayNext
          ? null
          : () => addAndSay(context, track, mode: 'next'),
      onSwipeAway: picking ? null : widget.onSwipeAway,
      builder: (context, hovering) {
        final artwork = _Art(
          track: track,
          leading: widget.leading,
          corner: widget.corner,
          state: picked
              ? _ArtState.picked
              : _starting
                  ? _ArtState.starting
                  : current
                      ? (buffering
                          ? _ArtState.buffering
                          : playing
                              ? _ArtState.playing
                              : _ArtState.paused)
                      : hovering && widget.onTap != null && !picking
                          ? _ArtState.hover
                          : _ArtState.plain,
        );

        final body = Padding(
          padding: EdgeInsets.only(
              left: widget.handle == null ? 8 : 0,
              right: 8,
              top: widget.dense ? 4 : 6,
              bottom: widget.dense ? 4 : 6),
          child: Row(
            children: [
              if (widget.handle != null) _Grip(child: widget.handle!),
              artwork,
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
                            : current || picked
                                ? scheme.primary
                                : null,
                        fontWeight: current || picked ? FontWeight.w700 : null,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: failed
                              ? scheme.error
                              : track.isDownloading
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                widget.trailing!
              ],
              TrackMark(track: track),
              // Where the file came from, immediately left of how long it is: the
              // right-hand end of the row is where the eye already goes for the
              // facts about a song. Nothing at all for the common case.
              if (!track.isDownloading &&
                  SourceTag.worthShowing(track.source)) ...[
                const SizedBox(width: 8),
                SourceTag(source: track.source),
              ],
              // The first thing to go when the type is turned up: a row has a fixed
              // width and a title that has to be read, and the length is also in
              // the song's sheet. At twice the size the title was squeezed to
              // nothing and the row still ran off the edge.
              if (widget.showDuration &&
                  duration.isNotEmpty &&
                  !track.isDownloading &&
                  MediaQuery.textScalerOf(context).scale(14) / 14 < 1.4) ...[
                const SizedBox(width: 6),
                Text(duration,
                    style: text.bodySmall?.copyWith(
                        color: current
                            ? scheme.primary
                            : scheme.onSurfaceVariant)),
              ],
              if (widget.showMenu && !picking)
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  tooltip: 'Track actions',
                  onPressed: () => _sheet(context),
                )
              else
                const SizedBox(width: 4),
            ],
          ),
        );

        return Stack(
          children: [
            body,
            // The rule down the left: where you are, the way the tabs say it.
            Positioned(
              left: 0,
              top: 6,
              bottom: 6,
              width: 3,
              child: AnimatedOpacity(
                opacity: current && !picked ? 1 : 0,
                duration: Motion.base,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            // How much of the song has arrived, along the foot of the row. The row
            // is no taller for it: a list of rows that jump in height as downloads
            // come and go is a list that cannot be scrolled while it happens.
            if (track.isDownloading)
              Positioned(
                left: widget.handle == null ? 58 : 50,
                right: 8,
                bottom: 0,
                height: 2,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  value: track.progressFraction?.clamp(0.0, 1.0),
                  backgroundColor: scheme.primary.withValues(alpha: 0.15),
                ),
              ),
          ],
        );
      },
    );
  }

  Selection? selectionOf(BuildContext context) =>
      widget.selectable == null ? null : context.read<Selection>();

  void _sheet(BuildContext context) => showTrackSheet(context, widget.track,
      onRemove: widget.onRemove,
      onChanged: widget.onChanged,
      queuePosition: widget.queuePosition);
}

/// The frame every song-shaped row sits in, and how it answers a hand.
///
/// A row is a row wherever it is — a song in a list, a search hit from a service the
/// library has never heard of, a line of a record, what is next in the dock — and
/// they had drifted: some answered a touch by giving a little, some lit under a
/// mouse, some could be pushed aside and some could not, and one of them was a
/// stock ListTile with none of it. This is all of that in one place: the ground it
/// sits on, the lift under a mouse, the give under a finger, the card it becomes
/// while it is being pushed, and the push itself. What is *in* the row is the
/// caller's, told whether a mouse is over it so it can say so on its own artwork.
class RowChrome extends StatefulWidget {
  const RowChrome({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.ground = Colors.transparent,
    this.outlined = false,
    this.onSwipe,
    this.onSwipeAway,
  });

  /// The row's contents, given whether a mouse is over it.
  final Widget Function(BuildContext context, bool hovering) builder;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// A right-click, on a desk: what the three dots open.
  final VoidCallback? onSecondaryTap;

  /// The row's own colour: the playing song's wash, a picked row's tint. Transparent
  /// rows lift a little under a mouse.
  final Color ground;

  /// Ruled round, for a row picked out along with others.
  final bool outlined;

  /// Pulled towards you, and pushed away. Neither, and the row does not move.
  final VoidCallback? onSwipe;
  final VoidCallback? onSwipeAway;

  @override
  State<RowChrome> createState() => _RowChromeState();
}

class _RowChromeState extends State<RowChrome> {
  /// Under a finger or a mouse button right now.
  bool _pressed = false;

  /// Under a mouse. Nothing on a phone, where nothing hovers.
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ground = widget.ground == Colors.transparent &&
            _hovering &&
            widget.onTap != null
        ? scheme.onSurface.withValues(alpha: 0.05)
        : widget.ground;

    final row = GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onSecondaryTap: widget.onSecondaryTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // The feedback is the point: a list that does not answer a touch immediately
        // reads as broken long before anything has actually gone wrong.
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onHighlightChanged: (down) => setState(() => _pressed = down),
        onHover: (over) => setState(() => _hovering = over),
        child: widget.builder(context, _hovering),
      ),
    );

    // The card the row becomes while it is pushed. Without it, what the row
    // uncovered showed through the row's own transparent ground, so the words slid
    // over a slab of colour and the whole thing looked half-drawn. Read in its own
    // builder so that only this ground, and not the row's words and artwork, is
    // rebuilt for every hundredth of the drag.
    final lifted = Builder(builder: (context) {
      final pushed = SwipingNow.of(context);
      final up = (pushed * 4).clamp(0.0, 1.0);
      return AnimatedContainer(
        duration: Motion.quick,
        decoration: BoxDecoration(
          // Solid the moment it moves: the card is opaque paper with the row's own
          // tint on it, not a tint with the back showing through.
          color: up == 0 ? ground : Color.alphaBlend(ground, scheme.surface),
          borderRadius: BorderRadius.circular(10),
          border: widget.outlined
              ? Border.all(
                  color: scheme.primary.withValues(alpha: 0.7), width: 1.2)
              : null,
          boxShadow: up == 0
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28 * up),
                    blurRadius: 14 * up,
                    offset: Offset(0, 4 * up),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: row,
        ),
      );
    });

    // A touch is answered by the row giving a little under it, the way a key does.
    // Small: this is the row saying "yes", not a button being pressed home.
    final pressed = AnimatedScale(
      scale: _pressed && !stillness(context) ? 0.985 : 1,
      duration: Motion.quick,
      curve: Motion.enter,
      child: lifted,
    );

    if (widget.onSwipe == null && widget.onSwipeAway == null) return pressed;
    return SwipeAction(
      onSwipe: widget.onSwipe,
      onSwipeAway: widget.onSwipeAway,
      child: pressed,
    );
  }
}

/// A hand over a picture: the mark a row's artwork wears under a mouse, or while
/// the row is waiting for something. Shared by the rows that are not a song of the
/// library's — a search hit, a line of a record we do not hold.
class ArtMark extends StatelessWidget {
  const ArtMark({super.key, required this.child, this.mark, this.radius = 5, this.size = 40});

  final Widget child;
  final Widget? mark;
  final double radius;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: Motion.base,
                switchInCurve: Motion.enter,
                switchOutCurve: Motion.exit,
                child: mark == null
                    ? const SizedBox.shrink(key: ValueKey('none'))
                    : DecoratedBox(
                        key: mark!.key ?? const ValueKey('mark'),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(radius),
                          color: Colors.black.withValues(alpha: 0.5),
                        ),
                        child: Center(child: mark),
                      ),
              ),
            ),
          ],
        ),
      );
}

/// What is drawn over the artwork, if anything.
enum _ArtState { plain, hover, starting, playing, paused, buffering, picked }

/// The artwork, with the row's state drawn on it.
///
/// The mark goes on the record itself, held back behind a scrim so it reads against
/// any cover — a bright glyph on a bright cover is invisible. One place for all of
/// them, so the change from one to the next is a cross-fade rather than a jump.
class _Art extends StatelessWidget {
  const _Art({
    required this.track,
    required this.state,
    this.leading,
    this.corner,
  });

  final Track track;
  final _ArtState state;
  final Widget? leading;
  final Widget? corner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final art = leading ?? Artwork(track: track, size: 40, radius: 5);
    final Widget? mark = switch (state) {
      _ArtState.plain => null,
      _ArtState.hover => Icon(Icons.play_arrow_rounded,
          key: const ValueKey('hover'), size: 24, color: Colors.white),
      _ArtState.starting => const SizedBox(
          key: ValueKey('starting'),
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
      _ArtState.playing ||
      _ArtState.paused ||
      _ArtState.buffering =>
        PlayingBars(
          key: const ValueKey('bars'),
          playing: state == _ArtState.playing,
          buffering: state == _ArtState.buffering,
          colour: scheme.primary,
          size: 18,
        ),
      _ArtState.picked => Icon(Icons.check_rounded,
          key: const ValueKey('picked'), size: 22, color: scheme.primary),
    };

    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          art,
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: Motion.base,
              switchInCurve: Motion.enter,
              switchOutCurve: Motion.exit,
              child: mark == null
                  ? const SizedBox.shrink(key: ValueKey('none'))
                  : DecoratedBox(
                      key: mark.key,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        color: Colors.black.withValues(alpha: 0.5),
                      ),
                      child: Center(child: mark),
                    ),
            ),
          ),
          if (corner != null) Positioned(left: -4, bottom: -4, child: corner!),
        ],
      ),
    );
  }
}

/// The sound, as three bars.
///
/// They move while the song is playing and hold still, low, while it is paused —
/// still there, because the song is still the one on — and breathe together while
/// the player is waiting on the network, which is the one state that otherwise looks
/// like nothing happening. Not a reading of the audio: that exists, on Android, and
/// lives on the player screen. This is a sign, at eighteen pixels, that this row is
/// the one making the noise.
class PlayingBars extends StatefulWidget {
  const PlayingBars({
    super.key,
    required this.playing,
    this.buffering = false,
    required this.colour,
    this.size = 18,
  });

  final bool playing;
  final bool buffering;
  final Color colour;
  final double size;

  @override
  State<PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<PlayingBars> with TickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// How far into motion the bars are, 0 at rest and 1 in full swing, so a pause
  /// settles them rather than freezing them mid-jump.
  late final AnimationController _life =
      AnimationController(vsync: this, duration: Motion.slow);

  bool get _moving => (widget.playing || widget.buffering);

  bool _started = false;

  /// Not initState: whether the phone wants stillness is asked of the tree, and the
  /// tree cannot be asked until the state is in it.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _settle();
  }

  @override
  void didUpdateWidget(PlayingBars old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing || old.buffering != widget.buffering) _settle();
  }

  void _settle() {
    if (_moving && !stillness(context)) {
      if (!_run.isAnimating) _run.repeat();
      _life.animateTo(1, curve: Motion.enter);
    } else {
      _life.animateTo(0, curve: Motion.exit).whenComplete(() {
        if (mounted && _life.value == 0) _run.stop();
      });
    }
  }

  @override
  void dispose() {
    _run.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: Listenable.merge([_run, _life]),
            builder: (context, _) => CustomPaint(
              painter: _BarsPainter(
                t: _run.value,
                life: _life.value,
                breathing: widget.buffering,
                colour: widget.colour,
              ),
            ),
          ),
        ),
      );
}

class _BarsPainter extends CustomPainter {
  const _BarsPainter({
    required this.t,
    required this.life,
    required this.breathing,
    required this.colour,
  });

  final double t;
  final double life;
  final bool breathing;
  final Color colour;

  /// Where each bar rests, and how it moves: three different rhythms so they never
  /// line up, which is what makes three bars read as music rather than a metronome.
  static const _rest = [0.30, 0.55, 0.40];
  static const _turns = [2.0, 3.0, 2.5];
  static const _phase = [0.0, 0.35, 0.7];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colour;
    const n = 3;
    final gap = size.width * 0.16;
    final w = (size.width - gap * (n - 1)) / n;
    for (var i = 0; i < n; i++) {
      double h;
      if (breathing) {
        // All together, slowly: waiting, not playing.
        final b = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
        h = 0.25 + 0.35 * b;
      } else {
        final s = math.sin((t * _turns[i] + _phase[i]) * 2 * math.pi);
        h = 0.5 + 0.42 * s;
      }
      final height = (_rest[i] + (h - _rest[i]) * life) * size.height;
      final x = i * (w + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, w, height),
          Radius.circular(w / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.t != t ||
      old.life != life ||
      old.breathing != breathing ||
      old.colour != colour;
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

    // Coming down the wire: the row's foot says how far, and the subtitle says
    // what. A third mark here would be saying it a third time.
    if (track.isDownloading) return const SizedBox.shrink();

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
        feel(Feel.tap);
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

/// A small printed tag naming where a recording came from, for a row.
///
/// The dot said a song was different without saying how, and at seven pixels a
/// colour is a thing you have to already know. Two letters in the same colour say
/// it, in the typewriter face the fact files are set in. Nothing at all for YouTube:
/// nearly everything is, and a tag on every row is a tag on none of them.
class SourceTag extends StatelessWidget {
  const SourceTag({super.key, required this.source});

  final String source;

  static bool worthShowing(String source) => lettersOf(source) != null;

  static String? lettersOf(String source) => switch (source) {
        'soundcloud' => 'SC',
        'bandcamp' => 'BC',
        'custom' => 'YOURS',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final letters = lettersOf(source);
    if (letters == null) return const SizedBox.shrink();
    final colour = SourceDot.colourOf(source, Theme.of(context).colorScheme);
    return Tooltip(
      message: SourceDot.labelOf(source),
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 1, 4, 0),
        decoration: BoxDecoration(
          border: Border.all(color: colour.withValues(alpha: 0.8), width: 1),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(letters, style: Mag.typewriter(9.5, color: colour, bold: true)),
      ),
    );
  }
}
