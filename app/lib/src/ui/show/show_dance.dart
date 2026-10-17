// The dancer: a photogrammetry scan of a person, rigged, put through motion capture
// and drawn live in 3D on the record's grid (show_dance_rig.dart, show_dance_draw.dart).
//
// A move is a loop of capture beats, its poses sampled eight times a beat, so it is
// played by the deck's beat — index and phase — and the steps land on the record's
// beats at any tempo; a seek lands on the same step. A record far off a capture's
// tempo dances it at half or double time.
//
// The choreography, two bars at a time (show_meme.dart's moods):
//
//   sleep   a breakdown, a quiet intro or outro, a paused deck: the calm moves at
//           half time, alone, the camera drifting round.
//   wake    the build: the moves warm toward big as the drop nears, the camera
//           pushing in and circling faster, a whip round on the last beat.
//   rage    the drop: the big moves, cut onto with a flash; others join — a trio, a
//           line doing the wave, a crowd round the dancer; the camera cuts by the bar.
//   vibe    between: the middle moves, glides between angles.
//
// Which moves: the tier for the mood, then a flavour for the record (two styles of
// the bank's seven it leans on), the tempo (a move whose capture is near the
// record's, or its half or double, dances truest), and what came lately. The next
// move starts at the beat of it whose pose is nearest the pose the dancer is in, and
// the two blend bone by bone over a beat — a step out of one into the other.
// Every choice is hashed from the record and the slot, so a record dances the same
// way twice.
//
// The dancers: the scan, or one of a few rigged characters (100Avatars, CC0) —
// picked in the show panel (ShowMacros.dancer), or "mix": each record its own lead
// and a troupe of the others. Every model dances the same moves, retargeted onto it
// ahead (tools/show-dance/dance_model.py), drawn at a person's height.
//
// The stages (the scene's sim kind):
//
//   dance.disco    a lit floor of tiles chasing the beat, a mirror ball and its flecks.
//   dance.neon     a void with a scrolling grid and a low sun; the dancer black inside
//                  a neon line, echoed by ghosts of a moment ago on the drop.
//   dance.shadow   a lamp low in front, the dancer's shadow huge on the wall behind;
//                  three coloured lamps and three shadows on the drop.
//   dance.art      renderings: a silhouette, light trails, text, dither, a
//                  chronophotograph (DanceArt).
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/show/show_state.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_dance_draw.dart';
import 'show_dance_rig.dart';
import 'show_meme.dart' show MemeClock;
import 'show_meme_bank.dart' show MemeMood, memeHash;
import 'show_sims.dart';

export 'show_dance_rig.dart' show DanceMove, DanceTier, DanceStyle;

/// Who dances: the dancer alone, or with others.
enum DanceTroupe { solo, duo, trio, line, crowd }

/// Where the camera is: in front of the dancer, a few ways framed, and still.
enum DanceShot { full, front, medium, close, wide }

/// The stage a scene puts the dancer on.
enum DanceStage { disco, neon, shadow, art }

/// How the stylised stage (dance.art) renders the dancer, a section at a time:
///
///   mono     a silhouette, black on white — the shadow-play of the Bad Apple
///            video — turning to white on black by the bar in a drop, a chorus line
///            of them at its height;
///   trails   a clay figure in the dark, ribbons of light swept behind its hands,
///            feet and head over the last beat or two;
///   ascii    the figure as text, each cell's brightness a glyph;
///   dither   one bit: the lit, textured figure in ordered dither, ink and paper;
///   chrono   a chronophotograph: the figure stamped every half beat (every quarter
///            in a drop), the older stamps darker behind the newest.
enum DanceArt { mono, trails, ascii, dither, chrono }

/// The dance's arithmetic, apart from any drawing.
class DanceClock {
  const DanceClock._();

  /// Track beats in a slot: one choice of move, troupe and shot.
  static const slotBeats = 8;

  /// Capture beats danced per track beat: 1, or half/double time when the record
  /// is far off the capture's tempo. A sleeping record dances at half again.
  static double rate(double trackBpm, double moveBpm, {bool sleep = false}) {
    final q = trackBpm / moveBpm;
    var r = q > 1.45 ? 0.5 : (q < 0.7 ? 2.0 : 1.0);
    if (sleep) r /= 2;
    return r;
  }

  /// How true [move] dances to a record at [trackBpm], 0..1: 1 where the capture's
  /// tempo (or its half or double) is the record's, falling off as it is stretched.
  static double tempoFit(double trackBpm, DanceMove move) {
    final played = trackBpm * rate(trackBpm, move.bpm);
    final l = math.log(played / move.bpm) / math.ln2;
    return math.exp(-l * l / (2 * 0.16 * 0.16));
  }

  /// Which tier of moves the mood dances: calm asleep, big in the drop, warming
  /// through a build ([wakeK] 0..1 toward the drop), middle otherwise — a little
  /// higher on a loud record.
  static DanceTier tier(MemeMood mood, {double wakeK = 0, double energy = 0.5, double dice = 0}) => switch (mood) {
        MemeMood.sleep => DanceTier.low,
        MemeMood.rage => DanceTier.high,
        MemeMood.wake => wakeK > 0.66 ? DanceTier.high : (wakeK > 0.2 || dice < 0.5 ? DanceTier.mid : DanceTier.low),
        MemeMood.vibe => energy > 0.75 && dice < 0.35 ? DanceTier.high : (energy < 0.35 && dice < 0.4 ? DanceTier.low : DanceTier.mid),
      };

  /// A record to dance to as to techno: four to the floor at a club's tempo, few
  /// words. It wants the steady grooves, pumping on the beat, and hardly any of
  /// the party pieces.
  static bool techno(double bpm, double vocal) => bpm >= 118 && bpm <= 152 && vocal < 0.4;

  /// How much a record leans on each style. Groove always. On techno, groove all but
  /// alone. Otherwise two more by the record, and the tempo's own (a swing's bounce,
  /// a salsa's quick count). The calm ones only asleep. The fun ones — the party
  /// pieces, the cartoon — rare, and a little likelier on a sung hook, where they fit.
  static Map<DanceStyle, double> flavour(int salt, double bpm, MemeMood mood, {bool hook = false, bool techno = false}) {
    final calm = mood == MemeMood.sleep ? 1.6 : 0.04;
    if (techno) {
      return {
        DanceStyle.groove: 3.0,
        DanceStyle.latin: 0.25,
        DanceStyle.folk: 0.2,
        DanceStyle.swing: 0.08,
        DanceStyle.toon: 0.04,
        DanceStyle.party: hook ? 0.1 : 0.02,
        DanceStyle.calm: calm,
      };
    }
    final w = <DanceStyle, double>{
      DanceStyle.groove: 1.2,
      DanceStyle.latin: 0.45,
      DanceStyle.folk: 0.4,
      DanceStyle.swing: 0.25,
      DanceStyle.toon: 0.1,
      DanceStyle.party: hook ? 0.35 : 0.04,
      DanceStyle.calm: calm,
    };
    const leaning = [DanceStyle.latin, DanceStyle.folk, DanceStyle.swing, DanceStyle.groove];
    final a = leaning[(memeHash(salt % 9973, 11, 5) * leaning.length).floor() % leaning.length];
    final b = leaning[(memeHash(salt % 9973, 13, 7) * leaning.length).floor() % leaning.length];
    w[a] = w[a]! * 2.5;
    w[b] = w[b]! * 1.8;
    if (bpm >= 112 && bpm <= 136) w[DanceStyle.swing] = w[DanceStyle.swing]! * 1.5;
    if (bpm < 110) w[DanceStyle.latin] = w[DanceStyle.latin]! * 1.5;
    if (bpm > 150) w[DanceStyle.folk] = w[DanceStyle.folk]! * 1.4;
    return w;
  }

  /// The moves worth dancing next, best first with their weights: [tier]'s, by the
  /// record's [flavour], by tempo, the [recent] ones held back.
  /// On [techno] the moves that pump on the beat (DanceMove.pulse) and keep the
  /// record's tempo count for more.
  static List<(DanceMove, double)> pool(List<DanceMove> moves, DanceTier tier, Map<DanceStyle, double> flavour, double bpm,
      {List<String> recent = const [], bool techno = false}) {
    final out = <(DanceMove, double)>[];
    for (final m in moves) {
      final d = (m.tier.index - tier.index).abs();
      final fit = tempoFit(bpm, m);
      var w = (d == 0 ? 1.0 : (d == 1 ? 0.12 : 0.015)) * (flavour[m.style] ?? 0.3) * (techno ? (0.1 + fit) * (0.25 + 1.5 * m.pulse) : 0.2 + fit);
      final r = recent.indexOf(m.id);
      if (r >= 0) w *= r == recent.length - 1 ? 0 : 0.15;
      if (w > 0) out.add((m, w));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  /// One of [pool] by its weights, by the dice [d] (0..1).
  static DanceMove? draw(List<(DanceMove, double)> pool, double d) {
    if (pool.isEmpty) return null;
    final total = pool.fold<double>(0, (s, e) => s + e.$2);
    var x = d * total;
    for (final (m, w) in pool) {
      x -= w;
      if (x <= 0) return m;
    }
    return pool.last.$1;
  }

  /// The beats of [move] a dancer may step into it on: the bar's halves.
  static List<int> entries(DanceMove move) => [for (var e = 0; e < move.beats; e += 2) e];

  /// Who dances slot [slot] in [mood]: often company — a partner, a trio, a line,
  /// in a drop's height a crowd — and alone mostly when it is quiet.
  static DanceTroupe troupe(MemeMood mood, int salt, int slot, {double heat = 1}) {
    final d = memeHash(salt % 9973, slot, 23);
    DanceTroupe by(List<(double, DanceTroupe)> odds) => odds.firstWhere((o) => d < o.$1, orElse: () => odds.last).$2;
    return switch (mood) {
      MemeMood.sleep => by([(0.75, DanceTroupe.solo), (1, DanceTroupe.duo)]),
      MemeMood.wake => by([(0.45, DanceTroupe.solo), (0.75, DanceTroupe.duo), (1, DanceTroupe.trio)]),
      MemeMood.rage => heat < 0.7
          ? by([(0.2, DanceTroupe.solo), (0.5, DanceTroupe.duo), (0.8, DanceTroupe.trio), (1, DanceTroupe.line)])
          : by([(0.1, DanceTroupe.solo), (0.3, DanceTroupe.trio), (0.6, DanceTroupe.line), (1, DanceTroupe.crowd)]),
      MemeMood.vibe => by([(0.3, DanceTroupe.solo), (0.6, DanceTroupe.duo), (0.85, DanceTroupe.trio), (1, DanceTroupe.line)]),
    };
  }

  /// The camera for cut [cut] in [mood]: always from the front, framed wider or
  /// closer; the whole troupe when there is one.
  static DanceShot shot(MemeMood mood, int salt, int cut, DanceTroupe troupe) {
    final d = memeHash(salt % 9973, cut, 41);
    if (troupe == DanceTroupe.line || troupe == DanceTroupe.crowd) return d < 0.75 ? DanceShot.wide : DanceShot.full;
    final pick = switch (mood) {
      MemeMood.sleep => [DanceShot.full, DanceShot.front],
      MemeMood.wake => [DanceShot.front, DanceShot.medium],
      MemeMood.rage => [DanceShot.full, DanceShot.front, DanceShot.medium, DanceShot.close],
      MemeMood.vibe => [DanceShot.full, DanceShot.front, DanceShot.full, DanceShot.medium, DanceShot.close],
    };
    return pick[(d * pick.length).floor() % pick.length];
  }

  /// The stylised stage's rendering for its [n]th section in [mood]: the calm ones
  /// asleep, the moving ones in a drop, any between; never [not] again.
  static DanceArt art(MemeMood mood, int salt, int n, {DanceArt? not}) {
    final pool = switch (mood) {
      MemeMood.sleep => [DanceArt.mono, DanceArt.ascii, DanceArt.dither],
      MemeMood.wake => [DanceArt.ascii, DanceArt.dither, DanceArt.trails, DanceArt.mono],
      MemeMood.rage => [DanceArt.trails, DanceArt.chrono, DanceArt.mono],
      MemeMood.vibe => DanceArt.values,
    };
    final d = memeHash(salt % 9973, n, 97);
    var a = pool[(d * pool.length).floor() % pool.length];
    if (a == not && pool.length > 1) a = pool[(pool.indexOf(a) + 1) % pool.length];
    return a;
  }

  /// How many beats a camera holds: long, and a little shorter in the drop.
  static int hold(MemeMood mood) => switch (mood) {
        MemeMood.rage => 8,
        MemeMood.sleep => 32,
        _ => 16,
      };
}

/// A camera placed: round the dancer by [yaw] (0 straight in front), at [height],
/// [dist] away, looking at [aim] high, [fov] wide, its horizon tipped by [roll].
class DanceFrame {
  const DanceFrame(this.yaw, this.height, this.dist, this.aim, this.fov, [this.roll = 0]);
  final double yaw, height, dist, aim, fov, roll;

  static DanceFrame of(DanceShot s, DanceTroupe t) {
    final wide = t == DanceTroupe.solo ? 1.0 : (t == DanceTroupe.duo || t == DanceTroupe.trio ? 1.3 : 1.6);
    return switch (s) {
      DanceShot.full => DanceFrame(0.3, 1.3, 4.4 * wide, 0.95, 0.62),
      DanceShot.front => DanceFrame(0.0, 1.2, 4.1 * wide, 0.95, 0.62),
      DanceShot.medium => const DanceFrame(0.15, 1.3, 3.3, 1.02, 0.6),
      DanceShot.close => const DanceFrame(0.1, 1.45, 2.5, 1.2, 0.6),
      DanceShot.wide => DanceFrame(0.1, 1.6, 4.6 * wide, 0.85, 0.62),
    };
  }

  static DanceFrame lerp(DanceFrame a, DanceFrame b, double t) {
    double l(double x, double y) => x + (y - x) * t;
    return DanceFrame(l(a.yaw, b.yaw), l(a.height, b.height), l(a.dist, b.dist), l(a.aim, b.aim), l(a.fov, b.fov), l(a.roll, b.roll));
  }

  DanceFrame turned(double by, {double closer = 1, double roll = 0}) => DanceFrame(yaw + by, height, dist * closer, aim, fov, this.roll + roll);

  DanceCam cam(Size size, {double shake = 0}) {
    final eye = V3(math.sin(yaw) * dist, -math.cos(yaw) * dist, height);
    return DanceCam(eye: eye, target: V3(0, 0, aim + shake * 0.01), size: size, fov: fov, roll: roll);
  }
}

/// The dancers to pick from, by id (`assets/show/dance/<id>/`) and name.
class DanceModels {
  const DanceModels._();
  static const all = [
    ('chris', 'Chris (scan)'),
    ('banana', 'Cool Banana'),
    ('hotdog', 'Hotdog'),
    ('stickbug', 'Sr. Stickbug'),
    ('stonks', 'Stonks'),
    ('alien', 'Weird Flex'),
    ('doge', 'Dogo Burger'),
  ];

  /// Each record its own lead, the troupe of the others.
  static const mix = 'mix';

  /// The lead for record [salt] when the panel says [choice].
  static String lead(String? choice, int salt) {
    if (choice != null && choice != mix && all.any((m) => m.$1 == choice)) return choice;
    return all[(memeHash(salt % 9973, 17, 29) * all.length).floor() % all.length].$1;
  }

  /// Member [i]'s model: the lead's, or in a mix one of the others.
  static String member(String? choice, int salt, int i) {
    if (choice != null && choice != mix) return lead(choice, salt);
    final others = [for (final m in all) if (m.$1 != lead(choice, salt)) m.$1];
    return others[(memeHash(salt % 9973, 31 + i, 37) * others.length).floor() % others.length];
  }
}

/// The rig and the skin of one dancer, read once per process.
class DanceAssets {
  DanceAssets._(this.name);
  final String name;
  static final _all = <String, DanceAssets>{};

  static DanceAssets of(String name) => _all.putIfAbsent(name, () {
        final a = DanceAssets._(name);
        a.loaded = a._load();
        return a;
      });

  @visibleForTesting
  static void put(String name, DanceRig rig, ui.Image skin) => _all[name] = DanceAssets._(name)
    ..rig = rig
    ..skin = skin;

  Future<void> loaded = Future.value();
  DanceRig? rig;
  ui.Image? skin;
  bool get ready => rig != null && skin != null;
  String get dir => 'assets/show/dance/$name/';

  Future<void> _load() async {
    try {
      rig = await DanceRig.load(rootBundle, dir);
      final data = await rootBundle.load('${dir}skin.webp');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      skin = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (e) {
      // ignore: avoid_print
      print('dance $name: $e');
    }
  }
}

/// One line of dancing: a move playing from an anchor, and the one before it while
/// they blend.
class _Track {
  DanceMove? move, prev;
  double at = 0, phase = 0, rate = 1;
  double pAt = 0, pPhase = 0, pRate = 1;
  double blendAt = -99, blendLen = 0;

  double beatOf(double beats) => phase + (beats - at) * rate;

  void switchTo(DanceMove m, double beats, double entry, double rate, double blend) {
    prev = move;
    pAt = at;
    pPhase = phase;
    pRate = this.rate;
    move = m;
    at = beats;
    phase = entry;
    this.rate = rate;
    blendAt = beats;
    blendLen = prev == null ? 0 : blend;
  }

  /// The same move on at a new rate, without a jump.
  void retime(double beats, double rate) {
    if (move == null || rate == this.rate) return;
    phase = beatOf(beats);
    at = beats;
    this.rate = rate;
  }

  /// The pose at track beat [beats] into [out] ([tmp] scratch).
  bool pose(DanceRig rig, double beats, DancePose out, DancePose tmp) {
    final m0 = move;
    if (m0 == null) return false;
    // Another model dances the same move from its own table.
    final m = rig.move(m0.id) ?? m0;
    rig.sample(m, beatOf(beats), out);
    final p0 = prev;
    if (p0 != null && blendLen > 0) {
      final k = ((beats - blendAt) / blendLen).clamp(0.0, 1.0);
      if (k < 1) {
        rig.sample(rig.move(p0.id) ?? p0, pPhase + (beats - pAt) * pRate, tmp);
        final w = k * k * (3 - 2 * k);
        tmp.blendToward(out, w);
        out.copyFrom(tmp);
      }
    }
    return true;
  }
}

/// A dancer in the troupe: which line it dances (the lead's, a beat-fraction behind,
/// or its own), where it stands, and how far in it has come.
class _Member {
  _Member(this.spot, {this.delay = 0, this.own = false, this.from = Offset.zero});
  DanceSpot spot;
  DanceBody? body;
  String? model;
  double delay;
  bool own;

  /// Where it comes in from (an offset on the floor) and how far in it is, 0..1.
  Offset from;
  double inK = 0;
  bool leaving = false;
}

class DanceSim implements SimLayer {
  DanceSim(this.kind)
      : stage = switch (kind) {
          'dance.neon' => DanceStage.neon,
          'dance.shadow' => DanceStage.shadow,
          'dance.art' => DanceStage.art,
          _ => DanceStage.disco,
        },
        assets = DanceAssets.of('chris') {
    for (final m in DanceModels.all) {
      DanceAssets.of(m.$1);
    }
    // A rendering forced from outside, for a look at one: WETOWL_DANCE_ART=ascii.
    try {
      final forced = Platform.environment['WETOWL_DANCE_ART'];
      if (forced != null) _forcedArt = DanceArt.values.where((a) => a.name == forced).firstOrNull;
      _forcedModel = Platform.environment['WETOWL_DANCE_MODEL'];
    } catch (_) {}
  }
  DanceArt? _forcedArt;

  /// A dancer forced from outside: WETOWL_DANCE_MODEL=banana (or mix).
  String? _forcedModel;
  @override
  final String kind;
  final DanceStage stage;

  /// The scan's: the moves' table and the poses' arithmetic go by it.
  final DanceAssets assets;

  /// A model's assets when they are in, the scan's otherwise.
  DanceAssets _ready(String id) {
    final a = DanceAssets.of(id);
    return a.ready ? a : assets;
  }

  /// How much bigger a model is drawn, so every dancer stands about a person's
  /// height — within reason: a round burger stays a short one.
  static double _scaleOf(DanceRig rig) => rig.height > 0.3 ? (1.75 / rig.height).clamp(0.8, 1.2) : 1;

  ui.Image? _out;
  double _t = 0;
  double? _dropAt, _awayWas;
  String? _sectionWas;
  int _slot = -999, _cut = -999;
  final _lead = _Track(), _alt = _Track();
  final _recent = <String>[];
  DanceTroupe _troupe = DanceTroupe.solo;
  final _members = <_Member>[];
  DanceShot _shot = DanceShot.full;
  DanceArt? _art;
  int _artN = 0;
  ui.FragmentShader? _fx;
  static ui.Image? _glyphs;
  static const _ramp = ' .:-=+*#%@';
  final _histW = Float64List(DanceRigLimits.bones * 12);
  final _p3 = Float64List(3);
  int _sectionSlot = -1;
  int _frames = 0;
  (DanceTier, Map<DanceStyle, double>, bool, bool)? _altDue;
  int _altDueFrame = 0;
  DanceTroupe? _troupeDrawn;
  Size? _sizeWas;
  DanceArt? _artWas;

  DanceBody? _hero;
  String? _heroModel;
  final _bodies = <String, DanceBody>{};
  double _heroScale = 1;
  DancePose? _pose, _tmp;
  final _ghosts = <DanceBody>[];
  String? _ghostModel;

  /// The lead model's light mesh [i] for ghosts and stamps.
  DanceBody _ghost(DanceRig rig, int i) {
    if (_ghostModel != _heroModel) {
      _ghosts.clear();
      _ghostModel = _heroModel;
    }
    final lod = rig.meshes.length > 1 ? rig.meshes[1] : rig.meshes.first;
    while (_ghosts.length <= i) {
      _ghosts.add(DanceBody(lod, _ready(_heroModel ?? 'chris').skin!));
    }
    return _ghosts[i];
  }

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) {
    final rig = assets.rig, skin = assets.skin;
    if (rig == null || skin == null) return null;
    _t += dt;
    final m = st.master;
    final f = st.flat;
    final playing = m.playing && m.beatIndex != null;
    final bpm = (m.bpm ?? 0) > 1 ? m.bpm! : 120.0;
    final beats = !playing
        ? _t * bpm / 60
        : (m.barIndex != null && m.beatInBar != null ? m.barIndex! * 4 + m.beatInBar! + m.beatPhase : m.beatIndex! + m.beatPhase);
    final salt = m.trackId ?? 0;

    // The drop, remembered past the deck's two beats (as the meme edit does).
    final away = m.dropBeatsAway;
    if (playing) {
      final was = _awayWas;
      if (away != null && away <= 0 && away > -2.5 && (was == null || was > 0)) _dropAt = beats + away;
      if (m.section == 'drop' && _sectionWas != 'drop' && (_dropAt == null || beats - _dropAt! > 8)) _dropAt = beats;
      final d = _dropAt;
      if (d != null && (beats - d < -1 || beats - d > 64)) _dropAt = null;
    }
    final sectionTurned = playing && _sectionWas != null && m.section != _sectionWas;
    _awayWas = away;
    _sectionWas = m.section;
    final since = _dropAt == null ? null : beats - _dropAt!;
    final mood = playing ? MemeClock.mood(m, sinceDrop: since) : MemeMood.sleep;
    final heat = mood == MemeMood.rage ? MemeClock.heat(m, sinceDrop: since) : 0.0;
    final wakeK = mood == MemeMood.wake ? MemeClock.wakeK(m) : 0.0;
    final kick = f['dyn.hit.kick'] ?? 0;

    final choice = _forcedModel ?? st.macros.dancer;
    final leadA = _ready(DanceModels.lead(choice, salt));
    if (_hero == null || _heroModel != leadA.name) {
      _hero = _bodies.putIfAbsent('${leadA.name}/lead', () => DanceBody(leadA.rig!.meshes.first, leadA.skin!));
      _heroModel = leadA.name;
    }
    final leadRig = leadA.rig!;
    _heroScale = _scaleOf(leadRig);
    _pose ??= DancePose(rig.bones);
    _tmp ??= DancePose(rig.bones);

    // ---- the choreography: a slot every two bars; a drop or a new section a slot of its own.
    final n = (beats / DanceClock.slotBeats).floor();
    final dropNow = since != null && since >= 0 && since < 0.5 && _lead.move?.tier != DanceTier.high;
    final sectionNow = sectionTurned && _sectionSlot != n;
    final sleep = mood == MemeMood.sleep;
    if (stage == DanceStage.art && (_art == null || dropNow || sectionNow)) {
      _art = _forcedArt ?? DanceClock.art(mood, salt, _artN++, not: _art);
    }
    if (_lead.move == null || n != _slot || dropNow || sectionNow) {
      if (sectionNow) _sectionSlot = n;
      final keep = _lead.move != null && !dropNow && !sectionNow && sleep && _lead.rate < 1 && n.isOdd;
      if (!keep) {
        final tier = DanceClock.tier(mood, wakeK: wakeK, energy: m.energy, dice: memeHash(salt % 9973, n, 3));
        final techno = DanceClock.techno(bpm, m.vocal);
        final flavour = DanceClock.flavour(salt, bpm, mood, hook: m.hook && m.vocal > 0.3, techno: techno);
        _step(rig, _lead, tier, flavour, bpm, beats, salt, n, sleep: sleep, blend: dropNow ? 0 : (sleep ? 2 : 1), techno: techno);
        // The others' own line on the next frame: the slot's work split in two.
        _altDue = (tier, flavour, techno, dropNow);
      }
      var troupe = dropNow ? DanceClock.troupe(MemeMood.rage, salt, n + 1) : DanceClock.troupe(mood, salt, n, heat: heat);
      // The stylised stage dances alone, but for a line of silhouettes in a drop.
      if (stage == DanceStage.art) {
        troupe = switch (_art) {
          DanceArt.mono => troupe,
          DanceArt.chrono => DanceTroupe.solo,
          _ => troupe == DanceTroupe.crowd || troupe == DanceTroupe.line ? DanceTroupe.trio : troupe,
        };
      }
      _setTroupe(troupe, salt, n, instant: dropNow);
      _slot = n;
    }
    final due = _altDue;
    if (due != null && (_altDueFrame++ > 0 || dropNow)) {
      _step(rig, _alt, due.$1, due.$2, bpm, beats, salt + 977, n, sleep: sleep, blend: due.$4 ? 0 : 1, quiet: true, techno: due.$3);
      _altDue = null;
      _altDueFrame = 0;
    }
    _lead.retime(beats, DanceClock.rate(bpm, _lead.move!.bpm, sleep: sleep));
    if (_alt.move != null) _alt.retime(beats, DanceClock.rate(bpm, _alt.move!.bpm, sleep: sleep));

    // ---- the camera: still, in front, cut (never moved) to another framing after a
    // while, on a drop and on a new section.
    final hold = DanceClock.hold(mood);
    final cutN = hold * 100000 + (beats / hold).floor();
    final shotWas = _shot, troupeWas = _troupeDrawn;
    if (cutN != _cut || dropNow || sectionNow) {
      _cut = cutN;
      _shot = DanceClock.shot(mood, salt, cutN, _troupe);
      // The silhouettes, the text and the dots read best square on.
      if (stage == DanceStage.art && _shot == DanceShot.full) _shot = DanceShot.front;
    }
    final frame = DanceFrame.of(_shot, _troupe);
    final sizeNow = Size(w.toDouble(), h.toDouble());
    final still = _shot == shotWas && _troupe == troupeWas && sizeNow == _sizeWas && _art == _artWas;
    _troupeDrawn = _troupe;
    _sizeWas = sizeNow;
    _artWas = _art;
    final size = Size(w.toDouble(), h.toDouble());
    final cam = frame.cam(size);

    // ---- the troupe's poses; everyone bobs on the kick (but asleep)
    final pose = _pose!, tmp = _tmp!;
    final bob = sleep ? 0.0 : 0.022 * kick;
    final bodies = <(DanceBody, DanceSpot, double)>[]; // body, spot, depth
    _lead.pose(leadRig, beats, pose, tmp);
    pose.hips[2] -= bob / _heroScale;
    _hero!.pose(leadRig, pose);
    final heroSpot = DanceSpot(scale: _heroScale);
    _hero!.place(heroSpot);
    bodies.add((_hero!, heroSpot, cam.project(const V3(0, 0, 1)).$3));
    for (var i = 0; i < _members.length; i++) {
      final mb = _members[i];
      mb.inK = (mb.inK + (mb.leaving ? -1 : 1) * dt * bpm / 60 / 1.0).clamp(0.0, 1.0);
      if (mb.inK <= 0 && mb.leaving) continue;
      final ma = _ready(DanceModels.member(choice, salt, i));
      final mr = ma.rig!;
      if (mb.body == null || mb.model != ma.name) {
        // Bodies kept by model and place in the troupe, so a new troupe reuses them.
        mb.body = _bodies.putIfAbsent('${ma.name}/$i', () => DanceBody(mr.meshes.length > 1 ? mr.meshes[1] : mr.meshes.first, ma.skin!));
        mb.model = ma.name;
      }
      final body = mb.body!;
      final sc = _scaleOf(mr);
      final e = mb.inK * mb.inK * (3 - 2 * mb.inK);
      final s = mb.spot;
      final spot = DanceSpot(x: s.x + mb.from.dx * (1 - e), y: s.y + mb.from.dy * (1 - e), yaw: s.yaw, mirror: s.mirror, scale: s.scale * sc);
      // The others at thirty frames a second, by turns: every other frame each draws
      // what it drew the frame before (the camera is still between cuts). Not while
      // walking in or off, nor on a cut.
      body.hold = still && mb.inK >= 1 && !mb.leaving && (_frames + i).isOdd;
      if (!body.hold) {
        final track = mb.own && _alt.move != null ? _alt : _lead;
        track.pose(mr, beats - mb.delay, pose, tmp);
        pose.hips[2] -= bob / sc;
        body.pose(mr, pose);
        body.place(spot);
      }
      bodies.add((body, spot, cam.project(V3(spot.x, spot.y, 1)).$3));
    }
    _members.removeWhere((mb) => mb.leaving && mb.inK <= 0);
    bodies.sort((a, b) => b.$3.compareTo(a.$3));
    for (final (b, _, _) in bodies) {
      b.begin();
    }
    _frames++;

    // ---- the picture
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final look = _Look(st, f, mood, beats, since, heat, wakeK, kick, stage);
    switch (stage) {
      case DanceStage.disco:
        _disco(c, size, cam, look, bodies);
      case DanceStage.neon:
        _neon(c, size, cam, look, bodies, leadRig, beats);
      case DanceStage.shadow:
        _shadowStage(c, size, cam, look, bodies, beats);
      case DanceStage.art:
        _artStage(c, size, cam, look, bodies, leadRig, beats);
    }
    // The stylised stage keeps its drop to its own rendering (mono turns over).
    if (stage != DanceStage.art) _finish(c, size, look, dt);
    final pic = rec.endRecording();
    var img = pic.toImageSync(w, h);
    pic.dispose();
    if (stage == DanceStage.art && (_art == DanceArt.ascii || _art == DanceArt.dither)) img = _post(img, w, h, p, look);
    _out?.dispose();
    _out = img;
    return img;
  }

  /// A new move on [track]: one of the pool, starting at the beat whose pose is
  /// nearest the pose it is in now.
  void _step(DanceRig rig, _Track track, DanceTier tier, Map<DanceStyle, double> flavour, double bpm, double beats, int salt, int slot,
      {required bool sleep, double blend = 1, bool quiet = false, bool techno = false}) {
    final pool = DanceClock.pool(rig.moves, tier, flavour, bpm, recent: quiet ? [if (track.move != null) track.move!.id] : _recent, techno: techno);
    if (pool.isEmpty) return;
    final now = DancePose(rig.bones), tmp = DancePose(rig.bones);
    final had = track.pose(rig, beats, now, tmp);
    final from = had ? rig.keyJoints(now) : null;
    // The likeliest few by the dice, then each at its best entry; the nearest pose wins
    // among those (the dice still have the most say).
    final picks = <DanceMove>{};
    for (var k = 0; k < 5 && picks.length < 4; k++) {
      final mv = DanceClock.draw(pool, memeHash(salt % 9973, slot * 7 + k, 7));
      if (mv != null) picks.add(mv);
    }
    DanceMove? best;
    var bestE = 0, bestScore = double.infinity;
    final probe = DancePose(rig.bones);
    var order = 0;
    for (final mv in picks) {
      for (final e in DanceClock.entries(mv)) {
        var d = 0.0;
        if (from != null) {
          rig.sample(mv, e.toDouble(), probe);
          d = DanceRig.poseDistance(from, rig.keyJoints(probe));
        }
        // Earlier picks are the dice's favourites: a small handicap for later ones.
        final score = d + order * 0.04 + e * 0.002;
        if (score < bestScore) {
          bestScore = score;
          best = mv;
          bestE = e;
        }
      }
      order++;
    }
    if (best == null) return;
    track.switchTo(best, beats, bestE.toDouble(), DanceClock.rate(bpm, best.bpm, sleep: sleep), blend);
    if (!quiet) {
      _recent.add(best.id);
      if (_recent.length > 5) _recent.removeAt(0);
    }
  }

  /// The troupe for a slot: the others walk in from the wings (or are simply there,
  /// on a drop's cut) and walk off when the dancer goes back to dancing alone.
  void _setTroupe(DanceTroupe t, int salt, int slot, {bool instant = false}) {
    if (t == _troupe && _members.where((m) => !m.leaving).isNotEmpty == (t != DanceTroupe.solo)) return;
    _troupe = t;
    for (final mb in _members) {
      mb.leaving = true;
      if (instant) mb.inK = 0;
    }
    final spots = <_Member>[];
    switch (t) {
      case DanceTroupe.solo:
        break;
      case DanceTroupe.duo:
        spots.add(_Member(const DanceSpot(x: 1.3, y: 0.6, mirror: true), from: const Offset(4, 0)));
      case DanceTroupe.trio:
        spots
          ..add(_Member(const DanceSpot(x: -1.4, y: 1.1), from: const Offset(-4, 1)))
          ..add(_Member(const DanceSpot(x: 1.4, y: 1.1, mirror: true), from: const Offset(4, 1)));
      case DanceTroupe.line:
        for (final (k, x) in const [(1, -1.2), (2, 1.2), (3, -2.4), (4, 2.4)]) {
          spots.add(_Member(DanceSpot(x: x, y: 0.15 * k, mirror: x > 0), delay: 0.25 * k, from: Offset(x.sign * 5, 0)));
        }
      case DanceTroupe.crowd:
        for (var i = 0; i < 6; i++) {
          final a = math.pi * (0.15 + 0.7 * i / 5);
          final r = 2.2 + 0.5 * memeHash(salt % 9973, slot * 3 + i, 61);
          final x = -math.cos(a) * r, y = math.sin(a) * r * 0.8 + 0.4;
          spots.add(_Member(DanceSpot(x: x, y: y, yaw: -x * 0.12, mirror: i.isOdd), delay: i.isEven ? 0 : 0.5, own: i % 3 == 1, from: Offset(x.sign * 5, 2)));
        }
    }
    for (final s in spots) {
      if (instant) s.inK = 1;
    }
    if (instant) _members.removeWhere((m) => m.leaving);
    _members.addAll(spots);
  }

  // ------------------------------------------------------------------ stages

  /// A backdrop washed from [top] to [bottom] down the picture: vertex colours, one
  /// draw — a gradient fill costs three render passes on Impeller GLES, and a baked
  /// picture of one has to be baked again for every frame the palette moves.
  void _wash(Canvas c, Size s, Color top, Color bottom) {
    final q = DanceQuads()
      ..tri(Offset.zero, Offset(s.width, 0), Offset(s.width, s.height), top, top, bottom)
      ..tri(Offset.zero, Offset(s.width, s.height), Offset(0, s.height), top, bottom, bottom);
    q.draw(c, blend: BlendMode.src);
  }

  /// A backdrop of [outer] with a soft glow of [inner] at [at], [radius] wide.
  void _glow(Canvas c, Size s, Offset at, double radius, Color inner, Color outer) {
    c.drawRect(Offset.zero & s, Paint()..color = outer);
    final q = DanceQuads();
    const seg = 32;
    for (var i = 0; i < seg; i++) {
      final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
      q.tri(at, at + Offset(math.cos(a0), math.sin(a0)) * radius, at + Offset(math.cos(a1), math.sin(a1)) * radius, inner, outer, outer);
    }
    q.draw(c);
  }

  /// Beams from a truss at the back, sweeping the floor (the room's and the disco's drop).
  void _beams(Canvas c, DanceCam cam, _Look l, List<Color> colors, double k) {
    final q = DanceQuads();
    for (var i = 0; i < 6; i++) {
      final x = -3.0 + i * 1.2;
      final apex = V3(x, 4.5, 4.6);
      final sw = math.sin(l.beats * math.pi / 4 + i * 0.9) * 2.6;
      final foot = V3(x * 0.4 + sw, -1.0 + math.cos(l.beats * math.pi / 8 + i) * 1.2, 0);
      final d = (foot - apex).unit;
      final side = d.cross(const V3(0, -1, 0)).unit * 0.22;
      final col = colors[i % colors.length];
      final a = cam.at(apex), b = cam.at(foot + side), cc = cam.at(foot - side);
      q.tri(a, b, cc, col.withValues(alpha: 0.32 * k), col.withValues(alpha: 0.02 * k), col.withValues(alpha: 0.02 * k));
    }
    q.draw(c, blend: BlendMode.plus);
  }

  /// On a drop's landing, rings across the floor.
  void _rings(Canvas c, DanceCam cam, _Look l, Color color) {
    final since = l.since;
    if (since == null || since < 0 || since >= 4) return;
    final r = since / 4;
    final q = DanceQuads();
    const seg = 40;
    final rad = 0.6 + 5 * r, wdt = 0.08 + 0.2 * r;
    for (var i = 0; i < seg; i++) {
      final t0 = i / seg * math.pi * 2, t1 = (i + 1) / seg * math.pi * 2;
      V3 at(double t, double rr) => V3(math.cos(t) * rr, math.sin(t) * rr, 0.01);
      q.quad(cam, at(t0, rad), at(t1, rad), at(t1, rad + wdt), at(t0, rad + wdt), color.withValues(alpha: 0.6 * (1 - r)));
    }
    q.draw(c, blend: BlendMode.plus);
  }

  /// The body lit for the room: the key warm from the front left, the rim the light's.
  DanceLook3 _lit(_Look l, Color light, {double dim = 1, bool lead = true}) {
    final pal = l.st.palette;
    return DanceLook3(
      keyColor: Color.lerp(const Color(0xfffff2e6), light, 0.25)!,
      keyK: 0.6 + 0.2 * l.beat,
      fill: pal.secondary.withLightness(0.55).toColor(),
      fillK: 0.25,
      ambient: 0.5,
      rim: light,
      rimK: dim < 1 || !lead ? 0 : (0.55 + 0.5 * l.kick * (l.rage ? 1 : 0.4)),
      dim: dim,
    );
  }

  void _disco(Canvas c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies) {
    final pal = l.st.palette;
    final cols = [pal.primary.withLightness(0.55).toColor(), pal.secondary.withLightness(0.55).toColor(), pal.accent.withLightness(0.6).toColor()];
    _wash(c, s, const Color(0xff050308), Color.lerp(cols[0], Colors.black, 0.86)!);
    _hero!.draw(c, cam, _lit(l, cols[2], dim: 0.4), underFloor: true);
    // The tiles: a pattern for the bar, stepped by the beat — a chase round the
    // floor, a checker swapping, a ripple out from the dancer on the kick.
    final q = DanceQuads();
    const nT = 11, tile = 0.7;
    final beatN = l.beats.floor();
    final pattern = l.rage ? (beatN ~/ 8) % 3 : (l.sleep ? 3 : (beatN ~/ 16) % 3);
    for (var i = 0; i < nT; i++) {
      for (var j = 0; j < nT; j++) {
        final x0 = (i - nT / 2) * tile, y0 = (j - nT / 2) * tile;
        final cx = i - nT ~/ 2, cy = j - nT ~/ 2;
        final r = math.sqrt((cx * cx + cy * cy).toDouble());
        double on;
        switch (pattern) {
          case 0:
            on = ((i + j + beatN) % 3 == 0) ? 1 : 0.12;
          case 1:
            on = ((i + j) % 2 == beatN % 2) ? 0.9 : 0.1;
          case 2:
            final front = (l.beats % 1) * 7;
            on = (r - front).abs() < 1.1 ? 1 : 0.1;
          default:
            on = 0.15 + 0.1 * math.sin(l.beats * 0.5 + r);
        }
        final fade = (1 - r / (nT * 0.75)).clamp(0.0, 1.0);
        final col = cols[(i * 3 + j * 5 + (beatN ~/ 4)) % 3];
        final k = (on * (0.55 + 0.45 * l.beat) * fade).clamp(0.0, 1.0);
        final cc = Color.lerp(const Color(0xff07060a), col, k)!.withValues(alpha: 0.86);
        const g = 0.03;
        q.quad(cam, V3(x0 + g, y0 + g, 0), V3(x0 + tile - g, y0 + g, 0), V3(x0 + tile - g, y0 + tile - g, 0), V3(x0 + g, y0 + tile - g, 0), cc);
      }
    }
    q.draw(c);
    for (final (b, _, _) in bodies) {
      b.floorShadow(c, cam, const V3(-0.2, -0.3, 1), const Color(0xff020203));
    }
    // The mirror ball, faceted, and its flecks thrown round the room.
    _ball(c, cam, l, cols);
    if (l.rage) _beams(c, cam, l, cols, 0.5 + 0.5 * l.kick);
    _rings(c, cam, l, cols[2]);
    for (final (b, _, _) in bodies) {
      b.draw(c, cam, _lit(l, cols[(l.beats ~/ 4) % 3], lead: identical(b, _hero)));
    }
  }

  void _ball(Canvas c, DanceCam cam, _Look l, List<Color> cols) {
    const centre = V3(0, 0.9, 3.6);
    const rad = 0.32;
    final q = DanceQuads();
    final spin = l.t * 0.6;
    const la = 8, lo = 16;
    for (var i = 0; i < la; i++) {
      for (var j = 0; j < lo; j++) {
        final t0 = math.pi * i / la - math.pi / 2, t1 = math.pi * (i + 1) / la - math.pi / 2;
        final p0 = 2 * math.pi * j / lo + spin, p1 = 2 * math.pi * (j + 1) / lo + spin;
        V3 at(double t, double p) => centre + V3(math.cos(t) * math.cos(p) * rad, math.cos(t) * math.sin(p) * rad, math.sin(t) * rad);
        // facing the camera? only the near half
        final mid = at((t0 + t1) / 2, (p0 + p1) / 2);
        if ((mid - centre).dot(cam.eye - centre) < 0) continue;
        final glint = memeHash(i, j + (l.t * 4).floor(), 3);
        final g = glint > 0.9 ? Colors.white : Color.lerp(const Color(0xff303038), const Color(0xffa0a0b0), glint)!;
        q.quad(cam, at(t0, p0), at(t0, p1), at(t1, p1), at(t1, p0), g);
      }
    }
    q.draw(c);
    // Flecks: points on a sphere round the ball, turning with it, where they fall.
    final pts = <double>[];
    final colsOut = <Color>[];
    for (var i = 0; i < 90; i++) {
      final u = memeHash(i, 1, 9) * 2 - 1, a = memeHash(i, 2, 9) * math.pi * 2 + spin;
      final rr = math.sqrt(1 - u * u);
      final dir = V3(rr * math.cos(a), rr * math.sin(a), u * 0.6 - 0.35);
      // out to the floor (z = 0) or a far wall
      final tz = dir.z < -0.05 ? -centre.z / dir.z : 9.0;
      final p = centre + dir * math.min(tz, 9.0);
      final (sx, sy, d) = cam.project(p);
      if (d < DanceCam.near) continue;
      pts..add(sx)..add(sy);
      colsOut.add(cols[i % 3]);
    }
    if (pts.isNotEmpty) {
      final k = 0.5 + 0.5 * l.beat;
      c.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(pts),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.7 * k)
            ..strokeWidth = cam.size.height * 0.007
            ..strokeCap = StrokeCap.round
            ..blendMode = BlendMode.plus);
    }
  }

  void _neon(Canvas c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, DanceRig rig, double beats) {
    final pal = l.st.palette;
    final a = pal.accent.withSaturation(1).withLightness(0.6).toColor();
    final b = pal.secondary.withSaturation(1).withLightness(0.62).toColor();
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xff040208));
    // The sun on the horizon, far behind.
    final (sx, sy, sd) = cam.project(const V3(0, 80, 9));
    if (sd > DanceCam.near) {
      final r = cam.scaleAt(sd) * 14;
      final top = pal.accent.withLightness(0.65).toColor(), bottom = pal.primary.withLightness(0.45).toColor();
      c.save();
      c.clipRect(Rect.fromLTRB(0, 0, s.width, sy + r * 0.2));
      final q = DanceQuads();
      const slices = 24;
      for (var i = 0; i < slices; i++) {
        final y0 = -1 + 2 * i / slices, y1 = -1 + 2 * (i + 1) / slices;
        final w0 = math.sqrt(math.max(0.0, 1 - y0 * y0)) * r, w1 = math.sqrt(math.max(0.0, 1 - y1 * y1)) * r;
        final c0 = Color.lerp(top, bottom, i / slices)!, c1 = Color.lerp(top, bottom, (i + 1) / slices)!;
        final a0 = Offset(sx - w0, sy + y0 * r), b0 = Offset(sx + w0, sy + y0 * r), a1 = Offset(sx - w1, sy + y1 * r), b1 = Offset(sx + w1, sy + y1 * r);
        q
          ..tri(a0, b0, b1, c0, c0, c1)
          ..tri(a0, b1, a1, c0, c1, c1);
      }
      q.draw(c);
      // its stripes
      for (var i = 0; i < 6; i++) {
        final y = sy - r * 0.1 + i * r * 0.16;
        c.drawRect(Rect.fromLTWH(sx - r, y, r * 2, r * 0.04 * (1 + i * 0.6)), Paint()..color = const Color(0xff040208));
      }
      c.restore();
    }
    // The grid, rolling toward us a line a beat.
    final q = DanceQuads();
    final roll = (l.beats % 1) * 1.0;
    final gk = 0.55 + 0.45 * l.beat;
    for (var i = -12; i <= 12; i++) {
      final x = i * 1.0;
      q.quad(cam, V3(x - 0.035, -10, 0), V3(x + 0.035, -10, 0), V3(x + 0.035, 40, 0), V3(x - 0.035, 40, 0), b.withValues(alpha: gk), null,
          b.withValues(alpha: 0), b.withValues(alpha: 0));
    }
    for (var j = -10; j < 40; j++) {
      final y = j * 1.0 - roll;
      final fade = (1 - (y + 10) / 50).clamp(0.0, 1.0);
      q.quad(cam, V3(-12, y - 0.035, 0), V3(12, y - 0.035, 0), V3(12, y + 0.035, 0), V3(-12, y + 0.035, 0), b.withValues(alpha: gk * fade));
    }
    q.draw(c, blend: BlendMode.plus);
    // On the drop: ghosts of the dancer a moment ago, fading, in the other colour.
    if (l.rage && l.heat > 0.6) {
      final pose = _pose!, tmp = _tmp!;
      for (var g = 0; g < 3; g++) {
        final ghost = _ghost(rig, g);
        _lead.pose(rig, beats - 0.18 * (g + 1), pose, tmp);
        ghost.pose(rig, pose);
        ghost.place(DanceSpot(scale: _heroScale));
        ghost.outline(c, cam, 0.012, Color.lerp(b, a, g / 3)!.withValues(alpha: 0.5 - 0.13 * g), blend: BlendMode.plus);
      }
    }
    final width = 0.014 + 0.01 * l.kick * (l.rage ? 1 : 0.3);
    for (final (body, _, _) in bodies) {
      // Glow: a wide faint line under a narrow bright one; the body black inside, its rim lit.
      body.outline(c, cam, width * 2.6, a.withValues(alpha: 0.18), blend: BlendMode.plus);
      body.outline(c, cam, width, a);
      body.draw(c, cam, DanceLook3(flat: const Color(0xff020104), textured: false, rim: a, rimK: 0.9, rimPower: 3));
    }
  }

  void _shadowStage(Canvas c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, double beats) {
    final pal = l.st.palette;
    const wallY = 2.6;
    final warm = HSLColor.fromAHSL(1, pal.accent.hue, 0.35, 0.78).toColor();
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xff050505));
    // The lamps: one low in front, swaying with the bar; three coloured ones on the drop.
    final sway = math.sin(beats * math.pi / 8) * 1.2;
    final lamps = l.rage
        ? [
            (V3(-1.6 + sway * 0.3, -3.2, 0.5), pal.primary.withSaturation(1).withLightness(0.55).toColor()),
            (V3(0, -3.4, 0.35), pal.secondary.withSaturation(1).withLightness(0.55).toColor()),
            (V3(1.6 - sway * 0.3, -3.2, 0.5), pal.accent.withSaturation(1).withLightness(0.55).toColor()),
          ]
        : [(V3(sway, -3.0, 0.45 + 0.15 * l.beat), warm)];
    // The wall, lit brightest where the lamps aim; the floor before it.
    final wallK = l.sleep ? 0.7 : 0.85 + 0.15 * l.beat;
    Color litWall(double x, double z) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (final (p, col) in lamps) {
        final dx = x - p.x, dz = z - 1.5;
        final k = math.exp(-(dx * dx + dz * dz) / 18) * wallK * (l.rage ? 0.8 : 1.0);
        r += col.r * k;
        g += col.g * k;
        b += col.b * k;
      }
      return Color.from(alpha: 1, red: r.clamp(0.0, 1.0), green: g.clamp(0.0, 1.0), blue: b.clamp(0.0, 1.0));
    }

    final q = DanceQuads();
    for (var i = 0; i < 12; i++) {
      for (var j = 0; j < 6; j++) {
        final x0 = -9 + i * 1.5, z0 = j * 1.0;
        q.quad(cam, V3(x0, wallY, z0), V3(x0 + 1.5, wallY, z0), V3(x0 + 1.5, wallY, z0 + 1), V3(x0, wallY, z0 + 1), litWall(x0, z0), litWall(x0 + 1.5, z0),
            litWall(x0 + 1.5, z0 + 1), litWall(x0, z0 + 1));
      }
    }
    for (var i = 0; i < 12; i++) {
      final x0 = -9 + i * 1.5;
      for (var j = 0; j < 4; j++) {
        final y0 = -6 + j * 2.15;
        Color fl(double x, double y) => Color.lerp(Colors.black, litWall(x, 0.2), 0.35 * ((y + 6) / 8.6).clamp(0.0, 1.0))!;
        q.quad(cam, V3(x0, y0, 0), V3(x0 + 1.5, y0, 0), V3(x0 + 1.5, y0 + 2.15, 0), V3(x0, y0 + 2.15, 0), fl(x0, y0), fl(x0 + 1.5, y0), fl(x0 + 1.5, y0 + 2.15),
            fl(x0, y0 + 2.15));
      }
    }
    q.draw(c);
    // Each lamp's shadow: where its light is stopped, the wall without that colour.
    for (final (lamp, col) in lamps) {
      final shade = lamps.length == 1
          ? const Color(0xff0a0806)
          : Color.from(alpha: 1, red: (1 - col.r) * 0.55, green: (1 - col.g) * 0.55, blue: (1 - col.b) * 0.55);
      for (final (b, _, _) in bodies) {
        b.wallShadow(c, cam, lamp, wallY, shade);
      }
    }
    for (final (b, _, _) in bodies) {
      b.draw(c, cam, DanceLook3(key: lamps.first.$1, keyColor: lamps.first.$2, keyK: 0.75, ambient: 0.3, fillK: 0.1, rim: warm, rimK: 0.5));
    }
  }

  // ------------------------------------------------------------------ the stylised stage

  /// Where the figure's middle is on the picture (0..1), for the ascii's pop.
  Offset _popAt = const Offset(0.5, 0.45);

  void _artStage(Canvas c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, DanceRig rig, double beats) {
    final pal = l.st.palette;
    final mid = cam.at(const V3(0, 0, 1.15));
    _popAt = Offset(mid.dx / s.width, mid.dy / s.height);
    switch (_art ?? DanceArt.mono) {
      case DanceArt.mono:
        // Black on white; in a drop, white on black by the bar — the cut on the downbeat.
        final inverted = l.rage && (beats / 4).floor().isOdd;
        final paper = inverted ? const Color(0xff050505) : const Color(0xfff3f2ee);
        final ink = inverted ? const Color(0xfff3f2ee) : const Color(0xff050505);
        c.drawRect(Offset.zero & s, Paint()..color = paper);
        // The kick: the figure a hair bigger for a moment.
        _hero!.place(DanceSpot(scale: _heroScale * (1 + 0.018 * l.kick)));
        for (final (b, _, _) in bodies) {
          b.draw(c, cam, DanceLook3(flat: ink, textured: false, shadeFlat: false), twoSided: true);
        }
      case DanceArt.trails:
        final deep = HSLColor.fromAHSL(1, pal.primary.hue, 0.35, 0.035).toColor();
        _wash(c, s, deep, const Color(0xff020203));
        _studioFloor(c, cam, l, bodies, pal.accent.withSaturation(0.3).withLightness(0.7).toColor());
        _ribbons(c, cam, l, rig, beats, [
          pal.accent.withSaturation(0.9).withLightness(0.65).toColor(),
          pal.secondary.withSaturation(0.9).withLightness(0.6).toColor(),
          pal.primary.withSaturation(0.8).withLightness(0.7).toColor(),
        ]);
        for (final (b, _, _) in bodies) {
          b.draw(c, cam, _porcelain(l, pal.accent.withLightness(0.7).toColor()), twoSided: true);
        }
      case DanceArt.ascii:
        // The figure lit bright on black; the finish turns it to text.
        c.drawRect(Offset.zero & s, Paint()..color = Colors.black);
        for (final (b, _, _) in bodies) {
          b.draw(c, cam, _porcelain(l, Colors.white), twoSided: true);
        }
      case DanceArt.dither:
        final top = HSLColor.fromAHSL(1, pal.primary.hue, 0.25, 0.3).toColor();
        _glow(c, s, Offset(s.width / 2, s.height * 0.42), s.height * 0.9, top, Colors.black);
        // The porcelain figure: its shading is what the dots draw.
        for (final (b, _, _) in bodies) {
          b.draw(c, cam, _porcelain(l, Colors.white), twoSided: true);
        }
      case DanceArt.chrono:
        c.drawRect(Offset.zero & s, Paint()..color = const Color(0xff060606));
        _studioFloor(c, cam, l, bodies, pal.primary.withSaturation(0.3).withLightness(0.7).toColor());
        _stamps(c, cam, l, rig, beats, pal.primary.withSaturation(0.3).withLightness(0.6).toColor());
        for (final (b, _, _) in bodies) {
          b.draw(c, cam, _porcelain(l, Colors.white), twoSided: true);
        }
    }
  }

  /// The grey figure, as porcelain under a studio's lights (a matcap: shaded by
  /// where the normal points on the screen): warm light from above left, the shadows
  /// cool with the record's colour, a highlight, a rim of [rim]. [dim] scales it all
  /// (an afterimage's share).
  DanceLook3 _porcelain(_Look l, Color rim, {double dim = 1}) => DanceLook3(
        textured: false,
        matcap: true,
        keyColor: const Color(0xffcfc8be),
        fill: HSLColor.fromAHSL(1, l.st.palette.secondary.hue, 0.28, 0.07).toColor(),
        rim: rim,
        rimK: 0.35 + 0.25 * l.beat,
        dim: dim,
      );

  /// A studio floor under the figure: a soft pool of light and the figure's shadow
  /// in it, so it stands somewhere rather than floating in the dark.
  void _studioFloor(Canvas c, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, Color light) {
    final q = DanceQuads();
    const seg = 28;
    final o = cam.at(const V3(0, 0, 0));
    final k = 0.16 + 0.05 * l.beat;
    for (var i = 0; i < seg; i++) {
      final t0 = i / seg * math.pi * 2, t1 = (i + 1) / seg * math.pi * 2;
      q.tri(o, cam.at(V3(math.cos(t0) * 2.4, math.sin(t0) * 1.6, 0)), cam.at(V3(math.cos(t1) * 2.4, math.sin(t1) * 1.6, 0)), light.withValues(alpha: k),
          light.withValues(alpha: 0), light.withValues(alpha: 0));
    }
    q.draw(c, blend: BlendMode.plus);
    for (final (b, _, _) in bodies) {
      b.floorShadow(c, cam, const V3(0.25, -0.35, 1), const Color(0xff030303));
    }
  }

  /// Light swept behind the hands, the feet and the head: where they were over the
  /// last beat or two, as ribbons thinning and fading into the past.
  void _ribbons(Canvas c, DanceCam cam, _Look l, DanceRig rig, double beats, List<Color> cols) {
    final span = switch (l.mood) {
      MemeMood.rage => 1.75,
      MemeMood.sleep => 2.0,
      MemeMood.wake => 1.25,
      MemeMood.vibe => 1.4,
    };
    const n = 30;
    final joints = [('Hand_L', 0.09, 0.07, 0), ('Hand_R', 0.09, 0.07, 0), ('Toes_L', 0.05, 0.045, 1), ('Toes_R', 0.05, 0.045, 1), ('Head', 0.16, 0.05, 2)];
    final ids = [for (final j in joints) rig.bone(j.$1)];
    final pts = [for (var j = 0; j < joints.length; j++) List<Offset>.filled(n + 1, Offset.zero)];
    final px = [for (var j = 0; j < joints.length; j++) List<double>.filled(n + 1, 0)];
    final pose = _pose!, tmp = _tmp!;
    for (var k = 0; k <= n; k++) {
      _lead.pose(rig, beats - span * k / n, pose, tmp);
      rig.solve(pose, _histW);
      for (var j = 0; j < joints.length; j++) {
        if (ids[j] < 0) continue;
        DanceRig.jointAt(_histW, ids[j], joints[j].$2, _p3);
        final (x, y, d) = cam.project(V3(_p3[0], _p3[1], _p3[2]) * _heroScale);
        pts[j][k] = Offset(x, y);
        px[j][k] = cam.scaleAt(d);
      }
    }
    final q = DanceQuads();
    final glow = 0.75 + 0.25 * l.beat;
    for (var j = 0; j < joints.length; j++) {
      if (ids[j] < 0) continue;
      final p = pts[j];
      final col = cols[joints[j].$4];
      Offset side(int k) {
        final a = p[math.max(0, k - 1)], b = p[math.min(n, k + 1)];
        final d = b - a;
        final len = d.distance;
        return len < 1e-3 ? Offset.zero : Offset(-d.dy / len, d.dx / len);
      }

      for (var k = 0; k < n; k++) {
        final t0 = k / n, t1 = (k + 1) / n;
        final kw = 1 + 0.45 * l.kick;
        final w0 = joints[j].$3 * kw * px[j][k] * math.pow(1 - t0, 0.6), w1 = joints[j].$3 * kw * px[j][k + 1] * math.pow(1 - t1, 0.6);
        final c0 = col.withValues(alpha: (glow * math.pow(1 - t0, 1.5)).clamp(0.0, 1.0));
        final c1 = col.withValues(alpha: (glow * math.pow(1 - t1, 1.5)).clamp(0.0, 1.0));
        final s0 = side(k) * w0.toDouble(), s1 = side(k + 1) * w1.toDouble();
        q.tri(p[k] + s0, p[k] - s0, p[k + 1] - s1, c0, c0, c1);
        q.tri(p[k] + s0, p[k + 1] - s1, p[k + 1] + s1, c0, c1, c1);
      }
    }
    q.draw(c, blend: BlendMode.plus);
  }

  /// The chronophotograph's stamps: the figure where it was every half beat (a
  /// quarter in a drop), translucent and added, so they glow where they overlap,
  /// fading with age; the newest comes in bright.
  void _stamps(Canvas c, DanceCam cam, _Look l, DanceRig rig, double beats, Color tint) {
    final step = l.rage ? 0.25 : 0.5;
    final count = l.rage ? 8 : 6;
    final pose = _pose!, tmp = _tmp!;
    final last = (beats / step).floor() * step;
    for (var k = count; k >= 1; k--) {
      final g = _ghost(rig, k - 1);
      _lead.pose(rig, last - (k - 1) * step - (beats - last < 0.02 ? step : 0), pose, tmp);
      g.pose(rig, pose);
      g.place(DanceSpot(scale: _heroScale));
      final age = (k - 1) / count;
      final fresh = k == 1 ? (1 - (beats - last) / (step * 0.6)).clamp(0.0, 1.0) : 0.0;
      final k0 = (0.42 * math.pow(1 - age, 1.6) + 0.25 * fresh).toDouble();
      g.draw(c, cam, _porcelain(l, Color.lerp(tint, Colors.white, 0.3)!, dim: k0), twoSided: true, blend: BlendMode.plus);
    }
  }

  /// The ascii or dither finish over the stylised stage's picture.
  ui.Image _post(ui.Image img, int w, int h, StagePrograms p, _Look l) {
    final program = p.sims['dance_fx'];
    if (program == null) return img;
    final fx = _fx ??= program.fragmentShader();
    final glyphs = _glyphs ??= _makeGlyphs();
    final pal = l.st.palette;
    final ascii = _art == DanceArt.ascii;
    final ink = ascii ? pal.accent.withSaturation(0.55).withLightness(0.78).toColor() : const Color(0xffeee7d6);
    final paper = ascii ? const Color(0xff040404) : HSLColor.fromAHSL(1, pal.primary.hue, 0.4, 0.07).toColor();
    final cell = ascii ? h / (l.rage ? 52 : 40) : math.max(2.0, h / 220);
    fx
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, ascii ? 1 : 2)
      ..setFloat(3, cell)
      ..setFloat(4, ink.r)
      ..setFloat(5, ink.g)
      ..setFloat(6, ink.b)
      ..setFloat(7, paper.r)
      ..setFloat(8, paper.g)
      ..setFloat(9, paper.b)
      ..setFloat(10, ascii ? 0.2 : 0)
      ..setFloat(11, _ramp.length.toDouble())
      ..setFloat(12, l.kick.clamp(0.0, 1.0))
      ..setFloat(13, _popAt.dx)
      ..setFloat(14, _popAt.dy)
      ..setImageSampler(0, img)
      ..setImageSampler(1, glyphs);
    final r = ui.PictureRecorder();
    Canvas(r).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx);
    final pic = r.endRecording();
    final out = pic.toImageSync(w, h);
    pic.dispose();
    img.dispose();
    return out;
  }

  /// The glyph ramp, light to dense, white on clear, side by side.
  static ui.Image _makeGlyphs() {
    const gw = 24.0, gh = 40.0;
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    for (var i = 0; i < _ramp.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: _ramp[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 34, height: 1, color: Colors.white, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(i * gw + (gw - tp.width) / 2, (gh - tp.height) / 2));
      tp.dispose();
    }
    final pic = r.endRecording();
    final img = pic.toImageSync((gw * _ramp.length).round(), gh.round());
    pic.dispose();
    return img;
  }

  /// Over it all: the drop's flash, brief.
  void _finish(Canvas c, Size s, _Look l, double dt) {
    final since = l.since;
    if (since != null && since >= 0 && since < 0.5) c.drawRect(Offset.zero & s, Paint()..color = Colors.white.withValues(alpha: 0.4 * (1 - since * 2)));
  }

  @override
  void dispose() {
    for (final b in [..._bodies.values, ..._ghosts]) {
      b.dispose();
    }
    _fx?.dispose();
    _fx = null;
    _out?.dispose();
    _out = null;
  }
}

/// The frame's facts the stages read.
class _Look {
  _Look(this.st, Map<String, double> f, this.mood, this.beats, this.since, this.heat, this.wakeK, this.kick, this.stage)
      : beat = f['dyn.beat.decay'] ?? 0,
        t = st.now.millisecondsSinceEpoch / 1000 % 10000;
  final ShowState st;
  final MemeMood mood;
  final double beats, heat, wakeK, kick, beat, t;
  final double? since;
  final DanceStage stage;
  bool get rage => mood == MemeMood.rage;
  bool get sleep => mood == MemeMood.sleep;
}
