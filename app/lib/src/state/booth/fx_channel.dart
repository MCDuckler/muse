// The third voice: what the booth plays that is neither record.
//
// The decks are two players through a mixer. This is one more player, off to the side
// of the crossfader, that plays a sound the booth made itself (fx_sounds.dart) — a
// riser under the last bars of a build, a whoosh over the change, a hit on the one.
// It is not a deck: it has no record, no beat, no tempo, nothing to sync, and the
// fader does not touch it. It has a level and a moment, and that is all.
//
// The sounds are made ready *before* the move starts, because rendering sixteen
// seconds of noise and handing it to an engine takes long enough to miss a downbeat
// by, and a riser that arrives a beat late is worse than no riser. Booth.go renders
// every shot in a plan while it is still waiting for its bar; firing one is then a
// seek to zero and a play.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'fx_sink_none.dart' if (dart.library.io) 'fx_sink_io.dart' as disk;
import 'fx_sink_none.dart' if (dart.library.js_interop) 'fx_sink_web.dart' as web;
import 'fx_sounds.dart';

/// Where a rendered sound can be put on this platform, or null where it cannot.
Future<String?> _sourceFor(Uint8List wav, String key) async =>
    kIsWeb ? web.fxSource(wav, key) : disk.fxSource(wav, key);

void _forget() {
  if (kIsWeb) {
    web.fxForget();
  } else {
    disk.fxForget();
  }
}

/// One shot, rendered and loaded, waiting to be fired.
class _Loaded {
  _Loaded(this.player, this.shot, this.gain);
  final AudioPlayer player;
  final FxShot shot;

  /// What the player is told when this fires — the shot's gain, through whatever
  /// correction the engine's volume wants (Mixer.playerVolume).
  final double gain;
}

/// The booth's own sounds, made ready and fired.
class FxChannel {
  FxChannel({AudioPlayer Function()? newPlayer}) : _newPlayer = newPlayer ?? AudioPlayer.new;

  final AudioPlayer Function() _newPlayer;

  /// A player each, up to [_most]: two shots can be wanted at the same instant (the
  /// hit on the one and the whoosh behind it), and one player cannot play two sounds.
  static const _most = 3;
  final _players = <AudioPlayer>[];

  final _ready = <int, _Loaded>{};

  /// Whether this platform can put a rendered sound anywhere a player will take it.
  /// False on a platform with neither a filesystem nor a browser: the moves that need
  /// this are then planned as the plain ones they are built on.
  bool get can => _can;
  bool _can = true;

  AudioPlayer _playerAt(int i) {
    while (_players.length <= i) {
      _players.add(_newPlayer());
    }
    return _players[i];
  }

  /// Render [shots] — each over [beat]-second beats, each [seconds] long — and load
  /// them, so that [fire] is immediate. Whatever was ready before is dropped.
  ///
  /// Returns how many were loaded: a shot past [_most], or one this platform cannot
  /// put anywhere, is not, and the caller simply does not fire it.
  Future<int> load(List<({FxShot shot, double seconds})> shots,
      {required double beat, double Function(double)? volume}) async {
    _ready.clear();
    var loaded = 0;
    for (var i = 0; i < shots.length && i < _most; i++) {
      final (shot: shot, seconds: seconds) = shots[i];
      if (seconds <= 0) continue;
      try {
        // Keyed by everything that changes the samples, so a set that plays the same
        // riser eleven times renders it once.
        final key = '${shot.sound.name}-${(seconds * 1000).round()}ms-${(beat * 1000).round()}bpm';
        final wav = fxWav(renderFx(shot.sound, seconds: seconds, beat: beat));
        final source = await _sourceFor(wav, key);
        if (source == null) {
          _can = false;
          return loaded;
        }
        final player = _playerAt(i);
        // A path on a desk or a phone, a blob's URL in a browser — the two are not
        // handed to a player the same way.
        if (kIsWeb) {
          await player.setUrl(source);
        } else {
          await player.setFilePath(source);
        }
        await player.setVolume((volume ?? (x) => x)(shot.gain).clamp(0.0, 1.0));
        _ready[i] = _Loaded(player, shot, shot.gain);
        loaded++;
      } catch (e) {
        // A sound that will not load is a sound not played. Never a mix that stops.
        debugPrint('booth: ${shots[i].shot.sound.name} could not be readied — $e');
      }
    }
    return loaded;
  }

  /// The shot loaded at [i], from its first sample, now.
  Future<void> fire(int i) async {
    final it = _ready[i];
    if (it == null) return;
    try {
      await it.player.seek(Duration.zero);
      unawaited(it.player.play());
    } catch (e) {
      debugPrint('booth: ${it.shot.sound.name} did not fire — $e');
    }
  }

  /// Everything the channel is playing, stopped — a mix called off part-way through
  /// its build should not leave a riser climbing over nothing.
  Future<void> silence() async {
    for (final p in _players) {
      try {
        await p.stop();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    for (final p in _players) {
      try {
        await p.dispose();
      } catch (_) {}
    }
    _players.clear();
    _ready.clear();
    _forget();
  }
}
