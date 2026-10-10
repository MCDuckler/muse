// The desk's WebSocket server: the board, reachable on the local network.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../booth.dart';
import '../control/transport.dart';
import '../../show/show_wire.dart';
import 'link_server.dart';

BoardLinkBase boardLink({required Booth Function() booth}) => BoardLinkServer(booth: booth);

class BoardLinkServer extends BoardLinkBase {
  BoardLinkServer({required super.booth});

  HttpServer? _server;
  String? _token;
  int _n = 0;
  Future<void>? _binding;

  /// The port, once bound.
  int? get port => _server?.port;
  String? get token => _token;

  /// A new token with every session of the server: whoever had the old one has to
  /// be told the new one, through the account, which is the point.
  static String _newToken() {
    final r = Random.secure();
    return [for (var i = 0; i < 32; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  /// Bound on first scan — which the ControllerManager does as it starts.
  @override
  Future<List<FoundDevice>> scan() async {
    await (_binding ??= _bind());
    return super.scan();
  }

  Future<void> _bind() async {
    try {
      // In the root zone: a bound server keeps a two-minute timer of dart:io's own
      // for idle connections, and a test's own clock would be left holding it.
      final server = await Zone.root.run(() => HttpServer.bind(InternetAddress.anyIPv4, 0));
      _server = server;
      _token = _newToken();
      server.listen(_request, onError: (Object e) => debugPrint('board link: $e'));
      debugPrint('board link: listening on ${server.port}');
    } catch (e) {
      debugPrint('board link: could not listen — $e');
    }
  }

  Future<void> _request(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final upgrade = _token != null && q['t'] == _token && WebSocketTransformer.isUpgradeRequest(req);
    // The stage's window (ui/show/stage_window.dart) reads the show here, on the
    // same server and token: frames out, nothing in but pings.
    if (req.uri.path == '/stage' && upgrade) {
      await _stage(req);
      return;
    }
    final ok = req.uri.path == '/board' && upgrade;
    if (!ok) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    if (peers.values.where((p) => p.direct && !p.closed).length >= 4) {
      req.response.statusCode = HttpStatus.tooManyRequests;
      await req.response.close();
      return;
    }
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (e) {
      debugPrint('board link: upgrade failed — $e');
      return;
    }
    final key = 'remote:${++_n}';
    final name = (q['name'] ?? 'A screen').trim();
    late final LinkPeer peer;
    peer = LinkPeer(
      key: key,
      name: name.isEmpty ? 'A screen' : name,
      say: (line) {
        try {
          ws.add(line);
        } catch (_) {}
      },
      onClose: () async {
        try {
          await ws.close();
        } catch (_) {}
      },
    );
    ws.listen(
      (data) {
        if (data is! String) return;
        // Pings are answered here, not by the booth.
        if (data.startsWith('{"t":"ping"')) {
          ws.add(data.replaceFirst('"ping"', '"pong"'));
          peer.heard = DateTime.now();
          return;
        }
        peer.arrived(data);
      },
      onDone: () => dismiss(key),
      onError: (Object _) => dismiss(key),
    );
    admit(peer);
  }

  final _stages = <WebSocket>{};

  Future<void> _stage(HttpRequest req) async {
    if (_stages.length >= 4) {
      req.response.statusCode = HttpStatus.tooManyRequests;
      await req.response.close();
      return;
    }
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (e) {
      debugPrint('stage link: upgrade failed — $e');
      return;
    }
    _stages.add(ws);
    final wire = ShowWire(booth.show, (line) {
      try {
        ws.add(line);
      } catch (_) {}
    });
    ws.listen(
      (data) {
        if (data is String && data.startsWith('{"t":"ping"')) ws.add(data.replaceFirst('"ping"', '"pong"'));
      },
      onDone: () {
        wire.close();
        _stages.remove(ws);
      },
      onError: (Object _) {
        wire.close();
        _stages.remove(ws);
      },
    );
  }

  /// How many stages are reading the show.
  int get stages => _stages.length;

  /// The local addresses a screen on the same network can try, the port and the
  /// token: what this desk tells the account about itself.
  @override
  Map<String, dynamic>? get advert {
    final port = this.port, token = _token;
    if (port == null || token == null) return null;
    return {'port': port, 'token': token, 'addrs': _addrs};
  }

  List<String> _addrs = const ['127.0.0.1'];

  /// Looked up now and then by the app's device report: the network can change.
  @override
  Future<void> refreshAddresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      final addrs = <String>['127.0.0.1'];
      for (final i in list) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !addrs.contains(a.address)) addrs.add(a.address);
        }
      }
      _addrs = addrs;
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await _server?.close(force: true);
    _server = null;
  }
}
