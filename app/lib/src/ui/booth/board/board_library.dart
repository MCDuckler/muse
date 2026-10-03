// The sounds there are to put on a pad: the kit the booth makes, and (with the
// server) the user's own. A row is heard with its button, dragged onto a pad, or —
// while a pad is asking — tapped to go there.
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../state/booth/board/pad_spec.dart';
import '../../../state/booth/booth.dart';
import '../../dialogs.dart';
import '../../dropped_files.dart';
import '../../snack.dart';
import '../../../state/booth/board/samples.dart';
import '../../../state/booth/board/soundboard.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../desk/console.dart';

enum LibraryTab { kit, yours }

class BoardLibrary extends StatefulWidget {
  const BoardLibrary({super.key, required this.board, this.forPad, required this.onPicked, this.booth});

  final Soundboard board;

  /// The booth, for cutting bars off a deck; null on a screen with no decks.
  final Booth? booth;

  /// The pad asking for a sound, if one is: a tapped row goes there.
  final (int, int)? forPad;
  final void Function(Sample) onPicked;

  @override
  State<BoardLibrary> createState() => _BoardLibraryState();
}

class _BoardLibraryState extends State<BoardLibrary> {
  LibraryTab _tab = LibraryTab.kit;
  final _search = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _did(Future<Sample> Function() what, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final s = await what();
      if (!mounted) return;
      setState(() => _tab = LibraryTab.yours);
      if (widget.forPad != null) widget.onPicked(s);
      if (done != null) messenger.say(snack(Text(done)));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await _did(() => widget.board.importBytes(file.name, bytes), done: '${file.name} is in your library');
  }

  Future<void> _dropped(List<({String name, List<int> bytes})> files) async {
    for (final f in files) {
      await _did(() => widget.board.importBytes(f.name, f.bytes));
    }
  }

  /// Bars off the master deck: which deck, how many.
  Future<void> _cut() async {
    final b = widget.booth;
    if (b == null) return;
    final deck = b.master.track != null ? b.master : b.other(b.master);
    if (deck.track == null) {
      ScaffoldMessenger.of(context).say(snack(const Text('Nothing on the decks to cut from')));
      return;
    }
    final bars = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Console.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Console.line)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('CUT FROM ${deck.name} · ${deck.track!.displayTitle.toUpperCase()}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: Console.label(10, color: Console.ink)),
            const SizedBox(height: 6),
            Text('From the start of the bar it is on, this many bars:', style: Mag.typewriter(11, color: Console.quiet)),
            const SizedBox(height: 12),
            Row(children: [
              for (final n in const [1, 2, 4, 8]) ...[
                Expanded(
                  child: Pad(
                    label: n == 1 ? '1 BAR' : '$n',
                    height: 34,
                    colour: Console.deck(deck.name),
                    onTap: () => Navigator.of(context).pop(n),
                  ),
                ),
                if (n != 8) const SizedBox(width: 6),
              ],
            ]),
          ]),
        ),
      ),
    );
    if (bars == null) return;
    await _did(() => widget.board.cutFromDeck(deck, bars), done: '$bars bar${bars == 1 ? '' : 's'} cut, in your library');
  }

  Future<void> _forget(Sample s) async {
    final ok = await confirm(context, 'Forget "${s.name}"?', 'It leaves every pad it is on, and the server.');
    if (ok != true) return;
    try {
      await widget.board.forgetSample(s);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).say(problem(e));
    }
  }

  Future<void> _rename(Sample s) async {
    final name = await promptForName(context, 'Name this sound', s.name);
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.board.renameSample(s, name.trim());
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).say(problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final all = switch (_tab) {
      LibraryTab.kit => SampleKit.all,
      LibraryTab.yours => widget.board.sampler.library.known.values.toList(),
    };
    final rows = q.isEmpty ? all : [for (final s in all) if (s.name.toLowerCase().contains(q)) s];
    final asking = widget.forPad;
    final yours = _tab == LibraryTab.yours;
    final server = widget.board.hasServer;
    return DropToAdd(
      onFiles: _dropped,
      child: Plate(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('LIBRARY', style: Console.label(10, color: Console.ink)),
            const Spacer(),
            for (final (t, label) in const [(LibraryTab.kit, 'KIT'), (LibraryTab.yours, 'YOURS')]) ...[
              Pad(
                label: label,
                height: 26,
                lit: _tab == t,
                colour: Console.ink,
                onTap: () => setState(() => _tab = t),
              ),
              const SizedBox(width: 4),
            ],
          ]),
          if (asking != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Theme.of(context).colorScheme.primary),
              ),
              child: Text('TAP A SOUND FOR PAD ${asking.$2 + 1}',
                  style: Console.label(9, color: Theme.of(context).colorScheme.primary)),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _search,
            style: Mag.typewriter(12, color: Console.ink),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search…',
              hintStyle: Mag.typewriter(12, color: Console.faint),
              prefixIcon: Icon(Icons.search, size: 16, color: Console.quiet),
              prefixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 20),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Console.line)),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Console.quiet)),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        yours
                            ? server
                                ? 'Nothing of your own yet: import a file, drop one here, or cut bars off a deck.'
                                : 'Your own sounds need the server: sign in to keep them.'
                            : 'Nothing by that name.',
                        textAlign: TextAlign.center,
                        style: Mag.typewriter(11, color: Console.quiet),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 36,
                    itemBuilder: (context, i) => _SampleRow(
                      sample: rows[i],
                      board: widget.board,
                      asking: asking != null,
                      onTap: asking == null ? null : () => widget.onPicked(rows[i]),
                      onRename: yours ? () => _rename(rows[i]) : null,
                      onForget: yours ? () => _forget(rows[i]) : null,
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          if (server)
            Row(children: [
              Expanded(
                child: Pad(
                  icon: Icons.file_upload_outlined,
                  label: 'IMPORT',
                  height: 28,
                  colour: Console.ink,
                  tooltip: 'A sound of your own, from a file (or drop one here)',
                  onTap: _busy ? null : () => unawaited(_import()),
                ),
              ),
              if (widget.booth != null) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Pad(
                    icon: Icons.content_cut,
                    label: 'CUT BARS',
                    height: 28,
                    colour: Console.ink,
                    tooltip: 'Bars off the record on the master deck, from the bar it is on',
                    onTap: _busy ? null : () => unawaited(_cut()),
                  ),
                ),
              ],
            ])
          else
            Text('Drag a sound onto a pad.', style: Mag.typewriter(10, color: Console.faint)),
          if (_busy) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(minHeight: 2, color: Console.ink, backgroundColor: Console.line),
          ],
        ],
      ),
    ),
    );
  }
}

class _SampleRow extends StatefulWidget {
  const _SampleRow(
      {required this.sample, required this.board, required this.asking, this.onTap, this.onRename, this.onForget});
  final Sample sample;
  final Soundboard board;
  final bool asking;
  final VoidCallback? onTap;
  final VoidCallback? onRename, onForget;

  @override
  State<_SampleRow> createState() => _SampleRowState();
}

class _SampleRowState extends State<_SampleRow> {
  bool _over = false;

  Future<void> _menu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset.zero);
    final pick = await showMenu<String>(
      context: context,
      color: Console.raised,
      position: RelativeRect.fromLTRB(at.dx + 40, at.dy + 20, at.dx + 40, at.dy + 20),
      items: [
        PopupMenuItem(value: 'rename', height: 34, child: Text('RENAME', style: Console.label(10, color: Console.ink))),
        PopupMenuItem(value: 'forget', height: 34, child: Text('FORGET', style: Console.label(10, color: Console.ink))),
      ],
    );
    if (pick == 'rename') widget.onRename?.call();
    if (pick == 'forget') widget.onForget?.call();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sample;
    final row = MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      cursor: widget.onTap == null ? SystemMouseCursors.grab : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onRename,
        onSecondaryTap: widget.onForget == null ? null : () => _menu(context),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 0, 2, 0),
          decoration: BoxDecoration(
            color: _over ? Console.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(children: [
            Icon(Icons.drag_indicator, size: 14, color: Console.faint),
            const SizedBox(width: 6),
            Expanded(
              child: Text(s.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(12, color: Console.ink)),
            ),
            Text('${(s.length.inMilliseconds / 1000).toStringAsFixed(1)} s',
                style: Mag.typewriter(10, color: Console.quiet)),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.play_arrow, size: 16, color: Console.quiet),
              tooltip: 'Listen',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                feel(Feel.pick);
                unawaited(widget.board.audition(s));
              },
            ),
          ]),
        ),
      ),
    );
    return Draggable<Sample>(
      data: s,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: Console.raised,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Console.ink),
          ),
          child: Text(s.name.toUpperCase(), style: Console.label(10, color: Console.ink)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }
}

/// A sample as a pad would first hold it: its name shouted, the kit's own colour.
PadSpec padFor(Sample s) {
  final colour = switch (s.id) {
    SampleKit.impact => PadColour.a,
    SampleKit.riser => PadColour.violet,
    SampleKit.sweepUp || SampleKit.sweepDown => PadColour.teal,
    SampleKit.hydrant => PadColour.orange,
    _ => PadColour.white,
  };
  var name = s.name.toUpperCase();
  final dot = name.indexOf(' · ');
  if (dot > 0) name = name.substring(0, dot);
  return PadSpec(sampleId: s.id, name: name, colour: colour);
}
