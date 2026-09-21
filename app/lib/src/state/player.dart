import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, visibleForTesting, TargetPlatform;
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'keepalive.dart';
import 'playback_log.dart';
import 'timing.dart';

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
  /// Android's own equalizer and loudness stage, which have to be named when the
  /// player is made: they are part of its audio pipeline, not something attached
  /// afterwards. Null everywhere else — see eqEngineFor for what the others do.
  static bool get _hasSystemEffects =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final AndroidEqualizer? androidEqualizer = _hasSystemEffects ? AndroidEqualizer() : null;
  final AndroidLoudnessEnhancer? androidLoudness =
      _hasSystemEffects ? AndroidLoudnessEnhancer() : null;
  late final AudioPlayer _player = AudioPlayer(
    audioPipeline: androidEqualizer == null
        ? null
        : AudioPipeline(androidAudioEffects: [androidLoudness!, androidEqualizer!]),
  );

  // ------------------------------------------------------------------ seamless
  //
  // Most files have a second or two of nothing at either end, and a queue played
  // straight through is a queue with a pause after every song. The server knows where
  // each song's sound really starts and ends (see TrackTiming); this is what is done
  // with it. A song starts where its sound does, and the moment its sound is over the
  // next one — already waiting in the engine — is stepped to, rather than the silence
  // being sat through. Positions stay what they always were, places in the file: a
  // song trimmed by clipping its source would report times a second out from the
  // lyrics, the seek bar's shape, and everybody else in a jam.

  /// Where songs start and end, their tempo and their beats; asked for ahead of need.
  late final TimingStore timing = TimingStore(api);

  /// Whether the dead air between songs is skipped. A setting, on by default.
  bool seamless = true;

  Timer? _soundEnds;
  int? _soundEndsFor;

  /// How many songs were joined to the next at the end of their sound. For tests, and
  /// for the playback log.
  @visibleForTesting
  int joins = 0;

  /// Near the end of the sound, set a timer for the exact moment: the position arrives
  /// a few times a second, which is far too coarse to cut on.
  void _watchForTheEndOfTheSound() {
    final track = current;
    if (!seamless || track == null || !_player.playing) return;
    if (_queuedNextId == null || repeat == QueueRepeat.one) return;
    if (_loadedTrackId != track.id || _soundEndsFor == track.id) return;
    final ends = timing.peek(track.id)?.soundEnds;
    if (ends == null) return;
    final left = ends - _player.position;
    if (left > const Duration(milliseconds: 1500)) return;
    _soundEndsFor = track.id;
    _soundEnds?.cancel();
    _soundEnds = Timer(
        left.isNegative ? Duration.zero : left * (1 / speed), () => _theSoundHasEnded(track.id));
  }

  void _theSoundHasEnded(int trackId) {
    _soundEndsFor = null;
    final ends = timing.peek(trackId)?.soundEnds;
    // Asked again, because a second and a half is long enough to pause, to seek back
    // into the song, or to skip: only a song still playing out its last moment is cut.
    if (ends == null || current?.id != trackId || _loadedTrackId != trackId) return;
    if (!seamless || !_player.playing || _mutating > 0) return;
    if (_queuedNextId == null || repeat == QueueRepeat.one) return;
    if (_player.position + const Duration(milliseconds: 120) < ends) return;
    joins++;
    PlaybackLog.note('joined to the next song ${timing.peek(trackId)!.tailMs}ms early');
    // The same step a song ending takes: the next one is already in the engine, so
    // this costs nothing, and the bookkeeping is done where it always is — see
    // _onEngineIndex.
    unawaited(_player.seekToNext().catchError((_) {}));
  }

  /// Where a song about to be played from the top should start: where its sound does,
  /// when that is known and worth the jump.
  Duration _topOf(Track track) =>
      seamless ? (timing.peek(track.id)?.lead ?? Duration.zero) : Duration.zero;

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

  /// Which *row* of the queue the engine's source was built from. A song can be in the
  /// queue twice, and the source carries its row's name in its tag — so moving from one
  /// copy to the other needs a load of its own even though the audio is identical.
  int? _loadedRow;
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

  /// Whether music was playing when something else took the speaker.
  bool _wasPlayingWhenInterrupted = false;

  /// When the speaker was taken for good, if it was and nobody has touched anything
  /// since. Null means nothing is waiting to be given back.
  DateTime? _handedOverAt;

  /// How long a handover can last and still be picked up from.
  ///
  /// Long enough to watch something, short enough that music does not start by itself
  /// in the middle of the night because an app let go of the speaker.
  static const handedOverFor = Duration(minutes: 30);

  /// How often to look at whether the speaker is free again.
  static const askAgainEvery = Duration(seconds: 5);

  Timer? _askingForItBack;

  /// Set when the player is on its way out, so nothing scheduled outlives it.
  bool _disposed = false;

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
  ///
  /// Only ever a fallback now: [_engineAt] asks the engine, because a transition this
  /// class did not see left this number a slot behind — and a slot behind is enough to
  /// drop the *playing* song out of the playlist while trying to queue the next one
  /// behind it, which is the player going quiet or jumping a song for no visible
  /// reason.
  int _engineIndex = 0;

  /// Where the engine says it is in its own playlist.
  int get _engineAt => _player.sequenceState.currentIndex ?? _engineIndex;

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
      a.buffering == b.buffering &&
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

  /// Called once the phone has answered the "may we show the playing notification"
  /// question, so whoever is drawing the screen can find out what it said.
  Future<void> Function()? onNotificationAnswer;

  Future<void> init() async {
    // Which audio platform this player is built on.
    //
    // The whole of background playback on Android hangs off this one fact: with the
    // background wrapper installed, everything the player does reaches a media session
    // and a notification; without it, the same calls go straight to the engine and
    // nothing holds the app up. It has never been written down at a moment that
    // survives in a report, and every round of guessing since has been about
    // mechanisms downstream of it.
    if (!kIsWeb) {
      PlaybackLog.note('player on ${JustAudioPlatform.instance.runtimeType}');
    }
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
      _noticeSomebodyElse(s);
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

  /// The buttons that are not in this app.
  ///
  /// The notification, the lockscreen, a watch, Android Auto and a headset button all
  /// go straight to the engine through the media session: they call play and pause on
  /// the same player this class drives, and nothing in here is told. So pressing pause
  /// out there left `_wantPlaying` true, and a few seconds later the stall watchdog
  /// saw music that was supposed to be playing and an engine that was not playing it,
  /// did its job, and started the song again. Pause on the notification, music back a
  /// moment later, over and over — the watchdog undoing a decision it could not see.
  ///
  /// `playing` in just_audio is what was last *asked for*, so a change in it that this
  /// class did not ask for is somebody pressing a button somewhere else. That is a
  /// decision, and it is recorded as one. A dying engine does not come through here:
  /// it keeps `playing` true and changes its processing state, which is what the
  /// watchdog actually watches for.
  void _noticeSomebodyElse(PlayerState s) {
    // Our own edits stop and start the engine as a matter of course.
    if (_mutating > 0 || _interrupted) return;
    if (s.playing == _wantPlaying) return;
    // An engine that has run out is not a pause: the queue moving on is handled by
    // the completion path, and reading it as "they stopped it" would leave the next
    // song unstarted.
    if (!s.playing && s.processingState != ProcessingState.ready) return;
    _wantPlaying = s.playing;
    unawaited(Keepalive.set(s.playing));
    if (s.playing) {
      _revivals = 0;                    // a fresh start deserves fresh attempts
    } else {
      _handedOverAt = null;
      _askingForItBack?.cancel();
      _askingForItBack = null;
    }
    PlaybackLog.note(
        s.playing ? 'played from somewhere else' : 'paused from somewhere else');
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
      session.interruptionEventStream.listen((event) => unawaited(
          handleInterruption(begin: event.begin, type: event.type)));
      // Only when something was actually playing.
      //
      // The log has this firing twice a minute with nothing playing between — a
      // Bluetooth route settling, not a pair of headphones being pulled out. Pausing
      // then costs nothing visible but it does set "nothing wanted", which is the one
      // state the watchdog will not bring music back from. Something that was not
      // playing cannot be interrupted.
      session.becomingNoisyEventStream.listen((_) async {
        if (!_player.playing && !_wantPlaying) return;
        // Only when something really did unplug.
        //
        // This broadcast means "the output you were using has gone, do not blast the
        // room" — and on this phone it also arrives when a Bluetooth route merely
        // settles, twice a minute, with nothing pulled out of anything. Pausing on one
        // of those while the app was in the background is music stopping for no reason
        // anybody can see, and it never came back because a pause is a decision.
        //
        // So ask what the sound is coming out of before believing it. A headset, a
        // Bluetooth speaker or anything else still connected means nothing was
        // unplugged and the event was noise.
        final still = await _stillPluggedIn(session);
        if (still != null) {
          PlaybackLog.note('audio route settled (still on $still) — kept playing');
          return;
        }
        PlaybackLog.note('audio route went away');
        unawaited(pause());
      });
    } catch (_) {
      // A platform with no session to configure still plays.
    }
  }

  /// The name of an output that is not the phone's own speaker, or null if the only
  /// thing left to play through is the speaker — which is what "becoming noisy"
  /// actually means.
  Future<String?> _stillPluggedIn(AudioSession session) async {
    try {
      return somewhereElseToPlay(await session.getDevices(includeInputs: false));
    } catch (_) {
      // A platform that will not say. Take the broadcast at its word.
      return null;
    }
  }

  /// Anything connected that is not the phone's own speaker, by name.
  ///
  /// "Becoming noisy" means the sound is about to come out of the speaker because
  /// what it was coming out of has gone. If a headset or a Bluetooth speaker is still
  /// there, nothing has gone anywhere and the broadcast was the audio routing
  /// settling, which this phone does about twice a minute.
  @visibleForTesting
  static String? somewhereElseToPlay(Iterable<AudioDevice> devices) {
    for (final d in devices) {
      if (!d.isOutput) continue;
      // The device list is marked experimental in audio_session; the three cases
      // named here are the ones that have existed since it was added.
      // ignore: experimental_member_use
      switch (d.type) {
        // ignore: experimental_member_use
        case AudioDeviceType.builtInSpeaker:
        // ignore: experimental_member_use
        case AudioDeviceType.builtInEarpiece:
        // ignore: experimental_member_use
        case AudioDeviceType.unknown:
          continue;
        default:
          // ignore: experimental_member_use
          return d.name.isEmpty ? d.type.name : d.name;
      }
    }
    return null;
  }

  /// Something else wanted the speaker, or has finished with it.
  ///
  /// Its own method so a test can be the phone: interruptions arrive from the platform
  /// and there is no other way to stand where they come from.
  @visibleForTesting
  Future<void> handleInterruption(
      {required bool begin, required AudioInterruptionType type}) async {
      if (begin) {
        _wasPlayingWhenInterrupted = _player.playing;
        if (type == AudioInterruptionType.duck) {
          await _player.setVolume(_volumeFor(current) * 0.3);
        } else if (_wasPlayingWhenInterrupted) {
          // Held apart from `pause()`: this is not the person deciding to stop, and
          // the watchdog must neither undo it nor forget that music was playing.
          //
          // Only for an interruption that will end. `unknown` on Android is the
          // permanent loss of the audio focus — another app has the speaker for as
          // long as it wants it — and no "over" event is coming for it, ever. Left
          // flagged as interrupted, the watchdog was disabled for the rest of the
          // session: the one stop it could not recover from was the one after
          // somebody opened a video, and every stop after that as well, because
          // nothing ever cleared the flag. A permanent loss is the speaker being
          // taken, so that is what it is recorded as — nothing wanted here — and
          // the next thing this app is asked to do starts cleanly.
          final forGood = type == AudioInterruptionType.unknown;
          _interrupted = !forGood;
          _handedOverAt = forGood ? DateTime.now() : null;
          PlaybackLog.note('interrupted (${type.name}'
              '${forGood ? ", handed over" : ""})');
          if (forGood) {
            _wantPlaying = false;
            _watchForTheSpeaker();
          }
          await _player.pause();
        }
      } else {
        if (_interrupted) PlaybackLog.note('interruption over');
        _interrupted = false;
        if (type == AudioInterruptionType.duck) {
          await _player.setVolume(_volumeFor(current));
        } else if (_wasPlayingWhenInterrupted && _oursAgain(type)) {
          // A phone call or a spoken direction: it was ours before and it is ours
          // again.
          //
          // And the speaker being handed back counts too. Switching to almost any
          // other app takes the audio focus for good — a video, a game, a browser
          // tab with a muted autoplay in it — and Android gives it back the moment
          // that app is done with it. Treating that as "somebody stopped the music"
          // is why playback stopped when you looked at something else and never came
          // back, while turning the screen off, which takes no focus from anybody,
          // was fine the whole time.
          PlaybackLog.note('the speaker is ours again');
          _startPlayback();
        }
      }
      _emit(force: true);
    }

  /// Wait for whoever took the speaker to stop using it.
  ///
  /// Android's permanent focus loss is exactly that — permanent. Nothing is coming
  /// back: the system drops the listener, and the app that took it has no obligation
  /// to hand anything over. So this is the other half of "switching to another app
  /// stops the music and it never comes back": almost every app asks for the speaker
  /// when it opens, whether or not it intends to make a sound, and a great many of
  /// them never make one.
  ///
  /// So look, rather than wait: while nothing at all is playing on this phone and it
  /// is not in a call, the speaker is nobody's, and the song that was playing when it
  /// was taken picks up where it left off. If something *is* playing — a video, a
  /// podcast, somebody else's music — this keeps its hands off it, and gives up
  /// entirely after [handedOverFor].
  void _watchForTheSpeaker() {
    // Android's rule, and only Android's: iOS hands the audio session back on its own
    // and the browser has no such notion at all.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _askingForItBack?.cancel();
    _askingForItBack = Timer.periodic(askAgainEvery, (timer) async {
      final handed = _handedOverAt;
      if (handed == null ||
          _disposed ||
          DateTime.now().difference(handed) > handedOverFor) {
        timer.cancel();
        _askingForItBack = null;
        return;
      }
      try {
        final android = AndroidAudioManager();
        if (await android.isMusicActive()) return;   // somebody is using it
        final mode = await android.getMode();
        if (mode == AndroidAudioHardwareMode.inCall ||
            mode == AndroidAudioHardwareMode.inCommunication ||
            mode == AndroidAudioHardwareMode.ringtone) {
          return;                                    // a call is not ours to interrupt
        }
        timer.cancel();
        _askingForItBack = null;
        _handedOverAt = null;
        PlaybackLog.note('nothing else is using the speaker — picking it back up');
        await (await AudioSession.instance).setActive(true);
        _startPlayback();
        _emit(force: true);
      } catch (_) {
        // Not Android, or nothing will say. Leave the music where it is.
        timer.cancel();
        _askingForItBack = null;
      }
    });
  }

  /// Whether the end of this interruption is ours to start playing again from.
  ///
  /// A transient one always is — it was ours before the phone call and it is ours
  /// after. A permanent one is only if we are still the last thing that was playing
  /// and it has not been long: the person may have gone to another app for a minute,
  /// and they may have put the phone down for a day.
  bool _oursAgain(AudioInterruptionType type) {
    if (type == AudioInterruptionType.pause) return true;
    final handed = _handedOverAt;
    if (handed == null) return false;
    _handedOverAt = null;
    return DateTime.now().difference(handed) <= handedOverFor;
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
    // Cheap, and the same question either way: is this player still doing what the
    // screen says it is doing.
    _checkTheScreenAgreesWithTheSpeaker();
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
        //
        // Counted as one of our own edits while it happens: this pause is a step in
        // getting the music back, not somebody pressing pause on the notification.
        _mutating++;
        try {
          await _player.pause();
        } catch (_) {
          // A dead platform cannot be paused. It is about to be replaced anyway.
        } finally {
          _mutating--;
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
    // Which *row* is playing, not which song. Two rows holding the same track are the
    // same track, so a queue with a song in it twice could only be searched by
    // distance — and a tie went to the copy nearer the top, which is playback sliding
    // from copy two back to copy one and then round again.
    final anchorRow = current?.queueItemId;
    _queueId = queue.id;
    _items = queue.items;
    _windowFrom = queue.windowFrom;
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
      final moved = _relocate(previousIndex, anchor, row: anchorRow);
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

    // The cursor counts the whole queue; the slice we hold starts somewhere in it.
    _syncOrder(
        keepItemIndex:
            (queue.cursorIndex - _windowFrom).clamp(0, _items.length - 1));
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
  int _relocate(int previousIndex, int trackId, {int? row}) {
    // The row itself, where the queue gave us one: exact, and the only thing that can
    // tell two copies of a song apart. An older server sends no row names, and then
    // this falls through to the nearest copy as it always did.
    if (row != null) {
      for (var i = 0; i < _items.length; i++) {
        if (_items[i].queueItemId == row) return i;
      }
      // The row is gone — somebody removed the copy that was playing. Fall through to
      // the nearest other copy rather than jumping to the top of the queue.
    }
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
  ///
  /// Returns the new order of what comes after the song playing, as track ids, so the
  /// server can be told to keep *this* order rather than dealing its own — which it
  /// used to, so the list reshuffled a second time when its answer arrived. Null when
  /// there was nothing worth rearranging.
  List<int>? shuffleWhatIsComing() {
    if (_items.length - index < 3) return null;  // nothing worth rearranging
    final at = index;
    final rest = _items.sublist(at + 1)..shuffle(math.Random());
    _items = [..._items.sublist(0, at + 1), ...rest];
    _rebuildOrder(keepItemIndex: at);
    _queuedNextId = null;                       // what comes next is a different song
    unawaited(_queueNext());
    _emit(force: true);
    return [for (final t in rest) t.id];
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
    final playingRow = current?.queueItemId;
    final items = [..._items];
    items.insert(to, items.removeAt(from));
    _items = items;
    // Keep playing what is playing: it has a new index in the list now.
    final at =
        playing == null ? index : _relocate(index, playing, row: playingRow);
    _rebuildOrder(keepItemIndex: at < 0 ? 0 : at);
    unawaited(_queueNext());
    _emit(force: true);
  }

  /// Move several rows at once, keeping their own order.
  void moveManyLocally(List<int> froms, int to) {
    final picked = ({...froms}.toList()..sort());
    if (picked.isEmpty || picked.any((p) => p < 0 || p >= _items.length)) return;
    final playing = current?.id;
    final playingRow = current?.queueItemId;
    final block = [for (final p in picked) _items[p]];
    final rest = [
      for (var i = 0; i < _items.length; i++)
        if (!picked.contains(i)) _items[i]
    ];
    final at = to.clamp(0, rest.length);
    _items = [...rest.sublist(0, at), ...block, ...rest.sublist(at)];
    final now =
        playing == null ? index : _relocate(index, playing, row: playingRow);
    _rebuildOrder(keepItemIndex: now < 0 ? 0 : now);
    _queuedNextId = null;
    unawaited(_queueNext());
    _emit(force: true);
  }

  /// Take a row out now, for the same reason.
  void removeLocally(int pos) {
    if (pos < 0 || pos >= _items.length) return;
    final playing = current?.id;
    final playingRow = current?.queueItemId;
    final items = [..._items]..removeAt(pos);
    _items = items;
    if (items.isEmpty) {
      _order = const [];
      _orderPos = 0;
      _emit(force: true);
      return;
    }
    final at = playing == null
        ? index
        : _relocate(index, playing, row: playingRow);
    _rebuildOrder(keepItemIndex: at < 0 ? pos.clamp(0, items.length - 1) : at);
    unawaited(_queueNext());
    _emit(force: true);
  }

  void setRepeat(QueueRepeat mode) {
    repeat = mode;
    finished = false;
    if (mode == QueueRepeat.one) {
      // The engine may already be holding the next song, handed over while repeat was
      // off. Left there, it plays: the platform walks its own playlist without asking,
      // and "repeat this one" turned into "play the next one" every time it was
      // switched on mid-song.
      unawaited(_dropQueuedNext());
    } else {
      unawaited(_queueNext());
    }
    _emit(force: true);
  }

  /// Take back whatever was queued behind the playing song.
  Future<void> _dropQueuedNext() async {
    if (_queuedNextId == null) return;
    _queuedNextId = null;
    _mutating++;
    try {
      final at = _engineAt;
      final length = _player.audioSources.length;
      if (length > at + 1) {
        await _player.removeAudioSourceRange(at + 1, length);
      }
    } catch (_) {
      // A platform that never took the playlist has nothing to take back.
    } finally {
      _mutating--;
    }
  }

  // ------------------------------------------------------------------ playback
  /// Play a specific track, identified by what it *is* rather than where it was.
  ///
  /// A list index is only valid for the frame it was rendered in: a server event or a
  /// radio append can reorder the queue between the row being drawn and the finger
  /// landing on it, and then the index points at a different song. The index is kept
  /// as a hint so the right copy is chosen when a track appears more than once.
  ///
  /// [row] is the queue's own name for the row, where whoever is asking knows it —
  /// another device saying which copy it is on. [startAt] is for joining a song that is
  /// already under way somewhere else: starting at the top and seeking afterwards is a
  /// second of the intro before the music jumps.
  Future<void> playTrack(int trackId, {int? indexHint, int? row, Duration? startAt}) async {
    final itemIndex = _relocate(indexHint ?? index, trackId, row: row);
    if (itemIndex < 0) return;
    final pos = _order.indexOf(itemIndex);
    if (pos < 0) return;
    await _playOrderPos(pos, startAt: startAt);
  }

  /// Where the engine is this instant, rather than where the last snapshot said.
  ///
  /// Snapshots are for drawing and come a few times a second at best — and not at all
  /// while nothing is listening for them. What is told to *other* devices is carried
  /// forward by their clocks from the moment it is said, so it has to be true then.
  Duration get livePosition =>
      _loadedTrackId != null && _loadedTrackId == current?.id
          ? _player.position
          : _pendingStart;

  /// Move to a song without making a sound.
  ///
  /// For a guest in a jam who is following the room but not listening to it on this
  /// device: the screen has to show what everyone is playing, and the audio has to
  /// stay off. Loading the stream to immediately pause it would be a download nobody
  /// asked for, on somebody's phone data, for a song they are not hearing.
  Future<void> showTrack(int trackId, {int? row}) async {
    final itemIndex = _relocate(index, trackId, row: row);
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
    // A queue that ran out still holds its last song, played to the end. Asking for
    // that song again has to load it afresh from the top: the engine sitting at the
    // end of it plays nothing, completes at once, and says "End of queue" again.
    final ranOut = finished;
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
      // The same song on another row is still another row. Playing the second copy of
      // a song while the first was loaded used to load nothing, so the engine went on
      // naming copy one — and every few seconds the watchdog believed the engine,
      // moved the screen back to copy one, and the queue hopped between the two.
      final otherRow = _loadedRow != null &&
          track.queueItemId != null &&
          _loadedRow != track.queueItemId;
      if (_loadedTrackId != track.id || otherRow || ranOut) {
        await _loadCurrent(startAt: ranOut ? Duration.zero : startAt, token: token);
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
    _handedOverAt = null;
    _askingForItBack?.cancel();
    _askingForItBack = null;
    // Asked for, so nothing is interrupting us any more — and the watchdog is allowed
    // to do its job again even if the "interruption over" event never arrived.
    _interrupted = false;
    unawaited(Keepalive.set(true));
    // And what came of it: a few seconds after the first play is the moment the
    // notification should be up, the service in the foreground and the session alive.
    // Asking only on the way out of the app means the answer always arrives after the
    // damage, and never says what it was like while the music was actually playing.
    Timer(const Duration(seconds: 5), () => PlaybackLog.checkTheService());
    unawaited(Keepalive.mayWeShowThePlayer().then((_) {
      // What the answer was. A refusal is not a failure to play — it is the music
      // stopping ten seconds after the app is switched away from, which is worth
      // saying on the screen rather than in a log nobody reads.
      unawaited(onNotificationAnswer?.call());
    }));
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
    // Stopped on purpose: the speaker is not owed back to anybody.
    _handedOverAt = null;
    _askingForItBack?.cancel();
    _askingForItBack = null;
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
      if (_waitingForTrack == null) _startPlayback();
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
      } else if (finished) {
        // Play, at the end of the queue. Whatever was added since it ran out is what
        // comes next; with nothing added, the last song again from the top — which is
        // what every player does, and where this one used to do nothing at all.
        if (_orderPos + 1 < _order.length) {
          await _advance(1);
        } else {
          await _playOrderPos(_orderPos);
        }
        return;
      } else {
        if (_loadedTrackId == null) await _loadCurrent();
        // A song still downloading is waited for, not played: asking the engine to
        // play nothing set "wanted" and had the watchdog reloading an empty player
        // every five seconds until it gave up. onTrackReady starts it when it lands.
        if (_waitingForTrack == null) _startPlayback();
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
      // Through seek(), not the engine directly: the furthest point heard has to come
      // back to the top with it, or a stall a minute later revives the song from where
      // it was before "previous" was pressed.
      await seek(Duration.zero);
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
    _mutating++;
    try {
      if (kIsWeb) {
        await _player.pause();
        return;
      }
      await _player.stop();
    } finally {
      _mutating--;
    }
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

    // Where these start and end, before it is needed: the next song's has to be here
    // at the moment it begins, not a request afterwards.
    if (seamless) {
      for (final soon in run) {
        unawaited(timing.of(soon));
      }
    }

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

  /// A signed key for the stream, unless the song is on the device.
  ///
  /// A kept song is played from its file and asks the server nothing — except that it
  /// used to ask for a stream key first, like any other, and with no connection that
  /// request failed and took the play with it. Music kept for the flight did not play
  /// on the flight.
  Future<void> _keyFor(Track track) async {
    if (offlinePath?.call(track.id) != null) return;
    await api.ensureStreamKey();
  }

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
          // Which row of the queue this is. The engine hands the tag back with
          // whatever it is playing, and that is how the screen is kept honest — see
          // _engineIsPlaying.
          extras: {'row': track.queueItemId},
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
        extras: {'row': track.queueItemId},
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
      await _keyFor(next);
      final at = _engineAt;
      final length = _player.audioSources.length;
      if (length > at + 1) {
        // Something else was queued and is no longer next. Dropping what comes after
        // the playing item does not touch the playing item.
        await _player.removeAudioSourceRange(at + 1, length);
      }
      await _player.insertAudioSource(at + 1, _sourceFor(next));
    } catch (_) {
      // A platform that will not take a playlist still works the old way: the track
      // ends, Dart notices, and the next one is loaded. Slower, not broken.
    } finally {
      // Marked whether or not it worked, and this is the important part.
      //
      // Clearing it on failure meant a prefetch that could not succeed was tried again
      // on the very next call — and this is called on every queue update, which with a
      // couple of hundred songs downloading in the background is several times a
      // second. Every attempt hands the engine a new playlist, and every one of those
      // makes it re-prepare and re-open the stream: the log is pages of
      // "playing loading" and "playing buffering" a second or two apart, which is the
      // music stuttering, and it is this loop doing it.
      //
      // One attempt per track. If it did not take, the old path still works — the song
      // ends, Dart notices, and loads the next one.
      _queuedNextId = next.id;
      _mutating--;
    }
  }

  /// The song the engine is actually playing, as it was handed to it.
  ///
  /// Every source carries a MediaItem with the track's id and the queue row it came
  /// from, and the engine gives that tag back with whatever it is playing. So this is
  /// not an inference from indexes and expectations — it is the thing itself, and it
  /// is what the screen is checked against.
  ({int trackId, int? row})? _engineIsPlaying() {
    final tag = _player.sequenceState.currentSource?.tag;
    if (tag is! MediaItem) return null;
    final id = int.tryParse(tag.id);
    if (id == null) return null;
    final row = tag.extras?['row'];
    return (trackId: id, row: row is int ? row : null);
  }

  /// Where a song the engine names sits in the queue: its own row for choice, and
  /// failing that the nearest copy at or after where playback was.
  int _orderPosOf({required int trackId, int? row}) {
    if (row != null) {
      for (var i = 0; i < _order.length; i++) {
        final item = _items[_order[i]];
        if (item.queueItemId == row) return i;
      }
    }
    // Forwards from here first: a queue with the same song twice would otherwise send
    // the screen back to the earlier copy every time the engine moved on.
    for (var step = 1; step <= _order.length; step++) {
      final i = (_orderPos + step) % _order.length;
      if (_items[_order[i]].id == trackId) return i;
    }
    return -1;
  }

  /// The engine moved on by itself, because the next song was already in its playlist.
  /// Catch our own bookkeeping up to it rather than reloading anything.
  void _onEngineIndex(int? at) {
    if (at == null || at == _engineIndex || _mutating > 0) return;
    _engineIndex = at;
    // What it moved *to*, from the engine rather than from what we assumed it would
    // be. An index that advanced by two — a source dropped, a platform that skipped a
    // dead stream — used to leave the screen on the previous song for the rest of the
    // session, because anything other than "exactly one along" was ignored.
    final playing = _engineIsPlaying();
    if (playing == null) return;
    if (playing.trackId == current?.id && playing.row == current?.queueItemId) return;

    final pos = _orderPosOf(trackId: playing.trackId, row: playing.row);
    if (pos < 0) return;                        // not in the queue we hold; leave it

    _recordListen(completed: true);
    _orderPos = pos;
    _loadedTrackId = playing.trackId;
    _loadedRow = playing.row;
    _queuedNextId = null;
    _waitingForTrack = null;
    finished = false;
    _pendingStart = Duration.zero;
    _soundEndsFor = null;
    // The engine started it at the top of the file. If that is a second of nothing,
    // go to where the sound is: it is already buffered, so this is not a wait.
    final arrived = current;
    if (arrived != null) {
      final top = _topOf(arrived);
      if (top > Duration.zero && _player.position < top) {
        _pendingStart = top;
        _heardUpTo = top;
        unawaited(_player.seek(top).catchError((_) {}));
      }
    }
    _emit(force: true);
    _saveCursor();
    unawaited(_lookAhead());
    unawaited(_queueNext());
  }

  /// Run something while this player counts every engine event as its own doing.
  ///
  /// A test needs one way to produce the state this is all about: a transition that
  /// happened while an edit was in flight and was therefore not acted on, leaving the
  /// screen naming one song and the speaker playing another.
  @visibleForTesting
  Future<void> whileBusy(Future<void> Function() body) async {
    _mutating++;
    try {
      await body();
    } finally {
      _mutating--;
    }
  }

  /// Is the song on the screen the song coming out of the speaker?
  ///
  /// It is supposed to be, and every path that changes one changes the other — but a
  /// transition that goes an unexpected way, a queue that was rewritten underneath a
  /// hand-over or a platform that moved on its own leaves the two apart, and from the
  /// outside that is the player naming one song while playing another, for as long as
  /// it takes to skip out of it. The engine is the authority here: it is the one that
  /// is making the sound.
  void _checkTheScreenAgreesWithTheSpeaker() {
    if (_mutating > 0 || _waitingForTrack != null) return;
    if (!_player.playing) return;
    final playing = _engineIsPlaying();
    if (playing == null) return;
    final shown = current;
    if (shown != null &&
        shown.id == playing.trackId &&
        (playing.row == null || shown.queueItemId == playing.row)) {
      return;
    }
    // The right song, under a row name this queue no longer has — a reorder renamed
    // the rows, or the list was patched. That is agreement: going looking for "the
    // nearest other copy" here is what made a song queued twice hop between its copies.
    if (shown != null &&
        shown.id == playing.trackId &&
        !_items.any((t) => t.queueItemId == playing.row)) {
      return;
    }
    final pos = _orderPosOf(trackId: playing.trackId, row: playing.row);
    if (pos < 0 || pos == _orderPos) return;
    PlaybackLog.note('screen said ${shown?.id}, speaker says ${playing.trackId}'
        ' — following the speaker');
    _orderPos = pos;
    _loadedTrackId = playing.trackId;
    _loadedRow = playing.row;
    _queuedNextId = null;
    finished = false;
    _emit(force: true);
    _saveCursor();
    unawaited(_queueNext());
  }

  Future<void> _loadCurrent({Duration? startAt, int? token}) async {
    final mine = token ?? ++_loadToken;
    final track = current;
    if (track == null) return;
    // From the top means from where the sound starts.
    if (startAt == null || startAt == Duration.zero) {
      final top = _topOf(track);
      if (top > Duration.zero) startAt = top;
    }
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
      await _keyFor(track);
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
      _loadedRow = track.queueItemId;
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
    if (_queuedNextId != null && repeat != QueueRepeat.one) {
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
      for (final t in _items) t.id == trackId ? fresh.inRowOf(t) : t
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
      for (final t in _items) t.id == trackId ? fresh.inRowOf(t) : t
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
    // The copy we are standing on, when that is the one: a song in the queue twice
    // would otherwise start from its first copy whichever one was being waited for.
    final waitingPos = current?.id == _waitingForTrack
        ? _orderPos
        : _order.indexWhere((i) => _items[i].id == _waitingForTrack);
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

  /// Where the slice this player holds starts, in the whole queue.
  ///
  /// A long queue arrives a few hundred rows at a time — see Queue.windowed — so the
  /// index of a song in `_items` is not its place in the queue, and the cursor the
  /// server keeps is a place in the queue.
  int _windowFrom = 0;

  /// Where the listener is, counted in the whole queue rather than in the slice.
  int get whereInQueue => _windowFrom + index;

  /// Which row of the whole queue the slice held here starts at. Row positions sent
  /// to the server are counted in the whole queue, and a list on screen counts from
  /// the top of the slice — the two differ by exactly this.
  int get windowFrom => _windowFrom;

  void _saveCursor() {
    final qid = _queueId;
    if (qid == null) return;
    onCursor?.call(qid,
        cursorIndex: whereInQueue, positionMs: _player.position.inMilliseconds);
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
    _watchForTheEndOfTheSound();
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
      // Asked to play and not yet making a sound: the stream is still opening, or
      // has run dry. The one state that looks exactly like "broken" from the outside
      // unless something says otherwise.
      buffering: _player.playing &&
          (_player.processingState == ProcessingState.loading ||
              _player.processingState == ProcessingState.buffering),
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
    _disposed = true;
    _cursorTimer?.cancel();
    _watchdog?.cancel();
    _askingForItBack?.cancel();
    _soundEnds?.cancel();
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

  /// The engine wants to play and is waiting on the network to let it.
  final bool buffering;
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
    this.buffering = false,
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
