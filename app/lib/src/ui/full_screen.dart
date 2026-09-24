import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// The window over the whole screen, and back — on a desk; nothing anywhere else.
/// The booth's button and its F11.
final fullScreen = ValueNotifier<bool>(false);

bool get canGoFullScreen =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

Future<void> toggleFullScreen() async {
  if (!canGoFullScreen) return;
  try {
    final now = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!now);
    fullScreen.value = !now;
  } catch (e) {
    debugPrint('full screen: $e');
  }
}

/// Before the first frame, on a desk: the plugin needs its hands on the window.
Future<void> readyTheWindow() async {
  if (!canGoFullScreen) return;
  try {
    await windowManager.ensureInitialized();
  } catch (e) {
    debugPrint('window: $e');
  }
}
