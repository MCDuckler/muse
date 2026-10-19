// The show's own page of the booth: the room slid left of the decks (the board's
// twin on the other side), where the show is put together — the stage's picture
// big, the hands and the tabs under it, and down the right the rig as rows: the
// BACKGROUND, the SCENE over it (with its style and its treatment), how the two
// BLEND, and the FINISH over both. A chip is a choice,
// with a picture where there is one; the chip lit is what the stage shows now; a
// dimmed chip is one the director may not use. Each row has a lock: locked, it is
// the hands' until let go; unlocked, the director and the look choose.
//
// Under the hands the tabs: every scene with the director's switches, the RULES
// (what goes with what, and how), the DANCERS (who, and every move), MILKDROP's
// director, and the PERF numbers. Plan: ~/.claude/plans/wetowl-show-layers.md, §3.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_engine.dart';
import '../../state/show/show_pool.dart';
import '../../state/show/show_rig.dart';
import '../../state/show/show_tune.dart';
import '../booth/desk/console.dart';
import '../feel.dart';
import '../mag.dart';
import 'milk_page.dart';
import 'native_stage.dart';
import 'scene.dart';
import 'show_dance.dart' show DanceArt, DanceModels;
import 'show_debug.dart';
import 'show_flock.dart' show FlockLook;
import 'show_words.dart' show WordsStyle, wordsStyleWords;
import 'show_moves.dart';
import 'show_tile.dart' show showTileOffsetDialog;
import 'stage_kit.dart';
import 'stage_preview.dart';
import 'stage_page.dart';
import 'stage_pop_out_none.dart' if (dart.library.io) 'stage_pop_out_io.dart';

/// Bumped by the K key: the room slides to the show's page, or back.
final showRoomToggles = ValueNotifier<int>(0);

enum ShowTab { scenes, rules, dancers, milkdrop, perf }

/// The dancer looks, as one family on the SCENE row: the stage dressings.
const _dancerLooks = ['dance-disco', 'dance-neon', 'dance-shadow', 'dance-art'];

/// A chip's picture: the look's thumbnail (`assets/show/thumbs/<id>.webp`), where there is one.
const _thumbs = {
  'blocks', 'drift', 'echo', 'flash', 'flock', 'fluid', 'fold', 'glide', 'kinetic', 'siebenschlaefer', 'turntable', 'veins',
  'dance-disco', 'dance-neon', 'dance-shadow', 'dance-art', 'milk', 'pulse-grid', 'pulse-rays', 'pulse-smoke', 'pulse-stars',
  'lyrics',
};

String? thumbOf(String lookId) => _thumbs.contains(lookId) ? 'assets/show/thumbs/$lookId.webp' : null;

class ShowRoom extends StatefulWidget {
  const ShowRoom({super.key, required this.booth});
  final Booth booth;

  @override
  State<ShowRoom> createState() => _ShowRoomState();
}

class _ShowRoomState extends State<ShowRoom> {
  StageKit? _kit;
  String? _trouble;
  ShowTab _tab = ShowTab.scenes;
  final _info = ValueNotifier<StageInfo>(StageInfo.none);

  ShowEngine get show => widget.booth.show;

  /// The lines between the page's parts, dragged like the crate's edge and kept in
  /// show.json: the picture and the rig's share of the width (or, narrow, of the
  /// height), and how tall the picture is, as shares of the screen.
  double _split = 0.58, _splitNarrow = 0.6, _previewK = 0.34;

  double _panelNum(String key, double or, double lo, double hi) {
    final v = show.doc.panel[key];
    return v is num ? v.toDouble().clamp(lo, hi) : or;
  }

  void _keepLayout() => show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'split': _split, 'splitNarrow': _splitNarrow, 'preview': _previewK}));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await ShowDebug.load();
      await show.ready();
      final t = show.doc.panel['tab'];
      if (t is String) _tab = ShowTab.values.asNameMap()[t] ?? _tab;
      _split = _panelNum('split', _split, 0.3, 0.8);
      _splitNarrow = _panelNum('splitNarrow', _splitNarrow, 0.25, 0.8);
      _previewK = _panelNum('preview', _previewK, 0.12, 0.75);
      final kit = await StageKit.load();
      show.director.scenes = kit.book.metas;
      show.looks = kit.book.looks;
      if (mounted) setState(() => _kit = kit);
    } catch (e) {
      if (mounted) setState(() => _trouble = '$e');
    }
  }

  @override
  void dispose() {
    _info.dispose();
    super.dispose();
  }

  void _pickTab(ShowTab t) {
    setState(() => _tab = t);
    show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'tab': t.name}));
  }

  @override
  Widget build(BuildContext context) {
    final kit = _kit;
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 1100;
      final screenH = MediaQuery.sizeOf(context).height;
      final left = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Preview(booth: widget.booth, kit: kit, trouble: _trouble, info: _info, maxHeight: (screenH * _previewK).clamp(100.0, 900.0)),
          _Seam(
            vertical: true,
            tip: 'Drag: the picture taller or shorter',
            onDrag: (dy) => setState(() => _previewK = (_previewK + dy / screenH).clamp(0.12, 0.75)),
            onDone: _keepLayout,
          ),
          _Hands(show: show, kit: kit),
          const SizedBox(height: 8),
          Expanded(child: _Tabs(tab: _tab, onPick: _pickTab, show: show, kit: kit, info: _info, booth: widget.booth)),
        ],
      );
      // The rig down the right, the whole height: its rows are what is worked.
      final right = kit == null ? const SizedBox.shrink() : _RigStack(show: show, book: kit.book, booth: widget.booth);
      if (narrow) {
        final room = math.max(1.0, c.maxHeight - _Seam.reach);
        return Column(children: [
          SizedBox(height: room * _splitNarrow, child: left),
          _Seam(
            vertical: true,
            tip: 'Drag: more of the picture and the tabs, or more of the rig',
            onDrag: (dy) => setState(() => _splitNarrow = (_splitNarrow + dy / room).clamp(0.25, 0.8)),
            onDone: _keepLayout,
          ),
          Expanded(child: right),
        ]);
      }
      final room = math.max(1.0, c.maxWidth - _Seam.reach);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: room * _split, child: left),
          _Seam(
            vertical: false,
            tip: 'Drag: more of the picture and the tabs, or more of the rig',
            onDrag: (dx) => setState(() => _split = (_split + dx / room).clamp(0.3, 0.8)),
            onDone: _keepLayout,
          ),
          Expanded(child: right),
        ],
      );
    });
  }
}

/// A line between two parts of the page, taken hold of and dragged (the crate's
/// edge, either way): [vertical] for a line across, dragged up and down.
class _Seam extends StatefulWidget {
  const _Seam({required this.vertical, required this.onDrag, required this.onDone, this.tip});
  final bool vertical;
  final void Function(double delta) onDrag;
  final VoidCallback onDone;
  final String? tip;

  /// How much room the line takes: a hand's reach round a thin mark.
  static const reach = 10.0;

  @override
  State<_Seam> createState() => _SeamState();
}

class _SeamState extends State<_Seam> {
  bool _over = false, _held = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.vertical;
    final lit = _over || _held;
    Widget seam = MouseRegion(
      cursor: v ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: v ? (_) => setState(() => _held = true) : null,
        onVerticalDragUpdate: v ? (d) => widget.onDrag(d.delta.dy) : null,
        onVerticalDragEnd: v ? (_) => _done() : null,
        onHorizontalDragStart: v ? null : (_) => setState(() => _held = true),
        onHorizontalDragUpdate: v ? null : (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: v ? null : (_) => _done(),
        child: SizedBox(
          width: v ? double.infinity : _Seam.reach,
          height: v ? _Seam.reach : double.infinity,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: v ? 48 : 2,
              height: v ? 2 : 48,
              decoration: BoxDecoration(color: lit ? Console.quiet : Console.line, borderRadius: BorderRadius.circular(1)),
            ),
          ),
        ),
      ),
    );
    final tip = widget.tip;
    if (tip != null) seam = Tooltip(message: tip, waitDuration: const Duration(milliseconds: 900), child: seam);
    return seam;
  }

  void _done() {
    setState(() => _held = false);
    widget.onDone();
  }
}

// ------------------------------------------------------------------ the picture
class _Preview extends StatelessWidget {
  const _Preview({required this.booth, required this.kit, required this.trouble, required this.info, required this.maxHeight});
  final Booth booth;
  final double maxHeight;
  final StageKit? kit;
  final String? trouble;
  final ValueNotifier<StageInfo> info;

  @override
  Widget build(BuildContext context) {
    final show = booth.show;
    return BoothPanel(
      child: Plate(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // As tall as the line under it says (a third of the screen to start):
            // the rig's rows want the room.
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: ColoredBox(
                      color: Colors.black,
                      child: trouble != null
                          ? Center(child: Text('The stage could not load.\n$trouble', style: TextStyle(color: Console.quiet)))
                          : kit == null
                              ? const SizedBox.shrink()
                              : StagePreview(feed: show, book: kit!.book, programs: kit!.programs, scale: 0.6, rank: 1, info: info),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            ListenableBuilder(
              listenable: show,
              builder: (context, _) => ValueListenableBuilder<StageInfo>(
                valueListenable: info,
                builder: (context, i, _) {
                  final st = show.state;
                  final m = st.master;
                  final pending = show.pendingLook;
                  final rig = st.rig;
                  return Row(children: [
                    Expanded(
                      child: Text(
                        [
                          'NOW: ${kit?.book[st.scene]?.name ?? st.scene ?? '—'}${rig.figure.style != null ? ' · ${rig.figure.style}' : ''}',
                          'on ${rig.ground.label}',
                          rig.blend.ground == GroundMode.over ? 'plainly' : rig.blend.ground.name,
                          if (m.section != null) m.section!,
                          if (m.dropBeatsAway != null && m.dropBeatsAway! > 0) 'drop in ${m.dropBeatsAway!.ceil()}',
                          if (pending != null) '→ ${kit?.book[pending]?.name ?? pending} on the ${show.pendingAt?.name}',
                        ].join(' · '),
                        style: TextStyle(color: Console.ink, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('${i.word}${i.parked ? ' parked' : ''}${i.fps > 0 ? ' ${i.fps.round()} fps' : ''}', style: TextStyle(color: Console.quiet, fontSize: 11)),
                  ]);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ the hands
class _Hands extends StatelessWidget {
  const _Hands({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final m = show.macros;
          final held = show.sceneHeld;
          return BoothPanel(
            child: Plate(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: _Line(children: [
                Pad(icon: Icons.chevron_left, width: 30, height: 30, colour: Console.ink, tooltip: 'The scene before', onTap: show.previousScene),
                const SizedBox(width: 4),
                Pad(icon: Icons.chevron_right, width: 30, height: 30, colour: Console.ink, tooltip: 'The next scene', onTap: show.nextScene),
                const SizedBox(width: 8),
                Pad(
                  label: held ? 'HELD' : 'HOLD',
                  height: 30,
                  lit: held,
                  colour: Console.a,
                  tooltip: held ? 'The scene is held — let the director choose again' : 'Hold this scene: the director leaves it (the arrows still change it)',
                  onTap: () => show.holdScene(!held),
                ),
                const SizedBox(width: 10),
                Pad(label: 'HIT', height: 30, colour: Console.ink, tooltip: 'A flash on the stage (H on the stage page)', onTap: show.hit),
                const SizedBox(width: 4),
                Pad(
                  label: 'BLACK',
                  height: 30,
                  lit: m.blackout,
                  colour: Console.ink,
                  tooltip: 'Blackout (B)',
                  onTap: () => show.setMacros(show.macros.copyWith(blackout: !show.macros.blackout)),
                ),
                const SizedBox(width: 4),
                _Held(
                  label: 'STROBE',
                  lit: m.strobe > 0,
                  tooltip: 'Strobe while held (S)',
                  onDown: () => show.setMacros(show.macros.copyWith(strobe: 1)),
                  onUp: () => show.setMacros(show.macros.copyWith(strobe: 0)),
                ),
                const SizedBox(width: 4),
                Pad(
                  label: 'FREEZE',
                  height: 30,
                  lit: m.freeze,
                  colour: Console.ink,
                  tooltip: 'The picture held still (F)',
                  onTap: () => show.setMacros(show.macros.copyWith(freeze: !show.macros.freeze)),
                ),
                const SizedBox(width: 14),
                Knob(
                  value: m.intensity,
                  min: 0,
                  max: 1,
                  rest: 1,
                  bipolar: false,
                  size: 30,
                  label: 'LEVEL',
                  tooltip: 'Intensity: a master for everything',
                  onChanged: (v) => show.setMacros(show.macros.copyWith(intensity: v)),
                ),
                const SizedBox(width: 8),
                Knob(
                  value: m.colour,
                  min: 0,
                  max: 1,
                  rest: 0,
                  bipolar: false,
                  size: 30,
                  label: 'HUE',
                  tooltip: 'A turn of the palette\'s hue',
                  onChanged: (v) => show.setMacros(show.macros.copyWith(colour: v)),
                ),
                const SizedBox(width: 14),
                Text('LAND', style: Console.label(9)),
                const SizedBox(width: 4),
                for (final q in Quantise.values) ...[
                  Pad(
                    label: switch (q) { Quantise.now => 'NOW', Quantise.beat => 'BEAT', Quantise.bar => 'BAR', Quantise.phrase => 'PHRASE' },
                    height: 26,
                    lit: show.pool.quantise == q,
                    colour: Console.quiet,
                    tooltip: 'A scene you pick lands ${switch (q) { Quantise.now => 'at once', Quantise.beat => 'on the next beat', Quantise.bar => 'on the next bar', Quantise.phrase => 'on the next phrase' }}',
                    onTap: () => show.setPool(show.pool.copyWith(quantise: q)),
                  ),
                  const SizedBox(width: 2),
                ],
              ]),
            ),
          );
        },
      );
}

/// A pad that is on while the pointer is down.
class _Held extends StatelessWidget {
  const _Held({required this.label, required this.lit, required this.tooltip, required this.onDown, required this.onUp});
  final String label, tooltip;
  final bool lit;
  final VoidCallback onDown, onUp;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => onDown(),
        onPointerUp: (_) => onUp(),
        onPointerCancel: (_) => onUp(),
        child: Pad(label: label, height: 30, lit: lit, colour: Console.ink, tooltip: tooltip, onTap: () {}),
      );
}

/// Pads in one line, scrolled sideways where there are many (a pad in a column or a
/// wrap takes the whole width; in a row it takes its word's).
class _Line extends StatelessWidget {
  const _Line({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
      );
}

// ------------------------------------------------------------------ the rig
class _RigStack extends StatelessWidget {
  const _RigStack({required this.show, required this.book, required this.booth});
  final ShowEngine show;
  final SceneBook book;
  final Booth booth;

  @override
  Widget build(BuildContext context) => BoothPanel(
        child: Plate(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: ListenableBuilder(
            listenable: show,
            builder: (context, _) {
              final rig = show.state.rig;
              return ListView(
                children: [
                  Row(children: [
                    Text('THE RIG', style: Console.label(10, color: Console.ink)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('what is under, what is on it, how they blend, how it is finished — the lit chip is on; lock a row to keep it',
                          style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _GroundRow(show: show, rig: rig, booth: booth, book: book),
                  const Divider(height: 16),
                  _SceneRow(show: show, book: book, rig: rig),
                  const Divider(height: 16),
                  _BlendRow(show: show, rig: rig),
                  const Divider(height: 16),
                  _FinishRow(show: show, rig: rig),
                ],
              );
            },
          ),
        ),
      );
}

/// A layer's row: its name and a word on it, its chips, its lock, and a line under
/// for what the chip chosen has to say.
class _LayerRow extends StatelessWidget {
  const _LayerRow({required this.name, required this.word, required this.locked, required this.onLock, required this.lockTip, required this.child, this.below});
  final String name, word, lockTip;
  final bool locked;
  final void Function(bool) onLock;
  final Widget child;
  final Widget? below;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: Console.label(9, color: Console.ink)),
                    const SizedBox(height: 2),
                    Text(word, style: TextStyle(fontSize: 9, color: Console.faint, height: 1.15)),
                  ]),
                ),
              ),
              Expanded(child: child),
              const SizedBox(width: 6),
              Pad(
                icon: locked ? Icons.lock : Icons.lock_open,
                width: 26,
                height: 26,
                lit: locked,
                colour: Console.a,
                tooltip: lockTip,
                onTap: () => onLock(!locked),
              ),
            ],
          ),
          if (below != null) Padding(padding: const EdgeInsets.only(left: 110, top: 4), child: below),
        ],
      );
}

/// A chip: one choice of a row — its picture (or a colour), its name — lit when it is
/// what the stage shows, dimmed when the director may not use it, marked when it is
/// about to land.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.lit,
    required this.onTap,
    this.off = false,
    this.pending = false,
    this.tooltip,
    this.thumb,
    this.swatch,
  });
  final String label;
  final bool lit, off, pending;
  final String? tooltip;
  final VoidCallback onTap;

  /// A picture for the chip (an asset), or a painted colour.
  final String? thumb;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    final border = lit ? Console.a : (pending ? Console.b : Console.line);
    final fg = off ? Console.faint : Console.ink;
    final pictured = thumb != null || swatch != null;
    final face = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: lit ? Console.a.withValues(alpha: 0.18) : Console.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: lit || pending ? 1.5 : 1),
        boxShadow: lit ? [BoxShadow(color: Console.a.withValues(alpha: 0.35), blurRadius: 10, spreadRadius: -2)] : null,
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 3),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (pictured)
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Opacity(
              opacity: off ? 0.4 : 1,
              child: SizedBox(
                width: 64,
                height: 36,
                child: thumb != null
                    ? Image.asset(thumb!, fit: BoxFit.cover, filterQuality: FilterQuality.medium, errorBuilder: (context, _, __) => ColoredBox(color: swatch ?? Console.ground))
                    : ColoredBox(color: swatch!),
              ),
            ),
          ),
        if (pictured) const SizedBox(height: 3),
        Text(
          pending ? '$label ▸' : label,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: Console.label(8.5, color: lit ? Console.a : fg),
        ),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 5, bottom: 5),
      child: IntrinsicWidth(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              feel(Feel.pick);
              onTap();
            },
            child: tooltip == null ? face : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: face),
          ),
        ),
      ),
    );
  }
}

/// A plain word chip (no picture), for a mode or a style.
class _Word extends StatelessWidget {
  const _Word({required this.label, required this.lit, required this.onTap, this.off = false, this.tooltip});
  final String label;
  final bool lit, off;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4, bottom: 4),
        child: IntrinsicWidth(
          child: Pad(
            label: label,
            height: 24,
            lit: lit,
            dim: off && !lit,
            colour: lit ? Console.a : (off ? Console.faint : Console.ink),
            tooltip: tooltip,
            onTap: onTap,
          ),
        ),
      );
}

// ---------------------------------------------------------------- BACKGROUND
class _GroundRow extends StatelessWidget {
  const _GroundRow({required this.show, required this.rig, required this.booth, required this.book});
  final ShowEngine show;
  final ShowRig rig;
  final Booth booth;
  final SceneBook book;

  static const _fields = ['drift', 'glide', 'kinetic', 'blocks', 'flash'];

  @override
  Widget build(BuildContext context) {
    final g = rig.ground;
    final pool = show.pool;
    bool on(RigGround x) => x.kind == g.kind && (x.kind != Ground.field || x.field == g.field);
    final chips = <Widget>[
      for (final (label, ground, tip, thumb, swatch) in [
        ('Black', RigGround.black, 'Nothing under the scene', null, const Color(0xff050505)),
        ('Wash', const RigGround(kind: Ground.wash), 'A slow wash of the record\'s colours', null, const Color(0xff2a2238)),
        ('MilkDrop', RigGround.milk, 'MilkDrop\'s preset under the scene (the booth\'s way)', 'assets/show/thumbs/milk.webp', const Color(0xff402060)),
        for (final f in _fields)
          if (book.shaders.contains(f)) ('Field · ${book[f]?.name ?? f}', RigGround(kind: Ground.field, field: f, dim: 0.6), 'The ${book[f]?.name ?? f} shader as a quiet backdrop', 'assets/show/thumbs/$f.webp', null),
      ])
        _Chip(
          label: label,
          lit: on(ground),
          off: !pool.isOn('ground.${ground.kind.name}'),
          tooltip: tip,
          thumb: thumb,
          swatch: swatch,
          onTap: () => show.setGround(ground),
        ),
      _Chip(
        label: 'Camera',
        lit: g.kind == Ground.camera,
        off: !pool.isOn('ground.camera'),
        tooltip: 'The room\'s camera under the scene (started as needed)',
        swatch: const Color(0xff203028),
        onTap: () => show.setGround(const RigGround(kind: Ground.camera, dim: 0.8)),
      ),
      _Chip(
        label: 'Cover',
        lit: g.kind == Ground.cover,
        off: !pool.isOn('ground.cover'),
        tooltip: 'The record\'s cover under the scene',
        swatch: const Color(0xff303040),
        onTap: () => show.setGround(const RigGround(kind: Ground.cover, dim: 0.6)),
      ),
      for (final v in pulseVariants)
        _Chip(
          label: 'Pulse · $v',
          lit: g.kind == Ground.pulse && pulseVariant(g.field) == pulseVariant(v),
          off: !pool.isOn('ground.pulse'),
          tooltip: 'A quiet field moving with the record\'s bands: ${switch (v) { 'grid' => 'a floor and a ceiling of thin lines', 'rays' => 'soft rays turning with the bar', 'smoke' => 'slow curls in two of the palette\'s hues', _ => 'a starfield drifting in' }}',
          thumb: 'assets/show/thumbs/pulse-$v.webp',
          swatch: const Color(0xff101418),
          onTap: () => show.setGround(RigGround(kind: Ground.pulse, field: v)),
        ),
    ];
    final milk = MilkFeed.shared;
    return _LayerRow(
      name: 'BACKGROUND',
      word: 'what lies under the scene',
      locked: show.locked(RigSlot.ground),
      lockTip: show.locked(RigSlot.ground) ? 'The background is yours — let the scene and the director have it' : 'Keep this background whatever the director does',
      onLock: (v) => show.lock(RigSlot.ground, v),
      below: g.kind == Ground.milk && milk.available
          ? ListenableBuilder(
              listenable: milk,
              builder: (context, _) {
                final d = milk.director;
                return _Line(children: [
                  Icon(Icons.blur_on, size: 14, color: Console.quiet),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(milk.running ? (milk.presetName ?? 'MilkDrop…') : 'MilkDrop off',
                        style: TextStyle(color: milk.running ? Console.ink : Console.quiet, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  Pad(icon: Icons.chevron_left, width: 24, height: 24, colour: Console.quiet, tooltip: 'The preset before', onTap: d.previous),
                  const SizedBox(width: 2),
                  Pad(icon: Icons.chevron_right, width: 24, height: 24, colour: Console.quiet, tooltip: 'The next preset', onTap: d.next),
                  const SizedBox(width: 2),
                  Pad(icon: Icons.casino_outlined, width: 24, height: 24, colour: Console.quiet, tooltip: 'Another preset', onTap: () {
                    if (!milk.running) unawaited(milk.start());
                    d.random(byHand: true);
                  }),
                  const SizedBox(width: 2),
                  Pad(
                    icon: d.locked ? Icons.lock : Icons.lock_open,
                    width: 24,
                    height: 24,
                    lit: d.locked,
                    colour: Console.a,
                    tooltip: d.locked ? 'The preset is held — let MilkDrop\'s director change it again' : 'Hold this preset',
                    onTap: () => d.set(locked: !d.locked),
                  ),
                  const SizedBox(width: 8),
                  Pad(label: 'PRESETS…', height: 24, colour: Console.quiet, tooltip: 'Browse, favourite, make and edit MilkDrop presets', onTap: () => openMilkPage(context, booth)),
                ]);
              },
            )
          : g.kind == Ground.field || g.kind == Ground.cover || g.kind == Ground.camera
              ? Row(children: [
                  Text('how much of it', style: Console.label(9)),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 160,
                    child: Slider(value: g.dim, onChanged: (v) => show.setGround(g.copyWith(dim: v)), padding: EdgeInsets.zero),
                  ),
                  Text('${(g.dim * 100).round()} %', style: Console.label(9)),
                ])
              : null,
      child: Wrap(children: chips),
    );
  }
}

// ---------------------------------------------------------------- SCENE
class _SceneRow extends StatelessWidget {
  const _SceneRow({required this.show, required this.book, required this.rig});
  final ShowEngine show;
  final SceneBook book;
  final ShowRig rig;

  @override
  Widget build(BuildContext context) {
    final st = show.state;
    final pool = show.pool;
    final pending = show.pendingLook;
    final dancersOn = _dancerLooks.contains(st.scene);
    final dancersPending = _dancerLooks.contains(pending);
    // The dancer family's chip launches the dressing last on (the stylized one to start).
    final dancerLast = dancersOn ? st.scene! : (show.doc.panel['dancerLook'] as String? ?? 'dance-art');
    final others = book.scenes.values.where((s) => !_dancerLooks.contains(s.id)).toList()..sort((a, b) => a.name.compareTo(b.name));
    void launch(String id) {
      if (pending == id) {
        show.launch(id, at: Quantise.now);
      } else {
        show.launch(id);
      }
      if (_dancerLooks.contains(id)) show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'dancerLook': id}));
    }

    final chips = <Widget>[
      _Chip(
        label: 'Dancers',
        lit: dancersOn,
        pending: !dancersOn && dancersPending,
        off: _dancerLooks.every((id) => !pool.isOn('look.$id')),
        thumb: thumbOf(dancerLast),
        tooltip: 'The dancers — ${book[dancerLast]?.name ?? dancerLast}; the dressing and the style under',
        onTap: () => launch(dancerLast),
      ),
      for (final s in others)
        _Chip(
          label: s.name,
          lit: s.id == st.scene,
          pending: s.id == pending,
          off: !pool.isOn('look.${s.id}'),
          thumb: thumbOf(s.id),
          swatch: Console.ground,
          tooltip: '${s.name}${s.meta.needs.contains('camera') ? ' (needs the camera)' : ''}${s.meta.needs.contains('milk') ? ' (MilkDrop as the scene)' : ''}',
          onTap: () => launch(s.id),
        ),
    ];
    // The style line: the dancers' dressing and art, or the birds' look.
    Widget? below;
    if (dancersOn) {
      final isArt = st.scene == 'dance-art';
      below = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 70, child: Text('dressing', style: Console.label(9))),
          Expanded(
            child: _Line(children: [
              for (final id in _dancerLooks)
                _Word(
                  label: (book[id]?.name ?? id).replaceFirst('Dancer · ', '').toUpperCase(),
                  lit: st.scene == id,
                  off: !pool.isOn('look.$id'),
                  tooltip: book[id]?.name,
                  onTap: () => launch(id),
                ),
            ]),
          ),
        ]),
        if (isArt)
          Row(children: [
            SizedBox(width: 70, child: Text('style', style: Console.label(9))),
            Expanded(
              child: _Line(children: [
                _Word(
                  label: 'AUTO',
                  lit: show.style == null,
                  tooltip: 'The dancers\' own clock picks a style a section at a time, from the pool',
                  onTap: () => show.setStyle(null),
                ),
                // The image treatments are on the treatment line, for every scene.
                for (final a in DanceArt.values)
                  if (!treatmentFxMode.containsKey(a.name))
                    _Word(
                      label: a.name.toUpperCase(),
                      lit: show.style == a.name && show.styleFor == Figure.dancers,
                      off: !pool.isOn('treatment.${a.name}') && Treatment.values.any((t) => t.name == a.name),
                      tooltip: _artWords[a],
                      onTap: () => show.setStyle(a.name, forKind: Figure.dancers),
                    ),
              ]),
            ),
          ]),
      ]);
    } else if (st.scene == 'flock') {
      below = Row(children: [
        SizedBox(width: 70, child: Text('look', style: Console.label(9))),
        Expanded(
          child: _Line(children: [
            _Word(label: 'AUTO', lit: show.style == null, tooltip: 'The flock\'s own clock picks a look a section at a time', onTap: () => show.setStyle(null)),
            for (final l in FlockLook.values)
              if (!treatmentFxMode.containsKey(l.name))
              _Word(
                label: l.name.toUpperCase(),
                lit: show.style == l.name && show.styleFor == Figure.birds,
                off: !pool.isOn('treatment.${l.name}') && Treatment.values.any((t) => t.name == l.name),
                onTap: () => show.setStyle(l.name, forKind: Figure.birds),
              ),
          ]),
        ),
      ]);
    } else if (st.scene == 'lyrics') {
      below = Row(children: [
        SizedBox(width: 70, child: Text('style', style: Console.label(9))),
        Expanded(
          child: _Line(children: [
            _Word(label: 'AUTO', lit: show.style == null, tooltip: 'The words\' own clock picks a style a section at a time (the hook in the stencil)', onTap: () => show.setStyle(null)),
            for (final s in WordsStyle.values)
              _Word(
                label: s.name.toUpperCase(),
                lit: show.style == s.name && show.styleFor == Figure.words,
                tooltip: wordsStyleWords[s],
                onTap: () => show.setStyle(s.name, forKind: Figure.words),
              ),
          ]),
        ),
      ]);
    }
    // Any scene through a treatment, kept for that scene: none, the conductor's mix
    // (as every scene starts), or one held; what is in the mix (for every scene on
    // it); and the knobs of the treatment on now.
    final scene = st.scene;
    if (scene != null) {
      final say = pool.treat[scene];
      final mix = say == null || say == 'mix';
      final now = imageTreatments.contains(rig.figure.treatment) ? rig.figure.treatment.name : null;
      final name = book[scene]?.name ?? scene;
      final treatLine = Row(children: [
        SizedBox(width: 70, child: Text('treatment', style: Console.label(9))),
        Expanded(
          child: _Line(children: [
            _Word(label: 'OFF', lit: say == 'raw', tooltip: '$name as it draws itself, always', onTap: () => show.setTreat(scene, 'raw')),
            _Word(
              label: mix ? 'MIX · ${(now ?? 'as drawn').toUpperCase()}' : 'MIX',
              lit: mix,
              tooltip: 'The conductor picks from the mix every ${ShowEngine.treatBars} bars (the look as drawn counts twice)',
              onTap: () => show.setTreat(scene, null),
            ),
            for (final t in imageTreatments)
              _Word(
                label: t.name.toUpperCase(),
                lit: say == t.name,
                tooltip: '${_treatWords[t]} — held for $name',
                onTap: () => show.setTreat(scene, say == t.name ? null : t.name),
              ),
          ]),
        ),
      ]);
      final mixLine = !mix
          ? null
          : Row(children: [
              SizedBox(width: 70, child: Text('the mix', style: Console.label(9))),
              Expanded(
                child: _Line(children: [
                  for (final t in [Treatment.raw, ...imageTreatments])
                    if (mixOf(pool, scene).contains(t.name) case final inMix)
                      _Word(
                        label: t == Treatment.raw ? 'AS DRAWN' : t.name.toUpperCase(),
                        lit: inMix,
                        off: !inMix,
                        tooltip: inMix
                            ? "In $name's mix — a tap takes it out (other scenes keep theirs)"
                            : "Out of $name's mix: the conductor never picks it here (the scene can still hold it)",
                        onTap: () => show.setPool(withInMix(pool, scene, t.name, !inMix)),
                      ),
                ]),
              ),
            ]);
      final knobs = now == null ? null : _TuneLine(show: show, treatment: now);
      below = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (below != null) below,
        treatLine,
        if (mixLine != null) mixLine,
        if (knobs != null) knobs,
      ]);
    }
    return _LayerRow(
      name: 'SCENE',
      word: 'what stands on it — a tap lands it as the hands say',
      locked: show.sceneHeld,
      lockTip: show.sceneHeld ? 'The scene is held — let the director choose again' : 'Hold this scene: the director leaves it',
      onLock: (v) => show.holdScene(v),
      below: below,
      child: Wrap(children: chips),
    );
  }

  static const _treatWords = {
    Treatment.ascii: 'the picture as text',
    Treatment.dither: 'one bit: ink and paper',
    Treatment.halftone: 'two inks screened, a riso print',
    Treatment.thermal: 'a heat camera',
    Treatment.lines: 'a ridgeline plot',
    Treatment.contour: 'a topographic map of the light',
  };

  static const _artWords = {
    DanceArt.mono: 'a silhouette, black on white (Bad Apple)',
    DanceArt.trails: 'a chrome figure with ribbons of light behind its hands and feet',
    DanceArt.ascii: 'the figure as text',
    DanceArt.dither: 'one bit: ink and paper',
    DanceArt.chrono: 'a chronophotograph: the figure stamped every half beat',
    DanceArt.contour: 'a topographic map of the light (off by default)',
    DanceArt.halftone: 'two inks screened, a riso print',
    DanceArt.thermal: 'a heat camera',
    DanceArt.lines: 'a ridgeline plot',
    DanceArt.fluid: 'chrome figures in a coloured fluid (native stage)',
    DanceArt.viewports: 'a model editor\'s grid of viewports (native stage)',
    DanceArt.plain: 'the scans as they are, on white: over MilkDrop, not blended',
  };
}

/// A treatment's knobs (show_tune.dart), for whatever is drawn through it: turned,
/// kept in show.json; a double-click puts one back.
class _TuneLine extends StatelessWidget {
  const _TuneLine({required this.show, required this.treatment});
  final ShowEngine show;
  final String treatment;

  @override
  Widget build(BuildContext context) {
    final tune = show.pool.tune;
    final specs = treatmentTunes[treatment] ?? const <TuneSpec>[];
    final touched = specs.any((s) => tune.containsKey(tuneKey(treatment, s.knob)));
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(children: [
        SizedBox(width: 70, child: Text(treatment, style: Console.label(9))),
        Expanded(
          child: _Line(children: [
            for (final s in specs)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Knob(
                  value: tuneOf(tune, treatment, s.knob),
                  min: s.min,
                  max: s.max,
                  rest: s.rest,
                  bipolar: false,
                  size: 30,
                  label: s.label,
                  tooltip: '${s.tip}: ${s.knob == TuneKnob.tint ? '${(tuneOf(tune, treatment, s.knob) * 100).round()} %' : '× ${tuneOf(tune, treatment, s.knob).toStringAsFixed(2)}'} (double-click: as drawn)',
                  onChanged: (v) => show.setTune(treatment, s.knob, v == s.rest ? null : v),
                ),
              ),
            if (touched)
              _Word(
                label: 'RESET',
                lit: false,
                tooltip: 'Every $treatment knob back as drawn',
                onTap: () {
                  var p = show.pool;
                  for (final s in specs) {
                    p = p.withTune(tuneKey(treatment, s.knob), null);
                  }
                  show.setPool(p);
                },
              ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- BLEND
class _BlendRow extends StatelessWidget {
  const _BlendRow({required this.show, required this.rig});
  final ShowEngine show;
  final ShowRig rig;

  static const words = {
    GroundMode.through: 'the scene\'s own backdrop dropped: the background shows there',
    GroundMode.over: 'the scene as drawn; the background hidden',
    GroundMode.add: 'the scene\'s light added over the background',
    GroundMode.screen: 'screened: neither blows the other out',
    GroundMode.dim: 'the background at a third, the scene on top',
    GroundMode.window: 'the background shows through the scene\'s bright parts',
    GroundMode.mask: 'the background only where the scene is dark',
    GroundMode.frame: 'the scene in the middle, the background round it',
    GroundMode.bands: 'vertical bands by turns, stepping with the beat',
    GroundMode.flip: 'the scene over the background; the background over it on each kick',
    GroundMode.outline: 'the background\'s edges only, as lines under the scene',
    GroundMode.contrast: 'the difference of the two: where they agree is dark (the booth\'s way)',
  };

  @override
  Widget build(BuildContext context) {
    final b = rig.blend;
    final locked = show.locked(RigSlot.blend);
    final figuresOver = b.figure == FigureMode.over;
    return _LayerRow(
      name: 'BLEND',
      word: 'how the scene sits on the background',
      locked: locked,
      lockTip: locked ? 'The blend is yours — let the rules decide again' : 'Keep this blend whatever the scene',
      onLock: (v) => show.lock(RigSlot.blend, v),
      below: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${b.ground.name}: ${words[b.ground]}${b.auto ? ' · by the rules' : ''}', style: TextStyle(fontSize: 10, color: Console.quiet), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        _Line(children: [
          Text('the figures', style: Console.label(9)),
          const SizedBox(width: 6),
          _Word(
            label: 'OVER',
            lit: figuresOver && !b.auto,
            tooltip: 'The bodies, the glyphs, the shapes go over the background as drawn',
            onTap: () => show.setBlend(b.copyWith(figure: FigureMode.over)),
          ),
          _Word(
            label: 'BLEND TOO',
            lit: !figuresOver && !b.auto,
            tooltip: 'The figures are blended like the scene\'s backdrop',
            onTap: () => show.setBlend(b.copyWith(figure: FigureMode.same)),
          ),
          _Word(
            label: 'AS THE SCENE ASKS',
            lit: b.auto,
            tooltip: 'The plain dancers over; the rest blended (today\'s picture)',
            onTap: () => show.lock(RigSlot.blend, false),
          ),
          const SizedBox(width: 12),
          Text('strength', style: Console.label(9)),
          const SizedBox(width: 6),
          SizedBox(
            width: 140,
            child: Slider(value: b.strength, onChanged: (v) => show.setBlend(b.copyWith(strength: v)), padding: EdgeInsets.zero),
          ),
          Text('${(b.strength * 100).round()} %', style: Console.label(9)),
        ]),
      ]),
      child: Wrap(children: [
        _Word(label: 'AUTO', lit: b.auto, tooltip: 'The rules decide: the booth\'s way is contrast under MilkDrop', onTap: () => show.lock(RigSlot.blend, false)),
        for (final m in GroundMode.values)
          _Word(
            label: m.name.toUpperCase(),
            lit: b.ground == m && !b.auto,
            tooltip: words[m],
            onTap: () => show.setBlend(b.copyWith(ground: m)),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- FINISH
class _FinishRow extends StatelessWidget {
  const _FinishRow({required this.show, required this.rig});
  final ShowEngine show;
  final ShowRig rig;

  @override
  Widget build(BuildContext context) {
    final f = rig.finish;
    final locked = show.locked(RigSlot.finish);
    Widget knob(String label, double v, double max, String tip, RigFinish Function(double) set) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Knob(value: v, min: 0, max: max, rest: 0, bipolar: false, size: 30, label: label, tooltip: '$tip: ${(v / max * 100).round()} %', onChanged: (x) => show.setFinish(set(x))),
        );
    return _LayerRow(
      name: 'FINISH',
      word: 'over everything',
      locked: locked,
      lockTip: locked ? 'The finish is yours — let the scene have its own again' : 'Keep this finish whatever the scene',
      onLock: (v) => show.lock(RigSlot.finish, v),
      child: _Line(children: [
        knob('TRAILS', f.trails, 0.9, 'How much of last frame lingers', (x) => f.copyWith(trails: x)),
        knob('BLOOM', f.bloom, 1.5, 'The glow round bright things', (x) => f.copyWith(bloom: x)),
        knob('TONE', f.tone, 1, 'The film curve (0 is the picture as drawn)', (x) => f.copyWith(tone: x)),
        knob('GRAIN', f.grain, 1, 'Film grain', (x) => f.copyWith(grain: x)),
        knob('VIGNETTE', f.vignette, 1, 'The corners darkened', (x) => f.copyWith(vignette: x)),
        _Word(
          label: 'WORDS',
          lit: f.title || f.lyrics,
          tooltip: 'The record\'s title and the line being sung over the stage',
          onTap: () => show.setFinish(f.copyWith(title: !(f.title || f.lyrics), lyrics: !(f.title || f.lyrics))),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ the tabs
class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.onPick, required this.show, required this.kit, required this.info, required this.booth});
  final ShowTab tab;
  final void Function(ShowTab) onPick;
  final ShowEngine show;
  final StageKit? kit;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  @override
  Widget build(BuildContext context) => BoothPanel(
        child: Plate(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Line(children: [
                for (final t in ShowTab.values) ...[
                  Pad(
                    label: t.name.toUpperCase(),
                    height: 26,
                    lit: t == tab,
                    colour: Console.ink,
                    onTap: () => onPick(t),
                  ),
                  const SizedBox(width: 4),
                ],
                const SizedBox(width: 8),
                Pad(icon: Icons.fullscreen, width: 26, height: 26, colour: Console.quiet, tooltip: 'The stage over this window (⇧V)', onTap: kit == null ? null : () => openStagePage(context, booth)),
                const SizedBox(width: 4),
                Pad(
                  icon: Icons.open_in_new,
                  width: 26,
                  height: 26,
                  colour: Console.quiet,
                  tooltip: 'The stage in a window of its own (⌥V)',
                  onTap: canPopOutStage ? () => unawaited(popOutStage(context.read<AppState?>()?.boardLink)) : null,
                ),
              ]),
              const Divider(height: 14),
              Expanded(
                // Under the picture the tabs may be short (a 1280 x 800 desk): a tab
                // gets at least the height it is laid out for, scrolled where the
                // panel has less (the moves' viewer and its list want the most).
                child: LayoutBuilder(builder: (context, c) {
                  final body = switch (tab) {
                    ShowTab.scenes => _ScenesTab(show: show, kit: kit) as Widget,
                    ShowTab.rules => _RulesTab(show: show, kit: kit),
                    ShowTab.dancers => _DancersTab(show: show),
                    ShowTab.milkdrop => _MilkTab(show: show, booth: booth),
                    ShowTab.perf => _PerfTab(show: show, info: info, booth: booth),
                  };
                  final least = tab == ShowTab.dancers ? 560.0 : 300.0;
                  if (c.maxHeight >= least) return body;
                  return SingleChildScrollView(child: SizedBox(height: least, child: body));
                }),
              ),
            ],
          ),
        ),
      );
}

class _ScenesTab extends StatelessWidget {
  const _ScenesTab({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  @override
  Widget build(BuildContext context) {
    final book = kit?.book;
    if (book == null) return const SizedBox.shrink();
    final looks = book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return ListenableBuilder(
      listenable: show,
      builder: (context, _) {
        final st = show.state;
        final pool = show.pool;
        return ListView(
          children: [
            Text('Every scene. A name puts it on (landing as the hands say); the switch is the director\'s: off, it never reaches for it.',
                style: TextStyle(fontSize: 11, color: Console.quiet)),
            const SizedBox(height: 6),
            for (final s in looks)
              Row(children: [
                SizedBox(
                  width: 64,
                  height: 36,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: thumbOf(s.id) != null ? Image.asset(thumbOf(s.id)!, fit: BoxFit.cover, errorBuilder: (c, _, __) => ColoredBox(color: Console.ground)) : ColoredBox(color: Console.ground),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () => show.launch(s.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          if (s.id == st.scene) Icon(Icons.play_arrow, size: 14, color: Console.a),
                          if (s.id == st.scene) const SizedBox(width: 3),
                          Text(s.name, style: TextStyle(color: pool.isOn('look.${s.id}') ? Console.ink : Console.faint, fontSize: 13)),
                        ]),
                        Text(
                          '${s.look.rig.figure.kind == Figure.none ? s.look.rig.ground.label : s.look.rig.figure.label} · energy ${(s.meta.energy.$1 * 10).round()}–${(s.meta.energy.$2 * 10).round()}${s.meta.sections.isEmpty ? '' : ' · ${s.meta.sections.join(' ')}'}',
                          style: TextStyle(color: Console.quiet, fontSize: 10),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ]),
                    ),
                  ),
                ),
                Tooltip(
                  message: pool.isOn('look.${s.id}') ? 'On: the director may choose it' : 'Off: the director passes it by (a tap still puts it on)',
                  child: Switch(
                    value: pool.isOn('look.${s.id}'),
                    onChanged: (v) {
                      show.setPool(pool.withOff('look.${s.id}', !v));
                      if (!v && st.scene == s.id) show.nextScene();
                    },
                  ),
                ),
              ]),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- RULES
/// What goes with what: the scenes down the side, the backgrounds across, a cell for
/// each pair — together (the rules' blend), never, or a blend of the hands' own.
class _RulesTab extends StatelessWidget {
  const _RulesTab({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  static const _grounds = [Ground.black, Ground.wash, Ground.milk, Ground.field, Ground.camera, Ground.cover, Ground.pulse];

  /// The rows: each figure kind once (its scene's name), and the dancers' plain and
  /// silhouette shades, which the table treats on their own.
  List<(String, RigFigure)> _rows(SceneBook book) {
    final out = <(String, RigFigure)>[];
    final seen = <Figure>{};
    for (final s in book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name))) {
      final f = s.look.rig.figure;
      if (f.kind == Figure.none || !seen.add(f.kind)) continue;
      final name = f.kind == Figure.dancers ? 'Dancers' : s.name;
      if (f.kind == Figure.dancers) {
        out.add(('Dancers · plain', const RigFigure(kind: Figure.dancers, shade: Shade.textured)));
        out.add(('Dancers · silhouette', const RigFigure(kind: Figure.dancers, shade: Shade.silhouette)));
        out.add(('Dancers · the rest', const RigFigure(kind: Figure.dancers)));
      } else {
        out.add((name, RigFigure(kind: f.kind)));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final book = kit?.book;
    if (book == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: show,
      builder: (context, _) {
        final pool = show.pool;
        final rows = _rows(book);
        return ListView(
          children: [
            Text('What goes with what. A cell is a scene on a background: ✓ together (blended by the rules — contrast under MilkDrop), ✗ never, or a blend of your own. '
                'A tap steps ✓ → ✗ → back; a long press picks a blend. The director keeps to the table; your own taps on the rig do not.',
                style: TextStyle(fontSize: 11, color: Console.quiet)),
            const SizedBox(height: 8),
            Table(
              defaultColumnWidth: const FixedColumnWidth(54),
              columnWidths: const {0: FlexColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(children: [
                  const SizedBox.shrink(),
                  for (final g in _grounds)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(g.name, textAlign: TextAlign.center, style: Console.label(8, color: pool.isOn('ground.${g.name}') ? Console.ink : Console.faint)),
                    ),
                ]),
                for (final (name, fig) in rows)
                  TableRow(children: [
                    Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(name, style: TextStyle(fontSize: 11, color: Console.ink))),
                    for (final g in _grounds) _RuleCell(show: show, figure: fig, ground: g),
                  ]),
              ],
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text('BACKGROUNDS the director may use', style: Console.label(10, color: Console.ink))),
              TextButton(
                onPressed: () => show.setPool(pool.copyWith(combos: const {})),
                child: Text('table as shipped', style: TextStyle(fontSize: 11, color: Console.quiet)),
              ),
            ]),
            Wrap(children: [
              for (final g in _grounds)
                _Word(
                  label: g.name.toUpperCase(),
                  lit: pool.isOn('ground.${g.name}'),
                  off: !pool.isOn('ground.${g.name}'),
                  tooltip: pool.isOn('ground.${g.name}') ? 'On' : 'Off: the director never puts it under a scene',
                  onTap: () => show.setPool(pool.withOff('ground.${g.name}', pool.isOn('ground.${g.name}'))),
                ),
            ]),
            const SizedBox(height: 8),
            Text("STYLES the dancers and the birds may wear (the treatments' mix is on the SCENE row)", style: Console.label(10, color: Console.ink)),
            const SizedBox(height: 4),
            Wrap(children: [
              for (final t in Treatment.values)
                if (t != Treatment.auto && t != Treatment.raw && !imageTreatments.contains(t))
                  _Word(
                    label: t.name.toUpperCase(),
                    lit: pool.isOn('treatment.${t.name}'),
                    off: !pool.isOn('treatment.${t.name}'),
                    tooltip: pool.isOn('treatment.${t.name}') ? 'On' : 'Off: their clocks never pick it (a tap on the style row still can)',
                    onTap: () => show.setPool(pool.withOff('treatment.${t.name}', pool.isOn('treatment.${t.name}'))),
                  ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Text('DIRECTOR', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 10),
              Text('calm', style: Console.label(9)),
              Expanded(child: Slider(value: pool.bias, min: -1, max: 1, onChanged: (v) => show.setPool(pool.copyWith(bias: v)))),
              Text('busy', style: Console.label(9)),
            ]),
            Text('calm leans to the quieter scenes, busy to the louder', style: TextStyle(fontSize: 10, color: Console.faint)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text('the beat before a drop goes black', style: TextStyle(fontSize: 12, color: Console.ink))),
              Switch(value: pool.darkBeat, onChanged: (v) => show.setPool(pool.copyWith(darkBeat: v))),
            ]),
          ],
        );
      },
    );
  }
}

class _RuleCell extends StatelessWidget {
  const _RuleCell({required this.show, required this.figure, required this.ground});
  final ShowEngine show;
  final RigFigure figure;
  final Ground ground;

  @override
  Widget build(BuildContext context) {
    final pool = show.pool;
    final key = ShowPool.comboKey(figure, ground);
    final mine = pool.combos[key];
    final rule = pool.ruleFor(figure, ground);
    final off = rule?.off ?? false;
    final mode = rule?.ground;
    final word = off ? '✗' : (mode == null || mode == GroundMode.over || mode == GroundMode.contrast && ground == Ground.milk ? '✓' : mode.name);
    final tip = off
        ? 'Never together'
        : 'Together${mode == null ? '' : ', ${mode.name}'}${rule?.figure == FigureMode.over ? ', the figures over' : ''}${mine != null ? ' (yours)' : ''}';
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        message: '$tip — tap: ✓ → ✗ → as shipped; long press: a blend',
        child: GestureDetector(
          onTap: () {
            feel(Feel.pick);
            final next = off ? null : ComboRule.never;
            if (off && mine == null) {
              // Shipped as never: the hands make it together.
              show.setPool(pool.withCombo(key, const ComboRule()));
            } else {
              show.setPool(pool.withCombo(key, next));
            }
          },
          onLongPress: () async {
            final picked = await showMenu<GroundMode>(
              context: context,
              position: RelativeRect.fill,
              items: [for (final m in GroundMode.values) PopupMenuItem(value: m, child: Text('${m.name} — ${_BlendRow.words[m]}', style: const TextStyle(fontSize: 12)))],
            );
            if (picked != null) show.setPool(pool.withCombo(key, ComboRule(ground: picked)));
          },
          child: Container(
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: off ? Console.ground : (mine != null ? Console.a.withValues(alpha: 0.15) : Console.raised),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: mine != null ? Console.a : Console.line),
            ),
            child: Text(word, style: TextStyle(fontSize: 10, color: off ? Console.faint : Console.ink)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- DANCERS
class _DancersTab extends StatelessWidget {
  const _DancersTab({required this.show});
  final ShowEngine show;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final pool = show.pool;
          final lead = pool.dancer;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('WHO DANCES · a name dances alone, a switch off keeps them out of the mix', style: Console.label(9, color: Console.ink)),
              const SizedBox(height: 4),
              _Line(children: [
                _Word(label: 'A MIX', lit: lead == null, tooltip: 'Each record its own lead, the others in the troupe', onTap: () => show.setPool(pool.copyWith(clearDancer: true))),
                const SizedBox(width: 6),
                for (final (id, name) in DanceModels.all) ...[
                  _Word(label: name.toUpperCase(), lit: lead == id, off: !pool.isOn('dancer.$id'), tooltip: 'Only $name dances', onTap: () => show.setPool(pool.copyWith(dancer: id))),
                  Tooltip(
                    message: pool.isOn('dancer.$id') ? 'On: may dance in the mix' : 'Off: never in the mix',
                    child: Switch(
                      value: pool.isOn('dancer.$id'),
                      onChanged: (v) {
                        var p = pool.withOff('dancer.$id', !v);
                        if (!v && p.dancer == id) p = p.copyWith(clearDancer: true);
                        show.setPool(p);
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
              ]),
              const Divider(height: 14),
              Expanded(child: MovesBrowser(show: show)),
            ],
          );
        },
      );
}

// ---------------------------------------------------------------- MILKDROP
class _MilkTab extends StatelessWidget {
  const _MilkTab({required this.show, required this.booth});
  final ShowEngine show;
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final milk = MilkFeed.shared;
    if (!milk.available) return Text('MilkDrop is not here (no helper beside the app).', style: TextStyle(color: Console.quiet));
    return ListenableBuilder(
      listenable: Listenable.merge([milk, milk.director]),
      builder: (context, _) {
        final d = milk.director;
        return ListView(
          children: [
            Text('MILKDROP\'S DIRECTOR', style: Console.label(10, color: Console.ink)),
            const SizedBox(height: 4),
            Text('Which preset is on, and when it changes — the record decides, not a clock: a hit or a drop cuts, a breakdown blends.', style: TextStyle(fontSize: 11, color: Console.quiet)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(milk.running ? (milk.presetName ?? 'MilkDrop…') : 'MilkDrop off', style: TextStyle(color: milk.running ? Console.ink : Console.quiet, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Pad(icon: Icons.chevron_left, width: 24, height: 24, colour: Console.quiet, tooltip: 'The preset before', onTap: d.previous),
              const SizedBox(width: 2),
              Pad(icon: Icons.chevron_right, width: 24, height: 24, colour: Console.quiet, tooltip: 'The next preset', onTap: d.next),
              const SizedBox(width: 2),
              Pad(icon: Icons.casino_outlined, width: 24, height: 24, colour: Console.quiet, tooltip: 'Another preset', onTap: () {
                if (!milk.running) unawaited(milk.start());
                d.random(byHand: true);
              }),
              const SizedBox(width: 2),
              Pad(icon: d.locked ? Icons.lock : Icons.lock_open, width: 24, height: 24, lit: d.locked, colour: Console.a, tooltip: d.locked ? 'Held' : 'Hold this preset', onTap: () => d.set(locked: !d.locked)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(width: 150, child: Text('a new preset every', style: TextStyle(fontSize: 12, color: Console.ink))),
              Expanded(
                child: Slider(
                  value: d.everyBars.toDouble().clamp(0, 64),
                  min: 0,
                  max: 64,
                  divisions: 16,
                  onChanged: (v) => d.set(everyBars: (v / 4).round() * 4),
                ),
              ),
              SizedBox(width: 70, child: Text(d.everyBars == 0 ? 'never by the clock' : '${d.everyBars} bars', style: TextStyle(fontSize: 11, color: Console.quiet))),
            ]),
            SwitchListTile(dense: true, title: const Text('cut on a drop, and on a hit', style: TextStyle(fontSize: 12)), value: d.cutOnDrop, onChanged: (v) => d.set(cutOnDrop: v)),
            SwitchListTile(dense: true, title: const Text('favourites only', style: TextStyle(fontSize: 12)), value: d.favouritesOnly, onChanged: (v) => d.set(favouritesOnly: v)),
            Row(children: [
              SizedBox(width: 150, child: Text('the least rating', style: TextStyle(fontSize: 12, color: Console.ink))),
              Expanded(child: Slider(value: d.minRating.clamp(0, 5), min: 0, max: 5, divisions: 5, onChanged: (v) => d.set(minRating: v))),
              SizedBox(width: 70, child: Text(d.minRating == 0 ? 'any' : '${d.minRating.round()} of 5', style: TextStyle(fontSize: 11, color: Console.quiet))),
            ]),
            const SizedBox(height: 8),
            Pad(label: 'BROWSE, FAVOURITE, MAKE PRESETS…', height: 28, colour: Console.ink, tooltip: 'The preset library and the maker', onTap: () => openMilkPage(context, booth)),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- PERF
class _PerfTab extends StatelessWidget {
  const _PerfTab({required this.show, required this.info, required this.booth});
  final ShowEngine show;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StageInfo>(
        valueListenable: info,
        builder: (context, i, _) => ValueListenableBuilder<List<String>>(
          valueListenable: ShowDebug.flips,
          builder: (context, flips, _) => ListView(
            children: [
              Text('THIS PICTURE', style: Console.label(10, color: Console.ink)),
              const SizedBox(height: 4),
              Text(
                [
                  'renderer: ${i.word}${i.parked ? ' (parked under the Flutter stage)' : ''}',
                  if (i.fps > 0) '${i.fps.toStringAsFixed(1)} fps${i.native ? ' · ${i.ms.toStringAsFixed(1)} ms a frame, worst ${i.worstMs.toStringAsFixed(1)}' : ''}',
                  if (i.width > 0) '${i.width}×${i.height}${i.native && i.workWidth > 0 ? ' → work ${i.workWidth}×${i.workHeight} (auto ×${i.autoScale.toStringAsFixed(2)})' : ''}',
                  if (i.native) i.float ? 'float targets' : '8-bit targets',
                  if (i.why.isNotEmpty) 'why not native: ${i.why}',
                ].join('\n'),
                style: Mag.typewriter(11, color: Console.ink),
              ),
              const SizedBox(height: 10),
              Text('CHANGES OF HANDS', style: Console.label(10, color: Console.ink)),
              const SizedBox(height: 4),
              Text(flips.isEmpty ? 'none yet' : flips.join('\n'), style: Mag.typewriter(11, color: Console.quiet)),
              const SizedBox(height: 10),
              ValueListenableBuilder<bool>(
                valueListenable: ShowDebug.on,
                builder: (context, on, _) => Row(children: [
                  Expanded(child: Text('Debug words over every stage (I on the stage page)', style: TextStyle(fontSize: 12, color: Console.ink))),
                  Switch(value: on, onChanged: (v) => unawaited(ShowDebug.set(v))),
                ]),
              ),
              const SizedBox(height: 6),
              Pad(label: 'THE PICTURE AGAINST THE SOUND…', height: 26, colour: Console.quiet, tooltip: 'The performer\'s offset for this screen', onTap: () => showTileOffsetDialog(context, booth)),
              const SizedBox(height: 10),
              Text('QUALITY', style: Console.label(10, color: Console.ink)),
              const SizedBox(height: 4),
              ListenableBuilder(
                listenable: show,
                builder: (context, _) => Wrap(children: [
                  for (final t in QualityPool.tiers)
                    _Word(
                      label: t.toUpperCase(),
                      lit: show.pool.tier == t,
                      tooltip: switch (t) {
                        'low' => 'A slow machine: the picture at 60 %, fewer birds, no big companies',
                        'mid' => 'The picture at 80 %, three quarters of the birds',
                        'high' => 'Everything, at full size',
                        _ => 'As the stage finds it can: full size, scaled down on its own when frames run late',
                      },
                      onTap: () => show.setPool(show.pool.copyWith(tier: t)),
                    ),
                ]),
              ),
              Text('The tier takes effect on the next frames; the stage still scales itself down when frames run late.', style: TextStyle(fontSize: 10, color: Console.faint)),
            ],
          ),
        ),
      );
}
