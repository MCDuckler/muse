import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/library_arrangement.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'library_page.dart' show PlaylistRow;
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'motion.dart';
import 'snack.dart';
import 'widths.dart';

/// A divider card in the record box: the folder's name on its tab, the faces of the
/// first few lists in it, how many there are. Tapped, it opens in place and the lists
/// in it stand under it, indented behind a rule; how it was left is remembered the way
/// the library's sections are.
class FolderCard extends StatelessWidget {
  const FolderCard({super.key, required this.shelf, this.shrunk = false, this.reorderable = false});

  final FolderShelf shelf;
  final bool shrunk;

  /// In the hand order, the lists behind the card drag into their places.
  final bool reorderable;

  String get _foldId => 'folder:${shelf.folder.id}';

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final closed =
        context.select<AppState, bool>((a) => a.closedSections.contains(_foldId));
    final folder = shelf.folder;
    final lists = shelf.playlists;
    final faces = lists.take(4).toList();

    final head = InkWell(
      onTap: () => app.setSectionClosed(_foldId, !closed),
      onLongPress: () => folderMenu(context, app, shelf),
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, shrunk ? 4 : 8, 0, shrunk ? 4 : 8),
        child: Row(
          children: [
            // The tab of the card: the name knocked out of ink, the way the library's
            // own section heads are set, a size down.
            Container(
              color: scheme.onSurface,
              padding: const EdgeInsets.fromLTRB(8, 3, 8, 2),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.45),
              child: Text(folder.name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Mag.flag(shrunk ? 10 : 11, color: scheme.surface)),
            ),
            const SizedBox(width: 10),
            if (!shrunk)
              Expanded(
                child: faces.isEmpty
                    ? Text('Nothing filed here yet',
                        style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant))
                    : Row(
                        children: [
                          for (final p in faces)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: p.isFavourites
                                  ? Icon(Icons.favorite, size: 22, color: scheme.primary)
                                  : PlaylistArt(playlist: p, size: 26, radius: 2),
                            ),
                        ],
                      ),
              )
            else
              const Spacer(),
            Text('${lists.length}',
                style: Mag.numerals(shrunk ? 15 : 18, color: scheme.primary)),
            IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'Folder',
              visualDensity: VisualDensity.compact,
              onPressed: () => folderMenu(context, app, shelf),
            ),
            Icon(closed ? Icons.expand_more : Icons.expand_less,
                size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlaylistDrop(
          into: folder.id,
          builder: (context, hovering) => Container(
            margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            decoration: BoxDecoration(
              color: hovering ? scheme.primary.withValues(alpha: 0.12) : null,
              border: Border.all(
                  color: hovering ? scheme.primary : scheme.onSurface, width: 1.5),
            ),
            child: Semantics(
              button: true,
              expanded: !closed,
              label: '${folder.name}, ${lists.length} playlists',
              child: head,
            ),
          ),
        ),
        AnimatedSize(
          duration: moving(context, Motion.base),
          curve: Motion.enter,
          alignment: Alignment.topCenter,
          child: closed
              ? const SizedBox(height: 0)
              : Container(
                  margin: const EdgeInsets.only(left: 20, right: 8),
                  decoration: BoxDecoration(
                    border: Border(
                        left: BorderSide(
                            color: scheme.onSurface.withValues(alpha: 0.35), width: 1.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (reorderable)
                        ReorderableListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          onReorderItem: (from, to) =>
                              reorderShelf(context, app, lists, folder.id, from, to),
                          children: [
                            for (var i = 0; i < lists.length; i++)
                              handledRow(context, i,
                                  PlaylistRow(key: ValueKey(lists[i].id), playlist: lists[i], shrunk: shrunk)),
                          ],
                        )
                      else
                        for (final p in lists)
                          DraggablePlaylist(playlist: p, child: PlaylistRow(playlist: p, shrunk: shrunk)),
                      if (lists.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                          child: Text(
                              'Hold a playlist, or open its menu, and move it here.',
                              style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// A row with a handle to drag it into its place, in the hand order.
Widget handledRow(BuildContext context, int index, Widget row) => Material(
      key: ValueKey('hand-$index-${row.key}'),
      // The row is lifted out of the page while it is dragged, and a lifted ListTile
      // wants a sheet of its own under it.
      type: MaterialType.transparency,
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 2),
              child: Icon(Icons.drag_indicator,
                  size: 20, color: Theme.of(context).colorScheme.outline),
            ),
          ),
          Expanded(child: row),
        ],
      ),
    );

/// A shelf's rows moved by hand: the new order written down whole.
Future<void> reorderShelf(BuildContext context, AppState app, List<Playlist> shelf,
    int? folderId, int from, int to) async {
  final ids = [for (final p in shelf) p.id];
  final moved = ids.removeAt(from);
  ids.insert(to, moved);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await app.api.orderPlaylists(ids, folderId: folderId);
    await app.refreshPlaylists();
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// File a dragged playlist where it was dropped, and say so. [into] null is the box.
Future<void> dropPlaylist(BuildContext context, AppState app, Playlist p, int? into) async {
  if (p.folderId == into || p.isFavourites) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await app.api.placePlaylist(p.id, folderId: into);
    await app.refreshPlaylists();
    if (into != null) app.setSectionClosed('folder:$into', false);
    final name = into == null
        ? null
        : app.folders.where((f) => f.id == into).map((f) => f.name).firstOrNull;
    messenger.say(snack(Text(name == null
        ? '"${p.name}" is out of its folder'
        : '"${p.name}" is in "$name"')));
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// A row that can be picked up and carried to a folder. A long press lifts it on a
/// phone; a mouse drags it straight off. Favourites stays where it is.
class DraggablePlaylist extends StatelessWidget {
  const DraggablePlaylist({super.key, required this.playlist, required this.child, this.width = 280});
  final Playlist playlist;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (playlist.isFavourites) return child;
    final scheme = Theme.of(context).colorScheme;
    final ghost = Material(
      elevation: 6,
      color: scheme.surface,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(children: [
            PlaylistArt(playlist: playlist, size: 32, radius: 2),
            const SizedBox(width: 10),
            Expanded(
              child: Text(playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ]),
        ),
      ),
    );
    return LongPressDraggable<Playlist>(
      data: playlist,
      // A mouse wants no hold; a finger does, or every scroll is a drag.
      delay: const Duration(milliseconds: 350),
      feedback: ghost,
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

/// Somewhere a carried playlist can be put down: a folder, or the box itself.
class PlaylistDrop extends StatelessWidget {
  const PlaylistDrop({super.key, required this.into, required this.builder});

  /// The folder, or null for out of every folder.
  final int? into;
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  Widget build(BuildContext context) => DragTarget<Playlist>(
        onWillAcceptWithDetails: (d) => d.data.folderId != into && !d.data.isFavourites,
        onAcceptWithDetails: (d) =>
            dropPlaylist(context, context.read<AppState>(), d.data, into),
        builder: (context, candidates, _) => builder(context, candidates.isNotEmpty),
      );
}

/// What can be done to a folder: played, renamed, given a new list, taken away.
Future<void> folderMenu(BuildContext context, AppState app, FolderShelf shelf) async {
  final folder = shelf.folder;
  final picked = await ask<String>(
    context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(folder.name,
                style: Theme.of(sheet).textTheme.titleSmall),
            subtitle: Text('${shelf.playlists.length} playlists'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Play everything in it'),
            onTap: () => Navigator.of(sheet).pop('play'),
          ),
          ListTile(
            leading: const Icon(Icons.shuffle),
            title: const Text('Shuffle everything in it'),
            onTap: () => Navigator.of(sheet).pop('shuffle'),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('New playlist in here…'),
            onTap: () => Navigator.of(sheet).pop('new'),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename…'),
            onTap: () => Navigator.of(sheet).pop('rename'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_off_outlined),
            title: const Text('Remove the folder'),
            subtitle: const Text('The playlists stay'),
            onTap: () => Navigator.of(sheet).pop('delete'),
          ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    switch (picked) {
      case 'play' || 'shuffle':
        final tracks = await app.api.folderTracks(folder.id);
        if (tracks.isEmpty) {
          messenger.say(snack(const Text('Nothing in it to play')));
          return;
        }
        await app.playNow(tracks, shuffle: picked == 'shuffle', named: folder.name);
      case 'new':
        final name = await promptForName(context, 'New playlist');
        if (name == null) return;
        final made = await app.api.createPlaylist(name);
        await app.api.placePlaylist(made.id, folderId: folder.id);
        await app.refreshPlaylists();
        app.setSectionClosed('folder:${folder.id}', false);
      case 'rename':
        final name = await promptForName(context, 'Rename folder', folder.name);
        if (name == null) return;
        await app.api.renameFolder(folder.id, name);
        await app.refreshPlaylists();
      case 'delete':
        final ok = await confirm(
            context,
            'Remove the folder "${folder.name}"?',
            shelf.playlists.isEmpty
                ? 'It is empty.'
                : 'The ${shelf.playlists.length} playlists in it stay in your library.',
            action: 'Remove');
        if (!ok) return;
        await app.api.deleteFolder(folder.id);
        await app.refreshPlaylists();
    }
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// Where to file a playlist: one of your folders, a new one, or back in the box.
Future<void> moveToFolderSheet(
    BuildContext context, AppState app, Playlist playlist) async {
  final folders = app.folders;
  final picked = await ask<Object>(
    context,
    scrollable: folders.length > 6,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          ListTile(
            title: Text('Move "${playlist.name}" to',
                style: Theme.of(sheet).textTheme.titleSmall),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder…'),
            onTap: () => Navigator.of(sheet).pop('new'),
          ),
          for (final f in folders)
            ListTile(
              leading: Icon(f.id == playlist.folderId
                  ? Icons.folder
                  : Icons.folder_outlined),
              title: Text(f.name),
              subtitle: Text('${f.count} ${f.count == 1 ? 'playlist' : 'playlists'}'),
              selected: f.id == playlist.folderId,
              onTap: () => Navigator.of(sheet).pop(f.id),
            ),
          if (playlist.folderId != null)
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Out of its folder'),
              onTap: () => Navigator.of(sheet).pop('none'),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    int? into;
    String where;
    if (picked == 'new') {
      final name = await promptForName(context, 'New folder');
      if (name == null) return;
      final made = await app.api.createFolder(name);
      into = made.id;
      where = made.name;
    } else if (picked == 'none') {
      into = null;
      where = '';
    } else {
      into = picked as int;
      where = folders.firstWhere((f) => f.id == into).name;
    }
    await app.api.placePlaylist(playlist.id, folderId: into);
    await app.refreshPlaylists();
    if (into != null) app.setSectionClosed('folder:$into', false);
    messenger.say(snack(Text(into == null
        ? '"${playlist.name}" is out of its folder'
        : '"${playlist.name}" is in "$where"')));
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// The library's "New": a playlist, or a folder to put some in.
Future<void> newInLibrary(BuildContext context, AppState app) async {
  final picked = await ask<String>(
    context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('New playlist…'),
            onTap: () => Navigator.of(sheet).pop('playlist'),
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder…'),
            subtitle: const Text('A divider card to file playlists behind'),
            onTap: () => Navigator.of(sheet).pop('folder'),
          ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (picked == 'playlist') {
      final name = await promptForName(context, 'New playlist');
      if (name == null) return;
      await app.api.createPlaylist(name);
    } else {
      final name = await promptForName(context, 'New folder');
      if (name == null) return;
      await app.api.createFolder(name);
    }
    await app.refreshPlaylists();
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// A folder opened as a page: from a link, the palette or the side column, where
/// opening it in place is not on offer.
class FolderPage extends StatelessWidget {
  const FolderPage({super.key, required this.folderId});
  final int folderId;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final arranged = LibraryArrangement(app.playlists, app.folders);
    final shelf = arranged.shelves.where((s) => s.folder.id == folderId).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    if (shelf == null) {
      return PlayerScaffold(
        appBar: AppBar(title: const Text('Folder')),
        body: const EmptyHint(
          icon: Icons.folder_off_outlined,
          title: 'No such folder',
          body: 'It was removed, or it is somebody else\'s.',
        ),
      );
    }
    final lists = shelf.playlists;
    return PlayerScaffold(
      appBar: AppBar(
        title: Text(shelf.folder.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Folder',
            onPressed: () => folderMenu(context, app, shelf),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(8, 4, 8, bottomForPlayer(context)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Row(
              children: [
                Text(
                    '${lists.length} ${lists.length == 1 ? 'PLAYLIST' : 'PLAYLISTS'}',
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true)),
                const Spacer(),
                PressButton(
                  label: 'Play',
                  loud: true,
                  onTap: lists.isEmpty
                      ? null
                      : () async {
                          final tracks = await app.api.folderTracks(folderId);
                          if (tracks.isNotEmpty) {
                            await app.playNow(tracks, named: shelf.folder.name);
                          }
                        },
                ),
                const SizedBox(width: 8),
                PressButton(
                  label: 'Shuffle',
                  onTap: lists.isEmpty
                      ? null
                      : () async {
                          final tracks = await app.api.folderTracks(folderId);
                          if (tracks.isNotEmpty) {
                            await app.playNow(tracks,
                                shuffle: true, named: shelf.folder.name);
                          }
                        },
                ),
              ],
            ),
          ),
          for (final p in lists) PlaylistRow(playlist: p),
          if (lists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Nothing filed here yet.')),
            ),
        ],
      ),
    );
  }
}
