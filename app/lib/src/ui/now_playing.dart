import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
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
import 'devices_sheet.dart';
import 'dialogs.dart';
import 'feel.dart';
import 'glass.dart';
import 'motion.dart';
import 'queue_page.dart' show openQueueScreen;
import 'record_stage.dart';
import 'sleeve_ink.dart';
import 'stage/arm_grip.dart';
import 'spectrum.dart';
import 'lyrics_sheet.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'mirror_ball.dart';
import 'track_menu.dart';
import 'song_row.dart';
import 'browse_page.dart';
import 'home_page.dart';
import 'jam_page.dart';
import 'halftone.dart';
import 'progress.dart';
import 'pulse.dart';
import 'open_from.dart';
import 'widths.dart';
import 'equalizer_page.dart';
import 'beat_pulse.dart';
import 'booth_page.dart';

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

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  /// The room's light, shared between the layer that makes it and the record and
  /// the glass that stand in it.
  final _room = RoomLight();

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_openedOnce) {
      _openedOnce = true;
      PlaybackLog.note('player screen opened');
    }
    final app = context.watch<AppState>();
    final player = app.player;
    if (player == null) return const SizedBox.shrink();

    // The whole player is where the arm can be picked up from: see ArmReach.
    return RoomLightScope(light: _room, child: ArmReach(child: StreamBuilder<PlayerSnapshot>(
      // Coarse on purpose. The record turning, the disc sliding out and the printed
      // background are animations with their own clocks; rebuilding the screen under
      // them four times a second is what made them stutter. The scrubber keeps its own
      // fine-grained subscription — see _Scrubber.
      stream: player.changes,
      initialData: player.last,
      builder: (context, snap) {
        final s = snap.data;
        final track = s?.current ?? player.current;

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
            // The queue's name, and the way into it: what plays after this.
            title: app.jam == null
                ? InkWell(
                    onTap: () => openQueueScreen(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text(app.activeQueue?.name ?? 'Now playing',
                          style: Theme.of(context).textTheme.titleSmall),
                    ),
                  )
                : _JamTitle(app: app),
            centerTitle: true,
            // Where these live is a setting: the top corners are furthest from a
            // thumb, which is why they moved, but it is also the arrangement people
            // knew — so it is still here to choose.
            //
            // Which device the sound comes out of is not one of them. It belongs to
            // the screen rather than to the song, every arrangement needs it, and a
            // button that exists in two of the four layouts is a button nobody can
            // find — which is exactly what happened.
            actions: [
              // Up next: the queue, which used to be a tab of its own and belongs to
              // what is playing.
              IconButton(
                icon: const Icon(Icons.queue_music),
                tooltip: 'Up next',
                onPressed: () => openQueueScreen(context),
              ),
              const WhereItPlays(compact: true),
              // The booth: the same records, mixed by hand. Only once it is switched
              // on in Settings, while it is early.
              if (app.boothOn)
                IconButton(
                  icon: const Icon(Icons.album_outlined),
                  tooltip: 'The booth',
                  onPressed: () => Navigator.of(context, rootNavigator: true)
                      .push(MaterialPageRoute(builder: (_) => const BoothPage())),
                ),
              ...(app.playerLayout == PlayerLayout.topBar && track != null
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
                : const <Widget>[]),
            ],
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
                    builder: (context) => BeatPulse(
                      app: app,
                      track: track,
                      builder: (context, beat) => HalftoneBackdrop(
                        colour: parseHexColour(track?.coverColor),
                        // What the room is doing, not what this device's own engine
                        // is: a guest listening to somebody else's speaker can hear
                        // the music, and a still background says it has stopped.
                        playing: app.musicIsPlaying,
                        loudnessDb: track?.loudnessLufs,
                        beat: beat,
                      ),
                    ),
                  )
                : null,
            child: track == null
              ? const Center(child: Text('Nothing playing'))
              : Stack(
                  children: [
                    Positioned.fill(child: SafeArea(
                  child: Builder(builder: (context) {
                    // The record, and everything that is said under it. On a phone
                    // that is one column, which is what the whole of this screen has
                    // always been. On a desk the two go side by side: a record blown
                    // up to nine hundred pixels tall is not a bigger record, it is a
                    // title pushed off the bottom of the window.
                    final record = <Widget>[

                            // Room above the record: a little, always. The rest of
                            // whatever the screen has spare is above this too — the
                            // column stands on the bar at the bottom, see below — and
                            // the record's own box now holds the arm and the top of
                            // the disc, so neither can be under the header whatever
                            // this is.
                            const SizedBox(height: 8),
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
                            // The box above already keeps the sleeve's bottom edge
                            // inside itself; this is the air between that edge and
                            // the song's name, where the reflection fades out.
                            SizedBox(
                                height: app.playerLayout == PlayerLayout.roomy
                                    ? 12
                                    : 22),
                    ];
                    final said = <Widget>[
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
                                opacity: 0.42,
                                blur: 36,
                                sheen: true,
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
                                opacity: 0.42,
                                blur: 36,
                                sheen: true,
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
                            // Air under the panel: enough that the volume slider and
                            // the bar with the three places in it are not two rows of
                            // controls touching, and no more — the rest of the room
                            // goes over the record, where the arm's post is.
                            const SizedBox(height: 6),
                    ];

                    if (Width.of(context) != Width.expanded) {
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Padding(
                            // Plain runs its panel almost to the walls, so the page's
                            // own margin gets out of the way and the words inside keep
                            // theirs.
                            padding: EdgeInsets.symmetric(
                                horizontal: app.playerLayout == PlayerLayout.plain
                                    ? 8
                                    : 24),
                            child: Column(
                              // Standing on the bar. Centred, whatever the screen
                              // had spare was split above and below, and the half
                              // below sat between the controls and the bar as a
                              // strip of nothing — while the arm's post was up
                              // against the header. The controls are what a thumb
                              // reaches for; they belong at the bottom, and the air
                              // belongs over the record.
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [...record, ...said],
                            ),
                          ),
                        ),
                      );
                    }

                    return Center(
                      child: ConstrainedBox(
                        // Wider, and with less of a margin inside it: the two columns
                        // want the room more than the walls do.
                        constraints: const BoxConstraints(maxWidth: 1440),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // The record keeps its own square: it is the thing on
                              // the screen, and it should be as big as the shorter
                              // side of the window allows rather than as wide as half
                              // of a very wide one.
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: record,
                                ),
                              ),
                              const SizedBox(width: 40),
                              Expanded(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 620),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: said,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                )),
                    // What the player has to say for itself — loading, waiting for
                    // a download, a stream that failed — in the air above the record.
                    //
                    // It was a row between the words and the controls, and a row that
                    // comes and goes moves everything around it: every skip is a
                    // moment of "Loading…", so every skip shoved the record up and let
                    // it drop again. Laid over the page it takes no room, and so
                    // nothing moves when it arrives or when it leaves.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        bottom: false,
                        child: IgnorePointer(
                          child: _StatusSlip(status: _statusLine(s, track)),
                        ),
                      ),
                    ),
                    // The disco ball's light, over everything and taking nothing:
                    // spots of it swinging across the page while the song plays.
                    if (app.discoLights)
                      Positioned.fill(
                        child: BeatPulse(
                          app: app,
                          track: track,
                          builder: (context, pulse) => MirrorBallLight(
                            playing: app.musicIsPlaying,
                            tint: parseHexColour(track.coverColor),
                            pulse: pulse,
                          ),
                        ),
                      ),
                  ],
                ),
          ),
          ),
        );
      },
    )));
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

/// A slip of paper with the player's state typed on it, fading in and out.
class _StatusSlip extends StatelessWidget {
  const _StatusSlip({required this.status});
  final ({String text, bool problem})? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final said = status;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: said == null
          ? const SizedBox(key: ValueKey('nothing'), height: 0)
          : Padding(
              key: ValueKey(said.text),
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(
                        color: (said.problem ? scheme.error : scheme.onSurface)
                            .withValues(alpha: 0.35)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    child: Text(
                      said.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Mag.typewriter(11.5,
                          color: said.problem
                              ? scheme.error
                              : scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
    );
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
    // Set the way a magazine credits a record: the artist in spaced capitals under
    // the title, the record's name typed under that.
    final style = Mag.flag(12, color: scheme.onSurface);

    Widget link(String label, VoidCallback onTap, {TextStyle? own}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: BackAndForth(label,
                style: (own ?? style).copyWith(
                    decoration: TextDecoration.underline,
                    decorationColor:
                        scheme.onSurfaceVariant.withValues(alpha: 0.4))),
          ),
        );

    final albumStyle =
        Mag.typewriter(12.5, color: scheme.onSurfaceVariant.withValues(alpha: 0.85));

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
          track.artistLine.toUpperCase(),
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
          // Which of your devices the sound is coming out of. Beside the transport
          // because that is what it is about, and because the question it answers —
          // "why is nothing coming out of this laptop" — is asked while looking at it.
     //      WhereItPlays( compact: true, size: size),
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
///
/// The button itself is a piece of hardware: a brushed steel disc set into a dark
/// bezel, with a ring of light round it in the edition's colour — lit while the music
/// plays, low while it does not, and running round the ring while the stream opens.
class PlayPauseButton extends StatefulWidget {
  const PlayPauseButton(
      {super.key,
      required this.playing,
      required this.size,
      required this.onPressed,
      this.busy = false,
      this.beat});
  final bool playing;
  final double size;
  final VoidCallback onPressed;

  /// Asked to play and waiting on the network: a brighter arc travels round the ring,
  /// so a silent second is visibly the stream opening rather than the button ignored.
  final bool busy;

  /// The song's beat, one on it and falling to nothing: the ring's glow breathes with
  /// it, a little. Null and it holds steady.
  final ValueListenable<double>? beat;

  @override
  State<PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<PlayPauseButton> with TickerProviderStateMixin {
  late final AnimationController _shape = AnimationController(
    vsync: this,
    duration: Motion.quick,
    value: widget.playing ? 1 : 0,
  );

  /// How lit the ring is: up in a third of a second when the music starts, down a
  /// little slower when it stops.
  late final AnimationController _lit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 520),
    value: widget.playing ? 1 : 0,
  );

  /// The arc running round the ring while the stream opens.
  late final AnimationController _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.busy) _run.repeat();
  }

  @override
  void didUpdateWidget(PlayPauseButton old) {
    super.didUpdateWidget(old);
    if (old.busy != widget.busy) {
      if (widget.busy && !stillness(context)) {
        _run.repeat();
      } else {
        _run.stop();
        _run.value = 0;
      }
    }
    if (old.playing == widget.playing) return;
    // Straight there when the phone has asked for stillness: the icon still has to
    // change, it just does not travel.
    if (stillness(context)) {
      _shape.value = widget.playing ? 1 : 0;
      _lit.value = widget.playing ? 1 : 0;
    } else {
      widget.playing ? _shape.forward() : _shape.reverse();
      widget.playing ? _lit.forward() : _lit.reverse();
    }
  }

  @override
  void dispose() {
    _shape.dispose();
    _lit.dispose();
    _run.dispose();
    super.dispose();
  }

  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // One footprint, whatever is happening: the ring's glow has its room kept whether
    // it is lit or not, so the row of controls never twitches on a skip.
    final whole = widget.size + 24;
    final still = stillness(context);
    return Semantics(
      button: true,
      label: widget.playing ? 'Pause' : 'Play',
      excludeSemantics: true,
      child: Tooltip(
        message: widget.playing ? 'Pause' : 'Play',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: felt(Feel.commit, widget.onPressed),
          child: AnimatedScale(
            scale: _down ? 0.96 : 1,
            duration: still ? Duration.zero : const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: SizedBox.square(
              dimension: whole,
              child: CustomPaint(
                painter: _ButtonFace(
                  colour: scheme.primary,
                  pressed: _down,
                  dark: Theme.of(context).brightness == Brightness.dark,
                  lit: _lit,
                  running: _run,
                  busy: widget.busy,
                  beat: widget.beat,
                ),
                child: Center(
                  child: AnimatedIcon(
                    icon: AnimatedIcons.play_pause,
                    progress: _shape,
                    size: whole * 0.40,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The play button's face: a brushed steel disc in a dark bezel, ringed with light.
///
/// From the outside in: the bezel, a dark moulded ring lit from above; the ring of
/// light, a neon tube in the edition's colour with its bloom on the bezel either side
/// of it; the disc, steel brushed in circles, which is why it is bright at two corners
/// and dark at the other two — a brushed surface throws the lamp back along its
/// grooves, and the grooves run round; and a hairline of shadow where the disc is set
/// into the bezel. Held down, the disc sinks and the ring dims; while the stream
/// opens, a brighter arc runs round the ring; and on the beat the bloom breathes.
class _ButtonFace extends CustomPainter {
  _ButtonFace({
    required this.colour,
    required this.pressed,
    required this.dark,
    required this.lit,
    required this.running,
    required this.busy,
    this.beat,
  }) : super(repaint: Listenable.merge([lit, running, if (beat != null) beat]));

  final Color colour;
  final bool pressed;
  final bool dark;
  final Animation<double> lit;
  final Animation<double> running;
  final bool busy;
  final ValueListenable<double>? beat;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    // The bezel's outer edge leaves room for the bloom; the ring sits just inside.
    final bezel = radius * 0.86;
    final ring = radius * 0.80;
    final ringWidth = radius * 0.095;
    final disc = radius * 0.62;
    final on = lit.value;
    final pulse = (beat?.value ?? 0.0) * on;
    final glow = (0.22 + 0.78 * on) * (pressed ? 0.6 : 1.0);

    // What it stands on: a shadow it sinks into when pressed.
    final lift = pressed ? 0.4 : 1.0;
    canvas.drawCircle(
        c.translate(0, 3 * lift),
        bezel,
        Paint()
          ..color = Colors.black.withValues(alpha: (dark ? 0.6 : 0.28) * (0.6 + 0.4 * lift))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * lift + 2));

    // The bezel: dark, lit from above, with a bright lip along its top edge.
    final body = Rect.fromCircle(center: c, radius: bezel);
    canvas.drawCircle(
        c,
        bezel,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF2E2E32), Color(0xFF17171A), Color(0xFF0E0E10)]
                : const [Color(0xFFE9E7E3), Color(0xFFC9C6C0), Color(0xFFAAA69F)],
          ).createShader(body));
    canvas.drawCircle(
        c,
        bezel - 0.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: dark ? 0.28 : 0.9),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: dark ? 0.5 : 0.25),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(body));

    // The ring of light. Its bloom first, on the bezel either side; then the tube,
    // then the hot thread down its middle. Off, the tube is still there — a neon
    // tube unlit is glass with a little of its colour in it.
    final tube = Color.lerp(colour, Colors.white, 0.08)!;
    final hot = Color.lerp(colour, Colors.white, 0.55)!;
    final bloom = glow * (0.55 + 0.12 * pulse);
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth * 3.4
          ..color = colour.withValues(alpha: 0.8 * bloom)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.17));
    // The tube's edges: a hair of dark either side, which is what makes it a tube
    // rather than a line.
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth + 1.6
          ..color = Colors.black.withValues(alpha: dark ? 0.55 : 0.25));
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth
          ..color = Color.lerp(tube.withValues(alpha: 0.35), tube, glow)!);
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth * 0.42
          ..color = hot.withValues(alpha: 0.85 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, ringWidth * 0.25));
    // The stream opening: a brighter length of tube running round.
    if (busy) {
      final at = running.value * 2 * math.pi;
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: ring),
          at,
          math.pi * 0.55,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ringWidth * 1.1
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 0.75)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, ringWidth * 0.4));
    }

    // The seat: a hairline of shadow the disc sits down into.
    canvas.drawCircle(
        c,
        disc + 1.5,
        Paint()
          ..color = Colors.black.withValues(alpha: dark ? 0.7 : 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));

    // The disc: brushed steel. Circular brushing throws the light back in two lobes
    // opposite each other — bright top-left and bottom-right under a lamp from the
    // top-left — with the metal's own grey between.
    final face = Rect.fromCircle(center: c, radius: disc);
    final hi = dark ? 0.62 : 0.86, lo = dark ? 0.30 : 0.58;
    Color grey(double v) => Color.fromRGBO((255 * v).round(), (255 * v).round(), (255 * (v * 0.985)).round(), 1);
    canvas.drawCircle(
        c,
        disc,
        Paint()
          ..shader = SweepGradient(
            center: Alignment.center,
            startAngle: 0,
            endAngle: 2 * math.pi,
            transform: const GradientRotation(-math.pi * 0.25),
            colors: [grey(hi), grey(lo), grey(hi * 0.92), grey(lo * 1.1), grey(hi)],
            stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
          ).createShader(face));
    // The brushing itself: fine rings, a hair lighter and darker in turn, each a
    // little off in width — a lathe, not a printer.
    canvas.save();
    canvas.clipPath(Path()..addOval(face));
    final brush = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    var r = disc * 0.18;
    var i = 0;
    while (r < disc) {
      final h = ((i * 2654435761) & 0xFFFF) / 65535.0;
      brush.color = (i.isEven ? Colors.white : Colors.black).withValues(alpha: 0.035 + 0.05 * h);
      canvas.drawCircle(c, r, brush);
      r += 1.1 + 0.9 * h;
      i++;
    }
    // Pressed, the lamp catches it less; up, a soft sheen at the top.
    canvas.drawCircle(
        c,
        disc,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.5),
            radius: 0.9,
            colors: [
              Colors.white.withValues(alpha: pressed ? 0.04 : (dark ? 0.16 : 0.22)),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: pressed ? 0.30 : 0.18),
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(face));
    canvas.restore();
    // The disc's own turned edge: light above, dark below.
    canvas.drawCircle(
        c,
        disc - 0.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: pressed ? 0.15 : 0.5),
              Colors.white.withValues(alpha: 0.05),
              Colors.black.withValues(alpha: 0.35),
            ],
          ).createShader(face));
    // The ring's colour, caught faintly on the steel nearest it.
    canvas.drawCircle(
        c,
        disc - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = disc * 0.16
          ..color = colour.withValues(alpha: 0.10 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, disc * 0.08));
  }

  @override
  bool shouldRepaint(_ButtonFace old) =>
      old.colour != colour || old.pressed != pressed || old.dark != dark || old.busy != busy || old.beat != beat;
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
      required this.app});
  final Track track;
  final PlayerSnapshot? snapshot;
  final PlayerService player;
  final AppState app;

  /// The record either side of this one, so the queue is something you can see rather
  /// than something you have to remember. Read from the player's own list.
  Track? _at(int offset) {
    final items = player.items;
    final i = (snapshot?.index ?? 0) + offset;
    return i >= 0 && i < items.length ? items[i] : null;
  }

  /// How far the picture reaches above and below the stage's own square, as a
  /// fraction of its side.
  ///
  /// The stage is a square, and what is drawn on it is not: the record leans up out of
  /// the top of it by a sixth of the side, the arm's plinth stands a little higher
  /// still, and the sleeve's bottom edge hangs a little below. Laid out as a square
  /// those parts fell wherever the screen put them — the arm under the header's
  /// buttons on a phone, the record through the panel's title on a desk, and on a
  /// short phone the whole top of it cut off. So the box the stage is given is the
  /// height of the picture, and the square sits inside it where the picture fits.
  static const headroom = 0.24;
  static const footroom = 0.06;

  /// The box's height for a stage of this side, and the side a box of this height holds.
  static double boxFor(double side) => side * (1 + headroom + footroom);
  static double sideIn(double height) => height / (1 + headroom + footroom);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (context.watch<AppState>().coverStyle == CoverStyle.flat) {
          // The cover and its reflection: as wide as the room, unless the room is not
          // tall enough for both, in which case as tall.
          final side = math.min(
              c.maxWidth,
              c.maxHeight.isFinite
                  ? c.maxHeight / (1 + Mirror.defaultDepth)
                  : c.maxWidth);
          // Just the cover: still, square, and the whole width of the stage. Square
          // corners on purpose — a record sleeve has corners, and rounding them off
          // makes the art look like an app icon of itself.
          final cover = Artwork(track: track, size: side, radius: 0, small: false);
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

        // The side of the square: the width, unless the height given will not hold
        // the picture that side draws, in which case the side the height holds.
        final side = math.min(
            c.maxWidth, c.maxHeight.isFinite ? sideIn(c.maxHeight) : c.maxWidth);
        // No clip and no shadow of our own: the pieces carry their own, and a rounded
        // rectangle around them would cut the disc off as it slides out.
        return Center(
          child: SizedBox(
            width: side,
            height: boxFor(side),
            child: Align(
            alignment: Alignment(0, -1 + 2 * headroom / (headroom + footroom)),
            child: SizedBox(
            width: side,
            height: side,
            child: _ArmFeed(
              player: player,
              app: app,
              builder: (hand) => RecordStage(
              hand: hand,
              label: context.watch<AppState>().discLabel,
              track: track,
              playing: app.musicIsPlaying,
              scale: context.watch<AppState>().coverScale,
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
            ),
            ),
          ),
        );
      },
    );
  }
}

/// Where the song is, for the tonearm, and what putting it down does.
///
/// From the player's fine-grained stream — the coarse one the rest of this screen is
/// drawn from does not carry the position — but only passed on when the needle would
/// actually move: a third of a second of a four-minute song is a fraction of a pixel
/// of arm, and repainting it for that is work nobody can see.
///
/// No hand at all where this device is not the one making the sound: a guest in
/// somebody else's jam, or a phone steering another speaker. The arm is still drawn;
/// it just cannot be picked up, because the music it would be sitting on is not here.
class _ArmFeed extends StatefulWidget {
  const _ArmFeed({required this.player, required this.app, required this.builder});

  final PlayerService player;
  final AppState app;
  final Widget Function(ArmHand? hand) builder;

  @override
  State<_ArmFeed> createState() => _ArmFeedState();
}

class _ArmFeedState extends State<_ArmFeed> {
  late final ValueNotifier<ArmReading> _reading =
      ValueNotifier(_read(widget.player.last));
  StreamSubscription<PlayerSnapshot>? _feed;

  late final ArmHand _hand = ArmHand(
    reading: _reading,
    onPlace: (at) async {
      final app = widget.app;
      await app.seekTo(at);
      if (!app.musicIsPlaying) await app.playPause();
    },
    onPark: () {
      final app = widget.app;
      if (app.musicIsPlaying) app.playPause();
    },
  );

  static ArmReading _read(PlayerSnapshot? s) => ArmReading(
        position: s?.position ?? Duration.zero,
        length: s?.duration,
        playing: s?.playing ?? false,
      );

  @override
  void initState() {
    super.initState();
    _feed = widget.player.snapshots.listen((s) {
      final next = _read(s);
      final now = _reading.value;
      if (next.playing != now.playing ||
          next.length != now.length ||
          (next.groove - now.groove).abs() >= 0.0015 ||
          // A seek backwards to the very start is worth drawing however small.
          (next.position < now.position && next.groove < 0.0015)) {
        _reading.value = next;
      }
    });
  }

  @override
  void dispose() {
    _feed?.cancel();
    _reading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final here = !app.isJamGuest && !app.controllingAnother;
    return widget.builder(here ? _hand : null);
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
class DeskNowPlaying extends StatefulWidget {
  const DeskNowPlaying({super.key, this.onClose});

  /// Folding the panel away again.
  final VoidCallback? onClose;

  /// What everything but the record takes: the head above it, and under it the
  /// words, the panel with the bar, the transport, the song's buttons and the volume.
  /// Measured, and generous by a few pixels — being a little smaller than it could be
  /// is nothing, and being a little too big is a scrollbar.
  static const forTheHead = 54.0;
  static const forTheRest = 304.0;

  /// The height this wants in a panel [width] wide: the record as wide as the panel
  /// allows, and everything else at its size. Any less and the record shrinks; any
  /// more is air under the controls.
  static double wanted(double width) =>
      forTheHead + _Artwork.boxFor(width - 48) + forTheRest;

  @override
  State<DeskNowPlaying> createState() => _DeskNowPlayingState();
}

class _DeskNowPlayingState extends State<DeskNowPlaying> {
  final _room = RoomLight();

  VoidCallback? get onClose => widget.onClose;

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = app.player;
    // No player yet is the same sight as a player with nothing on it.
    if (player == null) return _DeckIdle(onClose: onClose);
    final text = Theme.of(context).textTheme;

    // The whole player is where the arm can be picked up from: see ArmReach.
    return RoomLightScope(light: _room, child: ArmReach(child: StreamBuilder<PlayerSnapshot>(
      stream: player.changes,
      initialData: player.last,
      builder: (context, snap) {
        final s = snap.data;
        final track = s?.current ?? player.current;
        if (track == null) return _DeckIdle(onClose: onClose);
        final head = Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(app.activeQueue?.name ?? 'Now playing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall),
              ),
              const WhereItPlays(compact: true),
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
        );
        // Everything under the record. Its height is what is left for the record, and
        // it is the part that must never be cut off: the bar and the buttons are what
        // the panel is for.
        //
        // The same panel the phone's player has, with the same things in it in the
        // same order: the bar, the transport, the song's own buttons, the volume. It
        // was a loose stack of the first three, which read as a different, lesser
        // player rather than the same one seen from the side.
        final under = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            _Words(app: app, track: track),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GlassSurface(
                borderRadius: BorderRadius.circular(22),
                topBorder: false,
                opacity: 0.42,
                blur: 36,
                sheen: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Scrubber(player: player, timesBeside: true),
                    const SizedBox(height: 4),
                    _Controls(app: app, player: player, snapshot: s),
                    const SizedBox(height: 2),
                    _Extras(app: app, track: track),
                    const SizedBox(height: 2),
                    _VolumeRow(player: player),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        );

        // The record's box is the height of the picture — the arm and the top of the
        // disc above the square, the sleeve's edge below it — so none of it runs into
        // the panel's head or the song's name. See _Artwork.headroom.
        Widget record({double? side}) => Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: SizedBox(
                height: side == null ? null : _Artwork.boxFor(side),
                // Full size for the box it is in: what was wrong before was the
                // record, which sized itself from the window rather than from the
                // room this panel gives it.
                child: _Artwork(
                    track: track, snapshot: s, player: player, app: app),
              ),
            );

        // The record takes whatever height is left over, so the panel fits the window
        // at any size rather than scrolling — and when the window is genuinely too
        // short for a record and its controls, the record stops shrinking and the
        // whole thing scrolls instead of being squashed into a line.
        final laidOut = LayoutBuilder(
          builder: (context, c) {
            if (!c.maxHeight.isFinite) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [head, record(), under],
              );
            }
            // What the record may have is what is left when everything that has to
            // stay reachable has taken its share: the bar, the transport and the
            // song's own buttons are the panel's job, and a record is not allowed to
            // push them off the bottom. Generous on purpose — being a little smaller
            // than it could be is nothing, and being a little too big is a scrollbar.
            final side = _Artwork.sideIn(c.maxHeight - DeskNowPlaying.forTheHead - DeskNowPlaying.forTheRest)
                .clamp(0.0, c.maxWidth - 48);
            if (side >= 140) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [head, record(side: side), under],
              );
            }
            // Shorter than a record and its controls together. Nothing is squashed;
            // it scrolls, which is the honest answer to a window that small.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [record(side: 160), under],
                    ),
                  ),
                ),
              ],
            );
          },
        );

        // The same room the phone's player is in: the record's own colour washed
        // over the card, the printed dots breathing to the song behind it, the
        // disco ball's light over it, and the player's state on a slip at the top.
        // The panel was the same parts on plain paper, which is a different player.
        return AmbientBackdrop(
          colour: parseHexColour(track.coverColor),
          behind: app.halftone
              ? BeatPulse(
                  app: app,
                  track: track,
                  builder: (context, beat) => HalftoneBackdrop(
                    colour: parseHexColour(track.coverColor),
                    playing: app.musicIsPlaying,
                    loudnessDb: track.loudnessLufs,
                    beat: beat,
                  ),
                )
              : null,
          child: Stack(
            children: [
              Positioned.fill(child: laidOut),
              Positioned(
                top: DeskNowPlaying.forTheHead - 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: _StatusSlip(status: _NowPlayingScreenState._statusLine(s, track)),
                ),
              ),
              if (app.discoLights)
                Positioned.fill(
                  child: BeatPulse(
                    app: app,
                    track: track,
                    builder: (context, pulse) => MirrorBallLight(
                      playing: app.musicIsPlaying,
                      tint: parseHexColour(track.coverColor),
                      pulse: pulse,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    )));
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
  int? _askedTimingFor;

  /// Each song's shape, asked for once when it comes on. A song not asked for yet is
  /// missing from the map; one with no shape to give is in it as null.
  static final Map<int, List<int>?> _shapes = {};
  static final Set<int> _asking = {};

  void _askForShape(AppState app, int id) {
    if (_shapes.containsKey(id) || _asking.contains(id)) return;
    _asking.add(id);
    app.api.peaks(id).then((shape) {
      _shapes[id] = shape;
    }).catchError((_) {
      // A flat bar is what there was before; nothing is lost by drawing it.
      _shapes[id] = null;
    }).whenComplete(() {
      _asking.remove(id);
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final app = context.watch<AppState>();
    final songId = s?.current?.id;
    if (songId != null) _askForShape(app, songId);
    final shape = songId == null ? null : _shapes[songId];

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

    // The nothing at either end that is being skipped, so the bar says so: a song that
    // moves on with two seconds still showing looks like a fault unless those two
    // seconds look like what they are.
    var skips = (before: 0.0, after: 0.0);
    final current = s?.current;
    if (app.seamless && current != null && max > 0) {
      final store = widget.player.timing;
      final timing = store.peek(current.id);
      if (timing == null) {
        if (_askedTimingFor != current.id) {
          _askedTimingFor = current.id;
          store.of(current).then((_) {
            if (mounted) setState(() {});
          });
        }
      } else {
        skips = (
          before: (timing.leadMs / max).clamp(0.0, 0.5),
          after: (timing.tailMs / max).clamp(0.0, 0.5),
        );
      }
    }

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
          // The song's own shape behind the bar, where it is known: the played part
          // inked in, the rest faint. The slider on top keeps doing all the work —
          // the drag, the seek, the reading aloud — with its own track made clear.
          child: Stack(
          alignment: Alignment.center,
          children: [
          // Always the segmented bar: breathing quietly while the shape is being
          // fetched, flat where there is none, and rising into the song's shape when
          // it arrives — never a plain line that is swapped for something else.
          Positioned.fill(
            child: Padding(
              // The slider's track is held in by its overlay's radius; the shape
              // sits on exactly the same line.
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: IgnorePointer(
                child: WaveBar(
                  shape: shape,
                  loading: songId != null && !_shapes.containsKey(songId),
                  played: max > 0 ? (value / max).clamp(0.0, 1.0) : 0,
                  skippedBefore: skips.before,
                  skippedAfter: skips.after,
                ),
              ),
            ),
          ),
          SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: enabled ? 7 : 4),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
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
          ],
          ),
        );
        // Both times in a box as wide as the longer of them will ever be, in figures
        // that are all one width. They were sized by whatever they said, so "1:11" was
        // narrower than "0:48" and the bar between them changed length every second.
        final timeStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()]);
        final widest = TextPainter(
          text: TextSpan(
              text: (max > 0 ? formatTime(duration) : '--:--')
                  .replaceAll(RegExp(r'\d'), '0'),
              style: timeStyle),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final timeWidth = widest.width.ceilToDouble() + 1;
        widest.dispose();
        final elapsed = SizedBox(
          width: timeWidth,
          child: Text(formatTime(Duration(milliseconds: value.round())),
              maxLines: 1, softWrap: false, style: timeStyle),
        );
        final total = SizedBox(
          width: timeWidth,
          child: Text(max > 0 ? formatTime(duration) : '--:--',
              maxLines: 1, softWrap: false, textAlign: TextAlign.end, style: timeStyle),
        );

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
                      padding: const EdgeInsets.only(bottom: 8), child: elapsed),
                  Expanded(child: overBar),
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: total),
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
            BeatPulse(
              app: app,
              track: snapshot?.current,
              builder: (context, beat) => PlayPauseButton(
                  playing: playing,
                  size: 56,
                  busy: snapshot?.buffering ?? false,
                  beat: beat,
                  onPressed: app.playPause),
            ),
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
        BeatPulse(
          app: app,
          track: snapshot?.current,
          builder: (context, beat) => PlayPauseButton(
              playing: playing,
              size: big ? 54 : 42,
              busy: snapshot?.buffering ?? false,
              beat: beat,
              onPressed: app.playPause),
        ),
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
    ask<void>(
      context,
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
  await ask<void>(
    context,
    // As tall as it needs, up to the screen: see the note on scrolling in the sheet.
    scrollable: true,
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
          // Scrolls, because it has to: how it sounds, how songs join, the sleep timer
          // and the speed are more than a sheet's height on a small phone, and a column
          // that does not scroll simply loses its last rows off the bottom of the screen.
          child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // How it sounds, first: it is what somebody reaching for this sheet
              // from the player is most often after.
              ListenableBuilder(
                listenable: app.equalizer,
                builder: (context, _) {
                  final eq = app.equalizer;
                  return ListTile(
                    leading: const Icon(Icons.graphic_eq),
                    title: const Text('Equalizer'),
                    subtitle: Text(!eq.enabled
                        ? 'Off'
                        : eq.current != null
                            ? eq.current!.name
                            : 'A curve of your own'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      final navigator = Navigator.of(sheet);
                      navigator.pop();
                      navigator.push(MaterialPageRoute<void>(
                          builder: (_) => const EqualizerPage()));
                    },
                  );
                },
              ),
              // The curves, a tap away: changing how it sounds for this room or these
              // headphones should not mean leaving the player for a page of faders.
              ListenableBuilder(
                listenable: app.equalizer,
                builder: (context, _) {
                  final eq = app.equalizer;
                  if (!eq.engine.available) return const SizedBox.shrink();
                  final now = eq.enabled ? eq.current?.name : null;
                  // A dozen chips: all built, in a row that scrolls, as tall as they are.
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: const Text('Off'),
                            visualDensity: VisualDensity.compact,
                            selected: !eq.enabled,
                            onSelected: (_) => eq.setEnabled(false),
                          ),
                        ),
                        for (final p in eq.presets)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(p.name),
                              visualDensity: VisualDensity.compact,
                              selected: now == p.name,
                              onSelected: (_) => eq.use(p),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              _HowItPlays(app: app),
              const Divider(height: 8),
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
        ),
    );
  }
}

/// The seek bar's segments, and how they move.
///
/// Three states, one look. While the song's shape is being fetched the segments are
/// low and a slow swell travels along them; when it arrives they rise into it over
/// half a second; where there is none to be had they sit flat. A phone asked to keep
/// still gets no swell and no rise, just the result.
class WaveBar extends StatefulWidget {
  const WaveBar({
    super.key,
    required this.shape,
    required this.loading,
    required this.played,
    this.skippedBefore = 0,
    this.skippedAfter = 0,
  });

  final List<int>? shape;
  final bool loading;
  final double played;

  /// How much of either end of the file is nothing, as a share of its length — and is
  /// being skipped, with songs played one into the next. Drawn as dots rather than
  /// bars: the bar is the file, and these are the parts of the file that are not song.
  final double skippedBefore;
  final double skippedAfter;

  @override
  State<WaveBar> createState() => _WaveBarState();
}

class _WaveBarState extends State<WaveBar> with TickerProviderStateMixin {
  /// Four slow swells and then it rests: a request that never comes back must not
  /// leave the bar moving for as long as the player is open.
  late final AnimationController _swell =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 9600));
  late final AnimationController _rise = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      value: widget.shape == null ? 0 : 1);

  late final Animation<double> _rising =
      CurvedAnimation(parent: _rise, curve: Curves.easeOutCubic);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settle();
  }

  @override
  void didUpdateWidget(WaveBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.shape, widget.shape)) {
      if (widget.shape == null) {
        _rise.value = 0;                  // another song: back down, then up again
      } else if (stillness(context)) {
        _rise.value = 1;
      } else {
        _rise.forward(from: 0);
      }
    }
    _settle();
  }

  void _settle() {
    final moving = widget.loading && !stillness(context);
    if (moving && !_swell.isAnimating && _swell.value == 0) _swell.forward();
    if (!moving) {
      _swell.stop();
      _swell.value = 0;
    }
  }

  @override
  void dispose() {
    _swell.dispose();
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _Waveform(
          shape: widget.shape,
          played: widget.played,
          loading: widget.loading,
          skippedBefore: widget.skippedBefore,
          skippedAfter: widget.skippedAfter,
          swell: _swell,
          rise: _rising,
          ink: scheme.primary,
          rest: scheme.onSurface.withValues(alpha: 0.24),
        ),
      ),
    );
  }
}

/// A song's shape as a seek bar: evenly cut segments, each as tall as its slice of the
/// song is loud, mirrored about the line. What has played is inked in; what is to come
/// is faint.
class _Waveform extends CustomPainter {
  _Waveform({
    required this.shape,
    required this.played,
    required this.loading,
    this.skippedBefore = 0,
    this.skippedAfter = 0,
    required this.swell,
    required this.rise,
    required this.ink,
    required this.rest,
  }) : super(repaint: Listenable.merge([swell, rise]));

  final List<int>? shape;
  final double played;
  final bool loading;
  final double skippedBefore;
  final double skippedAfter;
  final Animation<double> swell;
  final Animation<double> rise;
  final Color ink;
  final Color rest;

  /// A segment and the gap after it, in whole pixels: the same everywhere, on every
  /// width of screen. The server's 160 slices were drawn one to a bar at whatever
  /// fraction of a pixel that came to, so the gaps beat against the pixel grid — some
  /// closed up, some doubled.
  static const _bar = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final count = math.max(1, ((size.width + _gap) / (_bar + _gap)).floor());
    // Centred, so whatever is left over is shared between the two ends.
    final left = ((size.width - (count * (_bar + _gap) - _gap)) / 2).floorToDouble();
    final mid = size.height / 2;
    final flat = math.min(2.0, mid);
    final peaks = shape;
    final up = rise.value;
    final phase = swell.value * 4 * 2 * math.pi;
    // Eased in at the start and out at the end, so it neither snaps on nor freezes
    // mid-wave when it rests.
    final strength = math.min(1.0, swell.value * 8) * math.min(1.0, (1 - swell.value) * 6);
    final edge = played * size.width;
    final done = Paint()..color = ink;
    final todo = Paint()..color = rest;

    for (var i = 0; i < count; i++) {
      var h = flat;
      if (peaks != null && peaks.isNotEmpty) {
        // The loudest of the slices this segment covers, so a drum hit is not lost
        // between two bars.
        final from = (i * peaks.length / count).floor();
        final to = math.max(from + 1, ((i + 1) * peaks.length / count).ceil());
        var top = 0;
        for (var k = from; k < to && k < peaks.length; k++) {
          if (peaks[k] > top) top = peaks[k];
        }
        final full = (top / 255 * mid).clamp(flat, mid);
        h = flat + (full - flat) * up;
      } else if (loading) {
        // A slow swell travelling along the bar: enough to say "working on it".
        h = flat + (mid * 0.22) * strength * (0.5 + 0.5 * math.sin(phase - i * 0.35));
      }
      final x = left + i * (_bar + _gap);
      // Dead air at either end, which is not played: a dot where a bar would be.
      final along = (x + _bar / 2) / size.width;
      if (along < skippedBefore || along > 1 - skippedAfter) {
        canvas.drawCircle(Offset(x + _bar / 2, mid), _bar / 2.4, todo);
        continue;
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(x, mid - h, x + _bar, mid + h), const Radius.circular(1.5)),
        x + _bar / 2 <= edge ? done : todo,
      );
    }
  }

  @override
  bool shouldRepaint(_Waveform old) =>
      old.played != played ||
      old.loading != loading ||
      old.skippedBefore != skippedBefore ||
      old.skippedAfter != skippedAfter ||
      !identical(old.shape, shape) ||
      old.ink != ink ||
      old.rest != rest;
}


/// One song into the next, and what is known about this one's time.
///
/// The switch, and under it what the server found when it listened to the song on now:
/// how fast it goes, and how much nothing there is at either end of its file that is
/// being skipped. Said only when there is something to say.
class _HowItPlays extends StatefulWidget {
  const _HowItPlays({required this.app});
  final AppState app;

  @override
  State<_HowItPlays> createState() => _HowItPlaysState();
}

class _HowItPlaysState extends State<_HowItPlays> {
  TrackTiming? _timing;

  @override
  void initState() {
    super.initState();
    final player = widget.app.player;
    final track = player?.current;
    if (player == null || track == null) return;
    _timing = player.timing.peek(track.id);
    player.timing.of(track).then((found) {
      if (mounted) setState(() => _timing = found);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final t = _timing;
    String seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';
    final about = [
      if (t?.bpm != null) '${t!.bpm!.round()} beats a minute',
      if (app.seamless && t != null && t.leadMs + t.tailMs > 0)
        '${seconds(t.leadMs + t.tailMs)} of silence skipped in this song',
    ];
    return SwitchListTile(
      secondary: const Icon(Icons.linear_scale),
      title: const Text('One song into the next'),
      subtitle: Text(about.isEmpty
          ? 'Skips the second or two of nothing at the ends of files'
          : about.join(' · ')),
      value: app.seamless,
      onChanged: app.setSeamless,
    );
  }
}


/// A turntable with no record on it: the platter, its mat, the spindle, drawn in line.
class _EmptyPlatter extends CustomPainter {
  const _EmptyPlatter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = ink.withValues(alpha: 0.75);
    final faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ink.withValues(alpha: 0.22);
    canvas.drawCircle(c, r - 1, line);
    // The strobe dots round the rim of a platter.
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi * 2 / 60;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (r - 7), 0.9,
          Paint()..color = ink.withValues(alpha: 0.45));
    }
    for (final at in [0.84, 0.66, 0.48]) {
      canvas.drawCircle(c, r * at, faint);
    }
    canvas.drawCircle(c, r * 0.30, line);
    canvas.drawCircle(c, 3.2, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_EmptyPlatter old) => old.ink != ink;
}


/// The deck with nothing on it: said the way the rest of the app says things, with the
/// way to fold it away still where it always is. It used to be two words in the middle
/// of four hundred empty pixels.
class _DeckIdle extends StatelessWidget {
  const _DeckIdle({this.onClose});
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionFlag('The deck', rule: false)),
              if (onClose != null)
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Hide',
                  onPressed: onClose,
                ),
            ],
          ),
          const Spacer(),
          Center(
            child: LayoutBuilder(
              builder: (context, box) => CustomPaint(
                size: Size.square((box.maxWidth * 0.62).clamp(120.0, 260.0)),
                painter: _EmptyPlatter(scheme.onSurface),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text('NOTHING ON', style: Mag.headline(30, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
                'Put a record on from anywhere — a song, an album, one of the '
                'lists — and it plays here, beside whatever page you are on.',
                style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant)),
          ),
          const Spacer(flex: 2),
        ],
      ),
    );
  }
}
