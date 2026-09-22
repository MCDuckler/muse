import 'dart:io';
import 'dart:ui';

/// Whether the screen this runs on is a tablet's: the shortest side, in logical
/// pixels, is the number every layout uses for the same question.
bool _tablet() {
  try {
    final view = PlatformDispatcher.instance.views.first;
    final shortest = view.physicalSize.shortestSide / view.devicePixelRatio;
    return shortest >= 600;
  } catch (_) {
    return false;
  }
}

String deviceName() {
  if (Platform.isIOS) return _tablet() ? 'iPad' : 'iPhone';
  if (Platform.isAndroid) return _tablet() ? 'Android tablet' : 'Android phone';
  // A computer has a name of its own, and it is the one its owner already uses.
  try {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty && host != 'localhost') {
      // "chris-laptop.local" is the same machine as "chris-laptop".
      return host.split('.').first;
    }
  } catch (_) {}
  return Platform.isWindows
      ? 'Windows PC'
      : Platform.isMacOS
          ? 'Mac'
          : 'Linux computer';
}

String deviceKind() {
  if (Platform.isIOS || Platform.isAndroid) return _tablet() ? 'tablet' : 'phone';
  return 'desktop';
}
