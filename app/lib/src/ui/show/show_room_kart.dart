// The combination selector: five rows of cards — BACKGROUND, SCENE, STYLE, MASK,
// BLEND — picked like a kart, a driver and wheels, and the combination they make
// shown blended on the spot with the stage's own blend (shaders/show/under.frag).
//
// Under the picture the combination's switch and its weight: off, it is never in the
// rotation; the weight says how often against the rest. A row left at ANY makes the
// switch and the weight a rule for every combination with the others (a card alone is
// that card's weight: how often MilkDrop, how often the keyhole). A row may hold a few
// cards (ctrl- or shift-click, or a long press; ALL BUT turns the row over): "the
// turntable × any style × any background × the keyhole × add, screen" is one rule, a
// batch, switched off at once. PLAY IT puts a whole combination on the stage, held.
//
// Under the blend, for the dancers and the flock, the CAMERA: their framings, each
// on, off or weighted (with the rest of the pattern, an exception: "the dancers in
// ascii, never through the fisheye"). Not how often a combination comes — how the
// figure is shot, cut by cut, while it is on.
//
// The model: state/show/show_combos.dart. The figures' pictures are baked
// (test/shots/rule_stills_bake_test.dart, assets/show/stills); the backgrounds' are
// MilkDrop's and the camera's live frames where they run, stand-ins for the rest.
part of 'show_room.dart';

/// A background's name.
String _groundName(String key) => switch (key) {
      'black' => 'Black',
      'white' => 'White',
      'milk' => 'MilkDrop',
      'wash' => 'Wash',
      'pulse.grid' => 'Pulse grid',
      'pulse.rays' => 'Pulse rays',
      'pulse.smoke' => 'Pulse smoke',
      'pulse.stars' => 'Pulse stars',
      'field.drift' => 'Drift',
      'cover' => 'Cover',
      'camera' => 'Camera',
      ownGround => 'Its own',
      _ => key,
    };

String _maskName(Mask m) => switch (m) { Mask.none => 'No mask', Mask.keyhole => 'Keyhole', Mask.inverted => 'Inverted' };

String _mixName(Mix m) => switch (m) { Mix.normal => 'Normal', Mix.add => 'Add', Mix.screen => 'Screen', Mix.contrast => 'Contrast' };

/// The rows in the selector's order.
const _rows = [ComboAxis.scene, ComboAxis.style, ComboAxis.ground, ComboAxis.mask, ComboAxis.mix, ComboAxis.shot];

String _rowWord(ComboAxis a) => switch (a) {
      ComboAxis.scene => 'scene',
      ComboAxis.style => 'style',
      ComboAxis.ground => 'background',
      ComboAxis.mask => 'mask',
      ComboAxis.mix => 'blend',
      ComboAxis.shot => 'camera',
    };

/// One thing of a row by name, in words.
String _valueName(ComboAxis a, String v, SceneBook? book) => switch (a) {
      ComboAxis.scene => book?[v]?.name ?? v,
      ComboAxis.style => v == 'raw' ? 'as drawn' : v,
      ComboAxis.ground => _groundName(v),
      ComboAxis.mask => _maskName(Mask.values.byName(v)),
      ComboAxis.mix => _mixName(Mix.values.byName(v)),
      ComboAxis.shot => _shotName(v),
    };

/// A framing's name, by its key (`dancers.fisheye`); with the figure's where
/// [whose] (the dancers' front and the flock's are two).
String _shotName(String key, {bool whose = false}) {
  if (key.isEmpty) return 'No camera';
  final dot = key.indexOf('.');
  final fig = key.substring(0, dot), shot = key.substring(dot + 1);
  final name = switch (shot) {
    'front' => 'Front',
    'medium' => 'Medium',
    'close' => 'Close',
    'wide' => 'Wide',
    'extremeLow' => 'Floor up',
    'extremeHigh' => 'From above',
    'extremeFront' => 'Face on',
    'fisheye' || 'fish' => 'Fisheye',
    'fisheyeLow' || 'fishLow' => 'Fisheye floor',
    'low' => 'Low',
    'high' => 'High',
    _ => shot,
  };
  return whose ? '${fig == 'birds' ? 'Birds' : 'Dancers'} ${name.toLowerCase()}' : name;
}

/// A framing's card picture.
IconData _shotIcon(String key) => switch (key.substring(key.indexOf('.') + 1)) {
      'front' => Icons.videocam_outlined,
      'medium' => Icons.crop_portrait,
      'close' => Icons.zoom_in,
      'wide' => Icons.zoom_out_map,
      'extremeLow' || 'low' => Icons.north,
      'extremeHigh' || 'high' => Icons.south,
      'extremeFront' => Icons.face,
      'fisheye' || 'fish' => Icons.panorama_fish_eye,
      _ => Icons.blur_circular,
    };

/// The framings of the scenes [scenes] (every scene's, at ANY) have.
List<String> _shotsOfScenes(SceneBook book, Set<String>? scenes) => [
      for (final f in const [Figure.dancers, Figure.birds])
        if (book.scenes.values.any((s) => s.look.rig.figure.kind == f && (scenes == null || scenes.contains(s.id)))) ...shotsOfFigure(f),
    ];

/// A pattern in words, row by row: `Dancer · plain · MilkDrop · Keyhole · Add, Screen`,
/// the rows at ANY left out; [anys] says them too, a sentence of the five
/// (`Turntable × any style × any background × Keyhole × Add, Screen`).
String _patternWords(ComboRule p, SceneBook? book, {bool anys = false}) {
  final parts = [
    for (final a in _rows)
      if (p.on(a) case final v?)
        _ordered(a, v).map((x) => a == ComboAxis.shot ? _shotName(x, whose: true) : _valueName(a, x, book)).join(', ')
      else if (anys && a != ComboAxis.shot)
        'any ${_rowWord(a)}',
  ];
  if (parts.isEmpty || (anys && p.fields == 0)) return 'everything';
  return parts.join(anys ? ' × ' : ' · ');
}

/// A row's things in their order (a mask's and a blend's as they come; the rest as
/// they were picked).
List<String> _ordered(ComboAxis a, Set<String> v) => switch (a) {
      ComboAxis.mask => [for (final m in Mask.values) if (v.contains(m.name)) m.name],
      ComboAxis.mix => [for (final m in Mix.values) if (v.contains(m.name)) m.name],
      ComboAxis.ground => [for (final g in [...comboGrounds, ownGround]) if (v.contains(g)) g],
      ComboAxis.shot => [for (final g in allShots) if (v.contains(g)) g],
      _ => v.toList(),
    };

/// The combination [c] as a pattern with every row one thing.
ComboRule _patternOfCombo(Combo c) => ComboRule(grounds: {c.ground}, scenes: {c.scene}, styles: {c.style}, masks: {c.mask}, mixes: {c.mix});

/// The scenes in the SCENE row's order: by family, then by name.
List<Scene> _scenesInOrder(SceneBook book) => book.scenes.values.toList()
  ..sort((a, b) {
    final f = _familyOf(a).index.compareTo(_familyOf(b).index);
    return f != 0 ? f : a.name.compareTo(b.name);
  });

/// The styles of [scenes] (every scene's, at ANY), each once, in their order.
List<String> _stylesOfScenes(SceneBook book, Set<String>? scenes) {
  final out = <String>{};
  for (final s in _scenesInOrder(book)) {
    if (scenes == null || scenes.contains(s.id)) out.addAll(stylesOfFigure(s.look.rig.figure.kind));
  }
  return out.toList();
}

/// [p] with row [a] said again (null: ANY); the styles the scenes picked have not,
/// let go. Where it comes to worlds alone, the background, the mask and the blend
/// let go too: a world has none of them to pick, and a pattern still saying the ones
/// picked before (hidden under "a world of its own") would match nothing.
ComboRule _putRow(ComboRule p, ComboAxis a, Set<String>? names, SceneBook book) {
  var next = p.withOn(a, names);
  final styles = next.styles;
  if (a == ComboAxis.scene && styles != null) {
    final have = _stylesOfScenes(book, next.scenes).toSet();
    next = next.withOn(ComboAxis.style, styles.where(have.contains).toSet());
  }
  final shots = next.shots;
  if (a == ComboAxis.scene && shots != null) {
    final have = _shotsOfScenes(book, next.scenes).toSet();
    next = next.withOn(ComboAxis.shot, shots.where(have.contains).toSet());
  }
  if (_worldsOnly(next, book)) {
    next = next.withOn(ComboAxis.ground, null).withOn(ComboAxis.mask, null).withOn(ComboAxis.mix, null);
  }
  return next;
}

/// Whether every scene and style [p] says is a world of its own (no background,
/// mask or blend to pick).
bool _worldsOnly(ComboRule p, SceneBook book) {
  final scenes = p.scenes;
  if (scenes == null) return false;
  for (final s in scenes) {
    final kind = book[s]?.look.rig.figure.kind ?? Figure.none;
    if (worldScenes.contains(s) || kind == Figure.none) continue;
    final styles = p.styles?.where(stylesOfFigure(kind).contains);
    if (styles == null || styles.isEmpty || !styles.every((st) => isWorld(s, kind, st))) return false;
  }
  return true;
}

/// Whether a tap means "this one too" (ctrl, shift or the command key held).
bool get _adding {
  final k = HardwareKeyboard.instance;
  return k.isControlPressed || k.isShiftPressed || k.isMetaPressed;
}

/// [names] with [v] in or out; none left is ANY.
Set<String>? _toggled(Set<String>? names, String v) {
  final next = {...?names};
  if (!next.remove(v)) next.add(v);
  return next.isEmpty ? null : next;
}

/// The weights a slider steps through.
const _weights = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0];

String _weightWord(double w) {
  if (w <= 0) return 'off';
  var t = w.toStringAsFixed(2);
  while (t.contains('.') && (t.endsWith('0') || t.endsWith('.'))) {
    t = t.substring(0, t.length - 1);
  }
  return '×$t';
}

/// The pictures the selector blends, shared by the page.
class _Stills extends ChangeNotifier {
  _Stills._();
  static final shared = _Stills._();

  final _figures = <String, ui.Image?>{};
  final _grounds = <String, ui.Image>{};
  final _loading = <String>{};
  ui.Image? _wash, _white, _milk;
  (double, double, double, double, double, double)? _washOf;
  Timer? _live;
  int _users = 0;

  /// The still of [kind] in [style] (the dancers', the flock's, the words' own), or
  /// of [kind] as drawn; null while it loads or where there is none.
  ui.Image? figure(Figure kind, String style) {
    final name = ownStyle(kind) ? '${kind.name}.$style' : kind.name;
    if (_figures.containsKey(name)) return _figures[name];
    _load(name, kind == Figure.none ? 'assets/show/thumbs/milk.webp' : 'assets/show/stills/$name.png', (img) => _figures[name] = img);
    return null;
  }

  /// Whether a still was looked for and is not there (the dancers' fluid and their
  /// viewports draw on the native stage only).
  bool missing(Figure kind, String style) {
    final name = ownStyle(kind) ? '${kind.name}.$style' : kind.name;
    return _figures.containsKey(name) && _figures[name] == null;
  }

  /// A background's picture: the live one where it runs, else its stand-in.
  ui.Image? ground(String key, ShowPalette palette) {
    switch (key) {
      case 'black':
      case ownGround:
        return null;
      case 'white':
        return _white ??= _flat(const Color(0xffffffff));
      case 'wash':
        return _washFor(palette);
    }
    final live = _grounds[key];
    if (live != null) return live;
    if (key == 'milk') return _milk ??= _milkStandIn();
    final asset = switch (key) {
      'field.drift' => 'assets/show/thumbs/drift.webp',
      'cover' => 'assets/brand/ball.webp',
      'camera' => 'assets/show/siebenschlaefer/photos/00.webp',
      _ => 'assets/show/thumbs/${key.replaceAll('.', '-')}.webp',
    };
    _load('ground.$key', asset, (img) {
      if (img != null) _grounds[key] = img;
    });
    return null;
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

  static ui.Image _flat(Color c) {
    final r = ui.PictureRecorder();
    Canvas(r).drawRect(const Rect.fromLTWH(0, 0, 16, 9), Paint()..color = c);
    final pic = r.endRecording();
    final img = pic.toImageSync(16, 9);
    pic.dispose();
    return img;
  }

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

  /// A selector on the page: MilkDrop's and the camera's frames taken every couple
  /// of seconds while one is.
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
    for (final (g, frame) in [('milk', MilkFeed.shared.frame), ('camera', CameraFeed.shared.running ? CameraFeed.shared.frame : null)]) {
      if (frame == null) continue;
      _grounds[g] = frame.clone();
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

/// Which pixels of a still are its figure (under.frag's uCoverage): the words' alpha,
/// the plain dancers' and the silhouettes' marks, the light for the rest.
int _stillCoverage(Figure kind, String style) => kind == Figure.words ? 1 : (kind == Figure.dancers && (style == 'plain' || style == 'mono') ? 0 : 2);

/// A figure's picture blended with a background's, the stage's way, drawn once and
/// kept until one of them (or the way) changes.
class _Blended extends StatefulWidget {
  const _Blended(
      {required this.program, required this.figure, required this.ground, required this.blend, required this.coverage, required this.dim, required this.width});
  final ui.FragmentProgram program;
  final ui.Image? figure, ground;
  final RigBlend blend;
  final int coverage;
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
    // On black (no picture): the figure as drawn.
    final ground = w.ground;
    if (ground == null && w.blend.plain) {
      _out = fig.clone();
      return;
    }
    _shader
      ..setFloat(0, pw.toDouble())
      ..setFloat(1, ph.toDouble())
      ..setFloat(2, w.blend.mix.index.toDouble())
      ..setFloat(3, w.blend.mask.index.toDouble())
      ..setFloat(4, w.coverage.toDouble())
      ..setFloat(5, w.blend.strength)
      ..setFloat(6, ground == null ? 0 : ground.width / ground.height)
      ..setFloat(7, ground == null ? 0 : w.dim)
      ..setImageSampler(0, fig)
      ..setImageSampler(1, ground ?? fig);
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

/// A little picture of a mask and a blend: a preset-like wash as the background and a
/// figure (a white body) on it, put together that way.
class _ComboSwatch extends StatelessWidget {
  const _ComboSwatch(this.mask, this.mix);
  final Mask mask;
  final Mix mix;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(64, 36), painter: _ComboPainter(mask, mix));
}

class _ComboPainter extends CustomPainter {
  const _ComboPainter(this.mask, this.mix);
  final Mask mask;
  final Mix mix;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final w = size.width, h = size.height;
    // A figure: a head and a body.
    final body = Path()
      ..addOval(Rect.fromCircle(center: Offset(w * 0.5, h * 0.3), radius: h * 0.14))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.38, h * 0.46, w * 0.24, h * 0.54), Radius.circular(h * 0.12)));
    final groundPaint = Paint()..shader = ui.Gradient.linear(r.topLeft, r.bottomRight, const [Color(0xff6a2fb8), Color(0xffe8b23a)]);
    canvas.drawRect(r, Paint()..color = Colors.black);
    // The background where the mask lets it show.
    canvas.save();
    switch (mask) {
      case Mask.none:
        break;
      case Mask.keyhole:
        canvas.clipPath(body);
      case Mask.inverted:
        canvas.clipPath(Path.combine(PathOperation.difference, Path()..addRect(r), body));
    }
    canvas.drawRect(r, groundPaint);
    canvas.restore();
    // The figure, the blend's way; under a mask and the normal blend the mask's shape
    // is the figure.
    if (mix == Mix.normal && mask != Mask.none) return;
    final figure = Paint()
      ..color = const Color(0xffeeeeee)
      ..blendMode = switch (mix) {
        Mix.normal => BlendMode.srcOver,
        Mix.add => BlendMode.plus,
        Mix.screen => BlendMode.screen,
        Mix.contrast => BlendMode.difference,
      };
    canvas.drawPath(body, figure);
  }

  @override
  bool shouldRepaint(_ComboPainter old) => old.mask != mask || old.mix != mix;
}

/// A card: one thing of a row — its picture, its name, its card weight where it is
/// not 1 — lit when picked, faint when its card is off.
class _Card extends StatelessWidget {
  const _Card(
      {required this.label,
      required this.lit,
      required this.onTap,
      this.onAdd,
      this.weight = 1,
      this.live = false,
      this.thumb,
      this.swatch,
      this.picture,
      this.tooltip});
  final String label;
  final bool lit;

  /// On the stage now.
  final bool live;
  final double weight;
  final VoidCallback onTap;

  /// A long press: this one too (or not), the rest of the row kept.
  final VoidCallback? onAdd;
  final String? thumb, tooltip;
  final Color? swatch;
  final Widget? picture;

  @override
  Widget build(BuildContext context) {
    final off = weight <= 0;
    final border = lit ? Console.a : (live ? Console.b : Console.line);
    final face = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: lit ? Console.a.withValues(alpha: 0.18) : Console.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: lit || live ? 1.5 : 1),
        boxShadow: lit ? [BoxShadow(color: Console.a.withValues(alpha: 0.35), blurRadius: 10, spreadRadius: -2)] : null,
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 3),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Opacity(
            opacity: off ? 0.3 : 1,
            child: SizedBox(
              width: 64,
              height: 36,
              child: Stack(fit: StackFit.expand, children: [
                picture ??
                    (thumb != null
                        ? Image.asset(thumb!,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (context, _, __) => ColoredBox(color: swatch ?? Console.ground))
                        : ColoredBox(color: swatch ?? Console.ground)),
                if (weight != 1)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(3)),
                      child: Text(_weightWord(weight), style: Console.label(8, color: off ? Console.quiet : Console.ink)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Console.label(8.5, color: lit ? Console.a : (off ? Console.faint : Console.ink))),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 5, bottom: 5),
      child: SizedBox(
        width: 84,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              feel(Feel.pick);
              onTap();
            },
            onLongPress: onAdd == null
                ? null
                : () {
                    feel(Feel.pick);
                    onAdd!();
                  },
            // The long press is the card's (this one too), not the tooltip's.
            child: Tooltip(
                message: tooltip ?? label,
                waitDuration: const Duration(milliseconds: 500),
                triggerMode: onAdd == null ? null : TooltipTriggerMode.manual,
                child: face),
          ),
        ),
      ),
    );
  }
}

/// The ANY card of a row.
class _Any extends StatelessWidget {
  const _Any({required this.lit, required this.onTap, required this.what});
  final bool lit;
  final VoidCallback onTap;
  final String what;

  @override
  Widget build(BuildContext context) => _Card(
        label: 'ANY',
        lit: lit,
        onTap: onTap,
        tooltip: 'Any $what: the switch and the weight above hold for all of them',
        picture: ColoredBox(color: Console.ground, child: Center(child: Text('*', style: Console.label(18, color: lit ? Console.a : Console.quiet)))),
      );
}

/// The selector.
class _Kart extends StatefulWidget {
  const _Kart({required this.show, required this.kit, required this.picked});
  final ShowEngine show;
  final StageKit kit;

  /// The pattern picked; null follows the stage (the combination on, as it changes).
  final ValueNotifier<ComboRule?> picked;

  @override
  State<_Kart> createState() => _KartState();
}

class _KartState extends State<_Kart> {
  ShowEngine get show => widget.show;
  SceneBook get book => widget.kit.book;

  @override
  void initState() {
    super.initState();
    _Stills.shared
      ..hold()
      ..addListener(_redraw);
  }

  @override
  void dispose() {
    _Stills.shared
      ..removeListener(_redraw)
      ..release();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  ComboRule get _pattern => widget.picked.value ?? (show.combo == null ? const ComboRule() : _patternOfCombo(show.combo!));

  void _set(ComboRule p) => widget.picked.value = p;

  Figure _kindOf(String scene) => book[scene]?.look.rig.figure.kind ?? Figure.none;

  List<Scene> get _scenes => _scenesInOrder(book);

  /// The styles of [scenes] (every scene's, at ANY), each once, in their order.
  List<String> _stylesOf(Set<String>? scenes) => _stylesOfScenes(book, scenes);

  ComboRule _put(ComboRule p, ComboAxis a, Set<String>? names) => _putRow(p, a, names, book);

  /// A card tapped: this one alone, or (ctrl, shift) this one too.
  void _tap(ComboRule p, ComboAxis a, String v) => _set(_put(p, a, _adding ? _toggled(p.on(a), v) : {v}));

  void _add(ComboRule p, ComboAxis a, String v) => _set(_put(p, a, _toggled(p.on(a), v)));

  bool _locked(ComboRule p) => _worldsOnly(p, book);

  /// A row's heading: its word, its hint, and with some of it picked ALL BUT (the row
  /// turned over: every other card of it).
  Widget _rowHead(ComboRule p, ComboAxis a, String word, String hint, List<String> all) {
    final picked = p.on(a);
    return Row(children: [
      Expanded(child: _Head(word, hint: hint)),
      if (picked != null && picked.length < all.length)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: IntrinsicWidth(
            child: Pad(
              label: 'ALL BUT',
              height: 20,
              colour: Console.quiet,
              tooltip: 'Every ${_rowWord(a)} but ${_ordered(a, picked).map((v) => _valueName(a, v, book)).join(', ')}',
              onTap: () => _set(_put(p, a, all.where((v) => !picked.contains(v)).toSet())),
            ),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ComboRule?>(
        valueListenable: widget.picked,
        builder: (context, picked, _) => ListenableBuilder(
          listenable: show,
          builder: (context, _) {
            final pool = show.pool;
            final p = _pattern;
            final on = show.combo;
            final one = p.scenes?.length == 1 ? p.scenes!.first : null;
            final kind = one == null ? null : _kindOf(one);
            final locked = _locked(p);
            final styles = _stylesOf(p.scenes);
            final shots = _shotsOfScenes(book, p.scenes);
            bool lit(ComboAxis a, String v) => p.on(a)?.contains(v) ?? false;
            double card(ComboAxis a, String v) => pool.cardWeight(a, v);
            const several = 'ctrl-click or hold: several';
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _SnapshotBar(show: show),
              _ComboPanel(show: show, kit: widget.kit, pattern: p, following: picked == null, onFollow: () => widget.picked.value = null, onPick: _set),
              const Divider(height: 14),
              Expanded(
                  // Sixty cards or so: built at once, so every row is there to scroll to.
                  child: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _rowHead(p, ComboAxis.scene, 'SCENE', 'what stands in the middle · $several', [for (final s in _scenes) s.id]),
                Wrap(children: [
                  _Any(lit: p.scenes == null, what: 'scene', onTap: () => _set(_put(p, ComboAxis.scene, null))),
                  for (final s in _scenes)
                    _Card(
                      label: s.name,
                      lit: lit(ComboAxis.scene, s.id),
                      live: on?.scene == s.id,
                      weight: card(ComboAxis.scene, s.id),
                      thumb: thumbOf(s.id),
                      onTap: () => _tap(p, ComboAxis.scene, s.id),
                      onAdd: () => _add(p, ComboAxis.scene, s.id),
                    ),
                ]),
                // The transformation, before the style: the style goes over what it makes.
                _TransformRow(show: show),
                _rowHead(p, ComboAxis.style, 'STYLE', one == null ? 'the style of this name, in every scene that has it' : 'how ${book[one]?.name ?? one} is drawn', styles),
                Wrap(children: [
                  _Any(lit: p.styles == null, what: 'style', onTap: () => _set(_put(p, ComboAxis.style, null))),
                  for (final st in styles)
                    _Card(
                      label: st == 'raw' ? 'As drawn' : st,
                      lit: lit(ComboAxis.style, st),
                      live: on != null && on.style == st && (p.scenes == null || p.scenes!.contains(on.scene)),
                      weight: card(ComboAxis.style, st),
                      picture: _stylePicture(kind, st),
                      onTap: () => _tap(p, ComboAxis.style, st),
                      onAdd: () => _add(p, ComboAxis.style, st),
                    ),
                ]),
                // The knobs of the style picked (or on, while following the stage),
                // where it is one drawn by a shader: a treatment, or a dancer's or a
                // flock's own look of that kind.
                if ((p.styles?.length == 1 ? p.styles!.first : (picked == null ? on?.style : null)) case final tuned?)
                  if (treatmentTunes.containsKey(tuned)) _TuneLine(show: show, treatment: tuned),
                _rowHead(p, ComboAxis.ground, 'BACKGROUND', locked ? 'a world of its own: its own background' : 'what is under it', comboGrounds),
                if (!locked)
                  Wrap(children: [
                    _Any(lit: p.grounds == null, what: 'background', onTap: () => _set(_put(p, ComboAxis.ground, null))),
                    for (final g in comboGrounds)
                      _Card(
                        label: _groundName(g),
                        lit: lit(ComboAxis.ground, g),
                        live: on?.ground == g,
                        weight: card(ComboAxis.ground, g),
                        thumb: switch (g) {
                          'milk' => 'assets/show/thumbs/milk.webp',
                          'field.drift' => 'assets/show/thumbs/drift.webp',
                          _ when g.startsWith('pulse.') => 'assets/show/thumbs/${g.replaceAll('.', '-')}.webp',
                          _ => null,
                        },
                        swatch: switch (g) {
                          'black' => const Color(0xff050505),
                          'white' => const Color(0xffffffff),
                          'wash' => const Color(0xff2a2238),
                          'camera' => const Color(0xff203028),
                          'cover' => const Color(0xff303040),
                          _ => const Color(0xff101418),
                        },
                        tooltip: g == 'camera' ? 'Only while a camera is on' : (g == 'cover' ? 'Only with a record\'s cover' : null),
                        onTap: () => _tap(p, ComboAxis.ground, g),
                        onAdd: () => _add(p, ComboAxis.ground, g),
                      ),
                  ]),
                _rowHead(p, ComboAxis.mask, 'MASK', locked ? '—' : 'where the background shows', [for (final m in Mask.values) m.name]),
                if (!locked)
                  Wrap(children: [
                    _Any(lit: p.masks == null, what: 'mask', onTap: () => _set(_put(p, ComboAxis.mask, null))),
                    for (final m in Mask.values)
                      _Card(
                        label: _maskName(m),
                        lit: lit(ComboAxis.mask, m.name),
                        live: on?.mask == m && on?.world == false,
                        weight: card(ComboAxis.mask, m.name),
                        picture: _ComboSwatch(m, Mix.normal),
                        tooltip: switch (m) {
                          Mask.none => 'The background everywhere',
                          Mask.keyhole => 'The background only inside the figure, black round it',
                          Mask.inverted => 'The background only round the figure: the figure cut out of it',
                        },
                        onTap: () => _tap(p, ComboAxis.mask, m.name),
                        onAdd: () => _add(p, ComboAxis.mask, m.name),
                      ),
                  ]),
                _rowHead(p, ComboAxis.mix, 'BLEND', locked ? '—' : 'how the two meet', [for (final x in Mix.values) x.name]),
                if (!locked)
                  Wrap(children: [
                    _Any(lit: p.mixes == null, what: 'blend', onTap: () => _set(_put(p, ComboAxis.mix, null))),
                    for (final x in Mix.values)
                      _Card(
                        label: _mixName(x),
                        lit: lit(ComboAxis.mix, x.name),
                        live: on?.mix == x && on?.world == false,
                        weight: card(ComboAxis.mix, x.name),
                        picture: _ComboSwatch(p.masks?.length == 1 ? p.masks!.first : Mask.none, x),
                        tooltip: switch (x) {
                          Mix.normal => 'The figure over the background (under a mask: the mask\'s shape alone)',
                          Mix.add => 'The two added: light on light',
                          Mix.screen => 'Screened: neither blows the other out',
                          Mix.contrast => 'The difference: where they agree is dark',
                        },
                        onTap: () => _tap(p, ComboAxis.mix, x.name),
                        onAdd: () => _add(p, ComboAxis.mix, x.name),
                      ),
                  ]),
                if (shots.isNotEmpty) ...[
                  _rowHead(p, ComboAxis.shot, 'CAMERA', 'how the dancers and the birds are framed, cut by cut — not how often it all comes', shots),
                  for (final f in const ['dancers', 'birds'])
                    if (shots.any((k) => k.startsWith('$f.')))
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (shots.any((k) => !k.startsWith('$f.')))
                          SizedBox(
                            width: 70,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 18),
                              child: Text(f == 'birds' ? 'BIRDS' : 'DANCERS', style: Console.label(8.5)),
                            ),
                          ),
                        Expanded(
                          child: Wrap(children: [
                            if (f == 'dancers' || !shots.any((k) => k.startsWith('dancers.')))
                              _Any(lit: p.shots == null, what: 'framing', onTap: () => _set(_put(p, ComboAxis.shot, null))),
                            for (final k in shots)
                              if (k.startsWith('$f.'))
                                _Card(
                                  label: _shotName(k),
                                  lit: lit(ComboAxis.shot, k),
                                  weight: card(ComboAxis.shot, k),
                                  picture: ColoredBox(
                                      color: Console.ground,
                                      child: Center(child: Icon(_shotIcon(k), size: 20, color: lit(ComboAxis.shot, k) ? Console.a : Console.quiet))),
                                  tooltip: _shotName(k, whose: true),
                                  onTap: () => _tap(p, ComboAxis.shot, k),
                                  onAdd: () => _add(p, ComboAxis.shot, k),
                                ),
                          ]),
                        ),
                      ]),
                ],
                const SizedBox(height: 10),
              ]))),
            ]);
          },
        ),
      );

  /// A style's card picture: its still, where one scene is picked and has one.
  Widget? _stylePicture(Figure? kind, String style) {
    if (kind == null) return null;
    final img = _Stills.shared.figure(kind, style);
    if (img == null) return null;
    return RawImage(image: img, fit: BoxFit.cover);
  }
}

/// The transformation (TransformSet, show_rig.dart), before the style — the style goes
/// over what it makes: the director's pick, none most of the time, or one held; the
/// kaleidoscope's copies and how far they differ, the slit-scan's knobs.
class _TransformRow extends StatelessWidget {
  const _TransformRow({required this.show});
  final ShowEngine show;

  static const _words = {
    TransformMode.auto: 'The director picks, once a combination: none most of the time',
    TransformMode.none: 'No transformation',
    TransformMode.kaleidoscope: 'Mirrors through the middle: the scene reflected into every wedge, cut at the mirrors, under it',
    TransformMode.slit: 'Each part of the picture from a frame further back (the native stage: Linux and Windows)',
    TransformMode.both: 'The slit-scan, then the kaleidoscope of it',
  };

  @override
  Widget build(BuildContext context) {
    final t = show.pool.transform;
    final now = show.transformOn;
    final kaleido = t.mode == TransformMode.auto || t.mode == TransformMode.kaleidoscope || t.mode == TransformMode.both;
    final slit = t.mode == TransformMode.auto || t.mode == TransformMode.slit || t.mode == TransformMode.both;
    String name(TransformMode m) => m == TransformMode.slit ? 'SLIT-SCAN' : m.name.toUpperCase();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Head('TRANSFORMATION', hint: 'before the style: the style goes over what it makes · over every combination'),
      _Line(children: [
        for (final m in TransformMode.values)
          _Word(
            label: m == TransformMode.auto ? 'AUTO · ${name(now)}' : name(m),
            lit: t.mode == m,
            tooltip: _words[m],
            onTap: () => show.setTransform(t.copyWith(mode: m)),
          ),
        if (t.mode == TransformMode.auto) ...[
          const SizedBox(width: 10),
          Tooltip(message: 'How many of the director’s combinations get a transformation at all (the rest have none)', child: Text('HOW OFTEN', style: Console.label(9))),
          SizedBox(
            width: 150,
            child: Slider(value: t.often, onChanged: (v) => show.setTransform(t.copyWith(often: v)), padding: const EdgeInsets.symmetric(horizontal: 10)),
          ),
          Text('${(t.often * 100).round()} %', style: Console.label(9)),
        ],
      ]),
      if (kaleido)
        _Line(children: [
          SizedBox(width: 92, child: Text('KALEIDOSCOPE', style: Console.label(9))),
          Tooltip(message: 'How many mirrors (2: one horizontal, one vertical); twice as many wedges', child: Text('MIRRORS', style: Console.label(9))),
          SizedBox(
            width: 150,
            child: Slider(
              value: t.count.toDouble(),
              min: 1,
              max: RigTransform.most.toDouble(),
              divisions: RigTransform.most - 1,
              onChanged: (v) => show.setTransform(t.copyWith(count: v.round())),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
          SizedBox(width: 26, child: Text('${t.count}', style: Console.label(9, color: Console.ink))),
          const SizedBox(width: 8),
          for (final (label, value, rest, tip, TransformSet Function(double) set) in [
            ('TURN', t.turn, 0.0, 'The mirrors turned: ${(t.turn * 180).round()}° (double-click: straight)', (double v) => t.copyWith(turn: v)),
            ('LINE', t.line, 0.3, 'How much of the mirrors’ edges shows: ${(t.line * 100).round()} %', (double v) => t.copyWith(line: v)),
            ('DIFFERS', t.differ, 0.3, 'How far the reflections’ light and colour are from the original’s: ${(t.differ * 100).round()} %', (double v) => t.copyWith(differ: v)),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Knob(
                value: value,
                min: 0,
                max: 1,
                rest: rest,
                bipolar: false,
                size: 30,
                label: label,
                tooltip: tip,
                onChanged: (v) => show.setTransform(set(v)),
              ),
            ),
        ]),
      if (slit) _TuneLine(show: show, treatment: 'slit'),
    ]);
  }
}

/// The combination picked, big: its picture, its words, its switch and weight, and
/// PLAY IT.
class _ComboPanel extends StatelessWidget {
  const _ComboPanel({required this.show, required this.kit, required this.pattern, required this.following, required this.onFollow, required this.onPick});
  final ShowEngine show;
  final StageKit kit;
  final ComboRule pattern;
  final bool following;
  final VoidCallback onFollow;
  final void Function(ComboRule) onPick;

  /// How many combinations the pattern covers, and how many of them are on: counted
  /// once per pattern and pool.
  static final _counts = <String, (int, int)>{};
  static ShowPool? _countsFor;

  (int, int) _count(ShowPool pool) {
    if (!identical(pool, _countsFor)) {
      _counts.clear();
      _countsFor = pool;
    }
    return _counts.putIfAbsent(pattern.pattern, () {
      final rules = pool.allRules;
      var n = 0, onN = 0;
      for (final s in kit.book.scenes.values) {
        if (pattern.scenes != null && !pattern.scenes!.contains(s.id)) continue;
        // A camera rule: the combinations of the figures it frames.
        final shots = pattern.shots;
        if (shots != null && !shotsOfFigure(s.look.rig.figure.kind).any(shots.contains)) continue;
        for (final c in combosOf(s.id, s.look.rig.figure.kind)) {
          if (!pattern.matches(c)) continue;
          n++;
          if (comboWeight(c, rules) > 0) onN++;
        }
      }
      return (n, onN);
    });
  }

  /// The pattern as one combination, where it is one: every field set, or a world
  /// (its scene and style).
  Combo? get _whole {
    final p = pattern;
    String? one(ComboAxis a) => p.on(a)?.length == 1 ? p.on(a)!.first : null;
    final scene = one(ComboAxis.scene), style = one(ComboAxis.style);
    if (scene == null || style == null) return null;
    final kind = kit.book[scene]?.look.rig.figure.kind ?? Figure.none;
    if (isWorld(scene, kind, style)) return Combo(ground: ownGround, scene: scene, style: style);
    if (!p.single) return null;
    return Combo(ground: p.grounds!.first, scene: scene, style: style, mask: p.masks!.first, mix: p.mixes!.first);
  }

  @override
  Widget build(BuildContext context) {
    final pool = show.pool;
    final p = pattern;
    final whole = _whole;
    // A world's one combination stands for its pattern.
    final rulePattern = whole != null && whole.world ? ComboRule(scenes: {whole.scene}, styles: {whole.style}, shots: p.shots) : p;
    final mine = pool.mineFor(rulePattern);
    final rule = pool.ruleFor(rulePattern);
    final weightHere = rule?.weight ?? 1;
    final (n, onN) = _count(pool);
    final card = rulePattern.card;
    final explain = whole == null ? null : pool.explain(whole);
    final measured = whole == null ? null : ComboScores.shipped?.quality(whole);
    final shot = p.shots?.length == 1 ? p.shots!.first : null;
    final camera = <String>[
      'a camera rule: how the figure is framed at each cut while these are on — never how often they come',
      if (whole != null && shot != null)
        '${_shotName(shot, whose: true)} with this combination: ${_weightWord(pool.shotWeightOf(whole, shot)).replaceAll('off', 'never')}'
      else
        n == 0 ? 'no combination with a camera is like this' : 'about $n combinations',
    ];
    final words = p.camera
        ? camera
        : <String>[
      if (whole != null && measured != null && explain!.weight > 0)
        measured < ComboScores.floor
            ? 'looks ${(measured * 100).round()}/100 measured: out of the rotation unless a rule of yours names it'
            : 'looks ${(measured * 100).round()}/100 measured${measured < 0.7 ? ', so comes less' : ''} · '
                'intensity ${((ComboScores.shipped!.intensity(whole) ?? 0) * 100).round()}/100',
      if (whole != null)
        explain!.weight <= 0
            ? 'off: never in the rotation'
            : 'in the rotation at ${explain.weight.toStringAsFixed(explain.weight < 1 ? 2 : 1)}'
                ' (${[
                for (final c in explain.cards) '${_patternWords(c, kit.book)} ${_weightWord(c.weight)}',
                if (explain.exception != null) 'rule "${_patternWords(explain.exception!, kit.book)}" ${_weightWord(explain.exception!.weight)}',
              ].join(' · ').ifEmpty('nothing says otherwise')})'
      else
        n == 0 ? 'no combination is like this' : '$n combinations, ${onN == n ? 'all' : onN == 0 ? 'none' : '$onN'} of them in the rotation',
      if (card) rulePattern.breadth > 1 ? 'these cards\' weight multiplies every combination with one of them' : 'this card\'s weight multiplies every combination with it',
          ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 240, child: AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _preview(context)))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(_patternWords(p, kit.book, anys: whole == null), style: Console.label(11, color: Console.ink), maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
                IntrinsicWidth(
                  child: Pad(
                    label: following ? 'FOLLOWING THE STAGE' : 'WHAT IS ON',
                    height: 22,
                    lit: following,
                    colour: Console.quiet,
                    tooltip:
                        following ? 'The selector shows what the stage has on; pick a card to look at another' : 'Back to what the stage has on, following it',
                    onTap: onFollow,
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              for (final w in words) Text(w, style: TextStyle(fontSize: 11, color: Console.quiet), maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Row(children: [
                Tooltip(
                  message: weightHere > 0 ? 'On: tap and ${_patternWords(rulePattern, kit.book)} is never in the rotation' : 'Off: tap to put it back',
                  child: Switch(
                    value: weightHere > 0,
                    onChanged: rulePattern.fields == 0
                        ? null
                        : (v) {
                            // Back on: as shipped where that is on, else at 1; off: at 0.
                            final shipped = _shippedWeight(rulePattern);
                            show.setPool(v
                                ? pool.withRule(rulePattern, shipped == null || shipped > 0 ? null : 1)
                                : pool.withRule(rulePattern, shipped == 0 ? null : 0));
                          },
                  ),
                ),
                Text(weightHere > 0 ? 'ON' : 'OFF', style: Console.label(10, color: weightHere > 0 ? Console.a : Console.quiet)),
                const SizedBox(width: 10),
                Text('WEIGHT', style: Console.label(9)),
                Expanded(
                  child: Slider(
                    value: _weights.indexWhere((w) => w >= weightHere.clamp(_weights.first, _weights.last)).toDouble().clamp(0, _weights.length - 1),
                    min: 0,
                    max: _weights.length - 1.0,
                    divisions: _weights.length - 1,
                    label: _weightWord(weightHere),
                    onChanged: rulePattern.fields == 0 || weightHere <= 0 ? null : (v) => show.setPool(pool.withRule(rulePattern, _weights[v.round()])),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                SizedBox(width: 34, child: Text(_weightWord(weightHere), style: Console.label(10, color: Console.ink))),
              ]),
              _Flow(children: [
                if (mine != null)
                  Pad(
                    label: 'AS SHIPPED',
                    height: 26,
                    colour: Console.quiet,
                    tooltip: _shippedWeight(rulePattern) == null
                        ? 'Take your rule away'
                        : 'Back to the weight it came with (${_weightWord(_shippedWeight(rulePattern)!)})',
                    onTap: () => show.setPool(pool.withRule(rulePattern, null)),
                  ),
                if (mine != null) const SizedBox(width: 6),
                Pad(
                  icon: Icons.play_arrow,
                  label: 'PLAY IT',
                  height: 26,
                  colour: Console.a,
                  tooltip: whole == null ? 'Pick every row (no ANY) to play one combination' : 'On the stage now, held until you let go (HOLD)',
                  onTap: whole == null ? null : () => show.play(whole),
                ),
              ]),
            ]),
          ),
        ]),
      ]),
    );
  }

  double? _shippedWeight(ComboRule p) {
    for (final r in shippedComboRules) {
      if (r.pattern == p.pattern) return r.weight;
    }
    return null;
  }

  /// The pattern's picture: its scene's still in its style on its background, the
  /// mask and the blend applied (ANY: the scene's first style, no mask, normal).
  Widget _preview(BuildContext context) {
    final p = pattern;
    String? first(ComboAxis a) => p.on(a) == null ? null : _ordered(a, p.on(a)!).first;
    final scene = first(ComboAxis.scene);
    if (scene == null) {
      return ColoredBox(
          color: Console.ground,
          child: Center(child: Text('pick a scene\nto see it', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Console.quiet))));
    }
    final kind = kit.book[scene]?.look.rig.figure.kind ?? Figure.none;
    final style = first(ComboAxis.style) ?? stylesOfFigure(kind).first;
    final stills = _Stills.shared;
    final fig = stills.figure(kind, style);
    if (fig == null) {
      return ColoredBox(
        color: Console.ground,
        child: Center(
            child: Text(stills.missing(kind, style) ? 'no picture of this one\n(drawn on the native stage only)' : '',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Console.quiet))),
      );
    }
    final world = isWorld(scene, kind, style);
    final g = world ? ownGround : (first(ComboAxis.ground) ?? 'milk');
    final m = first(ComboAxis.mask), x = first(ComboAxis.mix);
    final blend = world ? RigBlend.normal : RigBlend(mask: m == null ? Mask.none : Mask.values.byName(m), mix: x == null ? Mix.normal : Mix.values.byName(x));
    return Stack(fit: StackFit.expand, children: [
      _Blended(
        program: kit.programs.under,
        figure: fig,
        ground: stills.ground(g, show.state.palette),
        blend: blend,
        coverage: _stillCoverage(kind, style),
        dim: groundOfKey(g).dim,
        width: 480,
      ),
      if (!ownStyle(kind) && style != 'raw')
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            color: Colors.black.withValues(alpha: 0.6),
            child: Text('through $style on the stage', style: Console.label(8, color: Console.ink)),
          ),
        ),
    ]);
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ---------------------------------------------------------------- RULES
/// Every rule in force: yours (each one tapped is loaded into the selector, × takes it
/// away), and the ones that came with the app.
class _RulesTab extends StatelessWidget {
  const _RulesTab({required this.show, required this.kit, required this.onPick});
  final ShowEngine show;
  final StageKit? kit;
  final void Function(ComboRule) onPick;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final pool = show.pool;
          final mine = pool.rules;
          Widget row(ComboRule r, {required bool yours}) => InkWell(
                onTap: () => onPick(r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(
                        width: 44,
                        child: Text(_weightWord(r.weight), style: Console.label(10, color: r.off ? Console.quiet : (yours ? Console.a : Console.ink)))),
                    Expanded(
                      child: Text(
                        '${_patternWords(r, kit?.book)}${r.card ? '  (card)' : ''}',
                        style: TextStyle(fontSize: 12, color: Console.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (yours)
                      Pad(
                          icon: Icons.close,
                          width: 22,
                          height: 22,
                          colour: Console.quiet,
                          tooltip: 'Take this rule away',
                          onTap: () => show.setPool(pool.withRule(r, null))),
                  ]),
                ),
              );
          return ListView(children: [
            Row(children: [
              Expanded(
                child: Text(
                    'Every combination is in the rotation unless a rule says otherwise. Cards (one thing alone) multiply; a rule with more set is an exception — the most particular wins. Tap a rule to see it in the selector.',
                    style: TextStyle(fontSize: 11, color: Console.quiet)),
              ),
              if (mine.isNotEmpty)
                IntrinsicWidth(
                  child: Pad(
                    label: 'BACK TO THE DEFAULTS',
                    height: 26,
                    colour: Console.quiet,
                    tooltip: 'Take all ${mine.length} of your rules away',
                    onTap: () {
                      final before = pool;
                      show.setPool(pool.copyWith(rules: const []));
                      ScaffoldMessenger.of(context).say(snack(
                        const Text('Your rules are gone: the combinations as shipped'),
                        action: SnackBarAction(label: 'UNDO', onPressed: () => show.setPool(before)),
                      ));
                    },
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Text('YOURS', style: Console.label(10, color: Console.ink)),
            if (mine.isEmpty) Text('none yet — the switch and the weight under the selector make one', style: TextStyle(fontSize: 11, color: Console.faint)),
            for (final r in mine) row(r, yours: true),
            const SizedBox(height: 10),
            Text('AS SHIPPED', style: Console.label(10, color: Console.ink)),
            for (final r in shippedComboRules)
              if (pool.mineFor(r) == null) row(r, yours: false),
          ]);
        },
      );
}
