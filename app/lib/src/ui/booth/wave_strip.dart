import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../mag.dart';

/// The three inks a record's shape is printed in: one for the bass, one for the middle,
/// one for the top.
///
/// Every DJ program does this and they nearly all agree on the idea, if not the hues:
/// Serato and rekordbox's RGB mode put the bass in red, the middle in green and the top
/// in blue; rekordbox's 3Band and the Denon players use blue, orange and white; Traktor
/// ships four palettes over the same three numbers. What a DJ reads off it is where the
/// bass goes out, where the vocal comes in, where the hats are — none of which a grey
/// shape can say, however finely it is drawn.
///
/// The colour is mixed from the three bands and then *normalised so the brightest of
/// the three channels is full*, which is the part that makes these waveforms work: hue
/// then carries the balance of the record and nothing else, so a bass passage reads as
/// bass whether it is loud or quiet, and a breakdown at a whisper is as legible as a
/// drop. How loud it is is the height. The two say different things and neither is
/// spent saying the other's.
class WaveInks {
  const WaveInks(this.low, this.mid, this.high,
      {required this.name, this.stacked = false});

  /// Drawn as three layers standing on each other rather than as one colour mixed from
  /// the three.
  ///
  /// The two are not a matter of taste, they are what each palette can carry. A mixed
  /// colour can only be read back if each ink owns a channel of its own, so a palette
  /// whose inks share one — rekordbox's 3Band and the Denon players', where the top is
  /// white and the middle orange, both of them mostly red — has to be stacked instead:
  /// each band gets its own slice of the column's height and keeps its own ink. It
  /// says less per column, because the *shape* now carries the balance rather than the
  /// colour, and a great many DJs prefer it anyway.
  final bool stacked;

  /// What each band is worth in the mix, as red, green and blue from 0 to 1.
  final Color low, mid, high;

  /// For settings, and for saying which is which in a test's name.
  final String name;

  /// The house's own red for the bass, a green for the middle, a blue for the top: the
  /// convention a DJ arriving from Serato or rekordbox already knows how to read, in
  /// this room's red rather than a signal red.
  ///
  /// The hues are not free, and it took two goes to believe it. A colour mixed from
  /// three bands can only be read back if each ink owns a channel of its own — which is
  /// the real reason Serato and rekordbox settled on red, green and blue rather than on
  /// anything prettier. Magenta and orange were tried first, being the inks of the
  /// decade this room is dressed in, and both are mostly red: the middle of a record
  /// vanished into its bass and every song printed pink. Then red, lime and cyan, which
  /// is warmer and looks like the room — and lime and cyan both own green, so the top
  /// of a record vanished into its middle and a breakdown printed lime instead of
  /// cyan. One ink per channel is not a style; it is the condition of the picture
  /// meaning anything.
  static const press = WaveInks(
      Color(0xFFFF4A3D), Color(0xFF3FD86A), Color(0xFF4A7BFF),
      name: 'press');

  /// rekordbox's 3Band, and the CDJs': bass blue, middle orange, top white. Stacked,
  /// because white and orange cannot be told apart in a mixture.
  static const threeBand = WaveInks(
      Color(0xFF2E6BFF), Color(0xFFFF8A2B), Color(0xFFF3F0E8),
      name: 'three-band', stacked: true);

  /// No colour at all, for a deck that would rather read the shape. Traktor calls its
  /// version X-Ray and there are DJs who will use nothing else.
  static const xray = WaveInks(
      Color(0xFFEDE9E1), Color(0xFFEDE9E1), Color(0xFFEDE9E1),
      name: 'x-ray');

  static const all = [press, threeBand, xray];
}

/// The colour one column of a record is printed in, from how much of it is bass, middle
/// and top — each 0 to 1 — as a plain ARGB word.
///
/// Mixed from the three inks, de-greyed, then taken up so the brightest channel is
/// full. See the comments inside for why each of those three steps is there; between
/// them they are the whole of what makes a coloured waveform readable, and leaving any
/// one out gives a picture that looks coloured and says nothing.
int waveInk(WaveInks inks, double l, double m, double t) {
  var r = l * inks.low.r + m * inks.mid.r + t * inks.high.r;
  var g = l * inks.low.g + m * inks.mid.g + t * inks.high.g;
  var b = l * inks.low.b + m * inks.mid.b + t * inks.high.b;
  // The grey out. Serato and rekordbox add their bands straight into red, green and
  // blue and are done — they can, because their three inks *are* red, green and blue,
  // so each band lands in a channel of its own and the mixture is a readout. Three inks
  // chosen for a house rather than for a colour wheel all carry some of every channel,
  // so every mixture drifts towards white and the record comes out a pale pink lump,
  // which is what the first drawing of this was. What makes a colour pale is the part
  // all three channels share, so most of it goes.
  final dull = math.min(r, math.min(g, b)) * 0.75;
  r -= dull;
  g -= dull;
  b -= dull;
  // And up to full. This is the step that matters most: after it, hue carries the
  // balance of the record and nothing else, so a bass passage reads as bass whether it
  // is loud or quiet and a breakdown at a whisper is as legible as a drop. How loud it
  // is, the height says. Neither is spent saying the other's part.
  final bright = math.max(r, math.max(g, b));
  if (bright > 0) {
    final f = 1 / bright;
    r *= f;
    g *= f;
    b *= f;
  }
  return 0xFF000000 |
      ((r * 255).round().clamp(0, 255) << 16) |
      ((g * 255).round().clamp(0, 255) << 8) |
      (b * 255).round().clamp(0, 255);
}

/// How much of the record the shape's slices cover, in microseconds.
///
/// The file's length as the analysis measured it, where there is one. The slices were
/// taken across the file from end to end, so they have to be laid out across the file
/// — not across whatever the engine says the record is. Those are two different
/// measurements of the same thing: normally the same to the millisecond, and on some
/// containers a second apart. Where they differ, laying the slices over the engine's
/// number slides the shape against the grid drawn on the same strip, further the
/// further through the record you are — and a second of a four-minute record is two
/// beats, which is a picture arguing with its own ruler about where the drop is.
double slicesSpan(TrackTiming? timing, double engineUs) =>
    (timing?.durationMs ?? 0) > 0 ? timing!.durationMs * 1000.0 : engineUs;

/// A song's shape printed as a strip, with the grid on it.
///
/// Three inks: the bass as the heavy one, the middle over it, the top as the finest —
/// so "the bass drops out here" is visible from across the room, which is the one
/// thing a DJ reads off a waveform. Beat ticks along the foot, downbeats taller, a
/// rule through the lane every four bars where the record's sections start, the
/// phrases bracketed along the head, the mix-in and mix-out cues flagged, the loop
/// shaded. The playhead stands a third of the way in and the song runs under it.
///
/// Dragging scrubs: the song moves under the finger, and where it stops is where it
/// plays from. Drawn from a position notifier so the strip repaints on its own
/// clock and nothing else does.
class WaveStrip extends StatefulWidget {
  const WaveStrip({
    super.key,
    required this.position,
    required this.timing,
    required this.bands,
    required this.duration,
    required this.playing,
    this.loop,
    this.hotCues = const {},
    this.cueLabels = const {},
    this.window = const Duration(seconds: 20),
    this.height = 72,
    this.onScrub,
    this.accent,
    this.markAt,
    this.mirrored = false,
    this.inks = WaveInks.press,
    this.gains,
  });

  /// Which three inks the shape is printed in.
  final WaveInks inks;

  /// What the mixer is doing to each band, as a plain factor — 1 for a knob at noon, 0
  /// for one killed. Given, the shape is drawn as the room *hears* the record rather
  /// than as it was recorded: kill the bass and the bass goes out of the picture too.
  /// Serato has done this for years and it is the thing people miss most when it is
  /// not there. Null to draw the record as it is.
  final ({double low, double mid, double high})? gains;

  /// A moment worth flagging that is not the song's own — where the booth means to
  /// mix out of it.
  final Duration? markAt;

  /// Hanging from the top rather than standing on the foot, so two of these can face
  /// each other and their beats line up to the eye.
  final bool mirrored;

  final ValueListenable<Duration> position;
  final TrackTiming? timing;
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final Duration duration;
  final bool playing;
  final (Duration, Duration)? loop;
  final Map<int, Duration> hotCues;

  /// The word on a cue's flag where it is not its number: what the booth placed it
  /// for (Deck.padLabel).
  final Map<int, String> cueLabels;

  /// How much of the song the strip shows at once.
  final Duration window;
  final double height;
  final void Function(Duration to)? onScrub;
  final Color? accent;

  @override
  State<WaveStrip> createState() => _WaveStripState();
}

class _WaveStripState extends State<WaveStrip> {
  /// Where the record was when the finger went down, and how far it has travelled
  /// since — in pixels, added up.
  ///
  /// Every update used to be read off `position.value`, the *live* playhead, and have
  /// that update's delta taken off it. Two things move that number while a finger is
  /// on it: the record is playing, and the seek asked for on the last frame has not
  /// landed yet — the engine reports where it still is for a few frames after being
  /// told to move. So each frame subtracted its delta from a base that was somewhere
  /// else, and the strip stuttered, jumped back, or stuck. Anchored once and measured
  /// from there, a drag of n pixels is n pixels of record, whatever the engine is
  /// saying meanwhile. (The same way the EQ knobs take their start; see meters.dart.)
  Duration? _from;
  double _by = 0;

  /// The record's picture, kept between frames. See [_Tiles].
  final _tiles = _Tiles();

  @override
  void dispose() {
    _tiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final position = widget.position;
    final window = widget.window;
    final duration = widget.duration;
    final onScrub = widget.onScrub;
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: onScrub == null
            ? null
            : (_) {
                _from = position.value;
                _by = 0;
              },
        onHorizontalDragEnd: onScrub == null ? null : (_) => _from = null,
        onHorizontalDragCancel: onScrub == null ? null : () => _from = null,
        onHorizontalDragUpdate: onScrub == null
            ? null
            : (d) {
                final from = _from ??= position.value;
                _by += d.delta.dx;
                final perPixel = window.inMicroseconds / width;
                final at = from - Duration(microseconds: (_by * perPixel).round());
                onScrub(Duration(
                    microseconds: at.inMicroseconds.clamp(0, duration.inMicroseconds)));
              },
        child: SizedBox(
          // As wide as it is given: a painter with no child is as wide as nothing.
          width: width,
          height: widget.height,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _StripPainter(
                tiles: _tiles,
                dpr: MediaQuery.devicePixelRatioOf(context),
                position: position,
                timing: widget.timing,
                bands: widget.bands,
                duration: duration,
                window: window,
                loop: widget.loop,
                hotCues: widget.hotCues,
                cueLabels: widget.cueLabels,
                markAt: widget.markAt,
                mirrored: widget.mirrored,
                inks: widget.inks,
                gains: widget.gains,
                ink: scheme.onSurface,
                accent: widget.accent ?? scheme.primary,
                paper: scheme.surface,
                quiet: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Words already measured, kept between frames.
///
/// Laying a TextSpan out is shaping it — choosing glyphs, measuring them, breaking
/// the line — and the strip was doing that from scratch on every frame for every
/// section name, every phrase number, every DROP and every flag, on two lanes at
/// sixty frames a second. None of those strings change. They are measured once here
/// and drawn from then on, which is the difference between the strip costing a
/// dozen text layouts a frame and none.
final _laidOut = <(String, TextStyle), TextPainter>{};

TextPainter _measured(String text, TextStyle style) {
  final key = (text, style);
  final had = _laidOut[key];
  if (had != null) return had;
  // A record's bar numbers are the only unbounded part of this, and a long one has a
  // few hundred: cleared rather than grown without end.
  if (_laidOut.length > 400) _laidOut.clear();
  final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
    ..layout();
  _laidOut[key] = tp;
  return tp;
}

/// A record's loudness in three bands, one column a pixel wide each, for one tile.
typedef _Columns = ({Uint8List lo, Uint8List md, Uint8List hi});

/// The strip's picture, in pieces laid along the record rather than across the
/// screen.
///
/// Nearly everything on a strip is fixed to the record: its shape, its beats, its
/// four-bar rules, its phrases, its sections, its cues. Only where the needle is
/// changes from frame to frame — so the strip was spending sixty frames a second,
/// on two lanes, working out again where sixteen hundred columns, five hundred beat
/// ticks and a few dozen words go, to show them all one pixel to the left. Here they
/// are drawn once, in tiles [width] pixels of record wide, into pictures that are
/// kept; a frame is a few of those pictures put down at a new place. It also stops a
/// thing the old way could not help: each frame re-sorted the record's slices into
/// columns from a slightly different start, so the shape shimmered as it ran. Laid
/// along the record, a column is the same column all the way across the screen.
///
/// Three layers, because they go stale at different times. What stands under the
/// loop's shading (the sections), the shape (which the mixer's EQ re-colours while it
/// moves), and the grid and words over it. A knob turning re-draws the shape's tiles
/// from columns already sorted, and nothing else.
class _Tiles {
  static const width = 512.0;

  /// Microseconds of record a pixel of tile is: the strip's zoom when they were made.
  /// A deck's pitch changes the zoom a little (the window is in the room's time), and
  /// within a per cent and a half the tiles are stretched to fit rather than redrawn —
  /// a few pixels in a few hundred, which nobody can see, against a full redraw on
  /// every bend of a tempo glide.
  double scale = 0;
  double height = 0;

  Object? _binsKey, _underKey, _shapeKey, _overKey;
  final _bins = <int, _Columns?>{};
  final _under = <int, ui.Picture>{};
  final _shape = <int, ui.Picture>{};
  final _over = <int, ui.Picture>{};

  /// The edges' fades, made once for a size.
  (double, double, Color)? _fadeKey;
  Shader? _fadeLeft, _fadeRight;

  /// Lets go of everything when the zoom or the lane's height changes.
  void rescale(double usPerPixel, double h) {
    scale = usPerPixel;
    height = h;
    _binsKey = _underKey = _shapeKey = _overKey = null;
    _bins.clear();
    _drop(_under);
    _drop(_shape);
    _drop(_over);
  }

  bool fits(double usPerPixel, double h) =>
      scale > 0 && h == height && (usPerPixel / scale - 1).abs() <= 0.015;

  /// Keeps [layer] if [key] is what it was made for; empties it if not.
  static Object? _check(Map<int, ui.Picture> layer, Object? had, Object key) {
    if (had != key) _drop(layer);
    return key;
  }

  void checkBins(Object key) {
    if (_binsKey != key) {
      _bins.clear();
      _drop(_shape);
      _shapeKey = null;
    }
    _binsKey = key;
  }

  void checkUnder(Object key) => _underKey = _check(_under, _underKey, key);
  void checkShape(Object key) => _shapeKey = _check(_shape, _shapeKey, key);
  void checkOver(Object key) => _overKey = _check(_over, _overKey, key);

  /// Tiles far from [around] go, so a long record played through does not keep every
  /// tile it has ever shown.
  void forgetFarFrom(int around) {
    for (final layer in [_under, _shape, _over]) {
      layer.removeWhere((k, p) {
        final far = (k - around).abs() > 8;
        if (far) p.dispose();
        return far;
      });
    }
    _bins.removeWhere((k, _) => (k - around).abs() > 8);
  }

  static void _drop(Map<int, ui.Picture> layer) {
    for (final p in layer.values) {
      p.dispose();
    }
    layer.clear();
  }

  void dispose() {
    _drop(_under);
    _drop(_shape);
    _drop(_over);
    _bins.clear();
    _fadeLeft = _fadeRight = null;
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.tiles,
    required this.dpr,
    required this.position,
    required this.timing,
    required this.bands,
    required this.duration,
    required this.window,
    required this.loop,
    required this.hotCues,
    required this.cueLabels,
    required this.markAt,
    required this.mirrored,
    required this.inks,
    required this.gains,
    required this.ink,
    required this.accent,
    required this.paper,
    required this.quiet,
  }) : super(repaint: position);

  final _Tiles tiles;
  final double dpr;
  final ValueListenable<Duration> position;
  final TrackTiming? timing;
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final Duration duration;
  final Duration window;
  final (Duration, Duration)? loop;
  final Map<int, Duration> hotCues;
  final Map<int, String> cueLabels;
  final Duration? markAt;
  final bool mirrored;
  final WaveInks inks;
  final ({double low, double mid, double high})? gains;
  final Color ink, accent, paper, quiet;

  /// Where the playhead stands: a third in, so most of the strip is what is coming.
  static const _head = 0.34;

  static const _tw = _Tiles.width;

  @override
  void paint(Canvas canvas, Size size) {
    final total = duration.inMicroseconds.toDouble();
    if (total <= 0) {
      _empty(canvas, size);
      return;
    }
    final w = size.width, h = size.height;
    // Nothing past the strip's edges: a flag near the end was printed on the panel.
    canvas.clipRect(Offset.zero & size);
    if (mirrored) {
      // Turned over about its middle: the shape hangs from the top, the grid runs
      // along the head. Everything below is drawn once, the right way up.
      canvas.translate(0, h);
      canvas.scale(1, -1);
    }
    final perPixel = window.inMicroseconds / w;
    final at = position.value.inMicroseconds.toDouble();
    final left = at - _head * w * perPixel;
    double xOf(double us) => (us - left) / perPixel;

    // The line the shape stands about, and how far either side of it it may reach.
    // Room left under it for the beat ticks and over it for the phrase brackets.
    final axis = h * 0.46;
    canvas.drawLine(Offset(0, axis), Offset(w, axis),
        Paint()..color = ink.withValues(alpha: 0.12)..strokeWidth = 1);

    // The tiles: made at this zoom unless the last ones are close enough to stretch.
    if (!tiles.fits(perPixel, h)) tiles.rescale(perPixel, h);
    final scale = tiles.scale;
    // Screen pixels to a tile pixel, and where the screen's left edge is in tile
    // pixels.
    final k = scale / perPixel;
    final leftX = left / scale;
    final first = (leftX / _tw).floor();
    final last = ((leftX + w / k) / _tw).floor();
    tiles.forgetFarFrom((first + last) ~/ 2);
    final colours = (ink, accent, paper, quiet);
    tiles.checkUnder((timing, mirrored, colours));
    final b = bands;
    final hasShape = b != null && b.low.isNotEmpty;
    if (hasShape) {
      tiles.checkBins((b, slicesSpan(timing, total)));
      tiles.checkShape((inks, gains));
    }
    tiles.checkOver((timing, mirrored, colours, total));

    void lay(Map<int, ui.Picture> layer, ui.Picture Function(int i) make) {
      for (var i = first; i <= last; i++) {
        final p = layer[i] ??= make(i);
        // Put down on a whole device pixel, so a tick or a column stays crisp
        // rather than smearing across two pixels as it travels.
        final dx = ((i * _tw - leftX) * k * dpr).roundToDouble() / dpr;
        canvas.save();
        canvas.translate(dx, 0);
        if (k != 1) canvas.scale(k, 1);
        canvas.drawPicture(p);
        canvas.restore();
      }
    }

    lay(tiles._under, (i) => _tile(i, (c, x0) => _drawUnder(c, x0, h)));

    // The loop, shaded, over the sections and under everything else.
    final lp = loop;
    if (lp != null) {
      final x0 = xOf(lp.$1.inMicroseconds.toDouble()), x1 = xOf(lp.$2.inMicroseconds.toDouble());
      canvas.drawRect(Rect.fromLTRB(x0.clamp(0, w), 0, x1.clamp(0, w), h),
          Paint()..color = accent.withValues(alpha: 0.10));
    }

    if (hasShape) {
      lay(tiles._shape, (i) => _tile(i, (c, x0) => _drawShape(c, i, x0, h, total)));
    } else {
      // No shape yet: a quiet line, so the grid still has something to stand on.
      canvas.drawRect(
          Rect.fromLTWH(0, axis - 1.5, w, 3), Paint()..color = ink.withValues(alpha: 0.10));
    }

    lay(tiles._over, (i) => _tile(i, (c, x0) => _drawOver(c, x0, h, total)));

    for (final e in hotCues.entries) {
      _flag(canvas, xOf(e.value.inMicroseconds.toDouble()), cueLabels[e.key] ?? '${e.key}', h, 0, w,
          hot: true);
    }
    // Where the booth means to mix out of this record: a rule with a hatched run up
    // to it, so how long there is left to it is read off the strip rather than the
    // countdown alone.
    final mark = markAt;
    if (mark != null) {
      final x = xOf(mark.inMicroseconds.toDouble());
      if (x > -40 && x < w + 40) {
        final from = math.max(0.0, xOf(at));
        if (x > from) {
          canvas.drawRect(Rect.fromLTRB(from, 0, math.min(w, x), h),
              Paint()..color = accent.withValues(alpha: 0.07));
        }
        canvas.drawLine(Offset(x, 0), Offset(x, h),
            Paint()..color = accent..strokeWidth = 1.4
              ..strokeCap = StrokeCap.round);
        _flag(canvas, x, 'MIX', h, 0, w);
      }
    }

    // The playhead: a rule in the accent, a notch at its head — on a dark backing, so
    // that it is still a line where the record under it happens to be the same colour.
    // A red needle over a red kick was invisible exactly when it mattered.
    final x = _head * w;
    canvas.drawRect(Rect.fromLTRB(x - 2.2, 0, x + 2.2, h),
        Paint()..color = paper.withValues(alpha: 0.85));
    canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = accent..strokeWidth = 1.6);
    canvas.drawPath(
        Path()..moveTo(x - 5, 0)..lineTo(x + 5, 0)..lineTo(x, 6)..close(), Paint()..color = accent);

    // The edges fade, so the strip reads as a window onto the song, not the song.
    final fk = (w, h, paper);
    if (tiles._fadeKey != fk) {
      tiles._fadeKey = fk;
      tiles._fadeLeft = LinearGradient(colors: [paper, paper.withValues(alpha: 0)])
          .createShader(Rect.fromLTRB(0, 0, 18, h));
      tiles._fadeRight = LinearGradient(colors: [paper.withValues(alpha: 0), paper])
          .createShader(Rect.fromLTRB(w - 18, 0, w, h));
    }
    canvas.drawRect(Rect.fromLTRB(0, 0, 18, h), Paint()..shader = tiles._fadeLeft);
    canvas.drawRect(Rect.fromLTRB(w - 18, 0, w, h), Paint()..shader = tiles._fadeRight);
  }

  /// One tile's picture: [draw] is handed the canvas and the tile's left edge in tile
  /// pixels of record, and draws in tile pixels with that edge at nought. Clipped to
  /// the tile, hard, so whatever crosses into the next tile is drawn by each up to
  /// their common edge and not twice over it.
  ui.Picture _tile(int i, void Function(Canvas c, double x0) draw) {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    c.clipRect(Rect.fromLTWH(0, -tiles.height, _tw, tiles.height * 3), doAntiAlias: false);
    draw(c, i * _tw);
    return r.endRecording();
  }

  /// Under the loop: what the record is doing here, where the house has read it off
  /// the stems — each section named at its start, a breakdown shaded, a drop marked.
  void _drawUnder(Canvas canvas, double x0, double h) {
    final structure = timing?.structure;
    if (structure == null || structure.sections.isEmpty) return;
    final scale = tiles.scale;
    double xOf(double us) => us / scale - x0;
    final line = Paint()..color = quiet.withValues(alpha: 0.35)..strokeWidth = 1;
    final style = TextStyle(fontSize: 7.5, letterSpacing: 0.8, color: quiet, fontWeight: FontWeight.w700);
    for (final s in structure.sections) {
      final a = xOf(s.startMs * 1000.0), z = xOf(s.endMs * 1000.0);
      if (z < 0 || a > _tw + 80) continue;
      if (s.label == 'breakdown' || s.label == 'build') {
        canvas.drawRect(Rect.fromLTRB(a, 0, z, h),
            Paint()..color = quiet.withValues(alpha: s.label == 'build' ? 0.10 : 0.07));
      }
      canvas.drawLine(Offset(a, 0), Offset(a, h), line);
      final tp = _measured(s.label.toUpperCase(), style);
      canvas.save();
      if (mirrored) {
        canvas.translate(a + 3, h - 2);
        canvas.scale(1, -1);
        tp.paint(canvas, Offset.zero);
      } else {
        tp.paint(canvas, Offset(a + 3, 2));
      }
      canvas.restore();
    }
    final drop = Paint()..color = ink.withValues(alpha: 0.6)..strokeWidth = 1.5;
    for (final d in structure.dropsMs) {
      final x = xOf(d * 1000.0);
      if (x < -2 || x > _tw + 2) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, h), drop);
    }
  }

  /// The record's loudness sorted into columns a pixel of tile wide, once for a
  /// tile at a zoom: the loudest slice of each band under each column.
  _Columns? _columns(int i, double total) {
    if (tiles._bins.containsKey(i)) return tiles._bins[i];
    final b = bands!;
    final n = b.low.length;
    final usPerSlice = slicesSpan(timing, total) / n;
    final scale = tiles.scale;
    final cols = _tw.toInt();
    final lo = Uint8List(cols), md = Uint8List(cols), hi = Uint8List(cols);
    final low = b.low, mid = b.mid, high = b.high;
    var any = false;
    for (var px = 0; px < cols; px++) {
      final us0 = (i * _tw + px) * scale, us1 = us0 + scale;
      var i0 = (us0 / usPerSlice).floor();
      var i1 = (us1 / usPerSlice).ceil();
      if (i1 <= 0 || i0 >= n) continue;
      if (i0 < 0) i0 = 0;
      if (i1 > n) i1 = n;
      if (i1 <= i0) i1 = i0 + 1;
      var l = 0, m = 0, t = 0;
      for (var j = i0; j < i1; j++) {
        final a = low[j], c = mid[j], e = high[j];
        if (a > l) l = a;
        if (c > m) m = c;
        if (e > t) t = e;
      }
      lo[px] = l;
      md[px] = m;
      hi[px] = t;
      any = true;
    }
    final got = any ? (lo: lo, md: md, hi: hi) : null;
    tiles._bins[i] = got;
    return got;
  }

  /// The shape: a column a pixel wide for each pixel across, standing about the
  /// middle line rather than on the floor.
  ///
  /// Three filled outlines drawn over each other was what this was, and it could not
  /// work. Each band was a polygon from the foot up in its own ink at its own alpha,
  /// so the loudest band painted over the other two and the picture was one colour
  /// with a wash on it — a record's bass and its hats were the same shape in the same
  /// red. Worse, every band was normalised against *itself* on the house, so the three
  /// heights had no relation to each other at all (see peaks.py).
  ///
  /// A column takes the loudest slice under it, mixes the three bands into one colour,
  /// normalises that colour so its brightest channel is full, and stands it about the
  /// middle at the height of the loudest band. Hue is the balance of the record;
  /// height is how loud it is. Both sides of the middle, because that is what every DJ
  /// has looked at for twenty years and because a shape about a line is read faster
  /// than a skyline — the eye follows one edge and gets the other for nothing.
  ///
  /// Drawn as one call: a triangle pair per column into one Vertices, rather than a
  /// rectangle each.
  void _drawShape(Canvas canvas, int i, double x0, double h, double total) {
    final cols = _columns(i, total);
    if (cols == null) return;
    final axis = h * 0.46;
    final half = h * 0.36;
    final gain = gains;
    final gl = gain?.low ?? 1.0, gm = gain?.mid ?? 1.0, gh = gain?.high ?? 1.0;
    final n = cols.lo.length;
    final layers = inks.stacked ? 3 : 1;
    final xy = Float32List(n * 12 * layers);
    final tint = Int32List(n * 6 * layers);
    final highInk = inks.high.toARGB32(), midInk = inks.mid.toARGB32(), lowInk = inks.low.toARGB32();
    var v = 0, c = 0;
    for (var px = 0; px < n; px++) {
      final l = cols.lo[px] * gl / 255, m = cols.md[px] * gm / 255, t = cols.hi[px] * gh / 255;
      final peak = math.max(l, math.max(m, t));
      if (peak <= 0.004) continue;
      final a = px.toDouble(), z = a + 1;
      void quad(double to, int argb) {
        xy[v++] = a; xy[v++] = axis - to;
        xy[v++] = z; xy[v++] = axis - to;
        xy[v++] = z; xy[v++] = axis + to;
        xy[v++] = a; xy[v++] = axis - to;
        xy[v++] = z; xy[v++] = axis + to;
        xy[v++] = a; xy[v++] = axis + to;
        for (var q = 0; q < 6; q++) {
          tint[c++] = argb;
        }
      }
      // A floor under it so a quiet passage is a thin line rather than a gap: a
      // record with nothing in it still has to show where it is.
      final tall = half * (0.03 + 0.97 * peak);
      if (inks.stacked) {
        // Outermost first, each layer painted over the one under it: the top of the
        // record stands on the middle, which stands on the bass. The column is as
        // tall as the loudest band either way, so the two kinds of palette draw a
        // record at the same size and only differ in what fills it.
        final sum = l + m + t;
        if (sum <= 0) continue;
        quad(tall, highInk);
        quad(tall * (l + m) / sum, midInk);
        quad(tall * l / sum, lowInk);
      } else {
        quad(tall, waveInk(inks, l, m, t));
      }
    }
    if (v > 0) {
      canvas.drawVertices(
          ui.Vertices.raw(ui.VertexMode.triangles, Float32List.sublistView(xy, 0, v),
              colors: Int32List.sublistView(tint, 0, c)),
          BlendMode.dst,
          Paint());
    }
  }

  /// Over the shape: the grid — ticks along the foot, downbeats taller and darker —
  /// the four-bar rules, the phrases, the drops and the record's own cues.
  void _drawOver(Canvas canvas, double x0, double h, double total) {
    final t = timing;
    if (t == null || !t.hasBeats) return;
    final scale = tiles.scale;
    double xOf(double us) => us / scale - x0;
    // A little past each edge, for what straddles it.
    final usFrom = (x0 - 4) * scale, usTo = (x0 + _tw + 4) * scale;
    final tick = Paint()..color = ink.withValues(alpha: 0.35)..strokeWidth = 1;
    final down = Paint()..color = ink.withValues(alpha: 0.7)..strokeWidth = 1.2;
    final steady = t.steady;
    if (steady != null) {
      // The steady grid, the one SYNC and the beat-holding use: two records held on
      // the beat show their ticks in one line down both strips.
      final from = ((usFrom / 1000 - steady.origin) / steady.period).floor();
      final to = ((usTo / 1000 - steady.origin) / steady.period).ceil();
      for (var k = from; k <= to; k++) {
        final ms = steady.origin + k * steady.period;
        if (ms < t.beats.first - steady.period || ms > t.beats.last + steady.period) continue;
        final x = xOf(ms * 1000);
        final isDown = ((k - t.barStartsOn) % 4 + 4) % 4 == 0;
        canvas.drawLine(Offset(x, h), Offset(x, h - (isDown ? 10 : 5)), isDown ? down : tick);
      }
    } else {
      final beats = t.beats;
      for (var i = 0; i < beats.length; i++) {
        final us = beats[i] * 1000.0;
        if (us < usFrom) continue;
        if (us > usTo) break;
        final x = xOf(us);
        final isDown = (i - t.barStartsOn) % 4 == 0;
        canvas.drawLine(Offset(x, h), Offset(x, h - (isDown ? 10 : 5)), isDown ? down : tick);
      }
    }
    // Every four bars, from where the record's sections start: a rule the height of
    // the lane and the tallest tick, so two records lined up for a mix show it —
    // their rules pass the playhead together, strip over strip.
    final four = Paint()..color = ink.withValues(alpha: 0.3)..strokeWidth = 1;
    final fourTick = Paint()..color = ink.withValues(alpha: 0.9)..strokeWidth = 2;
    for (final m in t.markers) {
      // Where the house put them, not where this would put them.
      //
      // They used to be snapped to the grid fitted here, four beats at a time,
      // anchored on the bar phase. Where the two agree that does nothing; where
      // they do not — the marks on one in forty records are not all on the same
      // beat of the bar — it moved each rule on its own by as much as two beats,
      // which is a phrase grid that is neither the house's nor evenly spaced. The
      // marks are every fourth downbeat and already on the beat; re-deciding that
      // from a second fit can only be a way to be wrong.
      final us = m * 1000.0;
      if (us < usFrom) continue;
      if (us > usTo) break;
      final x = xOf(us);
      canvas.drawLine(Offset(x, 0), Offset(x, h), four);
      canvas.drawLine(Offset(x, h), Offset(x, h - 18), fourTick);
    }
    // Phrases: a bracket along the head, with the bar count typed at its start.
    final phrases = t.phrases;
    final bracket = Paint()..color = ink.withValues(alpha: 0.55)..strokeWidth = 1;
    final end = xOf(total) + 20;
    for (var i = 0; i < phrases.length; i++) {
      final x = xOf(phrases[i] * 1000.0);
      final to = i + 1 < phrases.length ? xOf(phrases[i + 1] * 1000.0) : end;
      if (to < 0 || x > _tw + 30) continue;
      canvas.drawLine(Offset(x, 4), Offset(to - 3, 4), bracket);
      canvas.drawLine(Offset(x, 4), Offset(x, 10), bracket);
      _type(canvas, '${i + 1}', Offset(x + 3, 5), quiet, 8);
    }
    // Where the song opens up, drawn the full height of the lane: the thing a mix
    // is landed on, so it has to be visible from further away than a flag.
    final dropPaint = Paint()..color = accent.withValues(alpha: 0.35);
    for (final d in t.drops) {
      final x = xOf(d * 1000.0);
      if (x < -40 || x > _tw + 2) continue;
      canvas.drawRect(Rect.fromLTWH(x - 1.5, 0, 3, h), dropPaint);
      _type(canvas, 'DROP', Offset(x + 5, h * 0.36), accent, 8);
    }
    // The cues: IN and OUT flags in the accent, the way a mark is put on a record.
    final cues = t.cues;
    if (cues != null) {
      _flag(canvas, xOf(cues.mixInMs * 1000.0), 'IN', h, -40, _tw + 30);
      _flag(canvas, xOf(cues.mixOutMs * 1000.0), 'OUT', h, -40, _tw + 30);
    }
  }

  /// A flag on a rule, if [x] falls between [from] and [to].
  void _flag(Canvas canvas, double x, String text, double h, double from, double to,
      {bool hot = false}) {
    if (x < from - 30 || x > to + 30) return;
    final c = hot ? ink : accent;
    canvas.drawLine(Offset(x, 12), Offset(x, h - 12),
        Paint()..color = c.withValues(alpha: 0.7)..strokeWidth = 1);
    final tp = _measured(text, Mag.flag(7.5, color: paper));
    final box = Rect.fromLTWH(x, 12, tp.width + 6, tp.height + 3);
    canvas.drawRect(box, Paint()..color = c);
    _write(canvas, tp, Offset(x + 3, 13.5));
  }

  void _type(Canvas canvas, String text, Offset at, Color c, double size) {
    _write(canvas, _measured(text, Mag.typewriter(size, color: c)), at);
  }

  /// Words the right way up, whichever way the strip is drawn: the shape and the
  /// grid turn over with the lane, the reading matter does not.
  void _write(Canvas canvas, TextPainter tp, Offset at) {
    if (!mirrored) {
      tp.paint(canvas, at);
      return;
    }
    canvas.save();
    canvas.translate(at.dx, at.dy + tp.height);
    canvas.scale(1, -1);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void _empty(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height * 0.78), Offset(size.width, size.height * 0.78),
        Paint()..color = ink.withValues(alpha: 0.12)..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.tiles != tiles ||
      old.dpr != dpr ||
      old.markAt != markAt ||
      old.mirrored != mirrored ||
      old.inks != inks ||
      old.gains != gains ||
      old.timing != timing ||
      old.bands != bands ||
      old.duration != duration ||
      old.window != window ||
      old.loop != loop ||
      old.hotCues != hotCues ||
      !mapEquals(old.cueLabels, cueLabels) ||
      old.accent != accent ||
      old.ink != ink ||
      old.paper != paper ||
      old.quiet != quiet;
}
