// The show's own page of the booth: the room slid left of the decks (the board's
// twin on the other side). One job per place:
//
//   PERFORM, down the left (show_room_perform.dart): the picture and what is on in
//   words, the judging of it in a tap (NEVER THIS, LESS, MORE, KEEP), everything the
//   hands hold and the letting go of it, NEXT · MOSH · HOLD, the pads;
//
//   and on the right, in tabs: the ROTATION — how often everything comes over a
//   night, scene by scene and the backgrounds, masks and blends they share, as faders
//   with each one's share of the night, the effects over everything and the
//   director's temper, saved as sets (show_room_rotation.dart, show_room_sets.dart);
//   each scene's own page from there — its styles, its own backgrounds, masks and
//   blends, the grid of its looks to judge one by one, its camera, what it shows
//   (show_room_scene.dart, show_room_grid.dart); the FAVES (show_room_faves.dart);
//   MILKDROP's presets; and the SETTINGS of this machine and of the picture's finish
//   (show_room_settings.dart).
//
// The model: state/show/show_plan.dart. Plan: ~/.claude/plans/wetowl-show-ui-rework.md.
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
import '../../state/show/plan_shares.dart';
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
import 'show_dance.dart' show DanceModels;
import 'show_debug.dart';
import 'show_faves.dart';
import 'show_moves.dart';
import 'show_tile.dart' show showTileOffsetDialog;
import 'stage_kit.dart';
import 'stage_preview.dart';
import 'stage_page.dart';
import 'stage_pop_out_none.dart' if (dart.library.io) 'stage_pop_out_io.dart';

part 'show_room_faves.dart';
part 'show_room_fader.dart';
part 'show_room_grid.dart';
part 'show_room_perform.dart';
part 'show_room_rotation.dart';
part 'show_room_scene.dart';
part 'show_room_settings.dart';
part 'show_room_snapshots.dart';
part 'show_room_stills.dart';
part 'show_room_type3d.dart';

/// Bumped by the K key: the room slides to the show's page, or back.
final showRoomToggles = ValueNotifier<int>(0);

enum ShowTab { rotation, faves, milkdrop, settings }

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

/// A background's picture on a card (where it has a thumbnail).
String? _groundThumb(String g) => switch (g) {
      'milk' => 'assets/show/thumbs/milk.webp',
      'field.drift' => 'assets/show/thumbs/drift.webp',
      _ when g.startsWith('pulse.') => 'assets/show/thumbs/${g.replaceAll('.', '-')}.webp',
      _ => null,
    };

/// A background's colour where it has no picture.
Color _groundSwatch(String g) => switch (g) {
      'black' => const Color(0xff050505),
      'white' => const Color(0xffffffff),
      'wash' => const Color(0xff2a2238),
      'camera' => const Color(0xff203028),
      'cover' => const Color(0xff303040),
      _ => const Color(0xff101418),
    };

/// The families the scenes fall into, in the scenes' order: what a scene puts on the
/// background — or nothing, the background alone.
enum _Family { bodies, shapes, flow, words, pictures, alone }

_Family _familyOf(Scene s) => switch (s.look.rig.figure.kind) {
      Figure.none => _Family.alone,
      Figure.dancers || Figure.birds || Figure.turntable => _Family.bodies,
      Figure.kinetic || Figure.blocks || Figure.flash || Figure.glide => _Family.shapes,
      Figure.fluid || Figure.veins || Figure.field => _Family.flow,
      Figure.words || Figure.type3d => _Family.words,
      Figure.meme || Figure.room => _Family.pictures,
    };

/// The plan's shares for what the show has now (the scenes known, the backgrounds here).
PlanShares _sharesOf(ShowEngine show) => PlanShares.of(show.pool.plan, show.kinds, show.groundsHere());

/// A scene's name.
String _sceneName(String id, SceneBook? book) => book?[id]?.name ?? id;

/// A combination in words: `Dancer · ascii on White · no mask · add`.
String _comboWords(Combo c, SceneBook? book) => [
      '${book?[c.scene]?.name ?? c.scene}${c.style != 'raw' ? ' · ${c.style}' : ''}',
      if (!c.world) 'on ${_groundName(c.ground)}${c.mask == Mask.none ? '' : ' · ${_maskName(c.mask).toLowerCase()}'} · ${_mixName(c.mix).toLowerCase()}',
      if (c.fx != Fx.none) '· ${_fxName(c.fx).toLowerCase()}',
    ].join(' ');

class ShowRoom extends StatefulWidget {
  const ShowRoom({super.key, required this.booth});
  final Booth booth;

  @override
  State<ShowRoom> createState() => _ShowRoomState();
}

class _ShowRoomState extends State<ShowRoom> {
  StageKit? _kit;
  String? _trouble;
  ShowTab _tab = ShowTab.rotation;
  final _info = ValueNotifier<StageInfo>(StageInfo.none);

  /// The scene whose page is open in the ROTATION tab; null: the rotation itself.
  String? _scene;

  ShowEngine get show => widget.booth.show;

  /// The lines between the page's parts, dragged like the crate's edge and kept in
  /// show.json: the perform side's share of the width (or, narrow, of the height),
  /// and how tall the picture is, as a share of the screen.
  double _split = 0.4, _splitNarrow = 0.55, _previewK = 0.34;

  double _panelNum(String key, double or, double lo, double hi) {
    final v = show.doc.panel[key];
    return v is num ? v.toDouble().clamp(lo, hi) : or;
  }

  void _keepPanel() => show.setDoc(show.doc.copyWith(panel: {
        // The keys of the pages before this one go.
        for (final e in show.doc.panel.entries)
          if (const {'faves.best', 'faves.least'}.contains(e.key)) e.key: e.value,
        'tab': _tab.name,
        if (_scene != null) 'scene': _scene,
        'split2': _split,
        'splitNarrow2': _splitNarrow,
        'preview': _previewK,
      }));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await ShowDebug.load();
      await show.ready();
      final p = show.doc.panel;
      final t = p['tab'];
      // Not MILKDROP on a fresh start: its panel starts the helper.
      if (t is String && t != ShowTab.milkdrop.name) _tab = ShowTab.values.asNameMap()[t] ?? ShowTab.rotation;
      _split = _panelNum('split2', _split, 0.28, 0.7);
      _splitNarrow = _panelNum('splitNarrow2', _splitNarrow, 0.25, 0.8);
      _previewK = _panelNum('preview', _previewK, 0.12, 0.75);
      final kit = await StageKit.load();
      show.director.scenes = kit.book.metas;
      show.looks = kit.book.looks;
      final s = p['scene'];
      if (s is String && kit.book[s] != null) _scene = s;
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
    _keepPanel();
  }

  void _openScene(String? id) {
    setState(() {
      _scene = id;
      _tab = ShowTab.rotation;
    });
    _keepPanel();
  }

  @override
  Widget build(BuildContext context) {
    final kit = _kit;
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 1100;
      final screenH = MediaQuery.sizeOf(context).height;
      final perform = _Perform(
        booth: widget.booth,
        kit: kit,
        trouble: _trouble,
        info: _info,
        previewHeight: (screenH * _previewK).clamp(100.0, 900.0),
        onPreviewDrag: (dy) => setState(() => _previewK = (_previewK + dy / screenH).clamp(0.12, 0.75)),
        onPreviewDone: _keepPanel,
        onScene: _openScene,
      );
      final work = _Workspace(
        tab: _tab,
        onTab: _pickTab,
        show: show,
        kit: kit,
        info: _info,
        booth: widget.booth,
        scene: _scene,
        onScene: _openScene,
      );
      if (narrow) {
        final room = math.max(1.0, c.maxHeight - _Seam.reach);
        return Column(children: [
          SizedBox(height: room * _splitNarrow, child: perform),
          _Seam(
            vertical: true,
            tip: 'Drag: more of the picture, or more of the rest',
            onDrag: (dy) => setState(() => _splitNarrow = (_splitNarrow + dy / room).clamp(0.25, 0.8)),
            onDone: _keepPanel,
          ),
          Expanded(child: work),
        ]);
      }
      final room = math.max(1.0, c.maxWidth - _Seam.reach);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: room * _split, child: perform),
          _Seam(
            vertical: false,
            tip: 'Drag: more of the picture, or more of the rest',
            onDrag: (dx) => setState(() => _split = (_split + dx / room).clamp(0.28, 0.7)),
            onDone: _keepPanel,
          ),
          Expanded(child: work),
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

/// A plain word chip (no picture), for a mode or a choice.
class _Word extends StatelessWidget {
  const _Word({required this.label, required this.lit, required this.onTap, this.off = false, this.tooltip});
  final String label;
  final bool lit, off;
  final String? tooltip;
  final VoidCallback? onTap;

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

/// A part's heading: its word and a hint, and what goes at its end.
class _Head extends StatelessWidget {
  const _Head(this.word, {this.hint, this.trailing = const []});
  final String word;
  final String? hint;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Row(children: [
          Text(word, style: Console.label(10, color: Console.ink)),
          const SizedBox(width: 8),
          Expanded(child: Text(hint ?? '', style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ...trailing,
        ]),
      );
}

/// A treatment's knobs (or a figure's own look's, where a shader draws it).
class _TuneLine extends StatelessWidget {
  const _TuneLine({required this.show, required this.treatment, this.label});
  final ShowEngine show;
  final String treatment;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final tune = show.pool.tune;
    final specs = treatmentTunes[treatment] ?? const <TuneSpec>[];
    final touched = specs.any((s) => tune.containsKey(tuneKey(treatment, s.knob)));
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(children: [
        SizedBox(width: 116, child: Text(label ?? treatment, style: Console.label(9))),
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

// ------------------------------------------------------------------ the workspace
class _Workspace extends StatelessWidget {
  const _Workspace(
      {required this.tab,
      required this.onTab,
      required this.show,
      required this.kit,
      required this.info,
      required this.booth,
      required this.scene,
      required this.onScene});
  final ShowTab tab;
  final void Function(ShowTab) onTab;
  final ShowEngine show;
  final StageKit? kit;
  final ValueNotifier<StageInfo> info;
  final Booth booth;
  final String? scene;
  final void Function(String?) onScene;

  static const _tips = {
    ShowTab.rotation: 'How often everything comes over a night: the scenes, and the backgrounds, masks and blends they share — each scene\'s own page from there',
    ShowTab.faves: 'Your favourites: what was on the stage, kept as it was — browse, rate, put one back on in a tap',
    ShowTab.milkdrop: 'The presets, their director, the maker',
    ShowTab.settings: 'The picture\'s finish, the quality, this screen\'s timing and camera, the stage\'s numbers',
  };

  @override
  Widget build(BuildContext context) {
    final kit = this.kit;
    final body = switch (tab) {
      _ when kit == null => const SizedBox.shrink(),
      ShowTab.rotation => scene == null
          ? _RotationTab(show: show, kit: kit, onScene: onScene)
          : _ScenePage(key: ValueKey(scene), show: show, kit: kit, scene: scene!, onScene: onScene, onTab: onTab),
      ShowTab.faves => _FavesTab(show: show, kit: kit),
      ShowTab.milkdrop => MilkPanel(booth: booth),
      ShowTab.settings => _SettingsTab(show: show, info: info, booth: booth),
    };
    return BoothPanel(
      child: Plate(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Line(children: [
            for (final t in ShowTab.values) ...[
              Pad(
                label: t.name.toUpperCase(),
                height: 26,
                lit: t == tab,
                colour: Console.ink,
                tooltip: _tips[t],
                onTap: () {
                  // ROTATION again from a scene's page: back to the rotation.
                  if (t == ShowTab.rotation && tab == ShowTab.rotation && scene != null) {
                    onScene(null);
                  } else {
                    onTab(t);
                  }
                },
              ),
              const SizedBox(width: 4),
            ],
          ]),
          const Divider(height: 14),
          Expanded(
            // A short panel (a 1280 x 720 desk): a tab gets at least the height it is
            // laid out for, scrolled where there is less.
            child: LayoutBuilder(builder: (context, c) {
              final least = tab == ShowTab.milkdrop || tab == ShowTab.faves ? 520.0 : 260.0;
              if (c.maxHeight >= least) return body;
              return SingleChildScrollView(child: SizedBox(height: least, child: body));
            }),
          ),
        ]),
      ),
    );
  }
}
