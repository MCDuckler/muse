import '../api/models.dart';

/// A folder and what is filed in it, in the order it was filed.
class FolderShelf {
  const FolderShelf(this.folder, this.playlists);
  final PlaylistFolder folder;
  final List<Playlist> playlists;
}

/// The library's playlists arranged the way the box is read: what is pinned at the
/// top, then the divider cards, then everything loose — Favourites first among the
/// loose, as it always was.
///
/// A pure function of the two lists the server sends, so the same arrangement is drawn
/// on the phone, in the side column on a desk, and in the add-to-playlist sheet.
class LibraryArrangement {
  LibraryArrangement(List<Playlist> playlists, List<PlaylistFolder> folders) {
    final known = {for (final f in folders) f.id};
    final byFolder = <int, List<Playlist>>{};
    for (final p in playlists) {
      if (p.pinned) pinned.add(p);
      final f = p.folderId;
      // A folder the server did not list — one just deleted, say — leaves its lists
      // loose rather than nowhere.
      if (f != null && known.contains(f)) {
        byFolder.putIfAbsent(f, () => []).add(p);
      } else {
        loose.add(p);
      }
    }
    int place(Playlist p) => p.placePos ?? 1 << 30;
    for (final f in folders) {
      final inside = [...?byFolder[f.id]];
      inside.sort((a, b) {
        final c = place(a).compareTo(place(b));
        return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      shelves.add(FolderShelf(f, inside));
    }
  }

  final List<Playlist> pinned = [];
  final List<FolderShelf> shelves = [];
  final List<Playlist> loose = [];

  /// Whether there is anything to arrange at all: one flat list needs no dividers.
  bool get flat => shelves.isEmpty && pinned.isEmpty;

  /// The folder a playlist sits in, if any.
  PlaylistFolder? folderOf(Playlist p) {
    for (final s in shelves) {
      if (s.folder.id == p.folderId) return s.folder;
    }
    return null;
  }
}
