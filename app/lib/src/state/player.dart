import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'keepalive.dart';
import 'playback_log.dart';

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

  /// How often playback is checked for having quietly stopped, and how long it has to
  /// be stuck before anything is done about it. Both are settable so a test does not
  /// have to wait out a real stall.
  static Duration watchInterval = const Duration(seconds: 5);
  static Duration stallAfter = const Duration(seconds: 12);

  Timer? _watchdog;

  /// Since when the engine has been waiting for audio, if it is.
  DateTime? _bufferingSince;

  /// Whether music is *supposed* to be playing.
  ///
  /// Not the same question as `_player.playing`, and the difference is the whole of
  /// this bug. The snapshot mirrors the engine — it is rebuilt from it on every state
  /// change — so "it says it is playing but the engine has stopped" was a state that
  /// could never be observed, and the check that was meant to catch a background stop
  /// could never fire. This is the other half: what the person asked for, which only
  /// the person changes.
  bool _wantPlaying = false;

  /// Something else has the speaker — a call, a spoken direction. Not a fault, and not
  /// ours to undo: the session tells us when it is over.
  bool _interrupted = false;

  /// How many times the watchdog has tried to get a stopped engine going again.
  int _revivals = 0;

  /// The furthest into this song playback has actually reached. Where to put the
  /// needle back when a stream dies: not where the engine last mentioned, which may be
  /// the top of the song.
  Duration _heardUpTo = Duration.zero;
  int _nudges = 0;

  /// The song already handed to the engine to play after this one, if any.
  int? _queuedNextId;

  /// Which slot of the engine's playlist the current song sits in. An explicit load
  /// puts it back at the top; an automatic advance moves it one along.
  int _engineIndex = 0;

  /// How many playlist edits are in flight.
  ///
  /// Loading a track inserts it at the top, which shifts everything already in the
  /// playlist down a slot — and the engine reports that as its current index changing,
  /// which is indistinguishable from the song having ended and the next one starting.
  /// Believing it there would move the queue on by one every time somebody pressed
  /// skip. While this is above zero, index changes are ours, not the music's.
  int _mutating = 0;

  /// Where the track now loading is meant to start. Until the engine holds the
  /// current track it is still reporting the *previous* one's position, and
  /// publishing that draws the new song as though it were already half over —
  /// then snapping back a moment later when the real one arrives.
  Duration _pendingStart = Duration.zero;

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

  /// The same reports, minus the ones that only say the clock moved.
  ///
  /// Position arrives four times a second, and a screen built from it rebuilds four
  /// times a second — every widget on the player, including the record, its shadow and
  /// the printed background behind it. The animations then compete with the rebuilds
  /// and the whole thing judders. Anything that needs the clock takes it from
  /// [snapshots] itself (and moves smoothly between reports on its own); everything
  /// else takes this, which fires when something visible actually changes — with a
  /// coarse position included so a seek is still noticed within a few seconds.
  Stream<PlayerSnapshot> get changes => _stateController.stream.distinct((a, b) =>
      a.current?.id == b.current?.id &&
      a.loadedTrackId == b.loadedTrackId &&
      a.index == b.index &&
      a.itemCount == b.itemCount &&
      a.playing == b.playing &&
      a.repeat == b.repeat &&
      a.finished == b.finished &&
      a.waitingForDownload == b.waitingForDownload &&
      a.needsGesture == b.needsGesture &&
      a.error == b.error &&
      a.duration == b.duration &&
      a.position.inSeconds ~/ 5 == b.position.inSeconds ~/ 5);

  /// Fired when the player changes the queue's settings or order itself, so the app
  /// can persist them without the player knowing about the API.
  void Function(int queueId, {int? cursorIndex, int? positionMs})? onCursor;

  AudioPlayer get raw => _player;
  List<Track> get items => _items;
  int get index => _orderPos < _order.length ? _order[_orderPos] : 0;
  Track? get current => (index >= 0 && index < _items.length) ? _items[index] : null;
  bool get isPlaying => _player.playing;
  int? get waitingForTrack => _waitingForTrack;

  /// The song already sitting in the engine's playlist, ready to follow this one.
  /// Read by the tests: it is the difference between a gap between songs and none.
  int? get queuedNextId => _queuedNextId;

  /// The audio session the platform is playing through, where there is such a thing.
  /// The visualiser needs it to read the shape of this app's own output.
  int? get androidAudioSessionId => _player.androidAudioSessionId;

  Future<void> init() async {
    var said = '';
    _player.playerStateStream.listen((s) {
      // Written down, because the minute worth reading is always the one with the
      // screen off. See PlaybackLog.
      final now = '${s.playing ? 'playing' : 'stopped'} ${s.processingState.name}';
      if (now != said) {
        said = now;
        PlaybackLog.note('engine $now'
            '${_wantPlaying ? '' : ' (nothing wanted)'}');
      }
      _emit(force: true);
      if (s.processingState == ProcessingState.completed) _onCompleted();
      if (!s.playing) _saveCursor();      // pausing is a good moment to remember
    });
    _player.positionStream.listen((_) => _emit());
    // The engine moving through its own playlist, which is what a gapless transition
    // looks like from here.
    _player.currentIndexStream.listen(_onEngineIndex);
    _player.playbackEventStream.listen((_) {}, onError: (Object e) {
      lastError = '$e';
      PlaybackLog.note('engine error: $e');
      _emit(force: true);
    });
    _cursorTimer = Timer.periodic(cursorInterval, (_) {
      if (_player.playing) _saveCursor();
    });
    _watchdog = Timer.periodic(watchInterval, (_) => checkForStall());
    unawaited(_listenToTheSession());
  }

  /// What to do when something else wants the speaker.
  ///
  /// Without this the phone's own rules apply and nothing here knows they did: a
  /// notification, a navigation instruction or a call takes the audio focus, playback
  /// stops, and it stays stopped — which is a song that ends in the middle for no
  /// reason anybody can see. A short interruption is now resumed from, and unplugging
  /// the headphones pauses rather than playing the record to the room.
  Future<void> _listenToTheSession() async {
    if (kIsWeb) return;                       // the browser has its own rules
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      var wasPlaying = false;
      session.interruptionEventStream.listen((event) async {
        if (event.begin) {
          wasPlaying = _player.playing;
          if (event.type == AudioInterruptionType.duck) {
            await _player.setVolume(_volumeFor(current) * 0.3);
          } else if (wasPlaying) {
            // Held apart from `pause()`: this is not the person deciding to stop, and
            // the watchdog must neither undo it nor forget that music was playing.
            _interrupted = true;
            PlaybackLog.note('interrupted (${event.type.name})');
            await _player.pause();
          }
        } else {
          if (_interrupted) PlaybackLog.note('interruption over');
          _interrupted = false;
          if (event.type == AudioInterruptionType.duck) {
            await _player.setVolume(_volumeFor(current));
          } else if (event.type == AudioInterruptionType.pause && wasPlaying) {
            // A phone call or a spoken direction: it was ours before and it is ours
            // again. (`unknown` is not resumed from — that is the user pressing pause
            // somewhere else, and starting again over their head is worse.)
            _startPlayback();
          }
        }
        _emit(force: true);
      });
      session.becomingNoisyEventStream.listen((_) {
        PlaybackLog.note('headphones unplugged');
        unawaited(pause());
      });
    } catch (_) {
      // A platform with no session to configure still plays.
    }
  }

  double _volumeFor(Track? t) => t == null ? userVolume : _volumeForTrack(t);

  /// Playback said it was running and the clock did not move.
  ///
  /// A phone changing network, a connection a sleeping phone dropped, a stream the
  /// server stopped feeding: the engine sits there believing it is playing, and the
  /// song stops in the middle until somebody opens the app and touches something.
  /// Nothing notices that on its own, so this does: nudge it back to where it was,
  /// and if that does not take, load the song again from that spot.
  Future<void> checkForStall() async {
    if (_loadedTrackId == null || _mutating > 0) {
      _bufferingSince = null;
      return;
    }

    // Music that is supposed to be playing, and an engine that is not playing it.
    //
    // This is the background case, and until now nothing looked for it: the app was
    // switched away from, something stopped the engine — a stream the connection
    // dropped, a socket a sleeping phone closed, the platform reclaiming the player —
    // and the app only ever noticed if you opened it again.
    //
    // `idle` is the signal that matters, not `playing`. just_audio keeps `playing` in
    // Dart: it is what was last *asked for*, and it stays true through an engine that
    // has died underneath it. What the platform actually reports is its processing
    // state, and an engine holding nothing reports idle. So a dead engine is one that
    // has gone idle while we still want sound out of it — which is precisely the state
    // that could not be seen from the snapshot, because the snapshot is built from the
    // same two values.
    final dead = _player.processingState == ProcessingState.idle;
    if (dead || !_player.playing) {
      _bufferingSince = null;
      if (_wantPlaying && !_interrupted && !finished) await _revive();
      return;
    }
    _revivals = 0;

    // Buffering is the signal, and only buffering.
    //
    // The obvious test — "has the position moved" — cannot be asked of either clock.
    // The one the app shows is worked out from "where it was, plus how long ago", so
    // it moves whether or not any sound is coming out; the one the engine reports only
    // changes when the engine has something to say, which on Android is a state change
    // and not the passing of time. Reading that second one as a stall is what made a
    // song jump back to where it started after a few seconds — which is worse than the
    // fault it was watching for.
    if (_player.processingState != ProcessingState.buffering) {
      _bufferingSince = null;
      _nudges = 0;
      return;
    }
    _bufferingSince ??= DateTime.now();
    if (DateTime.now().difference(_bufferingSince!) < stallAfter) return;

    _bufferingSince = DateTime.now();
    _nudges++;
    // Back to where the listener believes they are, which is the furthest the song has
    // actually played — never to whatever the engine last happened to mention.
    final at = _heardUpTo > _player.position ? _heardUpTo : _player.position;
    try {
      if (_nudges <= 2) {
        // Cheapest first: asking for the same spot again re-opens the stream.
        await _player.seek(at);
        _startPlayback();
      } else {
        // It is not coming back on its own.
        await _loadCurrent(startAt: at);
        _startPlayback();
        _nudges = 0;
      }
    } catch (e) {
      lastError = '$e';
    }
    _emit(force: true);
  }

  /// Get a stopped engine going again, from where the listener was.
  ///
  /// Escalating, and bounded. Asking it to play again is nearly always enough — the
  /// engine is idle but intact. When it is not, the source is loaded afresh from the
  /// furthest point that was actually heard. After a few failures in a row it stops
  /// trying: something is wrong that retrying will not fix, and a phone quietly
  /// reopening a dead stream every five seconds is worse than silence.
  static const maxRevivals = 6;

  Future<void> _revive() async {
    if (_revivals >= maxRevivals) {
      if (_revivals == maxRevivals) {
        _revivals++;
        PlaybackLog.note('gave up reviving after $maxRevivals tries');
      }
      return;
    }
    _revivals++;
    final at = _heardUpTo > _player.position ? _heardUpTo : _player.position;
    // An engine that is holding nothing cannot be talked round, and asking is worse
    // than useless: just_audio's play() returns immediately when it already believes
    // it is playing, which after a death underneath it is exactly what it believes.
    // So an idle engine is reloaded on the first attempt rather than the third.
    final holdingNothing = _player.processingState == ProcessingState.idle;
    PlaybackLog.note(
        'reviving (#$_revivals, ${holdingNothing ? 'engine empty' : 'engine holds it'}, at ${at.inSeconds}s)');
    try {
      if (!holdingNothing && _revivals <= 1) {
        // The engine still has the song and merely stopped — it lost the audio focus,
        // or the platform paused it. Asking again is the whole repair.
        _startPlayback();
      } else {
        // Put just_audio's own idea of playing back to false first, or the play()
        // after the load is a no-op for the same reason.
        try {
          await _player.pause();
        } catch (_) {
          // A dead platform cannot be paused. It is about to be replaced anyway.
        }
        await _loadCurrent(startAt: at);
        _startPlayback();
      }
    } catch (e) {
      lastError = '$e';
    }
    _emit(force: true);
  }

  /// The app came back to the front. If it should be playing and it is not, it stopped
  /// while nobody was looking — and whatever stopped it may also have stopped the
  /// watchdog getting anywhere, so this gets a fresh set of attempts.
  Future<void> resumeIfStopped() async {
    if (_loadedTrackId == null) return;
    _revivals = 0;
    if (_wantPlaying && !_player.playing && !_interrupted && !finished) {
      await _revive();
      return;
    }
    await checkForStall();
  }

  // ------------------------------------------------------------------ queue
  /// Load a queue and start at its stored cursor, so switching queues resumes.
  ///
  /// Adding a track re-reads the queue, so this is called constantly while music is
  /// playing. It must leave playback alone unless the audio actually has to change.
  Future<void> loadQueue(Queue queue, {bool autoplay = false}) async {
    final sameQueue = _queueId == queue.id;
    final previousIndex = index;
    // The song this device is on — which is not the same as the song whose audio has
    // finished loading, and the order of those two matters. Between a skip and its
    // stream being ready the engine still holds the *previous* track; anchoring on
    // that relocates the queue to the song just skipped, which is the flick backwards
    // you see for a moment before the new one settles. What this device means to play
    // is `current`; the loaded id is only the fallback for before there is one.
    final anchor = current?.id ?? _loadedTrackId ?? _waitingForTrack;
    _queueId = queue.id;
    _items = queue.items;
    if (!sameQueue) {
      repeat = queueRepeatFrom(queue.repeat);
    }

    if (_items.isEmpty) {
      _order = const [];
      _orderPos = 0;
      _loadedTrackId = null;
      await _halt();
      _emit(force: true);
      return;
    }

    if (sameQueue && anchor != null) {
      final moved = _relocate(previousIndex, anchor);
      if (moved >= 0) {
        _syncOrder(keepItemIndex: moved);
        // A track we were stalled on may have arrived with this update.
        if (_waitingForTrack != null) await _resumeIfPossible();
        // What comes next may be a different song now — somebody put something in
        // front of it, or took it out.
        await _queueNext();
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

  /// The play order, which is now simply the list.
  ///
  /// It used to be a separate ordering so that shuffle could be a mode: the queue said
  /// one thing and playback did another, and turning shuffle off put nothing back.
  /// Shuffling rearranges the rows themselves now — see shuffleWhatIsComing — so there
  /// is one order, and it is the one on screen.
  void _rebuildOrder({required int keepItemIndex}) {
    _order = List<int>.generate(_items.length, (i) => i);
    _orderPos = keepItemIndex.clamp(0, _items.length - 1);
    _orderedIds = [for (final t in _items) t.id];
  }

  /// Rearrange what is coming, once, keeping the song playing where it is.
  ///
  /// Applied here before the server is asked, like every other queue edit, so the list
  /// changes under the finger rather than a moment later.
  void shuffleWhatIsComing() {
    if (_items.length - index < 3) return;      // nothing worth rearranging
    final at = index;
    final rest = _items.sublist(at + 1)..shuffle(math.Random());
    _items = [..._items.sublist(0, at + 1), ...rest];
    _rebuildOrder(keepItemIndex: at);
    _queuedNextId = null;                       // what comes next is a different song
    unawaited(_queueNext());
    _emit(force: true);
  }

  /// Move a row now, rather than when the server says so.
  ///
  /// Reordering used to be: ask the server, wait, then redraw. For the length of that
  /// request the list was still the old one, so the row you had just dragged sprang
  /// back to where it came from and then jumped to where you put it. The server is
  /// still the authority — its answer replaces this — but it is confirming what the
  /// screen already shows instead of being the first to know.
  void moveLocally(int from, int to) {
    if (from < 0 || from >= _items.length) return;
    if (to < 0 || to >= _items.length || from == to) return;
    final playing = current?.id;
    final items = [..._items];
    items.insert(to, items.removeAt(from));
    _items = items;
    // Keep playing what is playing: it has a new index in the list now.
    final at = playing == null ? index : _relocate(index, playing);
    _rebuildOrder(keepItemIndex: at < 0 ? 0 : at);
    unawaited(_queueNext());
    _emit(force: true);
  }

  /// Move several rows at once, keeping their own order.
  void moveManyLocally(List<int> froms, int to) {
    final picked = ({...froms}.toList()..sort());
    if (picked.isEmpty || picked.any((p) => p < 0 || p >= _items.length)) return;
    final playing = current?.id;
    final block = [for (final p in picked) _items[p]];
    final rest = [
      for (var i = 0; i < _items.length; i++)
        if (!picked.contains(i)) _items[i]
    ];
    final at = to.clamp(0, rest.length);
    _items = [...rest.sublist(0, at), ...block, ...rest.sublist(at)];
    final now = playing == null ? index : _relocate(index, playing);
    _rebuildOrder(keepItemIndex: now < 0 ? 0 : now);
    _queuedNextId = null;
    unawaited(_queueNext());
    _emit(force: true);
  }

  /// Take a row out now, for the same reason.
  void removeLocally(int pos) {
    if (pos < 0 || pos >= _items.length) return;
    final playing = current?.id;
    final items = [..._items]..removeAt(pos);
    _items = items;
    if (items.isEmpty) {
      _order = const [];
      _orderPos = 0;
      _emit(force: true);
      return;
    }
    final at = playing == null ? index : _relocate(index, playing);
    _rebuildOrder(keepItemIndex: at < 0 ? pos.clamp(0, items.length - 1) : at);
    unawaited(_queueNext());
    _emit(force: true);
  }

  void setRepeat(QueueRepeat mode) {
    repeat = mode;
    finished = false;
    unawaited(_queueNext());
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

  /// Move to a song without making a sound.
  ///
  /// For a guest in a jam who is following the room but not listening to it on this
  /// device: the screen has to show what everyone is playing, and the audio has to
  /// stay off. Loading the stream to immediately pause it would be a download nobody
  /// asked for, on somebody's phone data, for a song they are not hearing.
  Future<void> showTrack(int trackId) async {
    final itemIndex = _relocate(index, trackId);
    if (itemIndex < 0) return;
    final pos = _order.indexOf(itemIndex);
    if (pos < 0 || pos == _orderPos) return;
    _orderPos = pos;
    finished = false;
    _wantPlaying = false;
    _loadedTrackId = null;
    _pendingStart = Duration.zero;
    _heardUpTo = Duration.zero;
    await _halt();
    _emit(force: true);
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
    _wantPlaying = true;
    unawaited(Keepalive.set(true));
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

  /// Stop, without deciding to start again. The jam needs the two halves separately:
  /// following somebody else's player is not a toggle.
  Future<void> pause() async {
    _wantPlaying = false;
    unawaited(Keepalive.set(false));
    if (!_player.playing) return;
    try {
      await _player.pause();
      _saveCursor();
    } catch (e) {
      lastError = '$e';
    }
    _emit(force: true);
  }

  /// Start, without deciding to stop. Loads the current track first if the engine is
  /// holding nothing — a guest that has just been told what the room is playing has
  /// usually not loaded anything yet.
  Future<void> resumeForJam() async {
    if (_player.playing) return;
    try {
      if (_loadedTrackId == null) await _loadCurrent();
      _startPlayback();
    } catch (e) {
      lastError = '$e';
    }
    _emit(force: true);
  }

  Future<void> playPause() async {
    try {
      if (_player.playing) {
        _wantPlaying = false;
        unawaited(Keepalive.set(false));
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
  /// Tracks whose first seconds have already been pulled into the HTTP cache.
  final _warmed = <int>{};

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
    _wantPlaying = false;              // the queue ran out; nothing to revive
    unawaited(Keepalive.set(false));
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
    _revivals = 0;
    if (kIsWeb) {
      await _player.pause();
      return;
    }
    await _player.stop();
  }

  Future<void> seek(Duration to) async {
    _heardUpTo = to;
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

    // The songs after this one, into the HTTP cache, so they play even if the
    // connection is busy downloading the rest of the library — or gone. Two rather
    // than one: skipping through a couple of tracks is normal, and the second one is
    // the difference between "instant" and "a moment while it thinks".
    for (final soon in run.skip(1)) {
      if (!soon.isReady || _warmed.contains(soon.id)) continue;
      if (offlinePath?.call(soon.id) != null) continue;   // already here
      _warmed.add(soon.id);
      unawaited(api.warmStream(soon));
    }
    // Remembering every track ever warmed would grow without limit; the last handful
    // is all that stops the same request going out twice in a row.
    while (_warmed.length > 12) {
      _warmed.remove(_warmed.first);
    }
  }

  /// Told the tally after every play that counted, so a score can move as it is
  /// earned rather than on the next start.
  void Function(int score)? onScore;

  /// Where a track is kept on this device, if it is. Set by the app when the offline
  /// store is ready; null everywhere that has no filesystem.
  String? Function(int trackId)? offlinePath;

  /// One track, as something the audio engine can play.
  AudioSource _sourceFor(Track track) {
    final cover = api.coverUrl(track, small: false);
    final coverUri = cover == null ? null : Uri.parse(cover);
    // A song kept on the device is played from the device — no request, no signal
    // needed, and no second copy of it coming down the wire.
    final local = offlinePath?.call(track.id);
    if (local != null) {
      return AudioSource.uri(
        Uri.file(local),
        tag: MediaItem(
          id: '${track.id}',
          title: track.displayTitle,
          artist: track.artistLine,
          album: track.albumLine,
          duration: track.duration,
          artUri: coverUri,
        ),
      );
    }
    return AudioSource.uri(
      Uri.parse(api.streamUrl(track)),
      // Headers are not deliverable from a browser's audio element, which is why the
      // URL is signed. Native platforms send them too; either proves identity.
      headers: kIsWeb ? null : api.streamHeaders,
      // just_audio_background requires this on every source, and it is what the
      // lockscreen, the notification and the car display actually show.
      tag: MediaItem(
        id: '${track.id}',
        title: track.displayTitle,
        artist: track.artistLine,
        album: track.albumLine,
        duration: track.duration,
        // The lockscreen and the car display fetch this themselves, so it has to be a
        // URL that authenticates on its own — the same signed key as audio.
        artUri: coverUri,
      ),
    );
  }

  /// Hand the engine the next song before the current one ends.
  ///
  /// Otherwise the end of a track is the *start* of the work: the engine stops, tells
  /// Dart, and Dart builds a source, hands it over and asks for play — which is the
  /// silence between songs, and which does not happen at all when the app is in the
  /// background and nothing is running our code. With the next source already in the
  /// engine's own playlist, the transition belongs to the audio platform: it happens
  /// with the screen off, in another app, or in a tab that is not on top.
  Future<void> _queueNext() async {
    if (repeat == QueueRepeat.one) return;      // it will play this one again
    if (_order.isEmpty) return;

    var pos = _orderPos + 1;
    if (pos >= _order.length) {
      if (repeat != QueueRepeat.all) return;    // nothing follows; let it end
      pos = 0;
      if (_order.length == 1) return;           // one song on repeat-all is a seek
    }
    final next = _items[_order[pos]];
    if (!next.isReady) return;                  // still downloading; not yet
    if (_queuedNextId == next.id) return;       // already waiting in the wings

    _mutating++;
    try {
      // The queued URL is signed, and it has to still be valid when the engine gets
      // round to playing it — which may be a whole song from now.
      await api.ensureStreamKey();
      final length = _player.audioSources.length;
      if (length > _engineIndex + 1) {
        // Something else was queued and is no longer next. Dropping what comes after
        // the playing item does not touch the playing item.
        await _player.removeAudioSourceRange(_engineIndex + 1, length);
      }
      await _player.insertAudioSource(_engineIndex + 1, _sourceFor(next));
      _queuedNextId = next.id;
    } catch (_) {
      // A platform that will not take a playlist still works the old way: the track
      // ends, Dart notices, and the next one is loaded. Slower, not broken.
      _queuedNextId = null;
    } finally {
      _mutating--;
    }
  }

  /// The engine moved on by itself, because the next song was already in its playlist.
  /// Catch our own bookkeeping up to it rather than reloading anything.
  void _onEngineIndex(int? at) {
    if (at == null || at == _engineIndex || _mutating > 0) return;
    final expected = _engineIndex + 1;
    final queued = _queuedNextId;
    _engineIndex = at;
    if (at != expected || queued == null) return;

    _recordListen(completed: true);
    final pos = _order.indexWhere((i) => _items[i].id == queued);
    if (pos >= 0) _orderPos = pos;
    _loadedTrackId = queued;
    _queuedNextId = null;
    _waitingForTrack = null;
    finished = false;
    _pendingStart = Duration.zero;
    _emit(force: true);
    _saveCursor();
    unawaited(_lookAhead());
    unawaited(_queueNext());
  }

  Future<void> _loadCurrent({Duration? startAt, int? token}) async {
    final mine = token ?? ++_loadToken;
    final track = current;
    if (track == null) return;
    _pendingStart = startAt ?? Duration.zero;
    _heardUpTo = _pendingStart;
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
    _mutating++;
    try {
      await api.ensureStreamKey();
      if (mine != _loadToken) return;      // superseded while fetching the key

      final sourceUrl = api.streamUrl(track);
      final source = _sourceFor(track);

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
      await _player.setVolume(_volumeForTrack(track));
      if (speed != 1.0) await _player.setSpeed(speed);
      _loadedTrackId = track.id;
      // An explicit load puts this song at the top of the engine's playlist and throws
      // away whatever was queued behind it, so the next song has to be handed over
      // again — see _queueNext.
      _engineIndex = 0;
      _queuedNextId = null;
      unawaited(_queueNext());
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
    } finally {
      _mutating--;
    }
  }

  double _volumeForTrack(Track t) {
    final gain = t.gainDb;
    final normalised = (gain == null || gain >= 0)
        ? 1.0                                     // never boost into clipping
        : math.pow(10, gain / 20).toDouble().clamp(0.05, 1.0);
    return (normalised * userVolume).clamp(0.0, 1.0);
  }

  Future<void> setUserVolume(double v) async {
    userVolume = v.clamp(0.0, 1.0);
    final t = current;
    if (t != null) await _player.setVolume(_volumeForTrack(t));
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
    // The next song is already in the engine, so moving to it is a step rather than a
    // load: no request, no wait, nothing to fetch. A platform that advances through
    // its own playlist never gets here at all — this is for the ones that stop at the
    // end of each item and wait to be told.
    if (_queuedNextId != null) {
      unawaited(_player.seekToNext().catchError((_) {
        _queuedNextId = null;
        _recordListen(completed: true);
        _advance(1, auto: true);
      }));
      return;
    }
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
    // Only the track we are actually stalled on may start playback, and only while
    // nothing is playing. Anything else is a download finishing somewhere further down
    // the queue, which is not a reason to touch what is on.
    //
    // This is where skipping went strange. The old test was "the index has not changed
    // since a moment ago", compared against a value read *after* the await, so it was
    // always true — and then any track in the queue becoming ready reloaded the
    // current one from the start. With a queue downloading in the background that
    // fired every few seconds, restarting or jumping past whatever you had just
    // skipped to.
    if (_waitingForTrack == trackId && !_player.playing) {
      await _resumeIfPossible();
    } else if (_queuedNextId == null && current?.id != trackId) {
      // It may be the one that plays after this: now that it is playable it can be
      // handed to the engine, so the transition still costs nothing.
      await _queueNext();
    } else if (current?.id == trackId && _loadedTrackId != trackId) {
      // The song on screen is the one that just became playable: load it, since until
      // now there was nothing to load.
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

  /// Start the track we were stalled on, if it is still here and still wanted.
  ///
  /// It used to fall back to "whatever is current" when the track it was waiting for
  /// had gone, which meant a download finishing could restart the song you had moved
  /// on to. If the thing we were waiting for is not in the queue any more, the wait is
  /// simply over.
  Future<void> _resumeIfPossible() async {
    final waitingPos = _order.indexWhere((i) => _items[i].id == _waitingForTrack);
    if (waitingPos < 0) {
      _waitingForTrack = null;
      return;
    }
    if (!_items[_order[waitingPos]].isReady) return;
    _waitingForTrack = null;
    await _playOrderPos(waitingPos);
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
    api
        .recordListen(track.id, played, done)
        .then((score) => onScore?.call(score))
        .catchError((_) => 0);
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
    // How far this song has actually played, which is what a stall has to be put back
    // to. Reset by loading or seeking, both of which go through _pendingStart.
    if (_player.playing &&
        _player.processingState == ProcessingState.ready &&
        _loadedTrackId == current?.id) {
      final at = _player.position;
      if (at > _heardUpTo) _heardUpTo = at;
    }
    // Sound is coming out, so whatever permission was missing is not missing now.
    if (_player.playing) needsGesture = false;
    last = PlayerSnapshot(
      current: current,
      index: index,
      playing: _player.playing,
      // Only believe the engine while it actually holds this track.
      position: _loadedTrackId != null && _loadedTrackId == current?.id
          ? _player.position
          : _pendingStart,
      duration: _loadedTrackId != null && _loadedTrackId == current?.id
          ? (_player.duration ?? current?.duration)
          : current?.duration,
      buffered: _player.bufferedPosition,
      itemCount: _items.length,
      loadedTrackId: _loadedTrackId,
      error: lastError,
      needsGesture: needsGesture,
      repeat: repeat,
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
    _watchdog?.cancel();
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
    this.waitingForDownload = false,
    this.finished = false,
  });

  bool get isConsistent => current == null || loadedTrackId == current!.id;

  /// Nothing after this one. Worth saying, because the alternative is the music
  /// simply stopping and nobody having been told it was going to.
  ///
  /// Not true on repeat: a queue that comes round again has no last song.
  bool get lastInQueue =>
      repeat == QueueRepeat.off && itemCount > 0 && index == itemCount - 1;

  double get progress {
    final d = duration?.inMilliseconds ?? 0;
    if (d <= 0) return 0;
    return (position.inMilliseconds / d).clamp(0.0, 1.0);
  }
}
