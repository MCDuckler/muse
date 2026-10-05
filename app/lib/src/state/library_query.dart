import '../api/models.dart';
import 'library_arrangement.dart';

/// How the library's playlists are shown: in what order, which of them, and as what.
/// Remembered per device — see AppState.libraryView.
enum LibrarySort {
  recent('Recently opened'),
  added('Recently made'),
  name('A to Z'),
  source('By where they are from'),
  hand('Hand order');

  const LibrarySort(this.label);
  final String label;
}

enum LibraryLook { list, compact, grid }

/// Which of the playlists: all of them, or one kind.
enum LibraryChip {
  all('All'),
  mine('Yours'),
  mirrors('Mirrors'),
  others('From others'),
  mixes('Mixes'),
  stations('Stations'),
  crates('Crates'),
  downloaded('Downloaded');

  const LibraryChip(this.label);
  final String label;

  bool keeps(Playlist p) => switch (this) {
        all => true,
        mine => p.mine && !p.isMirror && !p.isMix && !p.isStation,
        mirrors => p.isMirror,
        others => p.saved,
        mixes => p.isMix,
        // Written by the machine from a song, a record, an act or a genre.
        stations => p.isStation,
        crates => p.autoSplit,
        // Every song in it has its audio here: what will play on the train.
        downloaded => p.itemCount > 0 && p.waiting == 0,
      };
}

/// The library asked a question: these playlists, in this order, matching these words.
///
/// Pure, so the phone's page, the desk's column and the tests all read the same
/// answer. With nothing typed, the box is read in its arrangement — pinned, dividers,
/// loose — each part in the chosen order. With a name typed the dividers come out and
/// what matches is one list, each row saying which folder it was behind.
class LibraryQuery {
  LibraryQuery({
    required List<Playlist> playlists,
    required List<PlaylistFolder> folders,
    this.sort = LibrarySort.recent,
    this.chip = LibraryChip.all,
    String query = '',
  })  : query = query.trim(),
        _arranged = LibraryArrangement(playlists, folders) {
    final q = this.query.toLowerCase();
    final kept = [for (final p in playlists) if (chip.keeps(p)) p];
    if (q.isEmpty) {
      pinned = order(_arranged.pinned.where(chip.keeps).toList());
      shelves = [
        for (final s in _arranged.shelves)
          FolderShelf(s.folder, order(s.playlists.where(chip.keeps).toList())),
      ];
      loose = order([for (final p in _arranged.loose) if (chip.keeps(p) && !p.pinned) p]);
      matchedFolders = const [];
      matches = const [];
    } else {
      pinned = const [];
      shelves = const [];
      loose = const [];
      matchedFolders = [
        for (final s in _arranged.shelves)
          if (s.folder.name.toLowerCase().contains(q)) s
      ];
      matches = order([for (final p in kept) if (p.name.toLowerCase().contains(q)) p]);
    }
    recent = [
      for (final p in playlists)
        if (p.lastOpenedAt != null && !p.isFavourites) p
    ]..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    // Which chips are worth offering: one with nothing behind it is a button that
    // empties the page.
    chips = [
      LibraryChip.all,
      for (final c in LibraryChip.values)
        if (c != LibraryChip.all && playlists.any(c.keeps))
          // "Downloaded" only means something once something is not.
          if (c != LibraryChip.downloaded || playlists.any((p) => p.waiting > 0)) c,
    ];
  }

  final LibrarySort sort;
  final LibraryChip chip;
  final String query;
  final LibraryArrangement _arranged;

  late final List<Playlist> pinned;
  late final List<FolderShelf> shelves;
  late final List<Playlist> loose;

  /// With words typed: the folders and the playlists called that.
  late final List<FolderShelf> matchedFolders;
  late final List<Playlist> matches;

  /// What was opened lately, most recent first.
  late final List<Playlist> recent;
  late final List<LibraryChip> chips;

  bool get searching => query.isNotEmpty;

  /// Whether the rows can be dragged into an order: only the hand order, of the whole
  /// box — a part of it put in order would write an order for the rest too.
  bool get reorderable => sort == LibrarySort.hand && !searching && chip == LibraryChip.all;
  bool get flat => _arranged.flat;
  bool get nothing => searching
      ? matches.isEmpty && matchedFolders.isEmpty
      : pinned.isEmpty && loose.isEmpty && shelves.every((s) => s.playlists.isEmpty);

  PlaylistFolder? folderOf(Playlist p) => _arranged.folderOf(p);

  /// Favourites first whatever the order: it is the heart, not a list in the race.
  List<Playlist> order(List<Playlist> lists) {
    final out = [...lists];
    int byName(Playlist a, Playlist b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    int nullsLast<T extends Comparable<dynamic>>(T? a, T? b, {bool desc = false}) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return desc ? b.compareTo(a) : a.compareTo(b);
    }
    out.sort((a, b) {
      if (a.isFavourites != b.isFavourites) return a.isFavourites ? -1 : 1;
      final c = switch (sort) {
        LibrarySort.recent => nullsLast(a.lastOpenedAt, b.lastOpenedAt, desc: true),
        LibrarySort.added => nullsLast(a.createdAt, b.createdAt, desc: true),
        LibrarySort.name => 0,
        LibrarySort.source => _sourceRank(a).compareTo(_sourceRank(b)),
        LibrarySort.hand => nullsLast(a.placePos, b.placePos),
      };
      return c != 0 ? c : byName(a, b);
    });
    return out;
  }

  static int _sourceRank(Playlist p) {
    if (p.saved) return 9;
    return switch (p.kind) {
      'favourites' => 0,
      'local' => 1,
      'spotify' => 2,
      'youtube' || 'ytmusic' => 3,
      'deezer' => 4,
      'soundcloud' => 5,
      'bandcamp' => 6,
      _ => 7,
    };
  }
}
