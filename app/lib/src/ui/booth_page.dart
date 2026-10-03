import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/frame_watch.dart';
import '../state/app_state.dart';
import '../state/booth/board/board_keys.dart';
import '../state/booth/booth.dart';
import '../state/booth/deck.dart' as engine;
import 'artwork.dart';
import 'booth/booth_clock.dart';
import 'booth/board/board_room.dart';
import 'booth/board/pop_out_none.dart' if (dart.library.io) 'booth/board/pop_out_io.dart';
import 'booth/desk/console_plan.dart';
import 'booth/desk/console_room.dart';
import 'booth/desk/console_set.dart' show startAuto;
import 'booth/desk/set_planner_page.dart' show openSetPlanner;
import 'booth/phone/phone_room.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'stage/arm_grip.dart';
import 'widths.dart';
import 'booth/look.dart';
import 'snack.dart';
import '../state/booth/session.dart';

/// The booth: two records on the deck, the mixer between them, the crate beside.
///
/// The player's other life. The same records, the same arm, the same printed page —
/// laid out as a room to work in rather than a page to look at.
///
/// A desk gets the room a mixer is actually shaped like: the two waveforms at the
/// top, facing each other across the phase meter so their beats line up to the eye,
/// the decks either side of the mixer below them, and the crate down the edge. A
/// phone stacks the decks with the mixer between them and keeps the crate in a
/// drawer.
class BoothPage extends StatefulWidget {
  const BoothPage({super.key});

  @override
  State<BoothPage> createState() => _BoothPageState();
}

class _BoothPageState extends State<BoothPage> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // So a slow stretch in the log says which screen was open for it.
    FrameWatch.where = 'booth';
    final app = context.read<AppState>();
    unawaited(app.booth.init());
    // And the board's sounds made ready, so its keys fire from the decks' page too.
    unawaited(app.booth.board.load());
    // The booth makes the sound now; the ordinary player keeps quiet.
    unawaited(app.player?.pause());
  }

  @override
  void dispose() {
    FrameWatch.where = 'app';
    _focus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ the keys
  /// What a desk's hands do without reaching for the mouse, as the console's keys
  /// button lists them.
  static const keys = <(String, String)>[
    ('Space', 'Mix, or stop the mix'),
    ('1 2', 'Play or pause A, B'),
    ('Q W', 'SYNC on or off, A or B'),
    ('Z X', 'Start A, B on the bar'),
    ('← →', 'Crossfader'),
    ('⇧ ← →', 'Nudge the master'),
    ('[ ]', 'Loop A, B'),
    ('F G', 'Kill the bass on A, B'),
    ('A', 'Auto DJ on or off'),
    ('S', 'Auto DJ: skip — into the next at the next bar'),
    ('M', 'Auto DJ: mix now, the planned way'),
    ('N', 'Auto DJ: not now — the next to the end of the queue'),
    ('E D', 'Auto DJ: eight bars longer, sooner'),
    ('⌥ ↑ ↓', 'Auto DJ: more energy, less'),
    ('U', 'Auto DJ: undo what it just changed'),
    ('L', 'Plan a set'),
    ('P', 'Waveforms, the set, the plan'),
    ('B', 'The board, and back to the decks'),
    ('⇧ B', 'A row of the board pinned under the decks, or let go'),
    ('⌥ B', 'The board in a window of its own'),
    ('R', 'Auto DJ: hear the last mix again'),
    ...BoardKeys.sheet,
  ];

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    // Held with Ctrl (or ⌘) a key is the app's, not a deck's: Ctrl Q quits, Ctrl K goes
    // anywhere, and neither should toggle SYNC or start a mix on its way past.
    if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // Typing in the crate's search is typing, not playing the decks.
    final typing = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    final b = context.read<AppState>().booth;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    // The board's keys first — function keys and the number pad are nobody's text
    // keys — and up as well as down, since a hold pad lets go. A held key's repeats
    // are the board's to swallow: a one-shot is not fired again by a finger resting.
    if (b.board.keyEvent(e, typing: typing != null, shift: shift)) return KeyEventResult.handled;
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (typing != null) return KeyEventResult.ignored;
    // F11 is the program's (AppShortcuts), not the booth's: it falls through.
    final k = e.logicalKey;
    final master = b.master;

    void nudge(engine.Deck d, int ms) => unawaited(b.nudge(d, Duration(milliseconds: ms)));
    void killBass(engine.Deck d) {
      feel(Feel.pick);
      unawaited(b.kill(d, 0, !b.eqOf(d).lowKilled));
    }

    if (k == LogicalKeyboardKey.space) {
      feel(Feel.commit);
      if (b.busy) {
        b.stopTransition();
      } else {
        unawaited(b.go(Transition.blend, bars: 16));
      }
    } else if (k == LogicalKeyboardKey.digit1) {
      unawaited(b.a.playing ? b.a.pause() : b.play(b.a));
    } else if (k == LogicalKeyboardKey.digit2) {
      unawaited(b.b.playing ? b.b.pause() : b.play(b.b));
    } else if (k == LogicalKeyboardKey.keyQ) {
      unawaited(b.setSync(b.a, !b.a.synced));
    } else if (k == LogicalKeyboardKey.keyW) {
      unawaited(b.setSync(b.b, !b.b.synced));
    } else if (k == LogicalKeyboardKey.keyZ) {
      unawaited(b.startOnBeat(b.a));
    } else if (k == LogicalKeyboardKey.keyX) {
      unawaited(b.startOnBeat(b.b));
    } else if (k == LogicalKeyboardKey.keyF) {
      killBass(b.a);
    } else if (k == LogicalKeyboardKey.keyG) {
      killBass(b.b);
    } else if (k == LogicalKeyboardKey.keyA) {
      feel(Feel.commit);
      if (b.auto.running) {
        b.auto.stop();
      } else {
        startAuto(b, context.read<AppState>().player?.items ?? const []);
      }
    } else if (k == LogicalKeyboardKey.keyS) {
      feel(Feel.commit);
      unawaited(b.auto.skip());
    } else if (k == LogicalKeyboardKey.keyE) {
      b.auto.extend(2);
    } else if (k == LogicalKeyboardKey.keyD) {
      b.auto.extend(-2);
    } else if (k == LogicalKeyboardKey.keyU) {
      unawaited(b.auto.undoLast());
    } else if (k == LogicalKeyboardKey.keyL) {
      unawaited(openSetPlanner(context, b));
    } else if (HardwareKeyboard.instance.isAltPressed &&
        (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown)) {
      b.auto.nudgeEnergy(k == LogicalKeyboardKey.arrowUp ? 1 : -1);
    } else if (k == LogicalKeyboardKey.keyM) {
      feel(Feel.commit);
      unawaited(b.auto.mixNow());
    } else if (k == LogicalKeyboardKey.keyN) {
      unawaited(b.auto.dropNext());
    } else if (k == LogicalKeyboardKey.keyP) {
      planViewToggles.value++;
    } else if (k == LogicalKeyboardKey.keyB) {
      if (HardwareKeyboard.instance.isAltPressed) {
        unawaited(popOutBoard(context.read<AppState>().boardLink));
      } else if (shift) {
        unawaited(b.board.toggleStrip());
      } else {
        boardToggles.value++;
      }
    } else if (k == LogicalKeyboardKey.keyR) {
      unawaited(b.auto.replayLast());
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      shift ? nudge(master, -10) : unawaited(b.setCrossfader(b.crossfader - 0.05));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      shift ? nudge(master, 10) : unawaited(b.setCrossfader(b.crossfader + 0.05));
    } else if (k == LogicalKeyboardKey.bracketLeft) {
      b.a.loopStart == null ? b.a.loop(16) : b.a.unloop();
    } else if (k == LogicalKeyboardKey.bracketRight) {
      b.b.loopStart == null ? b.b.loop(16) : b.b.unloop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // The booth is made once and kept: nothing else of the app's state is drawn here,
    // and watching all of it rebuilt the room with every change anywhere in the app.
    final b = context.read<AppState>().booth;
    final compact = Width.of(context) == Width.compact;

    return ArmReach(
      child: BoothClock(
        booth: b,
        child: Focus(
          focusNode: _focus,
          autofocus: !compact,
          onKeyEvent: _keys,
          child: AnimatedBuilder(
            animation: b,
            builder: (context, _) => compact ? PhoneRoom(booth: b) : ConsoleRoom(booth: b, keys: keys),
          ),
        ),
      ),
    );
  }
}

/// Into the booth, and — with [mix] — with the booth mixing [tracks] from [at].
Future<void> openBooth(BuildContext context,
    {List<Track>? tracks, int at = 0, Map<String, dynamic>? mix}) async {
  final app = context.read<AppState>();
  final booth = app.booth;
  // The lights as they were left, before the room is built.
  await boothLook.load();
  // Where the ordinary player had got to, if the record it was on is the one the
  // booth starts with: the music carries on from there.
  final was = app.player?.last;
  final carryOn = tracks != null &&
          at < tracks.length &&
          was?.current?.id == tracks[at].id &&
          mix == null
      ? was?.position
      : null;
  await app.player?.pause();
  if (tracks != null && tracks.isNotEmpty) {
    await booth.init();
    unawaited(booth.auto.start(tracks, at: at, kept: MixMove.allIn(mix), from: carryOn));
  }
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true)
      .push(MaterialPageRoute(builder: (_) => const BoothPage()));
}

/// The bar at the bottom of the app while the booth has the sound: what is on,
/// what is coming and when, and a way to stop it. Tapping it goes back into the room.
class BoothBar extends StatelessWidget {
  const BoothBar({super.key, required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = booth.master.track;
    final auto = booth.auto;
    final next = auto.running ? auto.next : booth.other(booth.master).track;
    final at = auto.goesAt;
    final left = at == null || !auto.running ? null : at - booth.master.position;
    final line = [
      'The booth',
      if (booth.inTransition)
        'mixing'
      else if (next != null)
        'then ${next.displayTitle}'
            '${left == null ? '' : left.isNegative ? '' : ' · ${auto.plan?.kind.label ?? 'mix'} in ${left.inSeconds}s'}',
    ].join(' · ');
    return ListTile(
      dense: true,
      onTap: () => Navigator.of(context, rootNavigator: true)
          .push(MaterialPageRoute(builder: (_) => const BoothPage())),
      leading: on == null
          ? Icon(Icons.album_outlined, color: scheme.primary)
          : Artwork(track: on, size: 42, radius: 2),
      title: Text(on?.displayTitle ?? 'The booth',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(15.5, color: scheme.onSurface)),
      subtitle: Text(line,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11.5, color: scheme.onSurface)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!auto.running)
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                fixedSize: const Size.square(40),
              ),
              icon: Icon(booth.master.playing ? Icons.pause : Icons.play_arrow),
              onPressed: felt(Feel.commit, () => booth.master.playing ? booth.master.pause() : booth.master.play()),
            )
          else
            // Skip, the Auto DJ's way: into the next record at the next bar.
            IconButton(
              tooltip: 'Skip: into ${next?.displayTitle ?? 'the next record'}',
              icon: Icon(Icons.skip_next, color: scheme.onSurface),
              onPressed: next == null || booth.inTransition ? null : felt(Feel.commit, () => booth.auto.skip()),
            ),
          PressButton(label: 'Stop', onTap: () => unawaited(booth.stopAll())),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}


/// The booth as it was left when the app last ran, put back and set going — once,
/// on the home page's first frame, when a live session under eight hours old was
/// kept. The bar at the bottom says so, with a way to stop it.
class ResumeBooth extends StatefulWidget {
  const ResumeBooth({super.key, required this.child});
  final Widget child;

  @override
  State<ResumeBooth> createState() => _ResumeBoothState();
}

class _ResumeBoothState extends State<ResumeBooth> {
  static bool _tried = false;

  @override
  void initState() {
    super.initState();
    if (_tried) return;
    _tried = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_resume()));
  }

  Future<void> _resume() async {
    final snap = await BoothSession.load();
    if (snap == null || !mounted) return;
    final app = context.read<AppState>();
    final ids = BoothSession.trackIds(snap);
    if (ids.isEmpty) return;
    final tracks = <int, Track>{};
    await Future.wait([
      for (final id in ids.take(60))
        () async {
          try {
            tracks[id] = await app.api.track(id);
          } catch (_) {
            // A record the house no longer has: the session comes back without it.
          }
        }(),
    ]);
    if (!mounted || tracks.isEmpty) return;
    await boothLook.load();
    await app.player?.pause();
    final booth = app.booth;
    final came = await BoothSession.resume(booth, snap, tracks);
    if (!came || !mounted) return;
    final on = booth.master.track?.displayTitle;
    ScaffoldMessenger.of(context).say(snack(
      Text(on == null ? 'The booth is back where it was' : 'Back in the booth: $on'),
      action: SnackBarAction(label: 'STOP', onPressed: () => unawaited(booth.stopAll())),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
