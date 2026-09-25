// A fake audio engine, so the player's own logic can be tested without a browser.
//
// just_audio talks to a platform through an interface; on the web that is the plugin
// that owns the <audio> element, on Android it is ExoPlayer. Here it is this: a list of
// sources, an index into it, and a stream of the events a real engine would send. That
// is enough to ask the questions that matter — what did the player hand to the engine,
// when, and what did it do when the engine moved on by itself — none of which needs a
// browser, which is what makes this runnable when the browser harness is not.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class FakeJustAudio extends JustAudioPlatform {
  final players = <String, FakeAudioPlayer>{};

  FakeAudioPlayer get only => players.values.last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = FakeAudioPlayer(request.id);
    players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    players.remove(request.id)?.close();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    for (final p in players.values) {
      p.close();
    }
    players.clear();
    return DisposeAllPlayersResponse();
  }
}

class FakeAudioPlayer extends AudioPlayerPlatform {
  FakeAudioPlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();

  /// What is in the engine's playlist, as the URLs it was given.
  final List<String> sources = [];

  /// Every call the player made, in order. The test reads this to see whether a track
  /// change was a *load* (fetch, hand over, start — the slow path) or a step through a
  /// playlist the engine already held.
  final List<String> calls = [];

  // ---------------------------------------------------------------- audio effects
  /// The phone's own equalizer, as a phone reports it: five bands at frequencies of the
  /// maker's choosing, fifteen decibels either way.
  static const bandHz = <double>[60, 230, 910, 3600, 14000];
  final List<double> bandGains = List<double>.filled(bandHz.length, 0);
  final Map<String, bool> effectsOn = {};
  double loudnessGain = 0;

  @override
  Future<AndroidEqualizerGetParametersResponse> androidEqualizerGetParameters(
          AndroidEqualizerGetParametersRequest request) async =>
      AndroidEqualizerGetParametersResponse(
        parameters: AndroidEqualizerParametersMessage(
          minDecibels: -15,
          maxDecibels: 15,
          bands: [
            for (final (i, hz) in bandHz.indexed)
              AndroidEqualizerBandMessage(
                index: i,
                lowerFrequency: hz / 2,
                upperFrequency: hz * 2,
                centerFrequency: hz,
                gain: bandGains[i],
              ),
          ],
        ),
      );

  @override
  Future<AndroidEqualizerBandSetGainResponse> androidEqualizerBandSetGain(
      AndroidEqualizerBandSetGainRequest request) async {
    bandGains[request.bandIndex] = request.gain;
    return AndroidEqualizerBandSetGainResponse();
  }

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse> androidLoudnessEnhancerSetTargetGain(
      AndroidLoudnessEnhancerSetTargetGainRequest request) async {
    loudnessGain = request.targetGain;
    return AndroidLoudnessEnhancerSetTargetGainResponse();
  }

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
      AudioEffectSetEnabledRequest request) async {
    effectsOn[request.type] = request.enabled;
    return AudioEffectSetEnabledResponse();
  }

  /// How long the engine takes to accept a source. Nothing interesting happens while
  /// a load is instant: the races this exists to catch all live in the window between
  /// asking for a song and the engine holding it.
  Duration slowness = Duration.zero;

  int index = 0;

  /// Where the engine was at [_since]. While it plays it moves on from there at
  /// [speed], as a real one does: the position a report carries is where it is now.
  Duration position = Duration.zero;
  DateTime _since = DateTime.now();
  double speed = 1.0;
  bool playing = false;

  /// Bring [position] up to now.
  void _advance() {
    final now = DateTime.now();
    if (playing) {
      position += Duration(
          microseconds: (now.difference(_since).inMicroseconds * speed).round());
    }
    _since = now;
  }
  ProcessingStateMessage state = ProcessingStateMessage.idle;

  /// Every track is a minute long, which is all most tests need of a duration. The
  /// ones holding real records' grids set it longer.
  static Duration trackLength = const Duration(minutes: 1);

  /// How many times *any* engine has been handed a source. Kept off the instance
  /// because a repair may replace the platform player, and a count that disappears
  /// with the thing being counted cannot answer "how many times did it try".
  static int loadCount = 0;

  final _data = StreamController<PlayerDataMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  /// What a platform says about itself. The background wrapper reports the media
  /// session's own play and pause buttons through this — see [pressedElsewhere].
  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  /// Somebody pressed play or pause somewhere that is not this app: the notification,
  /// the lockscreen, a headset button, Android Auto. just_audio_background turns that
  /// into exactly this — the engine's own state changing with nothing in the app
  /// having asked for it.
  void pressedElsewhere({required bool playing}) {
    _advance();
    this.playing = playing;
    calls.add(playing ? 'play elsewhere' : 'pause elsewhere');
    _data.add(PlayerDataMessage(playing: playing));
    _emit();
  }

  void close() {
    _events.close();
    _data.close();
  }

  Future<void> _slow() async {
    if (slowness > Duration.zero) await Future<void>.delayed(slowness);
  }

  void _emit() {
    if (_events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: _since,
      updatePosition: position,
      bufferedPosition: position,
      duration: trackLength,
      icyMetadata: null,
      currentIndex: index,
      androidAudioSessionId: null,
    ));
  }

  List<String> _urlsOf(AudioSourceMessage message) {
    if (message is ConcatenatingAudioSourceMessage) {
      return [for (final child in message.children) ..._urlsOf(child)];
    }
    if (message is UriAudioSourceMessage) return [message.uri];
    return ['(other)'];
  }

  /// Refuse to take a record at all, the way an engine with no decoder for it does.
  /// What the test is after is what the player *writes down* about it.
  bool failLoad = false;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    if (failLoad) {
      calls.add('load refused');
      throw PlatformException(code: 'nope', message: 'cannot open that');
    }
    await _slow();
    sources
      ..clear()
      ..addAll(_urlsOf(request.audioSourceMessage));
    index = request.initialIndex ?? 0;
    _advance();
    position = request.initialPosition ?? Duration.zero;
    state = ProcessingStateMessage.ready;
    loadCount++;
    calls.add('load ${sources.length}');
    _emit();
    return LoadResponse(duration: trackLength);
  }

  /// Refuse to take a queued next track, the way a platform that cannot do playlists
  /// does. The point of the test is what the player does about it, not what it is.
  bool refuseInserts = false;

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    if (refuseInserts) {
      calls.add('insert refused');
      throw PlatformException(code: 'nope', message: 'no playlists here');
    }
    await _slow();
    final urls = [for (final child in request.children) ..._urlsOf(child)];
    sources.insertAll(request.index, urls);
    // A real engine keeps playing what it was playing: inserting above the current
    // item moves it down the list.
    if (request.index <= index) index += urls.length;
    calls.add('insert@${request.index}');
    _emit();
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    sources.removeRange(request.startIndex, request.endIndex);
    if (request.endIndex <= index) {
      index -= request.endIndex - request.startIndex;
    }
    calls.add('remove ${request.startIndex}-${request.endIndex}');
    _emit();
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _advance();
    playing = true;
    calls.add('play');
    _emit();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _advance();
    playing = false;
    calls.add('pause');
    _emit();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.index != null) index = request.index!;
    _advance();
    position = request.position ?? Duration.zero;
    calls.add('seek ${position.inSeconds}s'
        '${request.index == null ? '' : ' index:${request.index}'}');
    _emit();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    volume = request.volume;
    return SetVolumeResponse();
  }

  /// The last volume the engine was told.
  double volume = 1.0;

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    // A new rate from here on, not for the time already played: a report now, the
    // way the real engine's next position report is.
    _advance();
    speed = request.speed;
    _emit();
    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    calls.add('dispose');
    return DisposeResponse();
  }

  // ---------------------------------------------------------------- the engine acts
  /// The song ended and the engine moved to the next item by itself — a gapless
  /// transition, which is what a queued next source is *for*.
  void advanceByItself() {
    if (index + 1 >= sources.length) return;
    _advance();
    index += 1;
    position = Duration.zero;
    playing = true;
    state = ProcessingStateMessage.ready;
    _emit();
  }

  /// The engine skipped a source without being asked: a stream that would not open,
  /// a platform dropping a dead item and moving on. The app used to ignore any move
  /// that was not exactly one along, which left the screen a song behind for good.
  void jumpBy(int steps) {
    _advance();
    index = (index + steps).clamp(0, sources.length - 1);
    position = Duration.zero;
    playing = true;
    state = ProcessingStateMessage.ready;
    _emit();
  }

  /// The engine has run out of audio and is waiting for more — a network that went
  /// away, a stream the server stopped feeding. This is what a real stall looks like:
  /// the state changes and then nothing else happens at all.
  void stall() {
    state = ProcessingStateMessage.buffering;
    _emit();
  }

  /// The engine stopped on its own and said nothing more about it.
  ///
  /// What a phone actually does to a background app: the stream's socket is closed
  /// while the screen is off, or the platform takes the player back, and playback ends
  /// with no error anybody asked for. From Dart it looks exactly like this — playing
  /// goes false, the state goes idle, and nothing else ever happens.
  void die() {
    _advance();
    playing = false;
    state = ProcessingStateMessage.idle;
    _emit();
  }

  /// Audio again.
  void recover() {
    state = ProcessingStateMessage.ready;
    _emit();
  }

  /// The song ended and the engine stopped there, waiting to be told what to do.
  void reachEnd() {
    _advance();
    position = trackLength;
    state = ProcessingStateMessage.completed;
    _emit();
    state = ProcessingStateMessage.ready;
  }

  /// Time passing while a song plays.
  void tick(Duration to) {
    _advance();
    position = to;
    _emit();
  }
}
