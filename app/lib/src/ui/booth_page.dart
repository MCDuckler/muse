import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/booth/booth.dart';
import '../state/booth/deck.dart' as booth;
import 'booth/crate.dart';
import 'booth/deck_panel.dart';
import 'booth/mixer_strip.dart';
import 'feel.dart';
import 'glass.dart';
import 'mag.dart';
import 'stage/arm_grip.dart';
import 'widths.dart';

/// The booth: two records on the deck, the mixer between them, the crate beside.
///
/// The player's other life. The same records, the same arm, the same printed page —
/// laid out as a room to work in rather than a page to look at. A phone stacks the
/// two decks with the mixer between them and keeps the crate in a drawer; a desk puts
/// the crate down the side, and the keys do what the buttons do.
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

  Future<void> _load(booth.Deck deck, Track track) async {
    final app = context.read<AppState>();
    await app.booth.load(deck, track);
  }

  /// Which deck a record from the crate goes on: whichever is not the master.
  booth.Deck _free(Booth b) => b.other(b.master);

  Future<void> _pick(booth.Deck deck) async {
    final app = context.read<AppState>();
    final b = app.booth;
    if (Width.of(context) != Width.compact) {
      // The crate is on the page: say which deck, and the next tap in it loads there.
      _pickingFor = deck;
      setState(() {});
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

  booth.Deck? _pickingFor;

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final b = context.read<AppState>().booth;
    final k = e.logicalKey;
    Future<void> go() async {
      feel(Feel.commit);
      if (b.inTransition) {
        b.stopTransition();
      } else {
        await b.go(Transition.blend, bars: 16);
      }
    }

    if (k == LogicalKeyboardKey.space) {
      unawaited(go());
    } else if (k == LogicalKeyboardKey.digit1) {
      unawaited(b.a.playing ? b.a.pause() : b.a.play());
    } else if (k == LogicalKeyboardKey.digit2) {
      unawaited(b.b.playing ? b.b.pause() : b.b.play());
    } else if (k == LogicalKeyboardKey.keyQ) {
      unawaited(b.sync(b.a).then((_) => b.align(b.a)));
    } else if (k == LogicalKeyboardKey.keyW) {
      unawaited(b.sync(b.b).then((_) => b.align(b.b)));
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      unawaited(b.setCrossfader(b.crossfader - 0.05));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      unawaited(b.setCrossfader(b.crossfader + 0.05));
    } else if (k == LogicalKeyboardKey.bracketLeft) {
      b.a.loopStart == null ? b.a.loop(4) : b.a.unloop();
    } else if (k == LogicalKeyboardKey.bracketRight) {
      b.b.loopStart == null ? b.b.loop(4) : b.b.unloop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final b = app.booth;
    final scheme = Theme.of(context).colorScheme;
    final compact = Width.of(context) == Width.compact;
    final tint = parseHexColour(b.master.track?.coverColor);

    return ArmReach(
      child: Focus(
        focusNode: _focus,
        autofocus: !compact,
        onKeyEvent: _keys,
        child: AnimatedBuilder(
          animation: b,
          builder: (context, _) {
            final decks = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DeckPanel(booth: b, deck: b.a, compact: compact, onLoad: () => _pick(b.a)),
                const SizedBox(height: 8),
                MixerStrip(booth: b, compact: compact),
                const SizedBox(height: 8),
                DeckPanel(booth: b, deck: b.b, compact: compact, onLoad: () => _pick(b.b)),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'Keys: space go/stop · 1 2 play · Q W sync · ← → fader · [ ] loop',
                      style: Mag.typewriter(10, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            );

            return Scaffold(
              appBar: AppBar(
                title: const Text('The booth'),
                actions: [
                  if (compact)
                    IconButton(
                      icon: const Icon(Icons.inventory_2_outlined),
                      tooltip: 'The crate',
                      onPressed: () => _pick(_free(b)),
                    ),
                ],
              ),
              body: AmbientBackdrop(
                colour: tint,
                child: compact
                    ? ListView(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 40),
                        children: [decks],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 8, 40),
                              child: decks,
                            ),
                          ),
                          SizedBox(
                            width: 360,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
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
                                        _pickingFor = null;
                                        unawaited(_load(deck, t));
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}
