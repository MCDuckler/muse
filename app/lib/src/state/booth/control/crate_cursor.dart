/// The crate as a controller sees it: a cursor over the queue, moved by the browse
/// buttons, and LOAD puts the record under it on a deck.
///
/// Kept apart from the crate on the screen on purpose: the screen's crate has tabs
/// and searches and a set plan, and which of those a controller's four arrows should
/// steer is a question for the day the hardware is here. Until then the queue is the
/// crate, which is also what the auto mix plays from.
library;

import 'package:flutter/foundation.dart';

import '../../../api/models.dart';
import '../booth.dart';
import '../deck.dart';
import 'binding.dart';

class CrateCursor {
  CrateCursor({required this.booth, required this.items});

  final Booth booth;

  /// The queue, as it is now.
  final List<Track> Function() items;

  /// Where the cursor is, for the screen to show.
  final cursor = ValueNotifier<int>(0);

  BindingHooks get hooks => BindingHooks(load: load, browse: browse);

  void browse(int dx, int dy) {
    final n = items().length;
    if (n == 0) return;
    cursor.value = (cursor.value + dy + dx * 10).clamp(0, n - 1);
  }

  /// The record under the cursor onto [deck] — skipping, from there, anything already
  /// on a deck — and the cursor moves on past it.
  Future<void> load(Deck deck) async {
    final all = items();
    if (all.isEmpty) return;
    final onDecks = {booth.a.track?.id, booth.b.track?.id};
    var i = cursor.value.clamp(0, all.length - 1);
    for (var tries = 0; tries < all.length; tries++) {
      final t = all[(i + tries) % all.length];
      if (onDecks.contains(t.id)) continue;
      await booth.load(deck, t);
      cursor.value = ((i + tries + 1) % all.length);
      return;
    }
  }

  void dispose() => cursor.dispose();
}
