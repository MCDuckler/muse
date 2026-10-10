// The room, as a picture: the webcam, read through ffmpeg, kept as the latest frame
// and what moved in it.
//
// ffmpeg (on the path, as the house's own tools are) opens the camera — v4l2 on
// Linux, avfoundation on a Mac, dshow on Windows — decodes its MJPEG and pipes raw
// RGBA at a small size on its stdout. The pipe is read here into whole frames; only
// the latest is kept (a show wants now, not a backlog), decoded into a ui.Image for
// the shaders, and compared with the frame before for a motion map: where the room
// moved, how much, and where the moving is — which the engine reads as cam.*.
//
// Runs only while something is looking (a camera scene on the stage, or the window
// asked for it); the tile shows a red dot while it does; nothing is written anywhere.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

class CameraFeed extends ChangeNotifier {
  CameraFeed._();

  /// The one feed of this process.
  static final shared = CameraFeed._();

  static const width = 640, height = 360;
  static const _motionW = 160, _motionH = 90;

  /// The device: `/dev/video0`, a Mac's `0`, a dshow name. Null for the platform's first.
  String? device;

  Process? _ffmpeg;
  bool get running => _ffmpeg != null;

  /// Kept on whatever is showing: the window was asked for it (`--camera`, the C key).
  bool pinned = false;
  String? trouble;

  ui.Image? frame, prev, motion;
  int frames = 0;

  /// How much of the picture moved (0..1), where the moving is (0..1 across and down,
  /// mirrored like the picture), and how bright the room is (0..1).
  double motionAmount = 0, motionX = 0.5, motionY = 0.5, light = 0;

  final _buf = BytesBuilder(copy: false);
  Uint8List? _last;
  bool _decoding = false;
  StreamSubscription<List<int>>? _sub;

  static List<String> _args(String? device) {
    if (Platform.isMacOS) {
      return ['-f', 'avfoundation', '-framerate', '30', '-video_size', '1280x720', '-i', device ?? '0'];
    }
    if (Platform.isWindows) {
      return ['-f', 'dshow', '-i', 'video=${device ?? 'Integrated Camera'}'];
    }
    return ['-f', 'v4l2', '-input_format', 'mjpeg', '-video_size', '1280x720', '-framerate', '30', '-i', device ?? '/dev/video0'];
  }

  Future<void> start() async {
    if (_ffmpeg != null) return;
    trouble = null;
    try {
      final p = await Process.start('ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        ..._args(device),
        '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${width}x$height',
        // Mirrored: a room looks at itself the way a mirror shows it.
        '-vf', 'hflip',
        '-',
      ]);
      _ffmpeg = p;
      _buf.clear();
      _sub = p.stdout.listen(_arrived, onDone: _ended);
      p.stderr.transform(const SystemEncoding().decoder).listen((s) {
        if (s.trim().isNotEmpty) trouble = s.trim().split('\n').last;
      });
      unawaited(p.exitCode.then((_) => _ended()));
      notifyListeners();
    } catch (e) {
      trouble = 'ffmpeg: $e';
      _ffmpeg = null;
      notifyListeners();
    }
  }

  void stop() {
    final p = _ffmpeg;
    _ffmpeg = null;
    unawaited(_sub?.cancel());
    _sub = null;
    p?.kill();
    _buf.clear();
    notifyListeners();
  }

  void _ended() {
    if (_ffmpeg == null) return;
    _ffmpeg = null;
    trouble ??= 'the camera stopped';
    notifyListeners();
  }

  static const _frameBytes = width * height * 4;

  void _arrived(List<int> chunk) {
    _buf.add(chunk);
    if (_buf.length < _frameBytes) return;
    final all = _buf.takeBytes();
    // Whole frames only; the newest of them; the remainder kept for the next read.
    final whole = all.length ~/ _frameBytes;
    final start = (whole - 1) * _frameBytes;
    final latest = Uint8List.sublistView(all, start, start + _frameBytes);
    final rest = all.length - whole * _frameBytes;
    if (rest > 0) _buf.add(Uint8List.sublistView(all, whole * _frameBytes));
    if (_decoding) return;             // a frame still on its way: this one is dropped
    _decoding = true;
    _take(Uint8List.fromList(latest));
  }

  void _take(Uint8List rgba) {
    final was = _last;
    _last = rgba;
    _measure(rgba, was);
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, (img) {
      prev?.dispose();
      prev = frame;
      frame = img;
      frames++;
      _decoding = false;
      notifyListeners();
    });
  }

  /// What moved between [now] and [was], on a coarse grid: the motion map (as a
  /// picture), how much, and where.
  void _measure(Uint8List now, Uint8List? was) {
    const sx = width ~/ _motionW, sy = height ~/ _motionH;
    final map = Uint8List(_motionW * _motionH * 4);
    var sum = 0.0, wx = 0.0, wy = 0.0, lightSum = 0.0;
    for (var y = 0; y < _motionH; y++) {
      for (var x = 0; x < _motionW; x++) {
        final i = ((y * sy) * width + x * sx) * 4;
        final lum = (now[i] * 77 + now[i + 1] * 150 + now[i + 2] * 29) >> 8;
        lightSum += lum;
        var d = 0;
        if (was != null) {
          d = (now[i] - was[i]).abs() + (now[i + 1] - was[i + 1]).abs() + (now[i + 2] - was[i + 2]).abs();
          d = d ~/ 3;
          // Under the camera's own noise is nothing.
          d = d < 18 ? 0 : math.min(255, (d - 18) * 2);
        }
        final o = (y * _motionW + x) * 4;
        map[o] = map[o + 1] = map[o + 2] = d;
        map[o + 3] = 255;
        final w = d / 255;
        sum += w;
        wx += w * x;
        wy += w * y;
      }
    }
    const n = _motionW * _motionH;
    light = lightSum / n / 255;
    final amount = sum / n;
    // Eased: a single frame's noise is not a dancer.
    motionAmount += ((amount * 6).clamp(0.0, 1.0) - motionAmount) * 0.3;
    if (sum > 2) {
      motionX += (wx / sum / _motionW - motionX) * 0.3;
      motionY += (wy / sum / _motionH - motionY) * 0.3;
    }
    ui.decodeImageFromPixels(map, _motionW, _motionH, ui.PixelFormat.rgba8888, (img) {
      motion?.dispose();
      motion = img;
    });
  }

  /// The numbers for the engine, by name.
  Map<String, double> get numbers => {
        'cam.on': running && frame != null ? 1 : 0,
        'cam.motion': motionAmount,
        'cam.x': motionX,
        'cam.y': motionY,
        'cam.light': light,
      };

  @override
  void dispose() {
    stop();
    frame?.dispose();
    prev?.dispose();
    motion?.dispose();
    super.dispose();
  }
}
