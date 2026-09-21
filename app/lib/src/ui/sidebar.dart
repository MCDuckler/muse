import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'command_palette.dart';
import 'downloads_page.dart';
import 'feel.dart';
import 'home_page.dart' show openInTab;
import 'jam_page.dart';
import 'library_page.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'settings_page.dart';

/// Your library down the side of the page, on a desk.
///
/// A rail of four icons was the phone's bottom bar turned on its side: the places to
/// go, and nothing about what is in them. A window fourteen hundred pixels wide has
/// room for the thing people actually reach for — their playlists — beside whatever
/// they are looking at, the way a record shop keeps the racks along the wall. So on a
/// desk the side is the masthead, the four places, and then every playlist, filterable,
/// a click from open; and the rail's own buttons at the foot of it.
///
/// It folds back to the rail with one click and remembers which you wanted.
class LibrarySidebar extends StatefulWidget {
  const LibrarySidebar({
    super.key,
    required this.onSameTab,
    required this.dockOpen,
    this.onDock,
  });

  final VoidCallback onSameTab;
  final bool dockOpen;
  final VoidCallback? onDock;

  @override
  State<LibrarySidebar> createState() => _LibrarySidebarState();
}

class _LibrarySidebarState extends State<LibrarySidebar> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  static const _places = [
    (Tabs.home, 'Home', Icons.newspaper_outlined, Icons.newspaper),
    (Tabs.queue, 'Queue', Icons.queue_music_outlined, Icons.queue_music),
    (Tabs.search, 'Search', Icons.search, Icons.search),
    (Tabs.library, 'Library', Icons.library_music_outlined, Icons.library_music),
    (Tabs.people, 'People', Icons.people_outline, Icons.people),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final tab = context.select<AppState, int>((a) => a.homeTab);
    final playlists = context.select<AppState, List<Playlist>>((a) => a.playlists);
    final pending = context.select<AppState, int>((a) => a.downloadsPending);
    final jamming = context.select<AppState, String?>((a) => a.jam?.code);
    final q = _filter.text.trim().toLowerCase();
    final shown = [
      for (final p in playlists)
        if (q.isEmpty || p.name.toLowerCase().contains(q)) p
    ];

    return Container(
      width: 264,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(right: BorderSide(color: scheme.onSurface.withValues(alpha: 0.12))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Masthead(size: 28),
          const SizedBox(height: 8),
          for (final (index, label, icon, selectedIcon) in _places)
            _Place(
              label: label,
              icon: tab == index ? selectedIcon : icon,
              selected: tab == index,
              onTap: () {
                if (tab == index) {
                  widget.onSameTab();
                } else {
                  feel(Feel.pick);
                }
                app.setHomeTab(index);
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.keyboard_command_key, size: 20),
                  tooltip: 'Jump to anything (Ctrl K)',
                  onPressed: () => showCommandPalette(context),
                ),
                IconButton(
                  icon: Icon(jamming == null ? Icons.podcasts_outlined : Icons.podcasts,
                      size: 20, color: jamming == null ? null : scheme.primary),
                  tooltip: jamming == null ? 'Listen together' : 'Jam · $jamming',
                  onPressed: () => showJam(context),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh',
                  onPressed: app.refresh,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.keyboard_double_arrow_left, size: 20),
                  tooltip: 'Fold the library away',
                  onPressed: app.toggleSidebar,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: SectionFlag('Your playlists · ${playlists.length}'),
          ),
          if (playlists.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() {}),
                style: Theme.of(context).textTheme.bodySmall,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Find a playlist',
                  prefixIcon: Icon(Icons.filter_list, size: 18),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      playlists.isEmpty
                          ? 'No playlists yet. Make one from the Library.'
                          : 'None called that.',
                      style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _PlaylistRow(playlist: shown[i]),
                  ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.12))),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                if (pending > 0)
                  IconButton(
                    icon: Badge(label: Text('$pending'), child: const Icon(Icons.downloading)),
                    tooltip: 'Downloads',
                    onPressed: () =>
                        openInTab(app.homeTab, (_) => const DownloadsPage()),
                  ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Settings',
                  onPressed: () => openInTab(app.homeTab, (_) => const SettingsPage()),
                ),
                const Spacer(),
                if (widget.onDock != null)
                  IconButton(
                    icon: Icon(widget.dockOpen
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left),
                    tooltip:
                        widget.dockOpen ? 'Hide what is playing' : 'Show what is playing',
                    onPressed: widget.onDock,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the four places, as a row.
class _Place extends StatelessWidget {
  const _Place({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
          decoration: BoxDecoration(
            // The one you are on is marked the way the preview marked it: a red rule
            // down its edge, and its name in ink.
            border: Border(
              left: BorderSide(
                  color: selected ? scheme.primary : Colors.transparent, width: 4),
            ),
            color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 14),
              Text(label.toUpperCase(),
                  style: Mag.flag(11,
                      color: selected ? scheme.onSurface : scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A playlist in the side: its cover, its name, how many songs.
class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.read<AppState>();
    final p = playlist;
    return InkWell(
      onTap: () => openInTab(
          app.homeTab, (_) => PlaylistPage(playlistId: p.id, name: p.name)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          children: [
            p.isFavourites
                ? SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.favorite, color: scheme.primary, size: 22),
                  )
                : PlaylistArt(playlist: p, size: 36, radius: 2),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface, fontWeight: FontWeight.w600)),
                  Text('${p.itemCount} songs',
                      style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
