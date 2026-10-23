// MilkDrop in one panel: the preset on (with the helper's own picture to judge it
// by) and the hands on it — before, next, another, hold, favourite, off — where it
// goes in the rig (the background, or alone on the stage), what its director does
// (a new preset every so many bars, cut on a drop, favourites only, the least
// rating), and every preset the library has, searched and filtered, each a tap
// away, with the way to the maker.
//
// The panel sits in the show page's MILKDROP tab (ui/show/show_room.dart); MilkPage
// is the same panel as a page of its own, for the tile and for a phone.
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../state/booth/booth.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/milk_library.dart';
import '../../state/show/milk_preset_text.dart';
import '../../state/show/show_rig.dart';
import '../booth/desk/console.dart';
import '../mag.dart';
import '../snack.dart';
import 'milk_maker.dart';
import 'milk_preview.dart';

/// The hold on MilkDrop's preset, in three states: held for good (locked: nothing
/// changes it but the hands), held till the next drop (picked by hand: the clock, a
/// breakdown and a new record leave it), or the director's. A tap lets go of a hold,
/// or holds for good.
class MilkHoldPad extends StatelessWidget {
  const MilkHoldPad({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    final d = MilkFeed.shared.director;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final byHand = d.heldByHand && !d.locked;
        return Pad(
          icon: d.locked ? Icons.lock : (byHand ? Icons.pan_tool_outlined : Icons.lock_open),
          width: size + 6,
          height: size,
          lit: d.locked || byHand,
          colour: Console.a,
          tooltip: d.locked
              ? 'Held: nothing changes the preset but you — tap to let the director have it'
              : byHand
                  ? 'Held till the next drop or hit (you picked it) — tap to let the director change it now'
                  : 'The director changes the preset — tap to hold this one',
          onTap: () {
            if (d.locked) {
              d.set(locked: false);
              d.release();
            } else if (byHand) {
              d.release();
            } else {
              d.set(locked: true);
            }
          },
        );
      },
    );
  }
}

Future<void> openMilkPage(BuildContext context, Booth booth) => Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => MilkPage(booth: booth)),
    );

/// The panel as a page of its own.
class MilkPage extends StatelessWidget {
  const MilkPage({super.key, required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final feed = MilkFeed.shared;
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
      ),
      body: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 8), child: MilkPanel(booth: booth))),
    );
  }
}

class MilkPanel extends StatefulWidget {
  const MilkPanel({super.key, required this.booth});
  final Booth booth;

  @override
  State<MilkPanel> createState() => _MilkPanelState();
}

class _MilkPanelState extends State<MilkPanel> {
  final _query = TextEditingController();
  String? _collection;
  bool _favouritesOnly = false;
  bool _offOnly = false;
  bool _ratedOnly = true;
  bool _wasPinned = false;

  MilkFeed get feed => MilkFeed.shared;
  MilkLibrary get library => feed.library;

  @override
  void initState() {
    super.initState();
    // The helper on while the panel is, so there is a picture to judge by.
    _wasPinned = feed.pinned;
    feed.pinned = true;
    if (feed.available) unawaited(feed.start());
    unawaited(library.ready().then((_) => mounted ? setState(() {}) : null, onError: (Object e) {
      // No support directory (a test, a stripped build): the panel shows what it has.
      if (mounted) setState(() => _libraryTrouble = '$e');
    }));
  }

  String? _libraryTrouble;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _head(),
        const SizedBox(height: 8),
        _director(),
        const Divider(height: 14),
        _search(accent),
        const SizedBox(height: 4),
        Expanded(child: _list(accent)),
        _foot(),
      ],
    );
  }

  // ---------------------------------------------------------------- the preset on
  Widget _head() => ListenableBuilder(
        listenable: Listenable.merge([feed.director, feed, widget.booth.show]),
        builder: (context, _) {
          final d = feed.director;
          final show = widget.booth.show;
          final p = feed.preset;
          final rig = show.state.rig;
          final under = rig.ground.kind == Ground.milk;
          final kept = show.heldGround == 'milk';
          final alone = show.milkOnly;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 200, child: MilkPreview()),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    !feed.available
                        ? 'MilkDrop is not here'
                        : feed.running
                            ? (feed.presetName ?? 'MilkDrop…')
                            : 'MilkDrop off',
                    style: Mag.title(15, color: feed.running ? Console.ink : Console.quiet),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    !feed.available
                        ? 'no helper beside the app'
                        : p == null
                            ? 'the preset on, its author, its rating'
                            : [if (p.author.isNotEmpty) p.author, p.collection, if (p.rating > 0) '★' * p.rating.round()].join(' · '),
                    style: TextStyle(color: Console.quiet, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  ValueListenableBuilder<String?>(
                    valueListenable: feed.presetTrouble,
                    builder: (context, t, _) => t == null ? const SizedBox.shrink() : Text(t, style: const TextStyle(color: Color(0xffe0302a), fontSize: 11)),
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 3, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Pad(icon: Icons.chevron_left, width: 30, height: 26, colour: Console.ink, tooltip: 'The preset before', onTap: d.previous),
                    Pad(
                        icon: Icons.casino_outlined,
                        width: 30,
                        height: 26,
                        colour: Console.ink,
                        tooltip: 'Another preset',
                        onTap: () {
                          if (!feed.running && feed.available) unawaited(feed.start());
                          d.random(byHand: true);
                        }),
                    Pad(icon: Icons.chevron_right, width: 30, height: 26, colour: Console.ink, tooltip: 'The next', onTap: d.next),
                    const SizedBox(width: 4),
                    const MilkHoldPad(size: 26),
                    Pad(
                      icon: Icons.star,
                      width: 30,
                      height: 26,
                      lit: p != null && library.isFavourite(p),
                      colour: const Color(0xffe8b84a),
                      tooltip: 'A favourite (the director can keep to those)',
                      onTap: p == null ? () {} : () => setState(() => library.toggleFavourite(p)),
                    ),
                    Pad(
                      icon: Icons.block,
                      width: 30,
                      height: 26,
                      lit: p != null && library.isOff(p),
                      colour: const Color(0xffe0302a),
                      tooltip: 'Switch this one off: never put on by itself again (and on to another)',
                      onTap: () => setState(d.switchOff),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text('WHERE IT GOES', style: Console.label(8)),
                  const SizedBox(height: 3),
                  Wrap(spacing: 3, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    IntrinsicWidth(
                        child: Pad(
                      label: kept ? 'THE BACKGROUND, KEPT' : 'THE BACKGROUND',
                      height: 24,
                      lit: under,
                      colour: Console.a,
                      tooltip: kept
                          ? 'MilkDrop is the background and stays it whatever the director does — tap to let the director choose backgrounds again'
                          : under
                              ? 'MilkDrop is the background now — tap to keep it there whatever the director does'
                              : 'Put MilkDrop under the scene, and keep it there',
                      onTap: () => show.holdGround(kept ? null : 'milk'),
                    )),
                    IntrinsicWidth(
                        child: Pad(
                      label: 'ALONE',
                      height: 24,
                      lit: alone,
                      colour: Console.a,
                      tooltip: alone ? 'MilkDrop alone on the stage — tap for the scenes again' : 'Nothing but MilkDrop on the stage: ‹ › step its presets',
                      onTap: () => show.setMilkOnly(!alone),
                    )),
                    IntrinsicWidth(
                        child: Pad(
                      label: show.pool.milkOn ? 'THE DIRECTOR\'S' : 'NOT THE DIRECTOR\'S',
                      height: 24,
                      lit: show.pool.milkOn,
                      colour: Console.quiet,
                      tooltip: show.pool.milkOn
                          ? 'The director may put MilkDrop under the scenes (most of the time) — tap and it never does (MilkDrop\'s card at 0)'
                          : 'The director never puts MilkDrop under a scene — tap to let it again',
                      onTap: () => show.setPool(show.pool.withMilk(!show.pool.milkOn)),
                    )),
                  ]),
                ]),
              ),
            ],
          );
        },
      );

  // ---------------------------------------------------------------- the director
  Widget _director() => ListenableBuilder(
        listenable: feed.director,
        builder: (context, _) {
          final d = feed.director;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('WHEN IT CHANGES', style: Console.label(8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('the record decides, not a clock: a hit or a drop cuts, a breakdown blends, a new record too',
                    style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('and a new one every', style: TextStyle(color: Console.ink, fontSize: 12)),
                  const SizedBox(width: 6),
                  DropdownButton<int>(
                    value: const [0, 4, 8, 16, 32, 64].contains(d.everyBars) ? d.everyBars : 16,
                    dropdownColor: Console.panel,
                    style: TextStyle(color: Console.ink, fontSize: 12),
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    items: [
                      for (final n in const [0, 4, 8, 16, 32, 64]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'never by the clock' : '$n bars')),
                    ],
                    onChanged: (v) => v == null ? null : d.set(everyBars: v),
                  ),
                ]),
                FilterChip(
                  label: const Text('cut on drops & hits'),
                  selected: d.cutOnDrop,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => d.set(cutOnDrop: v),
                ),
                FilterChip(
                  label: const Text('move with the beat'),
                  selected: d.accents,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'In a loud part the preset\'s own motion is pushed on the kick, the bar or the snare; a build pushes in, a drop bursts. Presets that move with the music by themselves get less',
                  onSelected: (v) => d.set(accents: v),
                ),
                FilterChip(
                  label: const Text('favourites only'),
                  selected: d.favouritesOnly,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'The director keeps to the starred presets',
                  onSelected: (v) => d.set(favouritesOnly: v),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('rated', style: TextStyle(color: Console.ink, fontSize: 12)),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Only presets their author rated this or better (the originals rate themselves 1 to 5; under 3 is mostly the dull ones)',
                    child: DropdownButton<int>(
                      value: d.minRating.round().clamp(0, 5),
                      dropdownColor: Console.panel,
                      style: TextStyle(color: Console.ink, fontSize: 12),
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: [
                        for (final n in const [0, 1, 2, 3, 4, 5]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'any' : '$n+ of 5')),
                      ],
                      onChanged: (v) => v == null ? null : d.set(minRating: v.toDouble()),
                    ),
                  ),
                ]),
              ],
            ),
          ]);
        },
      );

  // ---------------------------------------------------------------- the presets
  Widget _search(Color accent) {
    final collections = ['shipped', 'mine', ...library.imported.keys];
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('THE PRESETS', style: Console.label(8)),
          const SizedBox(width: 8),
          Expanded(
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
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: Text('all ${library.presets.length}'),
              visualDensity: VisualDensity.compact,
              selected: _collection == null && !_favouritesOnly && !_offOnly,
              onSelected: (_) => setState(() {
                _collection = null;
                _favouritesOnly = false;
                _offOnly = false;
              }),
            ),
            ChoiceChip(
              label: Text('★ ${library.favourites.length}'),
              visualDensity: VisualDensity.compact,
              selected: _favouritesOnly,
              onSelected: (_) => setState(() => _favouritesOnly = !_favouritesOnly),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.block, size: 14),
              label: Text('off ${library.off.length}'),
              visualDensity: VisualDensity.compact,
              tooltip: 'The presets switched off',
              selected: _offOnly,
              onSelected: (_) => setState(() => _offOnly = !_offOnly),
            ),
            ChoiceChip(
              label: Text('rated ${feed.director.minRating.round()}+'),
              visualDensity: VisualDensity.compact,
              tooltip: 'Only what the director may pick by rating',
              selected: _ratedOnly,
              onSelected: (_) => setState(() => _ratedOnly = !_ratedOnly),
            ),
            for (final c in collections)
              ChoiceChip(
                label: Text(c),
                visualDensity: VisualDensity.compact,
                selected: _collection == c,
                onSelected: (_) => setState(() => _collection = _collection == c ? null : c),
              ),
            ActionChip(
                avatar: const Icon(Icons.folder_open, size: 16),
                visualDensity: VisualDensity.compact,
                label: const Text('bring in a folder…'),
                onPressed: _import),
          ],
        ),
      ]),
    );
  }

  Widget _list(Color accent) => ListenableBuilder(
        listenable: Listenable.merge([library, feed]),
        builder: (context, _) {
          final found = library.search(_query.text,
              collection: _collection, favouritesOnly: _favouritesOnly, minRating: _ratedOnly ? feed.director.minRating : 0, offOnly: _offOnly);
          if (found.isEmpty) {
            return Center(
              child: Text(
                _libraryTrouble != null
                    ? 'The presets could not be read: $_libraryTrouble'
                    : library.presets.isEmpty
                        ? 'No presets yet'
                        : 'Nothing by that name',
                style: TextStyle(color: Console.quiet),
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListView.builder(
            itemCount: found.length,
            itemExtent: 44,
            itemBuilder: (context, i) {
              final p = found[i];
              final on = feed.preset?.path == p.path;
              final fav = library.isFavourite(p);
              final off = library.isOff(p);
              return InkWell(
                onTap: () => setState(() => feed.director.pick(p)),
                onLongPress: () => _fork(p),
                child: Container(
                  color: on ? accent.withValues(alpha: 0.15) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      if (on) Icon(Icons.play_arrow, size: 14, color: accent),
                      if (on) const SizedBox(width: 4),
                      Expanded(
                        child: Opacity(
                          opacity: off ? 0.4 : 1,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name,
                                  style: TextStyle(color: on ? accent : Console.ink, fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w500),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              Text(
                                  [if (p.author.isNotEmpty) p.author, if (p.collection != 'shipped') p.collection, '★' * p.rating.round(), if (off) 'off']
                                      .join(' · '),
                                  style: TextStyle(color: Console.quiet, fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
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
                        icon: Icon(Icons.block, size: 18, color: off ? const Color(0xffe0302a) : Console.faint),
                        tooltip: off ? 'Switched off: tap to let it come on again' : 'Switch it off: never put on by itself',
                        onPressed: () => setState(() => on && !off ? feed.director.switchOff() : library.toggleOff(p)),
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
          );
        },
      );

  Widget _foot() => ListenableBuilder(
        listenable: feed,
        builder: (context, _) => Row(children: [
          Expanded(
            child: Text('Tap to put one on; hold to open it in the maker. Presets made here can read the show (docs/milk-presets.md).',
                style: TextStyle(color: Console.faint, fontSize: 10), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          TextButton.icon(
            onPressed: () => _fork(null),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New preset'),
            style: TextButton.styleFrom(foregroundColor: Console.ink, visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            onPressed: feed.preset == null ? null : () => _fork(feed.preset),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit this one'),
            style: TextButton.styleFrom(foregroundColor: Console.ink, visualDensity: VisualDensity.compact),
          ),
        ]),
      );
}
