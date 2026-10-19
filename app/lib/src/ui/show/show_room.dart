// The show's own page of the booth: the room slid left of the decks (the board's
// twin on the other side), where the show is put together — the stage's picture
// big, the hands and the tabs under it, and down the right the rig as rows: the
// BACKGROUND, the SCENE over it (with its style and its treatment), how the two
// BLEND, and the FINISH over both. A chip is a choice,
// with a picture where there is one; the chip lit is what the stage shows now; a
// dimmed chip is one the director may not use. Each row says whose it is: DIRECTOR
// (the director's and the scene's) or YOURS (locked: the hands' until let go).
//
// Under the hands the tabs: EVERYTHING (every scene, style and background, each
// with its card), the RULES (characters, the twelve rules, the exceptions), the
// DANCERS (who, and every move), MILKDROP (the presets, the director and the maker),
// and the PERF numbers. Hold or right-click any chip for its card. Plan:
// ~/.claude/plans/wetowl-show-layers.md, §3.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_director.dart' show ShowDirector;
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

part 'show_room_rules.dart';

/// Bumped by the K key: the room slides to the show's page, or back.
final showRoomToggles = ValueNotifier<int>(0);

enum ShowTab { scenes, rules, dancers, milkdrop, perf }

/// A chip's picture: the look's thumbnail (`assets/show/thumbs/<id>.webp`), where there is one.
const _thumbs = {
  'blocks',
  'drift',
  'echo',
  'flash',
  'flock',
  'fluid',
  'fold',
  'glide',
  'kinetic',
  'siebenschlaefer',
  'turntable',
  'veins',
  'dance-art',
  'milk',
  'pulse-grid',
  'pulse-rays',
  'pulse-smoke',
  'pulse-stars',
  'lyrics',
};

String? thumbOf(String lookId) => _thumbs.contains(lookId) ? 'assets/show/thumbs/$lookId.webp' : null;

/// The families the scenes fall into, on the SCENE row and in the SCENES tab: what a
/// scene puts on the background — or nothing, the background alone.
enum _Family { bodies, shapes, flow, words, pictures, alone }

_Family _familyOf(Scene s) => switch (s.look.rig.figure.kind) {
      Figure.none => _Family.alone,
      Figure.dancers || Figure.birds || Figure.turntable => _Family.bodies,
      Figure.kinetic || Figure.blocks || Figure.flash || Figure.glide => _Family.shapes,
      Figure.fluid || Figure.veins || Figure.field => _Family.flow,
      Figure.words => _Family.words,
      Figure.meme || Figure.room => _Family.pictures,
    };

String _familyWord(_Family f) => switch (f) {
      _Family.bodies => 'BODIES',
      _Family.shapes => 'SHAPES',
      _Family.flow => 'FLOW',
      _Family.words => 'WORDS',
      _Family.pictures => 'PICTURES',
      _Family.alone => 'ALONE',
    };

String _groundWord(Ground g) => switch (g) {
      Ground.milk => 'MilkDrop',
      Ground.black => 'Black',
      Ground.wash => 'Wash',
      Ground.camera => 'Camera',
      Ground.field => 'Field',
      Ground.cover => 'Cover',
      Ground.pulse => 'Pulse',
    };

/// Each way the scene's backdrop can sit on the background, in a line.
const _modeWords = {
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
  GroundMode.keyhole:
      'the figure is a window onto the background, everything else black — the dancers and the lyrics cut it; shapes and birds have no figure to cut, so black',
};

/// What the page's parts ask of each other: a tab to open; a thing's card.
class _Links {
  const _Links({required this.tab, required this.card});
  final void Function(ShowTab) tab;
  final void Function(_Thing) card;
}

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
  late final _links = _Links(tab: _pickTab, card: _card);

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
      // Not MILKDROP on a fresh start: its panel starts the helper.
      if (t is String && t != ShowTab.milkdrop.name) _tab = ShowTab.values.asNameMap()[t] ?? _tab;
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

  void _card(_Thing t) {
    final kit = _kit;
    if (kit != null) unawaited(_openCard(context, show, kit.book, t));
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
          Expanded(child: _Tabs(tab: _tab, show: show, kit: kit, info: _info, booth: widget.booth, links: _links)),
        ],
      );
      // The rig down the right, the whole height: its rows are what is worked.
      final right = kit == null ? const SizedBox.shrink() : _RigStack(show: show, book: kit.book, booth: widget.booth, links: _links);
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
                  final sceneName = kit?.book[st.scene]?.name ?? st.scene ?? '—';
                  final style = ShowPool.lookupFigure(rig.figure).style;
                  final blendWord = rig.figure.kind == Figure.none
                      ? null
                      : '${rig.blend.ground == GroundMode.over ? 'plainly' : rig.blend.ground.name} ${rig.blend.auto ? 'by the rules' : '(yours)'}';
                  return Row(children: [
                    Text('NOW', style: Console.label(9, color: Console.a)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          '$sceneName${style != null ? ' · $style' : ''}',
                          'on ${_groundWord(rig.ground.kind)}${rig.ground.kind == Ground.field || rig.ground.kind == Ground.pulse ? ' ${rig.ground.field ?? ''}' : ''}',
                          if (blendWord != null) blendWord,
                          if (m.section != null) m.section!,
                          if (m.dropBeatsAway != null && m.dropBeatsAway! > 0) 'drop in ${m.dropBeatsAway!.ceil()}',
                          if (pending != null) '→ ${kit?.book[pending]?.name ?? pending} on the ${show.pendingAt?.name}',
                        ].join(' · '),
                        style: TextStyle(color: Console.ink, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (pending != null) ...[
                      Pad(
                          icon: Icons.close,
                          width: 22,
                          height: 22,
                          colour: Console.quiet,
                          tooltip: 'Do not land ${kit?.book[pending]?.name ?? pending}',
                          onTap: show.cancelLaunch),
                      const SizedBox(width: 6),
                    ],
                    Text('${i.word}${i.parked ? ' parked' : ''}${i.fps > 0 ? ' ${i.fps.round()} fps' : ''}',
                        style: TextStyle(color: Console.quiet, fontSize: 11)),
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
              child: _Flow(children: [
                Pad(icon: Icons.chevron_left, width: 30, height: 30, colour: Console.ink, tooltip: 'The scene before', onTap: show.previousScene),
                const SizedBox(width: 4),
                Pad(icon: Icons.chevron_right, width: 30, height: 30, colour: Console.ink, tooltip: 'The next scene', onTap: show.nextScene),
                const SizedBox(width: 8),
                Pad(
                  label: held ? 'HELD' : 'HOLD',
                  height: 30,
                  lit: held,
                  colour: Console.a,
                  tooltip: held
                      ? 'The scene is held — let the director choose again'
                      : 'Hold this scene: the director leaves it (the arrows still change it; with MilkDrop alone they step its presets)',
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
                  tooltip: 'Blackout (B on the stage page)',
                  onTap: () => show.setMacros(show.macros.copyWith(blackout: !show.macros.blackout)),
                ),
                const SizedBox(width: 4),
                _Held(
                  label: 'STROBE',
                  lit: m.strobe > 0,
                  tooltip: 'Strobe while held (S on the stage page)',
                  onDown: () => show.setMacros(show.macros.copyWith(strobe: 1)),
                  onUp: () => show.setMacros(show.macros.copyWith(strobe: 0)),
                ),
                const SizedBox(width: 4),
                Pad(
                  label: 'FREEZE',
                  height: 30,
                  lit: m.freeze,
                  colour: Console.ink,
                  tooltip: 'The picture held still (F on the stage page)',
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
                Tooltip(
                  message: 'When a scene you tap lands on the stage; a background, a blend or the finish changes at once',
                  child: Text('LAND ON', style: Console.label(9)),
                ),
                const SizedBox(width: 4),
                for (final q in Quantise.values) ...[
                  Pad(
                    label: switch (q) { Quantise.now => 'NOW', Quantise.beat => 'BEAT', Quantise.bar => 'BAR', Quantise.phrase => 'PHRASE' },
                    height: 26,
                    lit: show.pool.quantise == q,
                    colour: Console.quiet,
                    tooltip: 'A scene you pick lands ${switch (q) {
                      Quantise.now => 'at once',
                      Quantise.beat => 'on the next beat',
                      Quantise.bar => 'on the next bar',
                      Quantise.phrase => 'on the next phrase'
                    }}',
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

/// Pads that wrap onto a second line where the column is narrow (each takes its
/// own width, as in a row), rather than scrolling the last of them out of sight.
class _Flow extends StatelessWidget {
  const _Flow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 4,
        children: [for (final c in children) c is SizedBox ? c : IntrinsicWidth(child: c)],
      );
}

/// A line under a row for one axis of it: its word, then its choices.
class _Axis extends StatelessWidget {
  const _Axis({required this.word, required this.children});
  final String word;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 54, child: Text(word, style: Console.label(9))),
        Expanded(child: _Line(children: children)),
      ]);
}

// ------------------------------------------------------------------ the rig
class _RigStack extends StatelessWidget {
  const _RigStack({required this.show, required this.book, required this.booth, required this.links});
  final ShowEngine show;
  final SceneBook book;
  final Booth booth;
  final _Links links;

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
                      child: Text(
                          'four layers, bottom up — the lit chip is on the stage; a row marked DIRECTOR is the director\'s, YOURS stays as you set it; hold or right-click a chip for its card',
                          style: TextStyle(fontSize: 10, color: Console.faint),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _GroundRow(show: show, rig: rig, booth: booth, book: book, links: links),
                  const Divider(height: 16),
                  _SceneRow(show: show, book: book, rig: rig, links: links),
                  const Divider(height: 16),
                  _BlendRow(show: show, rig: rig, book: book, links: links),
                  const Divider(height: 16),
                  _FinishRow(show: show, rig: rig),
                ],
              );
            },
          ),
        ),
      );
}

/// A layer's row: its name and a word on it, its chips, whose it is (the lock, with
/// DIRECTOR or YOURS under it), and a line under for what the chip chosen has to say.
class _LayerRow extends StatelessWidget {
  const _LayerRow({
    required this.name,
    required this.word,
    required this.locked,
    required this.onLock,
    required this.lockTip,
    required this.child,
    this.below,
    this.why,
    this.heldWord = 'YOURS',
  });
  final String name, word, lockTip, heldWord;
  final bool locked;
  final void Function(bool) onLock;
  final Widget child;
  final Widget? below;

  /// Why the row is as it is now: whose it is, and since when.
  final String? why;

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
              SizedBox(
                width: 60,
                child: Column(children: [
                  Pad(
                    icon: locked ? Icons.lock : Icons.lock_open,
                    width: 30,
                    height: 26,
                    lit: locked,
                    colour: Console.a,
                    tooltip: lockTip,
                    onTap: () => onLock(!locked),
                  ),
                  const SizedBox(height: 2),
                  Text(locked ? heldWord : 'DIRECTOR',
                      maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: Console.label(6.5, color: locked ? Console.a : Console.faint)),
                ]),
              ),
            ],
          ),
          if (below != null) Padding(padding: const EdgeInsets.only(left: 110, top: 4, right: 66), child: below),
          if (why != null)
            Padding(
              padding: const EdgeInsets.only(left: 110, top: 3, right: 66),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'WHY  ', style: Console.label(8, color: Console.faint)),
                  TextSpan(text: why, style: TextStyle(fontSize: 10, color: Console.quiet)),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      );
}

/// A chip: one choice of a row — its picture (an asset, a painted colour, or a
/// widget), its name — lit when it is what the stage shows, dimmed when the director
/// may not use it, marked when it is about to land.
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
    this.picture,
    this.pictureSize = const Size(64, 36),
    this.onHold,
  });

  /// Held, or right-clicked: the thing's card.
  final VoidCallback? onHold;
  final String label;
  final bool lit, off, pending;
  final String? tooltip;
  final VoidCallback onTap;

  /// A picture for the chip (an asset), a painted colour, or a widget of its own.
  final String? thumb;
  final Color? swatch;
  final Widget? picture;
  final Size pictureSize;

  @override
  Widget build(BuildContext context) {
    final border = lit ? Console.a : (pending ? Console.b : Console.line);
    final fg = off ? Console.faint : Console.ink;
    final pictured = thumb != null || swatch != null || picture != null;
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
                width: pictureSize.width,
                height: pictureSize.height,
                child: picture ??
                    (thumb != null
                        ? Image.asset(thumb!,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (context, _, __) => ColoredBox(color: swatch ?? Console.ground))
                        : ColoredBox(color: swatch!)),
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
            onLongPress: onHold,
            onSecondaryTap: onHold,
            // Hover only: a hold is the card's.
            child: tooltip == null ? face : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), triggerMode: TooltipTriggerMode.manual, child: face),
          ),
        ),
      ),
    );
  }
}

/// A family of chips with its word over them.
class _Group extends StatelessWidget {
  const _Group({required this.word, required this.chips});
  final String word;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(left: 1, bottom: 2), child: Text(word, style: Console.label(7, color: Console.faint))),
          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: chips),
        ]),
      );
}

/// A plain word chip (no picture), for a mode or a style.
class _Word extends StatelessWidget {
  const _Word({required this.label, required this.lit, required this.onTap, this.off = false, this.tooltip, this.onHold});
  final String label;
  final bool lit, off;
  final String? tooltip;
  final VoidCallback onTap;

  /// Held, or right-clicked: the thing's card.
  final VoidCallback? onHold;

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
            onLongPress: onHold,
          ),
        ),
      );
}

/// A slider for how much of a background shows.
class _HowMuch extends StatelessWidget {
  const _HowMuch({required this.value, required this.onChanged});
  final double value;
  final void Function(double) onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 54, child: Text('how much', style: Console.label(9))),
        SizedBox(width: 160, child: Slider(value: value, onChanged: onChanged, padding: EdgeInsets.zero)),
        const SizedBox(width: 6),
        Text('${(value * 100).round()} %', style: Console.label(9)),
      ]);
}

// ---------------------------------------------------------------- BACKGROUND
class _GroundRow extends StatelessWidget {
  const _GroundRow({required this.show, required this.rig, required this.booth, required this.book, required this.links});
  final ShowEngine show;
  final ShowRig rig;
  final Booth booth;
  final SceneBook book;
  final _Links links;

  static const _fields = ['drift', 'glide', 'kinetic', 'blocks', 'flash'];

  @override
  Widget build(BuildContext context) {
    final g = rig.ground;
    final pool = show.pool;
    final panel = show.doc.panel;
    final fields = [
      for (final f in _fields)
        if (book.shaders.contains(f)) f
    ];
    // The field and the pulse are families: their chip is the one on, or the one last on.
    final field = g.kind == Ground.field ? (g.field ?? fields.firstOrNull ?? 'drift') : (panel['field'] as String? ?? fields.firstOrNull ?? 'drift');
    final pulse = g.kind == Ground.pulse ? (g.field ?? 'grid') : (panel['pulse'] as String? ?? 'grid');
    void pickField(String f) {
      show.setGround(RigGround(kind: Ground.field, field: f, dim: g.kind == Ground.field ? g.dim : 0.6));
      show.setDoc(show.doc.copyWith(panel: {...panel, 'field': f}));
    }

    void pickPulse(String v) {
      show.setGround(RigGround(kind: Ground.pulse, field: v));
      show.setDoc(show.doc.copyWith(panel: {...panel, 'pulse': v}));
    }

    final chips = <Widget>[
      _Chip(
        label: 'Black',
        lit: g.kind == Ground.black,
        off: !pool.isOn('ground.black'),
        tooltip: 'Nothing under the scene',
        swatch: const Color(0xff050505),
        onTap: () => show.setGround(RigGround.black),
        onHold: () => links.card(const _GroundThing(Ground.black)),
      ),
      _Chip(
        label: 'Wash',
        lit: g.kind == Ground.wash,
        off: !pool.isOn('ground.wash'),
        tooltip: 'A slow wash of the record\'s colours',
        swatch: const Color(0xff2a2238),
        onTap: () => show.setGround(const RigGround(kind: Ground.wash)),
        onHold: () => links.card(const _GroundThing(Ground.wash)),
      ),
      _Chip(
        label: 'MilkDrop',
        lit: g.kind == Ground.milk,
        off: !pool.isOn('ground.milk'),
        tooltip: 'MilkDrop\'s preset under the scene (the booth\'s way) — the presets are on the MILKDROP tab',
        thumb: 'assets/show/thumbs/milk.webp',
        swatch: const Color(0xff402060),
        onTap: () => show.setGround(RigGround.milk),
        onHold: () => links.card(const _GroundThing(Ground.milk)),
      ),
      _Chip(
        label: 'Camera',
        lit: g.kind == Ground.camera,
        off: !pool.isOn('ground.camera'),
        tooltip: 'The room\'s camera under the scene (started as needed)',
        swatch: const Color(0xff203028),
        onTap: () => show.setGround(const RigGround(kind: Ground.camera, dim: 0.8)),
        onHold: () => links.card(const _GroundThing(Ground.camera)),
      ),
      _Chip(
        label: 'Cover',
        lit: g.kind == Ground.cover,
        off: !pool.isOn('ground.cover'),
        tooltip: 'The record\'s cover under the scene',
        swatch: const Color(0xff303040),
        onTap: () => show.setGround(const RigGround(kind: Ground.cover, dim: 0.6)),
        onHold: () => links.card(const _GroundThing(Ground.cover)),
      ),
      if (fields.isNotEmpty)
        _Chip(
          label: 'Field · ${book[field]?.name ?? field}',
          lit: g.kind == Ground.field,
          off: !pool.isOn('ground.field'),
          tooltip: 'A shader as a quiet backdrop — which one, and how much, under',
          thumb: 'assets/show/thumbs/$field.webp',
          swatch: const Color(0xff101418),
          onTap: () => pickField(field),
          onHold: () => links.card(const _GroundThing(Ground.field)),
        ),
      _Chip(
        label: 'Pulse · $pulse',
        lit: g.kind == Ground.pulse,
        off: !pool.isOn('ground.pulse'),
        tooltip: 'A dark field moving with the record\'s bands — which one, under',
        thumb: 'assets/show/thumbs/pulse-$pulse.webp',
        swatch: const Color(0xff101418),
        onTap: () => pickPulse(pulse),
        onHold: () => links.card(const _GroundThing(Ground.pulse)),
      ),
    ];
    final milk = MilkFeed.shared;
    Widget? below;
    switch (g.kind) {
      case Ground.milk:
        if (milk.available) {
          below = ListenableBuilder(
            listenable: Listenable.merge([milk, milk.director]),
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
                Pad(
                    icon: Icons.casino_outlined,
                    width: 24,
                    height: 24,
                    colour: Console.quiet,
                    tooltip: 'Another preset',
                    onTap: () {
                      if (!milk.running) unawaited(milk.start());
                      d.random(byHand: true);
                    }),
                const SizedBox(width: 2),
                const MilkHoldPad(),
                const SizedBox(width: 8),
                Pad(
                    label: 'PRESETS ▸',
                    height: 24,
                    colour: Console.quiet,
                    tooltip: 'Every preset, the favourites, the director, the maker: the MILKDROP tab',
                    onTap: () => links.tab(ShowTab.milkdrop)),
              ]);
            },
          );
        }
      case Ground.field:
        below = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Axis(word: 'which', children: [
            for (final f in fields)
              _Word(
                  label: (book[f]?.name ?? f).toUpperCase(),
                  lit: g.field == f,
                  tooltip: 'The ${book[f]?.name ?? f} shader, quiet, under the scene',
                  onTap: () => pickField(f)),
          ]),
          _HowMuch(value: g.dim, onChanged: (v) => show.setGround(g.copyWith(dim: v))),
        ]);
      case Ground.pulse:
        below = _Axis(word: 'which', children: [
          for (final v in pulseVariants)
            _Word(
              label: v.toUpperCase(),
              lit: pulseVariant(g.field) == pulseVariant(v),
              tooltip: switch (v) {
                'grid' => 'a floor and a ceiling of thin lines',
                'rays' => 'soft rays turning with the bar',
                'smoke' => 'slow curls in two of the palette\'s hues',
                _ => 'a starfield drifting in'
              },
              onTap: () => pickPulse(v),
            ),
        ]);
      case Ground.camera:
      case Ground.cover:
        below = _HowMuch(value: g.dim, onChanged: (v) => show.setGround(g.copyWith(dim: v)));
      case Ground.black:
      case Ground.wash:
        below = null;
    }
    return _LayerRow(
      name: 'BACKGROUND',
      word: 'what lies under the scene',
      why: _groundWhy(show, book),
      locked: show.locked(RigSlot.ground),
      lockTip:
          show.locked(RigSlot.ground) ? 'The background is yours — let the scene and the director have it' : 'Keep this background whatever the director does',
      onLock: (v) => show.lock(RigSlot.ground, v),
      below: below,
      child: Wrap(children: chips),
    );
  }
}

// ---------------------------------------------------------------- SCENE
class _SceneRow extends StatelessWidget {
  const _SceneRow({required this.show, required this.book, required this.rig, required this.links});
  final ShowEngine show;
  final SceneBook book;
  final ShowRig rig;
  final _Links links;

  @override
  Widget build(BuildContext context) {
    final st = show.state;
    final pool = show.pool;
    final pending = show.pendingLook;
    final dancersOn = st.scene == 'dance-art';
    final scenes = book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    void launch(String id) => show.launch(id, at: pending == id ? Quantise.now : null);

    // The chips, by family.
    final chipsBy = <_Family, List<Widget>>{};
    for (final s in scenes) {
      final family = _familyOf(s);
      const wholeWords = 'MilkDrop alone, nothing on it: its own whole picture';
      chipsBy.putIfAbsent(family, () => []).add(_Chip(
            label: s.name,
            lit: s.id == st.scene,
            pending: s.id == pending,
            off: !pool.isOn('look.${s.id}'),
            thumb: thumbOf(s.id),
            swatch: Console.ground,
            tooltip: family == _Family.alone
                ? wholeWords
                : s.id == 'dance-art'
                    ? 'The dancers — their style under, a section at a time or held'
                    : '${s.name}${s.meta.needs.contains('camera') ? ' (needs the camera)' : ''}',
            onTap: () => launch(s.id),
            onHold: () => links.card(_SceneThing(s.id)),
          ));
    }
    // The style line: the dancers' style, the birds' look, the words' face.
    Widget? below;
    if (dancersOn) {
      below = _Axis(word: 'style', children: [
        _Word(
          label: 'AUTO',
          lit: show.style == null || show.styleFor != Figure.dancers,
          tooltip: 'The dancers\' own clock picks a style a section at a time, from the ones switched on (RULES)',
          onTap: () => show.setStyle(null),
        ),
        // The image treatments are on the treatment line, for every scene.
        for (final a in DanceArt.values)
          if (!treatmentFxMode.containsKey(a.name) && (a != DanceArt.contour || pool.styleOn(Figure.dancers, 'contour')))
            _Word(
              label: a.name.toUpperCase(),
              lit: show.style == a.name && show.styleFor == Figure.dancers,
              off: !pool.styleOn(Figure.dancers, a.name),
              tooltip: _artWords[a],
              onTap: () => show.setStyle(a.name, forKind: Figure.dancers),
              onHold: () => links.card(_StyleThing(Figure.dancers, a.name)),
            ),
      ]);
    } else if (st.scene == 'flock') {
      below = _Axis(word: 'look', children: [
        _Word(
            label: 'AUTO',
            lit: show.style == null || show.styleFor != Figure.birds,
            tooltip: 'The flock\'s own clock picks a look a section at a time',
            onTap: () => show.setStyle(null)),
        for (final l in FlockLook.values)
          if (!treatmentFxMode.containsKey(l.name))
          _Word(
            label: l.name.toUpperCase(),
            lit: show.style == l.name && show.styleFor == Figure.birds,
            off: !pool.styleOn(Figure.birds, l.name),
            onTap: () => show.setStyle(l.name, forKind: Figure.birds),
            onHold: () => links.card(_StyleThing(Figure.birds, l.name)),
          ),
      ]);
    } else if (st.scene == 'lyrics') {
      below = Row(children: [
        SizedBox(width: 70, child: Text('style', style: Console.label(9))),
        Expanded(
          child: _Line(children: [
            _Word(
                label: 'AUTO',
                lit: show.style == null || show.styleFor != Figure.words,
                tooltip: 'The words\' own clock picks a face a section at a time: calm ones in the quiet, bold ones in the heat',
                onTap: () => show.setStyle(null)),
            for (final s in WordsStyle.values)
              _Word(
                label: s.name.toUpperCase(),
                lit: show.style == s.name && show.styleFor == Figure.words,
                tooltip: wordsStyleWords[s],
                onTap: () => show.setStyle(s.name, forKind: Figure.words),
                onHold: () => links.card(_StyleThing(Figure.words, s.name)),
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
    final styleNow = ShowPool.lookupFigure(rig.figure).style;
    final styleWhy = styleNow == null
        ? ''
        : show.style == styleNow && show.styleFor == rig.figure.kind
            ? ' Style $styleNow: yours, held.'
            : ' Style $styleNow: its clock\'s, for this section.';
    final pendingWhy = show.pendingLook == null ? '' : ' Next: ${book[show.pendingLook]?.name ?? show.pendingLook}, on the ${show.pendingAt?.name}.';
    return _LayerRow(
      why: '${_sceneWhy(show)}$styleWhy$pendingWhy',
      name: 'SCENE',
      word: 'what stands on it — a tap lands it as LAND ON says',
      locked: show.sceneHeld,
      heldWord: 'HELD',
      lockTip: show.sceneHeld ? 'The scene is held — let the director choose again' : 'Hold this scene: the director leaves it',
      onLock: (v) => show.holdScene(v),
      below: below,
      child: Wrap(
        children: [
          for (final f in _Family.values)
            if (chipsBy[f] case final chips?) _Group(word: _familyWord(f), chips: chips),
        ],
      ),
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
    DanceArt.disco: 'an LED floor that plays the record: lit where they step, rings on the kick, sparks on the snare',
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
/// A little picture of a blend: a preset-like wash as the background, a scene's
/// backdrop (dark, with a bright band) and a figure (a white disc) on it, put
/// together the way the mode says.
class _BlendSwatch extends StatelessWidget {
  const _BlendSwatch(this.mode, {this.width = 54, this.height = 30});
  final GroundMode mode;
  final double width, height;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(width, height), painter: _BlendPainter(mode));
}

class _BlendPainter extends CustomPainter {
  const _BlendPainter(this.mode);
  final GroundMode mode;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final w = size.width, h = size.height;
    final band = Path()
      ..moveTo(w * 0.28, h)
      ..lineTo(w * 0.52, 0)
      ..lineTo(w * 0.7, 0)
      ..lineTo(w * 0.46, h)
      ..close();
    void ground({BlendMode blend = BlendMode.srcOver, double alpha = 1, Path? within}) {
      canvas.save();
      if (within != null) canvas.clipPath(within);
      canvas.drawRect(
        r,
        Paint()
          ..blendMode = blend
          ..shader = ui.Gradient.linear(r.topLeft, r.bottomRight, [
            const Color(0xff6a2fb8).withValues(alpha: alpha),
            const Color(0xffe8b23a).withValues(alpha: alpha),
          ]),
      );
      canvas.restore();
    }

    void paper({BlendMode blend = BlendMode.srcOver, double alpha = 1, Rect? within}) {
      canvas.save();
      if (within != null) canvas.clipRect(within);
      canvas.drawRect(
          r,
          Paint()
            ..blendMode = blend
            ..color = const Color(0xff23272e).withValues(alpha: alpha));
      canvas.drawPath(
          band,
          Paint()
            ..blendMode = blend
            ..color = const Color(0xff9aa1ab).withValues(alpha: alpha));
      canvas.restore();
    }

    final disc = Offset(w * 0.78, h * 0.5);
    void figure() => canvas.drawCircle(disc, h * 0.24, Paint()..color = Colors.white);
    final whole = Path()..addRect(r);
    switch (mode) {
      case GroundMode.keyhole:
        canvas.drawRect(r, Paint()..color = Colors.black);
        ground(within: Path()..addOval(Rect.fromCircle(center: disc, radius: h * 0.3)));
        ground(within: Path()..addOval(Rect.fromCircle(center: Offset(w * 0.3, h * 0.55), radius: h * 0.22)));
        return;
      case GroundMode.through:
        ground();
      case GroundMode.over:
        paper();
      case GroundMode.add:
        ground();
        paper(blend: BlendMode.plus);
      case GroundMode.screen:
        ground();
        paper(blend: BlendMode.screen);
      case GroundMode.dim:
        canvas.drawRect(r, Paint()..color = Colors.black);
        ground(alpha: 0.38);
        paper(alpha: 0.7);
      case GroundMode.window:
        paper();
        ground(within: band);
      case GroundMode.mask:
        paper();
        ground(within: Path.combine(PathOperation.difference, whole, band));
      case GroundMode.frame:
        ground();
        paper(within: r.deflate(h * 0.2));
      case GroundMode.bands:
        ground();
        for (var i = 0; i < 6; i += 2) {
          paper(within: Rect.fromLTWH(w * i / 6, 0, w / 6, h));
        }
      case GroundMode.flip:
        paper(within: Rect.fromLTWH(0, 0, w * 0.5, h));
        ground(within: Path()..addRect(Rect.fromLTWH(w * 0.5, 0, w * 0.5, h)));
      case GroundMode.outline:
        paper();
        final line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xffe8b23a);
        canvas.drawPath(
            Path()
              ..moveTo(0, h * 0.75)
              ..quadraticBezierTo(w * 0.3, h * 0.1, w * 0.6, h * 0.55)
              ..quadraticBezierTo(w * 0.8, h * 0.85, w, h * 0.3),
            line);
        canvas.drawPath(
            Path()
              ..moveTo(0, h * 0.3)
              ..quadraticBezierTo(w * 0.25, h * 0.9, w * 0.5, h * 0.2),
            line..color = const Color(0xff9d6fe0));
      case GroundMode.contrast:
        ground();
        paper(blend: BlendMode.difference);
    }
    figure();
  }

  @override
  bool shouldRepaint(_BlendPainter old) => old.mode != mode;
}

class _BlendRow extends StatelessWidget {
  const _BlendRow({required this.show, required this.rig, required this.book, required this.links});
  final ShowEngine show;
  final ShowRig rig;
  final SceneBook book;
  final _Links links;

  @override
  Widget build(BuildContext context) {
    final b = rig.blend;
    final locked = show.locked(RigSlot.blend);
    final figuresOver = b.figure == FigureMode.over;
    final pool = show.pool;
    final figure = ShowPool.lookupFigure(rig.figure);
    final ground = rig.ground.kind;
    final alone = figure.kind == Figure.none;
    // What the rules answer for this pair, and where the answer came from.
    final ruled = alone ? rig.blend : pool.blendFor(figure, ground, from: rig.blend);
    final answer = alone ? null : pool.answer(figure, ground);
    final thing = alone ? null : (figure.style != null ? _StyleThing(figure.kind, figure.style!) : (show.state.scene != null ? _SceneThing(show.state.scene!) : null));
    final sceneName = book[show.state.scene]?.name ?? figure.kind.name;
    final pairWords = '$sceneName${figure.style != null ? ' · ${figure.style}' : ''} on ${_groundWord(ground)}';
    final String caption;
    if (alone) {
      caption = 'MilkDrop alone: its own whole picture, nothing to blend';
    } else if (b.auto) {
      caption = 'WHY  $pairWords: ${_answerWords(answer!)}';
    } else {
      caption = 'WHY  yours — ${b.ground.name}: ${_modeWords[b.ground]}';
    }
    return _LayerRow(
      name: 'BLEND',
      word: 'how the scene sits on the background — a way or the strength chosen keeps it yours',
      locked: locked,
      lockTip: locked ? 'The blend is yours — let the rules decide again' : 'Keep this blend whatever the scene',
      onLock: (v) => show.lock(RigSlot.blend, v),
      below: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(caption, style: TextStyle(fontSize: 10, color: b.auto ? Console.quiet : Console.a), maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (thing != null) ...[
            const SizedBox(width: 6),
            Pad(
              label: b.auto ? 'ITS CARD' : 'BACK TO THE RULES',
              height: 22,
              colour: Console.quiet,
              tooltip: b.auto ? 'What $sceneName${figure.style != null ? ' · ${figure.style}' : ''} goes with, and why' : 'Let the rules decide this blend again',
              onTap: () => b.auto ? links.card(thing) : show.lock(RigSlot.blend, false),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        _Line(children: [
          Text('the bodies & shapes', style: Console.label(9)),
          const SizedBox(width: 6),
          _Word(
            label: 'ON TOP',
            lit: figuresOver && !b.auto,
            tooltip: 'The bodies, the glyphs, the shapes go over the background as drawn; only the scene\'s backdrop is blended',
            onTap: () => show.setBlend(b.copyWith(figure: FigureMode.over)),
          ),
          _Word(
            label: 'BLENDED TOO',
            lit: !figuresOver && !b.auto,
            tooltip: 'The figures are blended like the scene\'s backdrop',
            onTap: () => show.setBlend(b.copyWith(figure: FigureMode.same)),
          ),
          _Word(
            label: 'AS THE SCENE ASKS',
            lit: b.auto,
            tooltip: 'The plain dancers on top; the rest blended (the rules\' way)',
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
        _Chip(
          label: 'BY THE RULES',
          lit: b.auto,
          tooltip: 'The RULES tab decides for each scene on each background — ${ruled.ground.name} here',
          picture: _BlendSwatch(ruled.ground),
          pictureSize: const Size(54, 30),
          onTap: () => show.lock(RigSlot.blend, false),
        ),
        for (final m in GroundMode.values)
          _Chip(
            label: m.name.toUpperCase(),
            lit: b.ground == m && !b.auto,
            tooltip: _modeWords[m],
            picture: _BlendSwatch(m),
            pictureSize: const Size(54, 30),
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
          child: Knob(
              value: v,
              min: 0,
              max: max,
              rest: 0,
              bipolar: false,
              size: 30,
              label: label,
              tooltip: '$tip: ${(v / max * 100).round()} %',
              onChanged: (x) => show.setFinish(set(x))),
        );
    return _LayerRow(
      name: 'FINISH',
      word: 'over everything — a knob turned keeps the whole finish yours',
      why: locked ? 'Yours: the scenes\' own finishes wait until you let it go.' : 'The scene\'s own finish (its trails, its bloom, its grain); a knob turned makes it yours.',
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
          label: 'TITLE & LYRICS',
          lit: f.title || f.lyrics,
          tooltip: 'The record\'s title and the line being sung, over the stage',
          onTap: () => show.setFinish(f.copyWith(title: !(f.title || f.lyrics), lyrics: !(f.title || f.lyrics))),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ the tabs
class _Tabs extends StatelessWidget {
  const _Tabs(
      {required this.tab, required this.show, required this.kit, required this.info, required this.booth, required this.links});
  final ShowTab tab;
  final ShowEngine show;
  final StageKit? kit;
  final ValueNotifier<StageInfo> info;
  final Booth booth;
  final _Links links;

  static const _tips = {
    ShowTab.scenes: 'Every scene, and which the director may pick',
    ShowTab.rules: 'What goes on what, and how it blends',
    ShowTab.dancers: 'Who dances, and every move',
    ShowTab.milkdrop: 'The presets, their director, the maker',
    ShowTab.perf: 'The stage\'s numbers and quality',
  };

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
                    label: t == ShowTab.scenes ? 'EVERYTHING' : t.name.toUpperCase(),
                    height: 26,
                    lit: t == tab,
                    colour: Console.ink,
                    tooltip: _tips[t],
                    onTap: () => links.tab(t),
                  ),
                  const SizedBox(width: 4),
                ],
                const SizedBox(width: 8),
                Pad(
                    icon: Icons.fullscreen,
                    width: 26,
                    height: 26,
                    colour: Console.quiet,
                    tooltip: 'The stage over this window (⇧V)',
                    onTap: kit == null ? null : () => openStagePage(context, booth)),
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
                    ShowTab.scenes => _EverythingTab(show: show, kit: kit, links: links) as Widget,
                    ShowTab.rules => _RulesTab(show: show, kit: kit, links: links),
                    ShowTab.dancers => _DancersTab(show: show),
                    ShowTab.milkdrop => MilkPanel(booth: booth),
                    ShowTab.perf => _PerfTab(show: show, info: info, booth: booth),
                  };
                  final least = tab == ShowTab.dancers || tab == ShowTab.milkdrop ? 560.0 : 300.0;
                  if (c.maxHeight >= least) return body;
                  return SingleChildScrollView(child: SizedBox(height: least, child: body));
                }),
              ),
            ],
          ),
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.colour, required this.border, required this.word, this.faint = false});
  final Color colour, border;
  final String word;
  final bool faint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 12, height: 10, decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(2), border: Border.all(color: border))),
          const SizedBox(width: 4),
          Text(word, style: TextStyle(fontSize: 9, color: faint ? Console.faint : Console.quiet)),
        ]),
      );
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
                _Word(
                    label: 'A MIX',
                    lit: lead == null,
                    tooltip: 'Each record its own lead, the others in the troupe',
                    onTap: () => show.setPool(pool.copyWith(clearDancer: true))),
                const SizedBox(width: 6),
                for (final (id, name) in DanceModels.all) ...[
                  _Word(
                      label: name.toUpperCase(),
                      lit: lead == id,
                      off: !pool.isOn('dancer.$id'),
                      tooltip: 'Only $name dances',
                      onTap: () => show.setPool(pool.withOff('dancer.$id', false).copyWith(dancer: id))),
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
              Text('THIS PAGE\'S PICTURE', style: Console.label(10, color: Console.ink)),
              const SizedBox(height: 4),
              Text(
                [
                  'renderer: ${i.word}${i.parked ? ' (parked under the Flutter stage)' : ''}',
                  if (i.fps > 0)
                    '${i.fps.toStringAsFixed(1)} fps${i.native ? ' · ${i.ms.toStringAsFixed(1)} ms a frame, worst ${i.worstMs.toStringAsFixed(1)}' : ''}',
                  if (i.width > 0)
                    '${i.width}×${i.height}${i.native && i.workWidth > 0 ? ' → work ${i.workWidth}×${i.workHeight} (auto ×${i.autoScale.toStringAsFixed(2)})' : ''}',
                  if (i.native) i.float ? 'float targets' : '8-bit targets',
                  if (i.why.isNotEmpty) 'why not native: ${i.why}',
                ].join('\n'),
                style: Mag.typewriter(11, color: Console.ink),
              ),
              const SizedBox(height: 10),
              Text('STAGE LOG', style: Console.label(10, color: Console.ink)),
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
              Pad(
                  label: 'THE PICTURE AGAINST THE SOUND…',
                  height: 26,
                  colour: Console.quiet,
                  tooltip: 'The performer\'s offset for this screen',
                  onTap: () => showTileOffsetDialog(context, booth)),
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
                        _ => 'As the stage finds it can: full size (the native stage scales itself down when frames run late)',
                      },
                      onTap: () => show.setPool(show.pool.copyWith(tier: t)),
                    ),
                ]),
              ),
              Text('The tier takes effect on the next frames; the stage still scales itself down when frames run late.',
                  style: TextStyle(fontSize: 10, color: Console.faint)),
            ],
          ),
        ),
      );
}
