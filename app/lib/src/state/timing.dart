import 'dart:async';

import '../api/client.dart';
import '../api/models.dart';

/// The timings that have been asked for, so each is asked for once.
///
/// The player wants the *next* song's before it is needed — where its sound starts has
/// to be known at the moment it begins, not a request later — so it asks ahead, and by
/// the time the song comes round the answer is here.
class TimingStore {
  TimingStore(this._api);

  final ApiClient _api;
  final _known = <int, TrackTiming?>{};
  final _asking = <int, Future<TrackTiming?>>{};

  /// What is already here, without asking.
  TrackTiming? peek(int trackId) => _known[trackId];

  /// An answer from elsewhere — a test, a mix that carried its own — kept as if asked.
  void put(int trackId, TrackTiming timing) => _known[trackId] = timing;

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
}
