// What the show knows, one frame at a time.
//
// Everything a scene on the stage or a light in the rig can be driven by, worked out
// once a frame by the engine (show_engine.dart) from the booth — the decks' clocks on
// the records' own grids, what the analysis says of the bar the needle is in, the
// record's pulse at the needle with the mixer modelled over it, the mix that is on or
// coming, the palette, the performer's own hands — and handed on as one immutable
// value. A scene binds a uniform to a name in [ShowState.flat]; a fixture reads the
// same names. Nothing in here reaches back into the booth.
import 'dart:math' as math;
import 'package:flutter/painting.dart' show Color, HSLColor;

import 'show_genome.dart';

/// The record's sound at the needle, 0 to 1 each: five bands, the kick, the onsets,
/// and the three stems where the record is in parts.
class ShowAudio {
  const ShowAudio({
    this.sub = 0,
    this.low = 0,
    this.mid = 0,
    this.high = 0,
    this.air = 0,
    this.kick = 0,
    this.onset = 0,
    this.drums = 0,
    this.rest = 0,
    this.vocals = 0,
  });

  final double sub, low, mid, high, air, kick, onset, drums, rest, vocals;

  static const silence = ShowAudio();

  /// The loudest band: a bass drop is loud even when the top has gone.
  double get level => [sub, low, mid, high, air].reduce(math.max);

  ShowAudio operator *(double k) => ShowAudio(
        sub: sub * k,
        low: low * k,
        mid: mid * k,
        high: high * k,
        air: air * k,
        kick: kick * k,
        onset: onset * k,
        drums: drums * k,
        rest: rest * k,
        vocals: vocals * k,
      );

  ShowAudio operator +(ShowAudio o) => ShowAudio(
        sub: _cap(sub + o.sub),
        low: _cap(low + o.low),
        mid: _cap(mid + o.mid),
        high: _cap(high + o.high),
        air: _cap(air + o.air),
        kick: _cap(kick + o.kick),
        onset: _cap(onset + o.onset),
        drums: _cap(drums + o.drums),
        rest: _cap(rest + o.rest),
        vocals: _cap(vocals + o.vocals),
      );

  static double _cap(double v) => v > 1 ? 1 : v;

  void flatInto(Map<String, double> m, String at) {
    m['$at.sub'] = sub;
    m['$at.low'] = low;
    m['$at.mid'] = mid;
    m['$at.high'] = high;
    m['$at.air'] = air;
    m['$at.kick'] = kick;
    m['$at.onset'] = onset;
    m['$at.drums'] = drums;
    m['$at.rest'] = rest;
    m['$at.vocals'] = vocals;
    m['$at.level'] = level;
  }

  Map<String, dynamic> toJson() => {
        'sub': sub, 'low': low, 'mid': mid, 'high': high, 'air': air,
        'kick': kick, 'onset': onset, 'drums': drums, 'rest': rest, 'vocals': vocals,
      };

  factory ShowAudio.fromJson(Map<String, dynamic> j) => ShowAudio(
        sub: _d(j['sub']), low: _d(j['low']), mid: _d(j['mid']), high: _d(j['high']),
        air: _d(j['air']), kick: _d(j['kick']), onset: _d(j['onset']),
        drums: _d(j['drums']), rest: _d(j['rest']), vocals: _d(j['vocals']),
      );
}

double _d(Object? v) => v is num ? v.toDouble() : 0;

/// One deck as the show sees it.
class ShowDeck {
  const ShowDeck({
    required this.name,
    this.trackId,
    this.title,
    this.artist,
    this.playing = false,
    this.position = Duration.zero,
    this.bpm,
    this.beatIndex,
    this.beatPhase = 0,
    this.beatInBar,
    this.barIndex,
    this.barPhase = 0,
    this.phraseBar,
    this.phrasePhase = 0,
    this.section,
    this.sectionK = 0,
    this.sectionBarsLeft,
    this.dropBeatsAway,
    this.breakdown = false,
    this.buildK = 0,
    this.energy = 0,
    this.vocal = 0,
    this.lyric,
    this.lyricK = 0,
    this.hook = false,
    this.key,
    this.camelot,
    this.keyHue,
    this.coverColor,
    this.coverUrl,
    this.level = 0,
    this.eqLow = 1,
    this.eqMid = 1,
    this.eqHigh = 1,
    this.filter = 0,
    this.stemDrums = 1,
    this.stemRest = 1,
    this.stemVocals = 1,
    this.looping = false,
    this.audio = ShowAudio.silence,
  });

  final String name;
  final int? trackId;
  final String? title, artist;
  final bool playing;

  /// Where the record is, as the ear hears it (the latency taken off).
  final Duration position;
  final double? bpm;

  /// The beat the record is on and how far through it; the bar (from the record's
  /// first downbeat) and how far through it; which bar of its four-bar phrase, and
  /// how far through the phrase.
  final int? beatIndex;
  final double beatPhase;

  /// Which beat of its bar, 0 to 3; null off the grid.
  final int? beatInBar;
  final int? barIndex;
  final double barPhase;
  final int? phraseBar;
  final double phrasePhase;

  /// The section the needle is in (intro, verse, chorus, inst, breakdown, build, drop,
  /// break, outro, on), how far through it, and how many bars of it are left.
  final String? section;
  final double sectionK;
  final double? sectionBarsLeft;

  /// How many beats to the next drop, where one is within sixty-four; null otherwise.
  /// Negative for a moment just after one.
  final double? dropBeatsAway;
  final bool breakdown;

  /// How far up a build is, 0 to 1: through a build section, or the last 32 beats
  /// before a drop where no build was labelled.
  final double buildK;

  /// The bar's energy, 0 to 1, the record's loudest bar at 1.
  final double energy;

  /// The voice's share of the bar, 0 to 1; the lyric line being sung and how far
  /// through it; whether the hook is on.
  final double vocal;
  final String? lyric;
  final double lyricK;
  final bool hook;

  final String? key, camelot;

  /// The key as a hue, 0 to 1 round the wheel — Camelot's twelve positions.
  final double? keyHue;
  final Color? coverColor;

  /// Where the cover is, for a stage in another process to fetch it.
  final String? coverUrl;

  /// What this channel sends: its share of the crossfader at its gain, 0 to 1.
  final double level;

  /// The EQ as linear gains, the filter -1 (low-pass) to 1 (high-pass).
  final double eqLow, eqMid, eqHigh, filter;
  final double stemDrums, stemRest, stemVocals;
  final bool looping;

  /// The pulse at the needle, through this channel's EQ, filter and fader.
  final ShowAudio audio;

  bool get onBeatOne => beatInBar == 0;

  /// This deck [dt] later, the clocks carried forward at its tempo: for a stage
  /// reading frames over a wire at thirty a second and drawing sixty.
  ShowDeck advanced(double dt) {
    if (!playing || bpm == null || bpm! <= 0 || dt <= 0) return this;
    final beats = dt * bpm! / 60;
    final beat = beatPhase + beats;
    final wholeBeats = beat.floor();
    final inBar = beatInBar == null ? null : (beatInBar! + wholeBeats) % 4;
    final bar = barPhase + beats / 4;
    final phrase = phrasePhase + beats / 16;
    return ShowDeck(
      name: name,
      trackId: trackId,
      title: title,
      artist: artist,
      playing: playing,
      position: position + Duration(microseconds: (dt * 1e6).round()),
      bpm: bpm,
      beatIndex: beatIndex == null ? null : beatIndex! + wholeBeats,
      beatPhase: beat - wholeBeats,
      beatInBar: inBar,
      barIndex: barIndex == null ? null : barIndex! + bar.floor(),
      barPhase: bar - bar.floor(),
      phraseBar: phraseBar,
      phrasePhase: phrase - phrase.floor(),
      section: section,
      sectionK: sectionK,
      sectionBarsLeft: sectionBarsLeft == null ? null : sectionBarsLeft! - beats / 4,
      dropBeatsAway: dropBeatsAway == null ? null : dropBeatsAway! - beats,
      breakdown: breakdown,
      buildK: buildK,
      energy: energy,
      vocal: vocal,
      lyric: lyric,
      lyricK: lyricK,
      hook: hook,
      key: key,
      camelot: camelot,
      keyHue: keyHue,
      coverColor: coverColor,
      coverUrl: coverUrl,
      level: level,
      eqLow: eqLow,
      eqMid: eqMid,
      eqHigh: eqHigh,
      filter: filter,
      stemDrums: stemDrums,
      stemRest: stemRest,
      stemVocals: stemVocals,
      looping: looping,
      audio: audio,
    );
  }

  void flatInto(Map<String, double> m, String at) {
    m['$at.playing'] = playing ? 1 : 0;
    m['$at.position'] = position.inMicroseconds / 1e6;
    m['$at.bpm'] = bpm ?? 0;
    m['$at.beat.index'] = (beatIndex ?? 0).toDouble();
    m['$at.beat.phase'] = beatPhase;
    m['$at.beat.inBar'] = (beatInBar ?? 0).toDouble();
    m['$at.bar.index'] = (barIndex ?? 0).toDouble();
    m['$at.bar.phase'] = barPhase;
    m['$at.phrase.bar'] = (phraseBar ?? 0).toDouble();
    m['$at.phrase.phase'] = phrasePhase;
    m['$at.section.k'] = sectionK;
    m['$at.section.barsLeft'] = sectionBarsLeft ?? 0;
    m['$at.drop.beatsAway'] = dropBeatsAway ?? 999;
    m['$at.drop.near'] = dropBeatsAway == null ? 0 : (1 - (dropBeatsAway!.abs() / 32)).clamp(0.0, 1.0);
    m['$at.breakdown'] = breakdown ? 1 : 0;
    m['$at.build.k'] = buildK;
    m['$at.energy'] = energy;
    m['$at.vocal'] = vocal;
    m['$at.lyric.k'] = lyricK;
    m['$at.hook'] = hook ? 1 : 0;
    m['$at.key.hue'] = keyHue ?? 0;
    m['$at.level'] = level;
    m['$at.eq.low'] = eqLow;
    m['$at.eq.mid'] = eqMid;
    m['$at.eq.high'] = eqHigh;
    m['$at.filter'] = filter;
    m['$at.stems.drums'] = stemDrums;
    m['$at.stems.rest'] = stemRest;
    m['$at.stems.vocals'] = stemVocals;
    m['$at.loop'] = looping ? 1 : 0;
    audio.flatInto(m, '$at.audio');
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'bpm': bpm,
        'beatIndex': beatIndex,
        'beatPhase': beatPhase,
        'beatInBar': beatInBar,
        'barIndex': barIndex,
        'barPhase': barPhase,
        'phraseBar': phraseBar,
        'phrasePhase': phrasePhase,
        'section': section,
        'sectionK': sectionK,
        'sectionBarsLeft': sectionBarsLeft,
        'dropBeatsAway': dropBeatsAway,
        'breakdown': breakdown,
        'buildK': buildK,
        'energy': energy,
        'vocal': vocal,
        'lyric': lyric,
        'lyricK': lyricK,
        'hook': hook,
        'key': key,
        'camelot': camelot,
        'keyHue': keyHue,
        'coverColor': coverColor?.toARGB32(),
        'coverUrl': coverUrl,
        'level': level,
        'eqLow': eqLow,
        'eqMid': eqMid,
        'eqHigh': eqHigh,
        'filter': filter,
        'stemDrums': stemDrums,
        'stemRest': stemRest,
        'stemVocals': stemVocals,
        'looping': looping,
        'audio': audio.toJson(),
      };

  factory ShowDeck.fromJson(Map<String, dynamic> j) => ShowDeck(
        name: '${j['name'] ?? 'A'}',
        trackId: (j['trackId'] as num?)?.toInt(),
        title: j['title'] as String?,
        artist: j['artist'] as String?,
        playing: j['playing'] == true,
        position: Duration(milliseconds: (j['positionMs'] as num?)?.toInt() ?? 0),
        bpm: (j['bpm'] as num?)?.toDouble(),
        beatIndex: (j['beatIndex'] as num?)?.toInt(),
        beatPhase: _d(j['beatPhase']),
        beatInBar: (j['beatInBar'] as num?)?.toInt(),
        barIndex: (j['barIndex'] as num?)?.toInt(),
        barPhase: _d(j['barPhase']),
        phraseBar: (j['phraseBar'] as num?)?.toInt(),
        phrasePhase: _d(j['phrasePhase']),
        section: j['section'] as String?,
        sectionK: _d(j['sectionK']),
        sectionBarsLeft: (j['sectionBarsLeft'] as num?)?.toDouble(),
        dropBeatsAway: (j['dropBeatsAway'] as num?)?.toDouble(),
        breakdown: j['breakdown'] == true,
        buildK: _d(j['buildK']),
        energy: _d(j['energy']),
        vocal: _d(j['vocal']),
        lyric: j['lyric'] as String?,
        lyricK: _d(j['lyricK']),
        hook: j['hook'] == true,
        key: j['key'] as String?,
        camelot: j['camelot'] as String?,
        keyHue: (j['keyHue'] as num?)?.toDouble(),
        coverColor: j['coverColor'] is num ? Color((j['coverColor'] as num).toInt()) : null,
        coverUrl: j['coverUrl'] as String?,
        level: _d(j['level']),
        eqLow: j['eqLow'] is num ? _d(j['eqLow']) : 1,
        eqMid: j['eqMid'] is num ? _d(j['eqMid']) : 1,
        eqHigh: j['eqHigh'] is num ? _d(j['eqHigh']) : 1,
        filter: _d(j['filter']),
        stemDrums: j['stemDrums'] is num ? _d(j['stemDrums']) : 1,
        stemRest: j['stemRest'] is num ? _d(j['stemRest']) : 1,
        stemVocals: j['stemVocals'] is num ? _d(j['stemVocals']) : 1,
        looping: j['looping'] == true,
        audio: j['audio'] is Map ? ShowAudio.fromJson((j['audio'] as Map).cast()) : ShowAudio.silence,
      );
}

/// A mix on, or waiting for its beat.
class ShowMix {
  const ShowMix({
    this.on = false,
    this.armed = false,
    this.kind,
    this.from,
    this.to,
    this.bars = 0,
    this.k = 0,
    this.startsIn,
  });

  final bool on, armed;
  final String? kind, from, to;
  final int bars;

  /// How far through, 0 to 1, while it is on.
  final double k;

  /// How long until it starts, while it is armed.
  final Duration? startsIn;

  static const none = ShowMix();

  void flatInto(Map<String, double> m) {
    m['mix.on'] = on ? 1 : 0;
    m['mix.armed'] = armed ? 1 : 0;
    m['mix.k'] = k;
    m['mix.bars'] = bars.toDouble();
    m['mix.startsIn'] = startsIn == null ? 0 : startsIn!.inMicroseconds / 1e6;
  }

  Map<String, dynamic> toJson() => {
        'on': on, 'armed': armed, 'kind': kind, 'from': from, 'to': to, 'bars': bars, 'k': k,
        'startsInMs': startsIn?.inMilliseconds,
      };

  factory ShowMix.fromJson(Map<String, dynamic> j) => ShowMix(
        on: j['on'] == true,
        armed: j['armed'] == true,
        kind: j['kind'] as String?,
        from: j['from'] as String?,
        to: j['to'] as String?,
        bars: (j['bars'] as num?)?.toInt() ?? 0,
        k: _d(j['k']),
        startsIn: j['startsInMs'] is num ? Duration(milliseconds: (j['startsInMs'] as num).toInt()) : null,
      );
}

/// The show's colours: a primary, a secondary that answers it, an accent for the
/// hits.
class ShowPalette {
  const ShowPalette({required this.primary, required this.secondary, required this.accent});

  final HSLColor primary, secondary, accent;

  static final house = ShowPalette(
    primary: const HSLColor.fromAHSL(1, 262, 0.7, 0.55),
    secondary: const HSLColor.fromAHSL(1, 190, 0.8, 0.5),
    accent: const HSLColor.fromAHSL(1, 40, 0.9, 0.7),
  );

  /// Eased towards [o]: the hue the short way round the wheel (HSLColor.lerp goes
  /// the long way, through every colour between), the rest straight.
  ShowPalette lerp(ShowPalette o, double t) => ShowPalette(
        primary: _lerpHsl(primary, o.primary, t),
        secondary: _lerpHsl(secondary, o.secondary, t),
        accent: _lerpHsl(accent, o.accent, t),
      );

  static HSLColor _lerpHsl(HSLColor a, HSLColor b, double t) {
    var d = (b.hue - a.hue) % 360;
    if (d > 180) d -= 360;
    return HSLColor.fromAHSL(
      1,
      (a.hue + d * t) % 360,
      a.saturation + (b.saturation - a.saturation) * t,
      a.lightness + (b.lightness - a.lightness) * t,
    );
  }

  void flatInto(Map<String, double> m) {
    for (final (name, c) in [('primary', primary), ('secondary', secondary), ('accent', accent)]) {
      m['palette.$name.h'] = c.hue / 360;
      m['palette.$name.s'] = c.saturation;
      m['palette.$name.l'] = c.lightness;
      final rgb = c.toColor();
      m['palette.$name.r'] = rgb.r;
      m['palette.$name.g'] = rgb.g;
      m['palette.$name.b'] = rgb.b;
    }
  }

  static List<double> _hsl(HSLColor c) => [c.hue, c.saturation, c.lightness];
  static HSLColor _fromList(Object? v, HSLColor or) {
    if (v is! List || v.length < 3) return or;
    return HSLColor.fromAHSL(1, _d(v[0]), _d(v[1]), _d(v[2]));
  }

  Map<String, dynamic> toJson() =>
      {'primary': _hsl(primary), 'secondary': _hsl(secondary), 'accent': _hsl(accent)};

  factory ShowPalette.fromJson(Map<String, dynamic> j) => ShowPalette(
        primary: _fromList(j['primary'], house.primary),
        secondary: _fromList(j['secondary'], house.secondary),
        accent: _fromList(j['accent'], house.accent),
      );
}

/// The performer's hands on the show: what the pads, the keys and the phone set.
class ShowMacros {
  const ShowMacros({
    this.intensity = 1,
    this.colour = 0,
    this.strobe = 0,
    this.blackout = false,
    this.freeze = false,
    this.hit = 0,
    this.macros = const [0, 0, 0, 0, 0, 0, 0, 0],
  });

  /// A master for everything, 0 to 1; a turn of the palette's hue, 0 to 1 round;
  /// the strobe held, 0 to 1; everything off; the picture held still; the last hit,
  /// 1 as it lands and falling; eight knobs each scene reads its own way.
  final double intensity, colour, strobe, hit;
  final bool blackout, freeze;
  final List<double> macros;

  static const none = ShowMacros();

  ShowMacros copyWith({
    double? intensity,
    double? colour,
    double? strobe,
    bool? blackout,
    bool? freeze,
    double? hit,
    List<double>? macros,
  }) =>
      ShowMacros(
        intensity: intensity ?? this.intensity,
        colour: colour ?? this.colour,
        strobe: strobe ?? this.strobe,
        blackout: blackout ?? this.blackout,
        freeze: freeze ?? this.freeze,
        hit: hit ?? this.hit,
        macros: macros ?? this.macros,
      );

  void flatInto(Map<String, double> m) {
    m['show.intensity'] = intensity;
    m['show.colour'] = colour;
    m['show.strobe'] = strobe;
    m['show.blackout'] = blackout ? 1 : 0;
    m['show.freeze'] = freeze ? 1 : 0;
    m['show.hit'] = hit;
    for (var i = 0; i < macros.length; i++) {
      m['show.macro.${i + 1}'] = macros[i];
    }
  }

  Map<String, dynamic> toJson() => {
        'intensity': intensity, 'colour': colour, 'strobe': strobe, 'blackout': blackout,
        'freeze': freeze, 'hit': hit, 'macros': macros,
      };

  factory ShowMacros.fromJson(Map<String, dynamic> j) => ShowMacros(
        intensity: j['intensity'] is num ? _d(j['intensity']) : 1,
        colour: _d(j['colour']),
        strobe: _d(j['strobe']),
        blackout: j['blackout'] == true,
        freeze: j['freeze'] == true,
        hit: _d(j['hit']),
        macros: [for (final v in (j['macros'] as List? ?? const [])) _d(v)],
      );
}

/// One frame of the show.
class ShowState {
  ShowState({
    required this.now,
    this.dt = 0,
    required this.a,
    required this.b,
    this.masterName = 'A',
    this.audio = ShowAudio.silence,
    this.mix = ShowMix.none,
    ShowPalette? palette,
    this.macros = ShowMacros.none,
    this.setK = 0,
    this.setEnergy = 0,
    this.scene,
    this.sceneFrom,
    this.sceneK = 1,
    this.genome = Genome.none,
    this.dyn = const {},
  }) : palette = palette ?? ShowPalette.house;

  /// The wall clock this frame was made for, and the seconds since the last.
  final DateTime now;
  final double dt;
  final ShowDeck a, b;

  /// Which deck has the room: the one with the fader, sticky through a mix.
  final String masterName;

  /// The two channels' pulses summed, as the room hears them.
  final ShowAudio audio;
  final ShowMix mix;
  final ShowPalette palette;
  final ShowMacros macros;

  /// Where the set is, 0 to 1, and how much energy its plan has here.
  final double setK, setEnergy;

  /// The scene the director has on, the one it is leaving, and how far across
  /// (1: wholly on [scene]).
  final String? scene, sceneFrom;
  final double sceneK;

  /// The record's own numbers (show_genome.dart), as `gene.*` in [flat].
  final Genome genome;

  /// The dynamics (show_dynamics.dart): hits, adaptive bands, exposure, the grid's
  /// ramps — by their `dyn.*` names.
  final Map<String, double> dyn;

  ShowDeck get master => masterName == 'B' ? b : a;
  ShowDeck get other => masterName == 'B' ? a : b;
  ShowDeck deck(String name) => name == 'B' ? b : a;

  /// Everything, by dotted name, for a binding — `master.beat.phase`,
  /// `audio.kick`, `palette.primary.h`, `show.strobe` — worked out once and kept.
  Map<String, double> get flat => _flat ??= _flatten();
  Map<String, double>? _flat;

  Map<String, double> _flatten() {
    final m = <String, double>{};
    m['time.now'] = now.millisecondsSinceEpoch / 1000;
    m['time.dt'] = dt;
    a.flatInto(m, 'deck.a');
    b.flatInto(m, 'deck.b');
    master.flatInto(m, 'master');
    m['master.isB'] = masterName == 'B' ? 1 : 0;
    audio.flatInto(m, 'audio');
    mix.flatInto(m);
    palette.flatInto(m);
    macros.flatInto(m);
    m['set.k'] = setK;
    m['set.energy'] = setEnergy;
    m['show.scene.k'] = sceneK;
    genome.flatInto(m);
    m.addAll(dyn);
    // What a scene mostly wants: how much is going on, all told, with the hands over it.
    m['intensity'] = macros.blackout ? 0 : (master.energy * master.level + other.energy * other.level).clamp(0.0, 1.0) * macros.intensity;
    return m;
  }

  double operator [](String name) => flat[name] ?? 0;

  ShowState copyWith({
    ShowMacros? macros,
    ShowPalette? palette,
    String? scene,
    String? sceneFrom,
    double? sceneK,
    bool clearSceneFrom = false,
    Genome? genome,
    Map<String, double>? dyn,
  }) =>
      ShowState(
        now: now,
        dt: dt,
        a: a,
        b: b,
        masterName: masterName,
        audio: audio,
        mix: mix,
        palette: palette ?? this.palette,
        macros: macros ?? this.macros,
        setK: setK,
        setEnergy: setEnergy,
        scene: scene ?? this.scene,
        sceneFrom: clearSceneFrom ? null : (sceneFrom ?? this.sceneFrom),
        sceneK: sceneK ?? this.sceneK,
        genome: genome ?? this.genome,
        dyn: dyn ?? this.dyn,
      );

  /// This frame [dt] seconds later, the decks' clocks carried forward.
  ShowState advanced(double dt) => ShowState(
        now: now.add(Duration(microseconds: (dt * 1e6).round())),
        dt: dt,
        a: a.advanced(dt),
        b: b.advanced(dt),
        masterName: masterName,
        audio: audio,
        mix: mix,
        palette: palette,
        macros: macros,
        setK: setK,
        setEnergy: setEnergy,
        scene: scene,
        sceneFrom: sceneFrom,
        sceneK: sceneK,
        genome: genome,
        dyn: dyn,
      );

  Map<String, dynamic> toJson() => {
        'now': now.millisecondsSinceEpoch,
        'dt': dt,
        'a': a.toJson(),
        'b': b.toJson(),
        'master': masterName,
        'audio': audio.toJson(),
        'mix': mix.toJson(),
        'palette': palette.toJson(),
        'macros': macros.toJson(),
        'setK': setK,
        'setEnergy': setEnergy,
        'scene': scene,
        'sceneFrom': sceneFrom,
        'sceneK': sceneK,
        'genome': genome.toJson(),
        'dyn': dyn,
      };

  factory ShowState.fromJson(Map<String, dynamic> j) => ShowState(
        now: DateTime.fromMillisecondsSinceEpoch((j['now'] as num?)?.toInt() ?? 0),
        dt: _d(j['dt']),
        a: ShowDeck.fromJson((j['a'] as Map?)?.cast() ?? const {'name': 'A'}),
        b: ShowDeck.fromJson((j['b'] as Map?)?.cast() ?? const {'name': 'B'}),
        masterName: '${j['master'] ?? 'A'}',
        audio: j['audio'] is Map ? ShowAudio.fromJson((j['audio'] as Map).cast()) : ShowAudio.silence,
        mix: j['mix'] is Map ? ShowMix.fromJson((j['mix'] as Map).cast()) : ShowMix.none,
        palette: j['palette'] is Map ? ShowPalette.fromJson((j['palette'] as Map).cast()) : null,
        macros: j['macros'] is Map ? ShowMacros.fromJson((j['macros'] as Map).cast()) : ShowMacros.none,
        setK: _d(j['setK']),
        setEnergy: _d(j['setEnergy']),
        scene: j['scene'] as String?,
        sceneFrom: j['sceneFrom'] as String?,
        sceneK: j['sceneK'] is num ? _d(j['sceneK']) : 1,
        genome: j['genome'] is Map ? Genome.fromJson((j['genome'] as Map).cast()) : Genome.none,
        dyn: j['dyn'] is Map ? {for (final e in (j['dyn'] as Map).entries) '${e.key}': _d(e.value)} : const {},
      );
}
