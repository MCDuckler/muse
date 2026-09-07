import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../api/client.dart';
import '../api/models.dart';

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

  List<Track> _items = const [];
  int _index = 0;
  int? _queueId;
  int? _loadedTrackId;      // what the audio element actually holds right now
  Timer? _saveCursor;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  String? lastError;

  /// The most recent snapshot, kept so a caller can read state without subscribing.
  PlayerSnapshot? last;

  final _stateController = StreamController<PlayerSnapshot>.broadcast();
  Stream<PlayerSnapshot> get snapshots => _stateController.stream;

  AudioPlayer get raw => _player;
  Track? get current => (_index >= 0 && _index < _items.length) ? _items[_index] : null;
  List<Track> get items => _items;
  int get index => _index;
  bool get isPlaying => _player.playing;

  Future<void> init() async {
    _player.playerStateStream.listen((s) {
      _emit(force: true);
      if (s.processingState == ProcessingState.completed) {
        _onCompleted();
      }
    });
    // Position drives the progress bar. Without emitting here the UI freezes while
    // the audio plays perfectly well, which reads as "playback is broken".
    _player.positionStream.listen((_) {
      _emit();
      _persistCursorSoon();
    });
    _player.playbackEventStream.listen((_) {}, onError: (Object e) {
      lastError = '$e';
      _emit(force: true);
    });
  }

  /// Load a queue and start at its stored cursor, so switching queues resumes.
  /// Load a queue and start at its stored cursor, so switching queues resumes.
  ///
  /// Adding a track re-reads the queue, so this is called constantly while music is
  /// playing. It must therefore leave playback alone unless the audio actually has to
  /// change: reloading the source on every add restarted the song, and adopting the
  /// server's cursor rewound it, since that cursor is only written every few seconds.
  Future<void> loadQueue(Queue queue, {bool autoplay = false}) async {
    final sameQueue = _queueId == queue.id;
    _queueId = queue.id;
    _items = queue.items;

    if (_items.isEmpty) {
      _loadedTrackId = null;
      await _player.stop();
      _emit(force: true);
      return;
    }

    if (sameQueue && _loadedTrackId != null) {
      // Keep playing what is playing; just follow it to its new position in the list.
      final moved = _items.indexWhere((t) => t.id == _loadedTrackId);
      if (moved >= 0) {
        _index = moved;
        _emit(force: true);
        return;
      }
      // The loaded track is gone from the queue: fall through and load the cursor.
    }

    _index = queue.cursorIndex.clamp(0, _items.length - 1);
    await _loadCurrent(startAt: Duration(milliseconds: queue.positionMs));
    if (autoplay) await _player.play();
    _emit(force: true);
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= _items.length) return;
    _index = index;
    if (_loadedTrackId != _items[index].id) await _loadCurrent();
    try {
      await _player.play();
    } catch (e) {
      // Browsers refuse play() outside a user gesture; say so rather than sit silent.
      lastError = '$e';
    }
    _emit(force: true);
  }

  Future<void> _loadCurrent({Duration? startAt}) async {
    final track = current;
    if (track == null) return;
    if (!track.isReady) {
      // Still downloading: hold here rather than skipping past what the user picked.
      _loadedTrackId = null;
      await _player.stop();
      _emit(force: true);
      return;
    }
    lastError = null;
    // A load that fails must say so. Swallowing it leaves a track that looks ready,
    // a play button that does nothing, and no way to tell what went wrong.
    try {
      await api.ensureStreamKey();
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(api.streamUrl(track)),
          // Headers are not deliverable from a browser's audio element, which is why
          // the URL is signed. Native platforms send them too; either proves identity.
          headers: kIsWeb ? null : api.streamHeaders,
          // just_audio_background requires this on every source, and it is also what
          // the lockscreen, the notification and the car display actually show.
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
    if (gain == null || gain >= 0) return 1.0;   // never boost into clipping
    return math.pow(10, gain / 20).toDouble().clamp(0.05, 1.0);
  }

  Future<void> playPause() async {
    try {
      if (_player.playing) {
        await _player.pause();
      } else {
        if (_loadedTrackId == null) await _loadCurrent();
        await _player.play();
      }
    } catch (e) {
      lastError = '$e';
    }
    _emit(force: true);
  }

  Future<void> next() async {
    if (_index + 1 < _items.length) await playAt(_index + 1);
  }

  Future<void> previous() async {
    // Same convention every player uses: restart the track first, then step back.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
    } else if (_index > 0) {
      await playAt(_index - 1);
    }
  }

  Future<void> seek(Duration to) => _player.seek(to);

  void _onCompleted() {
    final finished = current;
    if (finished != null) {
      api
          .recordListen(finished.id, _player.position.inMilliseconds, true)
          .catchError((_) {});
    }
    next();
  }

  /// The cursor is written back at most once every few seconds — it changes on every
  /// frame and the server does not version it, so there is nothing to race with.
  void _persistCursorSoon() {
    if (_queueId == null) return;
    _saveCursor?.cancel();
    _saveCursor = Timer(const Duration(seconds: 5), () {
      api
          .setCursor(_queueId!, index: _index, positionMs: _player.position.inMilliseconds)
          .catchError((_) {});
    });
  }

  /// A track that finished downloading while it sat in the queue becomes playable
  /// without the user doing anything.
  void onTrackReady(int trackId) async {
    final i = _items.indexWhere((t) => t.id == trackId);
    if (i < 0) return;
    final fresh = await api.track(trackId);
    _items = [..._items]..[i] = fresh;
    // Only touch the audio when the thing that just became playable is the thing the
    // player is stuck on. Anything else would interrupt what is already playing.
    if (i == _index && _loadedTrackId != trackId) await _loadCurrent();
    _emit(force: true);
  }

  /// Position ticks arrive several times a second; the UI does not need all of them.
  void _emit({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastEmit).inMilliseconds < 250) return;
    _lastEmit = now;
    last = PlayerSnapshot(
        current: current,
        index: _index,
        playing: _player.playing,
        position: _player.position,
        duration: _player.duration,
        itemCount: _items.length,
        error: lastError,
    );
    _stateController.add(last!);
  }

  Future<void> dispose() async {
    _saveCursor?.cancel();
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
  final int itemCount;
  final String? error;

  const PlayerSnapshot({
    required this.current,
    required this.index,
    required this.playing,
    required this.position,
    required this.duration,
    required this.itemCount,
    this.error,
  });
}
