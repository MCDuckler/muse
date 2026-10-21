// The show's own page of the booth: the room slid left of the decks (the board's
// twin on the other side). Made to be used, not studied:
//
//   the picture, and under it four big buttons — NEXT, KEEP (what is on stays),
//   NOT TOGETHER (this scene or style never on this background again), OTHER BLEND
//   (the next way of putting the two together; the one left on is kept for the
//   pair) — and the pads to play the light with (hit, black, strobe, freeze);
//
//   down the right what there is to pick, as pictures: the scenes, the backgrounds,
//   the style of the scene on — a tap puts it on, a hold says how often the show
//   takes it by itself (often, normal, rarely, never);
//
//   under the pads the tabs: the RULES at a glance (every scene and style against
//   every background, ✓ together or ✕ never, a tap to switch, your changes listed
//   and undone in one place), the DANCERS, MILKDROP's presets, and SETTINGS (the
//   finish, the director, the quality, the stage's numbers).
//
// What decides the rest stays out of sight: the scenes' and backgrounds' characters
// and the rules between them (state/show/show_characters.dart) are the defaults the
// director keeps to. Plan: ~/.claude/plans/wetowl-show-layers.md, §3.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/show/camera_feed.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_engine.dart';
import '../../state/show/show_pool.dart';
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart' show ShowPalette;
import '../../state/show/show_tune.dart';
import '../booth/desk/console.dart';
import '../feel.dart';
import '../mag.dart';
import '../snack.dart';
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

part 'show_room_grid.dart';
part 'show_room_switches.dart';

/// Bumped by the K key: the room slides to the show's page, or back.
final showRoomToggles = ValueNotifier<int>(0);

enum ShowTab { rules, switches, dancers, milkdrop, settings }

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

String _groundWord(Ground g) => switch (g) {
      Ground.milk => 'MilkDrop',
      Ground.black => 'Black',
      Ground.wash => 'Wash',
      Ground.camera => 'Camera',
      Ground.field => 'Field',
      Ground.cover => 'Cover',
      Ground.pulse => 'Pulse',
    };

/// The styles a figure's clock picks from, by name: the dancers' renderings, the
/// flock's looks, the words' faces.
List<String> _stylesOf(Figure f) => switch (f) {
      Figure.dancers => [for (final a in DanceArt.values) a.name],
      Figure.birds => [for (final l in FlockLook.values) l.name],
      Figure.words => [for (final w in WordsStyle.values) w.name],
      _ => const [],
    };

/// A pair key in words: `Dancer · mono on MilkDrop`.
String _keyWords(String key, SceneBook book) {
  final parts = key.split('|');
  final fig = parts[0].split('.');
  final kind = Figure.values.where((f) => f.name == (fig.length > 1 ? fig[1] : '')).firstOrNull;
  final name = kind == null ? (fig.length > 1 ? fig[1] : '?') : _figureName(kind, book);
  final sub = fig.length > 3 ? fig[3] : null;
  final g = Ground.values.where((x) => x.name == (parts.length > 1 ? parts[1].split('.').last : '')).firstOrNull;
  return '$name${sub != null ? ' · $sub' : ''} on ${g == null ? '?' : _groundWord(g)}';
}

/// A figure's name, as its scene is called.
String _figureName(Figure k, SceneBook book) {
  if (k == Figure.room) return 'Echo · Fold';
  return book.scenes.values.where((s) => s.look.rig.figure.kind == k).firstOrNull?.name ?? k.name;
}

/// The menu on a thing held: how often the show takes it by itself.
Future<void> _oftenMenu(BuildContext context, ShowEngine show, String key, String name) async {
  final box = context.findRenderObject() as RenderBox;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final at = RelativeRect.fromRect(
    Rect.fromPoints(box.localToGlobal(Offset.zero, ancestor: overlay), box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay)),
    Offset.zero & overlay.size,
  );
  final now = show.pool.oftenOf(key);
  final picked = await showMenu<Often>(
    context: context,
    position: at,
    color: Console.panel,
    items: [
      PopupMenuItem<Often>(
          enabled: false,
          height: 28,
          child: Text('$name — how often by itself', style: TextStyle(fontSize: 12, color: Console.ink, fontWeight: FontWeight.w700))),
      for (final o in [Often.often, Often.normal, Often.rarely, Often.never])
        PopupMenuItem<Often>(
          value: o,
          height: 34,
          child: Row(children: [
            Icon(o == now ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 16, color: o == now ? Console.a : Console.quiet),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                  switch (o) {
                    Often.often => 'More often',
                    Often.normal => 'Normal',
                    Often.rarely => 'Less often',
                    Often.never => 'Off everywhere (ON/OFF has it)'
                  },
                  style: TextStyle(fontSize: 12, color: o == now ? Console.a : Console.ink)),
            ),
          ]),
        ),
    ],
  );
  if (picked != null) {
    feel(Feel.pick);
    show.setPool(show.pool.withOften(key, picked));
  }
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
  ShowTab _tab = ShowTab.rules;
  final _info = ValueNotifier<StageInfo>(StageInfo.none);

  ShowEngine get show => widget.booth.show;

  /// The lines between the page's parts, dragged like the crate's edge and kept in
  /// show.json: the picture's side's share of the width (or, narrow, of the height),
  /// and how tall the picture is, as shares of the screen.
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
          _Controls(show: show, kit: kit),
          const SizedBox(height: 8),
          Expanded(child: _Tabs(tab: _tab, onPick: _pickTab, show: show, kit: kit, info: _info, booth: widget.booth)),
        ],
      );
      // What there is to pick, down the right.
      final right = kit == null ? const SizedBox.shrink() : _Pick(show: show, book: kit.book);
      if (narrow) {
        final room = math.max(1.0, c.maxHeight - _Seam.reach);
        return Column(children: [
          SizedBox(height: room * _splitNarrow, child: left),
          _Seam(
            vertical: true,
            tip: 'Drag: more of the picture, or more to pick from',
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
            tip: 'Drag: more of the picture, or more to pick from',
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

// ------------------------------------------------------------------ the four buttons
/// What is on as a pair the rules know: the figure (with the style it wears now) and
/// the background; none for a scene that is its own picture, or on black.
(RigFigure, Ground)? _pairOn(ShowEngine show) {
  final rig = show.state.rig;
  final f = ShowPool.lookupFigure(rig.figure);
  if (f.kind == Figure.none || rig.ground.kind == Ground.black) return null;
  return (f, rig.ground.kind);
}

/// The pair on in words: `Dancer · plain on MilkDrop`.
String _pairWords(ShowEngine show, StageKit? kit) {
  final st = show.state;
  final f = ShowPool.lookupFigure(st.rig.figure);
  final name = kit?.book[st.scene]?.name ?? st.scene ?? '—';
  return '$name${f.style != null ? ' · ${f.style}' : ''} on ${_groundWord(st.rig.ground.kind)}';
}

/// NEXT, KEEP, NOT TOGETHER, OTHER BLEND — and under them the pads.
class _Controls extends StatelessWidget {
  const _Controls({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  bool get _kept => show.sceneHeld && show.locked(RigSlot.ground);

  void _keep() {
    if (_kept) {
      show.holdScene(false);
      show.lock(RigSlot.ground, false);
      show.setStyle(null);
      return;
    }
    final f = ShowPool.lookupFigure(show.state.rig.figure);
    show.holdScene(true);
    show.lock(RigSlot.ground, true);
    if (f.style != null) show.setStyle(f.style, forKind: f.kind);
  }

  void _notTogether(BuildContext context) {
    final pair = _pairOn(show);
    if (pair == null) return;
    final (f, g) = pair;
    final words = _pairWords(show, kit);
    final before = show.pool;
    show.setPool(before.withTogether(f, g, false));
    // A background kept by hand goes with it: the scene plays on another.
    if (show.locked(RigSlot.ground)) show.lock(RigSlot.ground, false);
    ScaffoldMessenger.of(context).say(snack(
      Text('$words: never again — it plays on another background now'),
      action: SnackBarAction(label: 'UNDO', onPressed: () => show.setPool(before)),
    ));
  }

  void _otherBlend() {
    final pair = _pairOn(show);
    if (pair == null) return;
    final (f, g) = pair;
    final ways = show.pool.blendsFor(f, g);
    final now = show.state.rig.blend.ground;
    final next = ways[(ways.indexOf(now) + 1) % ways.length];
    if (show.locked(RigSlot.blend)) show.lock(RigSlot.blend, false);
    show.setPool(show.pool.withBlend(f, g, next));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final pair = _pairOn(show);
          final blend = show.state.rig.blend.ground;
          final yours = pair != null && show.pool.combos[ShowPool.comboKey(pair.$1, pair.$2)]?.ground != null;
          return BoothPanel(
            child: Plate(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  _Big(icon: Icons.skip_next, label: 'NEXT', tip: 'Another scene now (with MilkDrop alone: another preset)', onTap: show.nextScene),
                  _Big(
                    icon: _kept ? Icons.lock : Icons.lock_open,
                    label: _kept ? 'KEPT' : 'KEEP',
                    lit: _kept,
                    tip: _kept ? 'Let the show change again' : 'Keep what is on — the scene, its style, the background — until you let go',
                    onTap: _keep,
                  ),
                  _Big(
                    icon: Icons.thumb_down_alt_outlined,
                    label: 'NOT TOGETHER',
                    tip: pair == null
                        ? 'Nothing to part: the scene is on black, or is its own picture'
                        : '${_pairWords(show, kit)}: never again (undo in RULES)',
                    onTap: pair == null ? null : () => _notTogether(context),
                  ),
                  _Big(
                    icon: Icons.palette_outlined,
                    label: 'OTHER BLEND',
                    sub: pair == null ? null : '${blend == GroundMode.over ? 'as drawn' : blend.name}${yours ? ' · yours' : ''}',
                    swatch: pair == null ? null : blend,
                    tip: pair == null ? 'Nothing to blend' : 'Put the two together another way; the one you leave on is kept for this pair',
                    onTap: pair == null ? null : _otherBlend,
                  ),
                ]),
                const SizedBox(height: 8),
                _Pads(show: show),
              ]),
            ),
          );
        },
      );
}

/// A big button: an icon, a word, and a word under it.
class _Big extends StatelessWidget {
  const _Big({required this.icon, required this.label, required this.tip, required this.onTap, this.lit = false, this.sub, this.swatch});
  final IconData icon;
  final String label, tip;
  final String? sub;
  final GroundMode? swatch;
  final bool lit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final fg = !on ? Console.faint : (lit ? Console.a : Console.ink);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 500),
          child: Material(
            color: lit ? Console.a.withValues(alpha: 0.16) : Console.raised,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: lit ? Console.a : Console.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: !on
                  ? null
                  : () {
                      feel(Feel.commit);
                      onTap!();
                    },
              child: SizedBox(
                height: 52,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (swatch != null)
                    Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(borderRadius: BorderRadius.circular(3), child: _BlendSwatch(swatch!, width: 36, height: 22)))
                  else
                    Padding(padding: const EdgeInsets.only(right: 8), child: Icon(icon, size: 20, color: fg)),
                  Flexible(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: Console.label(10, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (sub != null) Text(sub!, style: TextStyle(fontSize: 10, color: Console.quiet), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pads to play the light with: hit, black, strobe (held), freeze, the level and
/// the hue; and when a scene you tap lands.
class _Pads extends StatelessWidget {
  const _Pads({required this.show});
  final ShowEngine show;

  @override
  Widget build(BuildContext context) {
    final m = show.macros;
    return _Flow(children: [
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
      Tooltip(message: 'When a scene you tap lands on the stage', child: Text('LAND ON', style: Console.label(9))),
      const SizedBox(width: 4),
      for (final q in Quantise.values) ...[
        Pad(
          label: switch (q) { Quantise.now => 'NOW', Quantise.beat => 'BEAT', Quantise.bar => 'BAR', Quantise.phrase => 'PHRASE' },
          height: 26,
          lit: show.pool.quantise == q,
          colour: Console.quiet,
          tooltip: 'A scene you tap lands ${switch (q) {
            Quantise.now => 'at once',
            Quantise.beat => 'on the next beat',
            Quantise.bar => 'on the next bar',
            Quantise.phrase => 'on the next phrase'
          }}',
          onTap: () => show.setPool(show.pool.copyWith(quantise: q)),
        ),
        const SizedBox(width: 2),
      ],
    ]);
  }
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

/// A chip: one choice of a row — its picture (an asset or a painted colour), its name — lit when it is what the stage shows, dimmed when the director
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
    this.onHold,
  });

  /// Held, or right-clicked: the thing's card.
  final VoidCallback? onHold;
  final String label;
  final bool lit, off, pending;
  final String? tooltip;
  final VoidCallback onTap;

  /// A picture for the chip (an asset) or a painted colour.
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
                    ? Image.asset(thumb!,
                        fit: BoxFit.cover, filterQuality: FilterQuality.medium, errorBuilder: (context, _, __) => ColoredBox(color: swatch ?? Console.ground))
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
            onLongPress: onHold,
            onSecondaryTap: onHold,
            // Hover only: a hold is the card's.
            child: tooltip == null
                ? face
                : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), triggerMode: TooltipTriggerMode.manual, child: face),
          ),
        ),
      ),
    );
  }
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

// ------------------------------------------------------------------ what to pick
/// A strip's heading: its word, a hint, and something at its end.
class _Head extends StatelessWidget {
  const _Head(this.word, {this.hint, this.trailing});
  final String word;
  final String? hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 5),
        child: Row(children: [
          Text(word, style: Console.label(10, color: Console.ink)),
          const SizedBox(width: 8),
          Expanded(child: Text(hint ?? '', style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (trailing != null) trailing!,
        ]),
      );
}

String _oftenMark(Often o) => switch (o) { Often.often => ' ↑', Often.rarely => ' ↓', _ => '' };

/// The scenes, the backgrounds and the style of the scene on, as pictures: a tap
/// puts one on, a hold says how often the show takes it by itself.
class _Pick extends StatelessWidget {
  const _Pick({required this.show, required this.book});
  final ShowEngine show;
  final SceneBook book;

  static final _grounds = <(Ground, RigGround)>[
    (Ground.black, RigGround.black),
    (Ground.wash, const RigGround(kind: Ground.wash)),
    (Ground.milk, RigGround.milk),
    (Ground.camera, const RigGround(kind: Ground.camera, dim: 0.8)),
    (Ground.cover, const RigGround(kind: Ground.cover, dim: 0.6)),
    (Ground.field, const RigGround(kind: Ground.field, field: 'drift', dim: 0.6)),
    (Ground.pulse, const RigGround(kind: Ground.pulse, field: 'grid')),
  ];

  @override
  Widget build(BuildContext context) => BoothPanel(
        child: Plate(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
          child: ListenableBuilder(
            listenable: show,
            builder: (context, _) {
              final st = show.state;
              final rig = st.rig;
              final pool = show.pool;
              final scenes = book.scenes.values.toList()
                ..sort((a, b) {
                  final f = _familyOf(a).index.compareTo(_familyOf(b).index);
                  return f != 0 ? f : a.name.compareTo(b.name);
                });
              final pinned = show.locked(RigSlot.ground);
              final kind = book[st.scene]?.look.rig.figure.kind ?? Figure.none;
              return ListView(children: [
                _Head('SCENE', hint: 'tap: on · hold: how often (↑ more, ↓ less)'),
                Wrap(children: [
                  for (final s in scenes)
                    if (pool.isOn('look.${s.id}') || s.id == st.scene)
                      Builder(builder: (context) {
                        final o = pool.oftenOf('look.${s.id}');
                        return _Chip(
                          label: '${s.name}${_oftenMark(o)}',
                          lit: s.id == st.scene,
                          pending: s.id == show.pendingLook,
                          off: o == Often.never,
                          thumb: thumbOf(s.id),
                          swatch: Console.ground,
                          tooltip: '${s.name} — ${o.words}',
                          onTap: () => show.launch(s.id, at: show.pendingLook == s.id ? Quantise.now : null),
                          onHold: () => _oftenMenu(context, show, 'look.${s.id}', s.name),
                        );
                      }),
                ]),
                _Head(
                  'BACKGROUND',
                  hint: pinned ? 'yours until you let go' : 'the show\'s · tap: yours',
                  trailing: pinned
                      ? IntrinsicWidth(
                          child: Pad(
                              label: 'LET GO',
                              height: 22,
                              colour: Console.a,
                              tooltip: 'The show picks the background again',
                              onTap: () => show.lock(RigSlot.ground, false)))
                      : null,
                ),
                Wrap(children: [
                  for (final (g, ground) in _grounds)
                    if (g == Ground.black || pool.isOn('ground.${g.name}') || rig.ground.kind == g)
                      Builder(builder: (context) {
                        final o = g == Ground.black ? Often.normal : pool.oftenOf('ground.${g.name}');
                        return _Chip(
                          label: '${_groundWord(g)}${_oftenMark(o)}',
                          lit: rig.ground.kind == g,
                          off: o == Often.never,
                          thumb: switch (g) {
                            Ground.milk => 'assets/show/thumbs/milk.webp',
                            Ground.field => 'assets/show/thumbs/drift.webp',
                            Ground.pulse => 'assets/show/thumbs/pulse-grid.webp',
                            _ => null,
                          },
                          swatch: switch (g) {
                            Ground.black => const Color(0xff050505),
                            Ground.wash => const Color(0xff2a2238),
                            Ground.camera => const Color(0xff203028),
                            Ground.cover => const Color(0xff303040),
                            _ => const Color(0xff101418),
                          },
                          tooltip: '${_groundWord(g)}${g == Ground.black ? '' : ' — ${o.words}'}',
                          onTap: () => pinned && rig.ground.kind == g ? show.lock(RigSlot.ground, false) : show.setGround(ground),
                          onHold: g == Ground.black ? null : () => _oftenMenu(context, show, 'ground.${g.name}', _groundWord(g)),
                        );
                      }),
                ]),
                if (rig.ground.kind == Ground.milk && MilkFeed.shared.available) _MilkLine(),
                ..._styles(context, kind),
                const SizedBox(height: 10),
                Text(
                    'Anything you put on lands as LAND ON says. Held long or right-clicked: how often the show takes it by itself.'
                    '${pool.off.isEmpty ? '' : ' ${pool.off.length} switched off — gone everywhere until switched back on in ON/OFF.'}',
                    style: TextStyle(fontSize: 10, color: Console.faint)),
              ]);
            },
          ),
        ),
      );

  /// The style strip for the scene on: the dancers', the flock's, the words', or —
  /// for any other — the treatment it goes through.
  List<Widget> _styles(BuildContext context, Figure kind) {
    final pool = show.pool;
    final st = show.state;
    final now = ShowPool.lookupFigure(st.rig.figure).style;
    if (kind == Figure.dancers || kind == Figure.birds || kind == Figure.words) {
      final held = show.style != null && show.styleFor == kind;
      final weighs = kind != Figure.words;
      return [
        _Head(switch (kind) { Figure.dancers => 'DANCER STYLE', Figure.birds => 'FLOCK LOOK', _ => 'LYRICS FACE' },
            hint: held ? 'yours until AUTO' : 'the show\'s, a section at a time · tap: yours'),
        Wrap(children: [
          _Word(label: 'AUTO', lit: !held, tooltip: 'The show picks one a section at a time', onTap: () => show.setStyle(null)),
          for (final name in _stylesOf(kind))
            if (pool.styleOn(kind, name) || name == now)
              Builder(builder: (context) {
                final o = weighs ? pool.oftenOf('style.${kind.name}.$name') : Often.normal;
                return _Word(
                  label: '${name.toUpperCase()}${_oftenMark(o)}',
                  lit: now == name,
                  off: o == Often.never,
                  tooltip: weighs ? '$name — ${o.words}' : wordsStyleWords[WordsStyle.values.byName(name)],
                  onTap: () => show.setStyle(name, forKind: kind),
                  onHold: weighs ? () => _oftenMenu(context, show, 'style.${kind.name}.$name', name) : null,
                );
              }),
        ]),
      ];
    }
    final scene = st.scene;
    if (kind == Figure.none || scene == null) return const [];
    final say = pool.treat[scene];
    final mix = say == null || say == 'mix';
    final on = imageTreatments.contains(st.rig.figure.treatment) ? st.rig.figure.treatment.name : null;
    return [
      _Head('TREATMENT', hint: mix ? 'the show\'s${on != null ? ' · now $on' : ''} · tap: yours' : 'yours until AUTO'),
      Wrap(children: [
        _Word(
            label: 'AUTO',
            lit: mix,
            tooltip: 'The show puts it through one now and then (every ${ShowEngine.treatBars} bars)',
            onTap: () => show.setTreat(scene, null)),
        _Word(label: 'OFF', lit: say == 'raw', tooltip: 'Always as it draws itself', onTap: () => show.setTreat(scene, 'raw')),
        for (final t in imageTreatments)
          if (pool.isOn('treatment.${t.name}'))
            Builder(builder: (context) {
              final o = pool.oftenOf('treatment.${t.name}');
              return _Word(
                label: '${t.name.toUpperCase()}${_oftenMark(o)}',
                lit: say == t.name || (mix && on == t.name),
                off: o == Often.never,
                tooltip: '${t.name} — ${o.words} (for every scene)',
                onTap: () => show.setTreat(scene, say == t.name ? null : t.name),
                onHold: () => _oftenMenu(context, show, 'treatment.${t.name}', t.name),
              );
            }),
      ]),
    ];
  }
}

/// MilkDrop's preset under the scene, and the hands on it.
class _MilkLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final milk = MilkFeed.shared;
    return ListenableBuilder(
      listenable: Listenable.merge([milk, milk.director]),
      builder: (context, _) {
        final d = milk.director;
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _Line(children: [
            Icon(Icons.blur_on, size: 14, color: Console.quiet),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
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
          ]),
        );
      },
    );
  }
}

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
                  tooltip:
                      '${s.tip}: ${s.knob == TuneKnob.tint ? '${(tuneOf(tune, treatment, s.knob) * 100).round()} %' : '× ${tuneOf(tune, treatment, s.knob).toStringAsFixed(2)}'} (double-click: as drawn)',
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

// ------------------------------------------------------------------ the tabs
class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.onPick, required this.show, required this.kit, required this.info, required this.booth});
  final ShowTab tab;
  final void Function(ShowTab) onPick;
  final ShowEngine show;
  final StageKit? kit;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  static const _tips = {
    ShowTab.rules: 'What goes with what, at a glance',
    ShowTab.switches: 'Every scene, style, treatment, background and blend: on, or gone everywhere',
    ShowTab.dancers: 'Who dances, and every move',
    ShowTab.milkdrop: 'The presets, their director, the maker',
    ShowTab.settings: 'The finish, the director, the quality, the stage\'s numbers',
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
                      label: t == ShowTab.switches ? 'ON/OFF' : t.name.toUpperCase(),
                      height: 26,
                      lit: t == tab,
                      colour: Console.ink,
                      tooltip: _tips[t],
                      onTap: () => onPick(t)),
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
                    ShowTab.rules => _RulesTab(show: show, kit: kit) as Widget,
                    ShowTab.switches => _SwitchesTab(show: show, kit: kit),
                    ShowTab.dancers => _DancersTab(show: show),
                    ShowTab.milkdrop => MilkPanel(booth: booth),
                    ShowTab.settings => _SettingsTab(show: show, info: info, booth: booth),
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

// ---------------------------------------------------------------- SETTINGS
/// The rest, tucked away: the finish over everything, how strong the blend is, the
/// treatment's knobs, the director's temper, the quality, the stage's numbers.
class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.show, required this.info, required this.booth});
  final ShowEngine show;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final rig = show.state.rig;
          final f = rig.finish;
          final pool = show.pool;
          final mineFinish = show.locked(RigSlot.finish);
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
          final treat = imageTreatments.contains(rig.figure.treatment) ? rig.figure.treatment.name : null;
          return ListView(children: [
            Row(children: [
              Text('THE FINISH', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(mineFinish ? 'yours for every scene' : 'each scene\'s own · a knob turned makes it yours',
                      style: TextStyle(fontSize: 10, color: Console.faint))),
              if (mineFinish)
                IntrinsicWidth(child: Pad(label: 'EACH SCENE\'S OWN', height: 22, colour: Console.quiet, onTap: () => show.lock(RigSlot.finish, false))),
            ]),
            const SizedBox(height: 6),
            _Line(children: [
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
            const SizedBox(height: 10),
            Row(children: [
              Text('HOW STRONG THE BLEND', style: Console.label(10, color: Console.ink)),
              Expanded(
                child: Slider(
                    value: rig.blend.strength,
                    onChanged: (v) => show.setBlend(rig.blend.copyWith(strength: v)),
                    padding: const EdgeInsets.symmetric(horizontal: 12)),
              ),
              Text('${(rig.blend.strength * 100).round()} %', style: Console.label(9)),
            ]),
            if (treat != null) ...[
              const SizedBox(height: 6),
              Text('THE TREATMENT ON NOW', style: Console.label(10, color: Console.ink)),
              _TuneLine(show: show, treatment: treat),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Text('THE DIRECTOR', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 10),
              Text('calm', style: Console.label(9)),
              Expanded(child: Slider(value: pool.bias, min: -1, max: 1, onChanged: (v) => show.setPool(pool.copyWith(bias: v)))),
              Text('busy', style: Console.label(9)),
            ]),
            Row(children: [
              Expanded(child: Text('the beat before a drop goes black', style: TextStyle(fontSize: 12, color: Console.ink))),
              Switch(value: pool.darkBeat, onChanged: (v) => show.setPool(pool.copyWith(darkBeat: v))),
            ]),
            const Divider(height: 20),
            _StageNumbers(show: show, info: info, booth: booth),
          ]);
        },
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

/// The stage's own numbers, its log, its quality and the picture against the sound.
class _StageNumbers extends StatelessWidget {
  const _StageNumbers({required this.show, required this.info, required this.booth});
  final ShowEngine show;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StageInfo>(
        valueListenable: info,
        builder: (context, i, _) => ValueListenableBuilder<List<String>>(
          valueListenable: ShowDebug.flips,
          builder: (context, flips, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
