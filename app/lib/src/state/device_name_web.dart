import 'package:web/web.dart' as web;

/// "Firefox on Windows", "Safari on iPhone": the browser and what it is running on,
/// which is how people already tell their browsers apart.
String deviceName() {
  final ua = _agent();
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('OPR/') || ua.contains('Opera')
          ? 'Opera'
          : ua.contains('Firefox/')
              ? 'Firefox'
              : ua.contains('Chrome/') || ua.contains('CriOS/')
                  ? 'Chrome'
                  : ua.contains('Safari/')
                      ? 'Safari'
                      : 'Browser';
  final on = ua.contains('iPad')
      ? 'iPad'
      : ua.contains('iPhone')
          ? 'iPhone'
          : ua.contains('Android')
              ? 'Android'
              : ua.contains('Windows')
                  ? 'Windows'
                  : ua.contains('Mac OS')
                      ? 'Mac'
                      : ua.contains('CrOS')
                          ? 'Chromebook'
                          : ua.contains('Linux')
                              ? 'Linux'
                              : '';
  return on.isEmpty ? browser : '$browser on $on';
}

String deviceKind() => 'browser';

String _agent() {
  try {
    return web.window.navigator.userAgent;
  } catch (_) {
    return '';
  }
}
