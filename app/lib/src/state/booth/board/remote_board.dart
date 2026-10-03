// A desk's board, on this screen: the same pads, drawn from what the desk says and
// pressed back to it.
//
// Direct where it can be (a WebSocket to the desk on the same network, a few
// milliseconds), through the server's relay where it cannot (the SSE stream down,
// a POST up, a few hundred). The screen never makes a sound of its own; what it
// shows is what the desk said, and the sweep across a pad is this screen's clock
// carrying on from how far along the desk said the sound was.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../api/models.dart';
import 'board_face.dart';
import 'link_wire.dart';
import 'pad_spec.dart';
import 'remote_link_none.dart' if (dart.library.io) 'remote_link_io.dart' as lan;
import 'soundboard.dart' show PadState, Soundboard;

/// A wire to the desk: lines up, lines down.
abstract class RemoteLink {
  Stream<String> get lines;
  void send(String line);
  Future<void> close();

  /// What it is, for the chip: LAN or RELAY.
  String get kind;
}

/// A link made of the server: up by POST, down by the account's event stream.
class RelayLink extends RemoteLink {
  RelayLink({required this.deskId, required this.post, required Stream<Map<String, dynamic>> states})
      : _sub = null {
    _sub = states.listen((m) {
      if (m['device_id'] == deskId) _down.add(jsonEncode(m));
    });
  }

  final int deskId;

  /// Posts a batch of lines to the desk, through the server.
  final Future<void> Function(int deskId, List<Map<String, dynamic>> lines) post;

  final _down = StreamController<String>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _pending = <Map<String, dynamic>>[];
  Timer? _flush;

  @override
  Stream<String> get lines => _down.stream;

  @override
  String get kind => 'RELAY';

  /// Lines go in batches of a few tens of milliseconds: a press and its release
  /// are one request, not two.
  @override
  void send(String line) {
    final m = LinkWire.decode(line);
    if (m == null) return;
    if (m['t'] == 'ping') {
      // The relay's round trip is measured by the batch itself.
      _down.add(jsonEncode({'t': 'pong', 'n': m['n']}));
      return;
    }
    _pending.add(m);
    _flush ??= Timer(const Duration(milliseconds: 30), () {
      _flush = null;
      final batch = List.of(_pending);
      _pending.clear();
      unawaited(post(deskId, batch).catchError((_) {}));
    });
  }

  @override
  Future<void> close() async {
    _flush?.cancel();
    await _sub?.cancel();
    await _down.close();
  }
}

/// The desk's board as this screen has it.
class RemoteBoard extends ChangeNotifier implements BoardFace {
  RemoteBoard._(this.desk, this._link) {
    _sub = _link.lines.listen(_arrived, onDone: _gone, onError: (Object _) => _gone());
    _pinger = Timer.periodic(const Duration(seconds: 2), (_) => _ping());
    _ping();
  }

  /// To [desk], directly if it can be reached on the network, else through
  /// [relay]. Null when neither answers.
  static Future<RemoteBoard?> connect(
    DeviceInfo desk, {
    required String myName,
    required RemoteLink Function() relay,
  }) async {
    final advert = desk.boardLink;
    if (advert != null) {
      final direct = await lan.connectLan(advert, name: myName);
      if (direct != null) return RemoteBoard._(desk, direct);
    }
    return RemoteBoard._(desk, relay());
  }

  /// Over a link already made: the board's own window, given the desk's url.
  factory RemoteBoard.over(DeviceInfo desk, RemoteLink link) => RemoteBoard._(desk, link);

  final DeviceInfo desk;
  final RemoteLink _link;
  StreamSubscription<String>? _sub;
  Timer? _pinger;

  @override
  BoardDoc doc = BoardDoc.empty();
  @override
  int bank = 0;

  /// The desk's look, so this screen can match it.
  bool light = false;

  /// Whether the desk has said what the board is yet.
  bool get ready => _ready;
  bool _ready = false;

  /// Whether the wire is still up.
  bool get linked => _linked;
  bool _linked = true;

  String get kind => _link.kind;

  /// The last measured round trip, or null before the first.
  Duration? get rtt => _rtt;
  Duration? _rtt;
  int _pingN = 0;
  final _pingAt = <int, DateTime>{};

  final _peaks = <int, Float32List>{};
  final _states = <String, PadState>{};

  void _ping() {
    final n = ++_pingN;
    _pingAt[n] = DateTime.now();
    _pingAt.removeWhere((k, _) => k < n - 5);
    _link.send(jsonEncode({'t': 'ping', 'n': n}));
  }

  void _arrived(String line) {
    final m = LinkWire.decode(line);
    if (m == null) return;
    switch (m['t']) {
      case 'board':
        doc = BoardDoc.fromJson((m['doc'] as Map).cast<String, dynamic>());
        bank = (m['bank'] as num?)?.toInt() ?? bank;
        light = m['light'] == true;
        final peaks = m['peaks'];
        if (peaks is Map) {
          for (final e in peaks.entries) {
            final id = int.tryParse('${e.key}');
            if (id == null) continue;
            final bytes = base64Decode('${e.value}');
            _peaks[id] = Float32List.fromList([for (final b in bytes) b / 255]);
          }
        }
        _ready = true;
        _playing(m);
      case 'playing':
        _playing(m);
      case 'pong':
        final at = _pingAt.remove((m['n'] as num?)?.toInt());
        if (at != null) _rtt = DateTime.now().difference(at);
      case 'lit':
        // The binary lights: the playing list says more, so nothing to do.
        return;
      default:
        return;
    }
    notifyListeners();
  }

  void _playing(Map<String, dynamic> m) {
    _states.clear();
    final now = DateTime.now();
    for (final p in (m['pads'] as List? ?? const [])) {
      if (p is! Map) continue;
      final bank = (p['bank'] as num?)?.toInt(), pad = (p['pad'] as num?)?.toInt();
      if (bank == null || pad == null) continue;
      final wait = (p['wait_ms'] as num?)?.toInt();
      final elapsed = (p['elapsed_ms'] as num?)?.toInt();
      _states[Soundboard.keyOf(bank, pad)] = PadState(
        sounding: elapsed != null,
        firedAt: elapsed == null ? null : now.subtract(Duration(milliseconds: elapsed)),
        length: Duration(milliseconds: (p['len_ms'] as num?)?.toInt() ?? 0),
        waitingUntil: wait == null ? null : now.add(Duration(milliseconds: wait)),
        held: p['held'] == true,
      );
    }
  }

  void _gone() {
    _linked = false;
    notifyListeners();
  }

  // ------------------------------------------------------------------ the face
  @override
  bool get editable => false;

  @override
  PadSpec? pad(int bank, int pad) => doc.pad(bank, pad);

  @override
  PadState stateOf(int bank, int pad) => _states[Soundboard.keyOf(bank, pad)] ?? PadState.quiet;

  @override
  bool get anySounding => _states.values.any((s) => s.sounding);

  @override
  PadSpec? get lastFired {
    String? key;
    DateTime? latest;
    for (final e in _states.entries) {
      final at = e.value.firedAt;
      if (at != null && (latest == null || at.isAfter(latest))) {
        latest = at;
        key = e.key;
      }
    }
    if (key == null) return null;
    final place = Soundboard.placeOf(key);
    return place == null ? null : doc.pad(place.$1, place.$2);
  }

  @override
  Float32List? peaksOf(int sampleId) => _peaks[sampleId];

  @override
  Future<void> press(int bank, int pad) async =>
      _link.send(jsonEncode({'t': 'press', 'bank': bank, 'pad': pad, 'down': true}));

  @override
  Future<void> release(int bank, int pad) async =>
      _link.send(jsonEncode({'t': 'press', 'bank': bank, 'pad': pad, 'down': false}));

  @override
  Future<void> stopAll() async => _link.send(jsonEncode({'t': 'stop'}));

  @override
  Future<void> showBank(int i) async {
    bank = i.clamp(0, doc.banks.length - 1);
    notifyListeners();
    _link.send(jsonEncode({'t': 'bank', 'bank': bank}));
  }

  @override
  Future<void> setLevel(double v) async {
    doc.level = v.clamp(0.0, 1.0);
    notifyListeners();
    _link.send(jsonEncode({'t': 'level', 'v': doc.level}));
  }

  @override
  void dispose() {
    _pinger?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_link.close());
    super.dispose();
  }
}
