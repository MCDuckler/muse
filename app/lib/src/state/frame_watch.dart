import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'playback_log.dart';

/// How long the app's frames are taking, in the log, from the machine it is slow on.
///
/// Written because there was no other way to find out. A phone that "starts to lag"
/// cannot be profiled from here — there is no device on this machine and no way to
/// attach to the one in somebody's hand — so the choice was between guessing at which
/// of a dozen painters is the expensive one and asking the app to say. This asks.
///
/// Flutter hands over every frame's build and raster time after the fact
/// ([SchedulerBinding.addTimingsCallback]); that costs nothing to receive. What is
/// kept is the shape of it rather than the frames: how many, how many went long, and
/// the worst — separately for the build, which is Dart, and the raster, which is the
/// GPU doing what the painters asked for. Which of the two is long says which half of
/// the app to look at, and that is the thing that cannot be guessed.
class FrameWatch {
  FrameWatch._();

  /// A frame is late past this. Sixteen and a half milliseconds is sixty a second;
  /// the allowance is for the phones that run at ninety or a hundred and twenty,
  /// where a frame the eye calls smooth is shorter still.
  static const _long = Duration(milliseconds: 17);

  static int _frames = 0, _lateBuild = 0, _lateRaster = 0;
  static int _worstBuild = 0, _worstRaster = 0, _totalBuild = 0, _totalRaster = 0;
  static Timer? _saying;
  static bool _on = false;

  /// Where the app is, so a slow stretch can be blamed on the screen that was open.
  static String where = 'app';

  static void watch() {
    if (_on) return;
    _on = true;
    SchedulerBinding.instance.addTimingsCallback(_took);
  }

  static void _took(List<FrameTiming> frames) {
    for (final f in frames) {
      final build = f.buildDuration.inMicroseconds;
      final raster = f.rasterDuration.inMicroseconds;
      _frames++;
      _totalBuild += build;
      _totalRaster += raster;
      if (build > _worstBuild) _worstBuild = build;
      if (raster > _worstRaster) _worstRaster = raster;
      if (f.buildDuration > _long) _lateBuild++;
      if (f.rasterDuration > _long) _lateRaster++;
    }
    // Said every half minute, and only when something was late: a log line a minute
    // saying everything is fine is a log nobody reads.
    _saying ??= Timer(const Duration(seconds: 30), _say);
  }

  static void _say() {
    _saying = null;
    final n = _frames;
    if (n == 0) return;
    final late_ = _lateBuild + _lateRaster;
    final smooth = late_ * 100 / n < 1.0;
    if (!smooth) {
      String ms(int us) => (us / 1000).toStringAsFixed(1);
      PlaybackLog.note('FRAMES $where — $n frames, '
          '${_lateBuild * 100 ~/ n}% slow to build, ${_lateRaster * 100 ~/ n}% slow to draw; '
          'build ${ms(_totalBuild ~/ n)} ms typical, ${ms(_worstBuild)} worst; '
          'draw ${ms(_totalRaster ~/ n)} ms typical, ${ms(_worstRaster)} worst');
    }
    _frames = _lateBuild = _lateRaster = 0;
    _worstBuild = _worstRaster = _totalBuild = _totalRaster = 0;
  }

  /// What the numbers say right now, for a screen that wants to show them.
  @visibleForTesting
  static ({int frames, int lateBuild, int lateRaster}) get seen =>
      (frames: _frames, lateBuild: _lateBuild, lateRaster: _lateRaster);

  @visibleForTesting
  static void forget() {
    _saying?.cancel();
    _saying = null;
    _frames = _lateBuild = _lateRaster = 0;
    _worstBuild = _worstRaster = _totalBuild = _totalRaster = 0;
  }
}
