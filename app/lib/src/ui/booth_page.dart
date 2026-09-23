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
  bool _crateOpen = true;
  engine.Deck? _pickingFor;

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
    if (Width.of(context) != Width.compact) {
      // The crate is on the page: say which deck, and the next tap in it loads there.
      setState(() {
        _crateOpen = true;
        _pickingFor = deck;
      });
      return;
    }
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
  /// What a desk's hands do without reaching for the mouse. Printed at the foot of
  /// the room, because a shortcut nobody is told about is a shortcut nobody uses.
  static const keysLegend =
      'space go · 1 2 play · Q W sync · Z X on the one · ← → fader · shift ← → nudge · '
      '[ ] loop · F G kill bass · M mix now · N not that one';

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final b = context.read<AppState>().booth;
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final master = b.master;

    void nudge(engine.Deck d, int ms) => unawaited(d.nudge(Duration(milliseconds: ms)));
    void killBass(engine.Deck d) {
      feel(Feel.pick);
      unawaited(b.kill(d, 0, !b.eqOf(d).lowKilled));
    }

    if (k == LogicalKeyboardKey.space) {
      feel(Feel.commit);
      if (b.inTransition) {
        b.stopTransition();
      } else {
        unawaited(b.go(Transition.blend, bars: 16));
      }
    } else if (k == LogicalKeyboardKey.digit1) {
      unawaited(b.a.playing ? b.a.pause() : b.a.play());
    } else if (k == LogicalKeyboardKey.digit2) {
      unawaited(b.b.playing ? b.b.pause() : b.b.play());
    } else if (k == LogicalKeyboardKey.keyQ) {
      unawaited(b.sync(b.a).then((ok) => ok ? b.align(b.a) : null));
    } else if (k == LogicalKeyboardKey.keyW) {
      unawaited(b.sync(b.b).then((ok) => ok ? b.align(b.b) : null));
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
            builder: (context, _) => Scaffold(
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
                    icon: Icon(compact
                        ? Icons.inventory_2_outlined
                        : _crateOpen
                            ? Icons.keyboard_double_arrow_right
                            : Icons.inventory_2_outlined),
                    tooltip: compact
                        ? 'The crate'
                        : _crateOpen
                            ? 'Hide the crate'
                            : 'The crate',
                    onPressed: compact
                        ? () => _pick(_free(b))
                        : () => setState(() => _crateOpen = !_crateOpen),
                  ),
                ],
              ),
              body: AmbientBackdrop(
                colour: tint,
                child: compact ? _phone(context, b) : _desk(context, b),
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

  // ------------------------------------------------------------------ a desk
  /// Below this, the room does not fit standing up and is scrolled instead: the
  /// waveforms keep a usable height and the decks keep their controls, rather than
  /// both being squeezed until neither can be read.
  static const _standingRoom = 840.0;

  Widget _desk(BuildContext context, Booth b) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 10, 8),
            child: LayoutBuilder(builder: (context, room) {
              final standing = room.maxHeight >= _standingRoom;
              // The two records' shapes, facing each other across the meter that
              // says how far apart their beats are: the pair of things a DJ actually
              // watches, so they are the top of the room. Standing up they take
              // whatever height is spare, because a taller waveform is more of the
              // song in front of you and the decks need no more room than their
              // controls.
              Widget waves(double lane) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _WaveDeck(booth: b, deck: b.a, height: lane),
                      const PhaseMeter(booth: null, height: 24),
                      _WaveDeck(booth: b, deck: b.b, mirrored: true, height: lane),
                    ],
                  );
              // And under them the room: a deck either side of the mixer.
              final decks = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: DeckPanel(
                        booth: b,
                        deck: b.a,
                        wide: true,
                        showWave: false,
                        record: standing ? 196 : 150,
                        onLoad: () => _pick(b.a)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(width: 340, child: MixerStrip(booth: b, wide: true)),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: DeckPanel(
                        booth: b,
                        deck: b.b,
                        wide: true,
                        showWave: false,
                        record: standing ? 196 : 150,
                        onLoad: () => _pick(b.b)),
                  ),
                ],
              );
              final legend = Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(keysLegend,
                    style: Mag.typewriter(9.5, color: scheme.onSurfaceVariant)),
              );
              if (!standing) {
                // Not enough wall for the whole room: it scrolls, and nothing is
                // squeezed to fit something else in.
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [waves(96), const SizedBox(height: 10), decks, legend],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LayoutBuilder(builder: (context, c) {
                      final lane = ((c.maxHeight - 24) / 2).clamp(72.0, 230.0);
                      return waves(lane);
                    }),
                  ),
                  const SizedBox(height: 10),
                  decks,
                  legend,
                ],
              );
            }),
          ),
        ),
        if (_crateOpen)
          SizedBox(
            width: 330,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_pickingFor != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                      child: Text('Tap a record for deck ${_pickingFor!.name}',
                          style: Mag.flag(9, color: scheme.primary)),
                    ),
                  Expanded(
                    child: Crate(
                      booth: b,
                      onPick: (t) {
                        final deck = _pickingFor ?? _free(b);
                        setState(() => _pickingFor = null);
                        unawaited(_load(deck, t));
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One deck's shape, with its name and what it is over the top of it.
class _WaveDeck extends StatelessWidget {
  const _WaveDeck(
      {required this.booth, required this.deck, this.mirrored = false, this.height = 86});
  final Booth booth;
  final engine.Deck deck;
  final bool mirrored;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = deck.track;
    final isMaster = identical(booth.master, deck);
    final head = Row(
      children: [
        Text(deck.name,
            style: Mag.numerals(15, color: isMaster ? scheme.primary : scheme.onSurface)),
        const SizedBox(width: 8),
        // One row of words that takes the room the numbers do not: two Flexibles
        // beside a Spacer share the free space between them, which leaves the
        // numbers stranded in the middle of the lane.
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(t?.displayTitle ?? 'Nothing on',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.title(12.5, color: scheme.onSurface)),
              ),
              if (t != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(t.artistLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (deck.loopBars != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text('LOOP ${deck.loopBars}', style: Mag.flag(8, color: scheme.primary)),
          ),
        if (deck.bpm != null)
          Text(deck.bpm!.toStringAsFixed(1),
              style: Mag.numerals(13, color: scheme.onSurface)),
        if (deck.timing?.camelot != null) ...[
          const SizedBox(width: 8),
          Text(deck.timing!.camelot!,
              style: Mag.typewriter(10, color: scheme.onSurfaceVariant, bold: true)),
        ],
      ],
    );
    final wave = WaveLane(booth: booth, deck: deck, height: height, mirrored: mirrored);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: mirrored ? [wave, const SizedBox(height: 2), head] : [head, const SizedBox(height: 2), wave],
    );
  }
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
            '${left == null ? '' : left.isNegative ? '' : ' · ${auto.plan?.kind.name ?? 'mix'} in ${left.inSeconds}s'}',
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
