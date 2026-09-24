import 'full_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/booth/booth.dart';
import '../state/booth/deck.dart' as engine;
import 'artwork.dart';
import 'booth/booth_clock.dart';
import 'booth/crate.dart';
import 'booth/deck_panel.dart';
import 'booth/desk/console_plan.dart';
import 'booth/desk/console_room.dart';
import 'booth/meters.dart';
import 'booth/mixer_strip.dart';
import 'feel.dart';
import 'glass.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'stage/arm_grip.dart';
import 'widths.dart';

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
    final app = context.read<AppState>();
    unawaited(app.booth.init());
    // The booth makes the sound now; the ordinary player keeps quiet.
    unawaited(app.player?.pause());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load(engine.Deck deck, Track track) async {
    await context.read<AppState>().booth.load(deck, track);
  }

  /// Which deck a record from the crate goes on: whichever is not the master.
  engine.Deck _free(Booth b) => b.other(b.master);

  Future<void> _pick(engine.Deck deck) async {
    final b = context.read<AppState>().booth;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * 0.7,
        child: Crate(
          booth: b,
          onPick: (t) {
            Navigator.of(sheet).pop();
            unawaited(_load(deck, t));
          },
        ),
      ),
    );
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
    ('M', 'Auto DJ: mix now'),
    ('N', 'Auto DJ: not that one'),
    ('P', 'Waveforms, the set, the plan'),
    ('R', 'Auto DJ: hear the last mix again'),
    ('F11', 'Full screen'),
  ];

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    // Typing in the crate's search is typing, not playing the decks.
    final typing = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    if (typing != null) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.f11) {
      unawaited(toggleFullScreen());
      return KeyEventResult.handled;
    }
    final b = context.read<AppState>().booth;
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
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
    } else if (k == LogicalKeyboardKey.keyM) {
      feel(Feel.commit);
      unawaited(b.auto.mixNow());
    } else if (k == LogicalKeyboardKey.keyN) {
      unawaited(b.auto.dropNext());
    } else if (k == LogicalKeyboardKey.keyP) {
      planViewToggles.value++;
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
    final app = context.watch<AppState>();
    final b = app.booth;
    final compact = Width.of(context) == Width.compact;
    final tint = parseHexColour(b.master.track?.coverColor);

    return ArmReach(
      child: BoothClock(
        booth: b,
        child: Focus(
          focusNode: _focus,
          autofocus: !compact,
          onKeyEvent: _keys,
          child: AnimatedBuilder(
            animation: b,
            builder: (context, _) => !compact
                ? ConsoleRoom(booth: b, keys: keys)
                : Scaffold(
              appBar: AppBar(
                title: const Text('The booth'),
                actions: [
                  if (b.live)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Center(
                        child: Text('ON AIR',
                            style: Mag.flag(9, color: Theme.of(context).colorScheme.primary)),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.inventory_2_outlined),
                    tooltip: 'The crate',
                    onPressed: () => _pick(_free(b)),
                  ),
                ],
              ),
              body: AmbientBackdrop(
                colour: tint,
                child: _phone(context, b),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ a phone
  Widget _phone(BuildContext context, Booth b) => ListView(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 40),
        children: [
          DeckPanel(booth: b, deck: b.a, onLoad: () => _pick(b.a)),
          const SizedBox(height: 8),
          PhaseMeter(booth: b),
          const SizedBox(height: 8),
          MixerStrip(booth: b),
          const SizedBox(height: 8),
          DeckPanel(booth: b, deck: b.b, onLoad: () => _pick(b.b)),
        ],
      );

}

/// Into the booth, and — with [mix] — with the booth mixing [tracks] from [at].
Future<void> openBooth(BuildContext context,
    {List<Track>? tracks, int at = 0, Map<String, dynamic>? mix}) async {
  final app = context.read<AppState>();
  final booth = app.booth;
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
            ),
          PressButton(label: 'Stop', onTap: () => unawaited(booth.stopAll())),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
