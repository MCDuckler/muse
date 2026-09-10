import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, kIsWeb, TargetPlatform;
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

  /// Let go of the microphone the moment the app is not in front of somebody.
  ///
  /// Android reads an app's own output through the same door a recording app uses, and
  /// a backgrounded app is not allowed through it — so this reads nothing there anyway.
  /// What it does do is hold an open capture on a foreground service declared for media
  /// playback, which on recent Android is a service doing something it did not say it
  /// would, and a plausible reason for one to be shut down mid-song.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () {
      if (_feed == null) unawaited(_listen());
    },
    onInactive: _release,
    onHide: _release,
    onPause: _release,
  );

  void _release() {
    _feed?.cancel();
    _feed = null;
    _levels = const [];
  }
  List<double> _levels = const [];

  /// What is drawn, which follows the levels rather than jumping to them: a bar that
  /// snaps to every reading reads as noise, and one that falls slowly reads as music.
  ///
  /// Held in a notifier rather than in the widget's state, and handed to the painter
  /// as its `repaint`. Sixty times a second is the right rate for bars to move at and
  /// the wrong rate to rebuild a widget at: setState on every tick put this subtree
  /// through build, layout and paint when only the painting had changed.
  final ValueNotifier<_Frame> _frame =
      ValueNotifier(const _Frame(levels: [], peaks: []));

  List<double> get _shown => _frame.value.levels;
  List<double> get _peaks => _frame.value.peaks;

  Ticker? _ease;

  @override
  void initState() {
    super.initState();
    _lifecycle;                     // built lazily; touching it starts it listening
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
    if (target.isEmpty && _shown.every((v) => v < 0.005)) return;
    final length = target.isEmpty ? _shown.length : target.length;
    final next = List<double>.filled(length, 0);
    final peaks = List<double>.filled(length, 0);
    for (var i = 0; i < length; i++) {
      final want = i < target.length ? target[i] : 0.0;
      final have = i < _shown.length ? _shown[i] : 0.0;
      // Up quickly, down slowly — the way a needle on a meter behaves. The reports
      // arrive about twenty times a second and this runs at sixty, so the bars move
      // between them rather than stepping.
      next[i] = want > have ? have + (want - have) * 0.45 : have * 0.90;

      // A mark that falls slower still, so a peak is legible after the bar under it
      // has dropped away.
      final was = i < _peaks.length ? _peaks[i] : 0.0;
      peaks[i] = next[i] > was ? next[i] : was - 0.012;
      if (peaks[i] < 0) peaks[i] = 0;
    }
    // Whether there is anything at all to draw decides whether the box is even in the
    // tree, and that *is* a rebuild — but it happens twice a song rather than sixty
    // times a second.
    final wasEmpty = _shown.isEmpty;
    _frame.value = _Frame(levels: next, peaks: peaks);
    if (wasEmpty != next.isEmpty && mounted) setState(() {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ease?.dispose();
    _feed?.cancel();
    _frame.dispose();
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
            frame: _frame,
            colour: widget.colour ?? Theme.of(context).colorScheme.primary,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// One reading, as the painter needs it.
class _Frame {
  const _Frame({required this.levels, required this.peaks});
  final List<double> levels;
  final List<double> peaks;
}

class _Bars extends CustomPainter {
  _Bars({required this.frame, required this.colour}) : super(repaint: frame);

  /// Listened to rather than copied in: a new reading repaints, and nothing above it
  /// is asked to rebuild.
  final ValueListenable<_Frame> frame;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final levels = frame.value.levels;
    final peaks = frame.value.peaks;
    if (levels.isEmpty) return;
    // Thin bars with a hairline between them: at sixty-four across a phone that is
    // about two pixels each, which is what makes it read as a spectrum rather than as
    // a row of blocks.
    const gap = 1.0;
    final width = (size.width - gap * (levels.length - 1)) / levels.length;
    if (width <= 0) return;

    final bar = Paint()..isAntiAlias = true;
    final mark = Paint()
      ..isAntiAlias = true
      ..color = colour.withValues(alpha: 0.45);

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final left = i * (width + gap);
      final height = (size.height * level).clamp(0.0, size.height);

      if (height > 0.5) {
        // Brighter and warmer towards the top of the bar, so a loud band reads as
        // loud at a glance rather than only as tall.
        bar.shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            colour.withValues(alpha: 0.30 + 0.35 * level),
            colour.withValues(alpha: 0.75 + 0.25 * level),
          ],
        ).createShader(
            Rect.fromLTWH(left, size.height - height, width, height));
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, size.height - height, width, height),
            Radius.circular(width / 2),
          ),
          bar,
        );
      }

      final peak = peaks.length > i ? peaks[i].clamp(0.0, 1.0) : 0.0;
      if (peak > level + 0.04) {
        final y = size.height - size.height * peak;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, y, width, 1.5),
            const Radius.circular(1),
          ),
          mark,
        );
      }
    }
  }

  @override
  // The readings come through `repaint`; this only has to answer for the colour,
  // which changes when the record does.
  bool shouldRepaint(_Bars old) => old.colour != colour || old.frame != frame;
}
