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
//   {"t":"ping"} / {"t":"pong"}
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'show_events.dart';
import 'show_feed.dart';
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
          _heardAt = DateTime.now();
          _state = _heard!;
          notifyListeners();
        }
      case 'event':
        final e = j['e'];
        if (e is Map) _events.add(ShowEvent.fromJson(e.cast<String, dynamic>()));
      default:
        break;
    }
  }

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}
