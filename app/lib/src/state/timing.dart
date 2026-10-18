import 'dart:async';

import '../api/client.dart';
import '../api/models.dart';

/// The timings that have been asked for, so each is asked for once.
///
/// The player wants the *next* song's before it is needed — where its sound starts has
/// to be known at the moment it begins, not a request later — so it asks ahead, and by
/// the time the song comes round the answer is here.
class TimingStore {
  TimingStore(this._api, {this.busyWait = const Duration(seconds: 10)});

  final ApiClient _api;
  final _known = <int, TrackTiming?>{};
  final _asking = <int, Future<TrackTiming?>>{};

  /// What is already here, without asking.
  TrackTiming? peek(int trackId) => _known[trackId];

  /// An answer from elsewhere — a test, a mix that carried its own — kept as if asked.
  void put(int trackId, TrackTiming timing) => _known[trackId] = timing;

  /// Asked again next time: the house has more on this record now (its parts, the
  /// tracker's beats), and the structure it builds from them.
  void forget(int trackId) => _known.remove(trackId);

  Future<TrackTiming?> of(Track track) {
    if (!track.isReady) return Future.value(null);
    if (_known.containsKey(track.id)) return Future.value(_known[track.id]);
    return _asking[track.id] ??= _ask(track.id);
  }

  Future<TrackTiming?> _ask(int id) async {
    try {
      final found = await _api.timing(id);
      _known[id] = found;
      return found;
    } catch (_) {
      // No connection, a server from before this, a file it could not read: the song
      // plays as it always did. Not remembered as a no, so it is asked again next time.
      return null;
    } finally {
      _asking.remove(id);
    }
  }

  /// The same, for something that can wait — a crate showing how well each record
  /// follows the one on: asked [_lane] at a time, and asked again a little later
  /// where the house said it was busy. A crate asked for all its records at once,
  /// and a record the house had not yet measured by its current reading is seconds
  /// of work in one of two turns: most were told to come back, never were, and the
  /// crate had no tempo or key on them. A deck's record ([of]) never waits behind these.
  Future<TrackTiming?> later(Track track) {
    if (!track.isReady) return Future.value(null);
    if (_known.containsKey(track.id)) return Future.value(_known[track.id]);
    final asking = _asking[track.id];
    if (asking != null) return asking;
    return _waiting[track.id] ??= () async {
      try {
        for (var tries = 0; tries < 4; tries++) {
          while (_inLane >= _lane) {
            await (_laneFree ??= Completer<void>()).future;
          }
          if (_known.containsKey(track.id)) return _known[track.id];
          _inLane++;
          try {
            final found = await _api.timing(track.id);
            _known[track.id] = found;
            return found;
          } on ApiException catch (e) {
            if (e.status != 503) return null;
          } catch (_) {
            return null;
          } finally {
            _inLane--;
            final free = _laneFree;
            _laneFree = null;
            free?.complete();
          }
          // Busy measuring: its Retry-After is ten seconds.
          await Future<void>.delayed(busyWait * (tries + 1));
        }
        return null;
      } finally {
        _waiting.remove(track.id);
      }
    }();
  }

  /// How long [later] leaves the house to measure before asking again, the first time.
  final Duration busyWait;
  static const _lane = 2;
  int _inLane = 0;
  Completer<void>? _laneFree;
  final _waiting = <int, Future<TrackTiming?>>{};
}

/// Each record's tempo and key as the house has them on file, for a crate: the records
/// asked for in the same moment go in one ask (/booth/traits), not one ask a record.
class FactsStore {
  FactsStore(this._api);
  final ApiClient _api;
  final _known = <int, (TrackFacts?, DateTime)>{};
  final _wanted = <int, Completer<TrackFacts?>>{};
  Timer? _soon;

  TrackFacts? peek(int trackId) => _known[trackId]?.$1;

  Future<TrackFacts?> of(Track track) {
    final have = _known[track.id];
    // One the house had not measured yet is asked again a couple of minutes on.
    if (have != null &&
        (have.$1 != null || DateTime.now().difference(have.$2) < const Duration(minutes: 2))) {
      return Future.value(have.$1);
    }
    final c = _wanted.putIfAbsent(track.id, Completer<TrackFacts?>.new);
    _soon ??= Timer(const Duration(milliseconds: 30), _ask);
    return c.future;
  }

  Future<void> _ask() async {
    _soon = null;
    final asked = Map.of(_wanted);
    _wanted.clear();
    final ids = asked.keys.toList();
    for (var i = 0; i < ids.length; i += 500) {
      final part = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      Map<int, TrackFacts>? got;
      try {
        got = await _api.facts(part);
      } catch (_) {
        // The house could not say (busy, or away): remembered as nothing, like a
        // record it has not measured, and asked again a couple of minutes on — not on
        // the next rebuild, which comes every tick and would ask every 30 ms.
        got = null;
      }
      final now = DateTime.now();
      for (final id in part) {
        final f = got?[id];
        _known[id] = (f, now);
        asked[id]!.complete(f);
      }
    }
  }
}

/// The voice of each record, asked for once — and again, a minute on, while the house
/// is still working it out (the record not yet in parts, the words not yet fetched).
class VocalStore {
  VocalStore(this._api);
  final ApiClient _api;
  final _known = <int, (VocalMap, DateTime)>{};
  final _asking = <int, Future<VocalMap?>>{};

  VocalMap? peek(int trackId) => _known[trackId]?.$1;

  Future<VocalMap?> of(Track track) {
    final have = _known[track.id];
    if (have != null &&
        (have.$1.complete || DateTime.now().difference(have.$2) < const Duration(minutes: 1))) {
      return Future.value(have.$1);
    }
    return _asking[track.id] ??= () async {
      try {
        final v = await _api.vocals(track.id);
        _known[track.id] = (v, DateTime.now());
        return v;
      } catch (_) {
        return have?.$1;
      } finally {
        _asking.remove(track.id);
      }
    }();
  }
}
