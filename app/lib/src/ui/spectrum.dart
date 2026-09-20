import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The shape of the sound, as a low band of bars sitting on the seek bar.
///
/// Quiet on purpose. It draws what is actually coming out of the speaker — Android
/// reports that for an app's own audio, which is what makes it a spectrum rather than
/// an animation pretending to be one — and draws nothing at all where it cannot be
/// read, rather than inventing something.
///
/// It used to be sixty-four hairline bars at full brightness, snapping about twenty
/// times a second with a peak mark riding on top of each one: a busy little strip that
/// pulled the eye away from the song. The reading is unchanged; what it is drawn like
/// is not. Wider bands, a slower fall, neighbours smoothed into each other and the
/// whole thing faint enough to read as texture on the panel rather than as a second
/// thing happening on the screen.
class Spectrum extends StatefulWidget {
  const Spectrum({
    super.key,
    required this.sessionId,
    required this.playing,
    this.colour,
    this.height = 26,
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

  /// How many bands are drawn, whatever the platform sends.
  ///
  /// Android folds its FFT into sixty-four, which across a phone is about two pixels a
  /// bar — too fine to read as anything but flicker. Neighbouring bands are averaged
  /// down to this many, which is wide enough to see a bass note arrive.
  static const _bands = 24;

  /// The readings, folded to [_bands] and smoothed sideways so one loud bin does not
  /// stand up alone between two quiet ones.
  List<double> _folded() {
    final raw = _levels;
    if (raw.isEmpty) return const [];
    final out = List<double>.filled(_bands, 0);
    for (var i = 0; i < _bands; i++) {
      final from = (i * raw.length) ~/ _bands;
      final to = (((i + 1) * raw.length) ~/ _bands).clamp(from + 1, raw.length);
      var sum = 0.0;
      for (var j = from; j < to; j++) {
        sum += raw[j];
      }
      out[i] = sum / (to - from);
    }
    final smooth = List<double>.filled(_bands, 0);
    for (var i = 0; i < _bands; i++) {
      final left = i == 0 ? out[i] : out[i - 1];
      final right = i == _bands - 1 ? out[i] : out[i + 1];
      smooth[i] = (left + out[i] * 2 + right) / 4;
    }
    return smooth;
  }

  /// What is drawn, which follows the levels rather than jumping to them: a bar that
  /// snaps to every reading reads as noise, and one that falls slowly reads as music.
  ///
  /// Held in a notifier rather than in the widget's state, and handed to the painter
  /// as its `repaint`. Sixty times a second is the right rate for bars to move at and
  /// the wrong rate to rebuild a widget at: setState on every tick put this subtree
  /// through build, layout and paint when only the painting had changed.
  final ValueNotifier<_Frame> _frame = ValueNotifier(const _Frame(levels: []));

  List<double> get _shown => _frame.value.levels;

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
    final target = widget.playing ? _folded() : const <double>[];
    if (target.isEmpty && _shown.every((v) => v < 0.005)) return;
    final length = target.isEmpty ? _shown.length : target.length;
    final next = List<double>.filled(length, 0);
    for (var i = 0; i < length; i++) {
      final want = i < target.length ? target[i] : 0.0;
      final have = i < _shown.length ? _shown[i] : 0.0;
      // Up quickly, down slowly — the way a needle on a meter behaves. Both ends are
      // gentler than they were: a rise that lands in three frames instead of one, and
      // a fall that takes about half a second, which is the difference between music
      // and flicker.
      next[i] = want > have ? have + (want - have) * 0.28 : have * 0.94;
    }
    // Whether there is anything at all to draw decides whether the box is even in the
    // tree, and that *is* a rebuild — but it happens twice a song rather than sixty
    // times a second.
    final wasEmpty = _shown.isEmpty;
    _frame.value = _Frame(levels: next);
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
    return ExcludeSemantics(
      // Deliberately silent rather than unlabelled: it is the shape of the sound
      // sixty times a second, and a screen reader announcing it would be reading out
      // a decoration on top of the song it is decorating.
      child: RepaintBoundary(
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
      ),
    );
  }
}

/// One reading, as the painter needs it.
class _Frame {
  const _Frame({required this.levels});
  final List<double> levels;
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
    if (levels.isEmpty) return;
    // Wide bands with room between them, and each one faintest where it stands on the
    // bar, so the band fades into the panel rather than sitting on top of it.
    const gap = 2.0;
    final width = (size.width - gap * (levels.length - 1)) / levels.length;
    if (width <= 0) return;

    final bar = Paint()..isAntiAlias = true;
    final radius = Radius.circular(width / 2);

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final left = i * (width + gap);
      final height = (size.height * level).clamp(0.0, size.height);
      if (height <= 0.5) continue;

      // Low alpha throughout: loud is still taller and a little clearer, but even a
      // full-height band stays something you can read the time through.
      bar.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          colour.withValues(alpha: 0.05),
          colour.withValues(alpha: 0.16 + 0.16 * level),
        ],
      ).createShader(Rect.fromLTWH(left, size.height - height, width, height));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, size.height - height, width, height),
          radius,
        ),
        bar,
      );
    }
  }

  @override
  // The readings come through `repaint`; this only has to answer for the colour,
  // which changes when the record does.
  bool shouldRepaint(_Bars old) => old.colour != colour || old.frame != frame;
}
