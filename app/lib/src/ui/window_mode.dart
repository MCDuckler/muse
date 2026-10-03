import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// The program's window, on a desk: over the whole screen or not, maximised or not —
/// as the window itself says.
///
/// What it says is the truth here, not what was last asked for. The window's state
/// changes when the compositor says so, which on Wayland is some time after
/// `setFullScreen` returns and can be for reasons of its own (the desktop's own key,
/// a double-click on the title bar); so the two flags below follow the window's
/// events, and asking for full screen means asking, then waiting to be told. Reading
/// the state straight back used to leave the booth's button lit for a window that was
/// not full screen, and the next press did the opposite of what the icon promised.
///
/// Full screen is the program's, not any one page's: F11 anywhere, and leaving the
/// booth leaves the window as it is.
class WindowMode with WindowListener {
  WindowMode._();

  /// Whether the window is over the whole screen, as of the last thing it said.
  final fullScreen = ValueNotifier<bool>(false);

  /// Whether the window is maximised.
  final maximised = ValueNotifier<bool>(false);

  /// Where there is a window to speak of: Linux, Windows, a Mac.
  static bool get can =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool _ready = false;

  /// The change in flight, if one is: a second press while the window is still on
  /// its way is dropped, not turned into its opposite.
  Completer<void>? _pending;

  /// The window's size as a floating window — kept up to date from its resizes, so it
  /// is known even when somebody else sent the window full screen — to be put back
  /// when the compositor does not. It does not, on GNOME: a floating window with GTK's
  /// own title bar comes back from full screen ninety pixels smaller each way, which
  /// is the content without the bar's shadow margins (measured under a headless mutter:
  /// 1360×860 → 1270×770). A maximised window comes back maximised and needs nothing.
  /// (Wayland lets nobody place a window, so only the size is ever asked for.)
  Size? _floating;

  /// When the window last changed, so two presses in a bounce are one.
  DateTime _changedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _bounce = Duration(milliseconds: 250);

  /// How long the window is given to say it changed before its state is read instead.
  static const _patience = Duration(seconds: 1);

  /// Before the first frame, on a desk: the plugin needs its hands on the window, and
  /// this needs to hear it.
  Future<void> ready() async {
    if (!can || _ready) return;
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      fullScreen.value = await windowManager.isFullScreen();
      maximised.value = await windowManager.isMaximized();
      if (!fullScreen.value && !maximised.value) _floating = (await windowManager.getBounds()).size;
      _ready = true;
    } catch (e) {
      debugPrint('window: $e');
    }
  }

  /// Over the whole screen, or back.
  Future<void> toggleFullScreen() => setFullScreen(!fullScreen.value);

  /// Ask the window for [want], and wait to be told it happened. Nothing happens for a
  /// window that is already there, or still on its way somewhere.
  Future<void> setFullScreen(bool want) async {
    if (!can || !_ready) return;
    if (_pending != null) return;
    if (want == fullScreen.value) return;
    if (DateTime.now().difference(_changedAt) < _bounce) return;
    final done = _pending = Completer<void>();
    try {
      await windowManager.setFullScreen(want);
      await done.future.timeout(_patience, onTimeout: () async {
        // Told nothing: read it, and believe that.
        fullScreen.value = await windowManager.isFullScreen();
      });
    } catch (e) {
      debugPrint('full screen: $e');
    } finally {
      if (identical(_pending, done)) _pending = null;
    }
  }

  /// Back from full screen, a floating window should be the size it was. A maximised
  /// one comes back maximised on its own; a floating one usually comes back right too,
  /// and is only resized when it did not.
  Future<void> _putBack() async {
    final was = _floating;
    if (was == null || maximised.value) return;
    // The compositor's own restore lands a frame or two after the state does.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (fullScreen.value || maximised.value) return;
    final now = (await windowManager.getBounds()).size;
    if ((now.width - was.width).abs() > 2 || (now.height - was.height).abs() > 2) {
      await windowManager.setSize(was);
    }
  }

  void _told(bool full) {
    _changedAt = DateTime.now();
    if (fullScreen.value != full) fullScreen.value = full;
    final p = _pending;
    if (p != null && !p.isCompleted) p.complete();
    // Whoever sent it there — this, the desktop's key — the floating size is put back.
    if (!full) unawaited(_putBack());
  }

  @override
  void onWindowResize() => unawaited(_noteSize());

  @override
  void onWindowResized() => unawaited(_noteSize());

  /// The floating size, as the window is resized while it is one.
  Future<void> _noteSize() async {
    if (fullScreen.value || maximised.value || _pending != null) return;
    try {
      _floating = (await windowManager.getBounds()).size;
    } catch (_) {}
  }

  @override
  void onWindowEnterFullScreen() => _told(true);

  @override
  void onWindowLeaveFullScreen() => _told(false);

  @override
  void onWindowMaximize() => maximised.value = true;

  @override
  void onWindowUnmaximize() => maximised.value = false;

  /// The window's size and place, for a test to check against the screen.
  Future<Rect> bounds() => windowManager.getBounds();
}

/// The one window.
final windowMode = WindowMode._();
