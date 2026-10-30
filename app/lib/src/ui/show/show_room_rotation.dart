// ROTATION: how often everything comes over a night. The set on (show_room_sets.dart);
// the scenes, each a fader with its share of the night and the way to its page; the
// backgrounds, masks and blends every scene shares (a scene may have its own: its
// page), each a fader with its share; which masks and blends each background takes;
// the effects over everything (the transformation, the datamosh); the director's
// temper.
part of 'show_room.dart';

class _RotationTab extends StatelessWidget {
  const _RotationTab({required this.show, required this.kit, required this.onScene});
  final ShowEngine show;
  final StageKit kit;
  final void Function(String?) onScene;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final plan = show.pool.plan;
          final shares = _sharesOf(show);
          final here = show.groundsHere();
          final live = show.combo;
          final scenes = [
            _Head('SCENES', hint: 'how often each comes, against the others · the music says when · › its page: its styles, its looks'),
            for (final s in _scenesInOrder(kit.book))
              () {
                final sp = plan.of(s.id);
                final noLook = sp.weight > 0 && !shares.anyOn(s.id);
                return _LevelRow(
                  key: ValueKey('scene:${s.id}'),
                  label: s.name,
                  thumb: thumbOf(s.id),
                  level: sp.level,
                  muted: sp.muted,
                  share: shares.scenes[s.id],
                  shareTip: 'Of the night, about',
                  live: show.state.scene == s.id,
                  note: noLook ? 'none of its looks can come: see its page' : null,
                  onLevel: (v) => show.setPlan(plan.withScene(s.id, level: v)),
                  onMuted: (m) => _muteScene(s.id, m),
                  onOpen: () => onScene(s.id),
                );
              }(),
          ];
          Widget sharedRow(PlanAxis a, String v, {String? label, Widget? picture, String? thumb, Color? swatch, String? note}) => _LevelRow(
                key: ValueKey('${a.name}:$v'),
                label: label ?? v,
                picture: picture,
                thumb: thumb,
                swatch: swatch,
                level: plan.sharedFader(a, v),
                muted: plan.sharedMuted(a, v),
                share: shares.ofNightBy(a, v),
                shareTip: 'Of the night, about (the scenes with their own count theirs)',
                live: live != null && (a == PlanAxis.fx || !live.world) && planValue(live, a) == v,
                note: note,
                onLevel: (x) => show.setPlan(plan.withShared(a, v, level: x)),
                onMuted: (m) => show.setPlan(plan.withShared(a, v, muted: m)),
              );
          final shared = [
            _SetBar(show: show),
            _Head('BACKGROUNDS', hint: 'under every scene that does not have its own'),
            for (final g in comboGrounds)
              sharedRow(
                PlanAxis.ground,
                g,
                label: _groundName(g),
                thumb: _groundThumb(g),
                swatch: _groundSwatch(g),
                note: here.contains(g)
                    ? null
                    : switch (g) {
                        'camera' => 'only while the room\'s camera is on (SETTINGS)',
                        'cover' => 'only with a record\'s cover',
                        _ => null,
                      },
              ),
            const _Head('MASKS', hint: 'where the background shows'),
            for (final m in Mask.values) sharedRow(PlanAxis.mask, m.name, label: _maskName(m), picture: _ComboSwatch(m, Mix.normal)),
            const _Head('BLENDS', hint: 'how the scene and the background meet'),
            for (final x in Mix.values) sharedRow(PlanAxis.mix, x.name, label: _mixName(x), picture: _ComboSwatch(Mask.none, x)),
            _TakesTable(show: show),
            const _Head('EFFECTS', hint: 'what is done to the scene over time and space · the native stage (Linux, Windows)'),
            for (final f in Fx.values) sharedRow(PlanAxis.fx, f.name, label: _fxName(f), picture: _FxIcon(f)),
            _EffectKnobs(show: show),
            _sliderRow(
              'MOSH CHANGES',
              show.pool.mosh,
              (v) => show.setPool(show.pool.copyWith(mosh: v)),
              left: 'never',
              right: '${(show.pool.mosh * 100).round()} %',
              tip: 'How many changes of scene are datamoshed into instead of cut or dissolved (MOSH under the picture: one now)',
            ),
            _Head('THE DIRECTOR', hint: 'its temper'),
            _sliderRow('CALM · BUSY', (show.pool.bias + 1) / 2, (v) => show.setPool(show.pool.copyWith(bias: v * 2 - 1)),
                left: 'calm', right: 'busy', tip: 'The energy it matches the scenes and the looks against, moved a quarter either way'),
            Row(children: [
              Expanded(child: Text('the beat before a drop goes black', style: TextStyle(fontSize: 12, color: Console.ink))),
              Switch(value: show.pool.darkBeat, onChanged: (v) => show.setPool(show.pool.copyWith(darkBeat: v))),
            ]),
            Row(children: [
              Expanded(
                child: Text(
                  show.doc.taste.isEmpty
                      ? 'NEXT has taught it nothing yet (a NEXT in a look\'s first bars: that look a little less)'
                      : 'NEXT has taught it ${show.doc.taste.length} look${show.doc.taste.length == 1 ? '' : 's'} to come less (ticks in the scenes\' grids)',
                  style: TextStyle(fontSize: 12, color: Console.ink),
                ),
              ),
              if (show.doc.taste.isNotEmpty)
                IntrinsicWidth(
                  child: Pad(
                    label: 'FORGET IT',
                    height: 24,
                    colour: Console.quiet,
                    tooltip: 'What NEXT taught it, forgotten',
                    onTap: () {
                      final was = show.doc.taste;
                      show.setDoc(show.doc.copyWith(taste: const {}));
                      ScaffoldMessenger.of(context).say(snack(const Text('What NEXT taught it is forgotten'),
                          action: SnackBarAction(label: 'UNDO', onPressed: () => show.setDoc(show.doc.copyWith(taste: was)))));
                    },
                  ),
                ),
            ]),
            const SizedBox(height: 12),
          ];
          return LayoutBuilder(builder: (context, c) {
            if (c.maxWidth >= 900) {
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: ListView(children: [const SizedBox(height: 0), ...scenes, const SizedBox(height: 12)])),
                const SizedBox(width: 18),
                Expanded(child: ListView(key: const ValueKey('rotation shared'), children: shared)),
              ]);
            }
            return ListView(key: const ValueKey('rotation shared'), children: [shared.first, ...scenes, ...shared.skip(1)]);
          });
        },
      );

  void _muteScene(String id, bool muted) {
    var plan = show.pool.plan;
    // Back on from a level of 0: at 1.
    if (!muted && plan.of(id).level <= 0) plan = plan.withScene(id, level: 1);
    show.setPlan(plan.withScene(id, muted: muted));
    // Off while it is on: on to the next one now.
    if (muted && show.state.scene == id) show.stepOn();
  }

  Widget _sliderRow(String label, double value, ValueChanged<double> onChanged, {required String left, required String right, String? tip}) => Tooltip(
        message: tip ?? '',
        waitDuration: const Duration(milliseconds: 700),
        child: Row(children: [
          SizedBox(width: 116, child: Text(label, style: Console.label(9, color: Console.ink))),
          Text(left, style: Console.label(8.5)),
          Expanded(child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged, padding: const EdgeInsets.symmetric(horizontal: 12))),
          SizedBox(width: 44, child: Text(right, textAlign: TextAlign.right, style: Console.label(8.5))),
        ]),
      );
}

/// Which masks and blends each background takes (show_plan.dart's notWith), folded.
class _TakesTable extends StatefulWidget {
  const _TakesTable({required this.show});
  final ShowEngine show;

  @override
  State<_TakesTable> createState() => _TakesTableState();
}

class _TakesTableState extends State<_TakesTable> {
  bool _open = false;

  static const _cols = ['keyhole', 'inverted', 'add', 'screen', 'contrast'];

  @override
  Widget build(BuildContext context) {
    final plan = widget.show.pool.plan;
    final not = [for (final g in comboGrounds) for (final x in _cols) if (!plan.takes(g, x)) '${_groundName(g)} no $x'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Row(children: [
            Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: Console.quiet),
            const SizedBox(width: 4),
            Text('WHAT EACH BACKGROUND TAKES', style: Console.label(9, color: Console.ink)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(not.isEmpty ? 'every mask and blend' : '${not.length} never: ${not.take(3).join(', ')}${not.length > 3 ? '…' : ''}',
                  style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      ),
      if (_open)
        Table(
          defaultColumnWidth: const FixedColumnWidth(64),
          columnWidths: const {0: FixedColumnWidth(100)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(children: [
              const SizedBox.shrink(),
              for (final x in _cols) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(x.toUpperCase(), style: Console.label(8))),
            ]),
            for (final g in comboGrounds)
              TableRow(children: [
                Text(_groundName(g), style: TextStyle(fontSize: 11.5, color: Console.ink)),
                for (final x in _cols)
                  Padding(
                    padding: const EdgeInsets.all(2),
                    child: _OnOff(
                      on: plan.takes(g, x),
                      onWord: 'YES',
                      offWord: 'NEVER',
                      width: 58,
                      tip: plan.takes(g, x) ? '${_groundName(g)} takes $x — tap: never' : '${_groundName(g)} never with $x — tap: it may',
                      onTap: () => widget.show.setPlan(plan.withTakes(g, x, !plan.takes(g, x))),
                    ),
                  ),
              ]),
          ],
        ),
    ]);
  }
}

/// An effect's name.
String _fxName(Fx f) => switch (f) {
      Fx.none => 'None',
      Fx.kaleidoscope => 'Kaleidoscope',
      Fx.slit => 'Slit-scan',
      Fx.both => 'Slit + kaleido',
      Fx.mosh => 'Datamosh',
    };

/// An effect's picture on its row.
class _FxIcon extends StatelessWidget {
  const _FxIcon(this.fx);
  final Fx fx;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Console.ground,
        child: Icon(
          switch (fx) {
            Fx.none => Icons.crop_square,
            Fx.kaleidoscope => Icons.filter_vintage_outlined,
            Fx.slit => Icons.view_week_outlined,
            Fx.both => Icons.auto_awesome_mosaic_outlined,
            Fx.mosh => Icons.blur_linear,
          },
          size: 18,
          color: Console.quiet,
        ),
      );
}

/// The effects' knobs, folded: the kaleidoscope's mirrors, the slit-scan's reach, the
/// datamosh's grain, melt and key frames.
class _EffectKnobs extends StatefulWidget {
  const _EffectKnobs({required this.show});
  final ShowEngine show;

  @override
  State<_EffectKnobs> createState() => _EffectKnobsState();
}

class _EffectKnobsState extends State<_EffectKnobs> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final t = show.pool.transform;
    Widget knob(String label, double value, double rest, String tip, TransformSet Function(double) set) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Knob(value: value, min: 0, max: 1, rest: rest, bipolar: false, size: 30, label: label, tooltip: tip, onChanged: (v) => show.setTransform(set(v))),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tooltip(
        message: _open ? 'Fold the knobs away' : 'The kaleidoscope\'s mirrors, the slit-scan\'s reach, the datamosh\'s grain, melt and key frames',
        child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(children: [
              Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: Console.quiet),
              const SizedBox(width: 4),
              Text('THEIR KNOBS', style: Console.label(9, color: Console.ink)),
            ]),
          ),
        ),
      ),
      if (_open) ...[
        _Line(children: [
          SizedBox(width: 116, child: Text('KALEIDOSCOPE', style: Console.label(8.5))),
          Tooltip(message: 'How many mirrors (2: one horizontal, one vertical); twice as many wedges', child: Text('MIRRORS', style: Console.label(8.5))),
          SizedBox(
            width: 140,
            child: Slider(
              value: t.count.toDouble(),
              min: 1,
              max: RigTransform.most.toDouble(),
              divisions: RigTransform.most - 1,
              onChanged: (v) => show.setTransform(t.copyWith(count: v.round())),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
          SizedBox(width: 22, child: Text('${t.count}', style: Console.label(9, color: Console.ink))),
          knob('TURN', t.turn, 0, 'The mirrors turned: ${(t.turn * 180).round()}° (double-click: straight)', (v) => t.copyWith(turn: v)),
          knob('LINE', t.line, 0.3, 'How much of the mirrors’ edges shows: ${(t.line * 100).round()} %', (v) => t.copyWith(line: v)),
          knob('DIFFERS', t.differ, 0.3, 'How far the reflections’ light and colour are from the original’s: ${(t.differ * 100).round()} %', (v) => t.copyWith(differ: v)),
          knob('AMOUNT', t.amount, 0.85, 'How much of the reflections: ${(t.amount * 100).round()} %', (v) => t.copyWith(amount: v)),
        ]),
        _Line(children: [
          const SizedBox(width: 116),
          Text('ITS BLEND', style: Console.label(8.5)),
          const SizedBox(width: 6),
          for (final x in Mix.values)
            _Word(
              label: x.name.toUpperCase(),
              lit: t.blend == x,
              tooltip: switch (x) {
                Mix.normal => 'The original whole on top; the reflections only where it is dark',
                Mix.add => 'The reflections added to the original: light on light',
                Mix.screen => 'Screened together: neither blows the other out',
                Mix.contrast => 'Their difference: where they agree is dark',
              },
              onTap: () => show.setTransform(t.copyWith(blend: x)),
            ),
        ]),
        _TuneLine(show: show, treatment: 'slit', label: 'SLIT-SCAN'),
        _Line(children: [
          SizedBox(width: 116, child: Text('DATAMOSH', style: Console.label(8.5))),
          knob('GRAIN', t.grain, 0.7, 'How blocky: a smooth melt .. a codec\'s grain, its blocks and colour bleed (${(t.grain * 100).round()} %)', (v) => t.copyWith(grain: v)),
          knob('MELT', t.melt, 0.5, 'How long its smears hold before the picture comes through (${(t.melt * 100).round()} %)', (v) => t.copyWith(melt: v)),
          knob('KEYS', t.keys, 0.5,
              'How often the picture is let through: patches on the bars, whole on a key frame (${(t.keys * 100).round()} %)', (v) => t.copyWith(keys: v)),
        ]),
      ],
    ]);
  }
}
