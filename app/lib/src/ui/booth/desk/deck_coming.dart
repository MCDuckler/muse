import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../state/booth/automix.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../artwork.dart';
import '../../mag.dart';
import 'console.dart';

/// What is on its way to a deck, said on the deck itself.
///
/// Two things, which used to show as nothing at all. A record being put on — by a
/// click, a drag, the Auto DJ — takes seconds: its beat is asked of the house, its
/// parts looked for, the engine handed the file. All that time the deck went on
/// showing the record before it, or the empty platter, and a click that had been
/// heard looked like one that had not. And the Auto DJ chooses what comes next well
/// before that record is on the free deck; until it was, the only word of it was a
/// line in the bar at the top of the room.
class DeckComing {
  const DeckComing._(this.track, this.loading, this.line);

  final Track track;

  /// Being put on now, rather than chosen and waiting its turn.
  final bool loading;

  /// What is happening to it, in a few words.
  final String line;

  /// What is coming to [deck], if anything.
  static DeckComing? of(Booth booth, engine.Deck deck) {
    final c = deck.coming;
    if (c != null) return DeckComing._(c, true, 'LOADING');
    final auto = booth.auto;
    final next = auto.next;
    // The Auto DJ's next, chosen but not on this deck yet: the free deck is where it
    // goes. Not while a transition runs — then the free deck is the one going out.
    if (!auto.running || next == null || booth.busy || identical(deck, booth.master)) return null;
    if (deck.track?.id == next.id) return null;
    if (booth.other(deck).playing && deck.playing) return null;
    final why = switch (auto.state) {
      AutoState.holding => 'WAITING FOR IT',
      _ => (auto.working ?? 'getting it ready').toUpperCase(),
    };
    return DeckComing._(next, false, 'UP NEXT · $why');
  }
}

/// [DeckComing] drawn over a deck's platter: the record's cover, a ring going round,
/// the word in the deck's colour and the title under it. Nothing when nothing comes.
class DeckComingCard extends StatelessWidget {
  const DeckComingCard({super.key, required this.booth, required this.deck, required this.side});
  final Booth booth;
  final engine.Deck deck;
  final double side;

  @override
  Widget build(BuildContext context) {
    final c = DeckComing.of(booth, deck);
    if (c == null) return const SizedBox.shrink();
    final colour = Console.deck(deck.name);
    final art = (side * 0.34).clamp(32.0, 96.0);
    final small = side < 140;
    // Loading covers the old record (it is going); UP NEXT sits over an empty or
    // finished platter without hiding what is still there to be read.
    return IgnorePointer(
      child: Container(
        width: side,
        height: side,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Console.panel.withValues(alpha: c.loading ? 0.88 : 0.78),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: art + 14,
              height: art + 14,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox(
                  width: art + 14,
                  height: art + 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colour,
                    backgroundColor: Console.line,
                    value: c.loading ? null : _progressOf(c.track),
                  ),
                ),
                Artwork(track: c.track, size: art, radius: art / 2),
              ]),
            ),
            SizedBox(height: small ? 4 : 8),
            Container(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 1),
              decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3)),
              child: Text(c.loading ? 'LOADING' : 'UP NEXT',
                  style: Console.label(small ? 7.5 : 8.5, color: Console.ground)),
            ),
            SizedBox(height: small ? 2 : 5),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: side * 0.72),
              child: Text(c.track.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Mag.title(small ? 11 : 14, color: Console.ink)),
            ),
            if (!c.loading && !small)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: side * 0.7),
                child: Text(c.line.replaceFirst('UP NEXT · ', ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Console.label(7.5, color: Console.quiet)),
              ),
          ],
        ),
      ),
    );
  }

  /// A record still downloading shows how far it has got; anything else just turns.
  static double? _progressOf(Track t) => t.isReady ? null : t.progressFraction;
}
