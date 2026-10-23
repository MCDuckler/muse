// The show's own page of the booth: the room slid left of the decks (the board's
// twin on the other side). Made to be used, not studied:
//
//   the picture, and under it NEXT, HOLD and KEEP and the pads to play the light with
//   (hit, black, strobe, freeze);
//
//   down the right the snapshots (show_room_snapshots.dart: the rules named, kept,
//   shared with every WetOwl account) and the combination selector (show_room_kart.dart): background,
//   scene, style, mask and blend as rows of cards, the combination they make shown
//   blended, its switch (in the rotation or never) and its weight, and PLAY IT;
//
//   under the pads the tabs: the RULES in force (yours, and the ones that came with
//   the app), the MAP (the rotation at a glance, show_room_map.dart), what is CUT by
//   the measuring (show_room_cut.dart), the FAVES
//   (what was on the stage, kept with KEEP: show_room_faves.dart), the 3D TEXT's
//   words and ways (show_room_type3d.dart), the DANCERS, MILKDROP's presets, and SETTINGS (the finish, the
//   director, the quality, the stage's numbers).
//
// The model: state/show/show_combos.dart. Plan: ~/.claude/plans/wetowl-show-combos.md.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, rootBundle;
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/show/camera_feed.dart';
import '../../state/show/combo_scores.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_engine.dart';
import '../../state/show/show_faves.dart';
import '../../state/show/show_pool.dart';
import '../../state/show/show_rig.dart';
import '../../state/show/show_snapshots.dart';
import '../../state/show/show_state.dart' show ShowPalette;
import '../../state/show/show_tune.dart';
import '../booth/desk/console.dart';
import '../dialogs.dart' show promptForName;
import '../feel.dart';
import '../mag.dart';
import '../snack.dart';
import 'milk_page.dart';
import 'native_stage.dart';
import 'scene.dart';
import 'show_dance.dart' show DanceClock, DanceModels, DanceShot, DanceTroupe;
import 'show_flock.dart' show FlockClock, FlockLook;
import 'show_meme_bank.dart' show MemeMood;
import 'show_debug.dart';
import 'show_faves.dart';
import 'show_moves.dart';
import 'show_tile.dart' show showTileOffsetDialog;
import 'stage_kit.dart';
import 'stage_preview.dart';
import 'stage_page.dart';
import 'stage_pop_out_none.dart' if (dart.library.io) 'stage_pop_out_io.dart';

part 'show_room_cut.dart';
part 'show_room_faves.dart';
part 'show_room_kart.dart';
part 'show_room_map.dart';
part 'show_room_snapshots.dart';
part 'show_room_type3d.dart';

/// Bumped by the K key: the room slides to the show's page, or back.
final showRoomToggles = ValueNotifier<int>(0);

enum ShowTab { rules, map, cut, faves, text, dancers, milkdrop, settings }

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
  'type3d',
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
      Figure.words || Figure.type3d => _Family.words,
      Figure.meme || Figure.room => _Family.pictures,
    };

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

  /// The selector's pattern; null follows the stage.
  final _picked = ValueNotifier<ComboRule?>(null);

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
    _picked.dispose();
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
          Expanded(child: _Tabs(tab: _tab, onPick: _pickTab, show: show, kit: kit, info: _info, booth: widget.booth, onRule: (r) => _picked.value = r, picked: _picked)),
        ],
      );
      // What there is to pick, down the right.
      final right = kit == null
          ? const SizedBox.shrink()
          : BoothPanel(child: Plate(padding: const EdgeInsets.fromLTRB(10, 2, 10, 8), child: _Kart(show: show, kit: kit, picked: _picked)));
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
                              : GrabbableStage(child: StagePreview(feed: show, book: kit!.book, programs: kit!.programs, scale: 0.6, rank: 1, info: info)),
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
                  final c = show.combo;
                  final sceneName = kit?.book[st.scene]?.name ?? st.scene ?? '—';
                  final style = c?.style ?? rig.figure.style;
                  return Row(children: [
                    Text('NOW', style: Console.label(9, color: Console.a)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          '$sceneName${style != null && style != 'raw' ? ' · $style' : ''}',
                          if (c != null && !c.world) 'on ${_groundName(c.ground)}',
                          if (c != null && !c.world) '${c.mask == Mask.none ? '' : '${_maskName(c.mask).toLowerCase()} · '}${_mixName(c.mix).toLowerCase()}',
                          if (show.sceneHeld) 'held',
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

// ------------------------------------------------------------------ the buttons
/// NEXT, HOLD — and under them the pads.
class _Controls extends StatelessWidget {
  const _Controls({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final held = show.sceneHeld;
          final milk = show.heldGround == 'milk';
          return BoothPanel(
            child: Plate(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  _Big(icon: Icons.skip_next, label: 'NEXT', tip: 'Another scene now (with MilkDrop alone: another preset)', onTap: show.nextScene),
                  _Big(
                    icon: Icons.blur_linear,
                    label: 'MOSH',
                    tip: 'Another scene now, datamoshed into: the picture on dragged by the new one\'s motion until it breaks through (M on the stage page)',
                    onTap: show.moshNext,
                  ),
                  _Big(
                    icon: held ? Icons.lock : Icons.lock_open,
                    label: held ? 'HELD' : 'HOLD',
                    lit: held,
                    tip: held ? 'Let the show change again' : 'Keep the combination on — scene, style, background, mask, blend — until you let go',
                    onTap: () => show.holdScene(!held),
                  ),
                  _Big(
                    icon: Icons.star_border,
                    label: 'KEEP',
                    tip: 'Keep what is on the stage as a favourite, as it is — MilkDrop preset, camera and all (P on the stage page)',
                    onTap: show.combo == null ? null : () => unawaited(_keepFave(context, show, kit)),
                  ),
                  _Big(
                    icon: Icons.blur_on,
                    label: milk ? 'MILKDROP UNDER' : 'ANY BACKGROUND',
                    lit: milk,
                    tip: milk
                        ? 'MilkDrop under every scene, whatever the rotation says — tap to let the show choose backgrounds again'
                        : 'The rotation chooses the background — tap to keep MilkDrop under every scene',
                    onTap: () => show.holdGround(milk ? null : 'milk'),
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
  const _Big({required this.icon, required this.label, required this.tip, required this.onTap, this.lit = false});
  final IconData icon;
  final String label, tip;
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
                  Padding(padding: const EdgeInsets.only(right: 8), child: Icon(icon, size: 20, color: fg)),
                  Flexible(child: Text(label, style: Console.label(10, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
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

// ------------------------------------------------------------------ what to pick
/// A strip's heading: its word and a hint.
class _Head extends StatelessWidget {
  const _Head(this.word, {this.hint});
  final String word;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 5),
        child: Row(children: [
          Text(word, style: Console.label(10, color: Console.ink)),
          const SizedBox(width: 8),
          Expanded(child: Text(hint ?? '', style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      );
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

// ------------------------------------------------------------------ the tabs
class _Tabs extends StatelessWidget {
  const _Tabs(
      {required this.tab,
      required this.onPick,
      required this.show,
      required this.kit,
      required this.info,
      required this.booth,
      required this.onRule,
      required this.picked});
  final ShowTab tab;
  final void Function(ShowTab) onPick;
  final void Function(ComboRule) onRule;

  /// The selector's pick (the MAP outlines it, and picks into it).
  final ValueNotifier<ComboRule?> picked;
  final ShowEngine show;
  final StageKit? kit;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  static const _tips = {
    ShowTab.rules: 'The rules in force: yours, and the ones that came with the app',
    ShowTab.text: 'The 3D text: its words, face, motions, looks and knobs',
    ShowTab.faves: 'Your favourites: what was on the stage, kept as it was — browse, rate, put one back on in a tap',
    ShowTab.map: 'The big picture: how much of the time each scene, style, background, mask and blend gets, and what is off',
    ShowTab.cut: 'What the measuring keeps out of the rotation, or lets come less — let one come, or never',
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
                      label: t.name.toUpperCase(),
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
                    ShowTab.rules => _RulesTab(show: show, kit: kit, onPick: onRule) as Widget,
                    ShowTab.map => _MapTab(show: show, kit: kit, picked: picked),
                    ShowTab.text => _Type3dTab(show: show),
                    ShowTab.cut => _CutTab(show: show, kit: kit),
                    ShowTab.faves => _FavesTab(show: show, kit: kit),
                    ShowTab.dancers => _DancersTab(show: show),
                    ShowTab.milkdrop => MilkPanel(booth: booth),
                    ShowTab.settings => _SettingsTab(show: show, info: info, booth: booth),
                  };
                  final least = tab == ShowTab.dancers || tab == ShowTab.milkdrop || tab == ShowTab.map || tab == ShowTab.cut || tab == ShowTab.text || tab == ShowTab.faves ? 560.0 : 300.0;
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
          final mineFinish = show.finish != null;
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
                IntrinsicWidth(child: Pad(label: 'EACH SCENE\'S OWN', height: 22, colour: Console.quiet, onTap: () => show.setFinish(null))),
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
                    value: show.blendStrength,
                    onChanged: show.setBlendStrength,
                    padding: const EdgeInsets.symmetric(horizontal: 12)),
              ),
              Text('${(show.blendStrength * 100).round()} %', style: Console.label(9)),
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
              Text('DATAMOSH', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 10),
              Text('never', style: Console.label(9)),
              Expanded(
                child: Tooltip(
                  message: 'How many of the changes are datamoshed instead of cut or dissolved (the stage in its own window, or on Linux and Windows)',
                  child: Slider(value: pool.mosh, onChanged: (v) => show.setPool(pool.copyWith(mosh: v))),
                ),
              ),
              Text('${(pool.mosh * 100).round()} %', style: Console.label(9)),
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
