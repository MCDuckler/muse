// The words: the record's lyrics set on the stage as type, and nothing else — no
// pictures, no panels, no titles: the line being sung, in one of seven faces, its
// words lit or coming as the voice reaches them, over whatever ground the rig has
// (MilkDrop in contrast, mostly), with a soft shadow so they read on any of it.
//
// A line is set ONCE — laid out and rasterised into a picture the moment it comes
// (TextPainter, on the UI thread, a few milliseconds a line) — and from then on every
// frame is one shader pass over that picture (shaders/show/sim/words_fx.frag): on the
// native stage (stage.cpp, "@words": the picture goes up as a texture, the frame's
// numbers through ws_words) or on the Flutter one (the same shader, the same
// numbers). The picture encodes, pixel by pixel, which word a letter belongs to (red:
// the word's index) and how far along the word it sits (green), so the shader can
// light, fade or type each word from sixteen ages — one number a word — knowing
// nothing of glyphs. The frame costs the shader pass and seventy floats; the UI thread
// does nothing between lines.
//
// The faces — each a style the clock picks a section at a time, or the hands do:
//   poster    Bebas Neue, tall capitals centred; the line whole, the sung words lit
//   serif     Instrument Serif italic; the words come softly as they are sung
//   grotesk   Archivo black, a block set left and low, stretched a touch by the bass
//   wide      Syne, every word a row the width of the stage, spaced
//   mono      Courier Prime, typed glyph by glyph, lower case
//   marker    Permanent Marker, each word thrown on at a tilt as it is sung
//   light     Manrope light, thin spaced capitals, coming slowly
// Every one answers the record: a kick scales the poster a hair, drops the grotesk a
// step; a snare slips rows in the hot sections; a drop's kicks split the colours; a
// word flares as it comes. Where the record has no words there is nothing but the
// ground.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/show_pool.dart' show StylePool;
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_sims.dart';

/// How the words are set. The names travel as the figure's style (ShowRig.figure.style).
enum WordsStyle { poster, serif, grotesk, wide, mono, marker, light }

/// A word of each, for the panel.
const wordsStyleWords = {
  WordsStyle.poster: 'Bebas Neue: tall capitals, centred; the line whole, the sung words lit',
  WordsStyle.serif: 'Instrument Serif italic: the words come softly as they are sung',
  WordsStyle.grotesk: 'Archivo black: a block set left and low, stretched by the bass',
  WordsStyle.wide: 'Syne: every word a row the width of the stage',
  WordsStyle.mono: 'Courier Prime: typed glyph by glyph, lower case',
  WordsStyle.marker: 'Permanent Marker: each word thrown on at a tilt',
  WordsStyle.light: 'Manrope light: thin spaced capitals, coming slowly',
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

  /// When each word began, in seconds of [age]; -1 for one not yet sung.
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
      if (at < end + 1) {
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

  /// Kept lines (the current and the ones before it).
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

/// Which face, when: a section at a time, from the ones that suit the moment,
/// deterministic from the record and the slot (as the dancers' and the birds' clocks).
class WordsClock {
  const WordsClock._();

  static const calm = [WordsStyle.serif, WordsStyle.light, WordsStyle.mono];
  static const mid = [WordsStyle.poster, WordsStyle.grotesk, WordsStyle.marker, WordsStyle.serif];
  static const hot = [WordsStyle.poster, WordsStyle.wide, WordsStyle.grotesk];

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

// ------------------------------------------------------------------ the faces

enum _Align { centre, left }

/// A face: the font and how a line is set in it, and how its words come.
class _Face {
  const _Face({
    required this.family,
    this.weight = FontWeight.w400,
    this.italic = false,
    this.wght,
    this.wdth,
    this.caps = false,
    this.lower = false,
    this.maxRows = 3,
    this.maxW = 0.86,
    this.maxSize = 0.3,
    this.fixedSize,
    this.leading = 1.0,
    this.spacing = 0,
    this.align = _Align.centre,
    this.anchorY = 0.5,
    this.bottom = false,
    this.stack = false,
    this.tilt = 0,
    this.mode = 0,
    this.dimK = 0.3,
    this.fadeIn = 0.1,
    this.flash = 0,
    this.accent = 0,
    this.shadowK = 0.85,
    this.kickScale = 0,
    this.kickDrop = 0,
    this.stretch = 0,
    this.outSec = 0.6,
    this.rise = 0,
    this.glitch = false,
    this.split = false,
  });

  final String family;
  final FontWeight weight;
  final bool italic;

  /// The variable axes, where the font has them.
  final double? wght, wdth;
  final bool caps, lower;
  final int maxRows;

  /// The block's width at most, and a row's size at most, of the stage.
  final double maxW, maxSize;

  /// A size that does not fit itself to the line (the typewriter's).
  final double? fixedSize;

  /// The row advance in ems; the letter spacing in ems.
  final double leading, spacing;
  final _Align align;

  /// Where the block sits: its middle at [anchorY] of the height — or its bottom,
  /// where [bottom].
  final double anchorY;
  final bool bottom;

  /// Every word its own row, each the width of the block.
  final bool stack;

  /// Each word turned a little, either way, up to this (radians).
  final double tilt;

  /// How the words come (words_fx.frag): 0 karaoke, 1 appear, 2 typed.
  final int mode;
  final double dimK, fadeIn, flash, accent, shadowK, kickScale, kickDrop, stretch, outSec, rise;
  final bool glitch, split;

  TextStyle style(double size, {Paint? foreground}) => TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: weight,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontVariations: wght == null && wdth == null
            ? null
            : [if (wght != null) FontVariation('wght', wght!), if (wdth != null) FontVariation('wdth', wdth!)],
        height: 1.0,
        letterSpacing: size * spacing,
        foreground: foreground,
        color: foreground == null ? Colors.white : null,
      );

  String shape(String w) => caps ? w.toUpperCase() : (lower ? w.toLowerCase() : w);
}

const _faces = {
  WordsStyle.poster: _Face(
    family: 'BebasNeue',
    caps: true,
    maxRows: 3,
    maxW: 0.84,
    maxSize: 0.36,
    leading: 0.9,
    spacing: 0.02,
    mode: 0,
    dimK: 0.3,
    fadeIn: 0.07,
    flash: 0.35,
    accent: 1,
    kickScale: 0.025,
    split: true,
    outSec: 0.3,
    rise: 0.02,
  ),
  WordsStyle.serif: _Face(
    family: 'InstrumentSerif',
    italic: true,
    maxRows: 3,
    maxW: 0.82,
    maxSize: 0.27,
    leading: 0.98,
    spacing: -0.005,
    mode: 1,
    fadeIn: 0.45,
    shadowK: 0.75,
    outSec: 0.8,
    rise: 0.04,
  ),
  WordsStyle.grotesk: _Face(
    family: 'Archivo',
    weight: FontWeight.w900,
    wght: 850,
    wdth: 70,
    caps: true,
    maxRows: 4,
    maxW: 0.88,
    maxSize: 0.3,
    leading: 0.86,
    spacing: -0.012,
    align: _Align.left,
    anchorY: 0.92,
    bottom: true,
    mode: 0,
    dimK: 0.26,
    fadeIn: 0.06,
    flash: 0.25,
    accent: 1,
    kickDrop: 0.006,
    stretch: 0.05,
    glitch: true,
    split: true,
    outSec: 0.3,
    rise: 0.015,
  ),
  WordsStyle.wide: _Face(
    family: 'Syne',
    weight: FontWeight.w800,
    wght: 800,
    caps: true,
    maxRows: 4,
    maxW: 0.9,
    maxSize: 0.3,
    leading: 1.02,
    spacing: 0.08,
    stack: true,
    mode: 1,
    fadeIn: 0.09,
    flash: 0.5,
    glitch: true,
    split: true,
    outSec: 0.25,
    rise: 0.02,
  ),
  WordsStyle.mono: _Face(
    family: 'CourierPrime',
    weight: FontWeight.w700,
    lower: true,
    maxRows: 6,
    maxW: 0.82,
    fixedSize: 0.08,
    leading: 1.25,
    align: _Align.left,
    anchorY: 0.5,
    mode: 2,
    shadowK: 0.8,
    glitch: true,
    outSec: 0.35,
  ),
  WordsStyle.marker: _Face(
    family: 'PermanentMarker',
    maxRows: 3,
    maxW: 0.84,
    maxSize: 0.24,
    leading: 1.12,
    mode: 1,
    fadeIn: 0.05,
    flash: 0.6,
    tilt: 0.05,
    outSec: 0.3,
    rise: 0.02,
  ),
  WordsStyle.light: _Face(
    family: 'Manrope',
    weight: FontWeight.w300,
    wght: 300,
    caps: true,
    maxRows: 2,
    maxW: 0.8,
    maxSize: 0.14,
    leading: 1.3,
    spacing: 0.22,
    mode: 1,
    fadeIn: 0.6,
    shadowK: 1.0,
    outSec: 0.8,
    rise: 0.03,
  ),
};

// ------------------------------------------------------------------ the picture

/// A line set in a face at a stage size: its picture (the words encoded, see the
/// shader), where it sits on the stage (0..1), and which of the stage's two texture
/// slots holds it.
class WordsSet {
  WordsSet({required this.line, required this.style, required this.w, required this.h, required this.slot, required this.image, required this.rect, required this.rows});

  final LyricLineOn line;
  final WordsStyle style;
  final int w, h, slot;
  final ui.Image image;
  final Rect rect;
  final int rows;

  /// Up on the native stage (its texture), or on its way.
  bool uploaded = false, uploading = false;
  bool disposed = false;

  String get texName => 'words.t$slot';

  void dispose() {
    disposed = true;
    image.dispose();
  }
}

/// The width of a group of words at size 100, in the measured widths [ref].
double _groupW(List<int> g, List<double> ref, double space) {
  var s = 0.0;
  for (var k = 0; k < g.length; k++) {
    s += ref[g[k]] + (k > 0 ? space : 0);
  }
  return s;
}

/// A word space at size 100, in a face.
double _space100(_Face face) => 100 * (0.26 + math.max(0.0, face.spacing));

/// The line's words packed into rows no wider than [maxW] at [size]; null where a
/// word alone is wider.
List<List<int>>? _pack(List<double> ref, double space100, double size, double maxW) {
  final rows = <List<int>>[];
  var row = <int>[];
  var rowW = 0.0;
  for (var i = 0; i < ref.length; i++) {
    final ww = ref[i] * size / 100;
    if (ww > maxW) return null;
    final add = row.isEmpty ? ww : rowW + space100 * size / 100 + ww;
    if (row.isNotEmpty && add > maxW) {
      rows.add(row);
      row = [i];
      rowW = ww;
    } else {
      row.add(i);
      rowW = add;
    }
  }
  if (row.isNotEmpty) rows.add(row);
  return rows;
}

/// The line set in [style] for a stage of [w]×[h]: laid out, rasterised, placed.
WordsSet layoutWords(LyricLineOn line, WordsStyle style, int w, int h, {int slot = 0}) {
  final face = _faces[style]!;
  final W = w.toDouble(), H = h.toDouble();
  final words = [for (final x in line.words) face.shape(x)];
  final n = words.length;
  // Every word measured at a hundred pixels: widths scale with the size.
  final ref = <double>[];
  for (final x in words) {
    final tp = TextPainter(text: TextSpan(text: x, style: face.style(100)), textDirection: TextDirection.ltr)..layout();
    ref.add(tp.width);
    tp.dispose();
  }
  final space100 = _space100(face);
  final maxW = face.maxW * W;
  final maxH = 0.84 * H;
  var rows = <List<int>>[];
  final sizes = <double>[];
  if (face.stack) {
    // Every word a row the width of the block; too many rows and the shortest
    // neighbours share one.
    var groups = [for (var i = 0; i < n; i++) [i]];
    while (groups.length > face.maxRows) {
      var best = 0;
      var bestW = double.infinity;
      for (var g = 0; g + 1 < groups.length; g++) {
        final sum = _groupW(groups[g], ref, space100) + _groupW(groups[g + 1], ref, space100);
        if (sum < bestW) {
          bestW = sum;
          best = g;
        }
      }
      groups[best] = [...groups[best], ...groups[best + 1]];
      groups.removeAt(best + 1);
    }
    rows = groups;
    for (final g in groups) {
      sizes.add(math.min(face.maxSize * H, maxW / math.max(1.0, _groupW(g, ref, space100)) * 100));
    }
    final total = sizes.fold(0.0, (a, s) => a + s * face.leading);
    if (total > maxH) {
      final k = maxH / total;
      for (var i = 0; i < sizes.length; i++) {
        sizes[i] *= k;
      }
    }
  } else {
    var size = (face.fixedSize ?? face.maxSize) * H;
    final minSize = 0.035 * H;
    final maxRows = face.fixedSize != null ? 6 : face.maxRows;
    List<List<int>>? packed;
    for (var tries = 0; tries < 60; tries++) {
      packed = _pack(ref, space100, size, maxW);
      final fits = packed != null && packed.length <= maxRows && packed.length * size * face.leading <= maxH;
      if (fits || size <= minSize) break;
      size *= 0.94;
    }
    packed ??= [for (var i = 0; i < n; i++) [i]];
    // Even rows read better than a full one over a word on its own: the narrowest
    // block that keeps the row count.
    if (packed.length > 1 && face.fixedSize == null) {
      var best = packed;
      var bestSpread = double.infinity;
      for (final k in [1.0, 0.92, 0.84, 0.76, 0.68]) {
        final p = _pack(ref, space100, size, maxW * k);
        if (p == null || p.length != packed.length) continue;
        final widths = [for (final r in p) _groupW(r, ref, space100)];
        final spread = widths.fold(0.0, math.max) - widths.fold(double.infinity, math.min);
        if (spread < bestSpread) {
          bestSpread = spread;
          best = p;
        }
      }
      packed = best;
    }
    rows = packed;
    for (var i = 0; i < rows.length; i++) {
      sizes.add(size);
    }
  }
  // The block, and its picture with room for the shadow and the tilt.
  final pad = 0.04 * H;
  final rowH = [for (final s in sizes) s * face.leading];
  final blockH = rowH.fold(0.0, (a, b) => a + b);
  final rowW = [for (var r = 0; r < rows.length; r++) _groupW(rows[r], ref, space100) * sizes[r] / 100];
  final blockW = face.stack ? maxW : rowW.fold(0.0, math.max);
  final picW = (blockW + 2 * pad).ceil().clamp(4, 4096);
  final picH = (blockH + 2 * pad + sizes.last * 0.3).ceil().clamp(4, 4096);
  // Where on the stage.
  final left = face.align == _Align.left ? (1 - face.maxW) / 2 * W : (W - blockW) / 2;
  final top = face.bottom ? face.anchorY * H - blockH : face.anchorY * H - blockH / 2;
  final rect = Rect.fromLTWH((left - pad) / W, (top - pad) / H, picW / W, picH / H);
  // The picture: each word in its code — red the word's index, green along the word.
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final rng = math.Random(line.index * 31 + style.index * 7);
  var y = pad;
  for (var r = 0; r < rows.length; r++) {
    final size = sizes[r];
    final sp = space100 * size / 100;
    var x = pad + (face.align == _Align.left && !face.stack ? 0 : (blockW - rowW[r]) / 2);
    for (final i in rows[r]) {
      final ww = ref[i] * size / 100;
      final idx = math.min(i, 15);
      final red = ((idx + 0.5) / 16 * 255).round();
      final paint = Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(math.max(1, ww), 0), [Color.fromARGB(255, red, 0, 255), Color.fromARGB(255, red, 255, 255)]);
      final tp = TextPainter(text: TextSpan(text: words[i], style: face.style(size, foreground: paint)), textDirection: TextDirection.ltr)..layout();
      c.save();
      c.translate(x, y);
      if (face.tilt > 0) {
        c.translate(ww / 2, tp.height / 2);
        c.rotate((rng.nextDouble() * 2 - 1) * face.tilt);
        c.translate(-ww / 2, -tp.height / 2);
      }
      tp.paint(c, Offset.zero);
      c.restore();
      tp.dispose();
      x += ww + sp;
    }
    y += rowH[r];
  }
  final pic = rec.endRecording();
  final img = pic.toImageSync(picW, picH);
  pic.dispose();
  return WordsSet(line: line, style: style, w: w, h: h, slot: slot, image: img, rect: rect, rows: rows.length);
}

// ------------------------------------------------------------------ the frame

/// The shader's floats (words_fx.frag), in the order the file declares them, each
/// with its count: the one list both stages take (Flutter's setFloat(i), the native
/// stage's ws_words).
class WordsParams {
  const WordsParams._();

  static const uniforms = <(String, int)>[
    ('uResolution', 2),
    ('uTime', 1),
    ('uKick', 1),
    ('uSnare', 1),
    ('uLow', 1),
    ('uBeat', 1),
    ('uShadow', 1),
    ('uShadowK', 1),
    ('uSplit', 1),
    ('uGlitch', 1),
    ('uInk', 3),
    ('uAccent', 3),
    ('uAccentK', 1),
    ('uDimK', 1),
    ('uFadeIn', 1),
    ('uFlash', 1),
    ('uCur', 1),
    ('uRectA', 4),
    ('uFadeA', 1),
    ('uScaleA', 2),
    ('uModeA', 1),
    ('uOnA', 1),
    ('uKA', 1),
    ('uAgeA0', 4),
    ('uAgeA1', 4),
    ('uAgeA2', 4),
    ('uAgeA3', 4),
    ('uRectB', 4),
    ('uFadeB', 1),
    ('uScaleB', 2),
    ('uRiseB', 1),
    ('uModeB', 1),
    ('uOnB', 1),
    ('uKB', 1),
    ('uAgeB0', 4),
    ('uAgeB1', 4),
    ('uAgeB2', 4),
    ('uAgeB3', 4),
    ('uPremul', 1),
  ];

  /// Where each begins.
  static final Map<String, int> at = () {
    final m = <String, int>{};
    var i = 0;
    for (final (name, n) in uniforms) {
      m[name] = i;
      i += n;
    }
    return m;
  }();

  static final int length = uniforms.fold(0, (a, u) => a + u.$2);
}

/// The hands' choice of a style, when the frame carries one.
WordsStyle? _styleNamed(String? name) => name == null ? null : WordsStyle.values.where((s) => s.name == name).firstOrNull;

/// A picture for the native stage: its texture by name, RGBA top row first.
typedef WordsUpload = void Function(String name, int w, int h, Uint8List rgba);

class WordsSim implements SimLayer {
  WordsSim({this.upload}) {
    try {
      final s = Platform.environment['WETOWL_WORDS_STYLE'];
      if (s != null) _forced = _styleNamed(s);
    } catch (_) {}
    _forced ??= forceStyle;
  }

  /// Forced by a test, for every sim made after.
  @visibleForTesting
  static WordsStyle? forceStyle;

  /// Where the pictures go on the native stage; null on the Flutter one.
  final WordsUpload? upload;

  @override
  String get kind => 'words';

  final score = LyricScore();
  WordsStyle? _forced;
  WordsStyle _style = WordsStyle.poster;
  String? _sectionWas;
  int _slot = -1, _styleN = 0;
  double _t = 0;
  double? _dropAt, _awayWas;
  double _kickWas = 0, _snareWas = 0;
  double _split = 0, _glitch = 0;
  int _trackWas = -1;

  WordsSet? _a, _b;
  double _fadeA = 0, _fadeB = 0;
  _Face _bFace = _faces[WordsStyle.poster]!;
  final _v = Float32List(WordsParams.length);

  ui.Image? _out;
  ui.FragmentShader? _fx;
  ui.Image? _black;

  final _watch = Stopwatch();
  int _frames = 0;

  /// The style on (for the panel's status, and a test).
  WordsStyle get style => _style;

  /// The line's picture on the stage now, and how far in (a test looks).
  @visibleForTesting
  WordsSet? get lineSet => _a;
  @visibleForTesting
  double get fadeIn => _fadeA;

  void _set(String name, double v) => _v[WordsParams.at[name]!] = v;
  void _setN(String name, List<double> v) {
    final at = WordsParams.at[name]!;
    for (var i = 0; i < v.length; i++) {
      _v[at + i] = v[i];
    }
  }

  void _setAges(String prefix, LyricLineOn? l) {
    for (var q = 0; q < 4; q++) {
      final at = WordsParams.at['$prefix$q']!;
      for (var j = 0; j < 4; j++) {
        final i = q * 4 + j;
        _v[at + j] = l != null && i < l.words.length && l.wordAt[i] >= 0 ? l.age - l.wordAt[i] : -1.0;
      }
    }
  }

  /// One frame's numbers for the shader, the pictures made and (on the native stage)
  /// sent as needed. [w]×[h] is the stage the pictures are set for.
  Float32List tick(ShowState st, double dt, int w, int h) {
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

    // The face: a section at a time, or every eight bars; the hands' over all.
    final energy = f['dyn.energy'] ?? m.energy;
    final slot = (beats / 32).floor();
    if (_styleN == 0 || sectionTurned || slot != _slot) {
      _slot = slot;
      // Not a face switched off (the ON/OFF list: gone everywhere).
      _style = WordsClock.style(m.section, energy, salt ^ st.macros.seed, _styleN,
          breakdown: m.breakdown, not: _styleN == 0 ? null : _style, off: [for (final w in WordsStyle.values) if (!StylePool.allows(Figure.words, w.name)) w]);
      _styleN++;
    }
    final style = _forced ?? _styleNamed(st.rig.figure.kind == Figure.words ? st.rig.figure.style : null) ?? _style;
    final face = _faces[style]!;

    // The pictures: A the line on, B the one before, going. A new line, or the line
    // in another face or for another size, is set afresh.
    if (line != null) {
      final a = _a;
      if (a == null || a.line != line || a.style != style || a.w != w || a.h != h) {
        if (a != null && a.line != line) {
          _b?.dispose();
          _b = a;
          _fadeB = _fadeA;
          _bFace = _faces[a.style]!;
        } else {
          a?.dispose();
        }
        _watch.start();
        _a = layoutWords(line, style, w, h, slot: a == null ? 0 : 1 - a.slot);
        _watch.stop();
        if (upload != null) _send(_a!);
      }
    }
    final a = _a;
    if (a != null) {
      final ready = upload == null || a.uploaded;
      final want = line != null && ready ? 1.0 : 0.0;
      final step = want > _fadeA ? dt / 0.12 : dt / (line == null ? 0.8 : face.outSec);
      _fadeA = want > _fadeA ? math.min(want, _fadeA + step) : math.max(want, _fadeA - step);
      if (_fadeA <= 0 && line == null) {
        a.dispose();
        _a = null;
      }
    }
    final b = _b;
    if (b != null) {
      _fadeB = math.max(0.0, _fadeB - dt / _bFace.outSec);
      if (_fadeB <= 0) {
        b.dispose();
        _b = null;
      }
    }

    // The moments.
    final kick = f['dyn.hit.kick'] ?? 0, snare = f['dyn.hit.snare'] ?? 0, low = f['dyn.band.low'] ?? 0;
    final kickEdge = kick > 0.4 && kick > _kickWas + 0.2;
    final snareEdge = snare > 0.45 && snare > _snareWas + 0.25;
    _kickWas = kick;
    _snareWas = snare;
    final hot = since != null && since >= 0 && since < 32;
    if (kickEdge && hot && face.split) _split = math.max(_split, 0.6 + 0.4 * kick);
    if (snareEdge && (hot || energy > 0.6) && face.glitch) _glitch = math.max(_glitch, 0.5 + 0.5 * snare);
    _split *= math.exp(-dt / 0.09);
    _glitch *= math.exp(-dt / 0.07);
    if (m.breakdown) {
      _split = 0;
      _glitch = 0;
    }

    // The numbers.
    const ink = Color(0xfff4f1ea);
    final accent = st.palette.accent.withSaturation(0.9).withLightness(0.66).toColor();
    _setN('uResolution', [w.toDouble(), h.toDouble()]);
    _set('uTime', _t);
    _set('uKick', kick);
    _set('uSnare', snare);
    _set('uLow', low);
    _set('uBeat', f['dyn.beat.decay'] ?? 0);
    _set('uShadow', h * 0.006);
    // No shadow where the blend is a keyhole (the letters a window onto the ground):
    // the alpha is the coverage there, and a shadow would cut a dim second window.
    final keyhole = st.rig.blend.ground == GroundMode.keyhole && st.rig.blend.strength > 0;
    _set('uShadowK', keyhole ? 0 : face.shadowK);
    _set('uSplit', _split * h * 0.008);
    _set('uGlitch', _glitch);
    _setN('uInk', [ink.r, ink.g, ink.b]);
    _setN('uAccent', [accent.r, accent.g, accent.b]);
    _set('uAccentK', face.accent);
    _set('uDimK', face.dimK);
    _set('uFadeIn', face.fadeIn);
    _set('uFlash', face.flash);
    _set('uCur', (_a?.slot ?? 0).toDouble());
    final aa = _a;
    final ra = aa?.rect ?? Rect.zero;
    final drop = face.kickDrop * kick;
    _setN('uRectA', [ra.left, ra.top + drop, ra.right, ra.bottom + drop]);
    _set('uFadeA', aa == null ? 0 : _fadeA);
    _setN('uScaleA', [1 + face.kickScale * kick + face.stretch * low, 1 + face.kickScale * kick]);
    _set('uModeA', face.mode.toDouble());
    _set('uOnA', (aa?.line.wordOn ?? -1).toDouble());
    _set('uKA', aa?.line.wordK ?? 0);
    _setAges('uAgeA', aa?.line);
    final bb = _b;
    final rb = bb?.rect ?? Rect.zero;
    _setN('uRectB', [rb.left, rb.top, rb.right, rb.bottom]);
    _set('uFadeB', bb == null ? 0 : _fadeB);
    final shrink = 1 - 0.05 * (1 - _fadeB);
    _setN('uScaleB', [shrink, shrink]);
    _set('uRiseB', bb == null ? 0 : _bFace.rise * (1 - _fadeB));
    _set('uModeB', _bFace.mode.toDouble());
    _set('uOnB', (bb?.line.wordOn ?? -1).toDouble());
    _set('uKB', bb?.line.wordK ?? 0);
    _setAges('uAgeB', bb?.line);
    // A Flutter picture holds its colour premultiplied; the native stage's blend mixes
    // straight colour by the coverage (and sets this itself where it draws the layer
    // whole).
    _set('uPremul', upload == null ? 1 : 0);

    if (++_frames % 600 == 0 && _watch.elapsedMilliseconds > 0) {
      // ignore: avoid_print
      print('WORDS ${_watch.elapsedMilliseconds} ms setting type over 600 frames, ${style.name}, ${score.lines.length} lines');
      _watch.reset();
    }
    return _v;
  }

  /// The set's picture up to the native stage, when its bytes are read out.
  void _send(WordsSet s) {
    final up = upload;
    if (up == null || s.uploading) return;
    s.uploading = true;
    s.image.toByteData(format: ui.ImageByteFormat.rawRgba).then((d) {
      if (d == null || s.disposed) return;
      up(s.texName, s.image.width, s.image.height, d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes));
      s.uploaded = true;
    }).catchError((Object e) {
      s.uploading = false;
    });
  }

  /// The frame for the native stage: its numbers (ws_words); the pictures go up by
  /// [upload] as they are set.
  Float32List native(ShowState st, double dt, int w, int h) => tick(st, dt, w, h);

  /// The frame on the Flutter stage: the shader over the pictures.
  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    final v = tick(st, dt, w, h);
    final program = p.sims['words_fx'];
    final out = program == null ? _plain(w, h) : _shade(program, v, w, h);
    _out?.dispose();
    _out = out;
    return out;
  }

  ui.Image _shade(ui.FragmentProgram program, Float32List v, int w, int h) {
    final fx = _fx ??= program.fragmentShader();
    for (var i = 0; i < v.length; i++) {
      fx.setFloat(i, v[i]);
    }
    fx.setImageSampler(0, _slotImage(0) ?? black);
    fx.setImageSampler(1, _slotImage(1) ?? black);
    return _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx));
  }

  ui.Image? _slotImage(int slot) {
    final a = _a, b = _b;
    if (a != null && a.slot == slot) return a.image;
    if (b != null && b.slot == slot) return b.image;
    return null;
  }

  /// Without the shader: the line's picture as it is, in the ink.
  ui.Image _plain(int w, int h) => _pass(w, h, (c) {
        final a = _a;
        if (a == null || _fadeA <= 0) return;
        final r = Rect.fromLTRB(a.rect.left * w, a.rect.top * h, a.rect.right * w, a.rect.bottom * h);
        c.drawImageRect(a.image, Rect.fromLTWH(0, 0, a.image.width.toDouble(), a.image.height.toDouble()), r,
            Paint()..colorFilter = ColorFilter.mode(const Color(0xfff4f1ea).withValues(alpha: _fadeA), BlendMode.srcIn));
      });

  ui.Image _pass(int w, int h, void Function(Canvas c) draw) {
    final r = ui.PictureRecorder();
    draw(Canvas(r));
    final pic = r.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  /// Nothing: a clear picture for an empty slot.
  ui.Image get black => _black ??= _pass(2, 2, (c) {});

  @override
  void dispose() {
    _a?.dispose();
    _b?.dispose();
    _a = null;
    _b = null;
    _out?.dispose();
    _out = null;
    _black?.dispose();
    _black = null;
    _fx?.dispose();
    _fx = null;
  }
}
