/// This phone opening the door to YouTube for the house's server.
///
/// YouTube answers "where is this song's audio?" only when asked from a home or a
/// mobile connection, never from the datacenter the server lives in. So the phone keeps
/// one WebSocket open to the server, and the server's yt-dlp asks its question through
/// it. Each connection yt-dlp wants is opened by the phone, from the phone's address,
/// and the bytes are passed along unread: the TLS runs end to end between yt-dlp and
/// YouTube. After that the server usually pulls the audio itself, and the song only
/// comes through here when YouTube insists. The question is about 370 KB. Everything
/// that breaks when YouTube changes something lives on the server, so no app update is
/// ever needed for it.
///
/// The phone connects to YouTube on 443 and nowhere else. The list is here, in the app,
/// where the server cannot widen it ([exitMayReach]).
///
/// Nothing but dart:io: like the downloader and the splitter, this could run in a
/// program without a window one day. server/muse/exits.py is the other half and has to
/// agree on every byte of a frame.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'told.dart';

/// A frame is one binary WebSocket message: its kind (1 byte), the stream it belongs to
/// (4 bytes, big-endian), then the payload. Stream 0 is the conversation about the door
/// itself.
abstract final class ExitFrame {
  static const hello = 0;
  static const open = 1;
  static const opened = 2;
  static const refused = 3;
  static const data = 4;
  static const close = 5;
  static const credit = 6;

  /// From the server, on stream 0: a song for this phone to fetch itself (door_pull.dart).
  static const pull = 7;
}

/// How much may be sent on one stream before hearing it arrived. Without it the
/// faster side queues a whole song in memory waiting for the slower one, and the slower
/// one is this phone's upload.
const exitWindow = 256 * 1024;

/// The most one frame carries.
const _piece = 64 * 1024;

Uint8List exitFrame(int kind, int stream, [List<int> payload = const []]) {
  final out = Uint8List(5 + payload.length);
  ByteData.sublistView(out)
    ..setUint8(0, kind)
    ..setUint32(1, stream);
  out.setRange(5, out.length, payload);
  return out;
}

final _hostName = RegExp(r'^[a-z0-9.-]+$');
const _youtube = ['youtube.com', 'googlevideo.com', 'ytimg.com', 'youtubei.googleapis.com'];

/// Where this phone will connect for the server: YouTube's own names, on 443. Not an
/// address and not any other port, whatever the server asks for.
bool exitMayReach(String host, int port) {
  if (port != 443) return false;
  final h = host.toLowerCase();
  if (!_hostName.hasMatch(h) || h.startsWith('.') || h.contains('..')) return false;
  return _youtube.any((e) => h == e || h.endsWith('.$e'));
}

/// The door's address on a server: the same host, over a WebSocket.
Uri exitUrlFor(String baseUrl) {
  final base = Uri.parse(baseUrl);
  return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/internal/exit');
}

enum ExitState {
  off,
  connecting,
  open,

  /// Shut, and trying again in a moment.
  waiting,

  /// The server said no: signed out, or an admin kept this device out of the pool.
  refused,
}

class _Link {
  _Link(this.socket);
  final Socket socket;
  StreamSubscription<Uint8List>? reading;

  /// What has gone to the server and not yet been heard of.
  int unacked = 0;

  /// Read from YouTube, waiting for room in the window. A socket hands over whatever
  /// has arrived in one go, a megabyte at a time on a fast line, so it is cut up here
  /// and the socket is paused while any of it waits.
  final pending = <Uint8List>[];

  /// YouTube has closed its end; the server is told once the last of it has gone.
  bool ended = false;

  /// The server's bytes, written one after another: a socket's flush may not overlap
  /// the next write.
  Future<void> writing = Future.value();
}

typedef ExitDial = Future<WebSocket> Function(Uri url, Map<String, String> headers);
typedef ExitConnect = Future<Socket> Function(String host, int port);

class ExitTunnel extends Told {
  ExitTunnel({
    required this.url,
    required this.token,
    required this.hello,
    ExitDial? dial,
    ExitConnect? connect,
    this.maxStreams = 6,
    this.onPull,
  })  : _dial = dial ?? _defaultDial,
        _connect = connect ?? _defaultConnect;

  final Uri Function() url;
  final String? Function() token;

  /// What this phone says about itself: its network, whether it may use mobile data.
  /// Asked again by [sayHello] whenever that changes.
  final Map<String, Object?> Function() hello;
  final int maxStreams;

  /// Told what the server asks this phone to fetch itself.
  final void Function(Map<String, dynamic> order)? onPull;
  final ExitDial _dial;
  final ExitConnect _connect;

  static Future<WebSocket> _defaultDial(Uri url, Map<String, String> headers) =>
      WebSocket.connect(url.toString(), headers: headers);

  static Future<Socket> _defaultConnect(String host, int port) =>
      Socket.connect(host, port, timeout: const Duration(seconds: 15));

  ExitState state = ExitState.off;
  String? problem;

  /// Connections opened for the server since the door opened, and what crossed them.
  int opened = 0;
  int bytes = 0;
  int get streams => _links.length;

  WebSocket? _ws;
  final _links = <int, _Link>{};
  bool _wanted = false;
  bool _dialing = false;
  int _failures = 0;
  Timer? _again;

  bool get wanted => _wanted;

  void _set(ExitState s) {
    if (state == s) return;
    state = s;
    notifyListeners();
  }

  Future<void> start() async {
    if (_wanted) return;
    _wanted = true;
    problem = null;
    _failures = 0;
    await _open();
  }

  Future<void> stop() async {
    _wanted = false;
    _again?.cancel();
    _again = null;
    final ws = _ws;
    _ws = null;
    _dropAll();
    if (ws != null) {
      try {
        await ws.close(1000);
      } catch (_) {}
    }
    _set(ExitState.off);
  }

  /// Tell the server again what this phone is like: on Wi-Fi now, say.
  void sayHello() => _send(exitFrame(ExitFrame.hello, 0, utf8.encode(jsonEncode(hello()))));

  Future<void> _open() async {
    if (!_wanted || _ws != null || _dialing) return;
    final t = token();
    if (t == null) {
      problem = 'not signed in';
      _set(ExitState.refused);
      return;
    }
    _dialing = true;
    _set(ExitState.connecting);
    try {
      final ws = await _dial(url(), {'Authorization': 'Bearer $t'})
          .timeout(const Duration(seconds: 20));
      if (!_wanted) {
        unawaited(ws.close(1000));
        return;
      }
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      problem = null;
      _set(ExitState.open);
      sayHello();
      ws.listen(_heard, onDone: () => _closed(ws), onError: (_) => _closed(ws),
          cancelOnError: true);
    } on WebSocketException catch (e) {
      // Turned down at the door: the token is not one the server knows any more.
      final said = '$e';
      if (said.contains('401') || said.contains('403')) {
        problem = 'the server did not let this device in';
        _wanted = false;
        _set(ExitState.refused);
      } else {
        problem = said;
        _later();
      }
    } catch (e) {
      problem = '$e';
      _later();
    } finally {
      _dialing = false;
    }
  }

  void _later() {
    if (!_wanted) return;
    _failures += 1;
    const steps = [1, 2, 5, 10, 30, 60];
    final wait = steps[(_failures - 1).clamp(0, steps.length - 1)];
    _set(ExitState.waiting);
    _again?.cancel();
    _again = Timer(Duration(seconds: wait), () {
      _again = null;
      unawaited(_open());
    });
  }

  void _closed(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ws = null;
    _dropAll();
    switch (ws.closeCode) {
      case 4401 || 4403:
        _wanted = false;
        problem ??= 'the server did not let this device in';
        _set(ExitState.refused);
      case 4000:
        // Replaced by a newer door for this same device: that one is the live one, and
        // knocking again would only shut it.
        _wanted = false;
        problem = 'opened again elsewhere for this device';
        _set(ExitState.refused);
      default:
        _later();
    }
  }

  void _send(Uint8List frame) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(frame);
    } catch (_) {
      // Closing; _closed tidies up.
    }
  }

  void _heard(dynamic message) {
    if (message is! List<int>) return;
    final raw = message is Uint8List ? message : Uint8List.fromList(message);
    if (raw.length < 5) return;
    final head = ByteData.sublistView(raw);
    final kind = head.getUint8(0);
    final sid = head.getUint32(1);
    final payload = Uint8List.sublistView(raw, 5);
    switch (kind) {
      case ExitFrame.hello when sid == 0:
        try {
          final said = jsonDecode(utf8.decode(payload));
          if (said is Map && said['ok'] == false) {
            problem = '${said['why'] ?? 'refused'}';
            _wanted = false;
            _set(ExitState.refused);
          }
        } catch (_) {}
      case ExitFrame.pull when sid == 0:
        try {
          final order = jsonDecode(utf8.decode(payload));
          if (order is Map<String, dynamic>) onPull?.call(order);
        } catch (_) {}
      case ExitFrame.open:
        if (payload.length < 3) return;
        final port = ByteData.sublistView(payload).getUint16(0);
        final host = utf8.decode(payload.sublist(2), allowMalformed: true);
        unawaited(_openFor(sid, host, port));
      case ExitFrame.data:
        final link = _links[sid];
        if (link == null) return;
        final n = payload.length;
        // A copy: the frame's buffer is not ours to keep while the write waits.
        final chunk = Uint8List.fromList(payload);
        link.writing = link.writing.then((_) async {
          link.socket.add(chunk);
          await link.socket.flush();
          bytes += n;
          _send(exitFrame(ExitFrame.credit, sid, _u32(n)));
        }).catchError((Object _) => _drop(sid, tell: true));
      case ExitFrame.credit:
        final link = _links[sid];
        if (link == null || payload.length < 4) return;
        link.unacked -= ByteData.sublistView(payload).getUint32(0);
        if (link.unacked < 0) link.unacked = 0;
        _drain(sid, link);
      case ExitFrame.close:
        final link = _links.remove(sid);
        if (link == null) return;
        link.writing.whenComplete(() {
          link.reading?.cancel();
          link.socket.destroy();
        });
        notifyListeners();
    }
  }

  Future<void> _openFor(int sid, String host, int port) async {
    if (!exitMayReach(host, port)) {
      _send(exitFrame(ExitFrame.refused, sid, utf8.encode('not somewhere this phone goes')));
      return;
    }
    if (_links.length >= maxStreams) {
      _send(exitFrame(ExitFrame.refused, sid, utf8.encode('too many at once')));
      return;
    }
    Socket socket;
    try {
      socket = await _connect(host, port);
    } catch (e) {
      _send(exitFrame(ExitFrame.refused, sid, utf8.encode('$e')));
      return;
    }
    if (_ws == null) {
      socket.destroy();
      return;
    }
    final link = _links[sid] = _Link(socket);
    opened += 1;
    _send(exitFrame(ExitFrame.opened, sid));
    link.reading = socket.listen(
      (chunk) {
        for (var at = 0; at < chunk.length; at += _piece) {
          final end = at + _piece < chunk.length ? at + _piece : chunk.length;
          link.pending.add(Uint8List.sublistView(chunk, at, end));
        }
        _drain(sid, link);
      },
      onDone: () {
        link.ended = true;
        _drain(sid, link);
      },
      onError: (Object _) => _drop(sid, tell: true),
      cancelOnError: true,
    );
    notifyListeners();
  }

  /// What YouTube sent, on to the server as far as the window allows; the socket
  /// waits while the rest does.
  void _drain(int sid, _Link link) {
    if (!identical(_links[sid], link)) return;
    while (link.pending.isNotEmpty && link.unacked < exitWindow) {
      final piece = link.pending.removeAt(0);
      _send(exitFrame(ExitFrame.data, sid, piece));
      bytes += piece.length;
      link.unacked += piece.length;
    }
    if (link.ended) {
      if (link.pending.isEmpty) _drop(sid, tell: true);
      return;
    }
    final r = link.reading;
    if (r == null) return;
    final full = link.pending.isNotEmpty || link.unacked >= exitWindow;
    if (full && !r.isPaused) {
      r.pause();
    } else if (!full && r.isPaused) {
      r.resume();
    }
  }

  void _drop(int sid, {required bool tell}) {
    final link = _links.remove(sid);
    if (link == null) return;
    link.reading?.cancel();
    link.socket.destroy();
    if (tell) _send(exitFrame(ExitFrame.close, sid));
    notifyListeners();
  }

  void _dropAll() {
    for (final sid in _links.keys.toList()) {
      _drop(sid, tell: false);
    }
  }

  static Uint8List _u32(int n) {
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, n);
    return b;
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
