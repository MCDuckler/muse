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

  /// How long the engine takes to accept a source. Nothing interesting happens while
  /// a load is instant: the races this exists to catch all live in the window between
  /// asking for a song and the engine holding it.
  Duration slowness = Duration.zero;

  int index = 0;
  Duration position = Duration.zero;
  bool playing = false;
  ProcessingStateMessage state = ProcessingStateMessage.idle;

  /// Every track is a minute long, which is all the tests need of a duration.
  static const trackLength = Duration(minutes: 1);

  /// How many times *any* engine has been handed a source. Kept off the instance
  /// because a repair may replace the platform player, and a count that disappears
  /// with the thing being counted cannot answer "how many times did it try".
  static int loadCount = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  void close() => _events.close();

  Future<void> _slow() async {
    if (slowness > Duration.zero) await Future<void>.delayed(slowness);
  }

  void _emit() {
    if (_events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
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

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    await _slow();
    sources
      ..clear()
      ..addAll(_urlsOf(request.audioSourceMessage));
    index = request.initialIndex ?? 0;
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
    playing = true;
    calls.add('play');
    _emit();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    playing = false;
    calls.add('pause');
    _emit();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.index != null) index = request.index!;
    position = request.position ?? Duration.zero;
    calls.add('seek ${position.inSeconds}s'
        '${request.index == null ? '' : ' index:${request.index}'}');
    _emit();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

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
    index += 1;
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
    position = trackLength;
    state = ProcessingStateMessage.completed;
    _emit();
    state = ProcessingStateMessage.ready;
  }

  /// Time passing while a song plays.
  void tick(Duration to) {
    position = to;
    _emit();
  }
}
