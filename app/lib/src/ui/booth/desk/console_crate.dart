import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../worker/parts_jobs.dart';
import '../../artwork.dart';
import '../../mag.dart';
import 'console.dart';

/// The crate's pages.
enum CrateTab { queue, search, parts }

/// The crate: the queue, best mixes first, the whole library a search away — and, on
/// a computer that takes records apart, the list of that happening.
/// A record is dragged onto a deck, or sent to one with its A and B.
class ConsoleCrate extends StatefulWidget {
  const ConsoleCrate(
      {super.key,
      required this.booth,
      required this.loadInto,
      this.forDeck,
      this.tab});
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;

  /// A deck that asked for a record: a plain click goes there.
  final engine.Deck? forDeck;

  /// Which page is open, where something outside the crate wants a say in it: the
  /// bar's parts light opens the list of parts.
  final ValueNotifier<CrateTab>? tab;

  @override
  State<ConsoleCrate> createState() => _ConsoleCrateState();
}

class _ConsoleCrateState extends State<ConsoleCrate> {
  late final ValueNotifier<CrateTab> _tab =
      widget.tab ?? ValueNotifier(CrateTab.queue);
  bool get _searching => _tab.value == CrateTab.search;
  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<Track>? _found;
  bool _looking = false;

  @override
  void initState() {
    super.initState();
    _tab.addListener(_retab);
  }

  void _retab() => setState(() {});

  void _open(CrateTab t) {
    _tab.value = t;
    if (t == CrateTab.search) _focus.requestFocus();
  }

  @override
  void dispose() {
    _tab.removeListener(_retab);
    if (widget.tab == null) _tab.dispose();
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _found = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 280), () async {
      setState(() => _looking = true);
      try {
        final r = await context.read<AppState>().api.search(q.trim());
        if (!mounted || _query.text != q) return;
        setState(() => _found = [
              for (final t in r.local)
                if (t.isReady) t
            ]);
      } catch (_) {
        if (mounted) setState(() => _found = const []);
      } finally {
        if (mounted) setState(() => _looking = false);
      }
    });
  }

  int _score(Track t) {
    final tm = widget.booth.timing.peek(t.id);
    final master = widget.booth.master.timing;
    // Against the tempo on show: the master at its pitch.
    final shown = widget.booth.master.bpm;
    if (tm == null || master == null) return 2;
    final tempoOk = tm.bpm != null &&
        shown != null &&
        Booth.syncRatio(tm.bpm!, shown) != null;
    final keyOk = tm.inKeyWith(master);
    return tempoOk && keyOk
        ? 0
        : tempoOk || keyOk
            ? 1
            : 3;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final queue = [
      for (final t in app.player?.items ?? const <Track>[])
        if (t.isReady) t
    ];
    final showing = _searching
        ? (_found ?? const <Track>[])
        : ([...queue]..sort((a, b) => _score(a).compareTo(_score(b))));
    final accent = Theme.of(context).colorScheme.primary;
    final tab = _tab.value;
    final partsHere = widget.booth.parts.separatesHere;

    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Pad(
                  label: 'QUEUE',
                  lit: tab == CrateTab.queue,
                  colour: Console.ink,
                  height: 30,
                  onTap: () => _open(CrateTab.queue),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Pad(
                  label: partsHere ? null : 'SEARCH',
                  icon: Icons.search,
                  lit: tab == CrateTab.search,
                  colour: Console.ink,
                  height: 30,
                  tooltip: partsHere ? 'Search the library' : null,
                  onTap: () => _open(CrateTab.search),
                ),
              ),
              if (partsHere) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: ListenableBuilder(
                    listenable: partsJobs,
                    builder: (context, _) {
                      final now = partsJobs.running.firstOrNull;
                      return Pad(
                        label: 'PARTS',
                        icon: Icons.call_split,
                        lit: tab == CrateTab.parts,
                        colour: Console.ink,
                        height: 30,
                        tooltip: now == null
                            ? 'Records taken apart here'
                            : '${now.title} · ${stageLine(now)}',
                        progress: now == null
                            ? partsJobs.busy
                                ? 0
                                : null
                            : now.stage == PartsStage.separating
                                ? now.progress ?? 0
                                : 0,
                        onTap: () => _open(CrateTab.parts),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
          if (_searching) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _query,
              focusNode: _focus,
              onChanged: _search,
              style: Mag.typewriter(13, color: Console.ink),
              cursorColor: accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Title, artist…',
                hintStyle: Mag.typewriter(13, color: Console.faint),
                filled: true,
                fillColor: Console.ground,
                prefixIcon: _looking
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5)),
                      )
                    : const Icon(Icons.search, size: 18, color: Console.quiet),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none),
              ),
            ),
          ],
          if (widget.forDeck != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: Row(
                children: [
                  Icon(Icons.arrow_downward,
                      size: 13, color: Console.deck(widget.forDeck!.name)),
                  const SizedBox(width: 4),
                  Text('DECK ${widget.forDeck!.name}',
                      style: Console.label(8.5,
                          color: Console.deck(widget.forDeck!.name))),
                ],
              ),
            ),
          const SizedBox(height: 6),
          if (tab == CrateTab.parts)
            Expanded(
              child: _PartsList(
                  booth: widget.booth,
                  loadInto: widget.loadInto,
                  forDeck: widget.forDeck),
            )
          else
            Expanded(
              child: showing.isEmpty
                  ? Center(
                      child: Icon(
                          _searching ? Icons.search_off : Icons.queue_music,
                          size: 28,
                          color: Console.faint),
                    )
                  : ListView.builder(
                      itemCount: showing.length,
                      itemBuilder: (context, i) => _Row(
                        track: showing[i],
                        booth: widget.booth,
                        loadInto: widget.loadInto,
                        forDeck: widget.forDeck,
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row(
      {required this.track,
      required this.booth,
      required this.loadInto,
      required this.forDeck});
  final Track track;
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final b = widget.booth;
    final target = widget.forDeck ?? b.other(b.master);
    final row = MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        onTap: () => widget.loadInto(target, t),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _over ? Console.raised : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Artwork(track: t, size: 36, radius: 3),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.title(13.5, color: Console.ink)),
                    Text(t.artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.typewriter(10.5, color: Console.quiet)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (_over) ...[
                for (final d in [b.a, b.b]) ...[
                  Pad(
                    label: d.name,
                    colour: Console.deck(d.name),
                    dim: true,
                    width: 28,
                    height: 26,
                    tooltip: 'Onto deck ${d.name}',
                    onTap: () => widget.loadInto(d, t),
                  ),
                  const SizedBox(width: 4),
                ],
              ] else ...[
                _PartsGlyph(trackId: t.id),
                _Facts(booth: b, track: t),
              ],
            ],
          ),
        ),
      ),
    );
    return Draggable<Track>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Console.raised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.line),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Artwork(track: t, size: 34, radius: 3),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(t.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.title(13, color: Console.ink)),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }
}

/// Tempo and key, lit where they sit with the master.
class _Facts extends StatelessWidget {
  const _Facts({required this.booth, required this.track});
  final Booth booth;
  final Track track;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TrackTiming?>(
      future: booth.timing.of(track),
      initialData: booth.timing.peek(track.id),
      builder: (context, snap) {
        final tm = snap.data;
        if (tm == null) return const SizedBox(width: 40);
        final master = booth.master.timing;
        final shown = booth.master.bpm;
        final tempoOk = tm.bpm != null &&
            shown != null &&
            Booth.syncRatio(tm.bpm!, shown) != null;
        final keyOk = master != null && tm.inKeyWith(master);
        final good = Console.deck(booth.master.name);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tm.bpm != null)
              Text(tm.bpm!.toStringAsFixed(0),
                  style:
                      Mag.numerals(14, color: tempoOk ? good : Console.quiet)),
            if (tm.camelot != null) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 28,
                child: Text(tm.camelot!,
                    textAlign: TextAlign.right,
                    style: Mag.typewriter(10.5,
                        color: keyOk ? good : Console.faint, bold: true)),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// How taking a queued record apart is going, as a small mark beside its tempo: an
/// hourglass in the line, a ring while it happens, the split sign once it is in parts.
class _PartsGlyph extends StatelessWidget {
  const _PartsGlyph({required this.trackId});
  final int trackId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: partsJobs,
        builder: (context, _) {
          final j = partsJobs.of(trackId);
          if (j == null || j.stage == PartsStage.cancelled) {
            return const SizedBox.shrink();
          }
          final accent = Theme.of(context).colorScheme.primary;
          final Widget mark = switch (j.stage) {
            PartsStage.waiting =>
              const Icon(Icons.hourglass_empty, size: 12, color: Console.faint),
            PartsStage.ready =>
              const Icon(Icons.call_split, size: 13, color: Console.ink),
            PartsStage.failed =>
              const Icon(Icons.error_outline, size: 13, color: Console.a),
            _ => SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  value: j.stage == PartsStage.separating ? j.progress : null,
                  strokeWidth: 1.6,
                  color: accent,
                  backgroundColor: Console.line,
                ),
              ),
          };
          return Tooltip(
            message: stageLine(j),
            child:
                Padding(padding: const EdgeInsets.only(right: 8), child: mark),
          );
        },
      );
}

/// Records being taken apart on this computer, the way downloads are shown: the one
/// being done now, the line behind it, what is ready and when, and what failed and why.
class _PartsList extends StatelessWidget {
  const _PartsList(
      {required this.booth, required this.loadInto, required this.forDeck});
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: partsJobs,
        builder: (context, _) {
          final now = partsJobs.running;
          final waiting = partsJobs.waiting;
          final ready = partsJobs.ready;
          final failed = partsJobs.failed;
          if (now.isEmpty &&
              waiting.isEmpty &&
              ready.isEmpty &&
              failed.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.call_split, size: 28, color: Console.faint),
                  const SizedBox(height: 8),
                  Text('NOTHING BEING TAKEN APART',
                      style: Console.label(8.5, color: Console.faint)),
                ],
              ),
            );
          }
          Widget row(PartsJob j) => _JobRow(
              job: j, booth: booth, loadInto: loadInto, forDeck: forDeck);
          return ListView(
            children: [
              if (now.isNotEmpty) ...[
                const _Head('NOW'),
                for (final j in now) row(j)
              ],
              if (waiting.isNotEmpty) ...[
                _Head('WAITING · ${waiting.length}'),
                for (final j in waiting) row(j)
              ],
              if (ready.isNotEmpty) ...[
                _Head('READY · ${ready.length}'),
                for (final j in ready) row(j)
              ],
              if (failed.isNotEmpty) ...[
                _Head('FAILED · ${failed.length}'),
                for (final j in failed) row(j)
              ],
            ],
          );
        },
      );
}

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
        child: Text(text, style: Console.label(8.5, color: Console.quiet)),
      );
}

/// One record on the list: what it is, the stage it is at in words, a bar while it
/// moves, and what can be done about it — stop it, put it next, try it again.
class _JobRow extends StatefulWidget {
  const _JobRow(
      {required this.job,
      required this.booth,
      required this.loadInto,
      required this.forDeck});
  final PartsJob job;
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;

  @override
  State<_JobRow> createState() => _JobRowState();
}

class _JobRowState extends State<_JobRow> {
  bool _over = false;

  Widget _act(IconData icon, String tip, VoidCallback? onTap) => Tooltip(
        message: tip,
        child: InkResponse(
          onTap: onTap,
          radius: 16,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon,
                size: 16, color: onTap == null ? Console.faint : Console.ink),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final j = widget.job;
    final t = j.track;
    final b = widget.booth;
    final accent = Theme.of(context).colorScheme.primary;
    final onDeck = b.decks.where((d) => d.track?.id == j.trackId).firstOrNull;
    final colour = onDeck != null ? Console.deck(onDeck.name) : accent;
    final place = partsJobs.placeOf(j.trackId);
    final actions = <Widget>[
      if (j.active)
        _act(Icons.close, 'Stop', () => partsJobs.onCancel?.call(j.trackId)),
      if (j.stage == PartsStage.waiting) ...[
        if (place != null && place > 1)
          _act(Icons.vertical_align_top, 'Take apart next',
              () => partsJobs.onPromote?.call(j.trackId)),
        _act(Icons.close, 'Cancel', () => partsJobs.onCancel?.call(j.trackId)),
      ],
      if (j.stage == PartsStage.failed)
        _act(Icons.refresh, 'Try again',
            () => partsJobs.onRetry?.call(j.trackId)),
      if (j.stage == PartsStage.ready && t != null && _over)
        for (final d in [b.a, b.b]) ...[
          Pad(
            label: d.name,
            colour: Console.deck(d.name),
            dim: true,
            width: 28,
            height: 26,
            tooltip: 'Onto deck ${d.name}',
            onTap: () => widget.loadInto(d, t),
          ),
          const SizedBox(width: 4),
        ],
    ];
    final line = stageLine(j);
    final p = j.active
        ? j.stage == PartsStage.fetching && j.total == null
            ? null
            : j.progress ?? (j.stage == PartsStage.separating ? 0.0 : null)
        : null;
    final row = MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      cursor: t != null ? SystemMouseCursors.grab : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: t == null
            ? null
            : () => widget.loadInto(widget.forDeck ?? b.other(b.master), t),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
          decoration: BoxDecoration(
            color: _over ? Console.raised : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              t == null
                  ? const SizedBox(
                      width: 36,
                      height: 36,
                      child: Icon(Icons.album, color: Console.faint))
                  : Artwork(track: t, size: 36, radius: 3),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(j.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.title(13.5, color: Console.ink)),
                    const SizedBox(height: 1),
                    Tooltip(
                      message: j.stage == PartsStage.failed && j.error != null
                          ? j.error!
                          : '',
                      child: Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.typewriter(10.5,
                            color: j.stage == PartsStage.failed
                                ? Console.a
                                : j.stage == PartsStage.ready
                                    ? Console.ink
                                    : Console.quiet),
                      ),
                    ),
                    if (j.active) ...[
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(1),
                        child: LinearProgressIndicator(
                          value: p,
                          minHeight: 2,
                          color: colour,
                          backgroundColor: Console.line,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              ...actions,
            ],
          ),
        ),
      ),
    );
    if (t == null) return row;
    return Draggable<Track>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Console.raised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.line),
          ),
          child: Artwork(track: t, size: 34, radius: 3),
        ),
      ),
      child: row,
    );
  }
}
