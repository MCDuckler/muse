// The maker: a preset put together without writing MilkDrop's code — the look as
// sliders, the wave and the borders as colours and switches, up to four shapes,
// and reactions ("zoom pulses with the kick") that become per-frame lines — with
// the code itself a tab away for anybody who wants it, and the helper drawing the
// result as it is changed. Saved to the library's mine/.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/show/milk_feed.dart';
import '../../state/show/milk_preset_text.dart';
import '../booth/desk/console.dart';
import '../mag.dart';
import '../snack.dart';
import 'milk_preview.dart';

Future<void> openMilkMaker(BuildContext context, {required MilkText text, required String name, String? path}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => MilkMaker(text: text, name: name, path: path)),
    );

class MilkMaker extends StatefulWidget {
  const MilkMaker({super.key, required this.text, required this.name, this.path});
  final MilkText text;
  final String name;

  /// The file it came from, where it is one of ours: saving writes it back.
  final String? path;

  @override
  State<MilkMaker> createState() => _MilkMakerState();
}

class _MilkMakerState extends State<MilkMaker> with SingleTickerProviderStateMixin {
  late final MilkText _t = widget.text;
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TabController _tabs = TabController(length: 5, vsync: this);
  final _reactions = <MilkReaction>[];
  late String _freeFrame;
  Timer? _apply;
  bool _dirty = false;
  bool _wasLocked = false, _wasPinned = false;

  MilkFeed get feed => MilkFeed.shared;

  @override
  void initState() {
    super.initState();
    // The per-frame code split: the reactions written here, and the rest.
    final lines = _t.code('per_frame_').split('\n');
    final free = <String>[];
    for (final l in lines) {
      final r = MilkReaction.parse(l);
      if (r != null) {
        _reactions.add(r);
      } else if (l.trim().isNotEmpty) {
        free.add(l);
      }
    }
    _freeFrame = free.join('\n');
    for (var i = 0; i < 4; i++) {
      MilkShape(_t, i).ensure();
    }
    // The helper on and held while the maker is: the picture is the one being made.
    _wasPinned = feed.pinned;
    _wasLocked = feed.director.locked;
    feed.pinned = true;
    feed.director.set(locked: true);
    unawaited(feed.start().then((_) => _push()));
  }

  @override
  void dispose() {
    _apply?.cancel();
    feed.pinned = _wasPinned;
    feed.director.set(locked: _wasLocked);
    // Back to a file, if one was on.
    final p = feed.library.last;
    if (p != null) feed.load(p);
    _name.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// The preset as text, the reactions written in.
  String get text {
    final lines = [
      if (_freeFrame.trim().isNotEmpty) ..._freeFrame.split('\n').where((l) => l.trim().isNotEmpty),
      for (final r in _reactions) r.line,
    ];
    _t.setCode('per_frame_', lines.join('\n'));
    return _t.toString();
  }

  /// A change: the helper shown it a moment later (not on every slider tick).
  void _changed() {
    _dirty = true;
    setState(() {});
    _apply?.cancel();
    _apply = Timer(const Duration(milliseconds: 250), _push);
  }

  void _push() => feed.loadText(text);

  Future<void> _save({bool as = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      messenger.say(snack(const Text('A name first')));
      return;
    }
    final p = await feed.library.save(name, text);
    _dirty = false;
    feed.load(p);
    messenger.say(snack(Text('Saved as ${p.fullName}')));
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
        title: SizedBox(
          width: 420,
          child: TextField(
            controller: _name,
            style: Mag.title(16, color: Console.ink),
            cursorColor: accent,
            decoration: InputDecoration(isDense: true, hintText: 'Author - Title', hintStyle: TextStyle(color: Console.faint), border: InputBorder.none),
          ),
        ),
        actions: [
          if (_dirty) Padding(padding: const EdgeInsets.only(right: 8), child: Center(child: Text('unsaved', style: TextStyle(color: Console.quiet, fontSize: 12)))),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined, size: 18), label: const Text('Save')),
          const SizedBox(width: 12),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: Console.ink,
          unselectedLabelColor: Console.quiet,
          indicatorColor: accent,
          isScrollable: true,
          tabs: const [Tab(text: 'Look'), Tab(text: 'Wave & borders'), Tab(text: 'Shapes'), Tab(text: 'Reactions'), Tab(text: 'Code')],
        ),
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 980;
          final form = TabBarView(
            controller: _tabs,
            children: [_look(), _wave(), _shapes(), _reactionsTab(), _code()],
          );
          final preview = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MilkPreview(),
              const SizedBox(height: 6),
              ValueListenableBuilder<String?>(
                valueListenable: feed.presetTrouble,
                builder: (context, t, _) => Text(
                  t ?? 'MilkDrop takes it as it is changed.',
                  style: TextStyle(color: t == null ? Console.quiet : const Color(0xffe0302a), fontSize: 12),
                ),
              ),
            ],
          );
          if (narrow) {
            return Column(children: [Padding(padding: const EdgeInsets.all(12), child: preview), Expanded(child: form)]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: form),
              SizedBox(width: 440, child: Padding(padding: const EdgeInsets.fromLTRB(0, 12, 16, 12), child: preview)),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------ the tabs
  Widget _look() => _page([
        _head('The frame, every frame', 'What the last picture does before this one is drawn over it.'),
        _num('zoom', 'Zoom', 0.9, 1.15, 'over 1 in, under 1 out'),
        _num('rot', 'Turn', -0.15, 0.15, 'radians a frame'),
        _num('warp', 'Warp', 0, 3, 'the wobble'),
        _num('fWarpScale', 'Warp size', 0.2, 4),
        _num('fWarpAnimSpeed', 'Warp speed', 0.1, 4),
        _num('fDecay', 'Decay', 0.85, 1, 'how much of the last frame stays'),
        _num('fGammaAdj', 'Brightness', 0.5, 4),
        _num('fZoomExponent', 'Zoom bias', 0.1, 3, 'how the zoom varies from the middle out'),
        _num('cx', 'Middle across', 0, 1),
        _num('cy', 'Middle down', 0, 1),
        _num('dx', 'Slide across', -0.1, 0.1),
        _num('dy', 'Slide down', -0.1, 0.1),
        _num('sx', 'Stretch across', 0.9, 1.1),
        _num('sy', 'Stretch down', 0.9, 1.1),
        _head('The echo', 'The picture over itself a second time, zoomed, flipped.'),
        _num('fVideoEchoZoom', 'Echo zoom', 0.5, 2),
        _num('fVideoEchoAlpha', 'Echo', 0, 1),
        _choice('nVideoEchoOrientation', 'Echo flipped', const ['as it is', 'across', 'down', 'both']),
        _head('Switches', ''),
        _flags([
          ('bTexWrap', 'wrap at the edges'),
          ('bDarkenCenter', 'darken the middle'),
          ('bBrighten', 'brighten'),
          ('bDarken', 'darken'),
          ('bSolarize', 'solarize'),
          ('bInvert', 'invert'),
        ]),
        _head('Motion vectors', 'A grid of short lines showing where the picture flows.'),
        _count('nMotionVectorsX', 'Across', 0, 64),
        _count('nMotionVectorsY', 'Down', 0, 48),
        _num('mv_l', 'Length', 0, 5),
        _num('mv_a', 'Strength', 0, 1),
        _colour('mv_', 'Colour'),
      ]);

  Widget _wave() => _page([
        _head('The wave', 'The sound, drawn: MilkDrop\'s own oscilloscope, in one of eight shapes.'),
        _choice('nWaveMode', 'Shape', const ['circle', 'x-y', 'centred line', 'spectrum-ish', 'two lines', 'explosive hash', 'line', 'double line']),
        _num('fWaveAlpha', 'Brightness', 0, 2),
        _num('fWaveScale', 'Size', 0, 5),
        _num('fWaveSmoothing', 'Smoothing', 0, 1),
        _num('fWaveParam', 'The shape\'s own knob', -1, 1),
        _num('wave_x', 'Place across', 0, 1),
        _num('wave_y', 'Place down', 0, 1),
        _colour('wave_', 'Colour'),
        _flags([
          ('bAdditiveWaves', 'additive'),
          ('bWaveDots', 'dots'),
          ('bWaveThick', 'thick'),
          ('bMaximizeWaveColor', 'full colour'),
          ('bModWaveAlphaByVolume', 'brightness by volume'),
        ]),
        _num('fModWaveAlphaStart', 'Volume: quiet end', 0, 2),
        _num('fModWaveAlphaEnd', 'Volume: loud end', 0, 2),
        _head('Borders', 'A frame round the picture, outer and inner.'),
        _num('ob_size', 'Outer size', 0, 0.5),
        _num('ob_a', 'Outer strength', 0, 1),
        _colour('ob_', 'Outer colour'),
        _num('ib_size', 'Inner size', 0, 0.5),
        _num('ib_a', 'Inner strength', 0, 1),
        _colour('ib_', 'Inner colour'),
      ]);

  Widget _shapes() => _page([
        for (var i = 0; i < 4; i++) ..._shape(MilkShape(_t, i)),
      ]);

  List<Widget> _shape(MilkShape s) => [
        Row(
          children: [
            Switch(value: s.enabled, onChanged: (v) {
              s.enabled = v;
              _changed();
            }),
            const SizedBox(width: 8),
            Text('Shape ${s.index + 1}', style: Mag.title(15, color: Console.ink)),
          ],
        ),
        if (s.enabled) ...[
          _slider('Sides', s.sides.toDouble(), 3, 100, (v) => s.sides = v.round(), integer: true),
          _slider('Across', s.x, 0, 1, (v) => s.x = v),
          _slider('Down', s.y, 0, 1, (v) => s.y = v),
          _slider('Size', s.rad, 0, 1, (v) => s.rad = v),
          _slider('Angle', s.ang, 0, 6.2832, (v) => s.ang = v),
          _slider('Copies', s.instances.toDouble(), 1, 64, (v) => s.instances = v.round(), integer: true, hint: 'each with its own `instance` in the code'),
          _rgba('Middle', s.inner, (c) => s.inner = c),
          _rgba('Edge', s.outer, (c) => s.outer = c),
          _rgba('Border', s.border, (c) => s.border = c),
          Wrap(
            spacing: 12,
            children: [
              _flag('additive', s.additive, (v) => s.additive = v),
              _flag('thick border', s.thick, (v) => s.thick = v),
              _flag('textured with the picture', s.textured, (v) => s.textured = v),
            ],
          ),
          _codeField('Its per-frame code', s.code, (v) => s.code = v, hint: 'rad = rad + 0.3*wo_hit_kick;\nang = ang + wo_bar*6.2832;'),
        ],
        const Divider(height: 24),
      ];

  Widget _reactionsTab() => _page([
        _head('Reactions', 'Each one pushes something in the look by one of the show\'s numbers, every frame. Written into the per-frame code for you.'),
        for (var i = 0; i < _reactions.length; i++) _reactionRow(i),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () {
              _reactions.add(const MilkReaction(target: 'zoom', source: 'wo_hit_kick', amount: 0.05));
              _changed();
            },
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add a reaction'),
            style: OutlinedButton.styleFrom(foregroundColor: Console.ink),
          ),
        ),
        const SizedBox(height: 16),
        Text('Some to start with', style: Mag.title(14, color: Console.ink)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, r) in const [
              ('zoom in on the kick', MilkReaction(target: 'zoom', source: 'wo_hit_kick', amount: 0.06)),
              ('turn with the bar', MilkReaction(target: 'rot', source: 'wo_bar', amount: 0.03, shape: 'sin')),
              ('wobble on the snare', MilkReaction(target: 'warp', source: 'wo_hit_snare', amount: 0.8)),
              ('fade up a build', MilkReaction(target: 'decay', source: 'wo_build', amount: 0.03)),
              ('blow out on the drop', MilkReaction(target: 'zoom', source: 'wo_drop', amount: -0.08)),
              ('dim in a breakdown', MilkReaction(target: 'gamma', source: 'wo_breakdown', amount: -0.8)),
              ('wave reddens on the bass', MilkReaction(target: 'wave_r', source: 'wo_band_low', amount: 0.6)),
              ('flash the border on the hit', MilkReaction(target: 'ob_size', source: 'wo_hit', amount: 0.1)),
              ('slide with the hats', MilkReaction(target: 'dx', source: 'wo_hit_top', amount: 0.01)),
            ])
              ActionChip(
                label: Text(label),
                onPressed: () {
                  _reactions.add(r);
                  _changed();
                },
              ),
          ],
        ),
      ]);

  Widget _reactionRow(int i) {
    final r = _reactions[i];
    void put(MilkReaction n) {
      _reactions[i] = n;
      _changed();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          _drop(r.target, MilkReaction.targets, (v) => put(MilkReaction(target: v, source: r.source, amount: r.amount, shape: r.shape))),
          const SizedBox(width: 8),
          Text('by', style: TextStyle(color: Console.quiet)),
          const SizedBox(width: 8),
          _drop(r.source, MilkReaction.sources, (v) => put(MilkReaction(target: r.target, source: v, amount: r.amount, shape: r.shape))),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: r.shape,
            dropdownColor: Console.panel,
            style: TextStyle(color: Console.ink, fontSize: 13),
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 'pulse', child: Text('as it is')),
              DropdownMenuItem(value: 'sin', child: Text('as a swing')),
              DropdownMenuItem(value: 'step', child: Text('past a half')),
            ],
            onChanged: (v) => v == null ? null : put(MilkReaction(target: r.target, source: r.source, amount: r.amount, shape: v)),
          ),
          Expanded(
            child: Slider(
              value: r.amount.clamp(-1.0, 1.0),
              min: -1,
              max: 1,
              divisions: 200,
              label: r.amount.toStringAsFixed(2),
              onChanged: (v) => put(MilkReaction(target: r.target, source: r.source, amount: v, shape: r.shape)),
            ),
          ),
          SizedBox(width: 44, child: Text(r.amount.toStringAsFixed(2), style: Mag.typewriter(12, color: Console.ink))),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: Console.faint),
            onPressed: () {
              _reactions.removeAt(i);
              _changed();
            },
          ),
        ],
      ),
    );
  }

  Widget _drop(String value, Map<String, String> options, void Function(String) on) => Tooltip(
        message: options[value] ?? '',
        child: DropdownButton<String>(
          value: options.containsKey(value) ? value : options.keys.first,
          dropdownColor: Console.panel,
          style: Mag.typewriter(13, color: Console.ink),
          underline: const SizedBox.shrink(),
          items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Tooltip(message: e.value, child: Text(e.key)))],
          onChanged: (v) => v == null ? null : on(v),
        ),
      );

  Widget _code() => _page([
        _head('The code', 'MilkDrop\'s own language: a line an assignment, `;` between. `wo_*` is the show (docs/milk-presets.md); `q1`–`q32` reach the shaders.'),
        _codeField('Once, when the preset starts (per_frame_init)', _t.code('per_frame_init_'), (v) => _t.setCode('per_frame_init_', v)),
        _codeField('Every frame (per_frame) — besides the reactions', _freeFrame, (v) => _freeFrame = v, hint: 'wave_r = 0.5 + 0.5*sin(wo_hue*6.2832);\nq1 = wo_drop;'),
        _codeField('Every vertex of the warp mesh (per_pixel)', _t.code('per_pixel_'), (v) => _t.setCode('per_pixel_', v), hint: 'zoom = zoom + 0.1*rad*wo_hit_kick;'),
        _codeField('The warp shader (HLSL, MilkDrop 2)', _t.code('warp_'), (v) => _t.setCode('warp_', v), lines: 10),
        _codeField('The composite shader (HLSL, MilkDrop 2)', _t.code('comp_'), (v) => _t.setCode('comp_', v), lines: 10),
      ]);

  // --------------------------------------------------------------- the widgets
  Widget _page(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: children,
      );

  Widget _head(String title, String sub) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Mag.title(15, color: Console.ink)),
            if (sub.isNotEmpty) Text(sub, style: TextStyle(color: Console.quiet, fontSize: 12)),
          ],
        ),
      );

  Widget _num(String key, String label, double min, double max, [String hint = '']) =>
      _slider(label, _t.num(key).clamp(min, max), min, max, (v) => _t.set(key, v), hint: hint);

  Widget _count(String key, String label, double min, double max) =>
      _slider(label, _t.integer(key).toDouble().clamp(min, max), min, max, (v) => _t.set(key, v.round()), integer: true);

  Widget _slider(String label, double value, double min, double max, void Function(double) on, {bool integer = false, String hint = ''}) => Row(
        children: [
          SizedBox(width: 150, child: Tooltip(message: hint, child: Text(label, style: TextStyle(color: Console.ink, fontSize: 13)))),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: integer ? (max - min).round() : 400,
              onChanged: (v) {
                on(v);
                _changed();
              },
            ),
          ),
          SizedBox(width: 56, child: Text(integer ? '${value.round()}' : value.toStringAsFixed(3), style: Mag.typewriter(12, color: Console.ink), textAlign: TextAlign.right)),
        ],
      );

  Widget _choice(String key, String label, List<String> names) => Row(
        children: [
          SizedBox(width: 150, child: Text(label, style: TextStyle(color: Console.ink, fontSize: 13))),
          DropdownButton<int>(
            value: _t.integer(key).clamp(0, names.length - 1),
            dropdownColor: Console.panel,
            style: TextStyle(color: Console.ink, fontSize: 13),
            underline: const SizedBox.shrink(),
            items: [for (var i = 0; i < names.length; i++) DropdownMenuItem(value: i, child: Text(names[i]))],
            onChanged: (v) {
              if (v == null) return;
              _t.set(key, v);
              _changed();
            },
          ),
        ],
      );

  Widget _flags(List<(String, String)> flags) => Wrap(
        spacing: 12,
        children: [for (final (k, l) in flags) _flag(l, _t.integer(k) != 0, (v) => _t.set(k, v ? 1 : 0))],
      );

  Widget _flag(String label, bool value, void Function(bool) on) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(value: value, onChanged: (v) {
            on(v ?? false);
            _changed();
          }),
          Text(label, style: TextStyle(color: Console.ink, fontSize: 13)),
        ],
      );

  /// Red, green, blue as three sliders, under keys `<prefix>r/g/b`.
  Widget _colour(String prefix, String label) => _rgba(
        label,
        [_t.num('${prefix}r'), _t.num('${prefix}g'), _t.num('${prefix}b'), -1],
        (c) {
          _t.set('${prefix}r', c[0]);
          _t.set('${prefix}g', c[1]);
          _t.set('${prefix}b', c[2]);
        },
      );

  Widget _rgba(String label, List<double> c, void Function(List<double>) on) {
    final colour = Color.fromARGB(255, (c[0] * 255).round().clamp(0, 255), (c[1] * 255).round().clamp(0, 255), (c[2] * 255).round().clamp(0, 255));
    Widget one(int i, String name) => Expanded(
          child: Slider(
            value: c[i].clamp(0.0, 1.0),
            min: 0,
            max: 1,
            activeColor: [Colors.red, Colors.green, Colors.blue, Colors.white][i],
            onChanged: (v) {
              final n = [...c];
              n[i] = v;
              on(n);
              _changed();
            },
          ),
        );
    return Row(
      children: [
        SizedBox(width: 150, child: Text(label, style: TextStyle(color: Console.ink, fontSize: 13))),
        Container(width: 18, height: 18, decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(4), border: Border.all(color: Console.line))),
        one(0, 'r'),
        one(1, 'g'),
        one(2, 'b'),
        if (c[3] >= 0) one(3, 'a'),
      ],
    );
  }

  Widget _codeField(String label, String value, void Function(String) on, {String hint = '', int lines = 5}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: Console.ink, fontSize: 13)),
            const SizedBox(height: 4),
            TextField(
              controller: TextEditingController(text: value),
              maxLines: lines,
              minLines: 3,
              style: Mag.typewriter(12, color: Console.ink),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                hintStyle: Mag.typewriter(12, color: Console.faint),
                filled: true,
                fillColor: Console.panel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
              onChanged: (v) {
                on(v);
                _dirty = true;
                _apply?.cancel();
                _apply = Timer(const Duration(milliseconds: 600), _push);
              },
            ),
          ],
        ),
      );
}
