import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../api/client.dart';
import '../api/models.dart';

enum QueueRepeat { off, one, all }

QueueRepeat queueRepeatFrom(String s) => switch (s) {
      'one' => QueueRepeat.one,
      'all' => QueueRepeat.all,
      _ => QueueRepeat.off,
    };

String queueRepeatTo(QueueRepeat m) => m.name;

/// Wraps just_audio so the rest of the app never learns where a track comes from.
///
/// Loudness: the server measures each track and stores `gain_db` against -14 LUFS.
/// A player can only attenuate (volume caps at 1.0), so positive gain on a quiet
/// track is deliberately ignored: everything is pulled DOWN to the quietest common
/// level instead of pushed up into clipping. That is the same choice ReplayGain's
/// clipping prevention makes.
class PlayerService {
  PlayerService(this.api);

  final ApiClient api;
  final AudioPlayer _player = AudioPlayer();

  /// How often the play position is written back while audio is playing. This used to
  /// be a debounce re-armed on every position tick, which meant it never fired at all
  /// during playback — closing the tab mid-song simply lost your place.
  static const cursorInterval = Duration(seconds: 10);

  /// Counts as a real listen rather than a skip.
  static const _completedFraction = 0.9;

  List<Track> _items = const [];
  List<int> _order = const [];   // positions into _items, in play order
  int _orderPos = 0;
  int? _queueId;
  int? _loadedTrackId;
  int? _waitingForTrack;         // stalled on a download; resume when it lands

  QueueRepeat repeat = QueueRepeat.off;
  bool shuffle = false;

  /// Separate from the per-track loudness gain: that normalises tracks against each
  /// other, this is the listener turning it down. They multiply.
  double userVolume = 1.0;

  Timer? _cursorTimer;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  String? lastError;
  bool finished = false;         // queue ran out with repeat off

  PlayerSnapshot? last;

  final _stateController = StreamController<PlayerSnapshot>.broadcast();
  Stream<PlayerSnapshot> get snapshots => _stateController.stream;

  /// Fired when the player changes the queue's settings or order itself, so the app
  /// can persist them without the player knowing about the API.
  void Function(int queueId, {int? cursorIndex, int? positionMs})? onCursor;

  AudioPlayer get raw => _player;
  List<Track> get items => _items;
  int get index => _orderPos < _order.length ? _order[_orderPos] : 0;
  Track? get current => (index >= 0 && index < _items.length) ? _items[index] : null;
  bool get isPlaying => _player.playing;
  int? get waitingForTrack => _waitingForTrack;

  Future<void> init() async {
    _player.playerStateStream.listen((s) {
      _emit(force: true);
      if (s.processingState == ProcessingState.completed) _onCompleted();
      if (!s.playing) _saveCursor();      // pausing is a good moment to remember
    });
    _player.positionStream.listen((_) => _emit());
    _player.playbackEventStream.listen((_) {}, onError: (Object e) {
      lastError = '$e';
      _emit(force: true);
    });
    _cursorTimer = Timer.periodic(cursorInterval, (_) {
      if (_player.playing) _saveCursor();
    });
  }

  // ------------------------------------------------------------------ queue
  /// Load a queue and start at its stored cursor, so switching queues resumes.
  ///
  /// Adding a track re-reads the queue, so this is called constantly while music is
  /// playing. It must leave playback alone unless the audio actually has to change.
  Future<void> loadQueue(Queue queue, {bool autoplay = false}) async {
    final sameQueue = _queueId == queue.id;
    _queueId = queue.id;
    _items = queue.items;
    if (!sameQueue) {
      repeat = queueRepeatFrom(queue.repeat);
      shuffle = queue.shuffle;
    }

    if (_items.isEmpty) {
      _order = const [];
      _orderPos = 0;
      _loadedTrackId = null;
      await _player.stop();
      _emit(force: true);
      return;
    }

    if (sameQueue && _loadedTrackId != null) {
      final moved = _items.indexWhere((t) => t.id == _loadedTrackId);
      if (moved >= 0) {
        _rebuildOrder(keepItemIndex: moved);
        // A track we were stalled on may have arrived with this update.
        if (_waitingForTrack != null) await _resumeIfPossible();
        _emit(force: true);
        return;
      }
    }

    _rebuildOrder(keepItemIndex: queue.cursorIndex.clamp(0, _items.length - 1));
    await _loadCurrent(startAt: Duration(milliseconds: queue.positionMs));
    if (autoplay) _startPlayback();
    _emit(force: true);
  }

  /// Play order is a list of indices, so shuffle is a stable reordering rather than a
  /// random pick each time — which is what makes "previous" mean anything.
  void _rebuildOrder({required int keepItemIndex}) {
    final all = List<int>.generate(_items.length, (i) => i);
    if (shuffle) {
      all.remove(keepItemIndex);
      all.shuffle(math.Random());
      all.insert(0, keepItemIndex);
      _order = all;
      _orderPos = 0;
    } else {
      _order = all;
      _orderPos = keepItemIndex.clamp(0, _items.length - 1);
    }
  }

  Future<void> setShuffle(bool value) async {
    if (shuffle == value) return;
    shuffle = value;
    _rebuildOrder(keepItemIndex: index);
    _emit(force: true);
  }

  void setRepeat(QueueRepeat mode) {
    repeat = mode;
    finished = false;
    _emit(force: true);
  }

  // ------------------------------------------------------------------ playback
  Future<void> playAt(int itemIndex) async {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final pos = _order.indexOf(itemIndex);
    if (pos < 0) return;
    await _playOrderPos(pos);
  }

  Future<void> _playOrderPos(int pos, {Duration? startAt}) async {
    _recordListen();                       // whatever we were on, log it before moving
    _orderPos = pos;
    finished = false;
    final track = current;
    if (track == null) return;
    if (_loadedTrackId != track.id) {
      await _loadCurrent(startAt: startAt);
    }
    if (_waitingForTrack == null) _startPlayback();
    _emit(force: true);
    _saveCursor();
  }

  /// Deliberately not awaited: just_audio's play() future completes when playback
  /// *stops*, so awaiting it would defer everything after it to the end of the song
  /// and leave an error handler open for the whole track.
  void _startPlayback() {
    unawaited(_player.play().catchError((Object e) {
      lastError = '$e';
      _emit(force: true);
    }));
  }

  Future<void> playPause() async {
    try {
      if (_player.playing) {
        await _player.pause();
        _saveCursor();
      } else {
        if (_loadedTrackId == null) await _loadCurrent();
        _startPlayback();
      }
    } catch (e) {
      lastError = '$e';
    }
    _emit(force: true);
  }

  Future<void> next() => _advance(1);

  Future<void> previous() async {
    // Restart the track first, then step back — the convention every player uses.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    await _advance(-1);
  }

  /// Move through the queue, honouring repeat and stepping over tracks that are not
  /// downloaded yet instead of stopping dead on them.
  Future<void> _advance(int direction, {bool auto = false}) async {
    if (_order.isEmpty) return;
    if (auto && repeat == QueueRepeat.one) {
      await _player.seek(Duration.zero);
      _startPlayback();
      return;
    }

    var pos = _orderPos;
    for (var step = 0; step < _order.length; step++) {
      pos += direction;
      if (pos >= _order.length) {
        if (repeat == QueueRepeat.all) {
          pos = 0;
        } else {
          await _finish();
          return;
        }
      } else if (pos < 0) {
        if (repeat == QueueRepeat.all) {
          pos = _order.length - 1;
        } else {
          return;                        // already at the top; stay put
        }
      }
      final candidate = _items[_order[pos]];
      if (candidate.isReady) {
        await _playOrderPos(pos);
        return;
      }
      // Not ready: remember it, keep looking for something that is.
      _waitingForTrack ??= candidate.id;
    }

    // Nothing in the queue is playable yet: wait rather than pretend it ended.
    _orderPos = pos.clamp(0, _order.length - 1);
    await _player.stop();
    _loadedTrackId = null;
    _emit(force: true);
  }

  Future<void> _finish() async {
    _recordListen();
    finished = true;
    await _player.stop();
    _emit(force: true);
  }

  Future<void> seek(Duration to) async {
    await _player.seek(to);
    _saveCursor();
  }

  Future<void> _loadCurrent({Duration? startAt}) async {
    final track = current;
    if (track == null) return;
    if (!track.isReady) {
      // Hold here rather than skipping past what the user picked, but remember it so
      // the track_ready event can start it.
      _waitingForTrack = track.id;
      _loadedTrackId = null;
      await _player.stop();
      _emit(force: true);
      return;
    }
    _waitingForTrack = null;
    lastError = null;
    try {
      await api.ensureStreamKey();
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(api.streamUrl(track)),
          // Headers are not deliverable from a browser's audio element, which is why
          // the URL is signed. Native platforms send them too; either proves identity.
          headers: kIsWeb ? null : api.streamHeaders,
          // just_audio_background requires this on every source, and it is what the
          // lockscreen, the notification and the car display actually show.
          tag: MediaItem(
            id: '${track.id}',
            title: track.title,
            artist: track.artistLine,
            album: track.album,
            duration: track.duration,
          ),
        ),
        initialPosition: startAt,
      );
      await _player.setVolume(_volumeFor(track));
      _loadedTrackId = track.id;
    } catch (e) {
      _loadedTrackId = null;
      lastError = 'Could not load "${track.title}": $e';
      _emit(force: true);
      rethrow;
    }
  }

  double _volumeFor(Track t) {
    final gain = t.gainDb;
    final normalised = (gain == null || gain >= 0)
        ? 1.0                                     // never boost into clipping
        : math.pow(10, gain / 20).toDouble().clamp(0.05, 1.0);
    return (normalised * userVolume).clamp(0.0, 1.0);
  }

  Future<void> setUserVolume(double v) async {
    userVolume = v.clamp(0.0, 1.0);
    final t = current;
    if (t != null) await _player.setVolume(_volumeFor(t));
    _emit(force: true);
  }

  /// Seek relative to where we are, for keyboard and headset controls.
  Future<void> nudge(Duration by) async {
    final target = _player.position + by;
    final max = _player.duration ?? Duration.zero;
    await seek(target < Duration.zero
        ? Duration.zero
        : (max > Duration.zero && target > max ? max : target));
  }

  void _onCompleted() {
    _recordListen(completed: true);
    _advance(1, auto: true);
  }

  /// A track that finished downloading becomes playable without the user doing
  /// anything — and if the player was stalled waiting for it, it starts.
  Future<void> onTrackReady(int trackId) async {
    final i = _items.indexWhere((t) => t.id == trackId);
    if (i < 0) return;
    final fresh = await api.track(trackId);
    _items = [..._items]..[i] = fresh;
    if (_waitingForTrack != null) {
      await _resumeIfPossible();
    } else if (i == index && _loadedTrackId != trackId) {
      await _loadCurrent();
    }
    _emit(force: true);
  }

  Future<void> _resumeIfPossible() async {
    final waitingPos = _order.indexWhere((i) => _items[i].id == _waitingForTrack);
    final target = waitingPos >= 0 ? waitingPos : _orderPos;
    if (target >= _order.length) return;
    if (!_items[_order[target]].isReady) return;
    _waitingForTrack = null;
    await _playOrderPos(target);
  }

  // ------------------------------------------------------------------ bookkeeping
  /// Recorded on every track change, not only on natural completion — otherwise
  /// everything you skip past is invisible to history and stats.
  void _recordListen({bool completed = false}) {
    final track = current;
    final played = _player.position.inMilliseconds;
    if (track == null || _loadedTrackId != track.id) return;
    if (!completed && played < 3000) return;      // a glance, not a listen
    final total = track.durationMs ?? 0;
    final done = completed ||
        (total > 0 && played / total >= _completedFraction);
    api.recordListen(track.id, played, done).catchError((_) {});
  }

  void _saveCursor() {
    final qid = _queueId;
    if (qid == null) return;
    onCursor?.call(qid,
        cursorIndex: index, positionMs: _player.position.inMilliseconds);
  }

  void _emit({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastEmit).inMilliseconds < 250) return;
    _lastEmit = now;
    last = PlayerSnapshot(
      current: current,
      index: index,
      playing: _player.playing,
      position: _player.position,
      duration: _player.duration ?? current?.duration,
      buffered: _player.bufferedPosition,
      itemCount: _items.length,
      error: lastError,
      repeat: repeat,
      shuffle: shuffle,
      waitingForDownload: _waitingForTrack != null,
      finished: finished,
    );
    _stateController.add(last!);
  }

  Future<void> dispose() async {
    _cursorTimer?.cancel();
    _saveCursor();
    await _player.dispose();
    await _stateController.close();
  }
}

class PlayerSnapshot {
  final Track? current;
  final int index;
  final bool playing;
  final Duration position;
  final Duration? duration;
  final Duration buffered;
  final int itemCount;
  final String? error;
  final QueueRepeat repeat;
  final bool shuffle;
  final bool waitingForDownload;
  final bool finished;

  const PlayerSnapshot({
    required this.current,
    required this.index,
    required this.playing,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    required this.itemCount,
    this.error,
    this.repeat = QueueRepeat.off,
    this.shuffle = false,
    this.waitingForDownload = false,
    this.finished = false,
  });

  double get progress {
    final d = duration?.inMilliseconds ?? 0;
    if (d <= 0) return 0;
    return (position.inMilliseconds / d).clamp(0.0, 1.0);
  }
}
