// A direct wire to a desk: its WebSocket, on the local network.
import 'dart:async';
import 'dart:io';

import 'remote_board.dart';

/// Tries every address the desk advertised at once; the first to answer is the
/// link. Null when none does within a moment.
Future<RemoteLink?> connectLan(Map<String, dynamic> advert, {required String name}) async {
  final port = (advert['port'] as num?)?.toInt();
  final token = advert['token'] as String?;
  final addrs = [for (final a in (advert['addrs'] as List? ?? const [])) '$a'];
  if (port == null || token == null || addrs.isEmpty) return null;
  final done = Completer<WebSocket?>();
  var left = addrs.length;
  for (final a in addrs) {
    unawaited(() async {
      try {
        final url = Uri(
          scheme: 'ws',
          host: a,
          port: port,
          path: '/board',
          queryParameters: {'t': token, 'name': name},
        );
        final ws = await WebSocket.connect(url.toString()).timeout(const Duration(milliseconds: 600));
        if (done.isCompleted) {
          await ws.close();
        } else {
          done.complete(ws);
        }
      } catch (_) {
        if (--left == 0 && !done.isCompleted) done.complete(null);
      }
    }());
  }
  final ws = await done.future;
  return ws == null ? null : _LanLink(ws);
}

class _LanLink extends RemoteLink {
  _LanLink(this._ws);
  final WebSocket _ws;

  @override
  Stream<String> get lines => _ws.where((d) => d is String).cast<String>();

  @override
  String get kind => 'LAN';

  @override
  void send(String line) {
    try {
      _ws.add(line);
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {}
  }
}

/// A link to one url, for the board's own window (which was told the desk's).
Future<RemoteLink?> connectLanUrl(String url, {required String name}) async {
  try {
    final u = Uri.parse(url);
    final with_ = u.replace(queryParameters: {...u.queryParameters, 'name': name});
    final ws = await WebSocket.connect(with_.toString()).timeout(const Duration(seconds: 3));
    return _LanLink(ws);
  } catch (_) {
    return null;
  }
}
