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
  PlayerService(this.api) : _instance = ++instances;

  final ApiClient api;
  final int _instance;
  final AudioPlayer _player = AudioPlayer();

  /// How often the play position is written back while audio is playing. This used to
  /// be a debounce re-armed on every position tick, which meant it never fired at all
  /// during playback — closing the tab mid-song simply lost your place.
  static const cursorInterval = Duration(seconds: 10);

  /// Counts as a real listen rather than a skip.
  static const _completedFraction = 0.9;

  List<Track> _items = const [];
  List<int> _order = const [];   // positions into _items, in play order
  List<int> _orderedIds = const [];  // what _order was built from
  int _orderPos = 0;
  int? _queueId;
  int? _loadedTrackId;
  int? _waitingForTrack;         // stalled on a download; resume when it lands

  /// Whether the web player already holds a playlist we can edit in place.
  /// Until the first source is set there is nothing to insert into.
  bool _webPlaylistLive = false;

  /// The browser refused to start audio because nothing has been tapped yet.
  ///
  /// Not an error: a browser will only make sound from an element a real interaction
  /// reached. It is a prompt — the next tap anywhere resumes what was waiting.
  bool needsGesture = false;

  /// Every load takes this token. Two loads can overlap — tapping a row while a skip
  /// is still resolving, or a server event arriving mid-tap — and without a token the
  /// slower one finishes last and wins, leaving the wrong song playing.
  int _loadToken = 0;

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
    final previousIndex = index;
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
      await _halt();
      _emit(force: true);
      return;
    }

    if (sameQueue && _loadedTrackId != null) {
      final moved = _relocate(previousIndex, _loadedTrackId!);
      if (moved >= 0) {
        _syncOrder(keepItemIndex: moved);
        // A track we were stalled on may have arrived with this update.
        if (_waitingForTrack != null) await _resumeIfPossible();
        _emit(force: true);
        return;
      }
    }

    _syncOrder(keepItemIndex: queue.cursorIndex.clamp(0, _items.length - 1));
    await _loadCurrent(startAt: Duration(milliseconds: queue.positionMs));
    if (autoplay) _startPlayback();
    _emit(force: true);
  }

  /// Where the playing track sits after the list changed.
  ///
  /// Matching purely by track id finds the *first* copy, so a queue containing the
  /// same song twice — radio produces those, and so does adding a favourite again —
  /// snapped playback back to copy one on every refresh, advanced from there, and hit
  /// the same song again. Which is what "it just plays the same song" felt like.
  int _relocate(int previousIndex, int trackId) {
    if (previousIndex >= 0 &&
        previousIndex < _items.length &&
        _items[previousIndex].id == trackId) {
      return previousIndex;                       // it did not move
    }
    var best = -1, bestDistance = 1 << 30;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].id != trackId) continue;
      final distance = (i - previousIndex).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;                                  // the nearest copy, not the first
  }

  /// Keep the existing play order unless the queue actually changed.
  ///
  /// loadQueue runs on every add, every server event and every edit. Rebuilding the
  /// order each time meant that with shuffle on, the queue was reshuffled several
  /// times a minute: "next" pointed somewhere new every time, and in a short queue
  /// the same song kept coming round. Only a real change to the item list rebuilds.
  void _syncOrder({required int keepItemIndex}) {
    final ids = [for (final t in _items) t.id];
    final unchanged = _order.length == _items.length &&
        _orderedIds.length == ids.length &&
        () {
          for (var i = 0; i < ids.length; i++) {
            if (_orderedIds[i] != ids[i]) return false;
          }
          return true;
        }();

    if (unchanged) {
      final at = _order.indexOf(keepItemIndex);
      if (at >= 0) _orderPos = at;
      return;
    }
    _rebuildOrder(keepItemIndex: keepItemIndex);
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
    _orderedIds = [for (final t in _items) t.id];
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
  /// Play a specific track, identified by what it *is* rather than where it was.
  ///
  /// A list index is only valid for the frame it was rendered in: a server event or a
  /// radio append can reorder the queue between the row being drawn and the finger
  /// landing on it, and then the index points at a different song. The index is kept
  /// as a hint so the right copy is chosen when a track appears more than once.
  Future<void> playTrack(int trackId, {int? indexHint}) async {
    final itemIndex = _relocate(indexHint ?? index, trackId);
    if (itemIndex < 0) return;
    final pos = _order.indexOf(itemIndex);
    if (pos < 0) return;
    await _playOrderPos(pos);
  }

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

    // Show the new track at once. Loading takes a moment on a slow connection, and
    // leaving the screen on the previous song until audio starts made skipping look
    // like it had not registered.
    _emit(force: true);

    final token = ++_loadToken;
    try {
      if (_loadedTrackId != track.id) {
        await _loadCurrent(startAt: startAt, token: token);
      }
      // A newer request came in while this one was loading: it owns playback now.
      if (token != _loadToken) return;
      if (_waitingForTrack == null) _startPlayback();
    } catch (e) {
      // A load that throws must not leave the UI frozen on a half-changed state.
      lastError = '$e';
    } finally {
      if (token == _loadToken) {
        _emit(force: true);
        _saveCursor();
      }
    }
  }

  /// Deliberately not awaited: just_audio's play() future completes when playback
  /// *stops*, so awaiting it would defer everything after it to the end of the song
  /// and leave an error handler open for the whole track.
  void _startPlayback() {
    unawaited(_player.play().catchError((Object e) {
      if (_isAutoplayRefusal(e)) {
        // Ask for the tap rather than reporting a failure — nothing is broken.
        needsGesture = true;
      } else {
        lastError = '$e';
      }
      _emit(force: true);
    }));
  }

  /// A browser saying "not without a tap first", in the several ways it says it.
  static bool _isAutoplayRefusal(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('notallowederror') ||
        text.contains('play method is not allowed') ||
        text.contains("didn't interact") ||
        text.contains('user gesture') ||
        text.contains('user activation');
  }

  /// Called when the person taps anything at all: a browser counts that as permission,
  /// so whatever was waiting for one can start now.
  Future<void> resumeAfterGesture() async {
    if (!needsGesture) return;
    needsGesture = false;
    _emit(force: true);
    await playPause();
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

  Future<void> next() {
    _waitingForTrack = null;   // an explicit skip overrides waiting for a download
    return _advance(1);
  }

  Future<void> previous() async {
    // Restart the track first, then step back — the convention every player uses.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    _waitingForTrack = null;
    await _advance(-1);
  }

  /// Move through the queue, honouring repeat and stepping over tracks that are not
  /// downloaded yet instead of stopping dead on them.
  int? _warmedTrackId;

  /// The last URL actually handed to the audio engine, and what the engine said about
  /// it. Debug only: when the screen and the sound disagree, this settles which one is
  /// lying. `instances` counts players ever built, to catch a second one holding the
  /// audio element while the first takes the commands.
  String? lastSourceUrl;
  static int instances = 0;

  /// Playback speed. Kept here rather than read back off the engine because it has to
  /// survive loading the next track, which resets it.
  double speed = 1.0;

  Future<void> setSpeed(double value) async {
    speed = value.clamp(0.5, 2.0);
    await _player.setSpeed(speed);
    _emit(force: true);
  }

  Future<void> _advance(int direction, {bool auto = false}) async {
    if (_order.isEmpty) return;
    if (auto && repeat == QueueRepeat.one) {
      await _player.seek(Duration.zero);
      _startPlayback();
      return;
    }

    // Walk the play order looking for something playable. A track that is still
    // downloading is remembered rather than skipped past for good: reaching the end
    // with one of those behind us means "wait", not "the queue is over".
    int? pendingPos;
    var pos = _orderPos;
    for (var step = 0; step < _order.length; step++) {
      pos += direction;
      if (pos >= _order.length) {
        if (repeat != QueueRepeat.all) break;
        pos = 0;
      } else if (pos < 0) {
        if (repeat != QueueRepeat.all) return;   // already at the top; stay put
        pos = _order.length - 1;
      }
      final candidate = _items[_order[pos]];
      if (candidate.isReady) {
        await _playOrderPos(pos);
        return;
      }
      pendingPos ??= pos;
    }

    if (pendingPos != null) {
      // Park on the track we are waiting for. onTrackReady starts it.
      _orderPos = pendingPos;
      _waitingForTrack = _items[_order[pendingPos]].id;
      _loadedTrackId = null;
      await _halt();
      _emit(force: true);
      _saveCursor();
      return;
    }

    await _finish();
  }

  Future<void> _finish() async {
    _recordListen();
    finished = true;
    await _halt();
    _emit(force: true);
  }

  /// Stop the audio without throwing the web player's `<audio>` element away.
  ///
  /// A browser grants permission to make sound to the *element* a tap happened on.
  /// just_audio's stop() deactivates the platform player, which on the web disposes
  /// that element — so the next track, started by a download finishing or by the
  /// previous one ending, met a brand new element with no permission and was refused
  /// ("NotAllowedError: The play method is not allowed..."). Pausing leaves the same
  /// element in place, which is all "stopped" needs to mean here.
  Future<void> _halt() async {
    if (kIsWeb) {
      await _player.pause();
      return;
    }
    await _player.stop();
  }

  Future<void> seek(Duration to) async {
    await _player.seek(to);
    _saveCursor();
  }

  /// Ask the server to fetch what is about to be played before it fetches the rest of
  /// the library, and warm the next song so it starts the instant this one ends.
  ///
  /// Both matter for the same reason: a mirrored playlist puts hundreds of tracks in
  /// the download queue, and without this the song you just pressed play on waits
  /// behind all of them.
  Future<void> _lookAhead() async {
    final run = <Track>[];
    for (var i = index; i < index + 3 && i < items.length; i++) {
      if (i >= 0) run.add(items[i]);
    }
    if (run.isEmpty) return;

    final pending = run.where((t) => !t.isReady).map((t) => t.id).toList();
    if (pending.isNotEmpty) {
      try {
        await api.promoteDownloads(pending);
      } catch (_) {
        // Best effort: it will download in its own time either way.
      }
    }

    // The next song, into the HTTP cache, so it plays even if the connection is busy
    // downloading the rest of the library — or gone.
    final next = run.length > 1 ? run[1] : null;
    if (next != null && next.isReady && next.id != _warmedTrackId) {
      _warmedTrackId = next.id;
      unawaited(api.warmStream(next));
    }
  }

  Future<void> _loadCurrent({Duration? startAt, int? token}) async {
    final mine = token ?? ++_loadToken;
    final track = current;
    if (track == null) return;
    unawaited(_lookAhead());
    if (!track.isReady) {
      // Hold here rather than skipping past what the user picked, but remember it so
      // the track_ready event can start it.
      _waitingForTrack = track.id;
      _loadedTrackId = null;
      await _halt();
      _emit(force: true);
      return;
    }
    _waitingForTrack = null;
    lastError = null;
    try {
      await api.ensureStreamKey();
      if (mine != _loadToken) return;      // superseded while fetching the key

      final cover = api.coverUrl(track, small: false);
      final coverUri = cover == null ? null : Uri.parse(cover);
      final sourceUrl = api.streamUrl(track);
      final source = AudioSource.uri(
        Uri.parse(sourceUrl),
        // Headers are not deliverable from a browser's audio element, which is why
        // the URL is signed. Native platforms send them too; either proves identity.
        headers: kIsWeb ? null : api.streamHeaders,
        // just_audio_background requires this on every source, and it is what the
        // lockscreen, the notification and the car display actually show.
        tag: MediaItem(
          id: '${track.id}',
          title: track.displayTitle,
          artist: track.artistLine,
          album: track.albumLine,
          duration: track.duration,
          // The lockscreen and the car display fetch this themselves, so it has to
          // be a URL that authenticates on its own — the same signed key as audio.
          artUri: coverUri,
        ),
      );

      final Duration? reported;
      if (kIsWeb && _webPlaylistLive) {
        // Edit the playlist instead of replacing it.
        //
        // just_audio wraps whatever you give it in an internal playlist whose id is
        // the empty string for the life of the AudioPlayer, and just_audio_web caches
        // its source player under that id. setAudioSource replaces the children in
        // Dart but never tells the platform, so the second call and every one after
        // it resolved to the *first* source: the screen moved on while the same song
        // kept playing. (Proved by hooking HTMLMediaElement — one src assignment for
        // the whole session.) The insert/remove calls are the ones the web plugin
        // actually implements, so they update that cached player.
        //
        // Doing it this way also keeps the one <audio> element alive, which is what
        // the browser's permission to make sound is attached to; and because the
        // plugin restarts playback itself when it swaps the src of a playing element,
        // a track that ends or finishes downloading starts the next one with no tap.
        await _player.insertAudioSource(0, source);
        if (mine != _loadToken) return;
        await _player.seek(startAt ?? Duration.zero, index: 0);
        if (mine != _loadToken) return;
        final stale = _player.audioSources.length;
        if (stale > 1) await _player.removeAudioSourceRange(1, stale);
        reported = _player.duration;
      } else {
        reported = await _player.setAudioSource(source, initialPosition: startAt);
        _webPlaylistLive = kIsWeb;
      }
      lastSourceUrl = '$sourceUrl -> engine says ${reported?.inMilliseconds}ms '
          '(player #$_instance of ${PlayerService.instances})';
      if (mine != _loadToken) return;      // a later track won the race
      await _player.setVolume(_volumeFor(track));
      if (speed != 1.0) await _player.setSpeed(speed);
      _loadedTrackId = track.id;
    } on PlayerInterruptedException {
      // Another load took over while this one was in flight — skipping twice quickly,
      // or a queue update arriving mid-load. That is the intended outcome, not
      // something to put on screen.
      return;
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
    if (!_items.any((t) => t.id == trackId)) return;
    final fresh = await api.track(trackId);
    // Update every copy: the same track can sit in a queue more than once.
    _items = [
      for (final t in _items) t.id == trackId ? fresh.copyWithOrigin(t.origin) : t
    ];
    final i = index;
    if (_waitingForTrack != null) {
      await _resumeIfPossible();
    } else if (i == index && _loadedTrackId != trackId) {
      await _loadCurrent();
    }
    _emit(force: true);
  }

  /// A progress tick for a track in this queue. Patched in place: these arrive
  /// several times a second and re-fetching the queue for each would be absurd.
  void applyProgress(int trackId, Map<String, dynamic> data) {
    var touched = false;
    _items = [
      for (final t in _items)
        if (t.id == trackId)
          () {
            touched = true;
            return t.withProgress({
              'stage': data['stage'],
              'label': data['label'],
              'percent': data['percent'],
              'speed': data['speed'],
            });
          }()
        else
          t
    ];
    if (touched) _emit(force: true);
  }

  /// Metadata or artwork changed for a track we are holding. Swap the row in place —
  /// and if it is the one playing, refresh the media session so the lockscreen picks
  /// up the new cover too.
  Future<void> onTrackUpdated(int trackId) async {
    if (!_items.any((t) => t.id == trackId)) return;
    final fresh = await api.track(trackId);
    _items = [
      for (final t in _items) t.id == trackId ? fresh.copyWithOrigin(t.origin) : t
    ];
    if (_loadedTrackId == trackId && !_player.playing) {
      // Only when paused: reloading the source mid-song would restart it, and a cover
      // is never worth interrupting playback for.
      await _loadCurrent(startAt: _player.position);
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
    // Sound is coming out, so whatever permission was missing is not missing now.
    if (_player.playing) needsGesture = false;
    last = PlayerSnapshot(
      current: current,
      index: index,
      playing: _player.playing,
      position: _player.position,
      duration: _player.duration ?? current?.duration,
      buffered: _player.bufferedPosition,
      itemCount: _items.length,
      loadedTrackId: _loadedTrackId,
      error: lastError,
      needsGesture: needsGesture,
      repeat: repeat,
      shuffle: shuffle,
      waitingForDownload: _waitingForTrack != null,
      finished: finished,
    );
    // A disposed player can still be reached by an event that was already in flight —
    // an SSE update landing while the app tears down, say. Adding to a closed stream
    // throws into nothing and looks like a crash in the logs.
    if (!_stateController.isClosed) _stateController.add(last!);
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
  /// What the audio engine actually holds. When this disagrees with [current] the UI
  /// is showing one song and playing another — the failure that kept coming back.
  final int? loadedTrackId;
  final String? error;
  /// The browser is waiting to be tapped before it will make a sound.
  final bool needsGesture;
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
    this.loadedTrackId,
    this.error,
    this.needsGesture = false,
    this.repeat = QueueRepeat.off,
    this.shuffle = false,
    this.waitingForDownload = false,
    this.finished = false,
  });

  bool get isConsistent => current == null || loadedTrackId == current!.id;

  double get progress {
    final d = duration?.inMilliseconds ?? 0;
    if (d <= 0) return 0;
    return (position.inMilliseconds / d).clamp(0.0, 1.0);
  }
}
