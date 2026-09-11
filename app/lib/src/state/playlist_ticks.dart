/// Which playlists a set of songs is already on, and which ones you have asked for.
///
/// The sheet that adds songs to playlists can now take them off again — a tick-box
/// that only goes one way is a button in disguise — and that makes "what changed"
/// worth keeping honest in one place. Nothing is written for a list whose tick was
/// never touched, and nothing is written twice: a tap over and back leaves no change
/// behind it.
class PlaylistTicks {
  PlaylistTicks({required this.songs});

  /// How many songs are being placed. A list holding all of them is ticked; a list
  /// holding some of them is the third state, which is neither a promise that they
  /// are all there nor an invitation to take the ones that are away.
  final int songs;

  /// How many of those songs each playlist held when the sheet opened.
  Map<int, int> held = const {};

  /// The ticks that have been changed by hand, by playlist id.
  final Map<int, bool> wanted = {};

  /// true — all of them are on it. null — some are. false — none are.
  bool? stateOf(int playlistId) {
    final choice = wanted[playlistId];
    if (choice != null) return choice;
    final n = held[playlistId] ?? 0;
    if (n == 0) return false;
    if (n >= songs) return true;
    return null;
  }

  /// A tick from "some" goes to "all", not to "none": the reason to touch a partly
  /// filled list is almost always to finish filling it.
  void toggle(int playlistId) {
    wanted[playlistId] = stateOf(playlistId) != true;
  }

  /// The lists to add to and the lists to take from, in the order given.
  ///
  /// Asymmetric on purpose, because the two ends of the third state are not the same
  /// question: a list that already holds every one of them has nothing to add, and a
  /// list that holds two of four has something to take away. Going by "was it full"
  /// alone would leave those two behind and call the box a liar.
  ({List<int> add, List<int> remove}) plan(Iterable<int> playlistIds) {
    final add = <int>[], remove = <int>[];
    for (final id in playlistIds) {
      final choice = wanted[id];
      if (choice == null) continue;
      final n = held[id] ?? 0;
      if (choice && n < songs) add.add(id);
      if (!choice && n > 0) remove.add(id);
    }
    return (add: add, remove: remove);
  }

  int changes(Iterable<int> playlistIds) {
    final p = plan(playlistIds);
    return p.add.length + p.remove.length;
  }
}
