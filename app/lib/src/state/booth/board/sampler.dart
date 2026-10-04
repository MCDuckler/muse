// The board's voices: a player per pad that is ready, each parked at its sound's
// start, so that a press is a seek and a play and nothing slower.
//
// Grown from FxChannel, which does the same for the automix's own shots; this one
// keeps its sounds between presses, plays several at once, and knows the four ways a
// pad plays (PadMode). It knows nothing of banks or keys or beats: Soundboard decides
// *when* a voice fires; this is *how*.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../deck_router.dart';
import 'pad_spec.dart';
import 'samples.dart';

/// One pad's player, with its sound in it.
class Voice {
  Voice._(this.key, this.player, this.sample, this.spec);

  /// Which pad this is the voice of, as the board names it ('A:3').
  final String key;
  final AudioPlayer player;
  Sample sample;
  PadSpec spec;

  /// Whether it is making a sound.
  bool sounding = false;

  /// When it was fired, by the wall clock, for the sweep across the pad.
  DateTime? firedAt;

  /// Whether a hold pad is still held.
  bool held = false;

  /// The last time it was pressed: the ones pressed longest ago give up their player
  /// first when the board needs one.
  DateTime pressedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The volume it was last given, so a hold's fade can go back up.
  double volume = 1.0;

  /// Whether a fade has the volume down: a press mid-fade puts it back first.
  bool _fading = false;

  Timer? _end;
  StreamSubscription<PlayerState>? _state;

  /// Counts the presses. A fade that started before the latest press stops touching
  /// the player the moment it notices: see Sampler._quiet.
  int _gen = 0;

  /// The sound being loaded into the player, when it is; a press waits for it rather
  /// than playing a player with nothing in it yet.
  Future<void>? _loading;

  /// How long the sound plays, trim to trim.
  Duration get length {
    final out = spec.trimOut ?? sample.length;
    final l = out - spec.trimIn;
    return l <= Duration.zero ? sample.length - spec.trimIn : l;
  }

  /// How far through its sound this voice is, 0..1, by the clock. Null while quiet.
  double? progressAt(DateTime now) {
    final at = firedAt;
    if (!sounding || at == null) return null;
    final l = length.inMicroseconds;
    if (l <= 0) return 0;
    final t = now.difference(at).inMicroseconds / l;
    return spec.mode == PadMode.loop ? t - t.floor() : t.clamp(0.0, 1.0);
  }
}

/// The players, and what each is playing.
class Sampler {
  Sampler({
    AudioPlayer Function()? newPlayer,
    SampleLibrary? library,
    double Function(double level)? playerVolume,
    this.most = 20,
  })  : _newPlayer = newPlayer ?? _deviceVoice,
        library = library ?? SampleLibrary(),
        _playerVolume = playerVolume ?? ((x) => x);

  final AudioPlayer Function() _newPlayer;
  final SampleLibrary library;

  /// The engine's own law for a gain (mpv's volume is a cube): see Mixer.playerVolume.
  final double Function(double) _playerVolume;

  /// How many voices may be kept warm at once.
  final int most;

  final _voices = <String, Voice>{};

  /// The voices there are, by pad key.
  Map<String, Voice> get voices => Map.unmodifiable(_voices);

  /// Told whenever a voice starts or stops sounding.
  final changed = SamplerPings();

  /// Whether this device can put a sound anywhere a player will take it.
  bool get can => _can;
  bool _can = true;

  /// A player for a voice: on an iPhone or an iPad, libmpv where the decks are —
  /// AVPlayer's volume is linear, and the gain law below is the engine's.
  static AudioPlayer _deviceVoice() => AudioPlayer(
        engine: DeckRouter.active ? DeckRouter.mpv : null,
        handleInterruptions: false,
        useProxyForRequestHeaders: false,
      );

  /// A voice for [key] with [sample] loaded and parked at [spec]'s start. The same
  /// sample already in it is kept; a different one is loaded over it. Returns null
  /// where the sound could not be readied.
  Future<Voice?> warm(String key, Sample sample, PadSpec spec, {required double level}) async {
    var v = _voices[key];
    final same = v != null && v.sample.id == sample.id;
    if (v == null) {
      if (_voices.length >= most) _evict();
      v = Voice._(key, _newPlayer(), sample, spec);
      _voices[key] = v;
      v._state = v.player.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed) _ended(v!);
      });
    }
    v.spec = spec;
    v.sample = sample;
    try {
      if (!same) {
        // Written down before the first await: a press in the meantime finds the
        // sample's id already on the voice and would play a player with nothing in
        // it, so it waits on this instead.
        final loading = Completer<void>();
        v._loading = loading.future;
        try {
          final source = await library.pathFor(sample);
          if (source == null) {
            _can = sample.source is! ServerSource ? false : _can;
            await _drop(v);
            return null;
          }
          if (kIsWeb) {
            await v.player.setUrl(source);
          } else {
            await v.player.setFilePath(source);
          }
          await v.player.seek(spec.trimIn);
        } finally {
          loading.complete();
          if (identical(v._loading, loading.future)) v._loading = null;
        }
      } else if (v._loading != null) {
        // The same sound, still on its way in from an earlier warm.
        await v._loading;
      }
      await setLevel(key, level);
      return v;
    } catch (e) {
      debugPrint('board: ${sample.name} could not be readied — $e');
      await _drop(v);
      return null;
    }
  }

  /// The quiet voice pressed longest ago gives up its player.
  void _evict() {
    Voice? oldest;
    for (final v in _voices.values) {
      if (v.sounding) continue;
      if (oldest == null || v.pressedAt.isBefore(oldest.pressedAt)) oldest = v;
    }
    if (oldest != null) unawaited(_drop(oldest));
  }

  Future<void> _drop(Voice v) async {
    _voices.remove(v.key);
    v._end?.cancel();
    await v._state?.cancel();
    try {
      await v.player.dispose();
    } catch (_) {}
  }

  /// Voices for pads not in [keep] that are quiet, let go — a bank that was turned
  /// away from, apart from what is still sounding on it.
  Future<void> cool(Set<String> keep) async {
    for (final v in _voices.values.toList()) {
      if (!keep.contains(v.key) && !v.sounding) await _drop(v);
    }
  }

  /// [key]'s sound, from its start, now. A voice already sounding starts over.
  Future<void> fire(String key, {DateTime? at}) async {
    var v = _voices[key];
    if (v == null) return;
    v.pressedAt = at ?? DateTime.now();
    // This press outranks any fade still running on the voice: see _quiet.
    final gen = ++v._gen;
    try {
      // The sound still loading: wait for it, within reason. A pad pressed the moment
      // its bank came up used to play a player with nothing in it — silence.
      final loading = v._loading;
      if (loading != null) {
        await loading.timeout(const Duration(seconds: 3), onTimeout: () {});
        v = _voices[key];
        if (v == null || v._gen != gen) return;
      }
      v._end?.cancel();
      if (v._fading) {
        // Pressed again mid-fade: back up to its level before it sounds.
        await v.player.setVolume(_playerVolume(v.volume));
      }
      await v.player.seek(v.spec.trimIn);
      v.sounding = true;
      v.firedAt = DateTime.now();
      v.held = v.spec.mode == PadMode.hold;
      unawaited(v.player.play());
      _armEnd(v);
      changed.ping();
    } catch (e) {
      debugPrint('board: ${_voices[key]?.sample.name ?? key} did not fire — $e');
    }
  }

  /// The end of the sound: a loop goes round, anything else stops. A sound trimmed
  /// at its own end is stopped by the engine saying it completed (see warm); a
  /// trim-out earlier than that is this timer's.
  void _armEnd(Voice v) {
    v._end?.cancel();
    final l = v.length;
    if (l <= Duration.zero) return;
    v._end = Timer(l, () {
      if (!v.sounding) return;
      if (v.spec.mode == PadMode.loop) {
        unawaited(() async {
          try {
            await v.player.seek(v.spec.trimIn);
            v.firedAt = DateTime.now();
            _armEnd(v);
          } catch (_) {}
        }());
      } else {
        unawaited(stop(key: v.key));
      }
    });
  }

  void _ended(Voice v) {
    if (!v.sounding) return;
    if (v.spec.mode == PadMode.loop) {
      unawaited(() async {
        try {
          await v.player.seek(v.spec.trimIn);
          await v.player.play();
          v.firedAt = DateTime.now();
          _armEnd(v);
        } catch (_) {}
      }());
      return;
    }
    v._end?.cancel();
    v.sounding = false;
    v.held = false;
    changed.ping();
    // Paused first, then parked. just_audio keeps `playing` true past the end of a
    // sound, and a seek on a playing player plays: parked without the pause, every
    // sound whose engine finished before the end timer did played itself again,
    // unlit — the "plays twice" of a house sound whose file is a few frames shorter
    // than its length says.
    final gen = v._gen;
    unawaited(() async {
      try {
        await v.player.pause();
        if (v._gen != gen) return;       // pressed again meanwhile: its seek, not this
        await v.player.seek(v.spec.trimIn);
      } catch (_) {}
    }());
  }

  /// A hold pad let go: three quick steps down so it does not click, then quiet.
  Future<void> release(String key) async {
    final v = _voices[key];
    if (v == null || !v.sounding) return;
    v.held = false;
    await stop(key: key, fade: const Duration(milliseconds: 30));
  }

  /// [key] quiet, now or over [fade]; every voice when [key] is null.
  Future<void> stop({String? key, Duration fade = Duration.zero}) async {
    final list = key == null ? _voices.values.toList() : [if (_voices[key] != null) _voices[key]!];
    // All at once: every pad let go together, not one after the other.
    await Future.wait([for (final v in list) if (v.sounding) _quiet(v, fade)]);
  }

  Future<void> _quiet(Voice v, Duration fade) async {
    v._end?.cancel();
    v.sounding = false;
    v.held = false;
    changed.ping();
    // A press during the fade wins: the moment one lands, this stops touching the
    // player. It used to carry on and pause the sound the press had just started —
    // a lit pad with nothing coming out of it.
    final gen = v._gen;
    bool superseded() => v._gen != gen;
    try {
      if (fade > Duration.zero) {
        v._fading = true;
        final full = _playerVolume(v.volume);
        for (var i = 2; i >= 0; i--) {
          if (superseded()) return;
          await v.player.setVolume(full * i / 3);
          await Future<void>.delayed(fade ~/ 3);
        }
      }
      if (superseded()) return;
      // Paused and parked, not stopped: a stopped just_audio player gives its
      // engine up, and the next press would have to load the sound again.
      await v.player.pause();
      if (superseded()) return;
      await v.player.seek(v.spec.trimIn);
      if (fade > Duration.zero && !superseded()) {
        await v.player.setVolume(_playerVolume(v.volume));
      }
    } catch (_) {
    } finally {
      if (!superseded()) v._fading = false;
    }
  }

  /// Every sounding voice in choke group [group] but [except], stopped — together,
  /// not one fade after another, so the pad that choked them is not late by their
  /// number.
  Future<void> choke(int group, {required String except}) async {
    if (group <= 0) return;
    await Future.wait([
      for (final v in _voices.values.toList())
        if (v.key != except && v.sounding && v.spec.choke == group)
          _quiet(v, const Duration(milliseconds: 15)),
    ]);
  }

  /// What [key]'s player is told to play at: [level] is the whole law worked out
  /// (pad gain × board level × master), 0..1, before the engine's own curve.
  Future<void> setLevel(String key, double level) async {
    final v = _voices[key];
    if (v == null) return;
    v.volume = level.clamp(0.0, 1.0);
    try {
      await v.player.setVolume(_playerVolume(v.volume).clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// Which voices are sounding now.
  Iterable<Voice> get sounding => _voices.values.where((v) => v.sounding);

  Future<void> dispose() async {
    for (final v in _voices.values.toList()) {
      await _drop(v);
    }
    changed.dispose();
  }
}

/// See [Sampler.changed].
class SamplerPings extends ChangeNotifier {
  void ping() => notifyListeners();
}
