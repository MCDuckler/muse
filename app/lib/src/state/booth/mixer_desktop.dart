import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import 'deck.dart';
import 'mixer.dart';
import 'seam.dart';

/// A desk: the gain as everywhere, and the kills and the filter as mpv's own audio
/// filter chain on the deck's player — shelves and a low- and high-pass from ffmpeg.
Mixer? desktopMixer() =>
    JustAudioMediaKit.instanceIfRegistered == null ? null : DesktopMixer();

/// One chain per deck, put on once and then *turned*, never replaced.
///
/// Setting mpv's `af` builds a new filter graph: the filters start again from
/// nothing, which is a click, and a sweep that set it twenty-five times a second was
/// twenty-five of them. So the whole chain goes on when the deck is first used — every
/// band at 0 dB, both passes mixed out — and from then on each change is an
/// `af-command` to the one filter it concerns, which ffmpeg applies to the running
/// filter without stopping anything.
///
/// The chain ends in a tempo stretcher, always there, so that a change of speed never
/// changes the chain: without one, mpv adds its own the moment a deck's speed leaves
/// 1.0 and takes it away when it comes back, over and over as the booth holds a beat.
///
/// Which stretcher matters more than anything else here. mpv's own (scaletempo2)
/// keeps the tempo right on average by skipping and repeating slivers of the sound, and
/// each one moves the beat: measured on a click track at 0.976×, beats landed 7.8 ms
/// either side of where they belonged and up to 17 ms out — a flam that comes and goes,
/// on every synced record, whatever the booth does. Rubber Band keeps them within
/// 0.2 ms. So it is Rubber Band where this mpv has it (Linux distributions build it
/// in), and mpv's own only where it does not.
class DesktopMixer extends VolumeMixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;

  /// mpv's volume is not a gain: it cubes it — (volume / 100)³ — so that a volume
  /// slider feels even to the ear. Measured on a tone: volume 70.7 came out at −9.0 dB,
  /// 50 at −18.1. Told the booth's levels as they were, the crossfader's middle, meant
  /// as −3 dB a deck (constant power: two records as loud together as one alone), was
  /// −9 dB a deck, and the room went quiet whenever both were up; the channel faders
  /// and the loudness trim were cubed with it. So the cube root goes in, and the
  /// gain the booth meant is the gain that comes out.
  @override
  double toEngine(double level) => level <= 0 ? 0 : math.pow(level, 1 / 3).toDouble();

  @override
  double fromEngine(double volume) => volume * volume * volume;

  final _eq = <String, EqSet>{};
  final _filter = <String, double>{};

  /// Decks whose chain is on, by player; and those where it would not go on (an mpv
  /// with no lavfi), which fall back to setting the chain whole, as before.
  final _installed = <String, String>{};
  final _whole = <String>{};

  /// Which stretcher each deck's chain ended in.
  final _stretcher = <String, String>{};

  /// Each deck's stretcher delay, once measured.
  final _latency = <String, Duration>{};

  NativePlayer? _native(Deck deck) {
    final id = deck.player.platformId;
    if (id == null) return null;
    final platform = JustAudioMediaKit.instanceIfRegistered?.playerFor(id)?.raw.platform;
    return platform is NativePlayer ? platform : null;
  }

  /// The bands and passes every deck carries. Named, so each can be spoken to.
  static const bands = '@wetowl:lavfi=['
      'lowshelf@low=f=250:g=0,'
      'equalizer@mid=f=1000:width_type=o:width=2:g=0,'
      'highshelf@high=f=4000:g=0,'
      'highpass@hp=f=20:m=0,'
      'lowpass@lp=f=15000:m=0'
      ']';

  /// The chains tried, best first: the bands, then the stretcher.
  static const standing = ['$bands,rubberband', '$bands,scaletempo2'];

  /// The same, for a stem deck: the six-channel stems file taken apart into its three
  /// pairs — the drums, the bass and the rest, the voice — each through a level of
  /// its own, mixed back together, and then the bands as on any deck. Each level is
  /// an `af-command` like a band: turned while it plays, with nothing rebuilt.
  static const stemBands = '@wetowl:lavfi=['
      'channelsplit=channel_layout=6c[c0][c1][c2][c3][c4][c5];'
      '[c0][c1]join=inputs=2:channel_layout=stereo,volume@d=1[d];'
      '[c2][c3]join=inputs=2:channel_layout=stereo,volume@r=1[r];'
      '[c4][c5]join=inputs=2:channel_layout=stereo,volume@v=1[v];'
      '[d][r][v]amix=inputs=3:normalize=0,'
      'lowshelf@low=f=250:g=0,'
      'equalizer@mid=f=1000:width_type=o:width=2:g=0,'
      'highshelf@high=f=4000:g=0,'
      'highpass@hp=f=20:m=0,'
      'lowpass@lp=f=15000:m=0'
      ']';
  static const stemStanding = ['$stemBands,rubberband', '$stemBands,scaletempo2'];

  /// Which decks are set up for stems, by name.
  final _stems = <String, bool>{};
  final _levels = <String, StemLevels>{};

  @override
  bool get canStem => true;

  /// Decks asked to get ready before their engine existed.
  final _missed = <String>{};

  @override
  Future<bool> firstLoadMissed(Deck deck) async => _missed.remove(deck.name);

  @override
  Future<bool> beforeLoad(Deck deck, {required bool stems}) async {
    final mpv = _native(deck);
    if (mpv == null) {
      _missed.add(deck.name);
      return false;
    }
    // The record on the same clock as its analysis and its stems: mpv's own reading of
    // an MP4's edit list skips the encoder's first 1024 samples twice, and every
    // YouTube record played 23 ms ahead of the beats found in it — and of its stems,
    // which ffmpeg made. (Measured: 0 samples apart with this, 1115 at 48 kHz without.)
    try {
      await mpv.setProperty('demuxer-lavf-o', 'advanced_editlist=0');
      // Six channels into the chain, not the two the speakers take: left to itself the
      // decoder folds a six-channel file to stereo before any filter sees it, and the
      // stems arrive as one mix on the first pair and silence on the others.
      await mpv.setProperty('ad-lavc-downmix', 'no');
    } catch (_) {}
    final was = _stems[deck.name] ?? false;
    _stems[deck.name] = stems;
    if (was != stems) _installed.remove(deck.name);
    _levels[deck.name] = StemLevels.all;
    if (!await _install(deck, mpv)) return false;
    return stems;
  }

  @override
  Future<void> setStems(Deck deck, StemLevels levels) async {
    if (!(_stems[deck.name] ?? false)) return;
    final was = _levels[deck.name] ?? StemLevels.all;
    _levels[deck.name] = levels;
    final mpv = _native(deck);
    if (mpv == null) return;
    for (final (target, now, before) in [
      ('volume@d', levels.drums, was.drums),
      ('volume@r', levels.rest, was.rest),
      ('volume@v', levels.vocals, was.vocals),
    ]) {
      if ((now - before).abs() < 0.001) continue;
      try {
        await mpv.command(['af-command', 'wetowl', 'volume', now.toStringAsFixed(3), target]);
      } catch (_) {}
    }
  }

  /// What to tell the standing chain for [eq] and [filter]: (filter, command, value).
  /// The passes are mixed in only while the knob is off centre.
  static List<(String, String, String)> commands({required EqSet eq, required double filter}) {
    String db(double v) => v.toStringAsFixed(1);
    final hp = filter > 0 ? 10 * math.pow(8000 / 10, filter) : 20.0;
    // Closing towards 60 Hz on a log scale, like the browser's; never above what a
    // 32 kHz part can carry, which ffmpeg would refuse.
    final lp = filter < 0 ? math.min(15000.0, 22000 * math.pow(60 / 22000, -filter)) : 15000.0;
    return [
      ('lowshelf@low', 'g', db(eq.low)),
      ('equalizer@mid', 'g', db(eq.mid)),
      ('highshelf@high', 'g', db(eq.high)),
      ('highpass@hp', 'f', '${hp.round()}'),
      ('highpass@hp', 'm', filter > 0 ? '1' : '0'),
      ('lowpass@lp', 'f', '${lp.round()}'),
      ('lowpass@lp', 'm', filter < 0 ? '1' : '0'),
    ];
  }

  /// The whole chain as one string, for an mpv the standing chain would not go on.
  static String chain({required EqSet eq, required double filter}) {
    String db(double v) => v.toStringAsFixed(1);
    final parts = <String>[
      if (eq.low != 0) 'lowshelf=f=250:g=${db(eq.low)}',
      if (eq.mid != 0) 'equalizer=f=1000:width_type=o:width=2:g=${db(eq.mid)}',
      if (eq.high != 0) 'highshelf=f=4000:g=${db(eq.high)}',
    ];
    if (filter < 0) {
      final hz = 22000 * math.pow(60 / 22000, -filter);
      parts.add('lowpass=f=${hz.round()}');
    } else if (filter > 0) {
      final hz = 10 * math.pow(8000 / 10, filter);
      parts.add('highpass=f=${hz.round()}');
    }
    return parts.isEmpty ? '' : 'lavfi=[${parts.join(',')}]';
  }

  /// Put the standing chain on [deck]'s player, once per player. Says whether it is on.
  Future<bool> _install(Deck deck, NativePlayer mpv) async {
    final id = deck.player.platformId!;
    if (_installed[deck.name] == id) return true;
    final stems = _stems[deck.name] ?? false;
    if (_whole.contains(id) && !stems) return false;
    for (final chain in stems ? stemStanding : standing) {
      try {
        await mpv.setProperty('af', chain);
        final got = await mpv.getProperty('af');
        if (got.contains('wetowl') && got.contains(chain.split(',').last)) {
          _installed[deck.name] = id;
          _stretcher[deck.name] = chain.split(',').last;
          debugPrint('mixer: deck ${deck.name} carries ${chain.split(',').last}');
          return true;
        }
      } catch (e) {
        debugPrint('mixer: ${chain.split(',').last} would not go on ($e)');
      }
    }
    if (!stems) _whole.add(id);
    return false;
  }

  Future<void> _apply(Deck deck, {List<(String, String, String)>? only}) async {
    final mpv = _native(deck);
    if (mpv == null) return;
    final eq = _eq[deck.name] ?? EqSet.flat, filter = _filter[deck.name] ?? 0;
    if (await _install(deck, mpv)) {
      for (final (target, command, value) in only ?? commands(eq: eq, filter: filter)) {
        try {
          await mpv.command(['af-command', 'wetowl', command, value, target]);
        } catch (_) {}
      }
      return;
    }
    // The chain would not go on: this mpv lacks what it is made of. The bands and the
    // filter are left alone rather than set as a whole chain on every turn of a knob —
    // an mpv that accepts the words and then cannot build the graph drops the sound
    // altogether, which is what turning a knob did on Windows, whose own libmpv has
    // none of the shelf or pass filters. The fader still works.
    if (!_warned.contains(deck.name)) {
      _warned.add(deck.name);
      debugPrint('mixer: no filter chain on deck ${deck.name}: EQ and filter do nothing here');
    }
  }

  final _warned = <String>{};

  /// Rubber Band's delay is 2048 of the record's own samples — 46 ms at 44.1 kHz,
  /// 64 ms for a part at 32 kHz. mpv counts it as if the deck ran at 1.0, so a deck
  /// at another speed sounds a few milliseconds away from where it says it is
  /// (measured on the real engine with the probe: 48 ms per unit of speed between two
  /// decks at 44.1 kHz — this, to the precision the probe has).
  static const rubberBandSamples = 2048;

  @override
  Duration stretchLatency(Deck deck) => _latency[deck.name] ?? Duration.zero;

  @override
  Future<void> measureLatency(Deck deck) async {
    final mpv = _native(deck);
    if (mpv == null || _stretcher[deck.name] != 'rubberband') {
      _latency.remove(deck.name);
      return;
    }
    try {
      final rate = double.tryParse(await mpv.getProperty('audio-params/samplerate'));
      if (rate != null && rate > 0) {
        _latency[deck.name] = Duration(microseconds: (rubberBandSamples / rate * 1e6).round());
      }
    } catch (_) {
      // Unknown: nothing corrected, which is how it was.
    }
  }

  /// A record has gone on [deck]: the chain goes on its player now, before anything
  /// is asked of it, with whatever the deck's bands and filter already are.
  @override
  Future<void> loaded(Deck deck) => _apply(deck);

  @override
  Future<void> setEq(Deck deck, EqSet eq) async {
    final was = _eq[deck.name] ?? EqSet.flat;
    _eq[deck.name] = eq;
    final all = commands(eq: eq, filter: _filter[deck.name] ?? 0);
    final before = commands(eq: was, filter: _filter[deck.name] ?? 0);
    // Only the bands that changed: a kill is one command, not seven.
    await _apply(deck, only: [
      for (var i = 0; i < 3; i++)
        if (all[i] != before[i]) all[i],
    ]);
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {
    _filter[deck.name] = value.clamp(-1.0, 1.0);
    await _apply(deck, only: commands(eq: _eq[deck.name] ?? EqSet.flat, filter: value).sublist(3));
  }

  @override
  Future<bool> setLoop(Deck deck, Duration? from, Duration? to) => _loop(deck, from, to);

  /// Read where a loop's seam will not click (seam.dart) from what [deck] plays, with
  /// an mpv of its own writing the samples around each end to a file: the same engine
  /// the deck plays through, so the same samples at the same places — for a file on
  /// this computer or a stream from the house alike, and with nothing else installed.
  @override
  Future<(Duration, Duration)?> quietSeam(Deck deck, Duration start, Duration end) async {
    final mpv = _native(deck), source = deck.sourceNow;
    if (mpv == null || source == null || end <= start) return null;
    try {
      final rate = int.tryParse((await mpv.getProperty('audio-params/samplerate')).split('.').first);
      if (rate == null || rate <= 0) return null;
      final sa = (start.inMicroseconds * rate / 1e6).round();
      final sb = (end.inMicroseconds * rate / 1e6).round();
      const w = seamReach + seamHalf;
      if (sa - w < 0) return null;
      final both = await Future.wait([_pcm(source, sa - w, rate), _pcm(source, sb - w, rate)]);
      final a = both[0], b = both[1];
      if (a == null || b == null) return null;
      return seamPoints(sa, sb, bestSplice(a, b), rate);
    } catch (e) {
      debugPrint('mixer: could not read the loop seam ($e)');
      return null;
    }
  }

  /// [seamWindow] frames of stereo float from sample [from] of [source], at [rate].
  Future<Float32List?> _pcm(({String uri, Map<String, String>? headers}) source, int from, int rate) async {
    final dir = await Directory.systemTemp.createTemp('wetowl-seam');
    final out = File('${dir.path}${Platform.pathSeparator}pcm.raw');
    final player = Player();
    try {
      final mpv = player.platform as NativePlayer;
      await mpv.setProperty('vid', 'no');
      await mpv.setProperty('ao', 'pcm');
      await mpv.setProperty('ao-pcm-file', out.path);
      await mpv.setProperty('ao-pcm-waveheader', 'no');
      await mpv.setProperty('audio-format', 'float');
      await mpv.setProperty('audio-channels', 'stereo');
      await mpv.setProperty('audio-samplerate', '$rate');
      await mpv.setProperty('hr-seek', 'yes');
      // Half a sample early: the first sample at or after it is the one asked for.
      await mpv.setProperty('start', ((from - 0.5) / rate).toStringAsFixed(9));
      await mpv.setProperty('length', ((seamWindow + 512) / rate).toStringAsFixed(6));
      final done = player.stream.completed.firstWhere((c) => c).timeout(const Duration(seconds: 8));
      await player.open(Media(source.uri, httpHeaders: source.headers));
      await done;
    } finally {
      await player.dispose();
    }
    try {
      final bytes = await out.readAsBytes();
      if (bytes.length < seamWindow * 8) return null;
      return Uint8List.fromList(bytes.sublist(0, seamWindow * 8)).buffer.asFloat32List();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Loop natively: mpv's own A–B loop jumps back from inside the audio, where a
  /// timer in Dart is twenty milliseconds late at best and sounds it on a roll.
  /// Says whether it could.
  Future<bool> _loop(Deck deck, Duration? from, Duration? to) async {
    final mpv = _native(deck);
    if (mpv == null) return false;
    // To the microsecond: the engine splices to the sample, and a loop's ends are put
    // on exact samples so its seam does not click (quietSeam). Four places was a
    // tenth of a millisecond — four samples either way of where they were meant.
    String at(Duration? d) => d == null ? 'no' : (d.inMicroseconds / 1e6).toStringAsFixed(6);
    try {
      await mpv.setProperty('ab-loop-a', at(from));
      await mpv.setProperty('ab-loop-b', at(to));
      return true;
    } catch (_) {
      return false;
    }
  }
}
