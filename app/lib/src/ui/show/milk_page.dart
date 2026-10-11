// The presets: everything the library has, searched and sorted, each a tap away;
// the favourites starred; what the director does with them (cut on a drop,
// blend every so many bars, favourites only, hold); the helper's picture to judge
// them by; and the way to the maker.
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../state/booth/booth.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/milk_library.dart';
import '../../state/show/milk_preset_text.dart';
import '../../state/show/show_state.dart';
import '../booth/desk/console.dart';
import '../mag.dart';
import '../snack.dart';
import 'milk_maker.dart';
import 'milk_preview.dart';

Future<void> openMilkPage(BuildContext context, Booth booth) => Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => MilkPage(booth: booth)),
    );

class MilkPage extends StatefulWidget {
  const MilkPage({super.key, required this.booth});
  final Booth booth;

  @override
  State<MilkPage> createState() => _MilkPageState();
}

class _MilkPageState extends State<MilkPage> {
  final _query = TextEditingController();
  String? _collection;
  bool _favouritesOnly = false;
  bool _ratedOnly = true;
  bool _wasPinned = false;

  MilkFeed get feed => MilkFeed.shared;
  MilkLibrary get library => feed.library;

  @override
  void initState() {
    super.initState();
    // The helper on while the page is, so there is a picture to judge by.
    _wasPinned = feed.pinned;
    feed.pinned = true;
    unawaited(feed.start());
    unawaited(library.ready().then((_) => mounted ? setState(() {}) : null));
  }

  @override
  void dispose() {
    feed.pinned = _wasPinned;
    _query.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.getDirectoryPath(dialogTitle: 'A folder of .milk presets');
    if (picked == null) return;
    final before = library.presets.length;
    await library.import(picked);
    messenger.say(snack(Text('${library.presets.length - before} presets brought in from $picked')));
    if (mounted) setState(() {});
  }

  Future<void> _fork(MilkPreset? p) async {
    MilkText text;
    String name;
    if (p == null) {
      text = MilkText.blank();
      name = 'Me - New preset';
    } else {
      text = MilkText.parse(await File(p.path).readAsString());
      name = p.collection == 'mine' ? p.fullName : '${p.fullName} (mine)';
    }
    if (!mounted) return;
    await openMilkMaker(context, text: text, name: name, path: p?.collection == 'mine' ? p!.path : null);
    if (mounted) setState(() {});
  }

  Future<void> _delete(MilkPreset p) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${p.fullName}"?'),
        content: const Text('The file goes; this cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;
    await library.delete(p);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Console.ground,
      appBar: AppBar(
        backgroundColor: Console.ground,
        foregroundColor: Console.ink,
        title: ListenableBuilder(
          listenable: feed,
          builder: (context, _) => Text(
            feed.presetName == null ? 'MilkDrop' : 'MilkDrop · ${feed.presetName}',
            style: Mag.title(18, color: Console.ink),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _fork(null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New preset'),
            style: TextButton.styleFrom(foregroundColor: Console.ink),
          ),
          TextButton.icon(
            onPressed: feed.preset == null ? null : () => _fork(feed.preset),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit this one'),
            style: TextButton.styleFrom(foregroundColor: Console.ink),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 900;
          final list = _list(accent);
          final side = _side(accent);
          if (narrow) {
            // The picture and its switches take what they need, scrolling past half
            // the height; the list has the rest.
            return Column(children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: c.maxHeight * 0.55),
                child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(12), child: side)),
              ),
              Expanded(child: list),
            ]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 380, child: list),
              Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 12, 16, 12), child: side)),
            ],
          );
        },
      ),
    );
  }

  Widget _side(Color accent) => ListenableBuilder(
        listenable: Listenable.merge([feed.director, feed]),
        builder: (context, _) {
          final d = feed.director;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MilkPreview(),
              const SizedBox(height: 8),
              ValueListenableBuilder<String?>(
                valueListenable: feed.presetTrouble,
                builder: (context, t, _) => t == null
                    ? const SizedBox.shrink()
                    : Text(t, style: TextStyle(color: const Color(0xffe0302a), fontSize: 12)),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Pad(icon: Icons.chevron_left, width: 34, colour: Console.ink, tooltip: 'The preset before', onTap: d.previous),
                  Pad(icon: Icons.casino_outlined, width: 34, colour: Console.ink, tooltip: 'Any other', onTap: () => d.random(byHand: true)),
                  Pad(icon: Icons.chevron_right, width: 34, colour: Console.ink, tooltip: 'The next', onTap: d.next),
                  Pad(
                    icon: d.locked ? Icons.lock : Icons.lock_open,
                    width: 34,
                    lit: d.locked,
                    colour: Console.ink,
                    tooltip: d.locked ? 'Held: nothing changes it but you' : 'Hold this preset',
                    onTap: () => d.set(locked: !d.locked),
                  ),
                  Pad(
                    icon: Icons.star,
                    width: 34,
                    lit: feed.preset != null && library.isFavourite(feed.preset!),
                    colour: const Color(0xffe8b84a),
                    tooltip: 'A favourite',
                    onTap: feed.preset == null ? () {} : () => setState(() => library.toggleFavourite(feed.preset!)),
                  ),
                  const SizedBox(width: 10),
                  Text('every', style: TextStyle(color: Console.quiet, fontSize: 12)),
                  DropdownButton<int>(
                    value: d.everyBars,
                    dropdownColor: Console.panel,
                    style: TextStyle(color: Console.ink, fontSize: 13),
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final n in const [0, 4, 8, 16, 32, 64])
                        DropdownMenuItem(value: n, child: Text(n == 0 ? 'never' : '$n bars')),
                    ],
                    onChanged: (v) => v == null ? null : d.set(everyBars: v),
                  ),
                  FilterChip(
                    label: const Text('cut on drops & hits'),
                    selected: d.cutOnDrop,
                    onSelected: (v) => d.set(cutOnDrop: v),
                  ),
                  FilterChip(
                    label: const Text('favourites only'),
                    selected: d.favouritesOnly,
                    onSelected: (v) => d.set(favouritesOnly: v),
                  ),
                  FilterChip(
                    label: Text('rated ${d.minRating.round()}+'),
                    selected: d.minRating > 0,
                    tooltip: 'Only presets their author rated this or better (the originals rate themselves 1 to 5)',
                    onSelected: (_) => d.set(minRating: d.minRating >= 4 ? 0 : d.minRating + 1),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: widget.booth.show,
                builder: (context, _) {
                  final show = widget.booth.show;
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      FilterChip(
                        avatar: const Icon(Icons.filter_center_focus, size: 16),
                        label: const Text('only MilkDrop on the stage'),
                        selected: show.milkOnly,
                        onSelected: show.setMilkOnly,
                      ),
                      FilterChip(
                        avatar: const Icon(Icons.layers_outlined, size: 16),
                        label: const Text('MilkDrop under every scene'),
                        selected: show.macros.milkUnder,
                        onSelected: (v) => show.setMacros(show.macros.copyWith(milkUnder: v)),
                      ),
                      if (show.macros.milkUnder)
                        for (var i = 0; i < ShowMacros.milkMixes.length; i++)
                          Tooltip(
                            message: ShowMacros.milkMixes[i].$2,
                            child: ChoiceChip(
                              label: Text(ShowMacros.milkMixes[i].$1),
                              selected: show.macros.milkMix == i,
                              onSelected: (_) => show.setMacros(show.macros.copyWith(milkMix: i)),
                            ),
                          ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                'A hit or a drop cuts to another preset; a breakdown or a new record blends into one; '
                'every so many bars the next comes on a blend. Hold to keep the one that is on. '
                'Presets you make here can read the show themselves (docs/milk-presets.md).',
                style: TextStyle(color: Console.quiet, fontSize: 12, height: 1.4),
              ),
            ],
          );
        },
      );

  Widget _list(Color accent) {
    final collections = ['shipped', 'mine', ...library.imported.keys];
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final found = library.search(_query.text, collection: _collection, favouritesOnly: _favouritesOnly, minRating: _ratedOnly ? feed.director.minRating : 0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                style: Mag.typewriter(13, color: Console.ink),
                cursorColor: accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Author, title',
                  hintStyle: Mag.typewriter(12, color: Console.faint),
                  filled: true,
                  fillColor: Console.panel,
                  prefixIcon: Icon(Icons.search, size: 18, color: Console.quiet),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ChoiceChip(label: Text('all ${library.presets.length}'), selected: _collection == null && !_favouritesOnly, onSelected: (_) => setState(() {
                        _collection = null;
                        _favouritesOnly = false;
                      })),
                  ChoiceChip(
                    label: Text('★ ${library.favourites.length}'),
                    selected: _favouritesOnly,
                    onSelected: (_) => setState(() => _favouritesOnly = !_favouritesOnly),
                  ),
                  ChoiceChip(
                    label: Text('rated ${feed.director.minRating.round()}+'),
                    selected: _ratedOnly,
                    onSelected: (_) => setState(() => _ratedOnly = !_ratedOnly),
                  ),
                  for (final c in collections)
                    ChoiceChip(
                      label: Text(c),
                      selected: _collection == c,
                      onSelected: (_) => setState(() => _collection = _collection == c ? null : c),
                    ),
                  ActionChip(avatar: const Icon(Icons.folder_open, size: 16), label: const Text('bring in a folder…'), onPressed: _import),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: found.isEmpty
                  ? Center(child: Text(library.presets.isEmpty ? 'No presets yet' : 'Nothing by that name', style: TextStyle(color: Console.quiet)))
                  : ListView.builder(
                      itemCount: found.length,
                      itemExtent: 44,
                      itemBuilder: (context, i) {
                        final p = found[i];
                        final on = feed.preset?.path == p.path;
                        final fav = library.isFavourite(p);
                        return InkWell(
                          onTap: () => setState(() => feed.director.pick(p)),
                          onLongPress: () => _fork(p),
                          child: Container(
                            color: on ? accent.withValues(alpha: 0.15) : null,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(p.name, style: TextStyle(color: on ? accent : Console.ink, fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      Text([if (p.author.isNotEmpty) p.author, if (p.collection != 'shipped') p.collection, '★' * p.rating.round()].join(' · '), style: TextStyle(color: Console.quiet, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                                if (p.collection == 'mine')
                                  IconButton(
                                    icon: Icon(Icons.delete_outline, size: 18, color: Console.faint),
                                    tooltip: 'Delete',
                                    onPressed: () => _delete(p),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                IconButton(
                                  icon: Icon(fav ? Icons.star : Icons.star_border, size: 18, color: fav ? const Color(0xffe8b84a) : Console.faint),
                                  tooltip: fav ? 'A favourite' : 'Make it a favourite',
                                  onPressed: () => setState(() => library.toggleFavourite(p)),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Tap to put one on; hold to open it in the maker.', style: TextStyle(color: Console.faint, fontSize: 11)),
            ),
          ],
        );
      },
    );
  }
}
