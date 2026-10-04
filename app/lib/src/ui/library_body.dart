import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/library_arrangement.dart';
import '../state/library_query.dart';
import 'album_grid.dart';
import 'artwork.dart';
import 'folders.dart';
import 'library_page.dart' show PlaylistPage, PlaylistRow;
import 'mag.dart';
import 'mag_parts.dart';
import 'pane.dart';
import 'search_page.dart' show searchAsked;
import 'service_shelf.dart';
import 'widths.dart';

/// The bar over the playlists, and it stays there while they scroll: a box to type a
/// name in, the order, the look, and New. Two rows; the second is the kinds.
class LibraryBar extends SliverPersistentHeaderDelegate {
  LibraryBar({
    required this.query,
    required this.controller,
    required this.onChanged,
    required this.count,
    this.focus,
  });

  final LibraryQuery query;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final int count;
  final FocusNode? focus;

  static const height = 100.0;

  @override
  double get maxExtent => height;
  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant LibraryBar old) =>
      old.query != query || old.count != count;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final look = query.sort;
    return Container(
      // Over the rows as they pass underneath: the page's own colour, nearly solid.
      color: scheme.surface.withValues(alpha: overlapsContent ? 0.96 : 1),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    onChanged: (_) => onChanged(),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (q) => _handOff(context, app, q),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: count == 0
                          ? 'Find a playlist'
                          : 'Find one of $count playlists, or a folder',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Clear',
                              onPressed: () {
                                controller.clear();
                                onChanged();
                              },
                            ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<LibrarySort>(
                tooltip: 'Order · ${look.label}',
                icon: const Icon(Icons.sort, size: 22),
                initialValue: look,
                onSelected: (s) => app.setLibraryView(sort: s),
                itemBuilder: (context) => [
                  for (final s in LibrarySort.values)
                    PopupMenuItem(
                      value: s,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 28,
                            child: s == look ? const Icon(Icons.check, size: 18) : null),
                        Flexible(child: Text(s.label, overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                ],
              ),
              PopupMenuButton<LibraryLook>(
                tooltip: 'Look',
                icon: Icon(switch (app.libraryLook) {
                  LibraryLook.list => Icons.view_list_outlined,
                  LibraryLook.compact => Icons.view_headline,
                  LibraryLook.grid => Icons.grid_view_outlined,
                }, size: 22),
                initialValue: app.libraryLook,
                onSelected: (l) => app.setLibraryView(look: l),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: LibraryLook.list, child: Text('List')),
                  PopupMenuItem(value: LibraryLook.compact, child: Text('Compact list')),
                  PopupMenuItem(value: LibraryLook.grid, child: Text('Covers')),
                ],
              ),
              const SizedBox(width: 2),
              PressButton(label: 'New', onTap: () => newInLibrary(context, app)),
            ],
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
              children: [
                for (final c in query.chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _Chip(
                      label: c.label,
                      on: c == query.chip,
                      onTap: () => app.setLibraryView(chip: c),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Enter in the box: what the library could not find by name, the Search tab looks
  /// for among the songs, records and artists.
  static void _handOff(BuildContext context, AppState app, String q) {
    if (q.trim().isEmpty) return;
    searchAsked.value = (query: q.trim(), where: 'library');
    app.setHomeTab(Tabs.search);
  }
}

/// A kind, as a word in a ruled box: on, it is ink with the word knocked out.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: on,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 10, 4),
          decoration: BoxDecoration(
            color: on ? scheme.onSurface : null,
            border: Border.all(color: scheme.onSurface, width: 1.2),
          ),
          child: Text(label.toUpperCase(),
              style: Mag.flag(10, color: on ? scheme.surface : scheme.onSurface)),
        ),
      ),
    );
  }
}

/// A line over a group of rows: PINNED, EVERYTHING ELSE.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key, this.tight = false});
  final String text;
  final bool tight;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, tight ? 6 : 12, 16, 2),
        child: Text(text.toUpperCase(),
            style: Mag.typewriter(10,
                color: Theme.of(context).colorScheme.onSurfaceVariant, bold: true)),
      );
}

/// The playlists as rows, built one at a time as they come on screen.
///
/// The box in its arrangement — pinned, dividers with their lists behind them,
/// everything else — or, with words typed, the folders and lists called that, each row
/// saying which divider it was behind. Returned as a list of row builders so the page
/// can hand it to a sliver.
List<Widget> libraryRows(BuildContext context, LibraryQuery q, {required bool compact}) {
  final scheme = Theme.of(context).colorScheme;
  if (q.searching) {
    return [
      for (final s in q.matchedFolders) FolderCard(shelf: s, shrunk: compact),
      for (final p in q.matches)
        PlaylistRow(playlist: p, shrunk: compact, under: q.folderOf(p)?.name),
      if (q.nothing)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text('No playlist or folder called that.',
              style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant)),
        ),
      _HandOffRow(query: q.query),
    ];
  }
  return [
    if (q.pinned.isNotEmpty) ...[
      const GroupLabel('Pinned'),
      for (final p in q.pinned) PlaylistRow(playlist: p, shrunk: compact),
    ],
    for (final s in q.shelves) FolderCard(shelf: s, shrunk: compact),
    if (!q.flat && q.loose.isNotEmpty) const GroupLabel('Everything else'),
    for (final p in q.loose) PlaylistRow(playlist: p, shrunk: compact),
    if (q.nothing)
      Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
            child: Text(q.chip == LibraryChip.all
                ? 'No playlists yet.'
                : 'Nothing of that kind here.')),
      ),
  ];
}

/// The last row of a search: what the library did not find by name, the Search tab
/// looks for among the songs.
class _HandOffRow extends StatelessWidget {
  const _HandOffRow({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return ListTile(
      leading: const Icon(Icons.manage_search),
      title: Text('Search songs, records and artists for “$query”'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => LibraryBar._handOff(context, app, query),
    );
  }
}

/// The playlists as covers: a wall of faces, the way a record shop looks from the door.
/// Folders are cards among them, their first four faces in a square.
class LibraryGrid extends StatelessWidget {
  const LibraryGrid({super.key, required this.query, required this.usable});
  final LibraryQuery query;
  final double usable;

  @override
  Widget build(BuildContext context) {
    final q = query;
    final wide = Width.of(context) == Width.expanded;
    final grid = AlbumGrid.of(
        usable: usable, wide: wide,
        textScale: MediaQuery.textScalerOf(context).scale(14) / 14);
    final cells = <Widget>[
      if (q.searching) ...[
        for (final s in q.matchedFolders) _FolderTile(shelf: s, size: grid.tile, captions: grid.captions),
        for (final p in q.matches) _PlaylistTile(playlist: p, size: grid.tile, captions: grid.captions),
      ] else ...[
        for (final p in q.pinned) _PlaylistTile(playlist: p, size: grid.tile, captions: grid.captions),
        for (final s in q.shelves) _FolderTile(shelf: s, size: grid.tile, captions: grid.captions),
        for (final p in q.loose) _PlaylistTile(playlist: p, size: grid.tile, captions: grid.captions),
      ],
    ];
    if (cells.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(child: Text(q.searching ? 'No playlist or folder called that.' : 'No playlists yet.')),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: grid.across,
          mainAxisExtent: grid.extent,
          crossAxisSpacing: grid.gapAcross,
          mainAxisSpacing: grid.gapDown,
        ),
        delegate: SliverChildBuilderDelegate((context, i) => cells[i], childCount: cells.length),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.playlist, required this.size, required this.captions});
  final Playlist playlist;
  final double size;
  final bool captions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = playlist;
    final face = p.isFavourites
        ? Container(
            width: size,
            height: size,
            color: scheme.surfaceContainerHighest,
            child: Icon(Icons.favorite, size: size * 0.4, color: scheme.primary),
          )
        : PlaylistArt(playlist: p, size: size, radius: 2, small: size <= 160);
    void open() => openPage(context, (_) => PlaylistPage(playlistId: p.id, name: p.name));
    if (!captions) {
      return Tooltip(
        message: '${p.name} · ${p.itemCount} songs',
        child: InkWell(onTap: open, child: face),
      );
    }
    return InkWell(
      onTap: open,
      onLongPress: () => moveToFolderSheet(context, context.read<AppState>(), p),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(children: [
            face,
            if (p.pinned)
              Positioned(
                  right: 4, top: 4,
                  child: Icon(Icons.push_pin, size: 14, color: scheme.primary)),
          ]),
          const SizedBox(height: 6),
          Text(p.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface, fontWeight: FontWeight.w600)),
          Text(
              [
                if (p.isMirror) serviceLabel(p.kind),
                if (p.saved) 'from ${p.ownerName ?? 'somebody'}',
                p.itemCount == 1 ? '1 song' : '${p.itemCount} songs',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.shelf, required this.size, required this.captions});
  final FolderShelf shelf;
  final double size;
  final bool captions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final faces = shelf.playlists.take(4).toList();
    final inner = (size - 6) / 2;
    final square = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurface, width: 1.5),
        color: scheme.surfaceContainerLow,
      ),
      padding: const EdgeInsets.all(1.5),
      child: faces.isEmpty
          ? Icon(Icons.folder_outlined, size: size * 0.4, color: scheme.onSurfaceVariant)
          : Wrap(
              spacing: 1,
              runSpacing: 1,
              children: [
                for (final p in faces)
                  p.isFavourites
                      ? SizedBox(
                          width: inner, height: inner,
                          child: Icon(Icons.favorite, color: scheme.primary))
                      : PlaylistArt(playlist: p, size: inner, radius: 0),
              ],
            ),
    );
    void open() => openPage(context, (_) => FolderPage(folderId: shelf.folder.id));
    if (!captions) {
      return Tooltip(
          message: '${shelf.folder.name} · ${shelf.playlists.length} playlists',
          child: InkWell(onTap: open, child: square));
    }
    return InkWell(
      onTap: open,
      onLongPress: () => folderMenu(context, context.read<AppState>(), shelf),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          square,
          const SizedBox(height: 6),
          Row(children: [
            Container(
              color: scheme.onSurface,
              padding: const EdgeInsets.fromLTRB(5, 2, 5, 1),
              child: Text('FOLDER', style: Mag.flag(8, color: scheme.surface)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(shelf.folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface, fontWeight: FontWeight.w600)),
            ),
          ]),
          Text('${shelf.playlists.length} ${shelf.playlists.length == 1 ? 'playlist' : 'playlists'}',
              style: Mag.typewriter(10, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// What was opened lately, as a row of faces to go straight back to. Only when the
/// list underneath is in some other order — in the recent order it would say the same
/// thing twice.
class RecentsStrip extends StatelessWidget {
  const RecentsStrip({super.key, required this.recent});
  final List<Playlist> recent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('Opened lately', tight: true),
        SizedBox(
          height: 118,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            itemCount: recent.length,
            itemBuilder: (context, i) {
              final p = recent[i];
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: InkWell(
                  onTap: () => openPage(
                      context, (_) => PlaylistPage(playlistId: p.id, name: p.name)),
                  child: SizedBox(
                    width: 72,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PlaylistArt(playlist: p, size: 72, radius: 2),
                        const SizedBox(height: 4),
                        Text(p.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.typewriter(10, color: scheme.onSurface)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One line for the other services: how much of them is here, and the way to the page
/// that lists all of them.
class ServicesRow extends StatelessWidget {
  const ServicesRow({super.key});

  @override
  Widget build(BuildContext context) {
    final mirrored = context.select<AppState, int>(
        (a) => a.playlists.where((p) => p.isMirror).length);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 0),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.35)),
            bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.35)),
          ),
        ),
        child: ListTile(
          leading: Icon(Icons.cloud_outlined, color: scheme.primary),
          title: Text('FROM YOUR SERVICES', style: Mag.flag(12, color: scheme.onSurface)),
          subtitle: Text(
              mirrored == 0
                  ? 'Spotify, YouTube Music, Deezer, SoundCloud, Bandcamp — their lists, ready to mirror'
                  : '$mirrored mirrored here · every list on every connected service',
              style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(context, (_) => const ServiceListsPage()),
        ),
      ),
    );
  }
}
