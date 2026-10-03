import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../state/booth/board/link_server.dart';
import '../../../state/booth/board/link_server_io.dart';
import 'board_window.dart';

bool get canPopOut =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// The board in a window of its own: this program, started again, pointed at the
/// desk's link over the loopback. On Linux the runner is told not to hand over to
/// the running app (it is one WetOwl per session otherwise); on Windows the runner
/// reads the flag itself.
Future<bool> popOutBoard(BoardLinkBase? link) async {
  if (!canPopOut || link is! BoardLinkServer) return false;
  final port = link.port, token = link.token;
  if (port == null || token == null) return false;
  final url = 'ws://127.0.0.1:$port/board?t=$token';
  try {
    await Process.start(
      Platform.resolvedExecutable,
      [boardWindowFlag, url],
      environment: {...Platform.environment, 'WETOWL_NON_UNIQUE': '1'},
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (e) {
    debugPrint('board window: could not start — $e');
    return false;
  }
}
