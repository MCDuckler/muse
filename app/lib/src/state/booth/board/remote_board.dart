// A desk's board, on this screen: the same pads, drawn from what the desk says and
// pressed back to it.
//
// Direct where it can be (a WebSocket to the desk on the same network, a few
// milliseconds), through the server's relay where it cannot (the SSE stream down,
// a POST up, a few hundred). The screen never makes a sound of its own; what it
// shows is what the desk said, and the sweep across a pad is this screen's clock
// carrying on from how far along the desk said the sound was.
//
// It changes the board too, where the desk takes changes over the wire (it says so
// with the board): a change shows here at once and is said to the desk, whose board
// — when it comes back — is the word on it. The sounds to pick from come from this
// screen's own server where it has one (a phone, signed in), else from the desk
// (the board's own window).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import 'board_face.dart';
import 'link_wire.dart';
import 'pad_spec.dart';
import 'remote_link_none.dart' if (dart.library.io) 'remote_link_io.dart' as lan;
import 'samples.dart';
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
  RemoteBoard._(this.desk, this._link, {this.api}) {
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
    ApiClient? api,
  }) async {
    final advert = desk.boardLink;
    if (advert != null) {
      final direct = await lan.connectLan(advert, name: myName);
      if (direct != null) return RemoteBoard._(desk, direct, api: api);
    }
    return RemoteBoard._(desk, relay(), api: api);
  }

  /// Over a link already made: the board's own window, given the desk's url.
  factory RemoteBoard.over(DeviceInfo desk, RemoteLink link, {ApiClient? api}) => RemoteBoard._(desk, link, api: api);

  final DeviceInfo desk;

  /// This screen's own way to the server, where it has one: the library is asked of
  /// it, and a sound can be kept from here. Null in the board's own window, which
  /// asks the desk.
  final ApiClient? api;

  /// Whether the desk takes the board's changes over the wire (it says so with the
  /// board; a desk from before that is played, not changed).
  bool _edits = false;
  bool _libraryAsked = false;

  @override
  final library = SampleLibrary();
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
        _edits = m['edits'] != null;
        _playing(m);
        if (_edits && !_libraryAsked) {
          _libraryAsked = true;
          unawaited(refreshLibrary());
        }
      case 'library':
        library
          ..takeServerList([for (final j in (m['own'] as List? ?? const [])) (j as Map).cast<String, dynamic>()])
          ..takeHouseList([for (final j in (m['house'] as List? ?? const [])) (j as Map).cast<String, dynamic>()]);
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
  bool get editable => _edits;

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
  Float32List? peaksOf(int sampleId) => _peaks[sampleId] ?? library.peaks[sampleId];

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

  // ------------------------------------------------------------------ changing it
  void _say(Map<String, dynamic> m) => _link.send(jsonEncode(m));

  @override
  Future<void> setPad(int bank, int pad, PadSpec? spec) async {
    if (bank < 0 || bank >= doc.banks.length || pad < 0 || pad >= Bank.size) return;
    doc.banks[bank].pads[pad] = spec;
    notifyListeners();
    _say({'t': 'pad', 'bank': bank, 'pad': pad, 'spec': spec?.toJson()});
  }

  @override
  Future<void> swap((int, int) from, (int, int) to) async {
    final a = doc.pad(from.$1, from.$2), b = doc.pad(to.$1, to.$2);
    if (a == null && b == null) return;
    doc.banks[from.$1].pads[from.$2] = b;
    doc.banks[to.$1].pads[to.$2] = a;
    notifyListeners();
    _say({'t': 'swap', 'from': [from.$1, from.$2], 'to': [to.$1, to.$2]});
  }

  @override
  Future<void> renameBank(int i, String name) async {
    if (i < 0 || i >= doc.banks.length) return;
    doc.banks[i].name = name.trim().isEmpty ? BoardDoc.bankNames[i] : name.trim();
    notifyListeners();
    _say({'t': 'bankname', 'bank': i, 'name': name});
  }

  @override
  Future<void> setStrip(StripSpec? strip) async {
    doc.strip = strip;
    notifyListeners();
    _say({'t': 'strip', if (strip != null) ...{'bank': strip.bank, 'row': strip.row}});
  }

  @override
  Future<void> listen(int bank, int pad) async => _say({'t': 'listen', 'bank': bank, 'pad': pad});

  @override
  Future<void> quiet(int bank, int pad) async => _say({'t': 'quiet', 'bank': bank, 'pad': pad});

  // ------------------------------------------------------------------ the sounds
  @override
  bool get hasServer => api?.token != null;

  @override
  Future<void> refreshLibrary() async {
    final a = api;
    if (a == null || a.token == null) {
      _say({'t': 'library?'});
      return;
    }
    try {
      final shelves = await a.sampleShelves();
      library
        ..takeServerList(shelves.own)
        ..takeHouseList(shelves.house);
      notifyListeners();
    } catch (e) {
      debugPrint('remote board: the library did not come — $e');
    }
  }

  /// Heard on the desk: this screen never makes a sound of its own.
  @override
  Future<void> audition(Sample sample) async => _say({'t': 'audition', 'sample': sample.id});

  @override
  Future<Sample> importBytes(String filename, List<int> bytes, {String? name}) async {
    final a = api;
    if (a == null || a.token == null) throw StateError('No server on this screen to keep it on');
    final j = await a.uploadSample(bytes, filename, name: name);
    await refreshLibrary();
    return library.byId((j['id'] as num).toInt()) ?? SampleLibrary.fromServer(j);
  }

  @override
  Future<void> renameSample(Sample s, String name) async {
    await api?.renameSample(s.id, name);
    await refreshLibrary();
  }

  /// Off every pad that holds it, then off the server.
  @override
  Future<void> forgetSample(Sample s) async {
    for (final p in doc.allPads.toList()) {
      if (p.spec.sampleId == s.id) await setPad(p.bank, p.pad, null);
    }
    await api?.deleteSample(s.id);
    await refreshLibrary();
  }

  @override
  void dispose() {
    _pinger?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_link.close());
    super.dispose();
  }
}
