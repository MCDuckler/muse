import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/keepalive.dart';
import '../state/offline.dart';
import '../state/playback_log.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'back_and_forth.dart';
import 'dialogs.dart';
import 'feel.dart';
import 'glass.dart';
import 'motion.dart';
import 'record_stage.dart';
import 'sleeve_ink.dart';
import 'spectrum.dart';
import 'lyrics_sheet.dart';
import 'track_menu.dart';
import 'song_row.dart';
import 'browse_page.dart';
import 'home_page.dart';
import 'jam_page.dart';
import 'halftone.dart';
import 'progress.dart';
import 'pulse.dart';
import 'open_from.dart';

String formatTime(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// The full player. The bar at the bottom of the app is a handle onto this; every
/// control that needs room — scrubbing, shuffle, repeat, volume — lives here.
/// Whether the player screen has ever been drawn in this session — a breadcrumb for
/// the log, so a browser that dies with the player open says so.
bool _openedOnce = false;

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!_openedOnce) {
      _openedOnce = true;
      PlaybackLog.note('player screen opened');
    }
    final app = context.watch<AppState>();
    final player = app.player;
    if (player == null) return const SizedBox.shrink();

    return StreamBuilder<PlayerSnapshot>(
      // Coarse on purpose. The record turning, the disc sliding out and the printed
      // background are animations with their own clocks; rebuilding the screen under
      // them four times a second is what made them stutter. The scrubber keeps its own
      // fine-grained subscription — see _Scrubber.
      stream: player.changes,
      initialData: player.last,
      builder: (context, snap) {
        final s = snap.data;
        final track = s?.current ?? player.current;
        final scheme = Theme.of(context).colorScheme;

        return Scaffold(
          extendBodyBehindAppBar: true,
          // The same three places as everywhere else.
          //
          // The player covered them completely, so opening what is playing meant
          // losing every way of going anywhere until you had closed it again — and
          // the way to close it was a downward drag nobody is told about. Tapping one
          // takes you there, which means getting out of the player on the way.
          bottomNavigationBar: GlassSurface(
            child: SafeArea(
              top: false,
              child: MuseNavigationBar(
                onLeaving: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
              ),
            ),
          ),
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Close',
            ),
            title: app.jam == null
                ? Text(app.activeQueue?.name ?? 'Now playing',
                    style: Theme.of(context).textTheme.titleSmall)
                : _JamTitle(app: app),
            centerTitle: true,
            // Where these live is a setting: the top corners are furthest from a
            // thumb, which is why they moved, but it is also the arrangement people
            // knew — so it is still here to choose.
            actions: app.playerLayout == PlayerLayout.topBar && track != null
                ? [
                    IconButton(
                      icon: const Icon(Icons.lyrics_outlined),
                      tooltip: 'Lyrics',
                      onPressed: () => showLyrics(context, track),
                    ),
                    IconButton(
                      icon: Icon(app.sleepSet
                          ? Icons.bedtime
                          : Icons.timer_outlined),
                      tooltip: 'Sleep timer and speed',
                      onPressed: () => showPlaybackExtras(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'Track actions',
                      onPressed: () => showTrackSheet(context, track,
                          onChanged: app.refresh),
                    ),
                  ]
                : const [],
          ),
          body: _CloseByHand(
            // Drag down to close, the gesture that dismisses a sheet anywhere else —
            // and the same animation that opened it, run backwards by the finger
            // rather than played at it. Sideways belongs to the record itself:
            // dragging the whole screen to change track carried the title and the
            // controls along with it, which is not what the gesture is about.
            child: AmbientBackdrop(
            colour: parseHexColour(track?.coverColor),
            // The album's own colour where it has one, so the page belongs to the
            // record rather than to the app.
            // Once it has arrived, not while it is on its way.
            //
            // The printed background is a shader over the whole screen, and it was
            // being built and first painted on the very frame the drag started — the
            // one frame that has to be smooth, because it is the one the finger is
            // waiting on. It costs nothing to wait for the page to land: until then
            // there is a window the size of the player bar to look through.
            behind: app.halftone
                ? _OnceItHasLanded(
                    builder: (context) => HalftoneBackdrop(
                      colour: parseHexColour(track?.coverColor),
                      // What the room is doing, not what this device's own engine is:
                      // a guest listening to somebody else's speaker can hear the
                      // music, and a still background says it has stopped.
                      playing: app.musicIsPlaying,
                      loudnessDb: track?.loudnessLufs,
                    ),
                  )
                : null,
            child: track == null
              ? const Center(child: Text('Nothing playing'))
              : SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Padding(
                        // Plain runs its panel almost to the walls, so the page's own
                        // margin gets out of the way and the words inside keep theirs.
                        padding: EdgeInsets.symmetric(
                            horizontal: app.playerLayout == PlayerLayout.plain
                                ? 8
                                : 24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Room above the record.
                            //
                            // It sat hard against the app bar, which reads as the
                            // screen having run out rather than as a record standing
                            // on a shelf with air around it.
                            const SizedBox(height: 28),
                            // Roomy trades artwork for buttons: the panel below wants
                            // the space more than the record does when the phone is
                            // being held in one hand.
                            Flexible(
                              child: FractionallySizedBox(
                                widthFactor: app.playerLayout == PlayerLayout.roomy
                                    ? 0.82
                                    : app.playerLayout == PlayerLayout.plain
                                        ? 0.88
                                        : 1.0,
                                child: _Artwork(
                                    track: track,
                                    snapshot: s,
                                    player: player,
                                    app: app),
                              ),
                            ),
                            // Putting a number here does not move the words: the
                            // column fills the screen and the record's box is the
                            // flexible one, so every pixel added to this gap comes
                            // straight out of the box above it and the words stay
                            // exactly where they were. What actually opens up the
                            // room under the cover is the cover standing higher on
                            // the stage, which is where that is done.
                            SizedBox(
                                height: app.playerLayout == PlayerLayout.roomy
                                    ? 18
                                    : 32),
                            // Only while a record is turned over. It is the back of a
                            // sleeve, not an art program: the pens appear because
                            // there is suddenly something to draw on, and go again
                            // when the record is turned back.
                            _SleeveTools(app: app),
                            Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: app.playerLayout == PlayerLayout.plain
                                      ? 14
                                      : 0),
                              child: _Words(app: app, track: track),
                            ),
                            if (_statusLine(s, track) != null) ...[
                              const SizedBox(height: 10),
                              Text(_statusLine(s, track)!.text,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: _statusLine(s, track)!.problem
                                          ? scheme.error
                                          : scheme.onSurfaceVariant)),
                            ],
                            // The one thing that stops the music which this app cannot
                            // fix from in here. See _TheMusicWillStop.
                            if (app.musicWillStopInTheBackground)
                              const _TheMusicWillStop(),
                            // Plain sets its buttons out in the open rather than in a
                            // panel, so the words need less air under them: the same
                            // gap that separates a block of text from a panel leaves a
                            // block of text stranded above a row of buttons.
                            SizedBox(
                                height: app.playerLayout == PlayerLayout.plain
                                    ? 6
                                    : 22),
                            // Plain lays the same things out in a different order and
                            // without a panel around them: the song's own buttons in a
                            // row, then the bar with its times at either end, then the
                            // transport large across the bottom.
                            if (app.playerLayout == PlayerLayout.plain)
                              GlassSurface(
                                borderRadius: BorderRadius.circular(20),
                                topBorder: false,
                                opacity: 0.55,
                                blur: 30,
                                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _Extras(app: app, track: track, spread: true),
                                    const SizedBox(height: 2),
                                    _Scrubber(
                                        player: player,
                                        timesBeside: true,
                                        on: _bars(app, player, track, s)),
                                    const SizedBox(height: 6),
                                    _Controls(
                                        app: app,
                                        player: player,
                                        snapshot: s,
                                        big: true,
                                        bare: true),
                                  ],
                                ),
                              )
                            else
                              GlassSurface(
                                borderRadius: BorderRadius.circular(22),
                                topBorder: false,
                                opacity: 0.55,
                                blur: 30,
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _Scrubber(
                                        player: player,
                                        timesBeside: true,
                                        on: _bars(app, player, track, s)),
                                    const SizedBox(height: 4),
                                    _Controls(
                                        app: app,
                                        player: player,
                                        snapshot: s,
                                        big: app.playerLayout ==
                                            PlayerLayout.roomy),
                                    if (app.playerLayout != PlayerLayout.topBar) ...[
                                      SizedBox(
                                          height: app.playerLayout ==
                                                  PlayerLayout.roomy
                                              ? 8
                                              : 2),
                                      _Extras(
                                          app: app,
                                          track: track,
                                          big: app.playerLayout ==
                                              PlayerLayout.roomy),
                                    ],
                                    SizedBox(
                                        height: app.playerLayout ==
                                                PlayerLayout.roomy
                                            ? 8
                                            : 2),
                                    _VolumeRow(player: player),
                                  ],
                                ),
                              ),
                            // Air under the panel.
                            //
                            // The controls ended where the body ended, which put the
                            // volume slider a couple of pixels above the bar with the
                            // three places in it — two rows of controls touching, and
                            // the bottom one is the one you reach for by feel.
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          ),
          ),
        );
      },
    );
  }

  /// The spectrum, where it is switched on and the platform can read one.
  ///
  /// Null everywhere else, which is what keeps it out of the bar's layout rather than
  /// leaving an empty strip above it.
  static Widget? _bars(AppState app, PlayerService player, Track track,
      PlayerSnapshot? s) {
    if (!app.spectrum || !Spectrum.available) return null;
    return Spectrum(
      sessionId: player.androidAudioSessionId,
      playing: s?.playing ?? false,
      colour: parseHexColour(track.coverColor),
    );
  }

  /// What to say under the song, and whether it is bad news. Only a failure is drawn
  /// in red; a download in progress or the end of the queue is simply information.
  static ({String text, bool problem})? _statusLine(PlayerSnapshot? s, Track track) {
    // First: the browser is only waiting to be tapped, which is not a failure.
    if (s?.needsGesture ?? false) return (text: 'Ready — tap play', problem: false);
    if (s?.error != null) return (text: s!.error!, problem: true);
    if (s?.waitingForDownload ?? false) {
      return (text: 'Waiting for download…', problem: false);
    }
    if (s?.finished ?? false) return (text: 'End of queue', problem: false);
    if (track.state == 'failed') {
      return (text: track.failReason ?? 'This track failed', problem: true);
    }
    if (track.isPending) return (text: 'Downloading…', problem: false);
    if (s?.buffering ?? false) return (text: 'Loading…', problem: false);
    return null;
  }
}

/// Said on the screen, because it is the difference between music that keeps playing
/// and music that stops ten seconds after you look at something else.
///
/// Android will not let an app hold itself up in the background without a notification
/// it can show, and since Android 13 that takes a permission somebody has to agree to.
/// Refused twice, it is never asked for again — the dialog simply stops appearing — so
/// an app that only asks is an app that goes quiet forever with no explanation. This is
/// the explanation, and the way to the page that fixes it.
class _TheMusicWillStop extends StatelessWidget {
  const _TheMusicWillStop();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 12, right: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Keepalive.takeMeToTheSettings(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.notifications_off_outlined,
                  size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Notifications are off, so the music stops when you leave the '
                  'app. Tap to turn them on.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The way into the player: the small bar opening out, and closing back into it.
///
/// It used to arrive from the side, which is what a *page* does — one thing after
/// another in a stack you go back through. Then it came up from the bottom, which was
/// closer but still a sheet arriving over the app rather than the thing you tapped
/// growing. The player *is* the bar at the bottom of the screen opened out: it starts
/// at the bar's own rectangle and grows to fill the screen, and dragging it down puts
/// it back where it came from.
///
/// [from] is where the bar is, in screen coordinates, at the moment it was tapped.
/// Without one — opened by a keyboard shortcut, or from a screen with no bar — it
/// falls back to rising from the bottom edge.
class NowPlayingRoute extends PageRouteBuilder<void> {
  NowPlayingRoute({this.from, this.byHand = false, WidgetBuilder? page})
      : super(
          // Opaque, so that once it has arrived the app underneath stops being drawn
          // at all. A see-through route keeps every screen below it painting for as
          // long as it is open, which is a whole app rendered behind a page that
          // covers it.
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (context, _, __) =>
              page == null ? const NowPlayingScreen() : page(context),
        );

  /// The bar's rectangle on screen, at the moment it was taken hold of.
  final Rect? from;

  /// Pushed by a finger that is still down, and is going to say how far.
  final bool byHand;

  /// The transition itself, for a gesture to drive.
  ///
  /// A page that opens on a timer no matter what the hand is doing is the difference
  /// between a control and an announcement. This is the same animation the tap uses;
  /// a drag simply sets where it is up to.
  AnimationController? get hand => controller;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      OpenFrom(animation: animation, from: from, child: child);

  @override
  TickerFuture didPush() {
    final pushed = super.didPush();
    if (byHand) {
      // Pushed and immediately held still at nothing: the finger is what moves it
      // from here, and it has not moved yet.
      controller!
        ..stop()
        ..value = 0;
    }
    return pushed;
  }
}

Route<void> nowPlayingRoute({Rect? from}) => NowPlayingRoute(from: from);

/// Opening and closing it with a finger.
///
/// Both directions are the same animation seen from different ends, so they are the
/// same code: take hold of the transition, follow the finger, and let go of it with
/// whatever speed it was moving at. Nothing about this is a duration.
class NowPlayingHold {
  NowPlayingHold(this.route)
      : navigator = route.navigator!,
        controller = route.hand! {
    navigator.didStartUserGesture();
  }

  final NowPlayingRoute route;
  final NavigatorState navigator;
  final AnimationController controller;

  /// Screen-heights per second below which a flick is not a flick.
  static const _flick = 1.0;

  void moveBy(double fraction) =>
      controller.value = (controller.value + fraction).clamp(0.0, 1.0);

  /// What letting go here means.
  ///
  /// A flick decides it whichever way it is going, however far the drag got — throwing
  /// it at the screen and having it fall back because it was only a third of the way
  /// is the thing that makes a gesture feel ignored. A slow drag that got more than
  /// halfway-ish carries on; anything less goes back.
  static bool opens({required double at, required double velocity}) =>
      velocity.abs() >= _flick ? velocity > 0 : at > 0.4;

  /// Let go. [velocity] is in screen-heights per second, positive towards open.
  void letGo(double velocity) {
    final opening = opens(at: controller.value, velocity: velocity);
    if (opening) {
      controller.fling(velocity: math.max(velocity, _flick));
    } else {
      // The route has to be popped for the navigator to take it away when the
      // animation reaches the bottom; without that it sits there at nothing,
      // invisible and in front of everything.
      navigator.pop();
      if (controller.isAnimating) {
        controller.animateBack(0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic);
      }
    }
    navigator.didStopUserGesture();
  }

  /// Give up without deciding — the gesture was taken over by something else.
  void cancel() => letGo(0);

  /// Let go of the navigator without deciding anything at all.
  ///
  /// For the screen being taken away mid-drag: popping or flinging something that is
  /// already on its way out is worse than leaving it, but the navigator still has to
  /// be told the gesture is over or it stays in a gesture for ever.
  void abandon() => navigator.didStopUserGesture();
}

/// Built when the page it is on has finished arriving, and kept from then on.
///
/// For the expensive parts of a screen — a full-screen shader, in this case. Opening
/// is the moment a phone has least to spare, and the thing being opened does not need
/// all of itself on the first frame. Once shown it stays: dragging the page back down
/// must not take the background away while the drag is happening.
class _OnceItHasLanded extends StatefulWidget {
  const _OnceItHasLanded({required this.builder});
  final WidgetBuilder builder;

  @override
  State<_OnceItHasLanded> createState() => _OnceItHasLandedState();
}

class _OnceItHasLandedState extends State<_OnceItHasLanded> {
  Animation<double>? _arriving;
  bool _landed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final arriving = ModalRoute.of(context)?.animation;
    if (identical(arriving, _arriving)) return;
    _arriving?.removeListener(_look);
    _arriving = arriving;
    _landed = arriving == null || arriving.isCompleted;
    if (!_landed) arriving!.addListener(_look);
  }

  void _look() {
    if (_landed || !(_arriving?.isCompleted ?? false)) return;
    _arriving?.removeListener(_look);
    setState(() => _landed = true);
  }

  @override
  void dispose() {
    _arriving?.removeListener(_look);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _landed ? widget.builder(context) : const SizedBox.shrink();
}


/// Dragging the player shut.
///
/// The page used to slide down a little under the finger and then, past a threshold,
/// let go of it and play a closing animation on its own — two different movements for
/// one gesture, and the hand-over was the moment it stopped feeling connected. This is
/// the opening animation in reverse, and the finger is what runs it: the window shrinks
/// back towards the bar by exactly as much as the drag, and letting go either throws it
/// the rest of the way shut or puts it back where it was.
class _CloseByHand extends StatefulWidget {
  const _CloseByHand({required this.child});
  final Widget child;

  @override
  State<_CloseByHand> createState() => _CloseByHandState();
}

class _CloseByHandState extends State<_CloseByHand> {
  NowPlayingHold? _hold;

  double get _height => MediaQuery.sizeOf(context).height;

  /// The route this screen is on, when it is one that can be driven. Opened any other
  /// way — a keyboard shortcut, a deep link — the drag simply closes it.
  NowPlayingRoute? get _route {
    final route = ModalRoute.of(context);
    return route is NowPlayingRoute && route.hand != null ? route : null;
  }

  void _start(DragStartDetails _) {
    final route = _route;
    if (route == null || _hold != null) return;
    _hold = NowPlayingHold(route);
  }

  void _update(DragUpdateDetails d) =>
      _hold?.moveBy(-(d.primaryDelta ?? 0) / _height);

  void _end(DragEndDetails d) {
    final hold = _hold;
    _hold = null;
    if (hold != null) {
      hold.letGo(-d.velocity.pixelsPerSecond.dy / _height);
      return;
    }
    // No hold to give back: a downward flick still means close.
    if (d.velocity.pixelsPerSecond.dy > 600) Navigator.of(context).maybePop();
  }

  void _cancel() {
    final hold = _hold;
    _hold = null;
    hold?.cancel();
  }

  @override
  void dispose() {
    _hold?.abandon();
    _hold = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onVerticalDragStart: _start,
        onVerticalDragUpdate: _update,
        onVerticalDragEnd: _end,
        onVerticalDragCancel: _cancel,
        child: widget.child,
      );
}

/// Listening together, said where you are looking.
///
/// A jam changes what the buttons on this screen mean — anyone can add, a skip is a
/// vote — so it has to be visible from the screen those buttons are on, not only from
/// the jam page. Tapping it goes there.
class _JamTitle extends StatelessWidget {
  const _JamTitle({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final jam = app.jam!;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const JamPage())),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                jam.isHost
                    ? 'Your jam · ${jam.listening} listening'
                    : "${jam.host ?? 'Someone'}'s jam",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: scheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Artist and album, and the way to each of their pages.
///
/// They were a line of grey text saying where a song came from. They are the two most
/// obvious things to want next — everything else by them, the rest of the record — and
/// a name that leads nowhere when you press it is a name you learn not to press.
class _Credits extends StatelessWidget {
  const _Credits({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(color: scheme.onSurfaceVariant);

    Widget link(String label, VoidCallback onTap, {TextStyle? own}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: BackAndForth(label,
                style: (own ?? style)?.copyWith(
                    decoration: TextDecoration.underline,
                    decorationColor:
                        scheme.onSurfaceVariant.withValues(alpha: 0.4))),
          ),
        );

    final albumStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.75));

    // Artist over album over source: one to a line, and always the same three lines.
    //
    // Side by side, artist and album were two links competing for one row — a long one
    // of each got half of it, both ended in an ellipsis, and the dot between them read
    // as punctuation rather than as a divider between two things you can tap.
    //
    // The room for all three is reserved whether or not this particular song has an
    // album or came from somewhere worth naming. Otherwise every song changes the
    // height of this block, and a block above the controls that changes height moves
    // the record, the bar and the buttons with it — so the whole screen twitches on
    // every track, which is the thing that is actually noticed.
    final lines = <Widget>[
        link(
          track.artistLine,
          () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArtistPage(
              artist: ArtistSummary(
                  name: track.artists.isEmpty
                      ? track.artistLine
                      : track.artists.first,
                  tracks: 0),
            ),
          )),
        ),
        if (track.albumLine != null)
          link(
            own: albumStyle,
            track.albumLine!,
            () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AlbumPage(
                album: AlbumSummary(
                  name: track.albumLine!,
                  artist: track.artists.isEmpty ? '' : track.artists.first,
                  tracks: 0,
                ),
              ),
            )),
          ),
    ];

    // Measured from the font rather than worked out from a line-height factor. The
    // factor was a guess at Manrope's line, a hair short of the real one, and the
    // column overflowed by a fraction of a pixel — which a debug build draws as a
    // striped bar across the album's name.
    final scaler = MediaQuery.textScalerOf(context);
    final ambient = DefaultTextStyle.of(context).style;
    double heightOf(TextStyle? style, double fallback) {
      final painter = TextPainter(
        text: TextSpan(
            text: 'Ag', style: ambient.merge(style ?? TextStyle(fontSize: fallback))),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final h = painter.height;
      painter.dispose();
      return h;
    }

    // Each line's own height, plus what the padding inside a link adds. Measured from
    // the type rather than guessed, so it holds at any text scale.
    //
    // Two lines, not three. There was a third — where the song came from — and it is
    // not drawn any more, but its height was still being kept: an empty row under
    // every song, which is a gap between the words and the buttons that nothing is
    // ever going to fill. What has to stay reserved is the album's row, because that
    // is the one that varies from song to song and the record sits above it.
    final reserved =
        (heightOf(style, 16) + 4 + heightOf(albumStyle, 14) + 4).ceilToDouble();

    return SizedBox(
      height: reserved,
      child: Column(mainAxisSize: MainAxisSize.min, children: lines),
    );
  }
}

/// The things that act on the song, where a thumb already is.
class _Extras extends StatelessWidget {
  const _Extras(
      {required this.app,
      required this.track,
      this.big = false,
      this.spread = false});
  final AppState app;
  final Track track;
  final bool big;

  /// The song's buttons on the left, what the queue does with it on the right — the
  /// two are different kinds of thing, and putting a gap between them says so.
  final bool spread;

  @override
  Widget build(BuildContext context) {
    final size = big ? 28.0 : 22.0;
    if (spread) {
      return Row(
        children: [
          FavouriteButton(trackId: track.id, size: size),
          IconButton(
            iconSize: size,
            icon: const Icon(Icons.lyrics_outlined),
            tooltip: 'Lyrics',
            onPressed: () => showLyrics(context, track),
          ),
          // The two things people do with a song they are listening to, next to the
          // things they already do with it here: put it somewhere, and keep it. Both
          // are in the sheet behind the last button as well — this is the shortcut,
          // not the only way.
          IconButton(
            iconSize: size,
            icon: const Icon(Icons.library_add_outlined),
            tooltip: 'Add to playlist',
            onPressed: () => addToPlaylistSheet(context, app, track),
          ),
          if (OfflineStore.supported) _KeepButton(app: app, track: track, size: size),
          IconButton(
            iconSize: size,
            icon: const Icon(Icons.more_horiz),
            tooltip: 'Track actions',
            onPressed: () =>
                showTrackSheet(context, track, onChanged: app.refresh),
          ),
          const Spacer(),
          _RepeatButton(app: app, size: size),
          IconButton(
            iconSize: size,
            icon: const Icon(Icons.shuffle),
            tooltip: 'Shuffle what is coming',
            onPressed: app.shuffleWhatIsComing,
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        FavouriteButton(trackId: track.id, size: size),
        IconButton(
          iconSize: size,
          icon: const Icon(Icons.lyrics_outlined),
          tooltip: 'Lyrics',
          onPressed: () => showLyrics(context, track),
        ),
        IconButton(
          iconSize: size,
          icon: const Icon(Icons.library_add_outlined),
          tooltip: 'Add to playlist',
          onPressed: () => addToPlaylistSheet(context, app, track),
        ),
        if (OfflineStore.supported) _KeepButton(app: app, track: track, size: size),
        IconButton(
          iconSize: size,
          icon: Icon(app.sleepSet ? Icons.bedtime : Icons.timer_outlined),
          tooltip: 'Sleep timer and speed',
          onPressed: () => showPlaybackExtras(context),
        ),
        IconButton(
          iconSize: size,
          icon: const Icon(Icons.more_vert),
          tooltip: 'Track actions',
          onPressed: () => showTrackSheet(context, track, onChanged: app.refresh),
        ),
      ],
    );
  }
}

/// Keeping this song on the device, as one button that knows which of the three
/// things it is: not here, on its way, or here.
class _KeepButton extends StatelessWidget {
  const _KeepButton(
      {required this.app, required this.track, required this.size});
  final AppState app;
  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<AppState>().offline;
    final here = offline.has(track.id);
    final coming = offline.isQueued(track.id);
    return IconButton(
      iconSize: size,
      icon: Icon(here
          ? Icons.download_done
          : coming
              ? Icons.downloading
              : Icons.download_outlined),
      tooltip: here
          ? 'Kept on this device'
          : coming
              ? 'Being kept…'
              : 'Keep on this device',
      onPressed: () =>
          here ? app.forgetOffline(track.id) : app.keepOffline([track]),
    );
  }
}

/// Play and pause, as one shape that turns into the other.
///
/// Two icons swapped is a flicker at the exact moment somebody is looking at the
/// button they just pressed; the same triangle folding into two bars is the button
/// answering. Material ships the drawing, so this is the animation and the tick that
/// goes with it.
class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton(
      {required this.playing,
      required this.size,
      required this.onPressed,
      this.busy = false});
  final bool playing;
  final double size;
  final VoidCallback onPressed;

  /// Asked to play and waiting on the network: a thin ring turns around the button,
  /// so a silent second is visibly the stream opening rather than the button ignored.
  final bool busy;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shape = AnimationController(
    vsync: this,
    duration: Motion.quick,
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(_PlayPauseButton old) {
    super.didUpdateWidget(old);
    if (old.playing == widget.playing) return;
    // Straight there when the phone has asked for stillness: the icon still has to
    // change, it just does not travel.
    if (stillness(context)) {
      _shape.value = widget.playing ? 1 : 0;
    } else {
      widget.playing ? _shape.forward() : _shape.reverse();
    }
  }

  @override
  void dispose() {
    _shape.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = IconButton.filled(
      iconSize: widget.size,
      tooltip: widget.playing ? 'Pause' : 'Play',
      icon: AnimatedIcon(
        icon: AnimatedIcons.play_pause,
        progress: _shape,
        size: widget.size,
      ),
      onPressed: felt(Feel.commit, widget.onPressed),
    );
    if (!widget.busy) return button;
    // IconButton.filled pads the icon by 8 on each side; the ring sits just outside.
    final ring = widget.size + 22;
    return Stack(
      alignment: Alignment.center,
      children: [
        button,
        IgnorePointer(
          child: SizedBox(
            width: ring,
            height: ring,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Repeat, wherever it is shown: off, the whole queue, or this one song.
class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.app, this.size = 22});
  final AppState app;
  final double size;

  @override
  Widget build(BuildContext context) {
    final repeat = app.player?.repeat ?? QueueRepeat.off;
    return IconButton(
      iconSize: size,
      icon: Icon(repeat == QueueRepeat.one ? Icons.repeat_one : Icons.repeat),
      isSelected: repeat != QueueRepeat.off,
      color: repeat != QueueRepeat.off
          ? Theme.of(context).colorScheme.primary
          : null,
      tooltip: switch (repeat) {
        QueueRepeat.off => 'Repeat off',
        QueueRepeat.all => 'Repeat queue',
        QueueRepeat.one => 'Repeat track',
      },
      onPressed: app.cycleRepeat,
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork(
      {required this.track,
      this.snapshot,
      required this.player,
      required this.app,
      this.shrink = 1.0});
  final Track track;
  final PlayerSnapshot? snapshot;
  final PlayerService player;
  final AppState app;

  /// How much smaller than the listener's own setting to stand.
  ///
  /// The size of the record is a choice made for a phone, where the record is the
  /// screen. In the column beside a page it has 340 pixels to live in, and a record
  /// that fills them leaves its own title nowhere to go — so the panel asks for a
  /// smaller one rather than quietly changing what the setting means.
  final double shrink;

  /// The record either side of this one, so the queue is something you can see rather
  /// than something you have to remember. Read from the player's own list.
  Track? _at(int offset) {
    final items = player.items;
    final i = (snapshot?.index ?? 0) + offset;
    return i >= 0 && i < items.length ? items[i] : null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth;
        if (context.watch<AppState>().coverStyle == CoverStyle.flat) {
          // Just the cover: still, square, and the whole width of the stage. Square
          // corners on purpose — a record sleeve has corners, and rounding them off
          // makes the art look like an app icon of itself.
          final cover =
              Artwork(track: track, size: side * shrink, radius: 0, small: false);
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: cover,
                ),
                // The same barely-there surface the record stands on.
                Mirror(size: side, child: cover),
              ],
            ),
          );
        }

        // No clip and no shadow of our own: the pieces carry their own, and a rounded
        // rectangle around them would cut the disc off as it slides out.
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: RecordStage(
              track: track,
              playing: app.musicIsPlaying,
              scale: context.watch<AppState>().coverScale * shrink,
              armStyle: context.watch<AppState>().armStyle,
              discScale: context.watch<AppState>().discScale,
              axis: context.watch<AppState>().shelfAxis,
              previous: _at(-1),
              next: _at(1),
              // Two either side as well: a journey held halfway by a finger shows the
              // fourth sleeve at the edge of the frame, and it should be the right one.
              before: _at(-2),
              after: _at(2),
              // Through the app: a swipe in a jam asks the room, like every other
              // way of changing track.
              onPrevious: context.read<AppState>().skipPrevious,
              onNext: context.read<AppState>().skipNext,
              board: context.read<AppState>().sleeveBoard,
            ),
          ),
        );
      },
    );
  }
}

/// The bar and the two times, with its own line to the player.
///
/// Everything else on this screen is drawn from the coarse stream; the clock is the
/// one thing that genuinely changes several times a second, so it listens for itself
/// and repaints nothing but itself.
/// The pens, while the record is face-down.
///
/// Takes the place of the words rather than sitting beside them, because while you are
/// drawing on a sleeve the title of the song is not what you are looking at — and
/// because anything that appears *in addition* moves everything under it, which is the
/// thing this screen has just stopped doing.
class _SleeveTools extends StatelessWidget {
  const _SleeveTools({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app.sleeveBoard,
      builder: (context, _) {
        final board = app.sleeveBoard;
        // Two conditions, not one. A board can only be open because a record is turned
        // over, and a record can only be turned over on the stage that draws records —
        // so the pens have no business appearing beside a flat cover, whatever the
        // board happens to think.
        if (!board.open01 || app.coverStyle != CoverStyle.record) {
          return const SizedBox.shrink();
        }
        final jam = app.jam;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SleevePalette(
            ink: board.ink,
            width: board.nib,
            onInk: board.pickInk,
            onWidth: board.pickNib,
            // The board is the host's in a jam, and clearing it is theirs alone.
            onWipe: jam == null || jam.isHost ? board.wipe : null,
            onTurnBack: board.onTurnBack,
          ),
        );
      },
    );
  }
}

/// What is playing, at whichever size the screen has room for.
///
/// Face up, the full thing: title over artist over album, with room reserved for all
/// of it. Turned over, one quiet line — the record is a third larger and is the thing
/// being looked at, and three lines of credits under a board somebody is drawing on is
/// the screen talking over them. It is still there, because knowing what is playing is
/// not optional; it is just said in a sentence rather than a stack.
/// What is playing, in a column beside the page rather than over it.
///
/// On a desk there is room for the record to be on screen while you are doing
/// something else, which is what every player on a desk does and what the phone
/// layout has no way to offer: there, opening the player means covering everything.
/// The parts are the same parts — the same artwork, the same words, the same bar and
/// the same buttons — laid out narrow and tall.
class DeskNowPlaying extends StatelessWidget {
  const DeskNowPlaying({super.key, this.onClose});

  /// Folding the panel away again.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = app.player;
    if (player == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;

    return StreamBuilder<PlayerSnapshot>(
      stream: player.changes,
      initialData: player.last,
      builder: (context, snap) {
        final s = snap.data;
        final track = s?.current ?? player.current;
        if (track == null) {
          return Center(
            child: Text('Nothing playing', style: text.bodyMedium),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(app.activeQueue?.name ?? 'Now playing',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall),
                  ),
                  IconButton(
                    icon: const Icon(Icons.open_in_full, size: 18),
                    tooltip: 'Open the player',
                    onPressed: () => Navigator.of(context, rootNavigator: true)
                        .push(nowPlayingRoute()),
                  ),
                  if (onClose != null)
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      tooltip: 'Hide',
                      onPressed: onClose,
                    ),
                ],
              ),
            ),
            // The record, with room around it. It used to be handed the whole width
            // of the panel at the size a phone uses, and a record that big in a column
            // this narrow spills out of its own box and sits on top of the title
            // underneath.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
              child: AspectRatio(
                aspectRatio: 1,
                child: _Artwork(
                    track: track,
                    snapshot: s,
                    player: player,
                    app: app,
                    shrink: 0.78),
              ),
            ),
            const SizedBox(height: 14),
            _Words(app: app, track: track),
            const SizedBox(height: 6),
            _Scrubber(player: player, timesBeside: true),
            const SizedBox(height: 2),
            _Controls(app: app, player: player, snapshot: s),
            const SizedBox(height: 2),
            _Extras(app: app, track: track, spread: true),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }
}

class _Words extends StatelessWidget {
  const _Words({required this.app, required this.track});
  final AppState app;
  final Track track;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app.sleeveBoard,
      builder: (context, _) {
        final flipped = app.sleeveBoard.open01 &&
            app.coverStyle == CoverStyle.record;
        if (!flipped) {
          return Column(
            children: [
              // Two lines' worth of room whether or not the title needs two. The
              // artwork sits above this in a centred column, so a title that wrapped
              // used to shove the record up the screen — and going from one song to
              // the next moved the picture as much as it changed it.
              _TitleBlock(title: track.displayTitle),
              // One thing said in two lines, so no gap at all between them.
              _Credits(track: track),
            ],
          );
        }
        final scheme = Theme.of(context).colorScheme;
        final said = [
          track.displayTitle,
          track.artistLine,
          if (track.albumLine != null) track.albumLine!,
        ].join('  ·  ');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            said,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
          ),
        );
      },
    );
  }
}

/// The song's name, in a box that is always two lines tall.
///
/// The height is worked out from the type rather than guessed, so it holds whatever
/// the text scale is set to. Top-aligned: a one-line title sits where the first line
/// of a two-line one does, which is what stops the words moving as well as the record.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    // One line, always, and it walks if it is too long for the row.
    //
    // Two lines' worth of room whether or not the title needed two left an empty line
    // under most songs; letting it wrap instead made the block a different height for
    // every song, and this block is above the record in a centred column — so the
    // picture moved as much as it changed on every track. One line is one height, and
    // the long names are still readable because they go past rather than being cut.
    return BackAndForth(title,
        style: Theme.of(context).textTheme.headlineSmall);
  }
}

class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.player, this.timesBeside = false, this.on});
  final PlayerService player;

  /// Elapsed and total at either end of the bar rather than underneath it.
  final bool timesBeside;

  /// What sits on the bar — the spectrum, where it is switched on.
  ///
  /// Passed in here rather than stacked above the whole panel so that it lines up
  /// with the track itself: above the panel it spanned the times as well, which put a
  /// band of moving bars over two numbers somebody is trying to read.
  final Widget? on;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: StreamBuilder<PlayerSnapshot>(
          stream: player.snapshots,
          initialData: player.last,
          builder: (context, snap) => _ScrubberBar(
              player: player,
              snapshot: snap.data,
              timesBeside: timesBeside,
              on: on),
        ),
      );
}

class _ScrubberBar extends StatefulWidget {
  const _ScrubberBar(
      {required this.player,
      required this.snapshot,
      this.timesBeside = false,
      this.on});
  final PlayerService player;
  final PlayerSnapshot? snapshot;
  final bool timesBeside;
  final Widget? on;

  @override
  State<_ScrubberBar> createState() => _ScrubberState();
}

class _ScrubberState extends State<_ScrubberBar>
    with SingleTickerProviderStateMixin {
  double? _dragging;   // while the thumb is held, the UI follows the finger

  /// The clock, run between reports.
  ///
  /// Position arrives four times a second, so the thumb moved in four steps a second
  /// and the time under it counted in quarter-seconds. The engine is not being asked
  /// more often — it is the same four reports, with the seconds between them filled in
  /// from the wall clock, which is what "the music is still playing" actually means.
  /// Only the bar rebuilds: everything else on the player takes the coarse stream.
  late final Ticker _clock = createTicker((_) {
    if (mounted) setState(() {});
  });

  /// What the engine last said, and when it said it.
  Duration _said = Duration.zero;
  DateTime _saidAt = DateTime.now();

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  /// Where the music is now: the last report plus however long ago it was.
  Duration _now(Duration reported, bool playing, Duration duration) {
    if (reported != _said) {
      _said = reported;
      _saidAt = DateTime.now();
    }
    // Held still while paused, while a finger is on the bar, and where the phone has
    // been asked not to animate — a clock that runs on its own through a pause is a
    // clock that is lying.
    if (!playing || _dragging != null || _seeking != null || stillness(context)) {
      if (_clock.isTicking) _clock.stop();
      return reported;
    }
    if (!_clock.isTicking) _clock.start();
    final since = DateTime.now().difference(_saidAt);
    final ahead = reported + since;
    return ahead > duration && duration > Duration.zero ? duration : ahead;
  }

  /// Where a seek was aimed, until the engine reports having got there.
  ///
  /// Letting go used to drop straight back to whatever the last snapshot said, which
  /// for a stream is the *old* position for as long as the seek takes — so the thumb
  /// sprang back to where it started and then jumped forward a moment later. Holding
  /// the target keeps the bar where the finger left it.
  double? _seeking;
  DateTime? _seekAt;

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final app = context.watch<AppState>();

    // The engine only knows a duration once it has read the file's header. The track
    // itself has always known, so a bar that is dead for the first second of every
    // song was only ever asking the wrong one of the two.
    var duration = s?.duration ?? Duration.zero;
    if (duration == Duration.zero) duration = s?.current?.duration ?? Duration.zero;

    // Whichever clock is actually running the music.
    //
    // A guest playing along on their own device has its own engine and that is the one
    // to draw. A guest who is only listening to the room has no engine running at all,
    // so the host's reported position is not a fallback for it — it *is* the clock,
    // and treating it as a fallback meant the bar sat at zero through a song they
    // could hear, because the silent engine was perfectly happy to report zero.
    var position = app.positionNow ?? s?.position ?? Duration.zero;
    if (position == Duration.zero) {
      position = app.hostPosition ?? s?.position ?? Duration.zero;
    }

    position = _now(position, app.musicIsPlaying, duration);
    final max = duration.inMilliseconds.toDouble();

    // A seek is finished when the engine reports somewhere near where we sent it, or
    // when it has had long enough that something must have gone wrong.
    if (_seeking != null) {
      final settled = (position.inMilliseconds - _seeking!).abs() < 1500 ||
          DateTime.now().difference(_seekAt ?? DateTime.now()) >
              const Duration(seconds: 3);
      if (settled) {
        _seeking = null;
        _seekAt = null;
      } else {
        position = Duration(milliseconds: _seeking!.round());
      }
    }

    // Dragging is allowed whenever it will reach the room: the host always, a guest
    // when the host has left the controls open. A guest who cannot control the room
    // would only move their own device out of step with it.
    final enabled = max > 0 && (!app.isJamGuest || app.jamControlsTheRoom);
    // In a jam the host is the one playing, so the clock runs from their reports even
    // though this device's own engine is silent — otherwise a guest watches a bar that
    // never moves through a song they can hear perfectly well.
    final playing =
        app.musicIsPlaying && _dragging == null && _seeking == null;

    return SmoothPosition(
      position: position,
      playing: playing,
      duration: duration,
      speed: widget.player.speed,
      builder: (context, at) {
        final value =
            (_dragging ?? at.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 1.0 : max);
        final bar = Pulse(
          // The last song in the queue, said quietly on the one thing that is already
          // about how much is left.
          on: widget.snapshot?.lastInQueue ?? false,
          child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: enabled ? 7 : 4),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: max > 0 ? value : 0,
            max: max > 0 ? max : 1,
            // Taking hold of the bar and letting go of it are both worth saying: a
            // scrub is the one gesture here where the finger is somewhere the eye is
            // not, because the eye is on the time.
            onChangeStart: enabled ? (_) => feel(Feel.pick) : null,
            onChanged: enabled ? (v) => setState(() => _dragging = v) : null,
            onChangeEnd: enabled
                ? (v) {
                    feel(Feel.commit);
                    app.seekTo(Duration(milliseconds: v.round()));
                    setState(() {
                      _seeking = v;
                      _seekAt = DateTime.now();
                      _dragging = null;
                    });
                  }
                : null,
          ),
        ),
        );
        final elapsed = Text(formatTime(Duration(milliseconds: value.round())),
            style: Theme.of(context).textTheme.labelMedium);
        final total = Text(max > 0 ? formatTime(duration) : '--:--',
            style: Theme.of(context).textTheme.labelMedium);

        // Beside the bar rather than under it: a line less, and the two numbers read
        // as the ends of the thing they belong to.
        // At the two ends of the bar, where they were — but held off the walls.
        //
        // Hard against the edge they read as part of the frame rather than as the two
        // ends of the thing above them.
        // The spectrum stands on the bar, so it is stacked with it and with nothing
        // else: the same width, the same place, whichever way the times are laid out.
        final overBar = widget.on == null
            ? bar
            : Column(mainAxisSize: MainAxisSize.min, children: [widget.on!, bar]);

        if (widget.timesBeside) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Padding(
                      padding: const EdgeInsets.only(bottom: 14), child: elapsed),
                  Expanded(child: overBar),
                  Padding(padding: const EdgeInsets.only(bottom: 14), child: total),
                ]),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            overBar,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [elapsed, total],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls(
      {required this.app,
      required this.player,
      required this.snapshot,
      this.big = false,
      this.bare = false});
  final AppState app;
  final PlayerService player;
  final PlayerSnapshot? snapshot;

  /// The roomy arrangement: same controls, more of them under the thumb.
  final bool big;

  /// Volume at one end and the equaliser-ish extras at the other, with shuffle and
  /// repeat left to the row above — the plain arrangement's transport.
  final bool bare;

  @override
  Widget build(BuildContext context) {
    // What the room is doing. A guest listening to somebody else's speaker can hear
    // the song; a play button on a song they can hear is simply wrong, and pressing it
    // asks the room to pause, which is what the button under their thumb should say.
    final playing = app.musicIsPlaying;
    final repeat = snapshot?.repeat ?? QueueRepeat.off;

    if (bare) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 24,
              icon: Icon(app.player?.userVolume == 0
                  ? Icons.volume_off
                  : Icons.volume_up),
              tooltip: 'Volume',
              onPressed: () => showVolume(context, player),
              onLongPress: app.toggleMute,
            ),
            IconButton(
              iconSize: 44,
              icon: const Icon(Icons.skip_previous),
              onPressed: felt(Feel.commit, app.skipPrevious),
            ),
            _PlayPauseButton(
                playing: playing,
                size: 56,
                busy: snapshot?.buffering ?? false,
                onPressed: app.playPause),
            IconButton(
              iconSize: 44,
              icon: const Icon(Icons.skip_next),
              onPressed: felt(Feel.commit, app.skipNext),
            ),
            IconButton(
              iconSize: 24,
              icon: Icon(app.sleepSet ? Icons.bedtime : Icons.timer_outlined),
              tooltip: 'Sleep timer and speed',
              onPressed: () => showPlaybackExtras(context),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: big ? 10 : 0),
      child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: const Icon(Icons.shuffle),
          tooltip: 'Shuffle what is coming',
          onPressed: app.shuffleWhatIsComing,
        ),
        IconButton(
          iconSize: big ? 42 : 34,
          icon: const Icon(Icons.skip_previous),
          onPressed: felt(Feel.commit, app.skipPrevious),
        ),
        _PlayPauseButton(
            playing: playing,
            size: big ? 54 : 42,
            busy: snapshot?.buffering ?? false,
            onPressed: app.playPause),
        IconButton(
          iconSize: big ? 42 : 34,
          icon: const Icon(Icons.skip_next),
          onPressed: felt(Feel.commit, app.skipNext),
        ),
        IconButton(
          icon: Icon(repeat == QueueRepeat.one ? Icons.repeat_one : Icons.repeat),
          isSelected: repeat != QueueRepeat.off,
          color: repeat != QueueRepeat.off
              ? Theme.of(context).colorScheme.primary
              : null,
          tooltip: switch (repeat) {
            QueueRepeat.off => 'Repeat off',
            QueueRepeat.all => 'Repeat queue',
            QueueRepeat.one => 'Repeat track',
          },
          onPressed: app.cycleRepeat,
        ),
      ],
    ),
    );
  }
}

/// Volume, as a sheet, for the arrangement that has no room for a slider of its own.
Future<void> showVolume(BuildContext context, PlayerService player) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: _VolumeRow(player: player),
        ),
      ),
    );

class _VolumeRow extends StatefulWidget {
  const _VolumeRow({required this.player});
  final PlayerService player;

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  double? _value;

  @override
  Widget build(BuildContext context) {
    // The web build has no hardware volume to fall back on, so the app needs its own.
    final v = _value ?? widget.player.userVolume;
    return Row(
      children: [
        Icon(v == 0 ? Icons.volume_off : Icons.volume_down,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        Expanded(
          child: Slider(
            value: v,
            onChanged: (nv) {
              setState(() => _value = nv);
              context.read<AppState>().setVolume(nv);
            },
            // Back to reading the player once the finger is off it, or muting from
            // the keyboard left the slider showing the volume from before.
            onChangeEnd: (_) => setState(() => _value = null),
          ),
        ),
        Icon(Icons.volume_up,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ],
    );
  }
}

/// Sleep timer and playback speed: the two things you reach for at either end of a
/// listening session, and the two the player was missing.
Future<void> showPlaybackExtras(BuildContext context) async {
  final app = context.read<AppState>();
  await showModalBottomSheet<void>(
   useRootNavigator: true,
    context: context,
    showDragHandle: true,
    builder: (sheet) => _PlaybackExtras(app: app),
  );
}

class _PlaybackExtras extends StatefulWidget {
  const _PlaybackExtras({required this.app});
  final AppState app;

  @override
  State<_PlaybackExtras> createState() => _PlaybackExtrasState();
}

class _PlaybackExtrasState extends State<_PlaybackExtras> {
  /// The countdown moves while the sheet is open, rather than saying "31 min" until
  /// something else happens to rebuild it.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _left(Duration left) {
    if (left.inMinutes >= 1) return 'Stops in ${left.inMinutes + 1} min';
    return 'Stopping in under a minute';
  }

  @override
  Widget build(BuildContext sheet) {
    final app = widget.app;
    final left = app.sleepIn;
    return AnimatedBuilder(
      animation: app,
      builder: (sheet, _) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                child: Text('Sleep timer',
                    style: Theme.of(sheet).textTheme.titleSmall),
              ),
              if (app.sleepAtEndOfTrack)
                ListTile(
                  leading: const Icon(Icons.bedtime),
                  title: const Text('Stops when this song ends'),
                  subtitle: const Text('Fading out over its last seconds'),
                  trailing: TextButton(
                    onPressed: () => app.setSleepTimer(null),
                    child: const Text('Cancel'),
                  ),
                )
              else if (left != null && !left.isNegative)
                ListTile(
                  leading: const Icon(Icons.bedtime),
                  title: Text(_left(left)),
                  subtitle: const Text('The music fades out before it stops'),
                  trailing: TextButton(
                    onPressed: () => app.setSleepTimer(null),
                    child: const Text('Cancel'),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final minutes in [15, 30, 45, 60, 90])
                        OutlinedButton(
                          onPressed: () =>
                              app.setSleepTimer(Duration(minutes: minutes)),
                          child: Text('$minutes min'),
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.music_off_outlined, size: 18),
                        label: const Text('End of this song'),
                        onPressed: () => app.setSleepTimer(null, endOfTrack: true),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                child: Text('Playback speed',
                    style: Theme.of(sheet).textTheme.titleSmall),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final rate in [0.75, 1.0, 1.25, 1.5, 2.0])
                      ChoiceChip(
                        selected: (app.player?.speed ?? 1.0) == rate,
                        label: Text(rate == 1.0 ? 'Normal' : '$rate×'),
                        onSelected: (_) async {
                          await app.player?.setSpeed(rate);
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
    );
  }
}
