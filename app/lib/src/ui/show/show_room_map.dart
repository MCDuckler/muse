// The MAP tab: the rotation at a glance. Two rows of the selector against each other
// (the scenes down, the backgrounds across, as it opens) as a grid of squares, each as
// bright as the share of the time its combinations get; the squares whose
// combinations are all off hatched, those with some off nicked in the corner; the
// selector's pick outlined, the combination on dotted. The totals of each row and
// column at the edges.
//
// The share is the director's way, roughly: a scene as likely as its lean (the mean
// weight of its combinations that are on), a combination within its scene as likely
// as its weight. The music picks the scene in the end; the hands only lean it.
//
// CAMERA as a row: each combination of the dancers' and the flock's split over its
// framings, by how often the clock reaches for each (counted once, every mood alike)
// times the camera's rules; every other scene's under "No camera".
//
// A square tapped puts its two things in the selector (the other rows kept); ctrl- or
// shift-tapped, adds them. A row's or a column's name, its thing alone.
part of 'show_room.dart';

/// One combination (and a framing of its camera, where it is counted by them): its
/// weight, whether it is on, its share of the time.
typedef _Entry = ({Combo combo, String shot, double weight, bool on, double share});

/// Every combination there is, with its weight and its share of the time.
class _Rotation {
  _Rotation._(this.all, this.grounds, this._rules, this._kinds);
  final List<_Entry> all;
  final List<ComboRule> _rules;
  final Map<String, Figure> _kinds;

  /// Every combination split over its camera's framings (the dancers', the flock's;
  /// the rest whole, with none).
  late final List<_Entry> withShots = [
    for (final o in all) ..._split(o),
  ];

  List<_Entry> _split(_Entry o) {
    final shots = shotsOfFigure(_kinds[o.combo.scene] ?? Figure.none);
    if (shots.isEmpty) return [o];
    final ws = [for (final k in shots) (_baseOdds[k] ?? 0) * shotWeight(o.combo, k, _rules)];
    final sum = ws.fold(0.0, (a, b) => a + b);
    return [
      for (final (i, k) in shots.indexed)
        (
          combo: o.combo,
          shot: k,
          weight: o.weight,
          on: o.on && ws[i] > 0,
          // Every framing at nought: the clock's own fallback (the front, wide).
          share: sum > 0 ? o.share * ws[i] / sum : (i == 0 ? o.share : 0.0),
        ),
    ];
  }

  /// How often the clocks reach for each framing with nothing said: their picks over
  /// many cuts, every mood alike (a solo dancer; a flock in an ordinary look), a
  /// little for one they reach for only otherwise (the wide shot of a big company).
  static final Map<String, double> _baseOdds = () {
    final count = <String, double>{};
    for (final mood in MemeMood.values) {
      for (var cut = 0; cut < 240; cut++) {
        final d = DanceClock.shot(mood, 7, cut, DanceTroupe.solo, art: true);
        final dk = 'dancers.${(d == DanceShot.full ? DanceShot.front : d).name}';
        count[dk] = (count[dk] ?? 0) + 1;
        final fk = 'birds.${FlockClock.shot(mood, 7, cut, FlockLook.embers).name}';
        count[fk] = (count[fk] ?? 0) + 1;
      }
    }
    final out = <String, double>{};
    for (final f in const [Figure.dancers, Figure.birds]) {
      final keys = shotsOfFigure(f);
      final total = keys.fold(0.0, (a, k) => a + (count[k] ?? 0));
      for (final k in keys) {
        out[k] = math.max(0.02, (count[k] ?? 0) / total);
      }
    }
    return out;
  }();

  /// The backgrounds counted (the ones there are now).
  final Set<String> grounds;

  static _Rotation? _last;
  static ShowPool? _lastPool;
  static String? _lastKey;

  static _Rotation of(ShowPool pool, SceneBook book, Set<String> grounds) {
    final key = '${(grounds.toList()..sort()).join(',')}|${book.scenes.length}';
    final last = _last;
    if (last != null && identical(pool, _lastPool) && key == _lastKey) return last;
    final rules = pool.allRules;
    final byScene = <String, List<(Combo, double)>>{};
    final leans = <String, double>{};
    for (final s in book.scenes.values) {
      final list = [
        for (final c in combosOf(s.id, s.look.rig.figure.kind, grounds: comboGrounds.where(grounds.contains))) (c, ComboScores.weigh(c, rules)),
      ];
      byScene[s.id] = list;
      var n = 0, sum = 0.0;
      for (final (_, w) in list) {
        if (w <= 0) continue;
        n++;
        sum += w;
      }
      leans[s.id] = n == 0 ? 0 : sum / n;
    }
    final leanSum = leans.values.fold(0.0, (a, b) => a + b);
    final all = <_Entry>[];
    for (final e in byScene.entries) {
      final within = e.value.fold(0.0, (a, o) => a + math.max(0.0, o.$2));
      final sceneShare = leanSum <= 0 ? 0.0 : leans[e.key]! / leanSum;
      for (final (c, w) in e.value) {
        all.add((combo: c, shot: '', weight: w, on: w > 0, share: w <= 0 || within <= 0 ? 0 : sceneShare * w / within));
      }
    }
    _lastPool = pool;
    _lastKey = key;
    return _last = _Rotation._(all, grounds, rules, {for (final s in book.scenes.values) s.id: s.look.rig.figure.kind});
  }
}

/// One square of the grid: how many combinations, how many on, their share.
class _Cell {
  int n = 0, on = 0;
  double share = 0;
  bool picked = false, live = false;
}

/// The grid of two rows against each other, added up.
class _Grid {
  _Grid(this.rows, this.cols, this.rowValues, this.colValues);
  final ComboAxis rows, cols;
  final List<String> rowValues, colValues;
  late final cells = List.generate(rowValues.length, (_) => List.generate(colValues.length, (_) => _Cell()));
  late final rowTotals = List.filled(rowValues.length, 0.0);
  late final colTotals = List.filled(colValues.length, 0.0);
  int n = 0, on = 0, pickedN = 0, pickedOn = 0;

  /// Counted by framing (a combination of the dancers' or the flock's once per each).
  bool byShot = false;
  double pickedShare = 0;

  double get maxCell {
    var m = 0.0;
    for (final r in cells) {
      for (final c in r) {
        m = math.max(m, c.share);
      }
    }
    return m;
  }

  static _Grid? _last;
  static String? _lastKey;
  static _Rotation? _lastOf;

  static _Grid of(_Rotation rot, SceneBook book, ComboAxis rows, ComboAxis cols, ComboRule pick, bool within, Combo? live) {
    final key = '${rows.name}|${cols.name}|${pick.pattern}|$within|$live|${StylePool.shotNow.values.join(',')}';
    final last = _last;
    if (last != null && identical(rot, _lastOf) && key == _lastKey) return last;
    // Within the pick: only the combinations it says on the other rows.
    final filter = within ? pick.withOn(rows, null).withOn(cols, null) : const ComboRule();
    // Counted by framing where the camera is a row, or the pick says one.
    final byShot = rows == ComboAxis.shot || cols == ComboAxis.shot || pick.camera || filter.camera;
    final entries = byShot ? rot.withShots : rot.all;
    String value(_Entry o, ComboAxis a) => a == ComboAxis.shot ? o.shot : comboValue(o.combo, a);
    bool says(ComboRule r, _Entry o) => r.matches(o.combo) && (r.shots == null || r.shots!.contains(o.shot));
    final present = {for (final a in ComboAxis.values) a: <String>{}};
    for (final o in entries) {
      for (final a in ComboAxis.values) {
        present[a]!.add(value(o, a));
      }
    }
    List<String> values(ComboAxis a) {
      final there = present[a]!;
      final order = switch (a) {
        ComboAxis.scene => [for (final s in _scenesInOrder(book)) s.id],
        ComboAxis.style => _stylesOfScenes(book, within ? pick.scenes : null),
        ComboAxis.ground => [...comboGrounds, ownGround],
        ComboAxis.mask => [for (final m in Mask.values) m.name],
        ComboAxis.mix => [for (final m in Mix.values) m.name],
        ComboAxis.shot => [...allShots, ''],
      };
      return [
        for (final v in order)
          if (there.contains(v) && (!within || a == rows || a == cols || (pick.on(a)?.contains(v) ?? true))) v
      ];
    }

    final g = _Grid(rows, cols, values(rows), values(cols))..byShot = byShot;
    final ri = {for (final (i, v) in g.rowValues.indexed) v: i};
    final ci = {for (final (i, v) in g.colValues.indexed) v: i};
    for (final o in entries) {
      final c = o.combo;
      if (!says(filter, o)) continue;
      final r = ri[value(o, rows)], k = ci[value(o, cols)];
      if (r == null || k == null) continue;
      final cell = g.cells[r][k];
      final isOn = o.on;
      cell.n++;
      g.n++;
      if (isOn) {
        cell.on++;
        g.on++;
      }
      cell.share += o.share;
      g.rowTotals[r] += o.share;
      g.colTotals[k] += o.share;
      if (pick.fields > 0 && says(pick, o)) {
        cell.picked = true;
        g.pickedN++;
        if (isOn) g.pickedOn++;
        g.pickedShare += o.share;
      }
      if (c == live && (o.shot.isEmpty || o.shot == _shotOn(o.shot))) cell.live = true;
    }
    _lastOf = rot;
    _lastKey = key;
    return _last = g;
  }
}

/// The framing on of the figure whose framing [key] is (its clock's last cut).
String? _shotOn(String key) {
  final fig = key.startsWith('birds.') ? Figure.birds : Figure.dancers;
  final now = StylePool.shotNow[fig];
  return now == null ? null : '${fig.name}.$now';
}

/// A thing of a row on the map: a framing with its figure's name (the dancers' and
/// the flock's side by side).
String _mapName(ComboAxis a, String v, SceneBook book) => a == ComboAxis.shot ? _shotName(v, whose: true) : _valueName(a, v, book);

String _percent(double share) {
  final p = share * 100;
  if (p <= 0) return '0 %';
  if (p < 0.1) return '<0.1 %';
  return '${p.toStringAsFixed(p < 10 ? 1 : 0)} %';
}

class _MapTab extends StatefulWidget {
  const _MapTab({required this.show, required this.kit, required this.picked});
  final ShowEngine show;
  final StageKit? kit;
  final ValueNotifier<ComboRule?> picked;

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  ComboAxis _down = ComboAxis.scene, _across = ComboAxis.ground;
  bool _within = false;

  /// The square or the name under the pointer, said in words over the grid.
  final _hover = ValueNotifier<String?>(null);

  ShowEngine get show => widget.show;

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  ComboRule get _pick => widget.picked.value ?? (show.combo == null ? const ComboRule() : _patternOfCombo(show.combo!));

  void _axis(bool rows, ComboAxis a) => setState(() {
        if (rows) {
          if (a == _across) _across = _down;
          _down = a;
        } else {
          if (a == _down) _down = _across;
          _across = a;
        }
      });

  /// A square or a name tapped: its things in the selector (alone, or added to what
  /// the row has).
  void _pickOut(SceneBook book, List<(ComboAxis, String)> things) {
    var p = _pick;
    final add = _adding;
    for (final (a, v) in things) {
      p = _putRow(p, a, add ? _toggled(p.on(a), v) : {v}, book);
    }
    widget.picked.value = p;
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    if (kit == null) return const SizedBox.shrink();
    final book = kit.book;
    return ValueListenableBuilder<ComboRule?>(
      valueListenable: widget.picked,
      builder: (context, _, __) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final held = show.heldGround;
          final grounds = held != null ? {held} : show.groundsHere();
          final rot = _Rotation.of(show.pool, book, grounds);
          final pick = _pick;
          final grid = _Grid.of(rot, book, _down, _across, pick, _within, show.combo);
          final missing = comboGrounds.where((g) => !grounds.contains(g)).map(_groundName).toList();
          Widget axisPads(bool rows) => Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 62, child: Text(rows ? 'DOWN' : 'ACROSS', style: Console.label(9))),
                for (final a in _rows)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: IntrinsicWidth(
                      child: Pad(
                        label: _rowWord(a).toUpperCase(),
                        height: 20,
                        lit: (rows ? _down : _across) == a,
                        colour: Console.ink,
                        onTap: () => _axis(rows, a),
                      ),
                    ),
                  ),
              ]);
          final words = pick.fields == 0
              ? 'Nothing picked in the selector.'
              : '${_patternWords(pick, book, anys: true)}: ${grid.pickedN} combinations, '
                  '${grid.pickedOn == grid.pickedN ? 'all' : grid.pickedOn == 0 ? 'none' : '${grid.pickedOn}'} on, '
                  '${_percent(grid.pickedShare)} of the time';
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Flow(children: [
              axisPads(true),
              const SizedBox(width: 12),
              axisPads(false),
              const SizedBox(width: 12),
              IntrinsicWidth(
                child: Pad(
                  label: 'WITHIN THE PICK',
                  height: 20,
                  lit: _within,
                  colour: Console.a,
                  tooltip: _within ? 'Every combination counted' : 'Only the combinations the selector picks on the other three rows',
                  onTap: () => setState(() => _within = !_within),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              '${grid.on} of ${grid.n} combinations${grid.byShot ? ' (by framing)' : ''} in the rotation${_within ? ' (within the pick)' : ''}'
              '${missing.isEmpty ? '' : ' · not here now, not counted: ${missing.join(', ')}'}',
              style: TextStyle(fontSize: 11, color: Console.quiet),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(words, style: TextStyle(fontSize: 11, color: Console.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            SizedBox(
              height: 16,
              child: ValueListenableBuilder<String?>(
                valueListenable: _hover,
                builder: (context, h, _) => Text(
                  h ?? 'Point at a square to read it; tap it to pick its two (ctrl-tap: add them), tap a name to pick it alone.',
                  style: TextStyle(fontSize: 11, color: h == null ? Console.faint : Console.a),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final layout = _MapLayout.fit(grid, c.maxWidth);
                final body = SizedBox(
                  width: layout.width,
                  height: layout.height,
                  child: MouseRegion(
                    onHover: (e) => _hover.value = _say(grid, layout.hit(e.localPosition), book),
                    onExit: (_) => _hover.value = null,
                    child: GestureDetector(
                      onTapUp: (e) {
                        final hit = layout.hit(e.localPosition);
                        if (hit == null) return;
                        feel(Feel.pick);
                        _pickOut(book, [
                          if (hit.$1 != null) (_down, grid.rowValues[hit.$1!]),
                          if (hit.$2 != null) (_across, grid.colValues[hit.$2!]),
                        ].where((t) => t.$2.isNotEmpty).toList());
                      },
                      child: CustomPaint(painter: _MapPainter(grid, layout, book, _hover, DefaultTextStyle.of(context).style)),
                    ),
                  ),
                );
                return SingleChildScrollView(
                  child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: body),
                );
              }),
            ),
            const SizedBox(height: 6),
            const _MapLegend(),
          ]);
        },
      ),
    );
  }

  /// A square or a name in words.
  String? _say(_Grid g, (int?, int?)? hit, SceneBook book) {
    if (hit == null) return null;
    final (r, k) = hit;
    final rn = r == null ? null : _mapName(g.rows, g.rowValues[r], book);
    final cn = k == null ? null : _mapName(g.cols, g.colValues[k], book);
    if (r != null && k != null) {
      final cell = g.cells[r][k];
      if (cell.n == 0) return '$rn × $cn: no such combination';
      return '$rn × $cn: ${_percent(cell.share)} of the time · ${cell.on == cell.n ? 'all ${cell.n}' : '${cell.on} of ${cell.n}'} combinations on';
    }
    if (r != null) return '$rn: ${_percent(g.rowTotals[r])} of the time';
    return '$cn: ${_percent(g.colTotals[k!])} of the time';
  }
}

/// Where everything of the grid goes.
class _MapLayout {
  _MapLayout(this.rows, this.cols, this.cell, this.cellH);
  final int rows, cols;
  final double cell, cellH;

  static const labelW = 104.0, headH = 96.0, sideW = 70.0, footH = 30.0, gap = 6.0;

  static _MapLayout fit(_Grid g, double width) {
    final room = width - labelW - gap - sideW;
    final cell = (room / math.max(1, g.colValues.length)).clamp(14.0, 44.0);
    return _MapLayout(g.rowValues.length, g.colValues.length, cell, 16);
  }

  double get width => labelW + cols * cell + gap + sideW;
  double get height => headH + rows * cellH + gap + footH;

  Rect cellRect(int r, int k) => Rect.fromLTWH(labelW + k * cell, headH + r * cellH, cell, cellH);

  /// The row and the column under [p]: both on a square, one on a name or a total.
  (int?, int?)? hit(Offset p) {
    final k = ((p.dx - labelW) / cell).floor();
    final r = ((p.dy - headH) / cellH).floor();
    final inCols = p.dx >= labelW && k < cols;
    final inRows = p.dy >= headH && r < rows;
    if (inCols && inRows) return (r, k);
    if (inRows && (p.dx < labelW || p.dx > labelW + cols * cell + gap)) return (r, null);
    if (inCols && (p.dy < headH || p.dy > headH + rows * cellH + gap)) return (null, k);
    return null;
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.g, this.l, this.book, this.hover, this.type) : super(repaint: hover);
  final _Grid g;
  final _MapLayout l;
  final SceneBook book;
  final ValueNotifier<String?> hover;

  /// The page's type, for the names.
  final TextStyle type;

  void _text(Canvas canvas, String s, Offset at, double maxW, {Color? color, bool right = false, double size = 10}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: type.copyWith(fontSize: size, color: color ?? Console.quiet)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxW);
    tp.paint(canvas, at.translate(right ? maxW - tp.width : 0, 0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final most = g.maxCell;
    final low = Console.raised, high = Console.a;
    final hatch = Paint()
      ..color = Console.faint
      ..strokeWidth = 1;
    // The column names, turned up.
    for (var k = 0; k < l.cols; k++) {
      canvas.save();
      canvas.translate(_MapLayout.labelW + k * l.cell + l.cell / 2 - 6, _MapLayout.headH - 4);
      canvas.rotate(-math.pi / 2);
      _text(canvas, _mapName(g.cols, g.colValues[k], book), Offset.zero, _MapLayout.headH - 8, color: Console.ink);
      canvas.restore();
    }
    final rowMost = g.rowTotals.fold(0.0, math.max), colMost = g.colTotals.fold(0.0, math.max);
    for (var r = 0; r < l.rows; r++) {
      final y = _MapLayout.headH + r * l.cellH;
      _text(canvas, _mapName(g.rows, g.rowValues[r], book), Offset(0, y + 2), _MapLayout.labelW - 6, color: Console.ink);
      for (var k = 0; k < l.cols; k++) {
        final cell = g.cells[r][k];
        final rect = l.cellRect(r, k).deflate(1);
        if (cell.n == 0) continue;
        if (cell.on == 0) {
          // All off: hatched.
          canvas.drawRect(rect, Paint()..color = Console.ground);
          canvas.save();
          canvas.clipRect(rect);
          for (var x = rect.left - rect.height; x < rect.right; x += 4) {
            canvas.drawLine(Offset(x, rect.bottom), Offset(x + rect.height, rect.top), hatch);
          }
          canvas.restore();
        } else {
          final t = most <= 0 ? 0.0 : math.sqrt(cell.share / most);
          canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), Paint()..color = Color.lerp(low, high, 0.12 + 0.88 * t)!);
          if (cell.on < cell.n) {
            // Some off: a nick in the corner.
            canvas.drawPath(
                Path()
                  ..moveTo(rect.right - 5, rect.top)
                  ..lineTo(rect.right, rect.top)
                  ..lineTo(rect.right, rect.top + 5)
                  ..close(),
                Paint()..color = Console.ground);
          }
        }
        if (cell.picked) {
          canvas.drawRect(
              rect.inflate(0.5),
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5
                ..color = Console.ink);
        }
        if (cell.live) canvas.drawCircle(rect.center, 2.5, Paint()..color = Console.b);
      }
      // The row's total.
      final x0 = _MapLayout.labelW + l.cols * l.cell + _MapLayout.gap;
      final w = rowMost <= 0 ? 0.0 : (_MapLayout.sideW - 34) * g.rowTotals[r] / rowMost;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x0, y + 4, math.max(w, g.rowTotals[r] > 0 ? 1 : 0), l.cellH - 8), const Radius.circular(2)),
          Paint()..color = Console.quiet);
      _text(canvas, _percent(g.rowTotals[r]), Offset(x0 + _MapLayout.sideW - 34, y + 2), 34, size: 9, right: true);
    }
    // The columns' totals.
    final y0 = _MapLayout.headH + l.rows * l.cellH + _MapLayout.gap;
    for (var k = 0; k < l.cols; k++) {
      final h = colMost <= 0 ? 0.0 : 14 * g.colTotals[k] / colMost;
      final x = _MapLayout.labelW + k * l.cell;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 2, y0 + 14 - h, l.cell - 4, h), const Radius.circular(2)), Paint()..color = Console.quiet);
      if (l.cell >= 28) _text(canvas, _percent(g.colTotals[k]), Offset(x, y0 + 16), l.cell, size: 8);
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => !identical(old.g, g) || old.l.cell != l.cell;
}

/// What the marks of the grid mean.
class _MapLegend extends StatelessWidget {
  const _MapLegend();

  @override
  Widget build(BuildContext context) {
    Widget key(Widget mark, String word) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [mark, const SizedBox(width: 5), Text(word, style: TextStyle(fontSize: 10, color: Console.quiet))]),
        );
    Widget box({Color? fill, Gradient? gradient, Border? border, double w = 14}) => Container(
          width: w,
          height: 10,
          decoration: BoxDecoration(color: fill, gradient: gradient, border: border, borderRadius: BorderRadius.circular(2)),
        );
    return _Flow(children: [
      key(box(gradient: LinearGradient(colors: [Color.lerp(Console.raised, Console.a, 0.12)!, Console.a]), w: 36), 'less → more of the time'),
      key(SizedBox(width: 14, height: 10, child: CustomPaint(painter: _HatchPainter())), 'all off'),
      key(
          SizedBox(
              width: 14,
              height: 10,
              child: CustomPaint(
                  painter: _NickPainter(),
                  child: const SizedBox.expand())),
          'some off'),
      key(box(border: Border.all(color: Console.ink, width: 1.5)), 'the selector\'s pick'),
      key(Container(width: 5, height: 5, decoration: BoxDecoration(color: Console.b, shape: BoxShape.circle)), 'on the stage now'),
    ]);
  }
}

class _HatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = Console.ground);
    canvas.clipRect(r);
    final p = Paint()
      ..color = Console.faint
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => false;
}

class _NickPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = Color.lerp(Console.raised, Console.a, 0.6)!);
    canvas.drawPath(
        Path()
          ..moveTo(r.right - 5, 0)
          ..lineTo(r.right, 0)
          ..lineTo(r.right, 5)
          ..close(),
        Paint()..color = Console.ground);
  }

  @override
  bool shouldRepaint(_NickPainter old) => false;
}
