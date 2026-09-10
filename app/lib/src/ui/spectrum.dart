import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The shape of the sound, as a row of bars under the artwork.
///
/// Wide and short on purpose: this is the bottom edge of the record, not an instrument
/// panel. It draws what is actually coming out of the speaker — Android will report
/// that for an app's own audio, which is what makes it a spectrum rather than an
/// animation pretending to be one — and draws nothing at all where it cannot be read,
/// rather than inventing something.
class Spectrum extends StatefulWidget {
  const Spectrum({
    super.key,
    required this.sessionId,
    required this.playing,
    this.colour,
    this.height = 44,
  });

  /// The audio session the engine is playing through. Null on platforms that have no
  /// such thing, which is every platform except Android.
  final int? sessionId;
  final bool playing;
  final Color? colour;
  final double height;

  /// Whether this device can show it at all.
  static bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const _permission = MethodChannel('muse/spectrum/permission');
  static const _bars = EventChannel('muse/spectrum');

  /// Android reads an app's own output through the microphone permission — the same
  /// one a recording app asks for. Asked at the moment somebody switches the bars on,
  /// so the reason for it is on screen when it is asked.
  static Future<bool> hasPermission() async =>
      available && (await _permission.invokeMethod<bool>('has') ?? false);

  static Future<bool> askForPermission() async =>
      available && (await _permission.invokeMethod<bool>('ask') ?? false);

  @override
  State<Spectrum> createState() => _SpectrumState();
}

class _SpectrumState extends State<Spectrum> with SingleTickerProviderStateMixin {
  StreamSubscription? _feed;
  List<double> _levels = const [];

  /// What is drawn, which follows the levels rather than jumping to them: a bar that
  /// snaps to every reading reads as noise, and one that falls slowly reads as music.
  List<double> _shown = const [];
  Ticker? _ease;

  @override
  void initState() {
    super.initState();
    _ease = createTicker((_) => _settle())..start();
    _listen();
  }

  @override
  void didUpdateWidget(Spectrum old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) _listen();
  }

  Future<void> _listen() async {
    await _feed?.cancel();
    _feed = null;
    final session = widget.sessionId;
    if (!Spectrum.available || session == null) return;
    if (!await Spectrum.hasPermission()) return;
    _feed = Spectrum._bars
        .receiveBroadcastStream({'session': session})
        .listen((data) {
      if (data is List) {
        _levels = [for (final v in data) (v as num).toDouble()];
      }
    }, onError: (_) {
      // No visualiser on this device, or the permission was taken away. Nothing to
      // draw is better than something invented.
      _levels = const [];
    });
  }

  void _settle() {
    if (!mounted) return;
    final target = widget.playing ? _levels : const <double>[];
    if (target.isEmpty && _shown.every((v) => v < 0.01)) return;
    final next = <double>[];
    for (var i = 0; i < (target.isEmpty ? _shown.length : target.length); i++) {
      final want = i < target.length ? target[i] : 0.0;
      final have = i < _shown.length ? _shown[i] : 0.0;
      // Up quickly, down slowly — the way a needle on a meter behaves.
      next.add(want > have ? have + (want - have) * 0.55 : have * 0.88);
    }
    setState(() => _shown = next);
  }

  @override
  void dispose() {
    _ease?.dispose();
    _feed?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) return SizedBox(height: widget.height);
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        child: CustomPaint(
          painter: _Bars(
            levels: _shown,
            colour: widget.colour ?? Theme.of(context).colorScheme.primary,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _Bars extends CustomPainter {
  _Bars({required this.levels, required this.colour});

  final List<double> levels;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final gap = 2.0;
    final width = (size.width - gap * (levels.length - 1)) / levels.length;
    if (width <= 0) return;

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final height = (size.height * level).clamp(1.5, size.height);
      final left = i * (width + gap);
      // Brighter where it is louder, so a quiet passage is a low grey line rather than
      // a row of full-strength stubs.
      final paint = Paint()
        ..color = colour.withValues(alpha: 0.25 + 0.6 * level);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, size.height - height, width, height),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Bars old) => true;
}
