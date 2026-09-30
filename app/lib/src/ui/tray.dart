import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';

/// WetOwl in the tray, on a desk: the window can be shut and the music go on.
///
/// Closing the window hides it rather than ending the app — a record in the booth, the
/// queue, the pool's splitting all carry on — and the icon brings it back. The app ends
/// from the icon's menu (or Ctrl Q), which is the one way out now that the window's
/// close button no longer is. Launching WetOwl again while it sits in the tray brings
/// the same window back rather than starting a second one (the runners: one WetOwl per
/// session).
///
/// Linux shows the icon through AppIndicator, whose menu is the whole of it: a click on
/// the icon opens the menu, there is no click of its own. Windows shows the window on a
/// click and the menu on a right click.
class DeskTray with TrayListener, WindowListener {
  DeskTray._(this._app);

  final AppState _app;

  static DeskTray? _running;

  /// Where there is a tray to put an icon in: Linux and Windows.
  static bool get wanted =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// Whether the icon went up. Without one — a desktop with no tray, a Linux without
  /// AppIndicator — the window's close button goes on ending the app, as before: a
  /// window that hides with nothing to bring it back is an app that cannot be found.
  static bool get up => _running != null;

  /// Put the icon up. Safe to call again; failures are said and left.
  static Future<void> start(AppState app) async {
    if (!wanted || _running != null) return;
    final tray = DeskTray._(app);
    try {
      await trayManager.setIcon(defaultTargetPlatform == TargetPlatform.windows
          ? 'assets/tray/tray.ico'
          : 'assets/tray/tray.png');
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await trayManager.setToolTip('WetOwl');
      }
      trayManager.addListener(tray);
      _running = tray;
      await tray._menu(force: true);
      app.addListener(tray._changed);
      // Only now, with an icon to come back from: the close button hides.
      windowManager.addListener(tray);
      await windowManager.setPreventClose(true);
    } catch (e) {
      debugPrint('tray: no icon ($e)');
      _running = null;
      trayManager.removeListener(tray);
      app.removeListener(tray._changed);
    }
  }

  /// End the app: the one way out while the window's close button only hides it.
  static Future<void> quit() async {
    final tray = _running;
    _running = null;
    if (tray != null) {
      tray._app.removeListener(tray._changed);
      trayManager.removeListener(tray);
      windowManager.removeListener(tray);
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (e) {
      debugPrint('tray: could not close the window ($e)');
    }
  }

  /// Bring the window back, in front.
  static Future<void> show() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('tray: could not show the window ($e)');
    }
  }

  // ------------------------------------------------------------------ the menu
  /// What the menu last said, so the app speaking ten times a second while a record
  /// downloads is not ten new menus a second.
  String? _said;

  void _changed() => unawaited(_menu());

  /// What is playing, as the menu's first line says it: the booth's record while the
  /// booth has the sound, the player's otherwise.
  ({String line, bool playing, bool booth}) get _now {
    final booth = _app.boothIfOpened;
    if (booth != null && booth.live) {
      final t = booth.master.track;
      return (
        line: t == null ? 'The booth' : 'The booth · ${t.displayTitle}',
        playing: true,
        booth: true,
      );
    }
    final last = _app.player?.last;
    final t = last?.current;
    return (
      line: t == null ? 'Nothing playing' : '${t.displayTitle} — ${t.artistLine}',
      playing: last?.playing ?? false,
      booth: false,
    );
  }

  Future<void> _menu({bool force = false}) async {
    if (_running != this) return;
    final now = _now;
    final said = '${now.line}|${now.playing}|${now.booth}';
    if (!force && said == _said) return;
    _said = said;
    // The transport is the player's. While the booth has the sound it is the booth's
    // to work, from the booth: a play button here would start the queue under a mix.
    final transport = _app.player != null && !now.booth;
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'now', label: _short(now.line), disabled: true),
        MenuItem(key: 'show', label: 'Open WetOwl'),
        MenuItem.separator(),
        MenuItem(key: 'play', label: now.playing ? 'Pause' : 'Play', disabled: !transport),
        MenuItem(key: 'next', label: 'Next', disabled: !transport),
        MenuItem(key: 'previous', label: 'Previous', disabled: !transport),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit WetOwl'),
      ]));
    } catch (e) {
      debugPrint('tray: menu not set ($e)');
    }
  }

  /// A menu line a menu can hold.
  static String _short(String s) => s.length <= 60 ? s : '${s.substring(0, 59)}…';

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(show());
      case 'play':
        unawaited(_app.playPause());
      case 'next':
        unawaited(_app.skipNext());
      case 'previous':
        unawaited(_app.skipPrevious());
      case 'quit':
        unawaited(quit());
    }
  }

  // Windows only: Linux's AppIndicator opens the menu itself and says nothing of clicks.
  @override
  void onTrayIconMouseDown() => unawaited(show());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  // ------------------------------------------------------------------ the window
  /// The close button, while the icon is up: the window goes, the app stays.
  @override
  void onWindowClose() {
    unawaited(() async {
      try {
        if (await windowManager.isPreventClose()) await windowManager.hide();
      } catch (e) {
        debugPrint('tray: could not hide the window ($e)');
      }
    }());
  }
}
