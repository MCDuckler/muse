// The screens a stage window can fill: listed for the Desk (its SCREEN chips), and
// the window full screen on one of them — the projector, say.
//
// On Linux the window asks GTK for full screen on that monitor (the runner's
// wetowl/stage_window channel): Wayland lets no program place its own window, but it
// may ask for an output. On a Mac and Windows it is moved there, then made full screen.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

typedef StageScreen = ({String name, int width, int height});

class StageScreens {
  static const _linux = MethodChannel('wetowl/stage_window');

  static List<Display> _displays = const [];

  /// The screens now, in the system's order (GTK's monitors on Linux).
  static Future<List<StageScreen>> list() async {
    try {
      _displays = await screenRetriever.getAllDisplays();
    } catch (e) {
      debugPrint('stage screens: $e');
    }
    final names = <String, int>{};
    return [
      for (final (i, d) in _displays.indexed)
        (
          // a name twice (two of the same projector) gets its place after it
          name: () {
            final n = (d.name ?? '').trim().isEmpty ? 'Screen ${i + 1}' : d.name!.trim();
            final seen = names[n] = (names[n] ?? 0) + 1;
            return seen > 1 ? '$n ($seen)' : n;
          }(),
          width: d.size.width.round(),
          height: d.size.height.round(),
        ),
    ];
  }

  /// The window full screen on screen [i] of the last [list]; false where it cannot be.
  static Future<bool> fillScreen(int i) async {
    if (i < 0 || i >= _displays.length) return false;
    try {
      if (Platform.isLinux) {
        return await _linux.invokeMethod<bool>('fullscreenOn', {'monitor': i}) ?? false;
      }
      final d = _displays[i];
      final at = d.visiblePosition ?? Offset.zero;
      final size = d.visibleSize ?? d.size;
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
        // the system's animation out of full screen, before the move
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      await windowManager.setBounds(Rect.fromLTWH(at.dx, at.dy, size.width * 0.8, size.height * 0.8));
      await windowManager.setFullScreen(true);
      return true;
    } catch (e) {
      debugPrint('stage screens: $e');
      return false;
    }
  }

  /// Full screen where the window is, or back to a window.
  static Future<void> setFull(bool on) async {
    try {
      await windowManager.setFullScreen(on);
    } catch (e) {
      debugPrint('stage screens: $e');
    }
  }

  static Future<bool> isFull() async {
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }
}
