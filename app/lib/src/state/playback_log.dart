import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A short written record of what the audio engine did, kept across restarts.
///
/// "It stops after a while when I am not looking at it" is not a bug report anybody
/// can act on, and it is not one anybody can watch happen either — the interesting
/// minute is always the one where the screen is off and the debugger is not attached.
/// So the app writes down what happened instead.
///
/// Kept on disk, which is the point: if the log picks up again with "app started" and
/// no goodbye before it, the process was killed by the system — a different fault with
/// a different fix from an engine that stopped on its own and said so.
class PlaybackLog {
  static const _key = 'muse.playbackLog';
  static const _max = 240;

  static final List<String> _lines = [];
  static Timer? _flush;
  static bool _loaded = false;

  static List<String> get lines => List.unmodifiable(_lines);

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _lines.addAll(prefs.getStringList(_key) ?? const []);
    } catch (_) {
      // A log we cannot read is not worth failing to start over.
    }
  }

  /// One thing that happened. Timestamped here rather than by the reader, because the
  /// gaps between entries are most of what the log is for.
  static void note(String what) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _lines.add('${two(now.hour)}:${two(now.minute)}:${two(now.second)} $what');
    while (_lines.length > _max) {
      _lines.removeAt(0);
    }
    // Batched: a state change can arrive several times a second, and writing the whole
    // list to disk each time would be its own reason for the audio to stutter.
    _flush ??= Timer(const Duration(seconds: 3), () {
      _flush = null;
      unawaited(_save());
    });
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, _lines);
    } catch (_) {
      // Best effort.
    }
  }

  static Future<void> clear() async {
    _lines.clear();
    await _save();
  }

  static String get text => _lines.join('\n');

  /// Whether the things that keep music playing in the background are there.
  ///
  /// Asked at the moment the app leaves the screen, which is the only moment the
  /// answer matters. See Health.kt for why this is a measurement and not another
  /// guess: the system's record of the last few kills says the app was *cached* at the
  /// time, and a process running a foreground service cannot be.
  static Future<void> checkTheService() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final said = await const MethodChannel('muse/health')
          .invokeMethod<String>('describe');
      if (said != null && said.isNotEmpty) note(said);
    } catch (_) {
      // Nothing to say.
    }
  }

  /// What Android says about how the app stopped running last time.
  ///
  /// Three rounds of "the music stops when I leave the app" have been answered with
  /// guesses, because the interesting minute is the one with the screen off. The system
  /// has been keeping the answer the whole time — it records why it kills a process —
  /// and "it was reclaimed for memory" and "it crashed" and "something force-stopped
  /// it" are three faults with three different fixes, only one of which is ours.
  static Future<void> askWhyItDied() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final said = await const MethodChannel('muse/lastexit')
          .invokeMethod<String>('describe');
      if (said != null && said.isNotEmpty) note(said);
    } catch (_) {
      // Older Android, or nothing recorded. Not worth a word.
    }
  }
}
