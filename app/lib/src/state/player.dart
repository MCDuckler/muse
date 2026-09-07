import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';

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
  Timer? _saveCursor;

  final _stateController = StreamController<PlayerSnapshot>.broadcast();
  Stream<PlayerSnapshot> get snapshots => _stateController.stream;

  AudioPlayer get raw => _player;
  Track? get current => (_index >= 0 && _index < _items.length) ? _items[_index] : null;
  List<Track> get items => _items;
  int get index => _index;
  bool get isPlaying => _player.playing;

  Future<void> init() async {
    _player.playerStateStream.listen((s) {
      _emit();
      if (s.processingState == ProcessingState.completed) {
        _onCompleted();
      }
    });
    _player.positionStream.listen((_) => _persistCursorSoon());
  }

  /// Load a queue and start at its stored cursor, so switching queues resumes.
  Future<void> loadQueue(Queue queue, {bool autoplay = false}) async {
    _queueId = queue.id;
    _items = queue.items;
    _index = queue.cursorIndex.clamp(0, math.max(_items.length - 1, 0));
    if (_items.isEmpty) {
      await _player.stop();
      _emit();
      return;
    }
    await _loadCurrent(startAt: Duration(milliseconds: queue.positionMs));
    if (autoplay) await _player.play();
    _emit();
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= _items.length) return;
    _index = index;
    await _loadCurrent();
    await _player.play();
    _emit();
  }

  Future<void> _loadCurrent({Duration? startAt}) async {
    final track = current;
    if (track == null) return;
    if (!track.isReady) {
      // Still downloading: hold here rather than skipping past what the user picked.
      await _player.stop();
      _emit();
      return;
    }
    await api.ensureStreamKey();
    await _player.setAudioSource(
      AudioSource.uri(
        Uri.parse(api.streamUrl(track)),
        // Headers are not deliverable from a browser's audio element, which is why
        // the URL is signed. Native platforms send them too; either proves identity.
        headers: kIsWeb ? null : api.streamHeaders,
      ),
      initialPosition: startAt,
    );
    await _player.setVolume(_volumeFor(track));
  }

  double _volumeFor(Track t) {
    final gain = t.gainDb;
    if (gain == null || gain >= 0) return 1.0;   // never boost into clipping
    return math.pow(10, gain / 20).toDouble().clamp(0.05, 1.0);
  }

  Future<void> playPause() async {
    _player.playing ? await _player.pause() : await _player.play();
    _emit();
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
    if (i == _index && !_player.playing) await _loadCurrent();
    _emit();
  }

  void _emit() => _stateController.add(PlayerSnapshot(
        current: current,
        index: _index,
        playing: _player.playing,
        position: _player.position,
        duration: _player.duration,
        itemCount: _items.length,
      ));

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

  const PlayerSnapshot({
    required this.current,
    required this.index,
    required this.playing,
    required this.position,
    required this.duration,
    required this.itemCount,
  });
}
