// A show written down, and played back.
//
// The recorder listens to a feed and writes a line per frame (at most twenty-five a
// second — the stage draws sixty, but a scene can be judged at twenty-five and the
// file is a quarter the size) and a line per event, each stamped with the
// milliseconds since the recording began. The replay reads those lines back as a
// feed of its own, at the pace they were written, so a scene can be worked on, on a
// train, against a set that happened last night — and a two-hour soak needs no DJ.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'show_events.dart';
import 'show_feed.dart';
import 'show_state.dart';

class ShowRecorder {
  ShowRecorder(this.feed, this.write) {
    _began = DateTime.now();
    feed.addListener(_frame);
    _sub = feed.events.listen(_event);
    write(jsonEncode({'v': 1, 'began': _began.millisecondsSinceEpoch}));
  }

  final ShowFeed feed;

  /// One line out.
  final void Function(String line) write;
  late final DateTime _began;
  StreamSubscription<ShowEvent>? _sub;
  int _lastFrameMs = -1000;
  int frames = 0, events = 0;

  static const _everyMs = 40;

  int get _t => DateTime.now().difference(_began).inMilliseconds;

  void _frame() {
    final t = _t;
    if (t - _lastFrameMs < _everyMs) return;
    _lastFrameMs = t;
    frames++;
    write(jsonEncode({'t': t, 'state': feed.state.toJson()}));
  }

  void _event(ShowEvent e) {
    events++;
    write(jsonEncode({'t': _t, 'event': e.toJson()}));
  }

  void stop() {
    feed.removeListener(_frame);
    unawaited(_sub?.cancel());
    _sub = null;
  }
}

/// A recording as a feed: the frames and the events, at the pace they were kept.
class ShowReplay extends ChangeNotifier implements ShowFeed {
  ShowReplay(Iterable<String> lines) {
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final j = jsonDecode(line);
      if (j is! Map<String, dynamic>) continue;
      final t = (j['t'] as num?)?.toInt();
      if (t == null) continue;
      if (j['state'] is Map) {
        _frames.add((t, ShowState.fromJson((j['state'] as Map).cast())));
      } else if (j['event'] is Map) {
        _moments.add((t, ShowEvent.fromJson((j['event'] as Map).cast())));
      }
    }
    _state = _frames.isEmpty
        ? ShowState(now: DateTime.now(), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'))
        : _frames.first.$2;
  }

  final _frames = <(int, ShowState)>[];
  final _moments = <(int, ShowEvent)>[];
  late ShowState _state;
  @override
  ShowState get state => _state;

  final _events = StreamController<ShowEvent>.broadcast(sync: true);
  @override
  Stream<ShowEvent> get events => _events.stream;

  int get frameCount => _frames.length;
  Duration get length => _frames.isEmpty ? Duration.zero : Duration(milliseconds: _frames.last.$1);

  Timer? _timer;
  DateTime? _began;
  int _nextFrame = 0, _nextMoment = 0;
  bool loop = true;

  bool get playing => _timer != null;

  void play() {
    if (_frames.isEmpty || _timer != null) return;
    _began = DateTime.now();
    _nextFrame = _nextMoment = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _step());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Everything up to [elapsed] since play, handed on. Public for a test.
  void advanceTo(Duration elapsed) {
    final t = elapsed.inMilliseconds;
    var moved = false;
    while (_nextFrame < _frames.length && _frames[_nextFrame].$1 <= t) {
      _state = _frames[_nextFrame].$2;
      _nextFrame++;
      moved = true;
    }
    if (moved) notifyListeners();
    while (_nextMoment < _moments.length && _moments[_nextMoment].$1 <= t) {
      _events.add(_moments[_nextMoment].$2);
      _nextMoment++;
    }
    if (_nextFrame >= _frames.length && _nextMoment >= _moments.length) {
      if (loop && _timer != null) {
        _began = DateTime.now();
        _nextFrame = _nextMoment = 0;
      } else {
        stop();
      }
    }
  }

  void _step() {
    final began = _began;
    if (began == null) return;
    advanceTo(DateTime.now().difference(began));
  }

  @override
  void dispose() {
    stop();
    unawaited(_events.close());
    super.dispose();
  }
}
