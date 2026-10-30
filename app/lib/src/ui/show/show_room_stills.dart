// The pictures the SHOW page shows a look by, and the names it says things by: the
// figures' baked stills (test/shots/rule_stills_bake_test.dart, assets/show/stills)
// blended with a background's picture the stage's own way (shaders/show/under.frag) —
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

/// The scenes in the SCENE row's order: by family, then by name.
List<Scene> _scenesInOrder(SceneBook book) => book.scenes.values.toList()
  ..sort((a, b) {
    final f = _familyOf(a).index.compareTo(_familyOf(b).index);
    return f != 0 ? f : a.name.compareTo(b.name);
  });

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
