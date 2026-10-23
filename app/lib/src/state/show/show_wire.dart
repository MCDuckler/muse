// The show over a wire: the booth's frames and moments sent to a stage in another
// process (or on another machine), and a feed on the far end that reads them.
//
// Frames go at thirty a second as JSON lines; the far end draws at sixty and carries
// the clocks forward between frames (ShowState.advanced), so the picture is smooth
// whatever the wire's jitter. The protocol is the one described in the plan as
// ShowSync, in its first form: whole frames rather than anchors.
//
//   {"t":"hello","v":1}
//   {"t":"state","s":{...}}
//   {"t":"event","e":{...}}
//   {"t":"rules","r":[...],"c":"<combo key>",   the hands' combination rules and the
//    "h":"<figure.shot>"}                       combination on, as they change: what
//                                               the figures' clocks weigh their styles
//                                               and their cameras by (StylePool); and
//                                               a framing the hands hold (a favourite)
//
// And back from the stage, a few times a second: its small picture (binary), and
//   {"t":"now","shots":{...},"type":{...}}     what its figures' cameras and its 3D
//                                               text show (stageNowJson): what a
//                                               favourite keeps
//   {"t":"ping"} / {"t":"pong"}
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'show_events.dart';
import 'show_feed.dart';
import 'show_pool.dart';
import 'show_rig.dart' show Figure;
import 'milk_feed.dart';
import 'show_state.dart';

/// The booth's end: a feed written to one peer.
class ShowWire {
  ShowWire(this.feed, this.say) {
    say(jsonEncode({'t': 'hello', 'v': 1}));
    feed.addListener(_frame);
    _sub = feed.events.listen(_event);
    _frame();
  }

  final ShowFeed feed;
  final void Function(String line) say;
  StreamSubscription<ShowEvent>? _sub;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Thirty frames a second over the wire.
  static const every = Duration(milliseconds: 33);

  void _frame() {
    final now = DateTime.now();
    if (now.difference(_lastAt) < every) return;
    _lastAt = now;
    say(jsonEncode({'t': 'state', 's': feed.state.toJson()}));
    _rules();
  }

  List<ComboRule>? _rulesSent;
  Combo? _comboSent;
  String? _heldSent;
  bool _sentOnce = false;

  /// The rules and the combination on, where they changed (the booth's StylePool: the
  /// engine's, in this process).
  void _rules() {
    final rules = StylePool.pool.rules, combo = StylePool.combo, held = StylePool.heldShot;
    if (_sentOnce && identical(rules, _rulesSent) && combo == _comboSent && held == _heldSent) return;
    _sentOnce = true;
    _rulesSent = rules;
    _comboSent = combo;
    _heldSent = held;
    say(jsonEncode({
      't': 'rules',
      'r': [for (final r in rules) r.toJson()],
      if (combo != null) 'c': combo.key,
      if (held != null) 'h': held,
    }));
  }

  void _event(ShowEvent e) => say(jsonEncode({'t': 'event', 'e': e.toJson()}));

  void close() {
    feed.removeListener(_frame);
    unawaited(_sub?.cancel());
    _sub = null;
  }
}

/// The stage's end: the frames read off the wire, carried forward between them.
class RemoteShowFeed extends ChangeNotifier implements ShowFeed {
  RemoteShowFeed() {
    _state = ShowState(now: DateTime.now(), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));
  }

  late ShowState _state;
  DateTime _heardAt = DateTime.now();
  ShowState? _heard;

  /// The last frame heard, carried forward to now.
  @override
  ShowState get state {
    final h = _heard;
    if (h == null) return _state;
    final dt = DateTime.now().difference(_heardAt).inMicroseconds / 1e6;
    // Carried forward a quarter second at most: past that the wire is gone and the
    // picture should hold rather than run on.
    return dt <= 0 ? h : h.advanced(dt.clamp(0.0, 0.25));
  }

  final _events = StreamController<ShowEvent>.broadcast(sync: true);
  @override
  Stream<ShowEvent> get events => _events.stream;

  bool connected = false;
  DateTime? lastHeard;

  /// A line off the wire.
  void arrived(String line) {
    final Object? j;
    try {
      j = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (j is! Map<String, dynamic>) return;
    lastHeard = DateTime.now();
    switch (j['t']) {
      case 'hello':
        connected = true;
        notifyListeners();
      case 'state':
        final s = j['s'];
        if (s is Map) {
          _heard = ShowState.fromJson(s.cast<String, dynamic>());
          _milk(_heard!);
          _heardAt = DateTime.now();
          _state = _heard!;
          notifyListeners();
        }
      case 'event':
        final e = j['e'];
        if (e is Map) _events.add(ShowEvent.fromJson(e.cast<String, dynamic>()));
      case 'rules':
        final r = j['r'];
        StylePool.from(ShowPool(rules: r is List ? [for (final x in r) ComboRule.fromJson(x)].whereType<ComboRule>().toList() : const []));
        final c = j['c'];
        StylePool.combo = c is String ? Combo.fromKey(c) : null;
        final h = j['h'];
        StylePool.heldShot = h is String ? h : null;
      default:
        break;
    }
  }

  /// MilkDrop here, as there: the numbers and the sound from the frame, the
  /// preset the booth has on (by name, out of the same library).
  void _milk(ShowState st) {
    final milk = MilkFeed.shared;
    if (!milk.running) return;
    milk.director.locked = true;
    milk.tick(st);
    final want = st.macros.milkPreset;
    if (want != null && want != milk.preset?.fullName) {
      final p = milk.library.byName(want);
      if (p != null) milk.load(p);
    }
  }

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

/// What the stage's figures show that is not in the combination, for the booth: the
/// cameras' framings and the 3D text's motion, look and bends (StylePool's).
String stageNowJson() {
  final t = StylePool.typeNow;
  return jsonEncode({
    't': 'now',
    'shots': {for (final e in StylePool.shotNow.entries) e.key.name: e.value},
    if (t != null) 'type': {'motion': t.motion.name, 'look': t.look.name, 'bends': [for (final b in t.bends) b.name]},
  });
}

/// The booth's end of [stageNowJson]: StylePool told what the stage shows. False for
/// any other line.
bool heardStageNow(String line) {
  if (!line.startsWith('{"t":"now"')) return false;
  try {
    final j = jsonDecode(line) as Map<String, dynamic>;
    final shots = j['shots'];
    if (shots is Map) {
      for (final f in Figure.values) {
        final s = shots[f.name];
        if (s is String) StylePool.shotNow[f] = s;
      }
    }
    final t = j['type'];
    if (t is Map) {
      final motion = TypeMotion.values.asNameMap()[t['motion']], look = TypeLook.values.asNameMap()[t['look']];
      final bends = t['bends'];
      if (motion != null && look != null) {
        StylePool.typeNow = (
          motion: motion,
          look: look,
          bends: {if (bends is List) for (final b in TypeDeform.values) if (bends.contains(b.name)) b},
        );
      }
    }
  } catch (_) {}
  return true;
}
