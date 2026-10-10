import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../state/booth/board/link_server.dart';
import '../../state/booth/board/link_server_io.dart';
import 'stage_window.dart';

bool get canPopOutStage =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// The stage in a window of its own: this program, started again, reading the show
/// off the desk's link over the loopback — the board's way (board/pop_out_io.dart).
Future<bool> popOutStage(BoardLinkBase? link) async {
  if (!canPopOutStage || link is! BoardLinkServer) return false;
  await link.scan();
  final port = link.port, token = link.token;
  if (port == null || token == null) return false;
  final url = 'ws://127.0.0.1:$port/stage?t=$token';
  try {
    await Process.start(
      Platform.resolvedExecutable,
      [stageWindowFlag, url],
      environment: {...Platform.environment, 'WETOWL_NON_UNIQUE': '1'},
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (e) {
    debugPrint('stage window: could not start — $e');
    return false;
  }
}
