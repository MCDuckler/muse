// The words: the record's lyrics set on the stage as type, and nothing else — no
// pictures, no models, the letters are the figure. A simulation (show_sims.dart's
// `words`) that reads the line being sung off the frame (ShowDeck.lyric/lyricK, from
// the synced lyrics LRCLIB has for the song, aligned to where the voice is), keeps a
// score of the lines as they come, and sets them in one of five styles, a section at
// a time, every one of them answering the record:
//
//   poster      the line set huge, black, extra condensed, as a gig poster's block,
//               ragged left, low on the page; the words light up as they are sung
//               (the one being sung in the accent), a rule above fills with the line,
//               the one before hangs over it fading; the bass widens the letters, the
//               kick drops the block a step, the downbeat flares the rule.
//   stencil     the line cut out of black in letters that fill the frame, rows of
//               them: the ground (MilkDrop, the room, the cover) shows only through
//               the letters, the unsung words dim; a rim of the accent on the beat;
//               a new line slams in.
//   typewriter  a terminal: the lines typed, one glyph at a time, in Courier, the
//               cursor blinking on the eighths, the earlier lines paling up the
//               panel; a snare makes a glyph slip for a frame.
//   kinetic     each word its own body, popping in on its turn across the frame at a
//               size its length earns and a slant of its own, the line building up
//               word by word; the last line's words shrink and drift away.
//   ribbon      one enormous row of letters the height of the stage sliding past, the
//               sung word kept in the middle, the unsung letters an outline that fills
//               as the voice reaches them, mirrored in a dark band like a ticker's.
//
// The picture comes out through words_fx.frag, which adds what a canvas cannot — a
// chromatic split on the kick in a drop, a glitch of slid rows on the snare, a soft
// dark halo round the letters so they read over any MilkDrop preset, the stencil's
// window onto the ground — and decides which pixels are the figure (drawn at alpha
// 254/255: shown as they are) and which are the paper (alpha 1: blended with the
// ground the rig's way, so MilkDrop shows in contrast where no letter is).
//
// Where a record has no words yet (no line has come, or none for a while) the title
// is set instead, as a poster, revealed over the phrase.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/camera_feed.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_meme_type.dart';
import 'show_sims.dart';

/// How the words are set. The names travel as the figure's style (ShowRig.figure.style).
enum WordsStyle { poster, stencil, typewriter, kinetic, ribbon }

/// A word of each, for the panel.
const wordsStyleWords = {
  WordsStyle.poster: 'the line as a gig poster\'s block, the words lit as they are sung',
  WordsStyle.stencil: 'letters cut out of black: the background shows through them',
  WordsStyle.typewriter: 'a terminal typing the lines, one glyph at a time',
  WordsStyle.kinetic: 'each word pops in on its turn, at a size its length earns',
  WordsStyle.ribbon: 'one huge row of letters sliding past, the sung word in the middle',
};

// ------------------------------------------------------------------ the score

/// One line as it was sung on the stage: when it came, how far it is revealed.
class LyricLineOn {
  LyricLineOn(this.text, this.index, {required this.atSeconds, required this.atBeats, this.hook = false})
      : words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  final String text;
  final int index;
  final List<String> words;
  final double atSeconds, atBeats;

  /// The hook: the line the song sings most, with its title in it first.
  bool hook;

  /// Seconds since it came.
  double age = 0;

  /// How much of it has been sung, 0..1 of its characters.
  double reveal = 0;

  /// The seconds the line is sung over, as guessed: from the words to start with,
  /// then from the lyric clock where it says the line is shorter.
  late double span = (0.55 + 0.34 * words.length).clamp(1.2, 7.0);
  double? _lrcSpan;

  /// The word being sung (-1 before the first), how far through it, and a pop on
  /// each new one that falls over a fifth of a second.
  int wordOn = -1;
  double wordK = 0;
  double pop = 0;

  /// When each word began, in seconds of [age] (for a word's own fade from the
  /// accent to the ink); -1 for one not yet sung.
  late final List<double> wordAt = List.filled(words.length, -1.0);

  int get chars => text.length;

  /// The character the reveal has reached, 0..[chars].
  double get revealChars => reveal * chars;

  void _step(double dt, double k, double? kWas) {
    age += dt;
    // The lyric clock's own span: seconds for the whole line, from how fast k moves.
    if (kWas != null && k > kWas + 1e-4 && dt > 0) {
      final m = (dt / (k - kWas)).clamp(0.8, 30.0);
      _lrcSpan = _lrcSpan == null ? m : _lrcSpan! * 0.7 + m * 0.3;
    }
    final lrc = _lrcSpan;
    // Sung over the shorter of the two guesses: a line that the clock says is over
    // in two seconds is, whatever its word count; one followed by a long gap is not
    // sung over the gap.
    final sing = lrc != null && lrc < span ? lrc * 0.92 : span;
    // The clock's head start, where the line came in late.
    final sinceByClock = lrc != null ? k * lrc : 0.0;
    reveal = (math.max(age, sinceByClock) / sing).clamp(0.0, 1.0);
    // Which word, how far through it.
    final at = revealChars;
    var pos = 0;
    var on = -1;
    for (var i = 0; i < words.length; i++) {
      final end = pos + words[i].length;
      if (at < end + (i == words.length - 1 ? 1 : 1)) {
        on = i;
        wordK = ((at - pos) / math.max(1, words[i].length)).clamp(0.0, 1.0);
        break;
      }
      pos = end + 1;
    }
    if (on < 0) {
      on = words.length - 1;
      wordK = 1;
    }
    if (on != wordOn) {
      wordOn = on;
      pop = 1;
      if (on >= 0 && wordAt[on] < 0) wordAt[on] = age;
    } else {
      pop *= math.exp(-dt / 0.18);
    }
  }
}

/// The lines as they come, most recent last; the current is the last one.
class LyricScore {
  final lines = <LyricLineOn>[];
  int _n = 0;
  String? _textWas;
  double? _kWas;

  /// Kept lines (the current and the ones before it, for the styles that show them).
  static const keep = 8;

  LyricLineOn? get current => lines.isEmpty ? null : lines.last;

  /// The line before the current, where there is one.
  LyricLineOn? get previous => lines.length < 2 ? null : lines[lines.length - 2];

  /// One frame: [lyric] the line the deck says is being sung (null for none),
  /// [k] how far through it the lyric clock is, [hook] whether the hook is on.
  void feed({String? lyric, required double k, required bool hook, required double dt, required double seconds, required double beats}) {
    final cur = current;
    // A new line: other words, or the same words started again (a chorus's lines are
    // the same text at another time, and the clock jumps back to nought).
    final restart = lyric != null && lyric == _textWas && _kWas != null && k < _kWas! - 0.05;
    if (lyric != null && (lyric != _textWas || restart)) {
      lines.add(LyricLineOn(lyric, _n++, atSeconds: seconds, atBeats: beats, hook: hook));
      while (lines.length > keep) {
        lines.removeAt(0);
      }
      _textWas = lyric;
      _kWas = k;
      lines.last._step(0, k, null);
      for (var i = 0; i < lines.length - 1; i++) {
        lines[i].age += dt;
      }
      return;
    }
    if (lyric == null) _textWas = null;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l == cur && lyric != null) {
        l._step(dt, k, _kWas);
        if (hook) l.hook = true;
      } else {
        l.age += dt;
      }
    }
    _kWas = lyric == null ? null : k;
  }

  /// Whether the current line is long gone: nothing sung for a while.
  bool get stale {
    final c = current;
    return c == null || c.age > math.max(c.span * 2.5, 10.0);
  }

  void clear() {
    lines.clear();
    _textWas = null;
    _kWas = null;
  }
}

// ------------------------------------------------------------------ the clock

/// Which style, when: a section at a time, from the ones that suit the moment,
/// deterministic from the record and the slot (as the dancers' and the birds' clocks).
class WordsClock {
  const WordsClock._();

  static const calm = [WordsStyle.typewriter, WordsStyle.poster, WordsStyle.kinetic];
  static const mid = [WordsStyle.poster, WordsStyle.kinetic, WordsStyle.ribbon, WordsStyle.stencil];
  static const hot = [WordsStyle.stencil, WordsStyle.ribbon, WordsStyle.kinetic];

  /// The styles that suit [section] at [energy].
  static List<WordsStyle> suiting(String? section, double energy, {bool breakdown = false}) {
    if (breakdown || section == 'intro' || section == 'outro' || energy < 0.3) return calm;
    if (section == 'drop' || energy > 0.78) return hot;
    return mid;
  }

  static WordsStyle style(String? section, double energy, int salt, int slot, {bool breakdown = false, WordsStyle? not, Iterable<WordsStyle> off = const []}) {
    var pool = [for (final s in suiting(section, energy, breakdown: breakdown)) if (!off.contains(s)) s];
    if (pool.isEmpty) pool = [for (final s in WordsStyle.values) if (!off.contains(s)) s];
    if (pool.isEmpty) pool = WordsStyle.values;
    if (pool.length > 1 && not != null) pool = [for (final s in pool) if (s != not) s];
    return pool[(hash(salt, slot) * pool.length).floor().clamp(0, pool.length - 1)];
  }

  /// 0..1 from two integers, the same every time.
  static double hash(int a, int b) {
    var h = (a * 73856093) ^ (b * 19349663) ^ 0x5bd1e995;
    h = (h ^ (h >> 13)) * 0x5bd1e995 & 0x7fffffff;
    h = (h ^ (h >> 15)) & 0x7fffffff;
    return h / 0x7fffffff;
  }
}

// ------------------------------------------------------------------ the type

TextStyle _archivo(double size, {double wght = 900, double wdth = 62, Color? color, double height = 0.9, double spacing = -0.012, Paint? foreground}) =>
    TextStyle(
      fontFamily: 'Archivo',
      fontSize: size,
      fontWeight: FontWeight.w900,
      fontVariations: [FontVariation('wght', wght), FontVariation('wdth', wdth)],
      height: height,
      letterSpacing: size * spacing,
      color: foreground == null ? color : null,
      foreground: foreground,
    );

TextStyle _courier(double size, {Color? color, bool bold = true}) => TextStyle(
      fontFamily: 'CourierPrime',
      fontSize: size,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      height: 1.25,
      color: color,
    );

/// The width axis, in steps of two: every step is a glyph set the renderer caches,
/// and the bass would otherwise ask for a new one every frame.
double _wdth(double w) => (w / 2).round() * 2.0;

// ------------------------------------------------------------------ the sim

/// The hands' choice of a style, when the frame carries one.
WordsStyle? _styleNamed(String? name) => name == null ? null : WordsStyle.values.where((s) => s.name == name).firstOrNull;

class WordsSim implements SimLayer {
  WordsSim() {
    try {
      final s = Platform.environment['WETOWL_WORDS_STYLE'];
      if (s != null) _forced = _styleNamed(s);
    } catch (_) {}
    _forced ??= forceStyle;
  }

  /// Forced by a test, for every sim made after.
  @visibleForTesting
  static WordsStyle? forceStyle;

  @override
  String get kind => 'words';

  final score = LyricScore();
  final type = MemeType();
  WordsStyle? _forced;
  WordsStyle _style = WordsStyle.poster;
  WordsStyle? _styleWas;
  String? _sectionWas;
  int _slot = -1, _styleN = 0;
  double _t = 0;
  double? _dropAt, _awayWas;
  double _kickWas = 0, _snareWas = 0;
  double _split = 0, _glitch = 0;
  int _trackWas = -1;
  ui.Image? _out;
  ui.FragmentShader? _fx;
  ui.Image? _black;
  final _rng = math.Random(11);

  // The ribbon's slide, and the typewriter's scroll, eased.
  double _ribbonX = 0;
  bool _ribbonFresh = true;
  double _scroll = 0;

  final _watch = Stopwatch();
  int _frames = 0;

  /// The style on (for the panel's status, and a test).
  WordsStyle get style => _style;

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    _t += dt;
    final m = st.master;
    final f = st.flat;
    final playing = m.playing && m.beatIndex != null;
    final bpm = (m.bpm ?? 0) > 1 ? m.bpm! : 120.0;
    final beats = !playing
        ? _t * bpm / 60
        : (m.barIndex != null && m.beatInBar != null ? m.barIndex! * 4 + m.beatInBar! + m.beatPhase : m.beatIndex! + m.beatPhase);
    final salt = m.trackId ?? 0;
    if (salt != _trackWas) {
      // Another record: its own lines.
      if (_trackWas >= 0) score.clear();
      _trackWas = salt;
    }

    // The drop, remembered past the deck's two beats.
    final away = m.dropBeatsAway;
    if (playing) {
      final was = _awayWas;
      if (away != null && away <= 0 && away > -2.5 && (was == null || was > 0)) _dropAt = beats + away;
      if (m.section == 'drop' && _sectionWas != 'drop' && (_dropAt == null || beats - _dropAt! > 8)) _dropAt = beats;
      final d = _dropAt;
      if (d != null && (beats - d < -1 || beats - d > 64)) _dropAt = null;
    }
    _awayWas = away;
    final since = _dropAt == null ? null : beats - _dropAt!;
    final sectionTurned = _sectionWas != null && m.section != _sectionWas;
    _sectionWas = m.section;

    // The score.
    score.feed(lyric: m.lyric, k: m.lyricK, hook: m.hook, dt: dt, seconds: _t, beats: beats);
    final line = score.stale ? null : score.current;

    // The style: a section at a time, or every eight bars; the hook line in the
    // stencil where the room is up for it; the hands' over all.
    final energy = f['dyn.energy'] ?? m.energy;
    final slot = (beats / 32).floor();
    if (_styleN == 0 || sectionTurned || slot != _slot) {
      _slot = slot;
      final next = WordsClock.style(m.section, energy, salt, _styleN, breakdown: m.breakdown, not: _styleN == 0 ? null : _style);
      _style = next;
      _styleN++;
    }
    var style = _forced ?? _styleNamed(st.rig.figure.kind == Figure.words ? st.rig.figure.style : null) ?? _style;
    if (_forced == null && st.rig.figure.style == null && line != null && line.hook && energy > 0.4 && style != WordsStyle.typewriter) {
      style = WordsStyle.stencil;
    }
    if (style != _styleWas) {
      if (style == WordsStyle.ribbon) _ribbonFresh = true;
      _styleWas = style;
    }

    // The moments.
    final kick = f['dyn.hit.kick'] ?? 0, snare = f['dyn.hit.snare'] ?? 0, top = f['dyn.hit.top'] ?? 0;
    final kickEdge = kick > 0.4 && kick > _kickWas + 0.2;
    final snareEdge = snare > 0.45 && snare > _snareWas + 0.25;
    _kickWas = kick;
    _snareWas = snare;
    final hot = since != null && since >= 0 && since < 32;
    // A drop's kicks split the colours; a snare slides a few rows — both for the instant.
    if (kickEdge && hot) _split = math.max(_split, 0.6 + 0.4 * kick);
    if (snareEdge && (hot || energy > 0.6)) _glitch = math.max(_glitch, 0.5 + 0.5 * snare);
    _split *= math.exp(-dt / 0.09);
    _glitch *= math.exp(-dt / 0.07);
    if (m.breakdown) {
      _split = 0;
      _glitch = 0;
    }

    final cue = _WordsCue(
      st: st,
      f: f,
      beats: beats,
      kick: kick,
      snare: snare,
      top: top,
      low: f['dyn.band.low'] ?? 0,
      beat: f['dyn.beat.decay'] ?? 0,
      barSaw: f['dyn.bar.saw'] ?? 0,
      downbeat: f['dyn.downbeat'] ?? 0,
      phraseSaw: f['dyn.phrase.saw'] ?? m.phrasePhase,
      energy: energy,
      hot: hot,
      voice: math.max(f['audio.vocals'] ?? 0, m.vocal),
    );

    _watch.start();
    final size = Size(w.toDouble(), h.toDouble());
    final glyphs = _pass(w, h, (c) => _drawGlyphs(c, size, style, line, cue, dt));
    final plates = _pass(w, h, (c) => _drawPlates(c, size, style, line, cue));
    final out = _post(glyphs, plates, w, h, p, style, line, cue);
    glyphs.dispose();
    plates.dispose();
    _out?.dispose();
    _out = out;
    _watch.stop();
    if (++_frames % 300 == 0) {
      // ignore: avoid_print
      print('WORDS ${(_watch.elapsedMicroseconds / 300 / 1000).toStringAsFixed(1)} ms a frame, ${style.name}, ${score.lines.length} lines');
      _watch.reset();
    }
    return out;
  }

  ui.Image _pass(int w, int h, void Function(Canvas c) draw) {
    final r = ui.PictureRecorder();
    draw(Canvas(r));
    final pic = r.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  ui.Image get black => _black ??= _pass(2, 2, (c) => c.drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = Colors.black));

  // ---------------------------------------------------------------- colours

  Color _ink(ShowState st) => const Color(0xfff3efe6);
  Color _dim(ShowState st) => HSLColor.fromAHSL(1, st.palette.secondary.hue, 0.18, 0.36).toColor();
  Color _accent(ShowState st) => st.palette.accent.withSaturation(0.92).withLightness(0.64).toColor();
  Color _second(ShowState st) => st.palette.secondary.withSaturation(0.7).withLightness(0.66).toColor();
  Color _paper(ShowState st) => HSLColor.fromAHSL(1, st.palette.primary.hue, 0.35, 0.025).toColor();

  // ---------------------------------------------------------------- the glyphs

  /// The letters, in colour, on nothing: the alpha is their coverage.
  void _drawGlyphs(Canvas c, Size s, WordsStyle style, LyricLineOn? line, _WordsCue l, double dt) {
    if (line == null) {
      _title(c, s, l);
      return;
    }
    switch (style) {
      case WordsStyle.poster:
        _poster(c, s, line, l);
      case WordsStyle.stencil:
        _stencil(c, s, line, l);
      case WordsStyle.typewriter:
        _typewriter(c, s, line, l, dt);
      case WordsStyle.kinetic:
        _kinetic(c, s, line, l);
      case WordsStyle.ribbon:
        _ribbon(c, s, line, l, dt);
    }
  }

  /// The plates: black where the ground must not show — a panel, a band.
  void _drawPlates(Canvas c, Size s, WordsStyle style, LyricLineOn? line, _WordsCue l) {
    if (line == null) return;
    final black = Paint()..color = const Color(0xff000000);
    switch (style) {
      case WordsStyle.typewriter:
        c.drawRect(_panel(s), black);
      case WordsStyle.ribbon:
        final (top, bottom) = _band(s, l);
        c.drawRect(Rect.fromLTRB(0, top, s.width, bottom), black);
      default:
        break;
    }
  }

  /// The sung part of a laid-out line, as rectangles: the glyphs up to the reveal,
  /// the glyph being sung cut at how far through it the voice is.
  List<Rect> _sungBoxes(TextPainter tp, LyricLineOn line, String display) {
    final at = (line.reveal * display.length).clamp(0.0, display.length.toDouble());
    final whole = at.floor();
    final frac = at - whole;
    final out = <Rect>[];
    if (whole > 0) {
      for (final b in tp.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: whole))) {
        out.add(b.toRect());
      }
    }
    if (whole < display.length && frac > 0) {
      for (final b in tp.getBoxesForSelection(TextSelection(baseOffset: whole, extentOffset: whole + 1))) {
        final r = b.toRect();
        out.add(Rect.fromLTRB(r.left, r.top, r.left + r.width * frac, r.bottom));
      }
    }
    return out;
  }

  /// The glyphs of word [i] of [display], as rectangles.
  List<Rect> _wordBoxes(TextPainter tp, LyricLineOn line, String display, int i) {
    if (i < 0 || i >= line.words.length) return const [];
    var pos = 0;
    for (var k = 0; k < i; k++) {
      pos += line.words[k].length + 1;
    }
    final end = math.min(display.length, pos + line.words[i].length);
    if (end <= pos) return const [];
    return [for (final b in tp.getBoxesForSelection(TextSelection(baseOffset: pos, extentOffset: end))) b.toRect()];
  }

  /// [tp] painted at [at] in [colour], only within [boxes] (grown by [grow]).
  void _paintWithin(Canvas c, TextPainter tp, Offset at, List<Rect> boxes, TextStyle style, String text, {double grow = 1}) {
    if (boxes.isEmpty) return;
    final path = Path();
    for (final b in boxes) {
      path.addRect(b.shift(at).inflate(grow));
    }
    c.save();
    c.clipPath(path);
    final key = 'w|$text|${style.fontSize!.round()}|${style.fontVariations?.map((v) => v.value.round()).join(',')}|${style.color?.toARGB32()}|${tp.width.round()}';
    type.text(key, () => TextSpan(text: text, style: style), align: tp.textAlign, maxWidth: tp.width + 0.5).paint(c, at);
    c.restore();
  }

  // ------------------------------------------------------------------ poster

  /// The block's size: as big as fits three rows of the width, found once a line.
  double _posterSize(LyricLineOn line, String display, double maxW, double h, double wdth) {
    var size = h * 0.2;
    for (var i = 0; i < 12; i++) {
      final tp = type.text('fit|$display|${size.round()}|$wdth', () => TextSpan(text: display, style: _archivo(size, wdth: wdth)), align: TextAlign.left, maxWidth: maxW);
      if (tp.computeLineMetrics().length <= 3 || size < h * 0.07) return size;
      size *= 0.88;
    }
    return size;
  }

  void _poster(Canvas c, Size s, LyricLineOn line, _WordsCue l) {
    final st = l.st;
    final ink = _ink(st), dim = _dim(st), accent = _accent(st);
    final display = line.text.toUpperCase();
    final margin = s.width * 0.08;
    final maxW = s.width * 0.84;
    // The letters widen with the bass, by a step of the width axis at a time.
    final wdth = _wdth(62 + 16 * l.low + 6 * l.kick);
    final size = _posterSize(line, display, maxW, s.height, 62);
    final style = _archivo(size, wdth: wdth, color: dim);
    final tp = type.text('p|$display|${size.round()}|$wdth|${dim.toARGB32()}', () => TextSpan(text: display, style: style), align: TextAlign.left, maxWidth: maxW);
    // Low on the page; the kick drops it a step.
    final drop = s.height * 0.006 * l.kick;
    final at = Offset(margin, s.height * 0.86 - tp.height + drop);
    // The line before, hanging over the block and fading over two bars.
    final prev = score.previous;
    if (prev != null && prev != line) {
      final k = ((prev.age - line.age) / (240 / math.max(60, st.master.bpm ?? 120) * 2)).clamp(0.0, 1.0);
      final gone = (line.age / (240 / math.max(60, st.master.bpm ?? 120) * 2)).clamp(0.0, 1.0);
      if (gone < 1) {
        final pd = prev.text.toUpperCase();
        final ps = size * 0.42;
        final col = Color.lerp(dim, _paper(st), 0.3 + 0.7 * gone)!;
        final ptp = type.text('pp|$pd|${ps.round()}|${col.toARGB32()}', () => TextSpan(text: pd, style: _archivo(ps, wdth: 70, color: col)), align: TextAlign.left, maxWidth: maxW);
        ptp.paint(c, Offset(margin, at.dy - ptp.height - s.height * (0.04 + 0.05 * gone) + k * 0));
      }
    }
    // A kicker above everything: who and what.
    final kicker = [st.master.artist, st.master.title].whereType<String>().join('  ·  ').toUpperCase();
    if (kicker.isNotEmpty) {
      final ks = s.height * 0.016;
      type.text('k|$kicker|${ks.round()}', () => TextSpan(text: kicker, style: _archivo(ks, wght: 800, wdth: 118, color: dim, height: 1.1, spacing: 0.12)), align: TextAlign.left, maxWidth: maxW)
          .paint(c, Offset(margin, s.height * 0.08));
    }
    // The rule: fills with the line, flares on the downbeat.
    final rule = Rect.fromLTWH(margin, at.dy - s.height * 0.028, maxW * line.reveal, s.height * (0.0035 + 0.004 * l.downbeat));
    c.drawRect(rule, Paint()..color = accent);
    // The block, dim; the sung part in ink; the word being sung in the accent, settling
    // to ink over half a second.
    tp.paint(c, at);
    _paintWithin(c, tp, at, _sungBoxes(tp, line, display), style.copyWith(color: ink), display);
    final on = line.wordOn;
    if (on >= 0 && on < line.wordAt.length && line.wordAt[on] >= 0) {
      final k = ((line.age - line.wordAt[on]) / 0.5).clamp(0.0, 1.0);
      final col = Color.lerp(accent, ink, k)!;
      final boxes = _wordBoxes(tp, line, display, on);
      // Only as far as the voice has reached into it.
      final sung = _sungBoxes(tp, line, display);
      final cut = <Rect>[];
      for (final b in boxes) {
        for (final sb in sung) {
          final r = b.intersect(sb);
          if (r.width > 0 && r.height > 0) cut.add(r);
        }
      }
      _paintWithin(c, tp, at, cut, style.copyWith(color: col), display);
    }
  }

  // ------------------------------------------------------------------ stencil

  /// The words packed into [rows] rows of about the same length.
  static List<List<String>> packRows(List<String> words, int rows) {
    if (words.isEmpty) return const [];
    rows = rows.clamp(1, words.length);
    final total = words.fold<int>(0, (a, w) => a + w.length + 1);
    final target = total / rows;
    final out = <List<String>>[];
    var row = <String>[];
    var len = 0;
    for (final w in words) {
      if (row.isNotEmpty && len + w.length + 1 > target * 1.08 && out.length < rows - 1) {
        out.add(row);
        row = [];
        len = 0;
      }
      row.add(w);
      len += w.length + 1;
    }
    if (row.isNotEmpty) out.add(row);
    return out;
  }

  void _stencil(Canvas c, Size s, LyricLineOn line, _WordsCue l) {
    final display = line.text.toUpperCase();
    final rows = packRows(display.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(), (line.chars / 13).round().clamp(1, 4));
    if (rows.isEmpty) return;
    const wdth = 70.0;
    // Each row sized to the width, the rows together capped to the height.
    final maxW = s.width * 0.92, maxH = s.height * 0.88;
    final sizes = <double>[];
    var sumH = 0.0;
    for (final r in rows) {
      final text = r.join(' ');
      final probe = type.text('sp|$text', () => TextSpan(text: text, style: _archivo(100, wdth: wdth, height: 0.84)), align: TextAlign.center);
      var size = 100 * maxW / math.max(1, probe.width);
      size = math.min(size, maxH / rows.length / 0.84);
      sizes.add(size);
      sumH += size * 0.84;
    }
    final fit = math.min(1.0, maxH / sumH);
    // A new line slams in, from a little too big.
    final slam = 1 + 0.22 * math.pow(1 - (line.age / 0.18).clamp(0.0, 1.0), 2);
    final swell = 1 + 0.025 * l.kick;
    var y = (s.height - sumH * fit) / 2;
    var wordAt = 0;
    final ink = const Color(0xffffffff);
    final unsung = const Color(0xff595959);
    for (var ri = 0; ri < rows.length; ri++) {
      final size = sizes[ri] * fit;
      final text = rows[ri].join(' ');
      final style = _archivo(size, wdth: wdth, color: unsung, height: 0.84);
      final tp = type.text('s|$text|${size.round()}', () => TextSpan(text: text, style: style), align: TextAlign.center);
      final rowH = size * 0.84;
      final cx = s.width / 2, cy = y + rowH / 2;
      c.save();
      c.translate(cx, cy);
      c.scale(slam * swell);
      final at = Offset(-tp.width / 2, -rowH / 2);
      tp.paint(c, at);
      // The sung words lit: the whole word as the voice reaches it (a stencil is cut,
      // not wiped), the one being sung white.
      var pos = 0;
      for (var wi = 0; wi < rows[ri].length; wi++) {
        final w = rows[ri][wi];
        final i = wordAt + wi;
        final sung = i < line.wordOn || (i == line.wordOn && line.wordK > 0.15);
        if (sung) {
          final boxes = [for (final b in tp.getBoxesForSelection(TextSelection(baseOffset: pos, extentOffset: pos + w.length))) b.toRect()];
          final col = i == line.wordOn ? ink : const Color(0xffc9c9c9);
          _paintWithin(c, tp, at, boxes, style.copyWith(color: col), text, grow: 0);
        }
        pos += w.length + 1;
      }
      c.restore();
      wordAt += rows[ri].length;
      y += rowH;
    }
  }

  // --------------------------------------------------------------- typewriter

  Rect _panel(Size s) => Rect.fromLTRB(s.width * 0.07, s.height * 0.12, s.width * 0.93, s.height * 0.88);

  void _typewriter(Canvas c, Size s, LyricLineOn line, _WordsCue l, double dt) {
    final st = l.st;
    final panel = _panel(s);
    final size = s.height * 0.054;
    final rowH = size * 1.25;
    final ink = _second(st);
    final accent = _accent(st);
    final pale = Color.lerp(ink, _paper(st), 0.55)!;
    final margin = s.width * 0.035;
    final maxW = panel.width - 2 * margin;
    // The frame and a header.
    c.drawRect(panel, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, s.height * 0.0015)
      ..color = pale);
    final head = '> ${[st.master.artist, st.master.title].whereType<String>().join(' — ')}'.toUpperCase();
    final hs = size * 0.6;
    type.text('th|$head|${hs.round()}', () => TextSpan(text: head, style: _courier(hs, color: pale, bold: false)), align: TextAlign.left, maxWidth: maxW)
        .paint(c, Offset(panel.left + margin, panel.top + margin * 0.6));
    // The lines, the current at the foot, the earlier ones paling upward; a new line
    // scrolls them up over a quarter beat.
    final lines = score.lines;
    final rowsFit = ((panel.height - margin * 2 - hs * 2.2) / rowH).floor().clamp(1, 12);
    final wrapOf = <int, int>{};
    final painters = <int, TextPainter>{};
    for (var i = 0; i < lines.length; i++) {
      final text = i == lines.length - 1 ? line.text.substring(0, line.revealChars.floor().clamp(0, line.chars)) : lines[i].text;
      final tp = type.text('t|${lines[i].index}|$text|${size.round()}', () => TextSpan(text: text, style: _courier(size, color: ink)), align: TextAlign.left, maxWidth: maxW);
      painters[i] = tp;
      wrapOf[i] = math.max(1, tp.computeLineMetrics().length);
    }
    final scrollTarget = lines.length.toDouble();
    if (_scroll == 0) _scroll = scrollTarget;
    _scroll += (scrollTarget - _scroll) * (1 - math.exp(-dt / 0.09));
    final slide = (scrollTarget - _scroll) * rowH;
    c.save();
    c.clipRect(panel.deflate(2));
    var y = panel.bottom - margin - rowH + slide;
    for (var i = lines.length - 1; i >= 0 && lines.length - 1 - i < rowsFit; i--) {
      final tp = painters[i]!;
      final rows = wrapOf[i]!;
      y -= (rows - 1) * rowH;
      final age = lines.length - 1 - i;
      final col = age == 0 ? ink : Color.lerp(ink, pale, (age / 5).clamp(0.0, 1.0))!;
      final text = tp.text!.toPlainText();
      // A snare slips one glyph for the frame.
      var shown = text;
      if (age == 0 && l.snare > 0.5 && text.isNotEmpty && _rng.nextDouble() < 0.5) {
        final at = _rng.nextInt(text.length);
        const junk = r'#%&@$/\|<>?!*';
        shown = text.replaceRange(at, at + 1, junk[_rng.nextInt(junk.length)]);
      }
      final ptp = shown == text && col == ink
          ? tp
          : type.text('t2|${lines[i].index}|$shown|${size.round()}|${col.toARGB32()}', () => TextSpan(text: shown, style: _courier(size, color: col)), align: TextAlign.left, maxWidth: maxW);
      final at = Offset(panel.left + margin, y);
      ptp.paint(c, at);
      if (age == 0) {
        // The word being typed in the accent, settling; the cursor after the last glyph.
        final on = line.wordOn;
        if (on >= 0 && on < line.wordAt.length && line.wordAt[on] >= 0) {
          final k = ((line.age - line.wordAt[on]) / 0.45).clamp(0.0, 1.0);
          final boxes = _wordBoxes(ptp, line, shown, on);
          _paintWithin(c, ptp, at, boxes, _courier(size, color: Color.lerp(accent, ink, k)), shown, grow: 0);
        }
        final end = shown.isEmpty ? Offset.zero : ptp.getOffsetForCaret(TextPosition(offset: shown.length), Rect.zero);
        final blink = (l.beats * 2) % 1 < 0.5;
        if (blink) c.drawRect(Rect.fromLTWH(at.dx + end.dx + size * 0.08, at.dy + end.dy + size * 0.12, size * 0.56, size * 1.0), Paint()..color = accent);
      }
      y -= rowH;
    }
    c.restore();
  }

  // ------------------------------------------------------------------ kinetic

  void _kinetic(Canvas c, Size s, LyricLineOn line, _WordsCue l) {
    final st = l.st;
    final ink = _ink(st), accent = _accent(st), dim = _dim(st);
    final words = line.words;
    if (words.isEmpty) return;
    final display = [for (final w in words) w.toUpperCase()];
    final n = words.length;
    final cols = n <= 3 ? n : (n <= 8 ? 3 : 4);
    final rows = (n / cols).ceil();
    final longest = words.fold<int>(1, (a, w) => math.max(a, w.length));
    final cellW = s.width * 0.9 / cols, cellH = s.height * 0.8 / rows;
    final wdth = _wdth(62 + 14 * l.low);
    final bpm = math.max(60.0, st.master.bpm ?? 120);
    final barSeconds = 240 / bpm;
    // The last line's words, shrinking and drifting off over a bar.
    final prev = score.previous;
    if (prev != null && prev != line && line.age < barSeconds) {
      final gone = (line.age / barSeconds).clamp(0.0, 1.0);
      _kineticWords(c, s, prev, l, Color.lerp(dim, _paper(st), gone)!, null, 0.8 - 0.3 * gone, gone * s.height * 0.12, wdth, all: true);
    }
    for (var i = 0; i < n; i++) {
      if (i > line.wordOn) break;
      final w = display[i];
      final row = i ~/ cols;
      final ci = i % cols;
      final inRow = math.min(cols, n - row * cols);
      final rowLeft = (s.width - inRow * cellW) / 2;
      // A brick's offset on the odd rows; a jitter and a slant of the word's own.
      final hx = WordsClock.hash(line.index * 31 + i, 1) - 0.5, hy = WordsClock.hash(line.index * 31 + i, 2) - 0.5;
      final rot = (WordsClock.hash(line.index * 31 + i, 3) - 0.5) * 0.14;
      final cx = rowLeft + (ci + 0.5 + (row.isOdd ? 0.1 : -0.06)) * cellW + hx * cellW * 0.16;
      final cy = s.height * 0.1 + (row + 0.5) * cellH + hy * cellH * 0.2;
      final size = _kineticSize(s, words[i], longest, rows, cellW);
      // The pop: in from half again as big, with a little overshoot.
      final since = line.wordAt[i] < 0 ? 1.0 : line.age - line.wordAt[i];
      final k = (since / 0.22).clamp(0.0, 1.0);
      final back = 1 + 0.5 * (1 - k) * (1 - k) - 0.08 * math.sin(k * math.pi);
      final current = i == line.wordOn;
      final settle = (since / 0.6).clamp(0.0, 1.0);
      final colour = current ? Color.lerp(accent, ink, settle)! : ink;
      final style = _archivo(size, wdth: wdth, color: colour, height: 1.0);
      final tp = type.text('kw|$w|${size.round()}|$wdth|${colour.toARGB32()}', () => TextSpan(text: w, style: style), align: TextAlign.center);
      c.save();
      c.translate(cx, cy);
      c.rotate(rot);
      c.scale(back * (1 + 0.03 * l.kick));
      if (current) c.skew(0.18 * l.snare, 0);
      tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
      c.restore();
    }
  }

  /// A word's size in the kinetic layout: what its length earns, no wider than its cell.
  static double _kineticSize(Size s, String word, int longest, int rows, double cellW) {
    final size = s.height * 0.17 * (0.7 + 0.5 * word.length / longest) / math.sqrt(rows * 0.45 + 0.55);
    // Archivo at width 62 runs about half its size a glyph.
    return math.min(size, cellW * 1.05 / (0.52 * math.max(2, word.length)));
  }

  /// A line's words in the kinetic layout, all at once (for the one leaving).
  void _kineticWords(Canvas c, Size s, LyricLineOn line, _WordsCue l, Color colour, Color? accent, double scale, double rise, double wdth, {bool all = false}) {
    final n = line.words.length;
    if (n == 0) return;
    final cols = n <= 3 ? n : (n <= 8 ? 3 : 4);
    final rows = (n / cols).ceil();
    final longest = line.words.fold<int>(1, (a, w) => math.max(a, w.length));
    final cellW = s.width * 0.9 / cols, cellH = s.height * 0.8 / rows;
    for (var i = 0; i < n; i++) {
      final w = line.words[i].toUpperCase();
      final ci = i % cols, row = i ~/ cols;
      final inRow = math.min(cols, n - row * cols);
      final rowLeft = (s.width - inRow * cellW) / 2;
      final hx = WordsClock.hash(line.index * 31 + i, 1) - 0.5, hy = WordsClock.hash(line.index * 31 + i, 2) - 0.5;
      final rot = (WordsClock.hash(line.index * 31 + i, 3) - 0.5) * 0.14;
      final cx = rowLeft + (ci + 0.5 + (row.isOdd ? 0.1 : -0.06)) * cellW + hx * cellW * 0.16;
      final cy = s.height * 0.1 + (row + 0.5) * cellH + hy * cellH * 0.2 - rise;
      final size = _kineticSize(s, line.words[i], longest, rows, cellW);
      final tp = type.text('kw|$w|${size.round()}|$wdth|${colour.toARGB32()}', () => TextSpan(text: w, style: _archivo(size, wdth: wdth, color: colour, height: 1.0)), align: TextAlign.center);
      c.save();
      c.translate(cx, cy);
      c.rotate(rot);
      c.scale(scale);
      tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
      c.restore();
    }
  }

  // ------------------------------------------------------------------ ribbon

  (double, double) _band(Size s, _WordsCue l) {
    final half = s.height * (0.2 + 0.012 * l.kick);
    return (s.height * 0.5 - half, s.height * 0.5 + half);
  }

  void _ribbon(Canvas c, Size s, LyricLineOn line, _WordsCue l, double dt) {
    final st = l.st;
    final ink = _ink(st), accent = _accent(st);
    final display = line.text.toUpperCase();
    final size = s.height * 0.3;
    final wdth = _wdth(62 + 12 * l.low);
    final fill = _archivo(size, wdth: wdth, color: ink, height: 1.0);
    final outline = _archivo(size, wdth: wdth, height: 1.0, foreground: Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, s.height * 0.0035)
      ..strokeJoin = StrokeJoin.round
      ..color = Color.lerp(ink, _paper(st), 0.35)!);
    final tp = type.text('r|$display|${size.round()}|$wdth', () => TextSpan(text: display, style: fill), align: TextAlign.left);
    final otp = type.text('ro|$display|${size.round()}|$wdth', () => TextSpan(text: display, style: outline), align: TextAlign.left);
    // The glyph being sung kept in the middle: the row slides to it, eased.
    final at = (line.revealChars).clamp(0.0, display.length.toDouble());
    final caret = tp.getOffsetForCaret(TextPosition(offset: at.floor().clamp(0, display.length)), Rect.zero).dx;
    final next = tp.getOffsetForCaret(TextPosition(offset: (at.floor() + 1).clamp(0, display.length)), Rect.zero).dx;
    final want = caret + (next - caret) * (at - at.floor());
    final margin = s.width * 0.06;
    final target = tp.width <= s.width - 2 * margin
        ? (s.width - tp.width) / 2
        : (s.width * 0.5 - want).clamp(s.width - margin - tp.width, margin);
    if (_ribbonFresh || line.age < dt * 1.5) {
      _ribbonX = s.width * 0.5 + s.width * 0.3;
      _ribbonFresh = false;
    }
    _ribbonX += (target - _ribbonX) * (1 - math.exp(-dt / 0.16));
    final (top, bottom) = _band(s, l);
    final y = (top + bottom) / 2 - tp.height * 0.46;
    final origin = Offset(_ribbonX, y);
    // The outline of the whole row, then the sung part filled, the word being sung in
    // the accent; a mirror of it under the baseline, fading.
    otp.paint(c, origin);
    final sung = _sungBoxes(tp, line, display);
    _paintWithin(c, tp, origin, sung, fill, display);
    final on = line.wordOn;
    if (on >= 0 && on < line.wordAt.length && line.wordAt[on] >= 0) {
      final k = ((line.age - line.wordAt[on]) / 0.5).clamp(0.0, 1.0);
      final cut = <Rect>[];
      for (final b in _wordBoxes(tp, line, display, on)) {
        for (final sb in sung) {
          final r = b.intersect(sb);
          if (r.width > 0 && r.height > 0) cut.add(r);
        }
      }
      _paintWithin(c, tp, origin, cut, fill.copyWith(color: Color.lerp(accent, ink, k)), display);
    }
    // The reflection: the row flipped under the band's middle, fading down.
    final mirror = Rect.fromLTRB(0, bottom - s.height * 0.1, s.width, bottom);
    c.save();
    c.clipRect(mirror);
    c.saveLayer(mirror, Paint());
    c.translate(0, 2 * (y + tp.height * 0.78));
    c.scale(1, -1);
    otp.paint(c, origin);
    _paintWithin(c, tp, origin, sung, fill, display);
    c.restore();
    c.drawRect(
        mirror,
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, mirror.top), Offset(0, mirror.bottom), [const Color(0x66ffffff), const Color(0x00ffffff)])
          ..blendMode = BlendMode.dstIn);
    c.restore();
  }

  // ------------------------------------------------------------------ the title

  /// No words: the record's title as a poster, revealed over the phrase.
  void _title(Canvas c, Size s, _WordsCue l) {
    final st = l.st;
    final title = st.master.title;
    if (title == null || title.isEmpty) return;
    final ink = _ink(st), dim = _dim(st), accent = _accent(st);
    final display = title.toUpperCase();
    final margin = s.width * 0.08, maxW = s.width * 0.84;
    const wdth = 62.0;
    var size = s.height * 0.17;
    TextPainter tp;
    for (var i = 0;; i++) {
      tp = type.text('ti|$display|${size.round()}', () => TextSpan(text: display, style: _archivo(size, wdth: wdth, color: dim)), align: TextAlign.left, maxWidth: maxW);
      if (tp.computeLineMetrics().length <= 3 || i > 10) break;
      size *= 0.88;
    }
    final at = Offset(margin, s.height * 0.82 - tp.height);
    tp.paint(c, at);
    final reveal = l.phraseSaw;
    final n = (reveal * display.length).clamp(0.0, display.length.toDouble());
    final boxes = n.floor() > 0 ? [for (final b in tp.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: n.floor()))) b.toRect()] : <Rect>[];
    _paintWithin(c, tp, at, boxes, _archivo(size, wdth: wdth, color: ink), display);
    final artist = st.master.artist;
    if (artist != null) {
      final fs = s.height * 0.022;
      type.text('ta|$artist|${fs.round()}', () => TextSpan(text: artist.toUpperCase(), style: _archivo(fs, wght: 800, wdth: 118, color: accent, height: 1.1, spacing: 0.12)), align: TextAlign.left, maxWidth: maxW)
          .paint(c, Offset(margin, at.dy - fs * 2.2));
    }
  }

  // ------------------------------------------------------------------ the finish

  ui.Image _post(ui.Image glyphs, ui.Image plates, int w, int h, StagePrograms p, WordsStyle style, LyricLineOn? line, _WordsCue l) {
    final program = p.sims['words_fx'];
    if (program == null) {
      // Without the finish: the letters over black, every pixel blended with the ground.
      return _pass(w, h, (c) {
        c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.black);
        c.drawImage(plates, Offset.zero, Paint());
        c.drawImage(glyphs, Offset.zero, Paint());
      });
    }
    final fx = _fx ??= program.fragmentShader();
    final st = l.st;
    final rig = st.rig;
    // The ground, for the stencil's windows and the halo's soft rim: MilkDrop's
    // frame, the room's, the cover; the stage's own size otherwise (none).
    ui.Image? ground;
    var fit = 0.0;
    switch (rig.ground.kind) {
      case Ground.milk:
        ground = MilkFeed.shared.frame;
        fit = 16 / 9;
      case Ground.camera:
        ground = CameraFeed.shared.frame;
        fit = CameraFeed.width / CameraFeed.height;
      default:
        break;
    }
    final soft = rig.ground.kind == Ground.milk && rig.blend.ground == GroundMode.contrast && ground != null;
    final ink = _accent(st), ink2 = _second(st), paper = _paper(st);
    final titleOnly = line == null;
    final mode = titleOnly ? 1 : wordsFxMode[style]!;
    final (halo, haloK) = switch (style) {
      WordsStyle.stencil => (0.0, 0.0),
      WordsStyle.typewriter => (h * 0.004, 0.5),
      WordsStyle.ribbon => (h * 0.004, 0.6),
      _ => (h * (0.0045 + 0.0015 * l.kick), 1.0),
    };
    final wipe = line != null && style == WordsStyle.poster && line.age < 0.3 ? (line.age / 0.3) : -1.0;
    final hotWave = l.hot && style == WordsStyle.stencil ? 0.5 + 0.5 * l.low : 0.0;
    fx
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, mode.toDouble())
      ..setFloat(3, _t)
      ..setFloat(4, l.kick)
      ..setFloat(5, l.snare)
      ..setFloat(6, l.top)
      ..setFloat(7, l.low)
      ..setFloat(8, l.beat)
      ..setFloat(9, l.barSaw)
      ..setFloat(10, halo)
      ..setFloat(11, haloK)
      ..setFloat(12, _split * h * 0.012)
      ..setFloat(13, _glitch)
      ..setFloat(14, hotWave)
      ..setFloat(15, wipe)
      ..setFloat(16, ground == null ? 0 : 1)
      ..setFloat(17, soft ? 1 : 0)
      ..setFloat(18, fit)
      ..setFloat(19, ink.r)
      ..setFloat(20, ink.g)
      ..setFloat(21, ink.b)
      ..setFloat(22, ink2.r)
      ..setFloat(23, ink2.g)
      ..setFloat(24, ink2.b)
      ..setFloat(25, paper.r)
      ..setFloat(26, paper.g)
      ..setFloat(27, paper.b)
      ..setFloat(28, 0.22 + 0.1 * l.energy)
      ..setImageSampler(0, glyphs)
      ..setImageSampler(1, plates)
      ..setImageSampler(2, ground ?? black);
    return _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx));
  }

  @override
  void dispose() {
    _out?.dispose();
    _out = null;
    _black?.dispose();
    _black = null;
    _fx?.dispose();
    _fx = null;
    type.dispose();
  }
}

/// words_fx.frag's uMode for each style.
const wordsFxMode = {
  WordsStyle.poster: 1,
  WordsStyle.stencil: 2,
  WordsStyle.typewriter: 3,
  WordsStyle.kinetic: 4,
  WordsStyle.ribbon: 5,
};

/// What a frame's style reads of the record: the moments, the bands, the room.
class _WordsCue {
  const _WordsCue({
    required this.st,
    required this.f,
    required this.beats,
    required this.kick,
    required this.snare,
    required this.top,
    required this.low,
    required this.beat,
    required this.barSaw,
    required this.downbeat,
    required this.phraseSaw,
    required this.energy,
    required this.hot,
    required this.voice,
  });
  final ShowState st;
  final Map<String, double> f;
  final double beats, kick, snare, top, low, beat, barSaw, downbeat, phraseSaw, energy, voice;

  /// In the heat of a drop.
  final bool hot;
}
