// The RULES: every scene, and every style of the three that have them, on every
// background, as pictures — each pair blended on the spot the way the show would put
// them together, with the stage's own blend (shaders/show/under.frag). Judged by eye:
//
//   a tap on a picture: together, or never (the picture stays, faded under a cross,
//   so a pair left out can be brought back);
//   a tap on a branch (a figure with styles, closed or open): every style at once;
//   held, or right-clicked: the pair big, beside every way of blending it — the one
//   tapped is kept for the pair.
//
// What a cell shows is the default way (where the shipped rule has a few, the show
// switches between them record by record; the cell says how many), or the hands'
// own. Ways, scenes, styles and backgrounds switched off (ON/OFF) are gone here too. A branch's
// word holds for its styles until one of them has a word of its own (a dot).
//
// The figures' pictures are baked (test/shots/rule_stills_bake_test.dart,
// assets/show/stills); the backgrounds' are MilkDrop's and the camera's live frame
// where they run, the wash in the record's colours, stand-ins for the rest.
part of 'show_room.dart';

/// The backgrounds across, grouped by what they are like (show_characters.dart's
/// backdrops).
const _gridGrounds = [Ground.milk, Ground.field, Ground.wash, Ground.pulse, Ground.camera, Ground.cover];

/// How dim each background goes under a figure (as the director puts it on).
double _groundDim(Ground g) => switch (g) { Ground.field || Ground.cover => 0.6, Ground.camera => 0.8, _ => 1.0 };

/// The pictures the grid blends, shared by every grid on the page.
class _Stills extends ChangeNotifier {
  _Stills._();
  static final shared = _Stills._();

  final _figures = <String, ui.Image?>{};
  final _grounds = <Ground, ui.Image>{};
  final _loading = <String>{};
  ui.Image? _wash;
  (double, double, double, double, double, double)? _washOf;
  Timer? _live;
  int _users = 0;

  static String nameOf(RigFigure f) => f.style == null ? f.kind.name : '${f.kind.name}.${f.style}';

  /// Whether [f] has no still at all (the dancers' fluid and viewports are drawn on
  /// the native stage only).
  bool missing(RigFigure f) {
    final name = nameOf(f);
    return _figures.containsKey(name) && _figures[name] == null;
  }

  /// The figure's still; null while it loads, or where there is none ([missing]).
  ui.Image? figure(RigFigure f) {
    final name = nameOf(f);
    if (_figures.containsKey(name)) return _figures[name];
    _load(name, 'assets/show/stills/$name.png', (img) => _figures[name] = img);
    return null;
  }

  /// The background's picture: the live one where it runs, else its stand-in; the
  /// wash in [palette]'s colours.
  ui.Image? ground(Ground g, ShowPalette palette) {
    switch (g) {
      case Ground.wash:
        return _washFor(palette);
      case Ground.black:
        return null;
      default:
        final live = _grounds[g];
        if (live != null) return live;
        if (g == Ground.milk) return _milk ??= _milkStandIn();
        final asset = switch (g) {
          Ground.field => 'assets/show/thumbs/drift.webp',
          Ground.pulse => 'assets/show/thumbs/pulse-grid.webp',
          Ground.cover => 'assets/brand/ball.webp',
          _ => 'assets/show/siebenschlaefer/photos/00.webp',
        };
        _load('ground.${g.name}', asset, (img) {
          if (img != null) _grounds[g] = img;
        });
        return null;
    }
  }

  void _load(String key, String asset, void Function(ui.Image?) put) {
    if (!_loading.add(key)) return;
    unawaited(() async {
      // Never back within the build that asked (a missing asset fails at once).
      await Future<void>.value();
      ui.Image? img;
      try {
        final data = await rootBundle.load(asset);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        img = (await codec.getNextFrame()).image;
      } catch (_) {
        img = null;
      }
      put(img);
      notifyListeners();
    }());
  }

  ui.Image? _milk;

  /// MilkDrop's picture while it is not running: a preset's sort of picture — busy,
  /// saturated, swirling colour on dark (its thumbnail is a pale one, which would
  /// show every blend washed out).
  static ui.Image _milkStandIn() {
    const w = 160.0, h = 90.0;
    final r = ui.PictureRecorder();
    final c = Canvas(r)..drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xff0a0620));
    for (final (x, y, rad, col) in const [
      (30.0, 25.0, 55.0, Color(0xffe0207a)),
      (120.0, 30.0, 50.0, Color(0xff20c0e0)),
      (80.0, 70.0, 45.0, Color(0xfff0a020)),
      (140.0, 80.0, 35.0, Color(0xff7030f0)),
      (15.0, 80.0, 30.0, Color(0xff30e070)),
    ]) {
      c.drawCircle(
        Offset(x, y),
        rad,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(Offset(x, y), rad, [col.withValues(alpha: 0.85), col.withValues(alpha: 0)]),
      );
    }
    // A preset's rings.
    for (var i = 1; i <= 5; i++) {
      c.drawCircle(
          const Offset(w / 2, h / 2),
          i * 11.0,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0x55ffffff));
    }
    final pic = r.endRecording();
    final img = pic.toImageSync(w.toInt(), h.toInt());
    pic.dispose();
    return img;
  }

  ui.Image _washFor(ShowPalette pal) {
    final a = pal.primary.toColor(), b = pal.secondary.toColor();
    final key = (a.r, a.g, a.b, b.r, b.g, b.b);
    final had = _wash;
    if (had != null && key == _washOf) return had;
    const w = 64, h = 36;
    final r = ui.PictureRecorder();
    Canvas(r).drawRect(
      const Rect.fromLTWH(0, 0, 64, 36),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 36), [
          Color.fromARGB(255, (a.r * 56).round(), (a.g * 56).round(), (a.b * 56).round()),
          Color.fromARGB(255, (b.r * 31).round(), (b.g * 31).round(), (b.b * 31).round()),
        ]),
    );
    final pic = r.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    _wash = img;
    _washOf = key;
    return img;
  }

  /// A grid on the page: MilkDrop's and the camera's frames taken every couple of
  /// seconds while one is.
  void hold() {
    if (_users++ == 0) {
      scheduleMicrotask(_take);
      _live = Timer.periodic(const Duration(seconds: 2), (_) => _take());
    }
  }

  void release() {
    if (--_users == 0) {
      _live?.cancel();
      _live = null;
    }
  }

  void _take() {
    var changed = false;
    for (final (g, frame) in [(Ground.milk, MilkFeed.shared.frame), (Ground.camera, CameraFeed.shared.running ? CameraFeed.shared.frame : null)]) {
      if (frame == null) continue;
      _grounds[g] = frame.clone();
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

/// A figure's picture blended with a background's, the stage's way, drawn once and
/// kept until one of them (or the way) changes.
class _Blended extends StatefulWidget {
  const _Blended(
      {required this.program, required this.figure, required this.ground, required this.blend, required this.coverage, required this.dim, required this.width});
  final ui.FragmentProgram program;
  final ui.Image? figure, ground;
  final RigBlend blend;
  final bool coverage;
  final double dim;

  /// The picture's width in pixels (16:9).
  final int width;

  @override
  State<_Blended> createState() => _BlendedState();
}

class _BlendedState extends State<_Blended> {
  late final ui.FragmentShader _shader = widget.program.fragmentShader();
  ui.Image? _out;

  @override
  void initState() {
    super.initState();
    _compose();
  }

  @override
  void didUpdateWidget(_Blended old) {
    super.didUpdateWidget(old);
    final w = widget;
    if (w.figure != old.figure || w.ground != old.ground || w.blend != old.blend || w.coverage != old.coverage || w.dim != old.dim || w.width != old.width) {
      _compose();
    }
  }

  void _compose() {
    final w = widget;
    final fig = w.figure;
    _out?.dispose();
    _out = null;
    if (fig == null) return;
    final pw = w.width, ph = (w.width * 9 / 16).round();
    final ground = w.ground ?? fig;
    final mode = w.ground == null ? GroundMode.over : w.blend.ground;
    _shader
      ..setFloat(0, pw.toDouble())
      ..setFloat(1, ph.toDouble())
      ..setFloat(2, mode.index.toDouble())
      ..setFloat(3, 0)
      ..setFloat(4, 0)
      ..setFloat(5, 0)
      ..setFloat(6, 0)
      ..setFloat(7, w.blend.figure.index.toDouble())
      ..setFloat(8, w.coverage ? 1 : 0)
      ..setFloat(9, w.blend.strength)
      ..setFloat(10, ground.width / ground.height)
      ..setFloat(11, w.dim)
      ..setImageSampler(0, fig)
      ..setImageSampler(1, ground);
    final r = ui.PictureRecorder();
    Canvas(r).drawRect(Rect.fromLTWH(0, 0, pw.toDouble(), ph.toDouble()), Paint()..shader = _shader);
    final pic = r.endRecording();
    _out = pic.toImageSync(pw, ph);
    pic.dispose();
  }

  @override
  void dispose() {
    _out?.dispose();
    _shader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _out == null ? ColoredBox(color: Console.ground) : RawImage(image: _out, fit: BoxFit.cover);
}

/// What a cell shows for [f] on [g]: the way it goes together — or, where it is
/// never, the way it would if it were.
RigBlend _cellBlend(ShowPool pool, RigFigure f, Ground g) {
  final a = pool.answer(f, g);
  return (a.never ? pool.withTogether(f, g, true) : pool).blendFor(f, g);
}

/// The way's name in a word.
String _wayWord(GroundMode m) => m == GroundMode.over ? 'as drawn' : m.name;

/// A row of the grid: a figure (a branch where it has styles) or one of its styles.
typedef _Row = ({String name, RigFigure figure, List<String> styles});

class _RulesTab extends StatefulWidget {
  const _RulesTab({required this.show, required this.kit, this.big = false});
  final ShowEngine show;
  final StageKit? kit;

  /// The grid on its own, over the whole window.
  final bool big;

  @override
  State<_RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<_RulesTab> {
  ShowEngine get show => widget.show;
  ShowPool? _pool;
  Object? _now;
  Object? _palette;

  @override
  void initState() {
    super.initState();
    _Stills.shared.hold();
    _Stills.shared.addListener(_redraw);
    show.addListener(_heard);
  }

  @override
  void dispose() {
    show.removeListener(_heard);
    _Stills.shared.removeListener(_redraw);
    _Stills.shared.release();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  /// The show says something every frame: the grid is drawn again only where the
  /// rules, the pair on the stage or the record's colours changed.
  void _heard() {
    final pair = _pairOn(show);
    final now = pair == null ? null : (pair.$1.kind, pair.$1.style, pair.$2);
    final pal = show.state.palette;
    final palette = (pal.primary.toColor(), pal.secondary.toColor());
    if (identical(show.pool, _pool) && now == _now && palette == _palette) return;
    _pool = show.pool;
    _now = now;
    _palette = palette;
    _redraw();
  }

  Set<String> _open() {
    final v = show.doc.panel['rulesOpen'];
    return v is List ? {for (final x in v) '$x'} : {'dancers'};
  }

  void _toggle(String kind) {
    final open = _open();
    open.contains(kind) ? open.remove(kind) : open.add(kind);
    show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'rulesOpen': open.toList()}));
    _redraw();
  }

  /// The rows: each figure once (where a scene of it is switched on), and the styles
  /// switched on of an opened one.
  List<_Row> _rows(SceneBook book, Set<String> open, ShowPool pool) {
    final rows = <_Row>[];
    final seen = <Figure>{};
    for (final s in book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name))) {
      final k = s.look.rig.figure.kind;
      if (k == Figure.none || !pool.isOn('look.${s.id}') || !seen.add(k)) continue;
      final styles = [
        for (final st in _stylesOf(k))
          if (pool.styleOn(k, st)) st
      ];
      rows.add(
          (name: k == Figure.room && pool.isOn('look.fold') && pool.isOn('look.echo') ? 'Echo · Fold' : s.name, figure: RigFigure(kind: k), styles: styles));
      if (styles.isNotEmpty && open.contains(k.name)) {
        for (final st in styles) {
          rows.add((name: st, figure: RigFigure(kind: k, style: st), styles: const []));
        }
      }
    }
    return rows;
  }

  Future<void> _openBig(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          backgroundColor: Console.panel,
          child: Padding(padding: const EdgeInsets.all(16), child: _RulesTab(show: show, kit: widget.kit, big: true)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    if (kit == null) return const SizedBox.shrink();
    final book = kit.book;
    final pool = show.pool;
    final open = _open();
    final rows = _rows(book, open, pool);
    // The backgrounds switched off are gone from here too.
    final grounds = [
      for (final g in _gridGrounds)
        if (pool.isOn('ground.${g.name}')) g
    ];
    final pair = _pairOn(show);
    final mine = pool.combos.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final label = widget.big ? 190.0 : 150.0;
    return LayoutBuilder(builder: (context, c) {
      final cell = math.max(48.0, (c.maxWidth - label - 4) / math.max(1, grounds.length));
      final px = (cell * MediaQuery.devicePixelRatioOf(context)).round().clamp(96, 480);
      final groups = <(Backdrop?, List<Ground>)>[];
      for (final g in grounds) {
        final b = pool.backdropOf(g);
        if (groups.isNotEmpty && groups.last.$1 == b) {
          groups.last.$2.add(g);
        } else {
          groups.add((b, [g]));
        }
      }
      return ListView(key: const ValueKey('rules'), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(
              'Every scene on every background, blended as the show would by default. Tap a picture: together or never (crossed out, still shown). '
              'Tap a scene\'s row of styles: all of them at once. Hold a picture: every way to blend it. A dot is your change.',
              style: TextStyle(fontSize: 11, color: Console.quiet, height: 1.35),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.big)
            IntrinsicWidth(child: Pad(label: 'DONE', height: 26, colour: Console.a, onTap: () => Navigator.of(context).pop()))
          else
            Pad(
                icon: Icons.open_in_full,
                width: 26,
                height: 26,
                colour: Console.quiet,
                tooltip: 'The grid over the whole window',
                onTap: () => unawaited(_openBig(context))),
        ]),
        const SizedBox(height: 8),
        // The backgrounds across, by what they are like.
        Row(children: [
          SizedBox(width: label),
          for (final (b, gs) in groups)
            SizedBox(
              width: cell * gs.length,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Console.line))),
                child: Text((b?.title ?? '').toUpperCase(), textAlign: TextAlign.center, style: Console.label(8, color: Console.quiet)),
              ),
            ),
        ]),
        const SizedBox(height: 3),
        Row(children: [
          SizedBox(width: label),
          for (final g in grounds) SizedBox(width: cell, child: Text(_groundWord(g), textAlign: TextAlign.center, style: Console.label(8, color: Console.ink))),
        ]),
        const SizedBox(height: 4),
        for (final row in rows)
          Row(children: [
            SizedBox(width: label, child: _rowLabel(row, open)),
            for (final g in grounds)
              SizedBox(
                width: cell,
                child: _Cell(
                  show: show,
                  program: kit.programs.under,
                  row: row,
                  ground: g,
                  px: px,
                  now: pair != null && pair.$2 == g && pair.$1.kind == row.figure.kind && (row.figure.style == null || pair.$1.style == row.figure.style),
                ),
              ),
          ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('YOUR CHANGES · ${mine.length}', style: Console.label(10, color: Console.ink))),
          if (mine.isNotEmpty)
            IntrinsicWidth(
              child: Pad(
                  label: 'BACK TO THE DEFAULTS',
                  height: 22,
                  colour: Console.quiet,
                  tooltip: 'Forget every change of yours here',
                  onTap: () => show.setPool(pool.copyWith(combos: const {}))),
            ),
        ]),
        const SizedBox(height: 4),
        if (mine.isEmpty) Text('none — everything as it came', style: TextStyle(fontSize: 11, color: Console.faint)),
        for (final e in mine)
          Row(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '${_keyWords(e.key, book)}  ', style: TextStyle(color: Console.ink)),
                    TextSpan(
                      text: e.value.follow
                          ? 'its exception off: as the rule says'
                          : e.value.off
                              ? 'never'
                              : 'together, ${_wayWord(e.value.ground ?? ShowPool.defaultMode)}',
                      style: TextStyle(color: Console.a),
                    ),
                  ]),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ),
            Pad(
                icon: Icons.close,
                width: 22,
                height: 22,
                colour: Console.quiet,
                tooltip: 'Undo this change',
                onTap: () => show.setPool(pool.withCombo(e.key, null))),
          ]),
      ]);
    });
  }

  Widget _rowLabel(_Row row, Set<String> open) {
    final k = row.figure.kind;
    if (row.styles.isEmpty) {
      final style = row.figure.style != null;
      return Padding(
        padding: EdgeInsets.only(left: style ? 20 : 0, right: 6),
        child: Text(row.name,
            style: TextStyle(fontSize: style ? 11 : 11.5, color: style ? Console.quiet : Console.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    final opened = open.contains(k.name);
    return InkWell(
      onTap: () => _toggle(k.name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(opened ? Icons.expand_more : Icons.chevron_right, size: 15, color: Console.quiet),
          Flexible(
            child: Text(opened ? '${row.name} · every style' : '${row.name} · ${row.styles.length} styles',
                style: TextStyle(fontSize: 11.5, color: Console.ink, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
    );
  }
}

/// One picture of the grid: the pair blended, crossed out where it is never, a dot
/// for your word, a ring for what is on the stage; a branch's says how many of its
/// styles go.
class _Cell extends StatelessWidget {
  const _Cell({required this.show, required this.program, required this.row, required this.ground, required this.px, required this.now});
  final ShowEngine show;
  final ui.FragmentProgram program;
  final _Row row;
  final Ground ground;
  final int px;
  final bool now;

  @override
  Widget build(BuildContext context) {
    final pool = show.pool;
    final f = row.figure;
    final g = ground;
    final a = pool.answer(f, g);
    final branch = row.styles.isNotEmpty;
    final kids = [for (final s in row.styles) RigFigure(kind: f.kind, style: s)];
    final going = kids.where((k) => !pool.answer(k, g).never).length;
    final together = branch ? !a.never && going == kids.length : !a.never;
    final none = branch ? a.never && going == 0 : a.never;
    final mine = pool.combos.containsKey(ShowPool.comboKey(f, g));
    final blend = _cellBlend(pool, f, g);
    final ways = a.from == RuleFrom.rule && !a.never ? (shippedWays[a.key] ?? const []) : const <GroundMode>[];
    final stills = _Stills.shared;
    final name = f.style ?? row.name;
    final tip = StringBuffer('$name on ${_groundWord(g)}: ')
      ..write(branch
          ? (together ? 'together, every style' : (none ? 'never, any style' : '$going of ${kids.length} styles together'))
          : (together
              ? 'together, ${_wayWord(blend.ground)}${ways.length > 1 ? ' (by default it switches between ${ways.map(_wayWord).join(', ')}, record by record)' : ''}'
              : 'never'))
      ..write(mine ? ' (your change)' : '')
      ..write(' — a tap: ${together ? 'never' : 'together'}${branch ? ' (every style)' : ''} · held: the ways to blend it');
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        message: tip.toString(),
        waitDuration: const Duration(milliseconds: 600),
        triggerMode: TooltipTriggerMode.manual,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            feel(Feel.pick);
            show.setPool(branch ? pool.withBranch(f.kind, row.styles, g, !together) : pool.withTogether(f, g, !together));
          },
          onLongPress: () => unawaited(_pickWay(context)),
          onSecondaryTap: () => unawaited(_pickWay(context)),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: now ? Console.b : (mine ? Console.a : Console.line), width: now || mine ? 2 : 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(fit: StackFit.expand, children: [
                    Opacity(
                      opacity: none ? 0.28 : (together ? 1 : 0.7),
                      child: _Blended(
                        program: program,
                        figure: stills.figure(f),
                        ground: stills.ground(g, show.state.palette),
                        blend: blend,
                        coverage: f.kind == Figure.words,
                        dim: _groundDim(g),
                        width: px,
                      ),
                    ),
                    if (stills.missing(f))
                      Center(
                          child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text('no picture — drawn on the full stage only',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 9.5, color: Console.quiet, height: 1.2)),
                      )),
                    if (none) Center(child: Icon(Icons.close, size: 22, color: Colors.white.withValues(alpha: 0.75))),
                    if (branch && !together && !none) Positioned(left: 3, top: 3, child: _Badge('$going/${kids.length}')),
                    if (!none && px >= 140)
                      Positioned(left: 3, bottom: 2, child: _Badge('${_wayWord(blend.ground)}${ways.length > 1 ? ' +${ways.length - 1}' : ''}')),
                    if (mine)
                      Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(color: Console.a, shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 1)))),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickWay(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => _WayPicker(show: show, program: program, figure: row.figure, ground: ground, name: row.figure.style ?? row.name),
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(3)),
        child: Text(text, style: const TextStyle(fontSize: 9, color: Colors.white, height: 1.2)),
      );
}

/// A pair held: the pair big, and beside it every way of blending the two; a tap
/// keeps that way for the pair (together, if it was never).
class _WayPicker extends StatelessWidget {
  const _WayPicker({required this.show, required this.program, required this.figure, required this.ground, required this.name});
  final ShowEngine show;
  final ui.FragmentProgram program;
  final RigFigure figure;
  final Ground ground;
  final String name;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Console.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListenableBuilder(
            listenable: Listenable.merge([show, _Stills.shared]),
            builder: (context, _) {
              final pool = show.pool;
              final f = figure, g = ground;
              final a = pool.answer(f, g);
              final key = ShowPool.comboKey(f, g);
              final mine = pool.combos[key];
              final blend = _cellBlend(pool, f, g);
              final ways = pool.blendsFor(f, g);
              final shipped = pool.asShipped(f, g);
              final shippedWaysHere = [
                ...(shipped.from == RuleFrom.rule
                    ? (shippedWays[shipped.key] ?? const <GroundMode>[])
                    : [if (shipped.rule.ground != null) shipped.rule.ground!]),
              ].where(pool.blendOn).toList();
              final stills = _Stills.shared;
              Widget picture(RigBlend b, int px) => _Blended(
                    program: program,
                    figure: stills.figure(f),
                    ground: stills.ground(g, show.state.palette),
                    blend: b,
                    coverage: f.kind == Figure.words,
                    dim: _groundDim(g),
                    width: px,
                  );
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Expanded(child: Text('$name on ${_groundWord(g)}', style: TextStyle(fontSize: 15, color: Console.ink, fontWeight: FontWeight.w700))),
                    IntrinsicWidth(
                      child: Pad(
                        label: a.never ? 'NEVER · TAP: TOGETHER' : 'TOGETHER · TAP: NEVER',
                        height: 26,
                        lit: !a.never,
                        colour: Console.a,
                        onTap: () => show.setPool(pool.withTogether(f, g, a.never)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IntrinsicWidth(child: Pad(label: 'DONE', height: 26, colour: Console.quiet, onTap: () => Navigator.of(context).pop())),
                  ]),
                  const SizedBox(height: 10),
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Opacity(opacity: a.never ? 0.4 : 1, child: picture(blend, 640))),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    a.never
                        ? 'Never together now — a way tapped below puts them together that way.'
                        : mine?.ground != null
                            ? 'Yours: always ${_wayWord(blend.ground)}. BACK TO DEFAULT forgets it.'
                            : shippedWaysHere.length > 1
                                ? 'Default: the show switches between ${shippedWaysHere.map(_wayWord).join(', ')}, record by record. Tap one to always use that one.'
                                : 'Default: ${shippedWaysHere.map(_wayWord).join()}. Tap another to use that one instead.',
                    style: TextStyle(fontSize: 11.5, color: Console.quiet),
                  ),
                  const SizedBox(height: 12),
                  Text('EVERY WAY', style: Console.label(10, color: Console.ink)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final m in ways)
                      Builder(builder: (context) {
                        final on = !a.never && blend.ground == m;
                        return InkWell(
                          onTap: () {
                            feel(Feel.pick);
                            show.setPool(pool.withBlend(f, g, m));
                          },
                          child: Container(
                            width: 150,
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: on ? Console.a : Console.line, width: on ? 2 : 1),
                            ),
                            child: Column(children: [
                              AspectRatio(
                                aspectRatio: 16 / 9,
                                child: ClipRRect(borderRadius: BorderRadius.circular(4), child: picture(blend.copyWith(ground: m), 240)),
                              ),
                              const SizedBox(height: 3),
                              Text('${_wayWord(m)}${shippedWaysHere.contains(m) ? ' · default' : ''}',
                                  style: Console.label(8.5, color: on ? Console.a : Console.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ]),
                          ),
                        );
                      }),
                  ]),
                  if (mine != null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IntrinsicWidth(
                        child: Pad(
                            label: 'BACK TO DEFAULT',
                            height: 24,
                            colour: Console.quiet,
                            tooltip: 'Forget your word on this pair',
                            onTap: () => show.setPool(pool.withCombo(key, null))),
                      ),
                    ),
                  ],
                ]),
              );
            },
          ),
        ),
      );
}
