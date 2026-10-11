// The meme edit's bits: the gags a phone editor drops into an edit for a few bars.
//
// A bit is scheduled by the edit (show_meme.dart) on a phrase, from a pool weighed
// by the mood, the style and the dice, and runs for a set number of bars. Two kinds:
//
//   takeover   draws the whole picture instead of the cut. Mostly *looks* — real
//              footage, a screensaver, a video wall, polaroids, a parallax, a
//              kaleidoscope, strips, a spotlight, a film strip, rings, a duotone, a
//              history lesson — and a few gags kept rare: a sunburst dance, a crowd,
//              a two-panel, the expanding brain, a top seven; a freeze frame on the
//              way into a breakdown;
//   overlay    drawn over the picture at the screen's own size — a reaction cam, a
//              spectrum, a bouncing logo, a news bar, a speech bubble, a stamp, a
//              cursor, error boxes, a hazard card.
//
// Each reads the frame it is handed ([MemeFrame]) and nothing else, so a bit is a
// pure function of the record's time and its seed.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/show/show_state.dart';
import '../mag.dart';
import 'show_meme_bank.dart';
import 'show_meme_type.dart';

/// What a bit is handed each frame.
class MemeFrame {
  MemeFrame({
    required this.bank,
    required this.type,
    required this.deck,
    required this.beats,
    required this.spb,
    required this.t,
    required this.w,
    required this.h,
    required this.mood,
    required this.look,
    required this.kick,
    required this.snare,
    required this.top,
    required this.low,
    required this.mid,
    required this.high,
    required this.beatDecay,
    required this.downbeat,
    required this.barSaw,
    required this.busy,
    required this.hot,
    required this.hue,
    required this.salt,
    required this.shake,
    required this.face,
    required this.newBeat,
    required this.snareEdge,
    required this.kickEdge,
  });
  final MemeBank bank;
  final MemeType type;
  final ShowDeck deck;
  final double beats, spb, t, w, h;
  final MemeMood mood;
  final MemeLook look;
  final double kick, snare, top, low, mid, high, beatDecay, downbeat, barSaw, busy, hot, hue;
  final int salt;

  /// The shake, as a share of the frame.
  final Offset shake;

  /// Where the face of the cut is on the frame, 0..1.
  final Offset face;
  final bool newBeat, snareEdge, kickEdge;

  int get beatInBar => deck.beatInBar ?? 0;
  int get barIndex => deck.barIndex ?? 0;
}

abstract class MemeBit {
  MemeBit(this.start, this.bars, this.seed);

  /// When it began, in beats; how long it runs, in bars; its dice.
  final double start;
  final int bars;
  final int seed;

  String get kind;

  /// Whether it draws the whole picture (instead of the cut) or over it.
  bool get takeover => false;

  /// Whether the edit's own captions stay off while it is on.
  bool get quiet => false;

  double beatsIn(MemeFrame f) => f.beats - start;
  double k(MemeFrame f) => (beatsIn(f) / (bars * 4)).clamp(0.0, 1.0);
  bool over(MemeFrame f) => beatsIn(f) >= bars * 4 || beatsIn(f) < -8;

  /// Not yet: scheduled for a little later (after a card, say).
  bool early(MemeFrame f) => beatsIn(f) < 0;

  /// The dice, 0..1, the same for the same [n].
  double r(int n) => memeHash(seed, n, 11);
  int pick(int n, int of) => of <= 0 ? 0 : (r(n) * of).floor() % of;

  /// Into the picture, at the working size.
  void draw(Canvas c, MemeFrame f) {}

  /// Over everything, at the screen's size.
  void paintOver(Canvas c, Size size, MemeFrame f) {}

  void dispose() {}

  /// Wanted before it starts, so its first frame is not black.
  void warm(MemeBank bank) {}
}

/// The ease a thing pops on with.
double _pop(double age, double over) => age < over ? Curves.easeOutBack.transform((age / over).clamp(0.0, 1.0)) : 1.0;

// ------------------------------------------------------------------ takeovers

/// Real footage: the clip, locked to the beat — forward in a vibe, back and forth
/// in a rage — zoomed on the animal, punched on the kick, a tag saying what it is.
class ClipBit extends MemeBit {
  ClipBit(super.start, super.bars, super.seed, this.clip);
  final MemeClip clip;
  @override
  String get kind => 'clip';
  @override
  bool get takeover => true;

  /// How it runs: forward at the record's pace, slow, back and forth, or backwards.
  int get _mode => r(7) < 0.45 ? 0 : (r(7) < 0.7 ? 1 : (r(7) < 0.9 ? 2 : 3));

  int _frameAt(MemeFrame f) {
    final b = beatsIn(f);
    final mode = f.mood == MemeMood.rage ? 2 : _mode;
    switch (mode) {
      case 1:
        return (b * 3).floor() % clip.frames;
      case 2:
        final i = (b * (f.mood == MemeMood.rage ? 8 : 6)).floor();
        final p = i % (2 * clip.frames);
        return p < clip.frames ? p : 2 * clip.frames - 1 - p;
      case 3:
        return clip.frames - 1 - (b * 6).floor() % clip.frames;
    }
    return (b * 6).floor() % clip.frames;
  }

  ColorFilter? get _grade => r(5) < 0.2 ? MemeFilters.sepia : (r(5) < 0.35 ? MemeFilters.grey : null);

  @override
  void warm(MemeBank bank) {
    for (var i = 0; i < 16; i++) {
      bank.want(clip.file(i));
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final i = _frameAt(f);
    for (var k = 1; k <= 14; k++) {
      f.bank.want(clip.file(i + k));
    }
    var img = f.bank.image(clip.file(i));
    for (var k = 1; img == null && k < 6; k++) {
      img = f.bank.image(clip.file(i - k));
    }
    if (img == null) return;
    final snap = f.mood == MemeMood.rage ? 1 + 0.25 * f.beatDecay : 1.0;
    final zoom = (1.55 + 0.3 * r(1)) * snap * (1 + 0.1 * f.kick);
    final shot = MemeShot.clip(clip, f.w, f.h, zoom: zoom, focus: clip.at(i), shift: Offset(f.shake.dx * f.w, f.shake.dy * f.h), sx: r(2) < 0.3 ? -1 : 1);
    final grade = _grade;
    shot.draw(c, img, paint: grade == null ? null : (Paint()..colorFilter = grade..filterQuality = FilterQuality.medium));
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final line = f.bank.line('clip', seed, 1) ?? 'echte aufnahmen';
    final s = (size.height * 0.032).roundToDouble();
    final p = f.type.text('ct|$line|$s', () => TextSpan(text: line.toUpperCase(), style: Mag.flag(s, color: Colors.white)));
    final x = size.width * 0.04, y = size.height * (f.mood == MemeMood.rage ? 0.12 : 0.06);
    c.drawRect(Rect.fromLTWH(x - s * 0.4, y - s * 0.25, p.width + s * 0.8, p.height + s * 0.5), Paint()..color = const Color(0xCCD4121A));
    p.paint(c, Offset(x, y));
    // The REC dot, as a camcorder's.
    if ((f.beats * 2).floor().isEven) {
      c.drawCircle(Offset(size.width * 0.93, y + s * 0.6), s * 0.35, Paint()..color = const Color(0xFFFF2A2A));
    }
  }
}

/// A sticker bouncing on a sunburst: the rays turn, the dormouse dances — a lean
/// each beat, a jump on the kick, a squash on the snare.
class SunburstBit extends MemeBit {
  SunburstBit(super.start, super.bars, super.seed, this.sticker);
  final MemeSticker sticker;
  @override
  String get kind => 'sunburst';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) => bank.want(sticker.file);

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final a = HSLColor.fromAHSL(1, (f.hue * 360) % 360, 0.95, 0.55).toColor();
    final b = HSLColor.fromAHSL(1, (f.hue * 360 + 40) % 360, 0.95, 0.72).toColor();
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = b);
    final centre = Offset(w / 2, h * 0.55);
    final far = math.sqrt(w * w + h * h);
    final turn = f.t * 0.35 * (r(3) < 0.5 ? 1 : -1) + f.beatDecay * 0.08;
    final path = Path();
    const n = 18;
    for (var i = 0; i < n; i++) {
      final a0 = turn + i * 2 * math.pi / n, a1 = a0 + math.pi / n;
      path
        ..moveTo(centre.dx, centre.dy)
        ..lineTo(centre.dx + math.cos(a0) * far, centre.dy + math.sin(a0) * far)
        ..lineTo(centre.dx + math.cos(a1) * far, centre.dy + math.sin(a1) * far)
        ..close();
    }
    c.drawPath(path, Paint()..color = a.withValues(alpha: 0.7));
    // A halo behind the dancer, breathing with the bass.
    c.drawCircle(centre, h * (0.32 + 0.06 * f.low), Paint()..color = Colors.white.withValues(alpha: 0.25 + 0.15 * f.kick));
    final img = f.bank.image(sticker.file);
    if (img == null) return;
    final lean = (f.beatInBar.isEven ? 1 : -1) * 0.1 * (0.4 + 0.6 * f.beatDecay);
    final jump = -h * 0.05 * f.kick;
    final sq = 1 + 0.1 * f.snare;
    drawSticker(c, img, sticker, Offset(centre.dx + f.shake.dx * w, centre.dy + jump), h * 0.62 * (1 + 0.12 * f.kick), rot: lean, sx: sq, sy: 1 / sq);
  }
}

/// A crowd: rows of cut-outs bouncing in turn, the way a chant animation does.
class CrowdBit extends MemeBit {
  CrowdBit(super.start, super.bars, super.seed, this.stickers);
  final List<MemeSticker> stickers;
  @override
  String get kind => 'crowd';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final s in stickers) {
      bank.want(s.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF14101E));
    // Stripes racing by.
    final stripe = Paint()..color = HSLColor.fromAHSL(0.35, (f.hue * 360) % 360, 0.9, 0.5).toColor();
    final step = h * 0.12;
    for (var y = -step + (f.t * h * 0.5) % step; y < h; y += step) {
      c.drawRect(Rect.fromLTWH(0, y, w, step * 0.35), stripe);
    }
    if (stickers.isEmpty) return;
    const rows = 3, cols = 4;
    final dh = h * 0.3;
    for (var row = 0; row < rows; row++) {
      final drift = (row.isEven ? 1 : -1) * w * 0.05 * math.sin(f.t * 0.7 + row);
      for (var col = 0; col < cols; col++) {
        final i = row * cols + col;
        final st = stickers[i % stickers.length];
        final img = f.bank.image(st.file);
        if (img == null) continue;
        final mine = (i + f.beatInBar).isEven;
        final hop = mine ? f.beatDecay : 0.0;
        final x = w * (0.14 + col * 0.24) + drift, y = h * (0.28 + row * 0.26) - h * 0.06 * hop;
        drawSticker(c, img, st, Offset(x, y), dh * (1 + 0.15 * hop + 0.1 * f.kick), rot: (mine ? 1 : -1) * 0.12 * hop + math.sin(f.t * 3 + i) * 0.04);
      }
    }
  }
}

/// "Nobody: / Siebenschläfer at 3 am:" — two panels, the sleeper and the maniac,
/// the lower one shaking with every kick.
class NobodyBit extends MemeBit {
  NobodyBit(super.start, super.bars, super.seed, this.top, this.bottom, this.lines);
  final MemePhoto top, bottom;
  final (String, String) lines;
  @override
  String get kind => 'nobody';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    bank.want(top.file);
    bank.want(bottom.file);
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    final label = h * 0.085;
    final ph = h / 2 - label;
    final a = f.bank.image(top.file), b = f.bank.image(bottom.file);
    if (a != null) {
      c.save();
      c.clipRect(Rect.fromLTWH(0, label, w, ph));
      c.translate(0, label);
      MemeShot(top, w, ph, zoom: 1.05 + 0.03 * math.sin(f.t), focus: top.face).draw(c, a);
      c.restore();
    }
    if (b != null) {
      c.save();
      c.clipRect(Rect.fromLTWH(0, h / 2 + label, w, ph));
      c.translate(0, h / 2 + label);
      final punch = 1 + 0.35 * f.kick;
      MemeShot(bottom, w, ph, zoom: (1.3 + 0.4 * r(2)) * punch, focus: bottom.face, rot: (f.beatInBar.isEven ? 1 : -1) * 0.05 * f.beatDecay,
              shift: Offset(f.shake.dx * w * 3, f.shake.dy * h * 3))
          .draw(c, b);
      c.restore();
    }
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final h = size.height;
    final s = (h * 0.055).roundToDouble();
    final (l1, l2) = lines;
    final p1 = f.type.text('nb1|$l1|$s', () => TextSpan(text: l1, style: Mag.title(s, color: Colors.black)), align: TextAlign.left, maxWidth: size.width * 0.95);
    p1.paint(c, Offset(size.width * 0.03, h * 0.012));
    final p2 = f.type.text('nb2|$l2|$s', () => TextSpan(text: l2, style: Mag.title(s, color: Colors.black)), align: TextAlign.left, maxWidth: size.width * 0.95);
    p2.paint(c, Offset(size.width * 0.03 + f.shake.dx * size.width, h * 0.512));
  }
}

/// The expanding brain: four rows, a row a bar, each label more and each
/// dormouse more unhinged than the last.
class BrainBit extends MemeBit {
  @override
  bool get quiet => true;
  BrainBit(super.start, super.bars, super.seed, this.photos, this.labels);
  final List<MemePhoto> photos;
  final List<String> labels;
  @override
  String get kind => 'brain';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    final rows = math.min(4, photos.length);
    final rh = h / rows;
    final bar = beatsIn(f) / 4;
    for (var i = 0; i < rows; i++) {
      final k = ((bar - i) * 4).clamp(0.0, 1.0);
      if (k <= 0) continue;
      final y = i * rh;
      final glow = i / (rows - 1);
      // The glow behind the later rows: the cosmic brain's.
      if (glow > 0.3) {
        c.drawRect(
            Rect.fromLTWH(0, y, w, rh),
            Paint()
              ..shader = ui.Gradient.radial(Offset(w * 0.72, y + rh / 2), w * 0.3,
                  [HSLColor.fromAHSL(0.9 * glow, 48 + 220 * glow, 1, 0.6).toColor(), Colors.white.withValues(alpha: 0)]));
      }
      final img = f.bank.image(photos[i].file);
      if (img != null) {
        final x0 = w * 0.44, pw = w * 0.56 - w * 0.02;
        c.save();
        c.clipRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x0, y + rh * 0.04, pw, rh * 0.92), Radius.circular(h * 0.01)));
        c.translate(x0 + pw * (1 - Curves.easeOutBack.transform(k)), y + rh * 0.04);
        final shake = i == rows - 1 ? Offset(f.shake.dx * w * 4, f.shake.dy * h * 4) : Offset.zero;
        MemeShot(photos[i], pw, rh * 0.92, zoom: 1.1 + 0.6 * glow * (1 + 0.3 * f.kick), focus: photos[i].face, shift: shake)
            .draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(1 + 2.2 * glow, 1 + 0.6 * glow));
        c.restore();
      }
      c.drawRect(Rect.fromLTWH(0, y, w, h * 0.004), Paint()..color = const Color(0xFFDDDDDD));
    }
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final rows = math.min(4, photos.length);
    final rh = size.height / rows;
    final bar = beatsIn(f) / 4;
    for (var i = 0; i < rows && i < labels.length; i++) {
      final k = ((bar - i) * 4).clamp(0.0, 1.0);
      if (k <= 0) continue;
      // Bigger down the rows, smaller for a long one, so none wraps mid-word.
      final s = (size.height * (0.05 + 0.025 * i) * (labels[i].length > 12 ? 11 / labels[i].length : 1).clamp(0.5, 1.0)).roundToDouble();
      final p = f.type.text('br|${labels[i]}|$s', () => TextSpan(text: labels[i], style: Mag.title(s, color: Colors.black)), align: TextAlign.left, maxWidth: size.width * 0.42);
      c.save();
      c.translate(size.width * 0.03, i * rh + rh / 2 - p.height / 2);
      c.scale(_pop(k, 1));
      p.paint(c, Offset.zero);
      c.restore();
    }
  }
}

/// A history lesson: engravings and a Roman jar in sepia, a fact typed under each.
class HistoryBit extends MemeBit {
  @override
  bool get quiet => true;
  HistoryBit(super.start, super.bars, super.seed, this.photos, this.facts);
  final List<MemePhoto> photos;
  final List<String> facts;
  @override
  String get kind => 'history';
  @override
  bool get takeover => true;

  int _slide(MemeFrame f) => (beatsIn(f) / 8).floor().clamp(0, photos.length - 1);

  @override
  void warm(MemeBank bank) {
    for (final p in photos.take(2)) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF2A2218));
    if (photos.isEmpty) return;
    final i = _slide(f);
    if (i + 1 < photos.length) f.bank.want(photos[i + 1].file);
    final img = f.bank.image(photos[i].file);
    if (img == null) return;
    final into = (beatsIn(f) - i * 8) / 8;
    final photo = photos[i];
    final zoom = 1.08 + 0.25 * into;
    final focus = Offset.lerp(Offset(0.5 + (photo.face.dx - 0.5) * 0.3, 0.5 + (photo.face.dy - 0.5) * 0.3), photo.face, into)!;
    MemeShot(photo, w, h, zoom: zoom, focus: focus).draw(c, img, paint: Paint()..colorFilter = MemeFilters.sepia);
    // The paper: a warm vignette, a few scratches.
    c.drawRect(Rect.fromLTWH(0, 0, w, h),
        Paint()..shader = ui.Gradient.radial(Offset(w / 2, h / 2), w * 0.7, const [Color(0x00000000), Color(0x99201408)]));
    final rnd = math.Random((f.t * 8).floor());
    for (var k = 0; k < 3; k++) {
      final x = rnd.nextDouble() * w;
      c.drawLine(Offset(x, 0), Offset(x + rnd.nextDouble() * 8 - 4, h), Paint()..color = Colors.white.withValues(alpha: 0.08 * rnd.nextDouble()));
    }
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    final s = (h * 0.038).roundToDouble();
    f.type.text('ht|$s', () => TextSpan(text: 'GESCHICHTSSTUNDE', style: Mag.flag(s * 0.8, color: const Color(0xFFF2E2B8)))).paint(c, Offset(w * 0.04, h * 0.05));
    final i = _slide(f);
    if (i >= facts.length) return;
    final into = (beatsIn(f) - i * 8) / 8;
    c.drawRect(Rect.fromLTWH(0, h * 0.78, w, h * 0.22), Paint()..color = const Color(0xB3160F08));
    f.type.typed(c, Offset(w * 0.05, h * 0.81), facts[i], into * 2.2, s, colour: const Color(0xFFF2E2B8), maxWidth: w * 0.9);
  }
}

/// Top seven moments: a bar of title, then a bar for each — a number, a picture, a
/// line — counting down to one.
class TopSevenBit extends MemeBit {
  @override
  bool get quiet => true;
  TopSevenBit(super.start, super.bars, super.seed, this.photos, this.lines);
  final List<MemePhoto> photos;
  final List<String> lines;
  @override
  String get kind => 'top7';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos.take(3)) {
      bank.want(p.file);
    }
  }

  int _entry(MemeFrame f) => (beatsIn(f) / 4).floor() - 1;

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF101014));
    final e = _entry(f);
    if (e < 0 || e >= photos.length) return;
    if (e + 1 < photos.length) f.bank.want(photos[e + 1].file);
    final img = f.bank.image(photos[e].file);
    if (img == null) return;
    final into = (beatsIn(f) - (e + 1) * 4) / 4;
    final box = Rect.fromLTWH(w * 0.38, h * 0.1, w * 0.58, h * 0.68);
    final slide = 1 - _pop(into, 0.25);
    c.save();
    c.translate(w * 0.6 * slide, 0);
    c.drawRect(box.inflate(h * 0.012), Paint()..color = Colors.white);
    c.clipRect(box);
    c.translate(box.left, box.top);
    MemeShot(photos[e], box.width, box.height, zoom: 1.15 + 0.1 * into + 0.08 * f.kick, focus: photos[e].face).draw(c, img);
    c.restore();
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    final e = _entry(f);
    if (e < 0) {
      final k = beatsIn(f) / 4;
      final t1 = f.type.bold('TOP 7', h * 0.22, f.look.hi, width: 62);
      final t2 = f.type.bold('SIEBENSCHLÄFER MOMENTE', h * 0.08, Colors.white, width: 110);
      f.type.paintBold(c, t1, Offset(w / 2, h * 0.4), scale: _pop(k, 0.3) * (1 + 0.08 * f.kick));
      f.type.paintBold(c, t2, Offset(w / 2, h * 0.62), scale: _pop(k - 0.15, 0.3));
      return;
    }
    if (e >= photos.length) return;
    final into = (beatsIn(f) - (e + 1) * 4) / 4;
    final n = f.type.bold('${7 - e}', h * 0.36, f.look.hi, width: 62);
    f.type.paintBold(c, n, Offset(w * 0.19, h * 0.42), scale: _pop(into, 0.2) * (1 + 0.1 * f.kick), rot: -0.08);
    final line = e < lines.length ? lines[e] : '';
    if (line.isEmpty) return;
    final s = (h * 0.05).roundToDouble();
    final p = f.type.text('t7|$line|$s', () => TextSpan(text: line.toUpperCase(), style: Mag.title(s, color: Colors.white)), maxWidth: w * 0.9);
    p.paint(c, Offset((w - p.width) / 2, h * 0.84));
  }
}

/// A freeze frame: the last picture held in sepia with "To Be Continued" sliding in,
/// or in grey under "WASTED". The bit owns the picture it was handed.
class FreezeBit extends MemeBit {
  @override
  bool get quiet => true;
  FreezeBit(super.start, super.bars, super.seed, this.image, {required this.wasted});
  final ui.Image image;
  final bool wasted;
  @override
  String get kind => wasted ? 'wasted' : 'tbc';
  @override
  bool get takeover => true;

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final paint = Paint()
      ..colorFilter = wasted ? MemeFilters.grey : MemeFilters.sepia
      ..filterQuality = FilterQuality.low;
    c.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Rect.fromLTWH(0, 0, w, h), paint);
    if (wasted) {
      c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black.withValues(alpha: 0.35));
    }
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    final k = (beatsIn(f) / 1.5).clamp(0.0, 1.0);
    if (wasted) {
      c.drawRect(Rect.fromLTWH(0, h * 0.4, w, h * 0.2), Paint()..color = Colors.black.withValues(alpha: 0.55 * k));
      final t = f.type.text('ws|${(h * 0.2).round()}', () => TextSpan(text: 'WASTED', style: Mag.headline((h * 0.2).roundToDouble(), width: 125, color: const Color(0xFFB3122A))));
      c.save();
      c.translate(w / 2, h / 2);
      c.scale(1.6 - 0.6 * Curves.easeOut.transform(k));
      t.paint(c, Offset(-t.width / 2, -t.height / 2));
      c.restore();
      return;
    }
    // The arrow slides in from the left, the words with it.
    final x = w * (-0.6 + 0.6 * Curves.easeOut.transform(k));
    final y = h * 0.78;
    final s = (h * 0.075).roundToDouble();
    final arrow = Path()
      ..moveTo(x, y - s * 0.5)
      ..lineTo(x + s * 5.2, y - s * 0.5)
      ..lineTo(x + s * 5.2, y - s * 0.95)
      ..lineTo(x + s * 6.3, y)
      ..lineTo(x + s * 5.2, y + s * 0.95)
      ..lineTo(x + s * 5.2, y + s * 0.5)
      ..lineTo(x, y + s * 0.5)
      ..close();
    c.drawPath(arrow, Paint()..color = const Color(0xFFF2E6C8));
    c.drawPath(
        arrow,
        Paint()
          ..color = const Color(0xFF3A2A12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.08);
    final t = f.type.text('tbc|$s', () => TextSpan(text: 'To Be Continued', style: Mag.quote(s * 0.9, color: const Color(0xFF3A2A12))));
    t.paint(c, Offset(x + s * 0.4, y - t.height / 2));
  }

  @override
  void dispose() => image.dispose();
}

// ------------------------------------------------------------------- overlays

/// "ACHTUNG: BLITZLICHTER" — hazard stripes and a word flashing on the beat.
class WarningBit extends MemeBit {
  WarningBit(super.start, super.bars, super.seed);
  @override
  String get kind => 'warning';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    final on = (f.beats * 2).floor().isEven;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black.withValues(alpha: on ? 0.7 : 0.5));
    final stripe = Paint()..color = on ? const Color(0xFFFFD400) : const Color(0xFF1A1A1A);
    final band = h * 0.1;
    c.drawRect(Rect.fromLTWH(0, h * 0.15, w, band), Paint()..color = const Color(0xFF1A1A1A));
    c.drawRect(Rect.fromLTWH(0, h * 0.75, w, band), Paint()..color = const Color(0xFF1A1A1A));
    final step = h * 0.12;
    for (var x = -step + (f.t * h * 0.6) % step; x < w + step; x += step) {
      for (final y in [h * 0.15, h * 0.75]) {
        c.drawPath(
            Path()
              ..moveTo(x, y)
              ..lineTo(x + step * 0.5, y)
              ..lineTo(x + step * 0.5 - band * 0.6, y + band)
              ..lineTo(x - band * 0.6, y + band)
              ..close(),
            stripe);
      }
    }
    final t1 = f.type.bold('⚠ ACHTUNG', h * 0.11, on ? const Color(0xFFFFD400) : Colors.white, width: 110);
    final t2 = f.type.bold('BLITZLICHTER', h * 0.15, on ? Colors.white : const Color(0xFFFF2A1A), width: 72);
    f.type.paintBold(c, t1, Offset(w / 2, h * 0.37), scale: 1 + 0.08 * f.beatDecay);
    f.type.paintBold(c, t2, Offset(w / 2, h * 0.55), scale: 1 + 0.12 * f.kick);
  }
}

/// A news channel's lower third, the ticker running.
class NewsBit extends MemeBit {
  NewsBit(super.start, super.bars, super.seed, this.headline, this.ticker);
  final String headline, ticker;
  @override
  String get kind => 'news';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final k = (beatsIn(f) / 1).clamp(0.0, 1.0);
    final out = ((bars * 4 - beatsIn(f)) / 1).clamp(0.0, 1.0);
    f.type.lowerThird(c, size, 'Eilmeldung', headline, ticker, beatsIn(f) * 0.08, slide: Curves.easeOut.transform(math.min(k, out)));
  }
}

/// Error boxes: one more on every snare, stacking up, lit on the kick.
class ErrorsBit extends MemeBit {
  ErrorsBit(super.start, super.bars, super.seed, this.lines);
  final List<String> lines;
  final _boxes = <(double, Offset, String, String)>[];
  @override
  String get kind => 'errors';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    if ((f.snareEdge || (f.newBeat && f.snare < 0.1)) && _boxes.length < 9) {
      final i = _boxes.length;
      final line = lines.isEmpty ? 'siebenschlaefer.exe|reagiert nicht mehr.' : lines[(pick(i + 1, lines.length))];
      final parts = line.split('|');
      _boxes.add((f.t, Offset(0.08 + 0.55 * r(i * 2 + 20), 0.08 + 0.5 * r(i * 2 + 21)), parts.first, parts.length > 1 ? parts[1] : ''));
    }
    for (final (born, at, title, body) in _boxes) {
      f.type.dialog(c, Offset(at.dx * size.width, at.dy * size.height), size.height, title, body, scale: 1.25 * _pop(f.t - born, 0.18), lit: f.kick > 0.5);
    }
  }
}

/// A rubber stamp slammed on the downbeat, held, then gone.
class StampBit extends MemeBit {
  StampBit(super.start, super.bars, super.seed, this.word);
  final String word;
  @override
  String get kind => 'stamp';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final age = beatsIn(f) * f.spb;
    final k = (age / 0.12).clamp(0.0, 1.0);
    final scale = 2.6 - 1.6 * Curves.easeIn.transform(k);
    final fade = ((bars * 4 - beatsIn(f)) / 1).clamp(0.0, 1.0);
    // Off the face: the emptier side.
    final x = f.face.dx < 0.5 ? 0.72 : 0.28;
    final y = f.face.dy < 0.5 ? 0.68 : 0.3;
    f.type.stamp(c, Offset(x * size.width, y * size.height), word, size.height,
        rot: (r(1) - 0.5) * 0.6, scale: scale * (1 + 0.05 * f.kick), opacity: 0.92 * fade, colour: f.look.style == MemeStyle.vapor ? f.look.hi : const Color(0xFFE0141E));
  }
}

/// A speech bubble at the mouth with a short word in it, wobbling.
class BubbleBit extends MemeBit {
  BubbleBit(super.start, super.bars, super.seed, this.line);
  final String line;
  @override
  String get kind => 'bubble';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final k = _pop(beatsIn(f) * f.spb, 0.25);
    final out = ((bars * 4 - beatsIn(f)) / 0.5).clamp(0.0, 1.0);
    final mouth = Offset(f.face.dx * size.width, (f.face.dy + 0.05) * size.height);
    final side = f.face.dx < 0.5 ? 1.0 : -1.0;
    final at = mouth + Offset(side * size.width * 0.22, -size.height * 0.22) + Offset(math.sin(f.t * 3) * 6, math.cos(f.t * 2.3) * 5);
    f.type.bubble(c, at, mouth, line, size.height, scale: k * out);
  }
}

/// A mouse cursor finds the face and clicks on it with every beat.
class CursorBit extends MemeBit {
  CursorBit(super.start, super.bars, super.seed);
  @override
  String get kind => 'cursor';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    final from = Offset(r(1) < 0.5 ? -0.05 : 1.05, r(2) < 0.5 ? -0.05 : 1.05);
    final k = Curves.easeInOut.transform((beatsIn(f) / 1.5).clamp(0.0, 1.0));
    final target = Offset(f.face.dx, f.face.dy);
    final at = Offset.lerp(from, target, k)! + Offset(math.sin(f.t * 1.7) * 0.006, math.cos(f.t * 1.3) * 0.006);
    final p = Offset(at.dx * w, at.dy * h);
    // The click: a ring on the beat, once there.
    if (k >= 1) {
      final ring = f.beatDecay;
      c.drawCircle(p, h * 0.02 + h * 0.06 * (1 - ring), Paint()
        ..color = Colors.white.withValues(alpha: 0.8 * ring)
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.006);
      if (ring > 0.5) {
        final s = (h * 0.03).roundToDouble();
        f.type.text('clk|$s', () => TextSpan(text: '*klick*', style: Mag.marker(s, color: Colors.white))).paint(c, p + Offset(h * 0.04, -h * 0.07));
      }
    }
    final s = h * 0.055 * (k >= 1 ? 1 - 0.15 * f.beatDecay : 1);
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, s)
      ..lineTo(s * 0.27, s * 0.78)
      ..lineTo(s * 0.45, s * 1.12)
      ..lineTo(s * 0.62, s * 1.04)
      ..lineTo(s * 0.45, s * 0.7)
      ..lineTo(s * 0.78, s * 0.7)
      ..close();
    c.save();
    c.translate(p.dx, p.dy);
    c.drawPath(arrow, Paint()..color = Colors.white);
    c.drawPath(
        arrow,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.08);
    c.restore();
  }
}

/// A reaction cam in the corner: a dormouse watching the edit, jumping on the kick.
class PipBit extends MemeBit {
  PipBit(super.start, super.bars, super.seed, this.photo);
  final MemePhoto photo;
  @override
  String get kind => 'pip';

  @override
  void warm(MemeBank bank) => bank.want(photo.file);

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final img = f.bank.image(photo.file);
    if (img == null) return;
    final w = size.width, h = size.height;
    final k = _pop(beatsIn(f) * f.spb, 0.3);
    final out = ((bars * 4 - beatsIn(f)) / 0.5).clamp(0.0, 1.0);
    final bw = w * 0.26 * k * out, bh = bw * 0.75;
    final box = Rect.fromLTWH(w * 0.97 - bw, h * (f.mood == MemeMood.rage ? 0.86 : 0.95) - bh, bw, bh);
    final rr = RRect.fromRectAndRadius(box, Radius.circular(h * 0.015));
    c.drawRRect(rr.inflate(h * 0.006), Paint()..color = Colors.white);
    c.save();
    c.clipRRect(rr);
    c.translate(box.left, box.top);
    MemeShot(photo, box.width, box.height, zoom: 1.6 + 0.4 * f.kick, focus: photo.face, rot: (f.beatInBar.isEven ? 1 : -1) * 0.06 * f.beatDecay).draw(c, img);
    c.restore();
    final s = (h * 0.025).roundToDouble();
    f.type.text('pip|$s', () => TextSpan(text: 'REAKTION', style: Mag.flag(s, color: Colors.white)))
        .paint(c, Offset(box.left + s * 0.4, box.top + s * 0.3));
  }
}

/// A cut-out bouncing off the edges, the DVD logo's way, with the corner it is
/// about to hit everyone's hope.
class DvdBit extends MemeBit {
  DvdBit(super.start, super.bars, super.seed, this.sticker);
  final MemeSticker sticker;
  @override
  String get kind => 'dvd';

  @override
  void warm(MemeBank bank) => bank.want(sticker.file);

  double _tri(double x) {
    final p = x % 2;
    return p < 1 ? p : 2 - p;
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final img = f.bank.image(sticker.file);
    if (img == null) return;
    final w = size.width, h = size.height;
    final dh = h * 0.22, dw = dh * sticker.w / sticker.h;
    final t = beatsIn(f) * f.spb;
    final x = _tri(t * (0.16 + 0.06 * r(1)) + r(2) * 2) * (w - dw) + dw / 2;
    final y = _tri(t * (0.21 + 0.06 * r(3)) + r(4) * 2) * (h - dh) + dh / 2;
    final nearX = math.min(x - dw / 2, w - dw / 2 - x) < h * 0.02, nearY = math.min(y - dh / 2, h - dh / 2 - y) < h * 0.02;
    drawSticker(c, img, sticker, Offset(x, y), dh * (1 + 0.06 * f.kick));
    if (nearX && nearY) {
      f.type.paintBold(c, f.type.bold('ECKE!!!', h * 0.14, f.look.hi), Offset(w / 2, h / 2));
    }
  }
}

/// A spectrum at the bottom, the way a music channel's visualiser sits under a
/// video: bars from the bands, with the kick in the bass end.
class SpectrumBit extends MemeBit {
  SpectrumBit(super.start, super.bars, super.seed);
  @override
  String get kind => 'spectrum';

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    const n = 40;
    final k = _pop(beatsIn(f) * f.spb, 0.3) * ((bars * 4 - beatsIn(f)) / 0.5).clamp(0.0, 1.0);
    final bw = w / n;
    final base = h * (f.mood == MemeMood.rage ? 0.905 : 0.99);
    for (var i = 0; i < n; i++) {
      final x = i / (n - 1);
      final band = x < 0.33 ? f.low * (1 + 0.6 * f.kick) : (x < 0.66 ? f.mid : f.high);
      final jitter = 0.6 + 0.4 * memeHash(i, (f.t * 20).floor(), 2);
      final v = (band * jitter * (1 - 0.3 * x)).clamp(0.04, 1.0) * h * 0.22 * k;
      final colour = HSLColor.fromAHSL(0.9, (f.hue * 360 + x * 120) % 360, 0.9, 0.55).toColor();
      c.drawRect(Rect.fromLTWH(i * bw + bw * 0.15, base - v, bw * 0.7, v), Paint()..color = colour);
      c.drawRect(Rect.fromLTWH(i * bw + bw * 0.15, base - v - h * 0.008, bw * 0.7, h * 0.006), Paint()..color = Colors.white);
    }
  }
}

/// Which bit a phrase gets: the pool, weighed by the mood, the style and the heat.
class MemeBitPicker {
  const MemeBitPicker._();

  /// A bit for [f] starting at [start], or null for none this phrase. [takeoverOk]
  /// is false where one is on already.
  static MemeBit? pick(MemeFrame f, double start, int seed, {required bool takeoverOk, required bool overlayOk, Set<String> notAgain = const {}}) {
    final bank = f.bank;
    final style = f.look.style;
    final w = <(String, double)>[];
    void add(String kind, double weight) {
      if (weight > 0) w.add((kind, weight));
    }

    final sleepers = bank.set('sleep'), stares = bank.sets({'stare', 'wake'}), chaos = bank.sets({'chaos', 'stare'});
    final old = bank.sets({'old', 'roman', 'devil', 'hunt'});
    final awake = [for (final s in bank.stickers) if (s.set != 'sleep') s];
    final hasClip = bank.clips.isNotEmpty, hasStickers = awake.isNotEmpty, many = bank.photos.length >= 12;
    final y2k = style == MemeStyle.y2k, vapor = style == MemeStyle.vapor;
    switch (f.mood) {
      case MemeMood.sleep:
        final asleep = [for (final s in bank.stickers) if (s.set == 'sleep') s];
        if (takeoverOk) {
          add('night', asleep.isEmpty ? 0 : 1.1);
          add('screensaver', hasStickers ? 0.8 : 0);
          add('spotlight', sleepers.isEmpty ? 0 : 0.8);
          add('polaroids', sleepers.length < 3 ? 0 : 0.4);
          add('film', many ? 0.3 : 0);
        }
        if (overlayOk) add('bubble', 0.2);
      case MemeMood.wake:
        break;
      case MemeMood.vibe:
        if (takeoverOk) {
          add('clip', hasClip ? 1.0 : 0);
          add('wall', many ? 0.9 : 0);
          add('polaroids', 0.8);
          add('parallax', hasStickers ? 0.8 : 0);
          add('kaleido', 0.7);
          add('strips', 0.7);
          add('spotlight', f.busy < 0.5 ? 0.6 : 0.2);
          add('film', many ? 0.7 : 0);
          add('rings', hasStickers ? 0.5 : 0);
          add('duotone', 0.6);
          add('documentary', f.busy < 0.7 ? 0.8 : 0.3);
          add('loupe', 0.6);
          add('booth', 0.6);
          add('flip', many ? 0.7 : 0);
          add('screensaver', hasStickers ? (y2k ? 1.2 : 0.6) : 0);
          add('history', old.isEmpty || f.busy > 0.65 ? 0 : 0.6);
          add('sunburst', hasStickers ? (vapor ? 0.5 : 0.25) : 0);
          add('nobody', sleepers.isEmpty ? 0 : 0.15);
          add('brain', stares.length < 4 ? 0 : 0.1);
          add('top7', chaos.length < 7 ? 0 : 0.15);
        }
        if (overlayOk) {
          add('pip', 0.4);
          add('spectrum', vapor ? 0.6 : 0.3);
          add('dvd', hasStickers ? 0.2 : 0);
          add('news', 0.2);
          add('bubble', 0.25);
          add('stamp', 0.1);
          add('cursor', y2k ? 0.3 : 0.08);
          add('errors', y2k ? 0.4 : 0.05);
        }
      case MemeMood.rage:
        if (takeoverOk) {
          add('clip', hasClip ? 0.9 : 0);
          add('strips', 0.8);
          add('wall', many ? 0.7 : 0);
          add('kaleido', 0.7);
          add('rings', hasStickers ? 0.7 : 0);
          add('duotone', 0.5);
          add('flip', many ? 0.8 : 0);
          add('crowd', awake.length < 4 ? 0 : 0.35 * f.hot);
          add('sunburst', hasStickers ? 0.25 : 0);
        }
        if (overlayOk) {
          add('spectrum', 0.4);
          add('pip', 0.2);
          add('stamp', 0.15);
          add('errors', y2k ? 0.3 : 0.05);
        }
    }
    w.removeWhere((e) => notAgain.contains(e.$1));
    if (w.isEmpty) return null;
    var total = 0.0;
    for (final (_, k) in w) {
      total += k;
    }
    var roll = memeHash(seed, 5, 9) * total;
    var kind = w.last.$1;
    for (final (name, k) in w) {
      if (roll < k) {
        kind = name;
        break;
      }
      roll -= k;
    }
    return make(kind, f, start, seed);
  }

  static MemeBit? make(String kind, MemeFrame f, double start, int seed) {
    final bank = f.bank;
    double r(int n) => memeHash(seed, n, 13);
    T one<T>(List<T> l, int n) => l[(r(n) * l.length).floor() % l.length];
    List<T> some<T>(List<T> l, int count, int n) {
      final out = <T>[];
      for (var i = 0; i < count && l.isNotEmpty; i++) {
        var p = l[((r(n + i) * l.length).floor() + i) % l.length];
        if (out.contains(p)) p = l[(l.indexOf(p) + 1) % l.length];
        out.add(p);
      }
      return out;
    }

    final awake = [for (final s in bank.stickers) if (s.set != 'sleep') s];
    switch (kind) {
      case 'clip':
        return bank.clips.isEmpty ? null : ClipBit(start, f.mood == MemeMood.rage ? 4 : 8, seed, one(bank.clips, 1));
      case 'screensaver':
        return awake.isEmpty ? null : ScreensaverBit(start, f.mood == MemeMood.sleep ? 16 : 12, seed, one(awake, 1));
      case 'wall':
        return WallBit(start, 8, seed, some(bank.sets({'stare', 'chaos', 'wake'}), 12, 1));
      case 'polaroids':
        final pool = f.mood == MemeMood.sleep ? bank.set('sleep') : bank.sets({'stare', 'chaos', 'wake'});
        return pool.isEmpty ? null : PolaroidBit(start, 8, seed, some(pool, 6, 1), [for (var i = 0; i < 6; i++) bank.line('polaroid', seed, i) ?? '']);
      case 'parallax':
        final pool = bank.sets({'stare', 'chaos', 'wake'});
        return awake.isEmpty || pool.isEmpty ? null : ParallaxBit(start, 8, seed, one(pool, 1), one(awake, 2));
      case 'kaleido':
        return KaleidoBit(start, 8, seed, one(bank.sets({'stare', 'chaos'}), 1));
      case 'strips':
        return StripsBit(start, 8, seed, some(bank.sets({'stare', 'chaos', 'wake'}), 3, 1));
      case 'spotlight':
        final pool = f.mood == MemeMood.sleep ? bank.set('sleep') : bank.sets({'stare', 'wake'});
        return pool.isEmpty ? null : SpotlightBit(start, 8, seed, some(pool, 2, 1));
      case 'film':
        return FilmBit(start, 8, seed, some(bank.sets({'stare', 'chaos', 'wake', 'sleep'}), 10, 1), bank.clips.isEmpty || r(9) < 0.5 ? null : one(bank.clips, 1));
      case 'rings':
        return awake.isEmpty ? null : RingsBit(start, 8, seed, one(awake, 1));
      case 'duotone':
        return DuotoneBit(start, 8, seed, some(bank.sets({'stare', 'chaos', 'wake'}), 4, 1));
      case 'night':
        final asleep = [for (final s in bank.stickers) if (s.set == 'sleep') s];
        return asleep.isEmpty ? null : NightBit(start, 16, seed, one(asleep, 1));
      case 'documentary':
        return DocumentaryBit(start, 8, seed, some(bank.sets({'stare', 'wake', 'chaos'}), 2, 1), bank.line('documentary', seed, 1) ?? '');
      case 'loupe':
        final eyed = [for (final p in bank.sets({'stare', 'wake'})) if (p.eyes.isNotEmpty) p];
        return eyed.isEmpty ? null : LoupeBit(start, 8, seed, one(eyed, 1));
      case 'booth':
        return BoothBit(start, 8, seed, some(bank.sets({'stare', 'chaos', 'wake'}), 8, 1));
      case 'flip':
        return FlipBit(start, 8, seed, some(bank.sets({'stare', 'chaos', 'wake'}), 12, 1));
      case 'sunburst':
        return awake.isEmpty ? null : SunburstBit(start, 4, seed, one(awake, 1));
      case 'crowd':
        return awake.isEmpty ? null : CrowdBit(start, 4, seed, some(awake, 12, 1));
      case 'nobody':
        final sleepers = bank.set('sleep'), chaos = bank.sets({'chaos', 'stare'});
        if (sleepers.isEmpty || chaos.isEmpty) return null;
        final pair = (bank.line('nobody', seed, 1) ?? 'Nobody:|Siebenschläfer um 3 Uhr nachts:').split('|');
        return NobodyBit(start, 2, seed, one(sleepers, 1), one(chaos, 2), (pair.first, pair.length > 1 ? pair[1] : ''));
      case 'brain':
        final labels = (bank.line('brain', seed, 1) ?? 'maus|ratte|eichhörnchen|SIEBENSCHLÄFER').split('|');
        return BrainBit(start, 4, seed, some(bank.sets({'stare', 'chaos'}), 4, 1), labels);
      case 'history':
        final old = bank.set('old'), roman = bank.set('roman'), devil = bank.set('devil'), hunt = bank.set('hunt');
        final photos = <MemePhoto>[], facts = <String>[];
        if (old.isNotEmpty) {
          photos.add(one(old, 1));
          facts.add(bank.line('facts', seed, 1) ?? '');
        }
        if (roman.isNotEmpty) {
          photos.add(one(roman, 2));
          facts.add(bank.line('roman', seed, 2) ?? '');
        }
        if (devil.isNotEmpty && r(3) < 0.5) {
          photos.add(devil.first);
          facts.add(bank.line('devil', seed, 3) ?? '');
        } else if (hunt.isNotEmpty) {
          photos.add(hunt.first);
          facts.add(bank.line('hunt', seed, 3) ?? '');
        }
        if (old.length > 1) {
          photos.add(one(old, 4));
          facts.add(bank.line('facts', seed, 4) ?? '');
        }
        return photos.isEmpty ? null : HistoryBit(start, photos.length * 2, seed, photos, facts);
      case 'top7':
        final lines = [for (var i = 0; i < 7; i++) bank.line('top7', seed, i + 1) ?? ''];
        return TopSevenBit(start, 8, seed, some(bank.sets({'chaos', 'stare', 'wake'}), 7, 1), lines);
      case 'warning':
        return WarningBit(start, 1, seed);
      case 'news':
        final head = bank.line('news', seed, 1) ?? 'Siebenschläfer wieder wach';
        final ticker = bank.lines('ticker').join('   +++   ');
        return NewsBit(start, 4, seed, head, ticker.isEmpty ? head : ticker);
      case 'errors':
        return ErrorsBit(start, 4, seed, bank.lines('errors'));
      case 'stamp':
        return StampBit(start, 2, seed, bank.line('stamps', seed, 1) ?? 'GOATED');
      case 'bubble':
        return BubbleBit(start, 2, seed, bank.line('bubbles', seed, 1) ?? 'nein.');
      case 'cursor':
        return CursorBit(start, 2, seed);
      case 'pip':
        final stares = bank.set('stare');
        return stares.isEmpty ? null : PipBit(start, 4, seed, one(stares, 1));
      case 'dvd':
        return awake.isEmpty ? null : DvdBit(start, 8, seed, one(awake, 1));
      case 'spectrum':
        return SpectrumBit(start, 4, seed);
    }
    return null;
  }
}

// ----------------------------------------------------------------------- looks

/// The screensaver: a cut-out drifting on black, off every edge it meets, in a new
/// tint each time — the one everyone waited on to hit the corner. A faint trail
/// behind it; a breath on the beat.
class ScreensaverBit extends MemeBit {
  ScreensaverBit(super.start, super.bars, super.seed, this.sticker);
  final MemeSticker sticker;
  @override
  String get kind => 'screensaver';
  @override
  bool get takeover => true;
  @override
  bool get quiet => true;

  @override
  void warm(MemeBank bank) => bank.want(sticker.file);

  // The path: a triangle wave each way, so the bounces are exact.
  (double, double, int) _at(double t, double span, double speed, double phase) {
    final x = t * speed + phase;
    final bounces = x.floor();
    final p = x - bounces;
    return (bounces.isEven ? p : 1 - p, 0, bounces);
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
    final img = f.bank.image(sticker.file);
    if (img == null) return;
    final dh = h * 0.4, dw = dh * sticker.w / sticker.h;
    final t = beatsIn(f) * f.spb;
    final sx = 0.06 + 0.02 * r(1), sy = 0.08 + 0.02 * r(2);
    final (px, _, bx) = _at(t, w - dw, sx, r(3));
    final (py, _, by) = _at(t, h - dh, sy, r(4));
    final bounces = bx + by;
    final hue = (bounces * 0.37 + r(5)) % 1.0;
    final tint = HSLColor.fromAHSL(1, hue * 360, 0.85, 0.62).toColor();
    final at = Offset(dw / 2 + px * (w - dw), dh / 2 + py * (h - dh));
    // The trail: ghosts a little behind, fading.
    for (var k = 5; k >= 1; k--) {
      final tt = t - k * 0.05;
      final (gx, _, _) = _at(tt, w - dw, sx, r(3));
      final (gy, _, _) = _at(tt, h - dh, sy, r(4));
      c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, 0.07));
      drawSticker(c, img, sticker, Offset(dw / 2 + gx * (w - dw), dh / 2 + gy * (h - dh)), dh, shadow: false);
      c.restore();
    }
    c.saveLayer(null, Paint());
    drawSticker(c, img, sticker, at, dh * (1 + 0.04 * f.beatDecay), shadow: false);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = tint..blendMode = BlendMode.modulate);
    c.restore();
    // The corner: a ring of light when it lands in one.
    final nearX = px < 0.01 || px > 0.99, nearY = py < 0.01 || py > 0.99;
    if (nearX && nearY) {
      c.drawCircle(at, dh * 0.9, Paint()..color = tint.withValues(alpha: 0.5)..style = PaintingStyle.stroke..strokeWidth = h * 0.01);
    }
  }
}

/// A video wall: a grid of photographs, each cell on its own clock, dissolving to
/// the next on a bar of its own; the kick lights a cell.
class WallBit extends MemeBit {
  WallBit(super.start, super.bars, super.seed, this.photos);
  final List<MemePhoto> photos;
  @override
  String get kind => 'wall';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF0A0A0C));
    if (photos.isEmpty) return;
    final cols = f.busy > 0.55 ? 4 : 3, rows = cols == 4 ? 3 : 2;
    final gap = h * 0.012;
    final cw = (w - gap * (cols + 1)) / cols, ch = (h - gap * (rows + 1)) / rows;
    final b = beatsIn(f);
    for (var i = 0; i < cols * rows; i++) {
      final x = gap + (i % cols) * (cw + gap), y = gap + (i ~/ cols) * (ch + gap);
      // Each cell cuts every four beats, at its own moment in the bar.
      final phase = (i * 1.37 + r(i)) % 4;
      final cut = ((b + phase) / 4).floor();
      final into = (b + phase) / 4 - cut;
      final a = photos[(cut * 5 + i * 3) % photos.length], prev = photos[((cut - 1) * 5 + i * 3) % photos.length];
      final ia = f.bank.image(a.file), ip = f.bank.image(prev.file);
      c.save();
      c.clipRect(Rect.fromLTWH(x, y, cw, ch));
      c.translate(x, y);
      final zoom = 1.08 + 0.1 * into;
      if (ip != null && into < 0.2) MemeShot(prev, cw, ch, zoom: 1.18, focus: prev.face).draw(c, ip);
      if (ia != null) {
        if (into < 0.2) c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, into / 0.2));
        MemeShot(a, cw, ch, zoom: zoom, focus: a.face).draw(c, ia);
        if (into < 0.2) c.restore();
      }
      final lit = (f.barIndex * 5 + f.beatInBar * 7 + 3) % (cols * rows) == i;
      if (lit && f.kick > 0.1) c.drawRect(Rect.fromLTWH(0, 0, cw, ch), Paint()..color = Colors.white.withValues(alpha: 0.3 * f.kick));
      c.restore();
    }
  }
}

/// Polaroids tossed on a table, one a bar, each with a line written under it.
class PolaroidBit extends MemeBit {
  PolaroidBit(super.start, super.bars, super.seed, this.photos, this.lines);
  final List<MemePhoto> photos;
  final List<String> lines;
  @override
  String get kind => 'polaroids';
  @override
  bool get takeover => true;
  @override
  bool get quiet => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos.take(3)) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final hue = (f.hue * 360) % 360;
    c.drawRect(Rect.fromLTWH(0, 0, w, h),
        Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(w, h), [HSLColor.fromAHSL(1, hue, 0.25, 0.16).toColor(), HSLColor.fromAHSL(1, (hue + 30) % 360, 0.3, 0.08).toColor()]));
    final bar = beatsIn(f) / 4;
    final n = math.min(photos.length, bar.floor() + 1);
    final cardW = h * 0.42, cardH = cardW * 1.22, pad = cardW * 0.06, photoH = cardW - 2 * pad;
    for (var i = 0; i < n; i++) {
      if (i + 1 < photos.length) f.bank.want(photos[i + 1].file);
      final img = f.bank.image(photos[i].file);
      final age = ((bar - i) * 4 * f.spb).clamp(0.0, 10.0);
      final drop = (age / 0.35).clamp(0.0, 1.0);
      final scale = 1.0 + 0.45 * (1 - Curves.easeOutCubic.transform(drop));
      final cx = w * (0.2 + 0.6 * r(i * 3 + 1)), cy = h * (0.3 + 0.4 * r(i * 3 + 2));
      final rot = (r(i * 3 + 3) - 0.5) * 0.5 + math.sin(f.t * 0.7 + i) * 0.01;
      c.save();
      c.translate(cx, cy);
      c.rotate(rot);
      c.scale(scale);
      final rect = Rect.fromCenter(center: Offset.zero, width: cardW, height: cardH);
      c.drawRect(rect.shift(Offset(cardW * 0.03, cardW * 0.04)), Paint()..color = Colors.black.withValues(alpha: 0.45 * drop));
      c.drawRect(rect, Paint()..color = const Color(0xFFF6F2E8).withValues(alpha: drop));
      final photoRect = Rect.fromLTWH(rect.left + pad, rect.top + pad, cardW - 2 * pad, photoH);
      c.drawRect(photoRect, Paint()..color = const Color(0xFF1A1816));
      if (img != null) {
        c.save();
        c.clipRect(photoRect);
        c.translate(photoRect.left, photoRect.top);
        MemeShot(photos[i], photoRect.width, photoRect.height, zoom: 1.05, focus: photos[i].face).draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(0.85, 1.05)..filterQuality = FilterQuality.medium);
        c.restore();
      }
      final line = i < lines.length ? lines[i] : '';
      if (line.isNotEmpty) {
        final s = (cardW * 0.09).roundToDouble();
        final p = f.type.text('pl|$line|$s', () => TextSpan(text: line, style: Mag.marker(s, color: const Color(0xFF2A2420))), maxWidth: cardW - 2 * pad);
        p.paint(c, Offset(-p.width / 2, photoRect.bottom + (cardH - photoH - 2 * pad) / 2 - p.height / 2 + pad * 0.3));
      }
      c.restore();
    }
  }
}

/// Parallax: a cut-out in front of a photograph, the two sliding against each other
/// as the bar goes, the way a 2.5D edit does; the bass brings the front forward.
class ParallaxBit extends MemeBit {
  ParallaxBit(super.start, super.bars, super.seed, this.photo, this.sticker);
  final MemePhoto photo;
  final MemeSticker sticker;
  @override
  String get kind => 'parallax';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    bank.want(photo.file);
    bank.want(sticker.file);
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final drift = math.sin(beatsIn(f) * math.pi / 16 + r(1) * 6);
    final bg = f.bank.image(photo.file);
    if (bg != null) {
      MemeShot(photo, w, h, zoom: 1.3, focus: Offset(photo.face.dx + 0.05 * drift, photo.face.dy), shift: Offset(f.shake.dx * w * 0.5, 0))
          .draw(c, bg, paint: Paint()..colorFilter = MemeFilters.punch(0.8, 0.95)..filterQuality = FilterQuality.medium);
      c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black.withValues(alpha: 0.3));
    }
    final fg = f.bank.image(sticker.file);
    if (fg == null) return;
    final dh = h * 0.72 * (1 + 0.05 * f.low + 0.03 * f.kick);
    final at = Offset(w * 0.5 - w * 0.06 * drift + f.shake.dx * w * 1.5, h * 0.62 - h * 0.02 * f.beatDecay);
    // A soft shadow, so it sits in front.
    c.saveLayer(null, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: h * 0.02, sigmaY: h * 0.02));
    drawSticker(c, fg, sticker, at + Offset(h * 0.03, h * 0.04), dh, shadow: false);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xAA000000)..blendMode = BlendMode.srcIn);
    c.restore();
    drawSticker(c, fg, sticker, at, dh, shadow: false, rot: 0.02 * drift);
  }
}

/// A kaleidoscope: the photograph mirrored into wedges, turning with the bar.
class KaleidoBit extends MemeBit {
  KaleidoBit(super.start, super.bars, super.seed, this.photo);
  final MemePhoto photo;
  @override
  String get kind => 'kaleido';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) => bank.want(photo.file);

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final img = f.bank.image(photo.file);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
    if (img == null) return;
    final n = r(1) < 0.5 ? 6 : 8;
    final centre = Offset(w / 2, h / 2);
    final far = math.sqrt(w * w + h * h);
    final turn = f.t * 0.08 * (r(2) < 0.5 ? 1 : -1) + f.barSaw * 0.15 + f.kick * 0.03;
    final zoom = 1.6 + 0.3 * math.sin(beatsIn(f) * math.pi / 8) + 0.12 * f.kick;
    final focus = Offset(photo.face.dx + 0.08 * math.sin(f.t * 0.3), photo.face.dy + 0.06 * math.cos(f.t * 0.23));
    // Drawn over a square the frame's diagonal wide, so a wedge turned any way is
    // covered.
    final shot = MemeShot(photo, far, far, zoom: zoom, focus: focus, shift: Offset(centre.dx - far / 2, centre.dy - far / 2));
    for (var i = 0; i < n; i++) {
      final a0 = i * 2 * math.pi / n, a1 = a0 + 2 * math.pi / n;
      c.save();
      c.clipPath(Path()
        ..moveTo(centre.dx, centre.dy)
        ..lineTo(centre.dx + math.cos(a0) * far, centre.dy + math.sin(a0) * far)
        ..lineTo(centre.dx + math.cos(a1) * far, centre.dy + math.sin(a1) * far)
        ..close());
      c.translate(centre.dx, centre.dy);
      c.rotate(a0 + turn);
      if (i.isOdd) c.scale(1, -1);
      c.translate(-centre.dx, -centre.dy);
      shot.draw(c, img);
      c.restore();
    }
  }
}

/// Strips: the picture cut into vertical strips, each sliding by its own amount
/// with the bass — a slit-scan, kept tidy; a new picture every two bars.
class StripsBit extends MemeBit {
  StripsBit(super.start, super.bars, super.seed, this.photos);
  final List<MemePhoto> photos;
  @override
  String get kind => 'strips';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
    if (photos.isEmpty) return;
    final photo = photos[(beatsIn(f) / 8).floor() % photos.length];
    final img = f.bank.image(photo.file);
    if (img == null) return;
    final shot = MemeShot(photo, w, h, zoom: 1.25 + 0.08 * f.kick, focus: photo.face);
    final n = 18 + (r(1) * 10).floor();
    final sw = w / n;
    final vertical = r(2) < 0.7;
    for (var i = 0; i < n; i++) {
      final k = i / n;
      final wave = math.sin(beatsIn(f) * math.pi * 0.5 + k * 5.0 + r(3) * 6) * h * (0.02 + 0.05 * f.low) + (i.isEven ? 1 : -1) * h * 0.03 * f.kick;
      c.save();
      if (vertical) {
        c.clipRect(Rect.fromLTWH(i * sw, 0, sw + 1, h));
        c.translate(0, wave);
      } else {
        final sh = h / n;
        c.clipRect(Rect.fromLTWH(0, i * sh, w, sh + 1));
        c.translate(wave, 0);
      }
      shot.draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(1, i.isEven ? 1.0 : 0.92)..filterQuality = FilterQuality.medium);
      c.restore();
    }
  }
}

/// A spotlight: dark, a soft circle of light wandering over the picture and settling
/// on the face; the kick opens it a little.
class SpotlightBit extends MemeBit {
  SpotlightBit(super.start, super.bars, super.seed, this.photos);
  final List<MemePhoto> photos;
  @override
  String get kind => 'spotlight';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
    if (photos.isEmpty) return;
    final photo = photos[(beatsIn(f) / 16).floor() % photos.length];
    final img = f.bank.image(photo.file);
    if (img == null) return;
    final shot = MemeShot(photo, w, h, zoom: 1.12 + 0.03 * math.sin(f.t * 0.4), focus: photo.face);
    shot.draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(0.7, 0.9)..filterQuality = FilterQuality.medium);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black.withValues(alpha: 0.86));
    // The light wanders for two bars, then finds the face.
    final settle = Curves.easeInOut.transform(((beatsIn(f) % 16) / 8).clamp(0.0, 1.0));
    final wander = Offset(w * (0.5 + 0.3 * math.sin(f.t * 0.5 + r(1) * 6)), h * (0.5 + 0.25 * math.cos(f.t * 0.37 + r(2) * 6)));
    final face = shot.map(photo.face);
    final at = Offset.lerp(wander, face, settle)!;
    final radius = h * (0.2 + 0.06 * f.kick + 0.04 * f.low);
    c.saveLayer(null, Paint());
    shot.draw(c, img);
    c.drawRect(Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.radial(at, radius * 1.6, const [Color(0xFFFFFFFF), Color(0xCCFFFFFF), Color(0x00FFFFFF)], const [0.0, 0.5, 1.0]));
    c.restore();
  }
}

/// A film strip running past, sprocket holes and all, at the record's pace: frames
/// of the clip, or of the photographs.
class FilmBit extends MemeBit {
  FilmBit(super.start, super.bars, super.seed, this.photos, this.clip);
  final List<MemePhoto> photos;
  final MemeClip? clip;
  @override
  String get kind => 'film';
  @override
  bool get takeover => true;
  @override
  bool get quiet => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos.take(6)) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF141210));
    final stripH = h * 0.62, frameH = stripH * 0.72, frameW = frameH * 4 / 3, pitch = frameW * 1.1;
    final y0 = (h - stripH) / 2 + h * 0.004 * f.kick * (r(1) < 0.5 ? 1 : -1);
    final speed = (0.35 + 0.5 * f.busy) * pitch;
    final x0 = -(beatsIn(f) * speed) % pitch;
    final first = (beatsIn(f) * speed / pitch).floor();
    c.drawRect(Rect.fromLTWH(0, y0, w, stripH), Paint()..color = const Color(0xFF26231E));
    // The sprocket holes.
    final hole = Paint()..color = const Color(0xFF0E0D0B);
    final holeW = pitch / 4, holeH = stripH * 0.07;
    for (var x = x0 - pitch; x < w + pitch; x += pitch / 2) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + holeW * 0.5, y0 + stripH * 0.035, holeW, holeH), Radius.circular(holeH * 0.3)), hole);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + holeW * 0.5, y0 + stripH - stripH * 0.035 - holeH, holeW, holeH), Radius.circular(holeH * 0.3)), hole);
    }
    final fy = y0 + (stripH - frameH) / 2;
    for (var k = -1; k * pitch + x0 < w + pitch; k++) {
      final i = first + k;
      final x = x0 + k * pitch;
      final rect = Rect.fromLTWH(x, fy, frameW, frameH);
      c.drawRect(rect, Paint()..color = Colors.black);
      ui.Image? img;
      MemeShot? shot;
      final cl = clip;
      if (cl != null) {
        final fi = (i * 4) % cl.frames;
        for (var a = 1; a <= 3; a++) {
          f.bank.want(cl.file(((i + a) * 4) % cl.frames));
        }
        img = f.bank.image(cl.file(fi));
        if (img != null) shot = MemeShot.clip(cl, frameW, frameH, zoom: 1.3, focus: cl.at(fi));
      } else if (photos.isNotEmpty) {
        final p = photos[i % photos.length];
        f.bank.want(photos[(i + 1) % photos.length].file);
        img = f.bank.image(p.file);
        if (img != null) shot = MemeShot(p, frameW, frameH, zoom: 1.05, focus: p.face);
      }
      if (img != null && shot != null) {
        c.save();
        c.clipRect(rect);
        c.translate(rect.left, rect.top);
        shot.draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(0.9, 1.05)..filterQuality = FilterQuality.medium);
        c.restore();
      }
    }
    // The gate's glow and the room's dark round it.
    c.drawRect(Rect.fromLTWH(0, 0, w, h),
        Paint()..shader = ui.Gradient.radial(Offset(w / 2, h / 2), w * 0.6, [Colors.transparent, Colors.black.withValues(alpha: 0.55)]));
  }
}

/// Rings: the same face rippling out from the middle, a ring a beat, hypnotic.
class RingsBit extends MemeBit {
  RingsBit(super.start, super.bars, super.seed, this.sticker);
  final MemeSticker sticker;
  @override
  String get kind => 'rings';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) => bank.want(sticker.file);

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final hue = (f.hue * 360) % 360;
    c.drawRect(Rect.fromLTWH(0, 0, w, h),
        Paint()..shader = ui.Gradient.radial(Offset(w / 2, h / 2), w * 0.7, [HSLColor.fromAHSL(1, hue, 0.5, 0.18).toColor(), HSLColor.fromAHSL(1, hue, 0.6, 0.04).toColor()]));
    final img = f.bank.image(sticker.file);
    if (img == null) return;
    final centre = Offset(w / 2, h / 2);
    final b = beatsIn(f);
    // One copy a beat, growing and fading over six beats, turning as it goes.
    for (var k = 6; k >= 0; k--) {
      final born = b.floor() - k;
      if (born < 0) continue;
      final age = b - born;
      final a = math.pow((1 - age / 6.5).clamp(0.0, 1.0), 1.5).toDouble();
      final scale = 0.18 + 1.6 * Curves.easeIn.transform((age / 6.5).clamp(0.0, 1.0));
      c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, a));
      drawSticker(c, img, sticker, centre, h * scale * (1 + 0.06 * f.kick), rot: (born.isEven ? 1 : -1) * age * 0.12, shadow: false);
      c.restore();
    }
  }
}

/// A duotone: the picture in two colours of the palette, the pair turning every
/// two bars, as a poster would be printed.
class DuotoneBit extends MemeBit {
  DuotoneBit(super.start, super.bars, super.seed, this.photos);
  final List<MemePhoto> photos;
  @override
  String get kind => 'duotone';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    if (photos.isEmpty) return;
    final slide = (beatsIn(f) / 8).floor();
    final photo = photos[slide % photos.length];
    final img = f.bank.image(photo.file);
    final hue = (f.hue * 360 + slide * 70) % 360;
    final dark = HSLColor.fromAHSL(1, hue, 0.8, 0.14).toColor(), light = HSLColor.fromAHSL(1, (hue + 50) % 360, 0.9, 0.62).toColor();
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = dark);
    if (img == null) return;
    final into = beatsIn(f) / 8 - slide;
    final shot = MemeShot(photo, w, h, zoom: 1.15 + 0.12 * into + 0.05 * f.kick, focus: photo.face, sx: slide.isOdd ? -1 : 1);
    // The grey picture screened over the dark, then the light multiplied in: the
    // shadows end up the dark colour, the lights the light one.
    c.saveLayer(null, Paint());
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = dark);
    shot.draw(c, img, paint: Paint()..colorFilter = MemeFilters.grey..blendMode = BlendMode.screen..filterQuality = FilterQuality.medium);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = light..blendMode = BlendMode.multiply);
    c.restore();
    // A halftone's dots, faint, so it reads as print: one call, not thousands.
    final step = h * 0.02;
    final pts = <double>[];
    var row = 0;
    for (var y = step / 2; y < h; y += step, row++) {
      for (var x = step / 2 + (row.isOdd ? step / 2 : 0); x < w; x += step) {
        pts
          ..add(x)
          ..add(y);
      }
    }
    c.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(pts),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.12)
          ..strokeWidth = step * 0.28
          ..strokeCap = StrokeCap.round);
  }
}

/// A night sky: stars that glint with the top end, a moon breathing with the bass,
/// a branch, and a dormouse asleep on it, moonlit. Now and then a shooting star on
/// the phrase.
class NightBit extends MemeBit {
  NightBit(super.start, super.bars, super.seed, this.sleeper);
  final MemeSticker sleeper;
  @override
  String get kind => 'night';
  @override
  bool get takeover => true;
  @override
  bool get quiet => true;

  @override
  void warm(MemeBank bank) => bank.want(sleeper.file);

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h),
        Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, h), const [Color(0xFF040817), Color(0xFF0E1638), Color(0xFF1E2350)], const [0.0, 0.6, 1.0]));
    // Stars: the same sky every time for this bit, each glinting at its own pace.
    final star = Paint();
    for (var i = 0; i < 140; i++) {
      final x = memeHash(seed, i, 1) * w, y = memeHash(seed, i, 2) * h * 0.8;
      final size = 0.6 + 1.8 * math.pow(memeHash(seed, i, 3), 3).toDouble();
      final tw = 0.55 + 0.45 * math.sin(f.t * (0.7 + 2 * memeHash(seed, i, 4)) + i);
      final a = (0.25 + 0.6 * tw + 0.35 * f.high * memeHash(seed, i, 5)).clamp(0.0, 1.0);
      star.color = Color.fromRGBO(235, 240, 255, a);
      c.drawCircle(Offset(x, y), size * h / 720, star);
    }
    // A shooting star across the first beat of every fourth bar.
    final into = beatsIn(f) % 16;
    if (into < 1.2) {
      final k = into / 1.2;
      final a = Offset(w * (0.15 + 0.5 * r(((beatsIn(f) / 16).floor()) + 7)), h * 0.12);
      final b = a + Offset(w * 0.35, h * 0.18);
      final head = Offset.lerp(a, b, k)!, tail = Offset.lerp(a, b, math.max(0, k - 0.25))!;
      c.drawLine(
          tail,
          head,
          Paint()
            ..shader = ui.Gradient.linear(tail, head, [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.9 * (1 - k))])
            ..strokeWidth = h * 0.004
            ..strokeCap = StrokeCap.round);
    }
    // The moon, breathing with the bass.
    final moon = Offset(w * 0.8, h * 0.24), mr = h * (0.085 + 0.006 * f.low);
    c.drawCircle(moon, mr * 3.2, Paint()..shader = ui.Gradient.radial(moon, mr * 3.2, [const Color(0x44FFF2C8), const Color(0x00FFF2C8)]));
    c.drawCircle(moon, mr, Paint()..color = const Color(0xFFF6EED2));
    c.drawCircle(moon + Offset(mr * 0.3, -mr * 0.2), mr * 0.22, Paint()..color = const Color(0x22000000));
    c.drawCircle(moon + Offset(-mr * 0.35, mr * 0.25), mr * 0.15, Paint()..color = const Color(0x1A000000));
    // The branch.
    final branch = Paint()
      ..color = const Color(0xFF05060C)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final sway = math.sin(f.t * 0.4) * h * 0.006;
    final path = Path()
      ..moveTo(-w * 0.05, h * 0.86)
      ..quadraticBezierTo(w * 0.3, h * 0.7 + sway, w * 0.72, h * 0.74 + sway * 1.5);
    c.drawPath(path, branch..strokeWidth = h * 0.035);
    for (final (x0, y0, x1, y1) in [(0.2, 0.79, 0.26, 0.66), (0.45, 0.73, 0.55, 0.62), (0.6, 0.735, 0.68, 0.84)]) {
      c.drawLine(Offset(w * x0, h * y0 + sway), Offset(w * x1, h * y1 + sway * 1.3), branch..strokeWidth = h * 0.012);
    }
    // The sleeper on it, breathing over two bars, moonlit.
    final img = f.bank.image(sleeper.file);
    if (img == null) return;
    final breath = math.sin(2 * math.pi * beatsIn(f) / 8);
    final dh = h * 0.38;
    c.saveLayer(null, Paint());
    drawSticker(c, img, sleeper, Offset(w * 0.42, h * 0.72 - dh / 2 + sway), dh, sx: 1 + 0.01 * breath, sy: 1 + 0.025 * breath, shadow: false);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()
      ..color = const Color(0xFFB4C4F2)
      ..blendMode = BlendMode.modulate);
    c.restore();
  }
}

/// A nature documentary: a slow pan across a photograph, letterboxed wide, the
/// species card in the corner and a line of the narration under it.
class DocumentaryBit extends MemeBit {
  DocumentaryBit(super.start, super.bars, super.seed, this.photos, this.line);
  final List<MemePhoto> photos;
  final String line;
  @override
  String get kind => 'documentary';
  @override
  bool get takeover => true;
  @override
  bool get quiet => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
    if (photos.isEmpty) return;
    final per = (bars * 4) / photos.length;
    final i = (beatsIn(f) / per).floor().clamp(0, photos.length - 1);
    final into = (beatsIn(f) - i * per) / per;
    void shot(int k, double t, double alpha) {
      final p = photos[k];
      final img = f.bank.image(p.file);
      if (img == null) return;
      // From the far side of the picture to the face, slowly.
      final from = Offset(p.face.dx < 0.5 ? 0.75 : 0.25, 0.5);
      final focus = Offset.lerp(from, p.face, Curves.easeInOut.transform(t))!;
      if (alpha < 1) c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, alpha));
      MemeShot(p, w, h, zoom: 1.25 + 0.2 * t, focus: focus).draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(0.92, 1.04)..filterQuality = FilterQuality.medium);
      if (alpha < 1) c.restore();
    }

    if (i > 0 && into < 0.12) shot(i - 1, 1, 1);
    shot(i, into, i > 0 && into < 0.12 ? into / 0.12 : 1);
    // Cinema's bars.
    final bar = (h - w / 2.39) / 2;
    if (bar > 0) {
      c.drawRect(Rect.fromLTWH(0, 0, w, bar), Paint()..color = Colors.black);
      c.drawRect(Rect.fromLTWH(0, h - bar, w, bar), Paint()..color = Colors.black);
    }
  }

  @override
  void paintOver(Canvas c, Size size, MemeFrame f) {
    final w = size.width, h = size.height;
    final b = beatsIn(f);
    final k = ((b - 2) / 3).clamp(0.0, 1.0);
    final out = ((bars * 4 - b) / 2).clamp(0.0, 1.0);
    final a = math.min(k, out);
    if (a <= 0) return;
    final s = (h * 0.046).roundToDouble();
    final x = w * 0.07, y = h * 0.68;
    c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, a));
    c.drawRect(Rect.fromLTWH(x, y, w * 0.004, s * 2.5), Paint()..color = Colors.white);
    f.type.text('doc1|$s', () => TextSpan(text: 'Glis glis', style: Mag.quote(s, color: Colors.white).copyWith(fontStyle: FontStyle.italic)), align: TextAlign.left)
        .paint(c, Offset(x + w * 0.015, y - s * 0.1));
    f.type.text('doc2|$s', () => TextSpan(text: 'SIEBENSCHLÄFER  ·  FAMILIE BILCHE', style: Mag.flag(s * 0.42, color: const Color(0xCCFFFFFF))), align: TextAlign.left)
        .paint(c, Offset(x + w * 0.015, y + s * 1.45));
    c.restore();
    if (line.isEmpty) return;
    final lk = ((b - 8) / 2).clamp(0.0, 1.0) * out;
    if (lk <= 0) return;
    final p = f.type.text('doc3|$line|$s', () => TextSpan(text: line, style: Mag.quote(s * 0.62, color: Colors.white)), maxWidth: w * 0.7);
    c.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, lk));
    p.paint(c, Offset((w - p.width) / 2, h * 0.86));
    c.restore();
  }
}

/// A magnifier gliding over a dimmed photograph, the picture enlarged inside it; it
/// wanders for a phrase, then finds the eyes. The lens swells a little on the kick.
class LoupeBit extends MemeBit {
  LoupeBit(super.start, super.bars, super.seed, this.photo);
  final MemePhoto photo;
  @override
  String get kind => 'loupe';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) => bank.want(photo.file);

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final img = f.bank.image(photo.file);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
    if (img == null) return;
    final shot = MemeShot(photo, w, h, zoom: 1.1, focus: photo.face);
    shot.draw(c, img, paint: Paint()..colorFilter = MemeFilters.punch(0.5, 0.85)..filterQuality = FilterQuality.medium);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black.withValues(alpha: 0.45));
    final t = beatsIn(f) * f.spb;
    final wander = Offset(w * (0.5 + 0.32 * math.sin(t * 0.55 + r(1) * 6)), h * (0.5 + 0.28 * math.sin(t * 0.83 + r(2) * 6)));
    final settle = Curves.easeInOut.transform(((beatsIn(f) - 16) / 6).clamp(0.0, 1.0));
    final at = Offset.lerp(wander, shot.map(photo.eyesMiddle), settle)!;
    final rad = h * (0.22 + 0.015 * f.kick);
    const mag = 2.4;
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: at, radius: rad)));
    c.translate(at.dx, at.dy);
    c.scale(mag);
    c.translate(-at.dx, -at.dy);
    shot.draw(c, img);
    c.restore();
    // The glass: a sheen and a rim; the handle.
    c.drawCircle(at, rad, Paint()..shader = ui.Gradient.radial(at + Offset(-rad * 0.35, -rad * 0.4), rad * 1.2, [Colors.white.withValues(alpha: 0.18), Colors.white.withValues(alpha: 0)]));
    final handle = at + Offset(rad * 0.72, rad * 0.72);
    c.drawLine(handle, handle + Offset(rad * 0.75, rad * 0.75), Paint()
      ..color = const Color(0xFF2A1F18)
      ..strokeWidth = rad * 0.16
      ..strokeCap = StrokeCap.round);
    c.drawCircle(at, rad, Paint()
      ..color = const Color(0xFFB8B2A6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = rad * 0.07);
  }
}

/// A photo booth: a paper strip of four frames, one taken on each beat of the first
/// bar with a flash, then the next strip slides in.
class BoothBit extends MemeBit {
  BoothBit(super.start, super.bars, super.seed, this.photos);
  final List<MemePhoto> photos;
  @override
  String get kind => 'booth';
  @override
  bool get takeover => true;
  @override
  bool get quiet => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos.take(4)) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    final hue = (f.hue * 360) % 360;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = HSLColor.fromAHSL(1, hue, 0.35, 0.22).toColor());
    // A curtain's folds behind.
    final fold = Paint()..color = Colors.black.withValues(alpha: 0.12);
    for (var x = 0.0; x < w; x += h * 0.08) {
      c.drawRect(Rect.fromLTWH(x, 0, h * 0.03, h), fold);
    }
    if (photos.isEmpty) return;
    final b = beatsIn(f);
    final strip = (b / 8).floor();
    final into = b - strip * 8;
    final stripH = h * 0.94, frameH = stripH * 0.22, frameW = frameH * 4 / 3, pad = frameH * 0.08;
    final stripW = frameW + 2 * pad;
    final slide = into < 0.5 ? 1 - Curves.easeOut.transform(into / 0.5) : 0.0;
    final cx = w / 2 + slide * w * 0.7, top = (h - stripH) / 2;
    c.save();
    c.translate(cx, h / 2);
    c.rotate(math.sin(f.t * 0.6 + strip) * 0.025 + (strip.isEven ? -0.03 : 0.03));
    c.translate(-cx, -h / 2);
    final paper = Rect.fromLTWH(cx - stripW / 2, top, stripW, stripH);
    c.drawRect(paper.shift(Offset(h * 0.012, h * 0.016)), Paint()..color = Colors.black.withValues(alpha: 0.4));
    c.drawRect(paper, Paint()..color = const Color(0xFFF7F4EC));
    for (var k = 0; k < 4; k++) {
      final rect = Rect.fromLTWH(paper.left + pad, top + pad + k * (frameH + pad), frameW, frameH);
      c.drawRect(rect, Paint()..color = const Color(0xFF222222));
      final taken = into - k;
      if (taken < 0) continue;
      final p = photos[(strip * 4 + k) % photos.length];
      f.bank.want(photos[(strip * 4 + k + 4) % photos.length].file);
      final img = f.bank.image(p.file);
      if (img == null) continue;
      c.save();
      c.clipRect(rect);
      c.translate(rect.left, rect.top);
      MemeShot(p, frameW, frameH, zoom: 1.3, focus: p.face, sx: k.isOdd ? -1 : 1).draw(c, img, paint: Paint()..colorFilter = (strip.isOdd ? MemeFilters.grey : MemeFilters.punch(1.05, 1.05))..filterQuality = FilterQuality.medium);
      c.restore();
      // The flash as the frame is taken.
      if (taken < 0.4) c.drawRect(rect, Paint()..color = Colors.white.withValues(alpha: 1 - taken / 0.4));
    }
    c.restore();
  }
}

/// Cards on a wall flipping over in a wave, a new photograph on the back of each,
/// one wave a beat.
class FlipBit extends MemeBit {
  FlipBit(super.start, super.bars, super.seed, this.photos);
  final List<MemePhoto> photos;
  @override
  String get kind => 'flip';
  @override
  bool get takeover => true;

  @override
  void warm(MemeBank bank) {
    for (final p in photos) {
      bank.want(p.file);
    }
  }

  @override
  void draw(Canvas c, MemeFrame f) {
    final w = f.w, h = f.h;
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF0B0B0E));
    if (photos.isEmpty) return;
    const cols = 4, rows = 3;
    final gap = h * 0.02;
    final cw = (w - gap * (cols + 1)) / cols, ch = (h - gap * (rows + 1)) / rows;
    final b = beatsIn(f);
    // Waves every two beats in a calm passage, every beat in a drop.
    final every = f.mood == MemeMood.rage ? 1.0 : 2.0;
    final diag = r(1) < 0.5;
    for (var i = 0; i < cols; i++) {
      for (var j = 0; j < rows; j++) {
        final delay = (diag ? (i + j) : (cols - 1 - i + j)) * 0.08;
        final t = (b - delay) / every;
        final n = t.floor();
        final k = ((t - n) / 0.35).clamp(0.0, 1.0); // the flip takes a third of the wave
        final side = k < 0.5 ? n - 1 : n;
        final p = photos[((side * 7 + i * 3 + j * 5) % photos.length + photos.length) % photos.length];
        final img = f.bank.image(p.file);
        final sx = math.cos(k * math.pi).abs();
        final rect = Rect.fromLTWH(gap + i * (cw + gap), gap + j * (ch + gap), cw, ch);
        c.save();
        c.translate(rect.center.dx, rect.center.dy);
        c.scale(math.max(sx, 0.02), 1 + 0.04 * (1 - sx));
        c.translate(-cw / 2, -ch / 2);
        c.clipRect(Rect.fromLTWH(0, 0, cw, ch));
        if (img != null) MemeShot(p, cw, ch, zoom: 1.15, focus: p.face).draw(c, img);
        // The card darkens as it turns away.
        if (sx < 1) c.drawRect(Rect.fromLTWH(0, 0, cw, ch), Paint()..color = Colors.black.withValues(alpha: 0.6 * (1 - sx)));
        c.restore();
      }
    }
  }
}
