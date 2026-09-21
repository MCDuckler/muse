import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'browse_page.dart';
import 'downloads_page.dart';
import 'feel.dart';
import 'home_page.dart' show openInTab;
import 'library_page.dart';
import 'listening_page.dart';
import 'mag.dart';
import 'queue_page.dart' show QueueScreen;
import 'settings_page.dart';
import 'theme.dart';
import 'equalizer_page.dart';

/// Jump to anything: Ctrl-K, or ⌘K on a Mac.
///
/// On a desk the app is driven by a mouse through a rail, a column and a dock, and the
/// thing somebody wants is usually two or three clicks away in a place they have to
/// remember. This is the other way in: start typing the name of a playlist, a queue, a
/// song, a record, an artist or a thing to do, and press return.
///
/// What is already in the app's hands — the commands, the playlists, the queues — is
/// matched as you type. The library is asked as well, a moment after you stop, and
/// what it finds is added underneath.
Future<void> showCommandPalette(BuildContext context) => showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => const _Palette(),
    );

/// One thing the palette can do.
class PaletteItem {
  const PaletteItem({
    required this.title,
    required this.group,
    required this.run,
    this.detail,
    this.icon,
    this.also = '',
  });

  final String title;
  final String group;
  final String? detail;
  final IconData? icon;

  /// Other words it answers to: "pause" finds play/pause.
  final String also;
  final FutureOr<void> Function() run;
}

/// How well [query] matches [text]: the start of it, the start of a word in it, any
/// part of it, or its letters in order. Zero is no match.
double matchScore(String query, String text) {
  final q = query.trim().toLowerCase();
  final t = text.toLowerCase();
  if (q.isEmpty) return 1;
  if (t.startsWith(q)) return 4;
  if (t.contains(' $q') || t.contains('-$q') || t.contains('($q')) return 3;
  if (t.contains(q)) return 2;
  var i = 0;
  for (final c in t.runes) {
    if (i < q.length && c == q.codeUnitAt(i)) i++;
  }
  return i == q.length ? 1 : 0;
}

class _Palette extends StatefulWidget {
  const _Palette();

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _field = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  List<PaletteItem> _found = const [];
  String _asked = '';
  int _at = 0;

  @override
  void initState() {
    super.initState();
    _field.addListener(_typed);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _typed() {
    setState(() => _at = 0);
    _debounce?.cancel();
    final q = _field.text.trim();
    if (q.length < 2) {
      if (_found.isNotEmpty) setState(() => _found = const []);
      return;
    }
    // The library, once the typing stops: every keystroke a request was a search per
    // letter, most of them for words nobody meant.
    _debounce = Timer(const Duration(milliseconds: 220), () => _ask(q));
  }

  Future<void> _ask(String q) async {
    final app = context.read<AppState>();
    try {
      final r = await app.api.searchEverything(q, where: 'library', limit: 8);
      if (!mounted || _field.text.trim() != q) return;
      setState(() {
        _asked = q;
        _found = [for (final f in r.items) _fromFound(app, f)];
      });
    } catch (_) {
      // The palette still does everything it knows about without the library.
    }
  }

  PaletteItem _fromFound(AppState app, Found f) => switch (f.kind) {
        'album' => PaletteItem(
            title: f.title,
            detail: f.subtitle,
            group: 'Records',
            icon: Icons.album_outlined,
            run: () => openInTab(
                Tabs.library,
                (_) => AlbumPage(
                    album: AlbumSummary(name: f.title, artist: f.subtitle, tracks: 0))),
          ),
        'artist' => PaletteItem(
            title: f.title,
            detail: 'Artist',
            group: 'Artists',
            icon: Icons.person_outline,
            run: () => openInTab(Tabs.library,
                (_) => ArtistPage(artist: ArtistSummary(name: f.title, tracks: 0))),
          ),
        _ => PaletteItem(
            title: f.title,
            detail: f.subtitle,
            group: 'Songs',
            icon: Icons.music_note_outlined,
            run: () async {
              final t = f.track;
              if (t != null) await app.playTrackNow(t);
            },
          ),
      };

  /// Everything the app can do from here, before the library has been asked.
  List<PaletteItem> _commands(AppState app) {
    PaletteItem go(String title, int tab, IconData icon, {String also = ''}) => PaletteItem(
          title: title,
          group: 'Go to',
          icon: icon,
          also: also,
          run: () => app.setHomeTab(tab),
        );
    return [
      PaletteItem(
          title: app.musicIsPlaying ? 'Pause' : 'Play',
          group: 'Do',
          icon: app.musicIsPlaying ? Icons.pause : Icons.play_arrow,
          also: 'play pause resume stop',
          run: app.playPause),
      PaletteItem(title: 'Next song', group: 'Do', icon: Icons.skip_next, also: 'skip', run: app.skipNext),
      PaletteItem(title: 'Previous song', group: 'Do', icon: Icons.skip_previous, also: 'back', run: app.skipPrevious),
      PaletteItem(title: 'Shuffle what is coming', group: 'Do', icon: Icons.shuffle, run: app.shuffleWhatIsComing),
      PaletteItem(title: 'Repeat: off, all, one', group: 'Do', icon: Icons.repeat, run: app.cycleRepeat),
      PaletteItem(title: 'Mute', group: 'Do', icon: Icons.volume_off, also: 'sound quiet', run: app.toggleMute),
      for (final minutes in const [15, 30, 60])
        PaletteItem(
          title: 'Sleep in $minutes minutes',
          group: 'Do',
          icon: Icons.bedtime_outlined,
          also: 'timer stop',
          run: () => app.setSleepTimer(Duration(minutes: minutes)),
        ),
      PaletteItem(
          title: 'Sleep at the end of this song',
          group: 'Do',
          icon: Icons.bedtime_outlined,
          also: 'timer stop',
          run: () => app.setSleepTimer(null, endOfTrack: true)),
      go('Home', Tabs.home, Icons.newspaper, also: 'cover issue'),
      PaletteItem(
          title: 'Up next',
          group: 'Go to',
          icon: Icons.queue_music,
          also: 'queue queues',
          run: () => openInTab(app.homeTab, (_) => const QueueScreen())),
      go('Search', Tabs.search, Icons.search, also: 'find'),
      go('Library', Tabs.library, Icons.library_music),
      go('People', Tabs.people, Icons.people_outline, also: 'house friends jam'),
      PaletteItem(
          title: 'The charts',
          group: 'Go to',
          icon: Icons.bar_chart,
          also: 'listening stats top',
          run: () => openInTab(Tabs.library, (_) => const ListeningPage())),
      PaletteItem(
          title: 'Downloads',
          group: 'Go to',
          icon: Icons.download_outlined,
          run: () => openInTab(app.homeTab, (_) => const DownloadsPage())),
      PaletteItem(
          title: 'Equalizer',
          group: 'Go to',
          icon: Icons.graphic_eq,
          also: 'eq bass treble tone sound presets',
          run: () => openInTab(app.homeTab, (_) => const EqualizerPage())),
      PaletteItem(
          title: 'Settings',
          group: 'Go to',
          icon: Icons.settings_outlined,
          also: 'preferences',
          run: () => openInTab(app.homeTab, (_) => const SettingsPage())),
      for (final p in Palette.all)
        PaletteItem(
          title: 'Print the ${p.name} edition',
          group: 'Do',
          icon: Icons.palette_outlined,
          also: 'colour color theme edition ${p.name}',
          run: () => app.setPalette(p),
        ),
    ];
  }

  List<PaletteItem> _matching(AppState app) {
    final q = _field.text;
    final items = <(PaletteItem, double)>[];
    void offer(PaletteItem item) {
      final score = [
        matchScore(q, item.title),
        matchScore(q, item.also) * 0.8,
      ].reduce((a, b) => a > b ? a : b);
      if (score > 0) items.add((item, score));
    }

    for (final c in _commands(app)) {
      offer(c);
    }
    for (final p in app.playlists) {
      offer(PaletteItem(
        title: p.name,
        detail: '${p.itemCount} songs',
        group: 'Playlists',
        icon: Icons.queue_music_outlined,
        also: 'playlist',
        run: () => openInTab(
            Tabs.library, (_) => PlaylistPage(playlistId: p.id, name: p.name)),
      ));
    }
    for (final queue in app.queues) {
      offer(PaletteItem(
        title: queue.name,
        detail: '${queue.itemCount} in the queue',
        group: 'Queues',
        icon: Icons.low_priority,
        also: 'queue',
        run: () async {
          await app.openQueue(queue.id);
          openInTab(app.homeTab, (_) => const QueueScreen());
        },
      ));
    }
    items.sort((a, b) => b.$2.compareTo(a.$2));
    // With nothing typed, the things to do first and not every playlist on the box.
    final known = [for (final (item, _) in items) item].take(q.trim().isEmpty ? 10 : 30);
    return [
      ...known,
      if (_asked == q.trim()) ..._found,
    ];
  }

  Future<void> _run(PaletteItem item) async {
    feel(Feel.commit);
    Navigator.of(context).pop();
    await item.run();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event, List<PaletteItem> items) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _at = (_at + 1).clamp(0, items.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _at = (_at - 1).clamp(0, items.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (items.isNotEmpty) _run(items[_at.clamp(0, items.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final items = _matching(app);
    final at = items.isEmpty ? 0 : _at.clamp(0, items.length - 1);

    final rows = <Widget>[];
    String? group;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.group != group) {
        group = item.group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(group.toUpperCase(), style: Mag.flag(9.5, color: scheme.primary)),
        ));
      }
      final on = i == at;
      rows.add(Material(
        color: on ? scheme.surfaceContainerHighest : Colors.transparent,
        child: InkWell(
          onTap: () => _run(item),
          onHover: (inside) {
            if (inside && _at != i) setState(() => _at = i);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(item.icon ?? Icons.arrow_forward, size: 18,
                    color: on ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: on ? FontWeight.w700 : null)),
                ),
                if (item.detail != null) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(item.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ));
    }

    return Dialog(
      alignment: const Alignment(0, -0.55),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.onSurface, width: 2),
        borderRadius: BorderRadius.zero,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Focus(
          onKeyEvent: (node, event) => _key(node, event, items),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: MuseTheme.masthead,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: Text('JUMP TO', style: Mag.flag(10, color: Colors.white)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  controller: _field,
                  autofocus: true,
                  style: Mag.title(20, color: scheme.onSurface),
                  decoration: const InputDecoration(
                    hintText: 'A playlist, a song, a record, or a thing to do',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onSubmitted: (_) {
                    if (items.isNotEmpty) _run(items[at]);
                  },
                ),
              ),
              Flexible(
                child: items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Nothing called that here.',
                            style: Mag.typewriter(12, color: scheme.onSurfaceVariant)),
                      )
                    : ListView(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: rows,
                      ),
              ),
              Container(
                decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.2)))),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: Text('↑ ↓ TO MOVE  ·  ↵ TO GO  ·  ESC TO CLOSE',
                    style: Mag.typewriter(10, color: scheme.onSurfaceVariant, bold: true)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
