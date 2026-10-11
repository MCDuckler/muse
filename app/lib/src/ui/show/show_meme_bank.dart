// What the meme edit draws from (show_meme.dart): the bank of photographs, cut-outs,
// a clip and captions in assets/show/<bank>/bank.json, the looks a record can be
// edited in, and the placer that sits a photograph on the frame.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum MemeMood { sleep, wake, rage, vibe }

/// The look a record is edited in — one per record, so a set is not one edit
/// eighty minutes long. Each style is a grade on the finish, a palette for the
/// captions and a lean towards some of the gags.
enum MemeStyle {
  /// Deep-fried: orange, sharpened, posterised, the laser eyes.
  fried,

  /// The phonk edit: black and white, hard, red type, VHS tracking.
  phonk,

  /// Vaporwave: pastel pink and cyan, scan lines, sunbursts.
  vapor,

  /// A clean modern TikTok: the photographs as they are, white type, emoji.
  clean,

  /// 2009: pixelated, pillarboxed to 4:3, error boxes, a bouncing logo.
  y2k,
}

/// The grade and the type of a [MemeStyle].
class MemeLook {
  const MemeLook({
    required this.style,
    required this.fry,
    this.mono = 0,
    this.pastel = 0,
    this.scan = 0,
    this.pixel = 0,
    required this.hi,
    required this.hi2,
    this.ink = Colors.white,
    this.outline = Colors.black,
    this.width = 100,
    this.pillarbox = false,
    this.emoji = 1,
  });
  final MemeStyle style;

  /// A multiplier on the fry the mood asks for.
  final double fry, mono, pastel, scan, pixel, emoji;
  final Color hi, hi2, ink, outline;
  final double width;
  final bool pillarbox;

  static const all = {
    MemeStyle.fried: MemeLook(style: MemeStyle.fried, fry: 0.8, hi: Color(0xFFFFE21A), hi2: Color(0xFF3DFF5A)),
    MemeStyle.phonk: MemeLook(style: MemeStyle.phonk, fry: 0.2, mono: 0.9, scan: 0.5, hi: Color(0xFFFF1E1E), hi2: Color(0xFFFF1E1E), ink: Colors.white, width: 62, emoji: 0.4),
    MemeStyle.vapor: MemeLook(style: MemeStyle.vapor, fry: 0.1, pastel: 0.85, scan: 0.35, hi: Color(0xFFFF71CE), hi2: Color(0xFF01CDFE), ink: Color(0xFFFFFBF0), outline: Color(0xFF2A0A4A), width: 125, emoji: 0.6),
    MemeStyle.clean: MemeLook(style: MemeStyle.clean, fry: 0.15, hi: Color(0xFFFFE21A), hi2: Color(0xFF3DFF5A), emoji: 1.2),
    MemeStyle.y2k: MemeLook(style: MemeStyle.y2k, fry: 0.4, pixel: 2.2, hi: Color(0xFF9BFF2E), hi2: Color(0xFF2EE6FF), pillarbox: true, width: 90, emoji: 0.7),
  };

  static MemeLook of(MemeStyle s) => all[s]!;
}

/// A number 0..1 from a few others, the same every time: the edit's dice.
double memeHash(num a, num b, [num c = 0]) {
  final x = math.sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43758.5453;
  return x - x.floorToDouble();
}

class MemePhoto {
  const MemePhoto({required this.id, required this.file, required this.set, required this.w, required this.h, required this.face, required this.faceR, this.eyes = const []});
  final String id, file;

  /// `sleep`, `wake` (peeking out of something), `stare`, `chaos`; `old` (an
  /// engraving), `roman` (a glirarium), `devil`, `hunt` for the history lesson.
  final String set;
  final int w, h;

  /// The face's middle (0..1 of the picture) and its radius as a share of the
  /// picture's height; the eyes, where they show.
  final Offset face;
  final double faceR;
  final List<Offset> eyes;

  Offset get eyesMiddle {
    if (eyes.isEmpty) return face;
    var x = 0.0, y = 0.0;
    for (final e in eyes) {
      x += e.dx;
      y += e.dy;
    }
    return Offset(x / eyes.length, y / eyes.length);
  }

  factory MemePhoto.fromJson(Map<String, dynamic> j) {
    final f = (j['face'] as List).map((v) => (v as num).toDouble()).toList();
    return MemePhoto(
      id: '${j['id']}',
      file: '${j['file']}',
      set: '${j['set']}',
      w: (j['w'] as num).toInt(),
      h: (j['h'] as num).toInt(),
      face: Offset(f[0], f[1]),
      faceR: f[2],
      eyes: [
        for (final e in (j['eyes'] as List? ?? const []))
          Offset(((e as List)[0] as num).toDouble(), (e[1] as num).toDouble()),
      ],
    );
  }
}

class MemeSticker {
  const MemeSticker({required this.id, required this.file, required this.set, required this.w, required this.h, this.peek = false});
  final String id, file, set;
  final int w, h;

  /// Upright and facing out: one that can rise from the bottom edge, head first.
  final bool peek;

  factory MemeSticker.fromJson(Map<String, dynamic> j) => MemeSticker(
      id: '${j['id']}', file: '${j['file']}', set: '${j['set']}', w: (j['w'] as num).toInt(), h: (j['h'] as num).toInt(), peek: j['peek'] == true);
}

/// A few seconds of real footage as numbered frames, with where the animal is in
/// each (0..1), so the edit can zoom on it.
class MemeClip {
  const MemeClip({required this.id, required this.dir, required this.frames, required this.fps, required this.w, required this.h, required this.track});
  final String id, dir;
  final int frames, fps, w, h;
  final List<Offset> track;

  String file(int i) => '$dir${(i % frames).toString().padLeft(3, '0')}.webp';
  Offset at(int i) => track.isEmpty ? const Offset(0.5, 0.5) : track[(i % frames).clamp(0, track.length - 1)];

  factory MemeClip.fromJson(Map<String, dynamic> j) => MemeClip(
        id: '${j['id']}',
        dir: '${j['dir']}',
        frames: (j['frames'] as num).toInt(),
        fps: (j['fps'] as num?)?.toInt() ?? 12,
        w: (j['w'] as num).toInt(),
        h: (j['h'] as num).toInt(),
        track: [for (final p in (j['track'] as List? ?? const [])) Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())],
      );
}

/// A bank of pictures and words, read once per process and shared by every edit
/// drawn from it. The pictures are decoded as they are wanted and the least lately
/// used let go past [keep], so a bank of fifty photographs is not fifty textures.
class MemeBank {
  MemeBank._(this.name);
  final String name;
  static final _banks = <String, MemeBank>{};

  static MemeBank of(String name) => _banks.putIfAbsent(name, () {
        final bank = MemeBank._(name);
        bank.loaded = bank._load();
        return bank;
      });

  /// Done when the bank's file has been read.
  Future<void> loaded = Future.value();

  /// Every picture decoded now, for a test, which cannot wait a frame for one.
  @visibleForTesting
  Future<void> decodeAll() async {
    await loaded;
    await Future.wait([for (final p in photos) _fetch(p.file), for (final s in stickers) _fetch(s.file)]);
  }

  /// A bank from what a test hands it, with no pictures to decode.
  @visibleForTesting
  factory MemeBank.forTest(List<MemePhoto> photos, {List<MemeSticker> stickers = const [], Map<String, List<String>> captions = const {}, List<MemeClip> clips = const []}) =>
      MemeBank._('test')
        ..photos = photos
        ..stickers = stickers
        ..captions = captions
        ..clips = clips
        .._index();

  String get dir => 'assets/show/$name/';

  bool ready = false;
  List<MemePhoto> photos = const [];
  List<MemeSticker> stickers = const [];
  List<MemeClip> clips = const [];
  Map<String, List<String>> captions = const {};
  String handle = '';

  /// The photographs a mood draws from.
  final pools = <MemeMood, List<MemePhoto>>{};

  /// The photographs of a set.
  List<MemePhoto> set(String name) => [for (final p in photos) if (p.set == name) p];
  List<MemePhoto> sets(Set<String> names) => [for (final p in photos) if (names.contains(p.set)) p];

  /// The lines of a caption pool; empty where the bank has none.
  List<String> lines(String pool) => captions[pool] ?? const [];

  /// One line of [pool], picked by the dice.
  String? line(String pool, num a, num b) {
    final l = lines(pool);
    if (l.isEmpty) return null;
    return l[(memeHash(a, b, pool.hashCode % 1000) * l.length).floor() % l.length];
  }

  static const keep = 56;
  final _images = <String, ui.Image>{};
  final _loading = <String>{};
  final _used = <String, int>{};

  /// Kept for good: the cut-outs, which are small and wanted all at once.
  final _pinned = <String>{};
  int _frame = 0;

  Future<void> _load() async {
    try {
      final j = jsonDecode(await rootBundle.loadString('${dir}bank.json')) as Map<String, dynamic>;
      photos = [for (final p in (j['photos'] as List? ?? const [])) MemePhoto.fromJson((p as Map).cast())];
      stickers = [for (final s in (j['stickers'] as List? ?? const [])) MemeSticker.fromJson((s as Map).cast())];
      clips = [for (final c in (j['clips'] as List? ?? const [])) MemeClip.fromJson((c as Map).cast())];
      captions = {
        for (final e in ((j['captions'] as Map?) ?? const {}).entries) '${e.key}': [for (final s in (e.value as List)) '$s'],
      };
      handle = '${j['handle'] ?? ''}';
      _index();
      // The sleepers first: a scene that comes on in a breakdown has them ready. The
      // cut-outs are small and all of them come at once in a drop: decoded now, one
      // after another, so the drop does not wait on eighteen at once.
      for (final p in pools[MemeMood.sleep]!.take(3)) {
        want(p.file);
      }
      for (final s in stickers) {
        _pinned.add(s.file);
        await _fetch(s.file);
      }
    } catch (e) {
      // ignore: avoid_print
      print('meme bank $name: $e');
    }
  }

  void _index() {
    pools[MemeMood.sleep] = set('sleep');
    pools[MemeMood.wake] = sets({'wake', 'stare'});
    pools[MemeMood.rage] = sets({'stare', 'chaos', 'wake'});
    pools[MemeMood.vibe] = sets({'stare', 'chaos', 'wake'});
    for (final mood in MemeMood.values) {
      if (pools[mood]!.isEmpty) pools[mood] = photos;
    }
    ready = photos.isNotEmpty;
  }

  /// The picture of [file], or null while it is being decoded (which this starts).
  ui.Image? image(String file) {
    _used[file] = _frame;
    final img = _images[file];
    if (img == null) _fetch(file);
    return img;
  }

  /// Wanted soon: decoded ahead and kept.
  void want(String file) {
    _used[file] = _frame;
    if (!_images.containsKey(file)) _fetch(file);
  }

  Future<void> _fetch(String file) async {
    if (!_loading.add(file)) return;
    try {
      final data = await rootBundle.load('$dir$file');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      final fr = await codec.getNextFrame();
      codec.dispose();
      _images[file]?.dispose();
      _images[file] = fr.image;
    } catch (e) {
      // ignore: avoid_print
      print('meme bank $name $file: $e');
    } finally {
      _loading.remove(file);
    }
  }

  /// A frame drawn: the oldest pictures not used in the last few frames let go.
  void tick() {
    _frame++;
    if (_images.length <= keep) return;
    final old = _images.keys.where((k) => !_pinned.contains(k) && (_used[k] ?? 0) < _frame - 3).toList()
      ..sort((a, b) => (_used[a] ?? 0).compareTo(_used[b] ?? 0));
    for (final k in old.take(_images.length - keep)) {
      _images.remove(k)?.dispose();
    }
  }
}

/// A photograph placed on a [w]×[h] frame: cover-fit, zoomed on a point, turned,
/// flipped, squashed and shaken, and kept covering the frame as it moves (a spin
/// aside).
class MemeShot {
  MemeShot(MemePhoto photo, this.w, this.h, {required double zoom, required Offset focus, this.rot = 0, double coverRot = 0, this.sx = 1, this.sy = 1, this.shift = Offset.zero})
      : photo = photo,
        pw = photo.w.toDouble(),
        ph = photo.h.toDouble() {
    _place(zoom, focus, coverRot);
  }

  /// The same for a clip's frame.
  MemeShot.clip(MemeClip clip, this.w, this.h, {required double zoom, required Offset focus, this.rot = 0, this.sx = 1, this.sy = 1, this.shift = Offset.zero})
      : photo = null,
        pw = clip.w.toDouble(),
        ph = clip.h.toDouble() {
    _place(zoom, focus, rot);
  }

  void _place(double zoom, Offset focus, double coverRot) {
    final c = math.cos(coverRot).abs(), s = math.sin(coverRot).abs();
    final bw = w * c + h * s, bh = w * s + h * c;
    final squash = math.max(sx.abs() < 1 ? 1 / sx.abs() : 1.0, sy.abs() < 1 ? 1 / sy.abs() : 1.0);
    final cover = math.max(bw / pw, bh / ph) * squash;
    scale = cover * zoom;
    final hx = (bw / 2) / (pw * scale), hy = (bh / 2) / (ph * scale);
    fx = hx >= 0.5 ? 0.5 : focus.dx.clamp(hx, 1 - hx);
    fy = hy >= 0.5 ? 0.5 : focus.dy.clamp(hy, 1 - hy);
  }

  final MemePhoto? photo;
  final double pw, ph;
  final double w, h, rot, sx, sy;
  final Offset shift;
  late final double scale, fx, fy;

  /// A point of the picture (0..1) on the frame.
  Offset map(Offset uv) {
    final x = (uv.dx - fx) * pw * scale * sx, y = (uv.dy - fy) * ph * scale * sy;
    final cs = math.cos(rot), sn = math.sin(rot);
    return Offset(w / 2 + shift.dx + x * cs - y * sn, h / 2 + shift.dy + x * sn + y * cs);
  }

  /// The face's radius on the frame, in pixels.
  double get faceRadius => (photo?.faceR ?? 0.2) * ph * scale;

  void draw(Canvas c, ui.Image img, {Paint? paint}) {
    c.save();
    c.translate(w / 2 + shift.dx, h / 2 + shift.dy);
    c.rotate(rot);
    c.scale(sx, sy);
    final dw = pw * scale, dh = ph * scale;
    c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), Rect.fromLTWH(-fx * dw, -fy * dh, dw, dh),
        paint ?? (Paint()..filterQuality = FilterQuality.medium));
    c.restore();
  }
}

/// A cut-out drawn with its drop shadow, centred, [dh] tall.
void drawSticker(Canvas c, ui.Image img, MemeSticker st, Offset centre, double dh, {double rot = 0, double sx = 1, double sy = 1, bool shadow = true}) {
  final dw = dh * st.w / st.h;
  c.save();
  c.translate(centre.dx, centre.dy);
  c.rotate(rot);
  c.scale(sx, sy);
  final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
  final dst = Rect.fromCenter(center: Offset.zero, width: dw, height: dh);
  if (shadow) {
    c.drawImageRect(img, src, dst.shift(Offset(dh * 0.03, dh * 0.04)), Paint()..colorFilter = const ColorFilter.mode(Color(0x77000000), BlendMode.srcIn));
  }
  c.drawImageRect(img, src, dst, Paint()..filterQuality = FilterQuality.medium);
  c.restore();
}
