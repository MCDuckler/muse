import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import '../playback_log.dart';
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
  /// Where the three bands are divided. A DJ mixer's are about here.
  static const lowCross = 300, highCross = 3000;

  /// The bands every deck carries: the record split three ways and each part given a
  /// level of its own, not three tone controls laid over one another.
  ///
  /// It was a low shelf, a bell and a high shelf — which is a tone control, and does
  /// not do what a mixer's EQ does. Measured on noise, against flat:
  ///
  ///   * killing LOW took 7 dB out of 700 Hz and 4 dB out of 1 kHz, so a bass swap
  ///     hollowed the voice of the record it was swapping under;
  ///   * killing HI took 4 dB out of 1 kHz;
  ///   * all three killed left −33 dB, plainly audible, where three knobs fully down
  ///     should be silence;
  ///   * all three at +6 gave anything from +2.6 to +6.5, with a hole at 250–400 Hz
  ///     in the gap between the shelf and the bell.
  ///
  /// Split at 300 Hz and 3 kHz with fourth-order Linkwitz-Riley crossovers — two
  /// cascaded Butterworths a side, which is what sums flat — each band through its own
  /// volume, and added back. The same measurements then read: kills that leave the
  /// other bands inside half a decibel, silence with all three down, and +6 across the
  /// band within a decibel and a half.
  static const _bandsOnly = 'asplit=3[b1][b2][b3];'
      '[b1]lowpass=f=$lowCross:p=2,lowpass=f=$lowCross:p=2,volume@low=1:eval=frame[lo];'
      '[b2]highpass=f=$lowCross:p=2,highpass=f=$lowCross:p=2,'
      'lowpass=f=$highCross:p=2,lowpass=f=$highCross:p=2,volume@mid=1:eval=frame[mi];'
      '[b3]highpass=f=$highCross:p=2,highpass=f=$highCross:p=2,volume@high=1:eval=frame[hi];'
      '[lo][mi][hi]amix=inputs=3:normalize=0,'
      'highpass@hp=f=20:m=0,'
      'lowpass@lp=f=15000:m=0,'
      // The gate, off. Its level is an *expression* evaluated every frame rather than
      // a number, which is the whole trick: the chop runs inside ffmpeg off the
      // frame's own timestamp — the record's position, ahead of the stretcher — so it
      // keeps the record's beat at any tempo, and Dart only has to say how deep it is
      // every so often. Told a number 25 times a second instead, a sixteenth-note
      // chop would have had three steps to a cycle.
      'volume@gate=volume=1:eval=frame';

  // A ceiling, appended last of all to every chain, at a decibel under full.
  //
  // Measured on a real record through this very chain: the source peaks at +0.6 dB
  // on the left and +1.1 on the right — modern masters are cut over full scale —
  // and the chain hands back +4.2 and +3.8 *with every knob at noon*. Three bands
  // split by cascaded Butterworths sum flat in magnitude, which is what they were
  // chosen for, but not in time: their phase shifts stack, and a transient that
  // went in at full comes out half as loud again. With the bass up six it is +6.9.
  //
  // Everything over full scale is cut off flat at the sound card, which is a
  // crackle, and it is heard on whichever side of the record is louder — which is
  // why it was "a slight crackling on the right ear" and why it was never there on
  // the plain player, whose chain is nothing at all.
  //
  // A limiter rather than a trim: pulling the whole chain down four decibels to
  // make room for a peak that happens twice a minute would make the booth quieter
  // than everything else on the machine. This is what the master of a DJ mixer has
  // for exactly this reason. Five milliseconds of lookahead, on both decks alike,
  // so nothing moves relative to anything else.
  //
  // Appended rather than written in, and the chain is offered again without it, so
  // that an mpv whose ffmpeg has no alimiter still gets its bands: a chain with one
  // word it does not know is refused whole, and a booth with no EQ would be a
  // worse trade than a booth that clips.

  /// The last thing in every chain: nothing leaves a deck over -1 dBFS.
  static const ceiling =
      'alimiter@out=limit=0.989:attack=10:release=200:level=disabled';

  /// The same, for an ffmpeg too old to know `level` — and then a plain trim, which
  /// every build has. A deck four decibels quieter than the rest of the machine is a
  /// poor trade, but it is a better one than a deck that crackles.
  static const _ceilings = [
    ceiling,
    'alimiter@out=limit=0.989:attack=10:release=200',
    'volume@out=-1dB',
  ];

  /// The echo every deck carries, ahead of the bands: the record split in two, one
  /// way through a send (volume@es, shut) into an echo timed to the record's beat —
  /// a dotted eighth and a dotted quarter, the way a DJ's echo is set — and back
  /// together with the other, which has a level of its own (volume@dry). Turned up
  /// and the dry taken away, the echo rings on after the record: an echo-out.
  static String _echo(double beatMs) {
    final d1 = (beatMs * 0.75).round(), d2 = (beatMs * 1.5).round();
    return 'asplit[dry][wet];'
        '[wet]volume@es=0,aecho=0.7:0.8:$d1|$d2:0.5|0.3[e];'
        '[dry]volume@dry=1[d0];'
        '[d0][e]amix=inputs=2:normalize=0';
  }

  /// The headroom every deck's chain is given before anything is done to it.
  ///
  /// Three bands split by cascaded Butterworths sum flat in *magnitude* — that is what
  /// they are chosen for, and the kills measured here depend on it — but not in time:
  /// their phase shifts stack, and a transient that went in at full comes out half as
  /// loud again. Measured on a real record through this very chain: a source peaking at
  /// +1.1 dBFS comes back at +4.2, with every knob at noon. So a deck was four decibels
  /// over full scale *doing nothing*, and everything over full scale is cut off flat at
  /// the sound card. That is the crackle, it was there whatever the EQ was set to, and
  /// it was never there on the plain player because the plain player has no chain.
  ///
  /// A limiter was tried first and made it worse in a different way: asked to claw back
  /// four to seven decibels on every kick, it is not a safety net but a compressor, and
  /// measured against a clean trim its own error was 12 dB below the signal — audible
  /// as pumping and grit, which is a crackle by another name.
  ///
  /// Given the room instead, the flat case lands at -0.27 dBFS and the ceiling above
  /// never engages at all — measured, the peak is identical with it and without. It
  /// only has work to do when a band is boosted past full scale, which is a thing no
  /// system can grant and every mixer limits.
  ///
  /// The cost is that a deck is four and a half decibels quieter than it was. That is
  /// not a loss; it is where it should have been.
  static const headroom = 'volume=-4.5dB';

  /// The loop, ahead of everything: the same samples handed round again underneath the
  /// filters, so that they never learn a loop happened.
  ///
  /// `start` is counted in samples from the first one the filter sees, and the first
  /// one it sees is the first after a seek — so the chain is put on and *then* the deck
  /// is sent to the loop's start, and zero means exactly there. `time` looks like it
  /// would say this more directly and does not work: asked to begin at two seconds it
  /// looped the first second of the record instead.
  static String loopAhead(int samples) =>
      'aloop=loop=-1:size=$samples:start=0';

  static String bandsFor(double beatMs, {String? cap, int? loop}) =>
      '@wetowl:lavfi=[${loop == null ? '' : '${loopAhead(loop)},'}$headroom,${_echo(beatMs)},$_bandsOnly${cap == null ? '' : ',$cap'}]';

  /// As it stands for a record of 120 a minute — the shape of every deck's chain.
  static final bands = bandsFor(500);

  /// How Rubber Band is asked to work, best first.
  ///
  /// It was asked for nothing at all — `@rb:rubberband`, every default — and two of
  /// those defaults are wrong for music.
  ///
  ///   * `channels=apart` stretches the left and right independently, so they drift
  ///     against each other and the stereo image swims. On a record, where both sides
  ///     carry the same kick and the same voice, that is the watery, phasey sound a
  ///     pitched deck had. `together` keeps them locked to one another.
  ///   * `pitch=quality` is about the *pitch shift*, which the booth uses for a key
  ///     made to fit and for the lunar echo. The default there is `speed`.
  ///
  /// And `engine=finer` is Rubber Band 3's R3 engine, which is a different class of
  /// thing again — where the library is new enough to have it.
  ///
  /// Tried in order, because an mpv that does not know one of these words rejects the
  /// whole chain: the best it will take, and plain rubberband before scaletempo2,
  /// which is the one that moves the beat about (see the note above).
  static const _stretchers = [
    '@rb:rubberband=engine=finer:channels=together:pitch=quality',
    '@rb:rubberband=channels=together:pitch=quality',
    '@rb:rubberband=channels=together',
    '@rb:rubberband',
    'scaletempo2',
  ];

  /// The chains tried, best first: the bands, then the stretcher — Rubber Band
  /// labelled, so its pitch can be spoken to (setPitchShift).
  /// Every shape of chain, best first: a ceiling and a stretcher each.
  static final _shapes = <(int, int)>[
    for (var c = 0; c <= _ceilings.length; c++)
      for (var st = 0; st < _stretchers.length; st++) (c, st),
  ];

  static String chainOf(double beatMs, (int, int) shape, {int? loop, bool stems = false}) {
    final (c, st) = shape;
    final cap = c < _ceilings.length ? _ceilings[c] : null;
    final bands = stems
        ? stemBandsFor(beatMs, cap: cap, loop: loop)
        : bandsFor(beatMs, cap: cap, loop: loop);
    return '$bands,${_stretchers[st]}';
  }

  static List<String> standingFor(double beatMs, {int? loop}) =>
      [for (final shape in _shapes) chainOf(beatMs, shape, loop: loop)];
  static final standing = standingFor(500);

  /// The same, for a stem deck: the six-channel stems file taken apart into its three
  /// pairs — the drums, the bass and the rest, the voice — each through a level of
  /// its own, mixed back together, and then the bands as on any deck. Each level is
  /// an `af-command` like a band: turned while it plays, with nothing rebuilt.
  static String stemBandsFor(double beatMs, {String? cap, int? loop}) => '@wetowl:lavfi=['
      '${loop == null ? '' : '${loopAhead(loop)},'}'
      'channelsplit=channel_layout=6c[c0][c1][c2][c3][c4][c5];'
      '[c0][c1]join=inputs=2:channel_layout=stereo,volume@d=1[d];'
      '[c2][c3]join=inputs=2:channel_layout=stereo,volume@r=1[r];'
      '[c4][c5]join=inputs=2:channel_layout=stereo,volume@v=1[v];'
      '[d][r][v]amix=inputs=3:normalize=0,'
      '$headroom,'
      '${_echo(beatMs)},'
      '$_bandsOnly'
      '${cap == null ? '' : ',$cap'}'
      ']';
  static final stemBands = stemBandsFor(500);
  static List<String> stemStandingFor(double beatMs, {int? loop}) =>
      [for (final shape in _shapes) chainOf(beatMs, shape, loop: loop, stems: true)];
  static final stemStanding = stemStandingFor(500);

  /// Each deck's record's beat, in milliseconds, for the echo's timing.
  final _beat = <String, double>{};
  final _shift = <String, double>{};

  @override
  bool get canShift => true;

  @override
  bool get canGate => true;

  /// What each deck's gate was last told, so an unchanged one is not re-sent.
  final _gate = <String, String>{};

  @override
  Future<void> setGate(Deck deck,
      {required double depth, required Duration period, required Duration origin}) async {
    final mpv = _native(deck);
    if (mpv == null) return;
    final d = depth.clamp(0.0, 1.0);
    final p = period.inMicroseconds / 1e6;
    // A cosine, not a square: a square gate on a record is a click every edge, and a
    // cosine down to nothing is what a chop sounds like anyway.
    final expr = d <= 0.001 || p <= 0.001
        ? '1'
        : '1-${d.toStringAsFixed(3)}*(0.5-0.5*cos(2*PI*(t-${(origin.inMicroseconds / 1e6).toStringAsFixed(4)})'
            '/${p.toStringAsFixed(5)}))';
    if (_gate[deck.name] == expr) return;
    _gate[deck.name] = expr;
    try {
      await mpv.command(['af-command', 'gate', 'volume', expr]);
    } catch (_) {
      // An mpv whose chain would not go on: the move runs without its chop.
    }
  }

  @override
  Future<void> setPitchShift(Deck deck, double semitones) async {
    final mpv = _native(deck);
    if (mpv == null || _stretcher[deck.name] != 'rubberband') return;
    if ((_shift[deck.name] ?? 0) == semitones) return;
    _shift[deck.name] = semitones;
    try {
      await mpv.command(['af-command', 'rb', 'set-pitch', math.pow(2, semitones / 12).toStringAsFixed(5)]);
    } catch (e) {
      debugPrint('mixer: deck ${deck.name} would not shift pitch ($e)');
    }
  }

  @override
  Future<void> setEcho(Deck deck, {required double send, required double dry}) async {
    final mpv = _native(deck);
    if (mpv == null || !await _install(deck, mpv)) return;
    for (final (target, value) in [('volume@es', send), ('volume@dry', dry)]) {
      try {
        await mpv.command(['af-command', 'wetowl', 'volume', value.clamp(0.0, 1.0).toStringAsFixed(3), target]);
      } catch (_) {}
    }
  }

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
  Future<bool> beforeLoad(Deck deck, {required bool stems, double? beatMs}) async {
    final mpv = _native(deck);
    if (mpv == null) {
      _missed.add(deck.name);
      return false;
    }
    // The chain stays on the player once built (the echo timed to the first record's
    // beat on it): setting `af` again on every load is a call into libmpv that waits
    // on its core, and a booth froze on one. What the last record left on the chain —
    // a shift, the echo — is put back by command instead.
    // The echo's delays are written into the chain, so a record at another tempo
    // needs the chain built again — now, while the deck is parked, which is when the
    // booth loads. (The chain used to be built once and the echo kept the beat of the
    // first record the deck ever played: every later record's echo-out was out of
    // time.) Within two per cent is the same beat to an echo.
    final want = beatMs ?? _beat[deck.name] ?? 500;
    final had = _beat[deck.name];
    if (had == null) {
      _beat[deck.name] = want;
    } else if ((want - had).abs() / had > 0.02) {
      _beat[deck.name] = want;
      _installed.remove(deck.name);
      _gate.remove(deck.name);
    }
    if ((_shift[deck.name] ?? 0) != 0) {
      _shift.remove(deck.name);
      try {
        await mpv.command(['af-command', 'rb', 'set-pitch', '1.00000']);
      } catch (_) {}
    }
    if (_installed[deck.name] == deck.player.platformId) {
      for (final (target, value) in const [('volume@es', '0.000'), ('volume@dry', '1.000')]) {
        try {
          await mpv.command(['af-command', 'wetowl', 'volume', value, target]);
        } catch (_) {}
      }
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
      // Every seek to the sample it asked for, not to the packet before it.
      //
      // mpv's default weighs exactness against how long a seek takes, and a loop is
      // nothing but a seek backwards, made over and over: left to that default an
      // ab-loop lands wherever the decoder can restart cheaply, so the loop comes
      // round a little differently each time and the record walks off its own grid.
      // The booth puts a loop's ends on exact samples (quietSeam) and it is worth
      // nothing if the engine rounds them off again. It is what a hand seek and a
      // nudge want too — those are small seeks, which is the cheap case anyway.
      await mpv.setProperty('hr-seek', 'yes');
      // And the frames either side of the splice kept, so the seek does not have to
      // go back to the file for them.
      await mpv.setProperty('demuxer-seekable-cache', 'yes');
    } catch (_) {}
    final was = _stems[deck.name] ?? false;
    _stems[deck.name] = stems;
    if (was != stems) _installed.remove(deck.name);
    // Not known until they are next set: a new record may or may not have the chain
    // built afresh, so the next levels go to all three stems either way.
    _levels.remove(deck.name);
    if (!await _install(deck, mpv)) return false;
    return stems;
  }

  @override
  Future<void> setStems(Deck deck, StemLevels levels) async {
    if (!(_stems[deck.name] ?? false)) return;
    final was = _levels[deck.name];
    _levels[deck.name] = levels;
    final mpv = _native(deck);
    if (mpv == null) return;
    // All three at once, not one after another. Each is a round trip to mpv, and a
    // stem move is these three sent twenty times a second: awaited in turn, the three
    // trips stacked up and a part change by hand took a third of a second to be heard.
    // Nothing here depends on the order they land in.
    await Future.wait([
      for (final (target, now, before) in [
        ('volume@d', levels.drums, was?.drums),
        ('volume@r', levels.rest, was?.rest),
        ('volume@v', levels.vocals, was?.vocals),
      ])
        if (before == null || (now - before).abs() >= 0.001)
          mpv
              .command(['af-command', 'wetowl', 'volume', now.toStringAsFixed(3), target])
              .catchError((Object _) {}),
    ]);
  }

  /// What to tell the standing chain for [eq] and [filter]: (filter, command, value).
  /// The passes are mixed in only while the knob is off centre.
  /// A band's level as a plain number rather than a decibel figure.
  ///
  /// The three band volumes are evaluated every frame now, so that a level can be given
  /// as an *expression* and slid rather than stepped (see [slide]); and what a frame
  /// evaluates is an expression, where `-6.0dB` is not a term. Linear both ways, so
  /// there is one language on that filter and not two.
  static String level(double db) =>
      db <= EqSet.killed ? '0' : math.pow(10, db / 20).toStringAsFixed(5);

  /// A level that walks from [was] to [now] over [_slide], starting at [at] seconds
  /// into the record — and that is simply [now] anywhere outside that window.
  ///
  /// Turning a knob used to hand the filter a new number, and a new number is a step in
  /// the waveform: a tick, once per report the knob sends, which at sixty a second is a
  /// crackle rather than a tick. This is the zipper every mixer has to deal with, and
  /// what every mixer does about it is slide the gain instead of setting it.
  ///
  /// The filter can only take a new value once per audio frame, which is about twenty
  /// milliseconds, so a slide over sixty gives three steps where there was one and each
  /// is a third the size; turned continuously, the slides overlap and what is left is a
  /// gain that walks rather than jumps.
  ///
  /// Outside the window it is [now] — *before* the window as well as after. That is not
  /// tidiness: a loop carries the record's clock back behind the anchor several times a
  /// minute, and a slide that read as the old value there would undo the knob every
  /// time round.
  static String slide(double was, double now, Duration at) {
    final a = level(was), b = level(now);
    if (a == b) return b;
    final t0 = at.inMicroseconds / 1e6;
    final t1 = t0 + _slide;
    return 'if(between(t,${t0.toStringAsFixed(4)},${t1.toStringAsFixed(4)}),'
        '$a+($b-$a)*(t-${t0.toStringAsFixed(4)})/$_slide,$b)';
  }

  static const _slide = 0.06;

  static List<(String, String, String)> commands({required EqSet eq, required double filter}) {
    final hp = filter > 0 ? 10 * math.pow(8000 / 10, filter) : 20.0;
    // Closing towards 60 Hz on a log scale, like the browser's; never above what a
    // 32 kHz part can carry, which ffmpeg would refuse.
    final lp = filter < 0 ? math.min(15000.0, 22000 * math.pow(60 / 22000, -filter)) : 15000.0;
    // A band's level, not a shelf's gain: a kill is a band that is gone rather than one
    // that is leaning.
    return [
      ('volume@low', 'volume', level(eq.low)),
      ('volume@mid', 'volume', level(eq.mid)),
      ('volume@high', 'volume', level(eq.high)),
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
      if (!eq.isFlat)
        'asplit=3[b1][b2][b3];'
            '[b1]lowpass=f=$lowCross:p=2,lowpass=f=$lowCross:p=2,volume=${db(eq.low)}dB[lo];'
            '[b2]highpass=f=$lowCross:p=2,highpass=f=$lowCross:p=2,'
            'lowpass=f=$highCross:p=2,lowpass=f=$highCross:p=2,volume=${db(eq.mid)}dB[mi];'
            '[b3]highpass=f=$highCross:p=2,highpass=f=$highCross:p=2,volume=${db(eq.high)}dB[hi];'
            '[lo][mi][hi]amix=inputs=3:normalize=0',
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
  /// How long a loop each deck's chain is carrying, where it carries one.
  final _inChain = <String, int>{};

  /// Which shape of chain this deck's engine took, so a rebuild need not ask again.
  final _shape = <String, (int, int)>{};

  @override
  Future<bool> loopInChain(Deck deck, Duration length) async {
    final mpv = _native(deck);
    if (mpv == null || length <= Duration.zero) return false;
    // The rate of the record on the deck *now*, asked every time. It was asked once
    // per deck and kept, and a deck's records do not share one: a 44.1 kHz record
    // after a 48 kHz stems file, or a 32 kHz part, got a loop 8 or 38 per cent the
    // wrong length — going round at one length while the deck's clock folded it at
    // the right one, off the grid a little more every time round.
    final rate = int.tryParse(
        (await mpv.getProperty('audio-params/samplerate')).split('.').first);
    if (rate == null || rate <= 0) return false;
    final samples = (length.inMicroseconds * rate / 1e6).round();
    if (samples <= 0) return false;
    final was = _inChain[deck.name];
    _inChain[deck.name] = samples;
    // The chain is built afresh to carry it, so it has to be forgotten first.
    _installed.remove(deck.name);
    if (!await _install(deck, mpv)) {
      if (was == null) {
        _inChain.remove(deck.name);
      } else {
        _inChain[deck.name] = was;
      }
      _installed.remove(deck.name);
      await _install(deck, mpv);
      return false;
    }
    // A fresh chain is a chain that has never been told anything: the bands, the
    // filter and the stems all go on again before a note of it is heard.
    await _sayItAllAgain(deck);
    return true;
  }

  @override
  Future<void> stopChainLoop(Deck deck, Duration at) async {
    if (!_inChain.containsKey(deck.name)) return;
    final mpv = _native(deck);
    _inChain.remove(deck.name);
    if (mpv == null) return;
    _installed.remove(deck.name);
    await _install(deck, mpv);
    await _sayItAllAgain(deck);
  }

  /// Everything a chain is told, told again — for a chain that has just been rebuilt.
  Future<void> _sayItAllAgain(Deck deck) async {
    final levels = _levels[deck.name];
    _levels.remove(deck.name);
    await _apply(deck);
    if (levels != null) await setStems(deck, levels);
  }

  Future<bool> _install(Deck deck, NativePlayer mpv) async {
    final id = deck.player.platformId!;
    if (_installed[deck.name] == id) return true;
    final stems = _stems[deck.name] ?? false;
    if (_whole.contains(id) && !stems) return false;
    final beat = _beat[deck.name] ?? 500;
    final loop = _inChain[deck.name];
    // What went on last time, first. Every shape that is refused is a round trip to
    // mpv and back, and there are fifteen of them: a chain rebuilt to pick a loop up
    // would have walked the whole ladder again while the record played on. Remembered,
    // it is one call.
    final known = _shape[deck.name];
    final order = [
      if (known != null) known,
      for (final shape in _shapes) if (shape != known) shape,
    ];
    for (final shape in order) {
      final chain = chainOf(beat, shape, loop: loop, stems: stems);
      // The stretcher's *name*, without its label or the options asked of it: the
      // rest of this only ever needs to know whether it is Rubber Band, and the
      // options are what the chain tiers differ by.
      final asked = chain.split(',').last.replaceFirst('@rb:', '');
      final stretcher = asked.split('=').first;
      try {
        await mpv.setProperty('af', chain);
        final got = await mpv.getProperty('af');
        if (got.contains('wetowl') && got.contains(stretcher)) {
          _installed[deck.name] = id;
          _stretcher[deck.name] = stretcher;
          _shape[deck.name] = shape;
          // Said out loud, not to the console: which chain a machine took is the one
          // thing that cannot be worked out from here, and the ceiling is the half of
          // it that matters most — an mpv whose ffmpeg has no alimiter falls through to
          // a chain with nothing holding its peaks down, and then a deck clips and
          // crackles exactly as it did before there was a limiter, with no way of
          // telling from this end which of the two is on.
          PlaybackLog.note('MIXER deck ${deck.name} carries $asked, '
              '${chain.contains('alimiter') ? 'with a ceiling' : 'WITH NO CEILING'}');
          return true;
        }
      } catch (e) {
        debugPrint('mixer: $asked would not go on ($e)');
      }
    }
    // Only a *plain* chain that will not go on says this engine cannot have one; a
    // looping chain that is refused says only that, and the plain one goes back.
    if (!stems && _inChain[deck.name] == null) _whole.add(id);
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
    // Slid from where the band was to where it is going, from where the record is now.
    // Only the bands that changed: a kill is one command, not seven.
    final at = deck.position;
    await _apply(deck, only: [
      for (final (name, from, to) in [
        ('volume@low', was.low, eq.low),
        ('volume@mid', was.mid, eq.mid),
        ('volume@high', was.high, eq.high),
      ])
        if (level(from) != level(to)) (name, 'volume', slide(from, to, at)),
    ]);
  }

  /// mpv's `audio-pitch-correction`: yes is the stretcher keeping the pitch (keylock),
  /// no is plain resampling, where a faster record is a higher one.
  @override
  Future<void> setKeylock(Deck deck, bool on) async {
    final mpv = _native(deck);
    if (mpv == null) return;
    try {
      await mpv.setProperty('audio-pitch-correction', on ? 'yes' : 'no');
    } catch (e) {
      debugPrint('mixer: deck ${deck.name} would not set keylock ($e)');
    }
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

  /// The loop is entered a stretcher's worth early, and a band splitter's.
  ///
  /// mpv comes round an A–B loop by seeking, and a seek empties the filter chain —
  /// so Rubber Band begins the new time round with nothing in it, and its first two
  /// thousand samples of output are it filling up rather than the record. At 44.1 kHz
  /// that is forty-six milliseconds of the top of the loop that never arrives, which
  /// is "the timing is right but the start is cut off".
  ///
  /// And the *filters'* settling. A seek empties the whole chain, so the crossover
  /// starts with no state and its first milliseconds of output are wrong — measured
  /// through this very chain against the same audio run warm: 5.7 dB below the signal
  /// over the first 2 ms, 20 dB over 2–5 ms, 43 dB over 5–10 ms, and gone by 15. Wrong
  /// output from a band splitter is heard as the EQ not being applied, which is what
  /// "there is a brief moment at the start of the loop where the eq settings are
  /// ignored" is — and no amount of sending the settings again can help, because the
  /// settings were never lost. What was lost was the filters' memory, and the only way
  /// to give it back is to let them hear a little music before the loop point arrives.
  ///
  /// Added rather than maxed: the stretcher is at the end of the chain and the
  /// crossover at the front, so one does not cover the other. Sent in that much before
  /// the loop's start, the filling up happens on the bar before and the record is at
  /// full voice by the time the loop point comes; the deck takes the same amount off
  /// the loop's end, so it goes round at its own length (Deck._engineLoopEnd).
  ///
  /// Not for a loop too short to spare it: a roll an eighth of a beat long led in by
  /// sixty milliseconds is a roll mostly made of the bar before it.
  @override
  Duration loopLead(Deck deck, Duration span) {
    final prime = stretchLatency(deck) + _settling;
    return span >= prime * 2 ? prime : Duration.zero;
  }

  /// How long the band splitter needs to hear before its output is right again. See
  /// [loopLead], where it is measured.
  static const _settling = Duration(milliseconds: 15);

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
