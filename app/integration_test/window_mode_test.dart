// The window over the whole screen and back, as the compositor actually does it.
//
// Run under a headless mutter (what the booth's frame measurements use), so the
// floating and the maximised paths each get a numbered trace rather than a feeling:
//
//   dbus-run-session -- mutter --headless --wayland --no-x11 --wayland-display=wm-test \
//     --virtual-monitor 1920x1080@60 &
//   WETOWL_NON_UNIQUE=1 GDK_BACKEND=wayland WAYLAND_DISPLAY=wm-test \
//     flutter drive -d linux --driver=test_driver/integration_test.dart \
//     --target=integration_test/window_mode_test.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muse/src/ui/window_mode.dart';
import 'package:window_manager/window_manager.dart';

const _floating = Size(1360, 860);

/// Waits for [listenable] to read [want], or fails after [patience].
Future<void> _until(ValueListenable<bool> listenable, bool want,
    {Duration patience = const Duration(seconds: 3), required String what}) async {
  if (listenable.value == want) return;
  final done = Completer<void>();
  void look() {
    if (listenable.value == want && !done.isCompleted) done.complete();
  }

  listenable.addListener(look);
  try {
    await done.future.timeout(patience, onTimeout: () => fail('$what: still ${listenable.value} after $patience'));
  } finally {
    listenable.removeListener(look);
  }
}

Future<void> _settle([int ms = 400]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<String> _trace(String step) async {
  final b = await windowMode.bounds();
  final line = '$step: full=${windowMode.fullScreen.value} max=${windowMode.maximised.value} '
      'bounds=${b.width.round()}x${b.height.round()} at ${b.left.round()},${b.top.round()}';
  debugPrint('[window] $line');
  return line;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final traces = <String>[];

  setUpAll(() async {
    await windowMode.ready();
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('window'))))); // something to draw
    await _settle(800);
  });

  tearDownAll(() {
    binding.reportData = {'traces': traces};
  });

  Future<void> floating() async {
    if (windowMode.fullScreen.value) {
      await windowMode.setFullScreen(false);
      await _until(windowMode.fullScreen, false, what: 'leave first');
    }
    if (windowMode.maximised.value) {
      await windowManager.unmaximize();
      await _until(windowMode.maximised, false, what: 'unmaximise first');
    }
    await windowManager.setSize(_floating);
    await _settle();
  }

  testWidgets('from a floating window: over the screen and back to the same size', (tester) async {
    await floating();
    traces.add(await _trace('floating start'));
    final before = await windowMode.bounds();

    await windowMode.setFullScreen(true);
    await _until(windowMode.fullScreen, true, what: 'enter');
    await _settle();
    traces.add(await _trace('floating full'));
    final full = await windowMode.bounds();
    expect(full.width, greaterThan(before.width), reason: 'the window should have grown to the screen');
    expect(full.height, greaterThan(before.height));

    await windowMode.setFullScreen(false);
    await _until(windowMode.fullScreen, false, what: 'leave');
    await _settle(600);
    traces.add(await _trace('floating back'));
    final back = await windowMode.bounds();
    expect(back.width, closeTo(before.width, 2));
    expect(back.height, closeTo(before.height, 2));
    expect(windowMode.maximised.value, isFalse);
  });

  testWidgets('from a maximised window: over the screen and back maximised', (tester) async {
    await floating();
    await windowManager.maximize();
    await _until(windowMode.maximised, true, what: 'maximise');
    await _settle();
    traces.add(await _trace('maximised start'));
    final before = await windowMode.bounds();

    await windowMode.setFullScreen(true);
    await _until(windowMode.fullScreen, true, what: 'enter');
    await _settle();
    traces.add(await _trace('maximised full'));
    final full = await windowMode.bounds();
    expect(full.width, greaterThanOrEqualTo(before.width));

    await windowMode.setFullScreen(false);
    await _until(windowMode.fullScreen, false, what: 'leave');
    await _settle(600);
    traces.add(await _trace('maximised back'));
    expect(windowMode.maximised.value, isTrue, reason: 'a maximised window comes back maximised');
    final back = await windowMode.bounds();
    expect(back.width, closeTo(before.width, 2));
  });

  testWidgets('two presses in quick succession are one change, not none', (tester) async {
    await floating();
    var changes = 0;
    void count() => changes++;
    windowMode.fullScreen.addListener(count);
    unawaited(windowMode.toggleFullScreen());
    await Future<void>.delayed(const Duration(milliseconds: 30));
    unawaited(windowMode.toggleFullScreen());
    await _until(windowMode.fullScreen, true, what: 'enter');
    await _settle(800);
    windowMode.fullScreen.removeListener(count);
    traces.add(await _trace('double press'));
    expect(changes, 1);
    expect(windowMode.fullScreen.value, isTrue);
    await windowMode.setFullScreen(false);
    await _until(windowMode.fullScreen, false, what: 'leave');
  });

  testWidgets('the window changed by someone else: the flag follows', (tester) async {
    await floating();
    // Straight to the plugin, past WindowMode — the desktop's own key would do this.
    await windowManager.setFullScreen(true);
    await _until(windowMode.fullScreen, true, what: 'follow enter');
    traces.add(await _trace('external enter'));
    await windowManager.setFullScreen(false);
    await _until(windowMode.fullScreen, false, what: 'follow leave');
    await _settle(700);
    traces.add(await _trace('external leave'));
    // GTK alone brings a floating window back ninety pixels smaller each way (the
    // content without its title bar's shadow margins); WindowMode puts it back.
    final back = await windowMode.bounds();
    expect(back.width, closeTo(_floating.width, 2));
    expect(back.height, closeTo(_floating.height, 2));
  });
}
