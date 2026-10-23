part of 'show_room.dart';

// The CUT tab: what the measuring keeps out of the rotation (state/show/combo_scores.dart:
// a figure lost in its background, a black or a white screen, mud, noise), and what
// it lets come less — each shown blended the selector's way, with LET IT COME (a rule
// of yours for it: it comes as the rules say, however it measured) and NEVER (off for
// good). The ones the rules would have come most often first.

class _CutTab extends StatefulWidget {
  const _CutTab({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  @override
  State<_CutTab> createState() => _CutTabState();
}

class _CutTabState extends State<_CutTab> {
  ShowEngine get show => widget.show;

  /// The ones that come less (under 0.5), rather than the ones cut.
  bool _less = false;

  /// One scene's only; null: all.
  String? _scene;

  /// How many are shown at most (the most likely first).
  static const _most = 96;

  static ComboRule _ruleOf(Combo c) => c.world
      ? ComboRule(scenes: {c.scene}, styles: {c.style})
      : ComboRule(grounds: {c.ground}, scenes: {c.scene}, styles: {c.style}, masks: {c.mask}, mixes: {c.mix});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([show, _Stills.shared]),
        builder: (context, _) {
          final kit = widget.kit;
          final scores = ComboScores.shipped;
          if (kit == null || scores == null) {
            return Center(child: Text('Nothing measured in this build.', style: TextStyle(color: Console.quiet, fontSize: 12)));
          }
          final pool = show.pool;
          final rules = pool.allRules;
          final rows = <(Combo, double, double)>[]; // combination, the rules' weight, measured
          var cut = 0, less = 0;
          final scenes = <String>{};
          for (final s in kit.book.scenes.values) {
            for (final c in combosOf(s.id, s.look.rig.figure.kind)) {
              final q = scores.quality(c);
              if (q == null) continue;
              final w = comboWeight(c, rules);
              final mine = pool.mineFor(_ruleOf(c));
              if (w <= 0 && mine == null) continue;
              final isCut = q < ComboScores.floor, isLess = !isCut && q < 0.5;
              if (isCut) cut++;
              if (isLess) less++;
              if (!(_less ? isLess : isCut)) continue;
              scenes.add(s.id);
              if (_scene != null && s.id != _scene) continue;
              rows.add((c, w, q));
            }
          }
          rows.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$3.compareTo(b.$3));
          final shown = rows.take(_most).toList();
          final book = kit.book;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Line(children: [
              Text('MEASURED', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 12),
              _Word(
                  label: 'CUT $cut',
                  lit: !_less,
                  tooltip: 'Kept out of the rotation: they measured badly on the stage (the figure lost, a black or white screen, mud, noise)',
                  onTap: () => setState(() => _less = false)),
              _Word(
                  label: 'COMES LESS $less',
                  lit: _less,
                  tooltip: 'In the rotation, but less often than the rules say: they measured middling',
                  onTap: () => setState(() => _less = true)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  rows.length > shown.length ? 'the ${shown.length} the rules would bring most, of ${rows.length}' : '',
                  style: Console.label(9),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            if (scenes.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _Line(children: [
                  _Word(label: 'ANY SCENE', lit: _scene == null, onTap: () => setState(() => _scene = null)),
                  for (final s in scenes)
                    _Word(label: _valueName(ComboAxis.scene, s, book), lit: _scene == s, onTap: () => setState(() => _scene = _scene == s ? null : s)),
                ]),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? Center(child: Text('None here.', style: TextStyle(color: Console.quiet, fontSize: 12)))
                  : LayoutBuilder(builder: (context, c) {
                      const gap = 8.0, least = 190.0;
                      final cols = math.max(1, ((c.maxWidth + gap) / (least + gap)).floor());
                      final w = (c.maxWidth - gap * (cols - 1)) / cols;
                      return GridView.builder(
                        itemCount: shown.length,
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, crossAxisSpacing: gap, mainAxisSpacing: gap, mainAxisExtent: w * 9 / 16 + 64),
                        itemBuilder: (context, i) {
                          final (combo, _, q) = shown[i];
                          final rule = _ruleOf(combo);
                          final mine = pool.mineFor(rule);
                          return _CutTile(
                            key: ValueKey(combo.key),
                            combo: combo,
                            measured: q,
                            mine: mine?.weight,
                            kit: kit,
                            palette: show.state.palette,
                            onCome: () => show.setPool(pool.withRule(rule, 1)),
                            onNever: () => show.setPool(pool.withRule(rule, 0)),
                            onBack: () => show.setPool(pool.withRule(rule, null)),
                            onPlay: () => show.play(combo),
                          );
                        },
                      );
                    }),
            ),
          ]);
        },
      );
}

class _CutTile extends StatelessWidget {
  const _CutTile(
      {super.key,
      required this.combo,
      required this.measured,
      required this.mine,
      required this.kit,
      required this.palette,
      required this.onCome,
      required this.onNever,
      required this.onBack,
      required this.onPlay});
  final Combo combo;
  final double measured;

  /// Your rule's weight for it, where you have one.
  final double? mine;
  final StageKit kit;
  final ShowPalette palette;
  final VoidCallback onCome, onNever, onBack, onPlay;

  @override
  Widget build(BuildContext context) {
    final book = kit.book;
    final kind = book[combo.scene]?.look.rig.figure.kind ?? Figure.none;
    final stills = _Stills.shared;
    final fig = stills.figure(kind, combo.style);
    final words = [
      _valueName(ComboAxis.scene, combo.scene, book),
      _valueName(ComboAxis.style, combo.style, book),
      if (!combo.world) ...[
        _valueName(ComboAxis.ground, combo.ground, book),
        if (combo.mask != Mask.none) _valueName(ComboAxis.mask, combo.mask.name, book),
        _valueName(ComboAxis.mix, combo.mix.name, book),
      ],
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: Tooltip(
          message: '$words\nmeasured on the stage: ${(measured * 100).round()}/100\n\nTap: on the stage, held',
          waitDuration: const Duration(milliseconds: 600),
          child: Material(
            color: Colors.black,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: Console.line)),
            child: InkWell(
              onTap: () {
                feel(Feel.commit);
                onPlay();
              },
              child: fig == null
                  ? Center(child: Text(stills.missing(kind, combo.style) ? 'no picture' : '', style: TextStyle(fontSize: 10, color: Console.quiet)))
                  : _Blended(
                      program: kit.programs.under,
                      figure: fig,
                      ground: stills.ground(combo.ground, palette),
                      blend: combo.world ? RigBlend.normal : RigBlend(mask: combo.mask, mix: combo.mix),
                      coverage: _stillCoverage(kind, combo.style),
                      dim: groundOfKey(combo.ground).dim,
                      width: 320,
                    ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 3),
      Text(words, style: TextStyle(color: Console.ink, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 2),
      Row(children: [
        Text('${(measured * 100).round()}/100', style: Console.label(9)),
        const Spacer(),
        if (mine != null)
          IntrinsicWidth(
            child: Pad(
                label: mine! > 0 ? 'YOURS ${_weightWord(mine!)} · BACK' : 'NEVER · BACK',
                height: 20,
                colour: Console.quiet,
                tooltip: 'Your rule for it taken away: the measuring says again',
                onTap: onBack),
          )
        else ...[
          IntrinsicWidth(
              child: Pad(label: 'LET IT COME', height: 20, colour: Console.a, tooltip: 'In the rotation as the rules say, however it measured', onTap: onCome)),
          const SizedBox(width: 4),
          IntrinsicWidth(child: Pad(label: 'NEVER', height: 20, colour: Console.quiet, tooltip: 'Off for good', onTap: onNever)),
        ],
      ]),
    ]);
  }
}
