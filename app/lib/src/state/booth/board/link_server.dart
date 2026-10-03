// The desk's end of the link: where phones, tablets and the board's own window
// reach this booth's board.
//
// It is a controller transport (control/transport.dart): each screen that connects
// is a device the ControllerManager connects with the remote layout, so its presses
// go through the one BoothBinding like a knob's would, and show in the monitor. On
// top of that it sends each screen the board itself and what is sounding, which
// are more than lights.
//
// The lines that change the board — a pad set, two swapped, a bank named — are not
// presses: they are made here, on the board itself, before the decoder sees them,
// and the board the change made goes back to every screen as any change does.
//
// Two wires. On a desk a WebSocket server on the local network (link_server_io.dart):
// a press is felt, not posted to another country. Everywhere, the server's relay:
// a screen that cannot reach the desk directly sends its presses through the API,
// and the desk's answers go back the same way (see AppState).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../booth.dart';
import '../control/layout.dart';
import '../control/transport.dart';
import 'link_wire.dart';
import 'pad_spec.dart';
import 'soundboard.dart';

/// One screen on the link.
class LinkPeer extends OpenDevice {
  LinkPeer({required this.key, required this.name, required this.say, required this.onClose});

  final String key;
  final String name;

  /// Sends a line to the screen; null for a relay peer, whose lines go out
  /// through the server (see [BoardLinkBase.snapshots]).
  final void Function(String line)? say;
  final Future<void> Function() onClose;

  /// One listener (the manager's session), and what arrives before it listens is
  /// kept for it: a relay's first press comes with the peer itself.
  final _in = StreamController<Uint8List>();
  bool closed = false;
  DateTime heard = DateTime.now();

  /// Offered each line first: true when it was taken (a change to the board), and
  /// the decoder never sees it.
  bool Function(LinkPeer peer, Map<String, dynamic> line)? onLine;

  /// Whether this screen reaches the desk directly.
  bool get direct => say != null;

  @override
  Stream<Uint8List> get packets => _in.stream;

  /// A line from the screen, as bytes for the decoder.
  void arrived(String line) {
    heard = DateTime.now();
    final take = onLine;
    if (take != null) {
      final m = LinkWire.decode(line);
      if (m != null && take(this, m)) return;
    }
    if (!closed) _in.add(Uint8List.fromList(utf8.encode(line)));
  }

  @override
  Future<void> send(Uint8List bytes) async => say?.call(utf8.decode(bytes));

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _in.close();
    await onClose();
  }
}

/// The link, apart from the wire: the peers, and what is sent to them.
class BoardLinkBase extends ControllerTransport {
  BoardLinkBase({required Booth Function() booth}) : _booth = booth;

  final Booth Function() _booth;
  Soundboard get board => _booth().board;

  final peers = <String, LinkPeer>{};
  final _changes = StreamController<void>.broadcast();

  /// Lines for the relay peers, which the app posts to the server.
  final snapshots = StreamController<String>.broadcast();

  /// Whether the board's look is light, said with the board so a screen matches.
  bool light = false;

  Timer? _playing;
  bool _watching = false;

  @override
  Protocol get protocol => Protocol.remote;

  @override
  bool get available => true;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<FoundDevice>> scan() async => [
        for (final p in peers.values)
          if (!p.closed) FoundDevice(key: p.key, name: p.name, protocol: Protocol.remote, handle: p),
      ];

  @override
  Future<OpenDevice> open(FoundDevice device) async {
    final p = peers[device.key];
    if (p == null || p.closed) throw StateError('${device.name} is gone');
    _watch();
    _sayBoard(p);
    return p;
  }

  /// A screen arrived (over whichever wire).
  void admit(LinkPeer p) {
    p.onLine = _take;
    peers[p.key] = p;
    if (!_changes.isClosed) _changes.add(null);
  }

  void dismiss(String key) {
    final p = peers.remove(key);
    if (p != null && !p.closed) unawaited(p.close());
    if (!_changes.isClosed) _changes.add(null);
    if (peers.isEmpty) _unwatch();
  }

  /// Relay: a screen's lines, arrived through the server. The screen is admitted
  /// on first sight and let go when it has been quiet a while.
  void relayIn(String key, String name, List<dynamic> lines) {
    var p = peers[key];
    if (p == null || p.closed) {
      p = LinkPeer(key: key, name: name, say: null, onClose: () async {});
      admit(p);
    }
    for (final l in lines) {
      if (l is Map) p.arrived(jsonEncode(l));
    }
    _sweep();
  }

  /// Relay peers that have said nothing for a minute are gone.
  void _sweep() {
    final now = DateTime.now();
    for (final p in peers.values.toList()) {
      if (!p.direct && now.difference(p.heard) > const Duration(minutes: 1)) dismiss(p.key);
    }
  }

  bool get anyRelay => peers.values.any((p) => !p.direct && !p.closed);

  // ------------------------------------------------------------------ changes, from a screen
  bool _take(LinkPeer p, Map<String, dynamic> m) {
    if (!LinkWire.edits.contains(m['t'])) return false;
    unawaited(edit(p, m).catchError((Object e) => debugPrint('board link: ${m['t']} — $e')));
    return true;
  }

  /// A screen's change, made on the board: what the board says next carries it back.
  @visibleForTesting
  Future<void> edit(LinkPeer p, Map<String, dynamic> m) async {
    final b = board;
    int? n(String k) => (m[k] as num?)?.toInt();
    bool fits(int? bank, int? pad) =>
        bank != null && pad != null && bank >= 0 && bank < b.doc.banks.length && pad >= 0 && pad < Bank.size;
    (int, int)? at(String k) {
      final v = m[k];
      if (v is! List || v.length != 2 || v[0] is! num || v[1] is! num) return null;
      final place = ((v[0] as num).toInt(), (v[1] as num).toInt());
      return fits(place.$1, place.$2) ? place : null;
    }

    switch (m['t']) {
      case 'pad':
        final bank = n('bank'), pad = n('pad');
        if (!fits(bank, pad)) return;
        final j = m['spec'];
        final spec = j is Map ? PadSpec.fromJson(j.cast<String, dynamic>()) : null;
        if (spec != null && spec.sampleId > 0 && b.library.byId(spec.sampleId) == null) {
          // A sound kept from another screen a moment ago: the library learns it first.
          await b.refreshLibrary();
        }
        await b.setPad(bank!, pad!, spec);
      case 'swap':
        final from = at('from'), to = at('to');
        if (from != null && to != null) await b.swap(from, to);
      case 'bankname':
        final i = n('bank');
        if (i != null && i >= 0 && i < b.doc.banks.length) await b.renameBank(i, '${m['name'] ?? ''}');
      case 'strip':
        final bank = n('bank'), row = n('row');
        await b.setStrip(bank == null || row == null || !fits(bank, row * Bank.across)
            ? null
            : StripSpec(bank: bank, row: row));
      case 'listen':
        final bank = n('bank'), pad = n('pad');
        if (fits(bank, pad)) await b.listen(bank!, pad!);
      case 'quiet':
        final bank = n('bank'), pad = n('pad');
        if (fits(bank, pad)) await b.quiet(bank!, pad!);
      case 'audition':
        final id = n('sample');
        if (id == null) return;
        var s = b.library.byId(id);
        if (s == null) {
          await b.refreshLibrary();
          s = b.library.byId(id);
        }
        if (s != null) await b.audition(s);
      case 'library?':
        // Only a screen on a wire of its own asks: one on the relay has a server.
        if (p.direct) p.say!(LinkWire.encode(LinkWire.libraryMessage(b.library)));
    }
  }

  // ------------------------------------------------------------------ down the wire
  void _watch() {
    if (_watching) return;
    _watching = true;
    board.addListener(_boardChanged);
    _boardChanged();
  }

  void _unwatch() {
    if (!_watching) return;
    _watching = false;
    board.removeListener(_boardChanged);
    _playing?.cancel();
    _playing = null;
  }

  int _rev = -1;
  int _bank = -1;
  double _level = -1;
  bool _light = false;

  void _boardChanged() {
    final b = board;
    if (b.doc.rev != _rev || b.bank != _bank || b.doc.level != _level || light != _light) {
      _rev = b.doc.rev;
      _bank = b.bank;
      _level = b.doc.level;
      _light = light;
      _broadcast(LinkWire.encode(LinkWire.boardMessage(b, light: light)));
    }
    final moving = b.anySounding || _anyWaiting();
    if (moving && _playing == null) {
      _playing = Timer.periodic(const Duration(milliseconds: 100), (_) => _sayPlaying());
      _sayPlaying();
    } else if (!moving && _playing != null) {
      _playing!.cancel();
      _playing = null;
      _sayPlaying();
    }
  }

  bool _anyWaiting() {
    final b = board;
    for (var p = 0; p < 16; p++) {
      if (b.stateOf(b.bank, p).waiting) return true;
    }
    return false;
  }

  void _sayPlaying() => _broadcast(LinkWire.encode(LinkWire.playingMessage(board)));

  void _sayBoard(LinkPeer p) {
    final line = LinkWire.encode(LinkWire.boardMessage(board, light: light));
    if (p.direct) {
      p.say!(line);
    } else if (!snapshots.isClosed) {
      snapshots.add(line);
    }
  }

  void _broadcast(String line) {
    var relay = false;
    for (final p in peers.values) {
      if (p.closed) continue;
      if (p.direct) {
        p.say!(line);
      } else {
        relay = true;
      }
    }
    if (relay && !snapshots.isClosed) snapshots.add(line);
  }

  /// The look changed: every screen follows.
  void setLight(bool on) {
    if (light == on) return;
    light = on;
    if (_watching) _boardChanged();
  }

  /// How a screen finds this desk directly: null where there is no such wire.
  Map<String, dynamic>? get advert => null;

  /// The network can change under a desk: looked at again now and then.
  Future<void> refreshAddresses() async {}

  @override
  Future<void> dispose() async {
    _unwatch();
    for (final p in peers.values.toList()) {
      await p.close();
    }
    peers.clear();
    await _changes.close();
    await snapshots.close();
  }

  @protected
  void changed() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
