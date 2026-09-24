import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'beat_pulse.dart';
import 'motion.dart';

/// What the room's light is doing this frame, for the things standing in it.
///
/// The light layer works out where the moving heads are pointing and how hard the
/// desk has them, and says so here, in the screen's own coordinates; the record and
/// the glass panel listen, and turn their highlights to it — the grooves throw the
/// beam back along the line to the head, the glass catches its reflection and lights
/// up along the edge nearest it. Nothing here rebuilds a widget: each listener is a
/// painter, repainting.
class RoomLight extends ChangeNotifier {
  /// The heads' beams, in global coordinates, and each one's colour.
  List<HeadBeam> heads = const [];
  List<Color> colours = const [];

  /// The ball's spots, in global coordinates, and the lamps that throw them: a thing
  /// standing in the room draws the ones that land on it in its own material.
  List<BallSpot> spots = const [];
  List<Color> lamps = const [];

  /// What stands in the room, by whoever put it there: its outline in global
  /// coordinates. The wall behind gets their shadows, thrown away from each beam.
  final placed = <Object, RRect>{};

  /// The record itself, where one stands in the room: the card in front of it takes
  /// its shadow.
  RRect? disc;

  void place(Object key, RRect outline) => placed[key] = outline;
  void unplace(Object key) => placed.remove(key);

  /// Where the ball hangs, in global coordinates.
  Offset? ball;

  /// How lit the room is, 0 to 1; the beat, one on it and falling; the bar's swell.
  double life = 0;
  double beat = 0;
  double swing = 0.5;
  bool onPaper = false;

  void set({
    required List<HeadBeam> heads,
    required List<Color> colours,
    required List<BallSpot> spots,
    required List<Color> lamps,
    required Offset ball,
    required double life,
    required double beat,
    required double swing,
    required bool onPaper,
  }) {
    this.heads = heads;
    this.colours = colours;
    this.spots = spots;
    this.lamps = lamps;
    this.ball = ball;
    this.life = life;
    this.beat = beat;
    this.swing = swing;
    this.onPaper = onPaper;
    notifyListeners();
  }

  /// The room gone dark: what the listeners paint when the lights are off.
  void out() {
    if (life == 0 && heads.isEmpty) return;
    heads = const [];
    spots = const [];
    life = 0;
    beat = 0;
    notifyListeners();
  }
}

/// The room the light layer and the things in it share. Put round a screen; the
/// light layer inside it publishes, and anything else inside it may listen.
class RoomLightScope extends InheritedNotifier<RoomLight> {
  const RoomLightScope({super.key, required RoomLight light, required super.child}) : super(notifier: light);

  /// The room, without a rebuild dependency on it: painters take the notifier as
  /// their repaint listenable instead, which is the whole point.
  static RoomLight? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<RoomLightScope>()?.notifier;
}

/// The light in the room while a record plays.
///
/// The logo is a disco ball, and a room with a disco ball in it is lit in a particular
/// way. There is the ball itself, above the top of the page and a little in front of
/// it: a sphere of small flat mirrors in rings, two or three coloured lamps pointed at
/// it, turning. So the room fills with *rows* of small bright spots that all swing the
/// same way at once, in arcs, slow in front of you and quickening and stretching as
/// they slide off towards the corners; and where the air has any haze in it, each spot
/// is the end of a thin ray that can be followed back to the ball. Then there are the
/// moving heads: two lamps on a bar that sweep a soft cone of colour slowly across the
/// wall, the floor and everything standing in the room, and that a lighting desk
/// pushes a little on every downbeat and sends somewhere new every eight bars.
///
/// That is what this draws — by doing the sum rather than by imitating the look. The
/// spots are found by ray: a tile at azimuth φ and tipped θ below level sends its light
/// to x = d·tan φ, y = d·tan θ / cos φ on a wall d away, which is the whole of the look
/// (see [spotsOnThePage]). The light is added to the page the way light is added to a
/// room, in one draw of a small sprite atlas, so there is nothing here a phone cannot
/// keep up with at sixty frames.
///
/// Quiet on purpose — you should see the record first and the light second — and gone
/// when the music stops: the lamps fade over two seconds rather than vanish, the way
/// the house lights come up. Held still, not removed, for a phone that has been asked
/// to keep still.
///
/// Its own layer: it repaints every frame while it moves, and nothing else on the
/// screen has to.
class MirrorBallLight extends StatefulWidget {
  const MirrorBallLight({super.key, required this.playing, this.tint, this.pulse});

  final bool playing;

  /// The song's beat, one on it and falling to nothing: the lamps flare with it, and
  /// the desk changes its mind every eight bars of it. Null, or a song with no beats,
  /// and the room drifts at its own pace.
  final ValueListenable<double>? pulse;

  /// The record's own colour, which the gels are cut from: the room is coloured by
  /// what is playing in it.
  final Color? tint;

  @override
  State<MirrorBallLight> createState() => _MirrorBallLightState();
}

class _MirrorBallLightState extends State<MirrorBallLight> with TickerProviderStateMixin {
  /// The layer's own box, for saying where the light is in the screen's coordinates.
  final _paint = GlobalKey();
  RoomLight? _room;
  ValueListenable<double>? _heard;
  // Three turns of the ball in four minutes: a whole number of them, so the loop
  // comes round to exactly where it started and there is no frame where every spot
  // jumps.
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(minutes: 4));

  /// How lit the room is, 0 to 1: the lamps come up in a second and a half and go
  /// down in two, and the ball stops turning once they are out.
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
    reverseDuration: const Duration(milliseconds: 2000),
  );

  @override
  void initState() {
    super.initState();
    _life.addStatusListener((s) {
      if (s == AnimationStatus.dismissed) {
        _clock.stop();
        _room?.out();
      }
    });
    _clock.addListener(_publish);
    _life.addListener(_publish);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _room = RoomLightScope.maybeOf(context);
    _listen();
    _run();
  }

  @override
  void didUpdateWidget(MirrorBallLight old) {
    super.didUpdateWidget(old);
    _listen();
    if (old.playing != widget.playing) _run();
  }

  void _listen() {
    if (identical(_heard, widget.pulse)) return;
    _heard?.removeListener(_publish);
    _heard = widget.pulse?..addListener(_publish);
  }

  /// Where the light is this frame, told to the room — the same sums the painter
  /// does, in the screen's coordinates rather than the layer's.
  void _publish() {
    final room = _room;
    if (room == null || !mounted) return;
    final box = _paint.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return;
    final origin = box.localToGlobal(Offset.zero);
    final frame = _Room.frameOf(_clock.value, widget.pulse);
    final size = box.size;
    final turn = _clock.value * 3 * 2 * math.pi;
    room.set(
      heads: [for (final h in headsOnThePage(size, frame.seconds, cue: frame.cue, beat: frame.beat, swing: frame.swing)) h.shifted(origin)],
      colours: _headColours ?? const [],
      spots: [for (final s in spotsOnThePage(size, turn, lamps: (_lamps ?? const []).length)) s.shifted(origin)],
      lamps: _lamps ?? const [],
      ball: ballOver(size) + origin,
      life: _life.value,
      beat: frame.beat,
      swing: frame.swing,
      onPaper: _onPaper,
    );
  }

  List<Color>? _headColours;
  List<Color>? _lamps;
  bool _onPaper = false;

  void _run() {
    final still = stillness(context);
    if (widget.playing) {
      if (still) {
        _life.value = 1;
      } else {
        if (!_clock.isAnimating) _clock.repeat();
        _life.forward();
      }
    } else {
      if (still) {
        _life.value = 0;
        _clock.stop();
      } else {
        _life.reverse();
      }
    }
  }

  @override
  void dispose() {
    _heard?.removeListener(_publish);
    _clock.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onPaper = scheme.brightness == Brightness.light;
    _onPaper = onPaper;
    final album = widget.tint ?? scheme.primary;
    // The gels. A club points two or three lamps at the ball; here one is left clear
    // (warm, as a lamp is), one is cut from the record's own colour and one is the
    // highlighter off the magazine's pages. The moving heads carry the record's
    // colour a third of the wheel round, and the clear one. On paper a clear lamp is
    // white on white, so there it is the masthead's ink instead.
    final gel = _gel(album, onPaper);
    final lamps = [
      onPaper ? _gel(scheme.primary, onPaper) : const Color(0xFFFFF1D6),
      gel,
      onPaper ? const Color(0xFFD8B400) : const Color(0xFFFFE14D),
    ];
    final heads = [
      _turned(gel, 40, onPaper),
      onPaper ? _turned(gel, -60, onPaper) : const Color(0xFFFFE2B8),
    ];
    _headColours = heads;
    _lamps = lamps;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            key: _paint,
            size: Size.infinite,
            painter: _Room(
              clock: _clock,
              life: _life,
              lamps: lamps,
              heads: heads,
              onPaper: onPaper,
              pulse: widget.pulse,
              room: _room,
              toLocal: (g) => (_paint.currentContext?.findRenderObject() as RenderBox?)?.globalToLocal(g) ?? g,
            ),
          ),
        ),
      ),
    );
  }

  /// A cover's colour as a gel: the same hue, but as saturated and as bright as a
  /// light is. A cover that is nearly black still has a hue, and a lamp with a nearly
  /// black gel on it is a lamp that is off.
  static Color _gel(Color from, bool onPaper) {
    final hsl = HSLColor.fromColor(from);
    return hsl.withSaturation(math.max(hsl.saturation, 0.75)).withLightness(onPaper ? 0.50 : 0.64).toColor();
  }

  /// The same gel [degrees] round the colour wheel: a second lamp in a colour that
  /// goes with the first rather than the same one twice.
  static Color _turned(Color gel, double degrees, bool onPaper) {
    final hsl = HSLColor.fromColor(gel);
    return hsl.withHue((hsl.hue + degrees) % 360).withLightness(onPaper ? 0.50 : 0.62).toColor();
  }
}

/// One spot of light on the page.
class BallSpot {
  const BallSpot({
    required this.at,
    required this.wide,
    required this.tall,
    required this.lean,
    required this.far,
    required this.lamp,
    required this.tile,
  });

  final Offset at;
  final double wide;
  final double tall;

  /// The same spot in another frame of reference, [by] along.
  BallSpot shifted(Offset by) =>
      BallSpot(at: at + by, wide: wide, tall: tall, lean: lean, far: far, lamp: lamp, tile: tile);

  /// How far it is turned: a spot lies along the arc it is travelling.
  final double lean;

  /// How much further the light has come than the shortest way to the page, one and
  /// up. Further is dimmer.
  final double far;
  final int lamp;

  /// Which tile threw it, the same number for as long as the ball turns.
  final int tile;
}

/// Where the ball hangs over a page of [size]: above its top, in the middle.
Offset ballOver(Size size) => Offset(size.width / 2, -size.height * 0.06);

/// Where the ball's light lands on a page of [size], with the ball turned by [turn]
/// radians and [lamps] lamps on it.
///
/// The ball hangs above the top of the page and a little in front of it. A tile at
/// azimuth φ and tipped θ below level sends its ray to x = d·tan φ, y = d·tan θ / cos φ
/// on a wall d away — which is the whole of the look: rows that sag into arcs, spots
/// that speed up and smear as φ grows, and nothing at all from the half of the ball
/// that faces away.
List<BallSpot> spotsOnThePage(Size size, double turn, {int lamps = 3}) {
  final spots = <BallSpot>[];
  if (size.isEmpty) return spots;
  // A wide window is a wide room: the wall is further off, so the spots do not all
  // crowd into a fan at the top.
  final d = math.max(size.height * 0.55, size.width * 0.42);
  final ball = ballOver(size);
  final cx = ball.dx, cy = ball.dy;
  final base = 4.4 * (size.shortestSide / 400).clamp(1.0, 1.6);
  const rings = 6;
  var tile = 0;
  for (var ring = 0; ring < rings; ring++) {
    final tip = 0.15 + ring * 0.17;
    // Fewer tiles round a ring nearer the pole, as on the ball itself.
    final around = (24 * math.cos(tip)).round();
    for (var k = 0; k < around; k++, tile++) {
      // No ball is glued perfectly: every tile is a hair off true, always by the same
      // hair. It is what keeps the rows from reading as a printed grid.
      final h = ((tile * 2654435761) & 0xFFFF) / 65535.0;
      final h2 = ((tile * 40503 + 977) & 0xFFFF) / 65535.0;
      for (var lamp = 0; lamp < lamps; lamp++) {
        // Each lamp is somewhere else round the ball, so each throws its own rows a
        // hand's width along from the last rather than a twin beside every spot.
        var phi = (k / around) * 2 * math.pi + turn + ring * 0.37 + lamp * 0.43 + (h - 0.5) * 0.07;
        phi = (phi + math.pi) % (2 * math.pi) - math.pi;
        if (phi.abs() > 1.2) continue;
        final theta = tip + lamp * 0.075 + (h2 - 0.5) * 0.05;
        final cosPhi = math.cos(phi), cosTheta = math.cos(theta);
        final x = cx + d * math.tan(phi);
        final y = cy + d * math.tan(theta) / cosPhi;
        if (x < -40 || x > size.width + 40 || y < -40 || y > size.height + 40) continue;
        spots.add(BallSpot(
          at: Offset(x, y),
          wide: base * math.min(2.6, 1 / (cosPhi * cosPhi)),
          tall: base * math.min(2.2, 1 / (cosPhi * cosTheta)),
          lean: math.atan(math.tan(theta) * math.sin(phi)),
          far: 1 / (cosPhi * cosTheta),
          lamp: lamp,
          tile: tile,
        ));
      }
    }
  }
  return spots;
}

/// A moving head's beam on the wall: where it is, how big, which way it leans, and
/// how bright the desk has it.
class HeadBeam {
  const HeadBeam({required this.at, required this.rx, required this.ry, required this.lean, required this.level});
  final Offset at;
  final double rx, ry, lean, level;

  /// The same beam in another frame of reference, [by] along.
  HeadBeam shifted(Offset by) => HeadBeam(at: at + by, rx: rx, ry: ry, lean: lean, level: level);
}

/// Where the moving heads are pointing at [seconds] into the set, on a page of [size].
///
/// Each head follows a slow figure of its own — two sines, one across and one down,
/// that never quite repeat — and every [cue] seconds the desk sends it a new one: a
/// different pair of speeds and phases from a table, eased into over two seconds so
/// the beam glides rather than jumps. Nearer the sides the beam is longer, as a cone
/// that meets the wall obliquely is.
List<HeadBeam> headsOnThePage(Size size, double seconds, {required double cue, double beat = 0, double swing = 0.5}) {
  if (size.isEmpty) return const [];
  final heads = <HeadBeam>[];
  final s = size.shortestSide;
  Offset where(int head, int cueIndex, double t) {
    final k = (cueIndex * 7 + head * 3) % _cues.length;
    final c = _cues[k];
    // The heads sit on one bar and are pointed apart, so the second is the first
    // some way round its figure and mirrored across the room.
    final mirror = head.isOdd ? -1.0 : 1.0;
    final x = size.width * (0.5 + mirror * 0.36 * math.sin(t * c.$1 + c.$3 + head * 1.9));
    final y = size.height * (0.46 + 0.30 * math.sin(t * c.$2 + c.$4 + head * 0.7));
    return Offset(x, y);
  }

  final cueIndex = (seconds / cue).floor();
  final into = seconds - cueIndex * cue;
  final ease = Curves.easeInOutCubic.transform((into / 2.0).clamp(0.0, 1.0));
  for (var head = 0; head < 2; head++) {
    final now = where(head, cueIndex, seconds);
    final before = where(head, cueIndex - 1, seconds);
    final at = Offset.lerp(before, now, ease)!;
    // Obliquity: further from the middle of the wall, longer along the way it went.
    final off = ((at.dx - size.width / 2) / (size.width / 2)).clamp(-1.0, 1.0);
    final rx = s * (0.38 + 0.18 * off.abs());
    final ry = s * 0.27;
    // On the downbeat the desk pushes the level up; between, it breathes with the bar.
    final level = 0.62 + 0.14 * swing + 0.30 * beat * (head == 0 ? 1.0 : 0.6);
    heads.add(HeadBeam(at: at, rx: rx, ry: ry, lean: off * 0.35, level: level.clamp(0.0, 1.0)));
  }
  return heads;
}

/// The desk's cues: (speed across, speed down, phase across, phase down) in radians a
/// second. Slow, all of them — a beam takes ten to twenty seconds to cross the room.
const _cues = <(double, double, double, double)>[
  (0.31, 0.19, 0.0, 1.1),
  (0.22, 0.34, 2.1, 0.4),
  (0.41, 0.26, 0.7, 2.6),
  (0.17, 0.29, 3.0, 1.8),
  (0.36, 0.15, 1.4, 0.2),
  (0.27, 0.40, 2.7, 3.3),
  (0.45, 0.21, 0.3, 1.5),
];

class _Room extends CustomPainter {
  _Room({
    required this.clock,
    required this.life,
    required this.lamps,
    required this.heads,
    required this.onPaper,
    this.pulse,
    this.room,
    this.toLocal,
  }) : super(repaint: Listenable.merge([clock, life, if (pulse != null) pulse]));

  final AnimationController clock;
  final Animation<double> life;
  final List<Color> lamps;
  final List<Color> heads;
  final bool onPaper;
  final ValueListenable<double>? pulse;

  /// What stands in the room, for their shadows on the wall; null where nothing is
  /// listening.
  final RoomLight? room;
  final Offset Function(Offset global)? toLocal;

  /// The sprites the spots are stamped from, made once: a soft square of light in
  /// three widths, and a glint — the four-pointed star a mirror throws when it catches
  /// the lamp square on. Stamping a picture is one draw for every spot on the page;
  /// blurring each spot as it was drawn was hundreds of blurs a frame.
  static ui.Image? _atlas;
  static const _cell = 64.0;
  static const _aspects = [1.0, 1.6, 2.4];

  static ui.Image _sprites() {
    final made = _atlas;
    if (made != null) return made;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    for (var i = 0; i < _aspects.length; i++) {
      final a = _aspects[i];
      final centre = Offset(_cell * (i + 0.5), _cell / 2);
      // Most of the cell, so the halo has room; the core is a rounded tile.
      final w = _cell * 0.62, h = w / a;
      final tile = RRect.fromRectAndRadius(Rect.fromCenter(center: centre, width: w, height: h), const Radius.circular(4));
      c.drawRRect(tile.inflate(_cell * 0.08), Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      c.drawRRect(tile, Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.1));
    }
    // The glint: two soft spikes and a bright heart.
    final g = Offset(_cell * (_aspects.length + 0.5), _cell / 2);
    for (final (dx, dy) in const [(1.0, 0.0), (0.0, 1.0)]) {
      c.drawLine(g - Offset(dx, dy) * _cell * 0.44, g + Offset(dx, dy) * _cell * 0.44, Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2));
    }
    c.drawCircle(g, _cell * 0.09, Paint()
      ..color = Colors.white
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    final picture = rec.endRecording();
    return _atlas = picture.toImageSync((_cell * (_aspects.length + 1)).round(), _cell.round());
  }

  /// The frame's numbers from the clock and the beat: the seconds into the set, the
  /// beat, the bar's swell, and how long the desk holds a cue. The desk breathes
  /// with the bar where it knows one, and slowly on its own where it does not.
  static ({double seconds, double beat, double swing, double cue}) frameOf(double clock, ValueListenable<double>? pulse) {
    final seconds = clock * 240;
    final beat = pulse?.value ?? 0.0;
    final signal = pulse is BeatSignal ? pulse : null;
    final beatSeconds = signal?.beatSeconds;
    final swing = beatSeconds != null ? signal!.swing : 0.5 + 0.5 * math.sin(seconds * 0.6);
    final cue = beatSeconds != null ? beatSeconds * 32 : 24.0;
    return (seconds: seconds, beat: beat, swing: swing, cue: cue);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final lit = life.value;
    if (lit <= 0.001) return;
    final turn = clock.value * 3 * 2 * math.pi;
    final frame = frameOf(clock.value, pulse);
    final seconds = frame.seconds, beat = frame.beat, swing = frame.swing, cue = frame.cue;
    // Light adds to a dark room; on paper it can only tint, which is a multiply.
    final blend = onPaper ? BlendMode.multiply : BlendMode.plus;
    // Paper takes a tint where a dark room takes light, and needs more of it to show.
    final strength = onPaper ? 1.15 : 1.0;

    _wash(canvas, size, lit * strength, swing, blend);
    final beams = headsOnThePage(size, seconds, cue: cue, beat: beat, swing: swing);
    for (final (i, b) in beams.indexed) {
      _head(canvas, b, heads[i % heads.length], lit * strength, blend);
    }
    final spots = spotsOnThePage(size, turn, lamps: lamps.length);
    if (!onPaper) _haze(canvas, size, spots, lit, beat, swing);
    _spots(canvas, size, spots, seconds, beat, lit * strength, blend);
    _shadows(canvas, beams, lit);
  }

  /// The shadows of what stands in the room, on the wall behind: each beam throws
  /// one away from itself, softer and further the nearer the beam; and under
  /// everything a little darkness where it meets the wall, which is what says it is
  /// standing there and not printed on it.
  void _shadows(Canvas canvas, List<HeadBeam> beams, double lit) {
    final r = room, local = toLocal;
    if (r == null || local == null || r.placed.isEmpty) return;
    final ink = onPaper ? 0.5 : 1.0;
    for (final outline in r.placed.values) {
      final tl = local(Offset(outline.left, outline.top));
      final o = outline.shift(tl - Offset(outline.left, outline.top));
      final centre = o.center;
      canvas.drawRRect(
          o.inflate(2),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.16 * ink)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      for (final b in beams) {
        final away = centre - b.at;
        final d = away.distance;
        if (d < 1) continue;
        final near = (1 - d / (o.width + o.height)).clamp(0.0, 1.0);
        final throwBy = away / d * (10 + 22 * near);
        canvas.drawRRect(
            o.shift(throwBy).inflate(4 * near),
            Paint()
              ..color = Colors.black.withValues(alpha: (0.10 + 0.22 * near) * b.level * lit * ink)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 + 14 * near));
      }
    }
  }

  /// The wall behind the ball, lit by the lamps that point at it: a broad glow at the
  /// top of the page that breathes with the bar.
  void _wash(Canvas canvas, Size size, double lit, double swing, BlendMode blend) {
    final ball = ballOver(size);
    final colour = Color.lerp(Color.lerp(lamps[0], lamps[1], 0.5), lamps[2], 0.25)!;
    final a = (onPaper ? 0.16 : 0.13) * lit * (0.75 + 0.25 * swing);
    final r = size.width * 0.85;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = blend
        ..shader = ui.Gradient.radial(
          ball,
          r,
          [_lightColour(colour, a), _lightColour(colour, a * 0.35), _lightColour(colour, 0)],
          const [0.0, 0.4, 1.0],
        ),
    );
  }

  /// One moving head's cone on the wall: a soft ellipse, brighter at its heart.
  void _head(Canvas canvas, HeadBeam b, Color colour, double lit, BlendMode blend) {
    final a = (onPaper ? 0.34 : 0.36) * lit * b.level;
    canvas.save();
    canvas.translate(b.at.dx, b.at.dy);
    canvas.rotate(b.lean);
    canvas.scale(1, b.ry / b.rx);
    canvas.drawCircle(
      Offset.zero,
      b.rx,
      Paint()
        ..blendMode = blend
        ..shader = ui.Gradient.radial(
          Offset.zero,
          b.rx,
          [_lightColour(colour, a), _lightColour(colour, a * 0.55), _lightColour(colour, a * 0.12), _lightColour(colour, 0)],
          const [0.0, 0.3, 0.7, 1.0],
        ),
    );
    canvas.restore();
  }

  /// The rays in the haze, from the ball to a few of the spots it throws: thin
  /// triangles fading from the ball down, in one draw. Brightest on the beat, when the
  /// lamps on the ball are pushed up.
  void _haze(Canvas canvas, Size size, List<BallSpot> spots, double lit, double beat, double swing) {
    final ball = ballOver(size);
    final positions = <Offset>[];
    final colours = <Color>[];
    final top = 0.11 * lit * (0.5 + 0.5 * beat);
    for (final s in spots) {
      if (s.lamp == 2 || s.tile % 4 != s.lamp) continue;
      final dir = s.at - ball;
      final len = dir.distance;
      if (len < 1) continue;
      final n = Offset(-dir.dy, dir.dx) / len;
      final half = s.wide * 0.7 + 2.0;
      final colour = lamps[s.lamp];
      positions
        ..add(ball)
        ..add(s.at + n * half)
        ..add(s.at - n * half);
      colours
        ..add(_lightColour(colour, top))
        ..add(_lightColour(colour, top * 0.22))
        ..add(_lightColour(colour, top * 0.22));
    }
    if (positions.isEmpty) return;
    canvas.drawVertices(
      ui.Vertices(ui.VertexMode.triangles, positions, colors: colours),
      BlendMode.plus,
      Paint(),
    );
  }

  /// The spots themselves, stamped from the atlas in one draw; and a glint on the
  /// few tiles that catch their lamp square on.
  void _spots(Canvas canvas, Size size, List<BallSpot> spots, double seconds, double beat, double lit, BlendMode blend) {
    final atlas = _sprites();
    final transforms = <ui.RSTransform>[];
    final rects = <Rect>[];
    final colours = <Color>[];
    final glints = <ui.RSTransform>[];
    final glintRects = <Rect>[];
    final glintColours = <Color>[];
    const glintRect = Rect.fromLTWH(_cell * 3, 0, _cell, _cell);
    for (final s in spots) {
      // A tile catches its lamp a little more and a little less as the ball swings;
      // on the beat the desk pushes every lamp up, and some tiles make more of it than
      // others.
      final glint = 0.5 + 0.5 * math.sin(seconds * 0.9 + s.tile * 1.7);
      final catches = 0.5 + 0.5 * ((s.tile * 7) % 5) / 4;
      final reach = 1 / math.pow(s.far, 1.3);
      final a = ((0.15 + 0.13 * glint + 0.50 * beat * catches) * reach * lit).clamp(0.0, 1.0);
      if (a < 0.02) continue;
      final swell = 1 + 0.18 * beat * catches;
      final colour = lamps[s.lamp];
      final ratio = s.wide / s.tall;
      var which = 0;
      for (var i = 1; i < _aspects.length; i++) {
        if ((ratio - _aspects[i]).abs() < (ratio - _aspects[which]).abs()) which = i;
      }
      // The sprite's core is 0.62 of a cell wide: scaled so that core is the spot.
      final scale = s.wide * swell / (_cell * 0.62);
      transforms.add(ui.RSTransform.fromComponents(
        rotation: s.lean,
        scale: scale,
        anchorX: _cell / 2,
        anchorY: _cell / 2,
        translateX: s.at.dx,
        translateY: s.at.dy,
      ));
      rects.add(Rect.fromLTWH(_cell * which, 0, _cell, _cell));
      colours.add(_lightColour(colour, a));
      // The glint: a tile square on to its lamp for a moment, brightest as it passes.
      final square = math.sin(seconds * 0.9 + s.tile * 1.7 + 0.35 * s.lamp);
      if (square > 0.975 && s.far < 1.6) {
        final flash = ((square - 0.975) / 0.025).clamp(0.0, 1.0);
        final peak = math.sin(flash * math.pi);
        glints.add(ui.RSTransform.fromComponents(
          rotation: s.lean * 0.5,
          scale: (s.wide * 2.4 / _cell) * (0.7 + 0.5 * peak),
          anchorX: _cell / 2,
          anchorY: _cell / 2,
          translateX: s.at.dx,
          translateY: s.at.dy,
        ));
        glintRects.add(glintRect);
        glintColours.add(_lightColour(Color.lerp(colour, Colors.white, 0.5)!, (0.55 + 0.45 * beat) * peak * lit));
      }
    }
    if (transforms.isEmpty) return;
    final paint = Paint()..blendMode = blend;
    canvas.drawAtlas(atlas, transforms, rects, colours, BlendMode.modulate, null, paint);
    if (glints.isNotEmpty) {
      canvas.drawAtlas(atlas, glints, glintRects, glintColours, BlendMode.modulate, null, paint);
    }
  }

  /// A colour as light of strength [a]: on a dark ground the colour itself, added;
  /// on paper a pale tint of it, multiplied in, since paper cannot get any brighter.
  Color _lightColour(Color c, double a) {
    if (!onPaper) return c.withValues(alpha: a.clamp(0.0, 1.0));
    return Color.lerp(Colors.white, c, (a * 1.7).clamp(0.0, 1.0))!;
  }

  @override
  bool shouldRepaint(_Room old) =>
      !listEquals(old.lamps, lamps) || !listEquals(old.heads, heads) || old.onPaper != onPaper || old.pulse != pulse;
}
