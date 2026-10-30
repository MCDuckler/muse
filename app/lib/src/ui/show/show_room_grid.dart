// A scene's looks as a grid: its styles down, the backgrounds across (the ones on
// first; the rest folded), each square the scene in that style on that background —
// every mask, blend and effect of it — blended the stage's way (its likeliest mask
// and blend), with its share of the scene's time. Marked: ✕ never (the hands'), hatched cut by the measuring, ½ / 2×
// the hands' less and more, a tick for each NEXT that skipped it, a dot on the stage
// now. A tap: never, or back (out of a wider never, through the measuring); a right
// click or a long press: less, more, as it was, let it come however it measured, play
// it, and its masks, blends and effects one by one.
//
// A world of its own (MilkDrop alone, the dormouse, the disco floor…) is one square a
// style: on its own background, nothing to blend.
part of 'show_room.dart';

/// What one square stands for: its looks (twelve, or one for a world) and how they
/// come.
class _Square {
  _Square(this.looks, this.plan, this.shares, this.scene, {this.here = true});
  final List<Combo> looks;
  final ShowPlan plan;
  final PlanShares shares;
  final String scene;

  /// Its background is here now (the camera on, a record's cover): else nothing of
  /// it can come now, and nothing is said of its measuring.
  final bool here;

  late final share = looks.fold(0.0, (t, c) => t + (shares.looksOf(scene)[c] ?? 0));

  /// Every look's levels say none (its style, its background… is off).
  late final levelsOff = looks.every((c) => plan.baseWeight(c) <= 0);

  /// The hands said never to all of them (a cell at 0), the levels aside.
  late final never = !levelsOff && looks.where((c) => plan.baseWeight(c) > 0).every((c) => plan.cellsFor(c) <= 0);

  /// Some of them never, by the hands.
  late final someNever = !never && looks.any((c) => plan.baseWeight(c) > 0 && plan.cellsFor(c) <= 0);

  /// The measuring keeps all of the rest out.
  late final cut = here && !levelsOff && !never && share <= 0;

  /// The measuring keeps some out.
  late final someCut = here && !cut && looks.any((c) => plan.lookWeight(c) > 0 && (shares.looksOf(scene)[c] ?? 0) <= 0);

  late final allowed = looks.any(plan.allowed);

  /// The likeliest of them (the one the square's picture shows).
  late final Combo face = () {
    final by = shares.looksOf(scene);
    var best = looks.first;
    var w = -1.0;
    for (final c in looks) {
      final x = (by[c] ?? 0) * 1000 + plan.baseWeight(c);
      if (x > w) {
        w = x;
        best = c;
      }
    }
    return best;
  }();
}

class _LooksGrid extends StatefulWidget {
  const _LooksGrid({required this.show, required this.kit, required this.scene, required this.kind, required this.shares});
  final ShowEngine show;
  final StageKit kit;
  final String scene;
  final Figure kind;
  final PlanShares shares;

  @override
  State<_LooksGrid> createState() => _LooksGridState();
}

class _LooksGridState extends State<_LooksGrid> {
  /// The styles and backgrounds that are off shown too.
  bool _all = false;

  ShowEngine get show => widget.show;
  String get scene => widget.scene;

  static const _nameW = 92.0;

  /// A square's size: the room shared between the backgrounds shown, within reason.
  double _cellW = 104, _cellH = 76;

  List<Combo> _looksOf(String style, String ground) {
    if (isWorld(scene, widget.kind, style)) return [for (final f in Fx.values) Combo(ground: ownGround, scene: scene, style: style, fx: f)];
    return [
      for (final m in Mask.values)
        for (final x in Mix.values)
          for (final f in Fx.values) Combo(ground: ground, scene: scene, style: style, mask: m, mix: x, fx: f),
    ];
  }

  String _keyOf(String style, String ground) => cellKey(style: style, ground: ground);

  /// A square tapped: never — or, never or cut already, back.
  void _toggle(_Square sq, String style, String ground) {
    final plan = show.pool.plan;
    final key = _keyOf(style, ground);
    final styles = stylesOfFigure(widget.kind);
    if (sq.levelsOff) {
      ScaffoldMessenger.of(context).say(snack(Text(
          '${style == 'raw' ? 'This style' : style} on ${_groundName(ground)} is off by its levels: turn the style${ground == ownGround ? '' : ' and the background'} on above')));
      return;
    }
    feel(Feel.pick);
    if (sq.never || sq.cut) {
      var p = plan;
      if (sq.never) p = p.withUnvetoed(scene, key, styles);
      if (sq.cut) p = p.withAllow(scene, key, true);
      show.setPlan(p);
    } else {
      show.setPlan(plan.withCell(scene, key, 0));
    }
  }

  Future<void> _menu(_Square sq, String style, String ground, Offset at) async {
    final plan = show.pool.plan;
    final key = _keyOf(style, ground);
    final cell = plan.of(scene).cells[key];
    final world = ground == ownGround;
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        PopupMenuItem(
            value: 'play',
            child: Text('Play it now${world ? '' : ' (${_maskName(sq.face.mask).toLowerCase()} · ${_mixName(sq.face.mix).toLowerCase()}'}'
                '${sq.face.fx == Fx.none ? '' : '${world ? ' (' : ' · '}${_fxName(sq.face.fx).toLowerCase()}'}${world && sq.face.fx == Fx.none ? '' : ')'}')),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'less', enabled: !sq.levelsOff, child: Text('Less (×½)${cell != null && cell > 0 ? ' — now ${levelWord(cell)}' : ''}')),
        PopupMenuItem(value: 'more', enabled: !sq.levelsOff, child: const Text('More (×2)')),
        PopupMenuItem(value: 'never', enabled: !sq.levelsOff && !sq.never, child: const Text('Never')),
        if (cell != null || sq.never || sq.someNever || sq.allowed) const PopupMenuItem(value: 'back', child: Text('As it was: the levels alone')),
        if (!sq.allowed && (sq.cut || sq.someCut)) const PopupMenuItem(value: 'allow', child: Text('Let it come however it measured')),
        if (sq.allowed) const PopupMenuItem(value: 'measure', child: Text('Measured again: the ugly ones out')),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'each', child: Text(world ? 'Each effect…' : 'Each mask, blend and effect…')),
      ],
    );
    if (pick == null || !mounted) return;
    final styles = stylesOfFigure(widget.kind);
    switch (pick) {
      case 'play':
        show.play(sq.face);
      case 'less':
        show.setPlan(plan.scaleCell(scene, key, 0.5));
      case 'more':
        show.setPlan(plan.withUnvetoed(scene, key, styles).scaleCell(scene, key, 2));
      case 'never':
        show.setPlan(plan.withCell(scene, key, 0));
      case 'back':
        var p = plan.withUnvetoed(scene, key, styles).withAllow(scene, key, false);
        // The cells inside this square go too.
        for (final k in p.of(scene).cells.keys.toList()) {
          if (cellCovers(key, k)) p = p.withCell(scene, k, null);
        }
        show.setPlan(p);
      case 'allow':
        show.setPlan(plan.withAllow(scene, key, true));
      case 'measure':
        show.setPlan(plan.withAllow(scene, key, false));
      case 'each':
        await showDialog<void>(context: context, builder: (context) => _Variants(show: show, kit: widget.kit, scene: scene, kind: widget.kind, style: style, ground: ground));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = show.pool.plan;
    final shares = widget.shares;
    final kind = widget.kind;
    final world = worldScenes.contains(scene) || kind == Figure.none;
    final here = show.groundsHere();
    final allStyles = stylesOfFigure(kind);
    final allGrounds = world ? [ownGround] : comboGrounds;
    bool styleOn(String st) => plan.levelIn(scene, PlanAxis.style, st) > 0;
    bool groundOn(String g) => g == ownGround || plan.levelIn(scene, PlanAxis.ground, g) > 0;
    final styles = [for (final st in allStyles) if (_all || styleOn(st)) st];
    final grounds = [for (final g in allGrounds) if (_all || groundOn(g)) g];
    final hidden = allStyles.length - styles.length + allGrounds.length - grounds.length;
    final live = show.combo?.scene == scene ? show.combo : null;
    final skips = show.doc.taste;
    final cols = math.max(1, grounds.length);
    return LayoutBuilder(builder: (context, c) {
      _cellW = ((c.maxWidth - _nameW) / cols - 4).clamp(104.0, 220.0);
      _cellH = _cellW * 9 / 16 + 18;
      return _grid(plan, shares, kind, world, here, styles, grounds, hidden, live, skips, styleOn, groundOn);
    });
  }

  Widget _grid(ShowPlan plan, PlanShares shares, Figure kind, bool world, Set<String> here, List<String> styles, List<String> grounds, int hidden, Combo? live,
      Map<String, double> skips, bool Function(String) styleOn, bool Function(String) groundOn) {
    // A world style in a scene that has backgrounds: its one square in the first column.
    final grid = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const SizedBox(width: _nameW),
        for (final g in grounds)
          SizedBox(
            width: _cellW + 4,
            child: Text(
              g == ownGround ? 'its own' : _groundName(g),
              style: Console.label(8.5, color: !groundOn(g) ? Console.faint : (here.contains(g) || g == ownGround ? Console.ink : Console.quiet)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ]),
      const SizedBox(height: 4),
      for (final st in styles)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            SizedBox(
              width: _nameW,
              child: Text(st == 'raw' ? 'as drawn' : st, style: TextStyle(fontSize: 11.5, color: styleOn(st) ? Console.ink : Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (isWorld(scene, kind, st) && !world)
              _squareAt(plan, shares, st, ownGround, live, skips, note: 'a world of its own')
            else
              for (final g in grounds) _squareAt(plan, shares, st, g, live, skips),
          ]),
        ),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: grid),
      if (hidden > 0 || _all)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _all = !_all),
            child: Text(_all ? 'only the styles and backgrounds that are on' : 'the $hidden styles and backgrounds that are off too', style: const TextStyle(fontSize: 11.5)),
          ),
        ),
      const _GridLegend(),
    ]);
  }

  Widget _squareAt(ShowPlan plan, PlanShares shares, String style, String ground, Combo? live, Map<String, double> skips, {String? note}) {
    final sq = _Square(_looksOf(style, ground), plan, shares, scene, here: ground == ownGround || show.groundsHere().contains(ground));
    final cell = plan.of(scene).cells[_keyOf(style, ground)];
    final skipped = sq.looks.fold(0.0, (t, c) => t + (skips[c.key] ?? 0)).round();
    final isLive = live != null && live.style == style && (live.ground == ground || (ground == ownGround && live.world));
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: _SquareView(
        key: ValueKey('look:$style|$ground'),
        square: sq,
        kit: widget.kit,
        kind: widget.kind,
        palette: show.state.palette,
        cell: cell,
        skipped: skipped,
        live: isLive,
        note: note,
        width: _cellW,
        height: _cellH,
        onTap: () => _toggle(sq, style, ground),
        onMenu: (at) => unawaited(_menu(sq, style, ground, at)),
      ),
    );
  }
}

/// One square: its picture, its share, its marks.
class _SquareView extends StatelessWidget {
  const _SquareView({
    super.key,
    required this.square,
    required this.kit,
    required this.kind,
    required this.palette,
    required this.width,
    required this.height,
    required this.onTap,
    required this.onMenu,
    this.cell,
    this.skipped = 0,
    this.live = false,
    this.note,
  });
  final _Square square;
  final StageKit kit;
  final Figure kind;
  final ShowPalette palette;
  final double width, height;
  final double? cell;
  final int skipped;
  final bool live;
  final String? note;
  final VoidCallback onTap;
  final void Function(Offset at) onMenu;

  @override
  Widget build(BuildContext context) {
    final sq = square;
    final c = sq.face;
    final stills = _Stills.shared;
    final fig = stills.figure(kind, c.style);
    final dead = sq.levelsOff || sq.never;
    final picture = fig == null
        ? Center(child: Text(stills.missing(kind, c.style) ? 'native only' : '', style: TextStyle(fontSize: 9, color: Console.quiet)))
        : _Blended(
            program: kit.programs.under,
            figure: fig,
            ground: stills.ground(c.ground, palette),
            blend: c.world ? RigBlend.normal : RigBlend(mask: c.mask, mix: c.mix),
            coverage: _stillCoverage(kind, c.style),
            dim: groundOfKey(c.ground).dim,
            width: 192,
          );
    final tip = [
      _comboWords(c, kit.book),
      if (note != null) note!,
      if (sq.levelsOff) 'off by its levels (the style or the background)',
      if (sq.never) 'never: the hands said so — tap to let it come',
      if (sq.someNever) 'some of its masks and blends never',
      if (sq.cut) 'cut by the measuring — tap to let it come however it measured',
      if (sq.someCut) 'some of its masks and blends cut by the measuring',
      if (cell != null && cell! > 0) '${levelWord(cell!)} by the hands',
      if (sq.allowed) 'comes however it measured',
      if (skipped > 0) 'skipped with NEXT $skipped×',
      if (!sq.here) 'not here now (the camera off, no cover): nothing of it comes now',
      if (!dead && sq.here) '${shareWord(sq.share)} of the scene\'s time',
      'tap: ${dead || sq.cut ? 'let it come' : 'never'} · right-click or hold: more',
    ].join('\n');
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        onLongPressStart: (d) => onMenu(d.globalPosition),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Console.raised,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: live ? Console.b : Console.line, width: live ? 1.5 : 1),
            ),
            padding: const EdgeInsets.all(2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(fit: StackFit.expand, children: [
                    Opacity(opacity: dead ? 0.18 : (sq.cut ? 0.45 : 1), child: ColoredBox(color: Colors.black, child: picture)),
                    if (sq.cut) CustomPaint(painter: _HatchPainter()),
                    if (sq.never) Center(child: Icon(Icons.close, size: 26, color: Console.a)),
                    if (cell != null && cell! > 0 && cell != 1)
                      Positioned(right: 2, top: 2, child: _Badge(levelWord(cell!), lit: true)),
                    if (sq.someNever) Positioned(left: 2, top: 2, child: _Badge('part ✕')),
                    if (sq.allowed) Positioned(left: 2, bottom: 2, child: _Badge('allowed')),
                    if (live) Positioned(right: 4, bottom: 4, child: Icon(Icons.circle, size: 8, color: Console.b)),
                  ]),
                ),
              ),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                  child: Text(dead ? (sq.never ? 'never' : 'off') : (!sq.here ? 'not here' : (sq.cut ? 'cut' : shareWord(sq.share))),
                      style: TextStyle(fontSize: 10, color: dead || sq.cut ? Console.faint : Console.ink, fontFeatures: const [ui.FontFeature.tabularFigures()])),
                ),
                if (skipped > 0)
                  Text('${'ı' * math.min(skipped, 5)}${skipped > 5 ? '+' : ''}', style: TextStyle(fontSize: 10, color: Console.quiet, letterSpacing: 1)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.word, {this.lit = false});
  final String word;
  final bool lit;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(3)),
        child: Text(word, style: Console.label(8, color: lit ? Console.a : Console.ink)),
      );
}

class _HatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.clipRect(r);
    final p = Paint()
      ..color = Console.faint
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => false;
}

/// What the grid's marks mean.
class _GridLegend extends StatelessWidget {
  const _GridLegend();

  @override
  Widget build(BuildContext context) {
    Widget key(Widget mark, String word) => Padding(
          padding: const EdgeInsets.only(right: 14, top: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [mark, const SizedBox(width: 5), Text(word, style: TextStyle(fontSize: 10, color: Console.quiet))]),
        );
    return _Flow(children: [
      key(Icon(Icons.close, size: 12, color: Console.a), 'never (yours)'),
      key(SizedBox(width: 14, height: 10, child: CustomPaint(painter: _HatchPainter())), 'cut by the measuring'),
      key(const _Badge('×½', lit: true), 'less / more (yours)'),
      key(Text('ııı', style: TextStyle(fontSize: 10, color: Console.quiet)), 'skipped with NEXT'),
      key(Icon(Icons.circle, size: 8, color: Console.b), 'on the stage now'),
    ]);
  }
}

/// One square's masks and blends under an effect (none to start), each judged on its
/// own; a world's, its effects.
class _Variants extends StatefulWidget {
  const _Variants({required this.show, required this.kit, required this.scene, required this.kind, required this.style, required this.ground});
  final ShowEngine show;
  final StageKit kit;
  final String scene, style, ground;
  final Figure kind;

  @override
  State<_Variants> createState() => _VariantsState();
}

class _VariantsState extends State<_Variants> {
  Fx _fx = Fx.none;

  ShowEngine get show => widget.show;

  Widget _square(Combo c, ShowPlan plan, PlanShares shares, Combo? live, {String? note, double w = 144, double h = 100}) {
    final scene = widget.scene, kind = widget.kind;
    final sq = _Square([c], plan, shares, scene);
    final key = cellOf(c);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: _SquareView(
        square: sq,
        kit: widget.kit,
        kind: kind,
        palette: show.state.palette,
        cell: plan.of(scene).cells[key],
        skipped: (show.doc.taste[c.key] ?? 0).round(),
        live: live == c,
        note: note,
        width: w,
        height: h,
        onTap: () {
          if (sq.levelsOff) return;
          feel(Feel.pick);
          if (sq.never || sq.cut) {
            var p = plan;
            if (sq.never) p = p.withUnvetoed(scene, key, stylesOfFigure(kind));
            if (sq.cut) p = p.withAllow(scene, key, true);
            show.setPlan(p);
          } else {
            show.setPlan(plan.withCell(scene, key, 0));
          }
        },
        onMenu: (at) async {
          final pick = await showMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
            items: const [
              PopupMenuItem(value: 'play', child: Text('Play it now')),
              PopupMenuItem(value: 'less', child: Text('Less (×½)')),
              PopupMenuItem(value: 'more', child: Text('More (×2)')),
              PopupMenuItem(value: 'back', child: Text('As it was')),
            ],
          );
          switch (pick) {
            case 'play':
              show.play(c);
            case 'less':
              show.setPlan(plan.scaleCell(scene, key, 0.5));
            case 'more':
              show.setPlan(plan.withUnvetoed(scene, key, stylesOfFigure(kind)).scaleCell(scene, key, 2));
            case 'back':
              show.setPlan(plan.withUnvetoed(scene, key, stylesOfFigure(kind)).withCell(scene, key, null).withAllow(scene, key, false));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Console.ground,
        child: IntrinsicWidth(
            child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: Listenable.merge([show, _Stills.shared]),
            builder: (context, _) {
              final plan = show.pool.plan;
              final shares = _sharesOf(show);
              final live = show.combo;
              final scene = widget.scene, style = widget.style, ground = widget.ground;
              final world = ground == ownGround;
              final title = '${widget.kit.book[scene]?.name ?? scene} · ${style == 'raw' ? 'as drawn' : style}${world ? '' : ' on ${_groundName(ground)}'}';
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Console.label(12, color: Console.ink)),
                const SizedBox(height: 4),
                Text(world ? 'each effect · tap: never, or back · right-click: less, more, play it' : 'each mask and blend, under the effect picked · tap: never, or back · right-click: less, more, play it',
                    style: TextStyle(fontSize: 11, color: Console.quiet)),
                const SizedBox(height: 10),
                if (world)
                  Row(children: [
                    for (final f in Fx.values)
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_fxName(f), style: Console.label(9, color: Console.ink)),
                        const SizedBox(height: 4),
                        _square(Combo(ground: ownGround, scene: scene, style: style, fx: f), plan, shares, live),
                      ]),
                  ])
                else ...[
                  _Line(children: [
                    Text('EFFECT', style: Console.label(9)),
                    const SizedBox(width: 8),
                    for (final f in Fx.values)
                      _Word(
                        label: '${_fxName(f).toUpperCase()} ${shareWord(shares.looksOf(scene).entries.where((e) => e.key.fx == f && e.key.style == style && e.key.ground == ground).fold(0.0, (t, e) => t + e.value))}',
                        lit: _fx == f,
                        off: plan.levelIn(scene, PlanAxis.fx, f.name) <= 0,
                        tooltip: 'The masks and blends under ${_fxName(f).toLowerCase()} (its share of the scene\'s time with this style on this background)',
                        onTap: () => setState(() => _fx = f),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    const SizedBox(width: 72),
                    for (final x in Mix.values) SizedBox(width: 148, child: Text(_mixName(x), style: Console.label(9, color: Console.ink))),
                  ]),
                  const SizedBox(height: 4),
                  for (final m in Mask.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        SizedBox(width: 72, child: Text(_maskName(m), style: Console.label(9, color: Console.ink))),
                        for (final x in Mix.values)
                          _square(Combo(ground: ground, scene: scene, style: style, mask: m, mix: x, fx: _fx), plan, shares, live,
                              note: plan.takes(ground, m.name) && plan.takes(ground, x.name) ? null : '${_groundName(ground)} does not take this (ROTATION)'),
                      ]),
                    ),
                ],
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))),
              ]);
            },
          ),
        )),
      );
}
