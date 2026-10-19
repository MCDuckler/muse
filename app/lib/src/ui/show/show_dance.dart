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
// move starts at the beat of it whose pose — and whose motion — is nearest what the
// dancer is doing, and plays whole from there while what is left of the old pose
// fades out of it over a beat or two (DanceCarry: the body keeps its momentum, the
// new move keeps its steps), longer the further apart the two were.
//
// The company dances routines, a slot at a time (DanceRoutine): all in unison, a
// wave rippling out from the lead, a canon a beat or two behind, split between two
// moves, or call and answer — each half holding a pose while the other dances. Small
// sets change formation now and then, gliding to their new places on the beat. And
// couples: the bank's duets are two people captured dancing together (a salsa
// couple, a chicken dance side by side); the lead dances one half and a partner the
// other, where they stood, or three couples at once.
// Every choice is hashed from the record and the slot, so a record dances the same
// way twice.
//
// The dancers: two photogrammetry scans, Chris and Joe — picked in the show panel
// (ShowMacros.dancer), or "mix": each record one of them leading, the other in the
// company. Both dance the same moves, retargeted onto each ahead
// (tools/show-dance), drawn at a person's height.
//
// The stages (the scene's sim kind):
//
//   dance.disco    a lit floor of tiles chasing the beat, a mirror ball and its flecks.
//   dance.neon     a void with a scrolling grid and a low sun; the dancer black inside
//                  a neon line, echoed by ghosts of a moment ago on the drop.
//   dance.shadow   a lamp low in front, the dancer's shadow huge on a plain backdrop;
//                  three coloured lamps and three shadows on the drop.
//   dance.art      renderings: a silhouette, light trails, text, dither, a
//                  chronophotograph (DanceArt).
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/show/show_pool.dart' show MovePool, QualityPool, StylePool;
import '../../state/show/show_state.dart';
import '../../state/show/show_tune.dart';
import 'show_canvas.dart' show StagePrograms;
import 'show_common.dart' show setFxKnobs, tunedCell;
import 'show_dance_draw.dart';
import 'show_dance_rig.dart';
import 'show_dance_surface.dart';
import 'show_meme.dart' show MemeClock;
import 'show_meme_bank.dart' show MemeMood, memeHash;
import 'show_sims.dart';

export 'show_dance_rig.dart' show DanceMove, DanceTier, DanceStyle;

/// Who dances: the dancer alone, or with others. Grid, ring and army are big — a
/// grid of dancers evenly spaced, a ring round the lead, an army in rows behind — and
/// only where the bodies are drawn on the GPU (the native stage). A couple is the
/// lead and a partner dancing a duet's two halves; couples three of them.
enum DanceTroupe { solo, duo, trio, line, crowd, grid, ring, army, couple, couples }

/// What the company does with the lead's dancing in a slot:
///
///   unison   the same steps at the same time;
///   wave     the same steps rippling out from the lead, a quarter beat a place
///            (an eighth in a big set);
///   canon    the same steps a beat behind, the next ones two — a round;
///   split    half the company dancing a move of its own;
///   answer   call and answer: two halves taking four beats each, the one holding
///            the pose it was in while the other dances (the lead dances through).
enum DanceRoutine { unison, wave, canon, split, answer }

/// Where the camera is: in front of the dancer, a few ways framed, and still.
///
/// The stylised stage adds three extreme wide angles (a ~110° lens, half a metre to
/// three quarters away, still a fixed camera): from the floor looking up the body, from just above
/// looking down on it, and face on, close enough that the hands and the head loom.
///
/// And two fisheyes: drawn through a 120° straight lens and bent into a fisheye after
/// (dance_fx.frag's mode 7) — face on, close, and from the floor.
enum DanceShot { full, front, medium, close, wide, extremeLow, extremeHigh, extremeFront, fisheye, fisheyeLow }

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
///            in a drop), the older stamps darker behind the newest;
///   contour  a topographic map of the figures' light, lines of equal brightness;
///   halftone two inks screened at two angles, a riso print on dark paper;
///   thermal  a heat camera's false colour;
///   lines    a ridgeline plot: lines across the picture lifted by the light;
///   fluid    the figures in chrome in a coloured fluid, pushing it away as they
///            move (the native stage only);
///   viewports a model editor's grid of viewports, a dancer front on in each, every
///            model dancing the same moves, the selection stepping on the beat (the
///            native stage only);
///   plain    the models as they are: textured, in a plain light, on white — no
///            stage, no floor, no rendering style at all.
/// The figures are chrome throughout (the "clay" ones were porcelain).
enum DanceArt { mono, trails, ascii, dither, chrono, contour, halftone, thermal, lines, fluid, viewports, plain }

/// The renderings finished by dance_fx.frag, and its mode for each.
const danceFxMode = {DanceArt.ascii: 1, DanceArt.dither: 2, DanceArt.contour: 3, DanceArt.halftone: 4, DanceArt.thermal: 5, DanceArt.lines: 6};

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
  /// A duet's halves are danced only as a couple: [duo] the leads' halves alone.
  static List<(DanceMove, double)> pool(List<DanceMove> moves, DanceTier tier, Map<DanceStyle, double> flavour, double bpm,
      {List<String> recent = const [], bool techno = false, bool duo = false}) {
    final out = <(DanceMove, double)>[];
    for (final m in moves) {
      if (duo ? (m.duo == null || m.part != 0) : m.duo != null) continue;
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
  static DanceTroupe troupe(MemeMood mood, int salt, int slot, {double heat = 1, bool big = false}) {
    final d = memeHash(salt % 9973, slot, 23);
    DanceTroupe by(List<(double, DanceTroupe)> odds) => odds.firstWhere((o) => d < o.$1, orElse: () => odds.last).$2;
    // With the bodies on the GPU, the big sets join in: a ring in the calm, rows
    // building, a grid or an army in the drop.
    if (big) {
      return switch (mood) {
        MemeMood.sleep => by([(0.55, DanceTroupe.solo), (0.8, DanceTroupe.duo), (1, DanceTroupe.ring)]),
        MemeMood.wake => by([(0.3, DanceTroupe.solo), (0.5, DanceTroupe.duo), (0.7, DanceTroupe.trio), (0.85, DanceTroupe.army), (1, DanceTroupe.ring)]),
        MemeMood.rage => heat < 0.7
            ? by([(0.25, DanceTroupe.trio), (0.45, DanceTroupe.line), (0.75, DanceTroupe.army), (1, DanceTroupe.grid)])
            : by([(0.35, DanceTroupe.grid), (0.6, DanceTroupe.army), (0.75, DanceTroupe.crowd), (0.9, DanceTroupe.ring), (1, DanceTroupe.line)]),
        MemeMood.vibe => by([(0.2, DanceTroupe.solo), (0.35, DanceTroupe.duo), (0.5, DanceTroupe.trio), (0.65, DanceTroupe.ring), (0.82, DanceTroupe.army), (1, DanceTroupe.grid)]),
      };
    }
    return switch (mood) {
      MemeMood.sleep => by([(0.75, DanceTroupe.solo), (1, DanceTroupe.duo)]),
      MemeMood.wake => by([(0.45, DanceTroupe.solo), (0.75, DanceTroupe.duo), (1, DanceTroupe.trio)]),
      MemeMood.rage => heat < 0.7
          ? by([(0.2, DanceTroupe.solo), (0.5, DanceTroupe.duo), (0.8, DanceTroupe.trio), (1, DanceTroupe.line)])
          : by([(0.1, DanceTroupe.solo), (0.3, DanceTroupe.trio), (0.6, DanceTroupe.line), (1, DanceTroupe.crowd)]),
      MemeMood.vibe => by([(0.3, DanceTroupe.solo), (0.6, DanceTroupe.duo), (0.85, DanceTroupe.trio), (1, DanceTroupe.line)]),
    };
  }

  /// The company as couples, now and then, where the bank has duets: a partner for
  /// the lead instead of a second dancer, three couples instead of a set — likelier
  /// on a record that leans latin, never asleep.
  static DanceTroupe paired(DanceTroupe t, MemeMood mood, Map<DanceStyle, double> flavour, int salt, int slot) {
    if (mood == MemeMood.sleep) return t;
    final total = flavour.values.fold<double>(0, (a, b) => a + b);
    final latin = total > 0 ? (flavour[DanceStyle.latin] ?? 0) / total : 0.0;
    final d = memeHash(salt % 9973, slot, 59);
    return switch (t) {
      DanceTroupe.duo => d < 0.2 + latin ? DanceTroupe.couple : t,
      DanceTroupe.trio || DanceTroupe.line || DanceTroupe.crowd => d < 0.08 + 0.5 * latin ? DanceTroupe.couples : t,
      DanceTroupe.army || DanceTroupe.grid => d < 0.06 + 0.25 * latin ? DanceTroupe.couples : t,
      _ => t,
    };
  }

  static bool isPaired(DanceTroupe t) => t == DanceTroupe.couple || t == DanceTroupe.couples;

  /// The company's routine for slot [slot].
  static DanceRoutine routine(DanceTroupe t, int salt, int slot) {
    final d = memeHash(salt % 9973, slot, 67);
    final pick = switch (t) {
      DanceTroupe.solo || DanceTroupe.couple => const [DanceRoutine.unison],
      DanceTroupe.duo => const [DanceRoutine.unison, DanceRoutine.unison, DanceRoutine.canon, DanceRoutine.split],
      DanceTroupe.couples => const [DanceRoutine.unison, DanceRoutine.canon, DanceRoutine.answer, DanceRoutine.unison],
      DanceTroupe.trio => const [DanceRoutine.unison, DanceRoutine.canon, DanceRoutine.split, DanceRoutine.answer],
      DanceTroupe.line => const [DanceRoutine.wave, DanceRoutine.unison, DanceRoutine.canon, DanceRoutine.split, DanceRoutine.answer],
      DanceTroupe.crowd => const [DanceRoutine.split, DanceRoutine.wave, DanceRoutine.unison, DanceRoutine.answer],
      DanceTroupe.grid || DanceTroupe.army || DanceTroupe.ring => const [
          DanceRoutine.unison,
          DanceRoutine.wave,
          DanceRoutine.split,
          DanceRoutine.answer,
          DanceRoutine.unison
        ],
    };
    return pick[(d * pick.length).floor() % pick.length];
  }

  /// Which of a small set's formations slot [slot] stands in (0 the one it walked in
  /// as): it changes every so often, not every slot.
  static int formation(DanceTroupe t, int salt, int slot) {
    final count = switch (t) {
      DanceTroupe.duo => 3,
      DanceTroupe.trio || DanceTroupe.line || DanceTroupe.couples => 4,
      _ => 1,
    };
    if (count == 1) return 0;
    final d = memeHash(salt % 9973, slot ~/ 2, 71);
    return d < 0.45 ? 0 : 1 + ((d - 0.45) / 0.55 * (count - 1)).floor().clamp(0, count - 2);
  }

  /// The camera for cut [cut] in [mood]: always from the front, framed wider or
  /// closer; the whole troupe when there is one.
  static DanceShot shot(MemeMood mood, int salt, int cut, DanceTroupe troupe, {bool art = false}) {
    final d = memeHash(salt % 9973, cut, 41);
    // The stylised stage's extreme wide angles: most in a drop, never asleep.
    if (art) {
      final e = memeHash(salt % 9973, cut, 43);
      final odds = switch (mood) {
        MemeMood.rage => 0.55,
        MemeMood.wake => 0.4,
        MemeMood.vibe => 0.35,
        MemeMood.sleep => 0.0,
      };
      if (e < odds) {
        const extremes = [
          DanceShot.extremeLow,
          DanceShot.fisheye,
          DanceShot.extremeFront,
          DanceShot.fisheyeLow,
          DanceShot.extremeHigh,
          DanceShot.fisheye,
        ];
        return extremes[(d * extremes.length).floor() % extremes.length];
      }
    }
    if (troupe == DanceTroupe.line || troupe == DanceTroupe.crowd || troupe == DanceTroupe.couples) return d < 0.75 ? DanceShot.wide : DanceShot.full;
    if (isBig(troupe)) return d < 0.6 ? DanceShot.front : DanceShot.full;
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
  static DanceArt art(MemeMood mood, int salt, int n, {DanceArt? not, bool gpu = false}) {
    final pool = [
      for (final a in switch (mood) {
        MemeMood.sleep => [DanceArt.mono, DanceArt.ascii, DanceArt.dither, DanceArt.contour, DanceArt.lines, DanceArt.fluid, DanceArt.plain],
        MemeMood.wake => [DanceArt.ascii, DanceArt.dither, DanceArt.trails, DanceArt.mono, DanceArt.halftone, DanceArt.thermal, DanceArt.lines, DanceArt.viewports, DanceArt.plain],
        MemeMood.rage => [DanceArt.trails, DanceArt.chrono, DanceArt.mono, DanceArt.thermal, DanceArt.halftone, DanceArt.fluid, DanceArt.viewports, DanceArt.plain],
        MemeMood.vibe => DanceArt.values,
      })
        // The image treatments (ascii, dither, halftone, thermal, lines, contour) are
        // the conductor's (the frame's rig's treatment, state/show/show_engine.dart),
        // as for every scene: this clock picks the stage's own. The styles the pool
        // switched off are out; the GPU-only ones where there is no GPU.
        if (!treatmentFxMode.containsKey(a.name) && !StylePool.off.contains(a.name) && (gpu || (a != DanceArt.fluid && a != DanceArt.viewports))) a,
    ];
    if (pool.isEmpty) return not ?? DanceArt.plain;
    final d = memeHash(salt % 9973, n, 97);
    var a = pool[(d * pool.length).floor() % pool.length];
    if (a == not && pool.length > 1) a = pool[(pool.indexOf(a) + 1) % pool.length];
    return a;
  }

  static bool isBig(DanceTroupe t) => t == DanceTroupe.grid || t == DanceTroupe.ring || t == DanceTroupe.army;

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
  const DanceFrame(this.yaw, this.height, this.dist, this.aim, this.fov, [this.roll = 0, this.ahead = 0]);
  final double yaw, height, dist, aim, fov, roll;

  /// How far behind the lead (away from the camera) the camera looks: the middle of a
  /// big set.
  final double ahead;

  static DanceFrame of(DanceShot s, DanceTroupe t) {
    // The extreme wide angles: close to the lead whatever the company — in a big set
    // the rows behind rush away into the distance.
    switch (s) {
      // Close enough that the body fills the picture and breaks out of it: the lens's
      // width is in the perspective, not in empty room round a small figure.
      case DanceShot.extremeLow:
        return const DanceFrame(0.16, 0.12, 0.72, 1.35, 1.95, 0.07);
      case DanceShot.extremeHigh:
        return const DanceFrame(-0.14, 1.95, 0.62, 1.2, 1.92, -0.05);
      case DanceShot.extremeFront:
        return const DanceFrame(0.0, 1.3, 0.58, 1.15, 1.95);
      // The fisheyes: the straight lens a full 120° (the bend needs it), close in.
      case DanceShot.fisheye:
        return const DanceFrame(0.06, 1.25, 0.72, 1.05, fisheyeFov, 0.1);
      case DanceShot.fisheyeLow:
        return const DanceFrame(0.14, 0.18, 0.66, 1.25, fisheyeFov, 0.06);
      default:
        break;
    }
    // The big sets from the front and above, so every row shows: still a front view.
    if (DanceClock.isBig(t)) {
      // Looking down onto the middle of the set, so the rows behind stand clear of the
      // ones in front.
      final ahead = switch (t) {
        DanceTroupe.grid => 3.2,
        DanceTroupe.army => 2.6,
        _ => 0.6,
      };
      return switch (s) {
        DanceShot.full => DanceFrame(0.2, 7.0, 10.5, 0.3, 0.6, 0, ahead),
        _ => DanceFrame(0.0, 6.2, 10.0, 0.4, 0.6, 0, ahead),
      };
    }
    final wide = t == DanceTroupe.solo ? 1.0 : (t == DanceTroupe.duo || t == DanceTroupe.trio || t == DanceTroupe.couple ? 1.3 : 1.6);
    return switch (s) {
      DanceShot.full => DanceFrame(0.3, 1.3, 4.4 * wide, 0.95, 0.62),
      DanceShot.front => DanceFrame(0.0, 1.2, 4.1 * wide, 0.95, 0.62),
      DanceShot.medium => const DanceFrame(0.15, 1.3, 3.3, 1.02, 0.6),
      DanceShot.close => const DanceFrame(0.1, 1.45, 2.5, 1.2, 0.6),
      DanceShot.wide || _ => DanceFrame(0.1, 1.6, 4.6 * wide, 0.85, 0.62),
    };
  }

  /// The straight lens a fisheye shot is drawn through, and the fisheye's angle at
  /// the picture's top edge.
  static const fisheyeFov = 2.094; // 120°: past its 60° the fisheye's circle is black
  static const fisheyeEdge = 1.25; // 72° at the top edge: the lens's circle shows, the middle looms

  static bool isFisheye(DanceShot s) => s == DanceShot.fisheye || s == DanceShot.fisheyeLow;

  static DanceFrame lerp(DanceFrame a, DanceFrame b, double t) {
    double l(double x, double y) => x + (y - x) * t;
    return DanceFrame(l(a.yaw, b.yaw), l(a.height, b.height), l(a.dist, b.dist), l(a.aim, b.aim), l(a.fov, b.fov), l(a.roll, b.roll), l(a.ahead, b.ahead));
  }

  DanceFrame turned(double by, {double closer = 1, double roll = 0}) => DanceFrame(yaw + by, height, dist * closer, aim, fov, this.roll + roll, ahead);

  DanceCam cam(Size size, {double shake = 0}) {
    final eye = V3(math.sin(yaw) * dist, ahead - math.cos(yaw) * dist, height);
    return DanceCam(eye: eye, target: V3(0, ahead, aim + shake * 0.01), size: size, fov: fov, roll: roll);
  }
}

/// The dancers to pick from, by id (`assets/show/dance/<id>/`) and name.
class DanceModels {
  const DanceModels._();
  static const all = [
    ('chris', 'Chris (scan)'),
    ('joe', 'Joe (scan)'),
  ];

  /// Each record its own lead, the troupe of the others.
  static const mix = 'mix';

  /// Who may dance in a mix: all but those switched [off] (all of them off is none).
  static List<String> pool(Iterable<String> off) {
    final on = [for (final m in all) if (!off.contains(m.$1)) m.$1];
    return on.isEmpty ? [for (final m in all) m.$1] : on;
  }

  /// The lead for record [salt] when the panel says [choice], [off] switched off.
  static String lead(String? choice, int salt, [Iterable<String> off = const []]) {
    if (choice != null && choice != mix && all.any((m) => m.$1 == choice)) return choice;
    final p = pool(off);
    return p[(memeHash(salt % 9973, 17, 29) * p.length).floor() % p.length];
  }

  /// Member [i]'s model: the lead's, or in a mix one of the others on.
  static String member(String? choice, int salt, int i, [Iterable<String> off = const []]) {
    if (choice != null && choice != mix) return lead(choice, salt, off);
    final first = lead(choice, salt, off);
    final others = [for (final m in pool(off)) if (m != first) m];
    if (others.isEmpty) return first;
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

/// One line of dancing: a move playing from an anchor, the one before it (danced on
/// by anyone a beat or so behind, until their turn comes), and what is left of the
/// pose it was in when it changed (DanceCarry) — for the lead's half and, in a duet,
/// the partner's.
class _Track {
  DanceMove? move, prev;
  double at = 0, phase = 0, rate = 1;
  double pAt = 0, pPhase = 0, pRate = 1;
  double blendLen = 0;
  final carry = <DanceCarry?>[null, null];

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
    blendLen = prev == null ? 0 : blend;
  }

  /// The same move on at a new rate, without a jump.
  void retime(double beats, double rate) {
    if (move == null || rate == this.rate) return;
    phase = beatOf(beats);
    at = beats;
    this.rate = rate;
  }

  /// The pose at track beat [beats] into [out]: the lead's half, or with [partner] the
  /// partner's half of a duet (the move itself when it is not one).
  bool pose(DanceRig rig, double beats, DancePose out, {bool partner = false}) {
    final m0 = move;
    if (m0 == null) return false;
    final p0 = prev;
    if (p0 != null && blendLen > 0 && beats < at) {
      // Someone behind the lead, not there yet: still in the move before.
      final pm = rig.move(p0.id) ?? p0;
      rig.sample(partner ? rig.partnerOf(pm) : pm, pPhase + (beats - pAt) * pRate, out);
      return true;
    }
    // Another model dances the same move from its own table.
    final m = rig.move(m0.id) ?? m0;
    rig.sample(partner ? rig.partnerOf(m) : m, beatOf(beats), out);
    if (blendLen > 0) carry[partner ? 1 : 0]?.apply(out, beats - at);
    return true;
  }
}

/// What a member dances: the lead's line or the company's own ([own]), [delay] beats
/// behind, the partner's half of a duet; and in call and answer ([group] ≥ 0) the
/// four-beat turns it holds still in, counted from beat [at].
typedef _Line = ({bool own, double delay, bool partner, int group, double at});

/// A dancer in the company: what it dances (and what it danced, eased out of for a
/// beat from [lineAt]), where it stands (and where it stood, glided from over two
/// beats from [spotAt]), its place counted out from the lead ([rank]) and its half of
/// the company ([group]), and how far in it has come.
class _Member {
  _Member(this.spot, {double delay = 0, bool own = false, bool partner = false, this.rank = 1, this.group = 0, this.from = Offset.zero})
      : line = (own: own, delay: delay, partner: partner, group: -1, at: 0);
  DanceSpot spot;
  DanceSpot? spotWas;
  double spotAt = -99;
  DanceBody? body;
  String? model;
  _Line line;
  _Line? was;
  double lineAt = -99;
  final int rank, group;

  /// Where it comes in from (an offset on the floor) and how far in it is, 0..1.
  Offset from;
  double inK = 0;
  bool leaving = false;

  void dance(_Line l, double beats) {
    if (l == line) return;
    was = line;
    lineAt = beats;
    line = l;
  }

  /// Off to [s] (keeping which way round it dances: a mirror flipped mid-move jumps).
  void moveTo(DanceSpot s, double beats) {
    final o = spot;
    if (o.x == s.x && o.y == s.y) return;
    spotWas = spotNow(beats);
    spotAt = beats;
    spot = DanceSpot(x: s.x, y: s.y, yaw: s.yaw, mirror: o.mirror, scale: o.scale);
  }

  /// Where it stands at [beats] (gliding to a new place for two beats).
  DanceSpot spotNow(double beats) {
    final w = spotWas;
    if (w == null) return spot;
    final k = ((beats - spotAt) / 2).clamp(0.0, 1.0);
    if (k >= 1) return spot;
    final e = k * k * (3 - 2 * k);
    // The mirror flips at the halfway mark, mid-stride.
    return DanceSpot(x: w.x + (spot.x - w.x) * e, y: w.y + (spot.y - w.y) * e, yaw: w.yaw + (spot.yaw - w.yaw) * e, mirror: spot.mirror, scale: spot.scale);
  }
}

class DanceSim implements SimLayer {
  DanceSim(this.kind, {this.gpu = false})
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
      final t = Platform.environment['WETOWL_DANCE_TROUPE'];
      if (t != null) _forcedTroupe = DanceTroupe.values.where((x) => x.name == t).firstOrNull;
      final sh = Platform.environment['WETOWL_DANCE_SHOT'];
      if (sh != null) _forcedShot = DanceShot.values.where((x) => x.name == sh).firstOrNull;
    } catch (_) {}
  }
  DanceArt? _forcedArt;

  /// A troupe forced from outside, for a look at one: WETOWL_DANCE_TROUPE=grid.
  DanceTroupe? _forcedTroupe;

  /// A framing forced from outside: WETOWL_DANCE_SHOT=extremeLow.
  DanceShot? _forcedShot;

  /// A dancer forced from outside: WETOWL_DANCE_MODEL=joe (or mix).
  String? _forcedModel;
  @override
  final String kind;
  final DanceStage stage;

  /// Drawn by the native stage: its bodies skinned there (DanceBody.gpu), the frame a
  /// list of commands ([record]) rather than a picture.
  final bool gpu;

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

  /// The rendering the frame asked for last (RigFigure.style), to see it let go.
  String? _styledWas;
  static const _ramp = ' .:-=+*#%@';
  final _histW = Float64List(DanceRigLimits.bones * 12);
  final _p3 = Float64List(3);
  int _sectionSlot = -1;

  /// What was danced in each slot of each kind of section, by `section|slot in it`:
  /// the lead's move and its entry, the company, and the slot the routine was dealt
  /// for. A chorus or a drop that comes round again is danced the same way — a
  /// record's choreography, not a fresh shuffle each time. Forgotten with the record.
  final _book = <String, ({String move, int entry, DanceTroupe troupe, int slot})>{};
  int? _bookSalt;
  int _frames = 0;
  int _auditionWaits = 0;
  (DanceTier, Map<DanceStyle, double>, bool, bool)? _altDue;
  int _altDueFrame = 0;
  DanceTroupe? _troupeDrawn;
  Size? _sizeWas;
  DanceArt? _artWas;

  DanceBody? _hero;
  String? _heroModel;
  final _bodies = <String, DanceBody>{};
  double _heroScale = 1;
  DancePose? _pose, _was, _held;
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
      _ghosts.add(DanceBody(lod, _ready(_heroModel ?? 'chris').skin!, gpu: gpu));
    }
    return _ghosts[i];
  }

  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) => _run(st, dt, w, h, p, null);

  /// The frame as the native stage's commands ([gpu] sims only): [w]×[h] the picture
  /// the commands' 2D is in. Null while the assets are not in yet.
  Float32List? record(ShowState st, double dt, int w, int h, NativeDanceSurface surface) {
    _run(st, dt, w, h, null, surface);
    return _recorded ? surface.finish() : null;
  }

  bool _recorded = false;

  /// The frame wants drawing finer than the picture (a fisheye's middle is magnified).
  bool get wantsDetail => DanceFrame.isFisheye(_shot);

  ui.Image? _run(ShowState st, double dt, int w, int h, StagePrograms? p, NativeDanceSurface? native) {
    _recorded = false;
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
    final leadA = _ready(DanceModels.lead(choice, salt, st.macros.dancersOff));
    if (_hero == null || _heroModel != leadA.name) {
      _hero = _bodies.putIfAbsent('${leadA.name}/lead', () => DanceBody(leadA.rig!.meshes.first, leadA.skin!, gpu: gpu));
      _heroModel = leadA.name;
    }
    final leadRig = leadA.rig!;
    _heroScale = _scaleOf(leadRig);
    _pose ??= DancePose(rig.bones);

    // ---- the choreography: a slot every two bars; a drop or a new section a slot of its own.
    final n = (beats / DanceClock.slotBeats).floor();
    final dropNow = since != null && since >= 0 && since < 0.5 && _lead.move?.tier != DanceTier.high;
    final sectionNow = sectionTurned && _sectionSlot != n;
    final sleep = mood == MemeMood.sleep;
    // The stage's own rendering a section at a time — and at once when one from the
    // frame (the hands', the conductor's treatment) is let go, so it does not linger.
    final styled = st.rig.figure.style;
    final letGo = styled == null && _styledWas != null;
    _styledWas = styled;
    if (stage == DanceStage.art && (_art == null || dropNow || sectionNow || letGo)) {
      _art = _forcedArt ?? DanceClock.art(mood, salt, _artN++, not: letGo ? null : _art, gpu: gpu);
    }
    // The hands' own rendering, from the frame (the show's rig): on at once.
    if (stage == DanceStage.art && styled != null) {
      final want = DanceArt.values.where((a) => a.name == styled).firstOrNull;
      if (want != null && (gpu || (want != DanceArt.fluid && want != DanceArt.viewports))) _art = want;
    }
    if (_lead.move == null || n != _slot || dropNow || sectionNow) {
      if (sectionNow) _sectionSlot = n;
      final keep = _lead.move != null && !dropNow && !sectionNow && sleep && _lead.rate < 1 && n.isOdd;
      final tier = DanceClock.tier(mood, wakeK: wakeK, energy: m.energy, dice: memeHash(salt % 9973, n, 3));
      final techno = DanceClock.techno(bpm, m.vocal);
      final flavour = DanceClock.flavour(salt, bpm, mood, hook: m.hook && m.vocal > 0.3, techno: techno);
      final big = gpu && stage == DanceStage.art && QualityPool.bigTroupes;
      var troupe = dropNow ? DanceClock.troupe(MemeMood.rage, salt, n + 1, big: big) : DanceClock.troupe(mood, salt, n, heat: heat, big: big);
      // The stylised stage on a canvas dances alone, but for a line of silhouettes in
      // a drop; on the GPU it takes any company (the chronophotograph alone).
      if (stage == DanceStage.art) {
        troupe = switch (_art) {
          DanceArt.chrono || DanceArt.viewports => DanceTroupe.solo,
          DanceArt.mono => troupe,
          _ when big => troupe,
          _ => troupe == DanceTroupe.crowd || troupe == DanceTroupe.line ? DanceTroupe.trio : troupe,
        };
      }
      if (!keep) troupe = DanceClock.paired(troupe, mood, flavour, salt, n);
      // A section come round again: as it was danced before (its first eight slots).
      if (_bookSalt != salt) {
        _book.clear();
        _bookSalt = salt;
      }
      final inSection = n - _sectionSlot;
      final bookKey = playing && m.section != null && _sectionSlot >= 0 && inSection < 8 ? '${m.section}|$inSection' : null;
      final again = bookKey == null ? null : _book[bookKey];
      final againMove = again == null ? null : rig.move(again.move);
      if (againMove != null) troupe = again!.troupe;
      if (_forcedTroupe != null) troupe = _forcedTroupe!;
      if (keep && DanceClock.isPaired(_troupe)) troupe = _troupe;
      if (!keep) {
        final blend = dropNow ? 0.0 : (sleep ? 2.0 : 1.0);
        if (againMove != null) {
          _replay(rig, _lead, againMove, again!.entry, bpm, beats, sleep: sleep, blend: blend);
        } else {
          _step(rig, _lead, tier, flavour, bpm, beats, salt, n,
              sleep: sleep, blend: blend, techno: techno, duo: DanceClock.isPaired(troupe) && rig.hasDuets);
        }
        // The others' own line on the next frame: the slot's work split in two.
        _altDue = (tier, flavour, techno, dropNow);
      }
      // No duet to dance (none in the bank, none this slot): a partner becomes a second dancer.
      if (DanceClock.isPaired(troupe) && _lead.move?.duo == null) troupe = troupe == DanceTroupe.couple ? DanceTroupe.duo : DanceTroupe.line;
      final dealt = againMove != null ? again!.slot : n;
      if (bookKey != null && again == null && !keep && _lead.move != null) {
        _book[bookKey] = (move: _lead.move!.id, entry: _lead.phase.round(), troupe: troupe, slot: n);
      }
      _setTroupe(troupe, salt, dealt, instant: dropNow);
      _routine(troupe, salt, dealt, n, beats);
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
      _shot = _forcedShot ?? DanceClock.shot(mood, salt, cutN, _troupe, art: true);
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
    final pose = _pose!;
    final bob = sleep ? 0.0 : 0.022 * kick;
    final bodies = <(DanceBody, DanceSpot, double)>[]; // body, spot, depth
    _lead.pose(leadRig, beats, pose);
    pose.hips[2] -= bob / _heroScale;
    _hero!.pose(leadRig, pose);
    final heroSpot = DanceSpot(scale: _heroScale);
    _hero!.place(heroSpot);
    bodies.add((_hero!, heroSpot, cam.project(const V3(0, 0, 1)).$3));
    // Poses worked out this frame, by model and line: the lead's first.
    final shared = <String, DanceBody>{'$_heroModel|${(own: false, delay: 0.0, partner: false, group: -1, at: 0.0)}': _hero!};
    for (var i = 0; i < _members.length; i++) {
      final mb = _members[i];
      mb.inK = (mb.inK + (mb.leaving ? -1 : 1) * dt * bpm / 60 / 1.0).clamp(0.0, 1.0);
      if (mb.inK <= 0 && mb.leaving) continue;
      final ma = _ready(DanceModels.member(choice, salt, i, st.macros.dancersOff));
      final mr = ma.rig!;
      if (mb.body == null || mb.model != ma.name) {
        // Bodies kept by model and place in the troupe, so a new troupe reuses them.
        mb.body = _bodies.putIfAbsent('${ma.name}/$i', () => DanceBody(mr.meshes.length > 1 ? mr.meshes[1] : mr.meshes.first, ma.skin!, gpu: gpu));
        mb.model = ma.name;
      }
      final body = mb.body!;
      final sc = _scaleOf(mr);
      final e = mb.inK * mb.inK * (3 - 2 * mb.inK);
      final s = mb.spotNow(beats);
      final gliding = beats - mb.spotAt < 2;
      final spot = DanceSpot(x: s.x + mb.from.dx * (1 - e), y: s.y + mb.from.dy * (1 - e), yaw: s.yaw, mirror: s.mirror, scale: s.scale * sc);
      // The others at thirty frames a second, by turns: every other frame each draws
      // what it drew the frame before (the camera is still between cuts). Not while
      // walking in, off or to a new place, nor on a cut.
      body.hold = still && mb.inK >= 1 && !mb.leaving && !gliding && (_frames + i).isOdd;
      if (!body.hold) {
        final easing = mb.was != null && beats - mb.lineAt < 1;
        // On the GPU, a model dancing the same line as one already posed this frame
        // takes its pose (a grid of thirty-four is a handful of poses).
        final key = easing ? null : '${ma.name}|${mb.line}';
        final twin = gpu && key != null ? shared[key] : null;
        if (twin != null) {
          body.copyPose(twin);
        } else {
          _linePose(mr, mb.line, beats, pose);
          if (easing) {
            // Out of what it danced before, over a beat.
            final was = _was ??= DancePose(rig.bones);
            _linePose(mr, mb.was!, beats, was);
            final k = beats - mb.lineAt;
            was.blendToward(pose, k * k * (3 - 2 * k));
            pose.copyFrom(was);
          }
          pose.hips[2] -= bob / sc;
          body.pose(mr, pose);
          if (key != null) shared[key] = body;
        }
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
    // The dancers' bones, for the scene that takes over from them (the flock seeds
    // its birds along them and starts from this camera).
    DanceHandoff.note(bodies, leadRig, cam);

    // ---- the picture
    final look = _Look(st, f, mood, beats, since, heat, wakeK, kick, stage);
    final postNow = stage == DanceStage.art && danceFxMode.containsKey(_art);
    if (native != null) {
      native.camera(cam);
      _paint(native, size, cam, look, bodies, leadRig, beats, dt);
      if (postNow) {
        final q = _postParams(look, h);
        native.post(
            mode: q.mode, cell: q.cell, ink: q.ink, paper: q.paper, tint: q.tint, glyphs: _ramp.length, pop: look.kick.clamp(0.0, 1.0), popAt: _popAt, time: _t);
      }
      if (DanceFrame.isFisheye(_shot)) {
        native.post(
            mode: 7,
            cell: DanceFrame.fisheyeEdge,
            ink: Colors.white,
            paper: Colors.black,
            tint: math.tan(DanceFrame.fisheyeFov / 2),
            glyphs: _ramp.length,
            pop: look.kick.clamp(0.0, 1.0),
            popAt: const Offset(0.5, 0.5),
            time: _t);
      }
      _recorded = true;
      return null;
    }
    final rec = ui.PictureRecorder();
    _paint(CanvasDanceSurface(Canvas(rec)), size, cam, look, bodies, leadRig, beats, dt);
    final pic = rec.endRecording();
    var img = pic.toImageSync(w, h);
    pic.dispose();
    if (postNow && p != null) img = _post(img, w, h, p, look);
    if (DanceFrame.isFisheye(_shot) && p != null) img = _post(img, w, h, p, look, lens: true);
    _out?.dispose();
    _out = img;
    return img;
  }

  /// The stage and the bodies on it, onto [c].
  void _paint(DanceSurface c, Size size, DanceCam cam, _Look look, List<(DanceBody, DanceSpot, double)> bodies, DanceRig leadRig, double beats, double dt) {
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
  }

  /// A member's pose for line [l] at [beats], into [out]. In call and answer a turn
  /// held still is the pose the turn began in; out of one, the dancer eases back
  /// into the steps over three quarters of a beat.
  void _linePose(DanceRig mr, _Line l, double beats, DancePose out) {
    final track = l.own && _alt.move != null ? _alt : _lead;
    final t = beats - l.delay;
    if (l.group >= 0) {
      final w = ((t - l.at) / 4).floor();
      final w0 = l.at + w * 4;
      if ((w + l.group).isOdd) {
        track.pose(mr, w0, out, partner: l.partner);
        return;
      }
      final k = (t - w0) / 0.75;
      if (w > 0 && k < 1) {
        final held = _held ??= DancePose(mr.bones);
        track.pose(mr, w0 - 4, held, partner: l.partner);
        track.pose(mr, t, out, partner: l.partner);
        held.blendToward(out, k * k * (3 - 2 * k));
        out.copyFrom(held);
        return;
      }
    }
    track.pose(mr, t, out, partner: l.partner);
  }

  /// The company's routine and places (DanceClock.routine, .formation):
  /// [slot] the slot it is dealt for (an earlier one when a section is danced again),
  /// [now] the slot it is danced in.
  void _routine(DanceTroupe t, int salt, int slot, int now, double beats) {
    final r = DanceClock.routine(t, salt, slot);
    final at = (now * DanceClock.slotBeats).toDouble();
    final big = DanceClock.isBig(t);
    final live = [for (final mb in _members) if (!mb.leaving) mb];
    for (final mb in live) {
      final p = mb.line.partner;
      // The lead's partner dances with the lead, whatever the others do.
      final lead = p && mb.rank == 0;
      final _Line l = lead
          ? (own: false, delay: 0.0, partner: true, group: -1, at: 0.0)
          : switch (r) {
              DanceRoutine.unison => (own: false, delay: 0.0, partner: p, group: -1, at: 0.0),
              DanceRoutine.wave => (own: false, delay: math.min(1.5, mb.rank * (big ? 0.125 : 0.25)), partner: p, group: -1, at: 0.0),
              DanceRoutine.canon => (own: false, delay: mb.rank.isOdd ? 1.0 : 2.0, partner: p, group: -1, at: 0.0),
              DanceRoutine.split => (own: mb.group == 1, delay: 0.0, partner: p, group: -1, at: 0.0),
              DanceRoutine.answer => (own: false, delay: 0.0, partner: p, group: mb.group, at: at),
            };
      mb.dance(l, beats);
    }
    final f = DanceClock.formation(t, salt, slot);
    final spots = _formation(t, f);
    if (spots == null || spots.length != live.length) return;
    for (var i = 0; i < live.length; i++) {
      live[i].moveTo(spots[i], beats);
    }
  }

  /// A small set's places in formation [f] (0 the one it walks in as), in the order
  /// _setTroupe makes its members; null where it has only the one.
  static List<DanceSpot>? _formation(DanceTroupe t, int f) {
    List<DanceSpot> pairs(List<(double, double)> xy) => [
          for (final (x, y) in xy) ...[DanceSpot(x: -x, y: y), DanceSpot(x: x, y: y, mirror: true)]
        ];
    return switch (t) {
      DanceTroupe.duo => [
          [const DanceSpot(x: 1.3, y: 0.6, mirror: true)],
          [const DanceSpot(x: -1.3, y: 0.6, mirror: true)],
          [const DanceSpot(x: 0.9, y: 1.3, mirror: true)],
        ][f % 3],
      DanceTroupe.trio => pairs([
          [(1.4, 1.1)],
          [(0.9, 1.8)],
          [(1.9, 0.3)],
          [(0.65, 2.0)],
        ][f % 4]),
      DanceTroupe.line => [
          // the staggered line it walks in as, a wedge, a row behind, a diamond
          [(1.2, 0.15), (2.4, 0.3)],
          [(1.1, 1.0), (2.2, 2.0)],
          [(1.0, 1.6), (2.6, 1.6)],
          [(1.4, 0.9), (0.7, 2.1)],
        ][f % 4]
            .indexed
            .expand((e) => [DanceSpot(x: -e.$2.$1, y: e.$2.$2 + 0.15 * e.$1), DanceSpot(x: e.$2.$1, y: e.$2.$2 + 0.15 * e.$1 + 0.15, mirror: true)])
            .toList(),
      DanceTroupe.couples => [
          const DanceSpot(),
          for (final (x, y) in [(2.7, 1.5), (2.2, 2.5), (3.1, 0.5), (1.6, 2.2)].skip(f % 4).take(1)) ...[
            DanceSpot(x: -x, y: y, mirror: true),
            DanceSpot(x: -x, y: y, mirror: true),
            DanceSpot(x: x, y: y),
            DanceSpot(x: x, y: y),
          ],
        ],
      _ => null,
    };
  }

  /// A new move on [track]: one of the pool ([duo]: a duet's lead half), starting at
  /// the beat whose pose — and motion — is nearest what the dancer is doing now; what
  /// is left of the old pose fades out of it (DanceCarry) over [blend] beats, longer
  /// the further apart the two were.
  void _step(DanceRig rig, _Track track, DanceTier tier, Map<DanceStyle, double> flavour, double bpm, double beats, int salt, int slot,
      {required bool sleep, double blend = 1, bool quiet = false, bool techno = false, bool duo = false}) {
    // The pool's say: the moves switched off are out, the favourites count for more.
    final offMoves = MovePool.off;
    final moves = offMoves.isEmpty ? rig.moves : [for (final m in rig.moves) if (!offMoves.contains(m.id)) m];
    var pool = DanceClock.pool(moves.isEmpty ? rig.moves : moves, tier, flavour, bpm, recent: quiet ? [if (track.move != null) track.move!.id] : _recent, techno: techno, duo: duo);
    final stars = MovePool.favourites;
    if (stars.isNotEmpty) pool = [for (final (m, w) in pool) (m, stars.contains(m.id) ? w * 2.5 : w)];
    // A move asked for by hand: the lead dances it now, whatever the dice say.
    final asked = quiet ? null : MovePool.audition;
    if (asked != null) {
      final m = rig.move(asked);
      if (m != null && (duo == (m.duo != null))) {
        pool = [(m, 1.0)];
        MovePool.audition = null;
      } else if (m != null) {
        // Not for this slot's company (a duet asked of a solo, or the reverse): kept
        // for the next slot that fits, let go after a while.
        if (_auditionWaits++ > 4) {
          MovePool.audition = null;
          _auditionWaits = 0;
        }
      } else {
        MovePool.audition = null;
      }
    }
    if (pool.isEmpty) return;
    const h = 0.25; // a quarter beat: how far back a motion is read
    final now = DancePose(rig.bones), was = DancePose(rig.bones);
    final had = track.pose(rig, beats, now) && track.pose(rig, beats - h, was);
    final from = had ? rig.keyJoints(now) : null;
    final fromWas = had ? rig.keyJoints(was) : null;
    // The likeliest few by the dice, then each at its best entry; the nearest pose wins
    // among those (the dice still have the most say).
    final picks = <DanceMove>{};
    for (var k = 0; k < 5 && picks.length < 4; k++) {
      final mv = DanceClock.draw(pool, memeHash(salt % 9973, slot * 7 + k, 7));
      if (mv != null) picks.add(mv);
    }
    if (pool.length == 1) picks.add(pool.first.$1);
    DanceMove? best;
    var bestE = 0, bestScore = double.infinity, bestD = 0.0;
    final probe = DancePose(rig.bones), probeWas = DancePose(rig.bones);
    var order = 0;
    for (final mv in picks) {
      final rate = DanceClock.rate(bpm, mv.bpm, sleep: sleep);
      for (final e in DanceClock.entries(mv)) {
        var d = 0.0, dv = 0.0;
        if (from != null) {
          rig.sample(mv, e.toDouble(), probe);
          final to = rig.keyJoints(probe);
          d = DanceRig.poseDistance(from, to);
          // How differently the joints are moving (metres a beat): a hand swinging up
          // stepping into one swinging down reads as a jolt, however near the poses.
          rig.sample(mv, e - h * rate, probeWas);
          dv = DanceRig.motionDistance(from, fromWas!, to, rig.keyJoints(probeWas)) / h;
        }
        // Earlier picks are the dice's favourites: a small handicap for later ones.
        final score = d + 0.08 * dv + order * 0.04 + e * 0.002;
        if (score < bestScore) {
          bestScore = score;
          best = mv;
          bestE = e;
          bestD = d;
        }
      }
      order++;
    }
    if (best == null) return;
    _enter(rig, track, best, bestE, bestD, bpm, beats, sleep: sleep, blend: blend, quiet: quiet, now: had ? now : null);
  }

  /// [track] into [best] at its beat [bestE], [bestD] metres from the pose it is in
  /// ([now], when it was dancing): what is left of the old pose fades out of the new
  /// move (DanceCarry) over [blend] beats, longer the further apart the two were.
  void _enter(DanceRig rig, _Track track, DanceMove best, int bestE, double bestD, double bpm, double beats,
      {required bool sleep, double blend = 1, bool quiet = false, DancePose? now}) {
    final had = now != null;
    final was = DancePose(rig.bones);
    final rate = DanceClock.rate(bpm, best.bpm, sleep: sleep);
    final len = blend <= 0 ? 0.0 : blend * (0.8 + 2.5 * bestD).clamp(0.8, 1.8);
    // The old poses the carry starts from: the lead's half and, where a duet is
    // involved, the partner's (who was dancing the lead's move if it was no duet).
    // Its speed read over a sixteenth (the moves are sampled every eighth, straight
    // between: the speed it has right now).
    const hc = 1 / 16;
    final pair = best.duo != null || track.move?.duo != null;
    DancePose? pNow, pWas;
    if (pair && len > 0 && had) {
      pNow = DancePose(rig.bones);
      pWas = DancePose(rig.bones);
      track.pose(rig, beats, pNow, partner: true);
      track.pose(rig, beats - hc, pWas, partner: true);
    }
    if (len > 0 && had) track.pose(rig, beats - hc, was);
    track.switchTo(best, beats, bestE.toDouble(), rate, len);
    if (len > 0 && had) {
      final to = DancePose(rig.bones), toWas = DancePose(rig.bones);
      void carry(int part, DancePose a, DancePose aWas) {
        final mv = part == 1 ? rig.partnerOf(best) : best;
        rig.sample(mv, bestE.toDouble(), to);
        rig.sample(mv, bestE - hc * rate, toWas);
        (track.carry[part] ??= DanceCarry(rig.bones)).start(a, aWas, to, toWas, hc, len);
      }

      carry(0, now, was);
      if (pNow != null) {
        carry(1, pNow, pWas!);
      } else {
        track.carry[1]?.len = 0;
      }
    }
    if (!quiet) {
      _recent.add(best.id);
      if (_recent.length > 5) _recent.removeAt(0);
    }
  }

  /// [track] back into [move] at its beat [entry], as it was danced the last time
  /// the record was here.
  void _replay(DanceRig rig, _Track track, DanceMove move, int entry, double bpm, double beats, {required bool sleep, double blend = 1}) {
    final now = DancePose(rig.bones);
    final had = track.pose(rig, beats, now);
    var d = 0.0;
    if (had) {
      final probe = DancePose(rig.bones);
      rig.sample(move, entry.toDouble(), probe);
      d = DanceRig.poseDistance(rig.keyJoints(now), rig.keyJoints(probe));
    }
    _enter(rig, track, move, entry, d, bpm, beats, sleep: sleep, blend: blend, now: had ? now : null);
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
        spots.add(_Member(_formation(t, 0)![0], group: 1, from: const Offset(4, 0)));
      case DanceTroupe.trio:
        final f = _formation(t, 0)!;
        spots
          ..add(_Member(f[0], group: 1, from: const Offset(-4, 1)))
          ..add(_Member(f[1], group: 1, from: const Offset(4, 1)));
      case DanceTroupe.line:
        final f = _formation(t, 0)!;
        for (var k = 1; k <= 4; k++) {
          final sp = f[k - 1];
          // The inner pair answers the outer one.
          spots.add(_Member(sp, rank: k, group: k <= 2 ? 0 : 1, delay: 0.25 * k, from: Offset(sp.x.sign * 5, 0)));
        }
      case DanceTroupe.grid:
        // Seven across, five deep, evenly spaced, the lead in the front middle.
        for (var row = 0; row < 5; row++) {
          for (var col = -3; col <= 3; col++) {
            if (row == 0 && col == 0) continue;
            final x = col * 1.35, y = row * 1.6;
            spots.add(_Member(DanceSpot(x: x, y: y, mirror: col.isOdd), rank: row + col.abs(), group: row.isOdd ? 1 : 0, from: Offset(x.sign * 6 + 0.01, row * 0.5)));
          }
        }
      case DanceTroupe.ring:
        // Twelve round the lead.
        for (var i = 0; i < 12; i++) {
          final a = math.pi * 2 * i / 12 + math.pi / 2;
          final x = math.cos(a) * 3.3, y = math.sin(a) * 3.3 + 0.6;
          spots.add(_Member(DanceSpot(x: x, y: y, mirror: i.isOdd), rank: math.min(i, 12 - i) + 1, group: i % 2, from: Offset(x * 0.6, y * 0.6 + 4)));
        }
      case DanceTroupe.army:
        // Rows behind the lead, eight across, offset like bricks.
        for (var row = 1; row <= 3; row++) {
          for (var k = 0; k < 8; k++) {
            final x = (k - 3.5) * 1.25 + (row.isOdd ? 0.3 : -0.3), y = row * 1.7;
            spots.add(_Member(DanceSpot(x: x, y: y, mirror: k.isOdd), rank: row * 2 + (x.abs() / 1.25).round(), group: row % 2, from: Offset(x.sign * 7, 0)));
          }
        }
      case DanceTroupe.crowd:
        for (var i = 0; i < 6; i++) {
          final a = math.pi * (0.15 + 0.7 * i / 5);
          final r = 2.2 + 0.5 * memeHash(salt % 9973, slot * 3 + i, 61);
          final x = -math.cos(a) * r, y = math.sin(a) * r * 0.8 + 0.4;
          spots.add(_Member(DanceSpot(x: x, y: y, yaw: -x * 0.12, mirror: i.isOdd),
              rank: i + 1, group: i % 3 == 1 ? 1 : 0, delay: i.isEven ? 0 : 0.5, own: i % 3 == 1, from: Offset(x.sign * 5, 2)));
        }
      case DanceTroupe.couple:
        // The partner, where the duet puts them round the couple's middle.
        spots.add(_Member(const DanceSpot(), partner: true, rank: 0, group: -1, from: const Offset(4, 0.3)));
      case DanceTroupe.couples:
        // The lead's couple in the middle, one either side behind, each a half of the
        // company.
        final f = _formation(t, 0)!;
        spots.add(_Member(f[0], partner: true, rank: 0, group: -1, from: const Offset(4, 0.3)));
        for (var k = 0; k < 4; k++) {
          final sp = f[k + 1];
          spots.add(_Member(sp, partner: k.isOdd, rank: 1, group: k < 2 ? 0 : 1, from: Offset(sp.x.sign * 5, 0.5)));
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
  void _wash(DanceSurface c, Size s, Color top, Color bottom) {
    final q = DanceQuads()
      ..tri(Offset.zero, Offset(s.width, 0), Offset(s.width, s.height), top, top, bottom)
      ..tri(Offset.zero, Offset(s.width, s.height), Offset(0, s.height), top, bottom, bottom);
    q.draw(c, blend: BlendMode.src);
  }

  /// A backdrop of [outer] with a soft glow of [inner] at [at], [radius] wide.
  void _glow(DanceSurface c, Size s, Offset at, double radius, Color inner, Color outer) {
    c.fill(Offset.zero & s, outer);
    final q = DanceQuads();
    const seg = 32;
    for (var i = 0; i < seg; i++) {
      final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
      q.tri(at, at + Offset(math.cos(a0), math.sin(a0)) * radius, at + Offset(math.cos(a1), math.sin(a1)) * radius, inner, outer, outer);
    }
    q.draw(c);
  }

  /// Beams from a truss at the back, sweeping the floor (the room's and the disco's drop).
  void _beams(DanceSurface c, DanceCam cam, _Look l, List<Color> colors, double k) {
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
  void _rings(DanceSurface c, DanceCam cam, _Look l, Color color) {
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

  void _disco(DanceSurface c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies) {
    final pal = l.st.palette;
    final cols = [pal.primary.withLightness(0.55).toColor(), pal.secondary.withLightness(0.55).toColor(), pal.accent.withLightness(0.6).toColor()];
    _wash(c, s, const Color(0xff050308), Color.lerp(cols[0], Colors.black, 0.86)!);
    c.body(_hero!, cam, _lit(l, cols[2], dim: 0.4), underFloor: true);
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
      c.floorShadow(b, cam, const V3(-0.2, -0.3, 1), const Color(0xff020203));
    }
    // The mirror ball, faceted, and its flecks thrown round the room.
    _ball(c, cam, l, cols);
    if (l.rage) _beams(c, cam, l, cols, 0.5 + 0.5 * l.kick);
    _rings(c, cam, l, cols[2]);
    for (final (b, _, _) in bodies) {
      c.body(b, cam, _lit(l, cols[(l.beats ~/ 4) % 3], lead: identical(b, _hero)));
    }
  }

  void _ball(DanceSurface c, DanceCam cam, _Look l, List<Color> cols) {
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
      c.points(Float32List.fromList(pts), cam.size.height * 0.007, Colors.white.withValues(alpha: 0.7 * k));
    }
  }

  void _neon(DanceSurface c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, DanceRig rig, double beats) {
    final pal = l.st.palette;
    final a = pal.accent.withSaturation(1).withLightness(0.6).toColor();
    final b = pal.secondary.withSaturation(1).withLightness(0.62).toColor();
    c.fill(Offset.zero & s, const Color(0xff040208));
    // The sun on the horizon, far behind.
    final (sx, sy, sd) = cam.project(const V3(0, 80, 9));
    if (sd > DanceCam.near) {
      final r = cam.scaleAt(sd) * 14;
      final top = pal.accent.withLightness(0.65).toColor(), bottom = pal.primary.withLightness(0.45).toColor();
      c.clip(Rect.fromLTRB(0, 0, s.width, sy + r * 0.2));
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
        c.fill(Rect.fromLTWH(sx - r, y, r * 2, r * 0.04 * (1 + i * 0.6)), const Color(0xff040208));
      }
      c.clip(null);
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
      final pose = _pose!;
      for (var g = 0; g < 3; g++) {
        final ghost = _ghost(rig, g);
        _lead.pose(rig, beats - 0.18 * (g + 1), pose);
        ghost.pose(rig, pose);
        ghost.place(DanceSpot(scale: _heroScale));
        c.outline(ghost, cam, 0.012, Color.lerp(b, a, g / 3)!.withValues(alpha: 0.5 - 0.13 * g), blend: BlendMode.plus);
      }
    }
    final width = 0.014 + 0.01 * l.kick * (l.rage ? 1 : 0.3);
    for (final (body, _, _) in bodies) {
      // Glow: a wide faint line under a narrow bright one; the body black inside, its rim lit.
      c.outline(body, cam, width * 2.6, a.withValues(alpha: 0.18), blend: BlendMode.plus);
      c.outline(body, cam, width, a);
      c.body(body, cam, DanceLook3(flat: const Color(0xff020104), textured: false, rim: a, rimK: 0.9, rimPower: 3));
    }
  }

  void _shadowStage(DanceSurface c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, double beats) {
    final pal = l.st.palette;
    const wallY = 2.6;
    final warm = HSLColor.fromAHSL(1, pal.accent.hue, 0.35, 0.78).toColor();
    // The lamps: one low in front, swaying with the bar; three coloured ones on the drop.
    final sway = math.sin(beats * math.pi / 8) * 1.2;
    final lamps = l.rage
        ? [
            (V3(-1.6 + sway * 0.3, -3.2, 0.5), pal.primary.withSaturation(1).withLightness(0.55).toColor()),
            (V3(0, -3.4, 0.35), pal.secondary.withSaturation(1).withLightness(0.55).toColor()),
            (V3(1.6 - sway * 0.3, -3.2, 0.5), pal.accent.withSaturation(1).withLightness(0.55).toColor()),
          ]
        : [(V3(sway, -3.0, 0.45 + 0.15 * l.beat), warm)];
    // The backdrop: one even colour, the lamps' light all over it (no pool, no
    // floor), so nothing competes with the shadows on it.
    final wallK = l.sleep ? 0.7 : 0.85 + 0.15 * l.beat;
    var br = 0.0, bg = 0.0, bb = 0.0;
    for (final (_, col) in lamps) {
      br += col.r;
      bg += col.g;
      bb += col.b;
    }
    final k = wallK * (l.rage ? 0.5 : 1.0);
    c.fill(Offset.zero & s, Color.from(alpha: 1, red: (br * k).clamp(0.0, 1.0), green: (bg * k).clamp(0.0, 1.0), blue: (bb * k).clamp(0.0, 1.0)));
    // Each lamp's shadow: where its light is stopped, the wall without that colour.
    for (final (lamp, col) in lamps) {
      final shade = lamps.length == 1
          ? const Color(0xff0a0806)
          : Color.from(alpha: 1, red: (1 - col.r) * 0.55, green: (1 - col.g) * 0.55, blue: (1 - col.b) * 0.55);
      for (final (b, _, _) in bodies) {
        c.wallShadow(b, cam, lamp, wallY, shade);
      }
    }
    for (final (b, _, _) in bodies) {
      c.body(b, cam, DanceLook3(key: lamps.first.$1, keyColor: lamps.first.$2, keyK: 0.75, ambient: 0.3, fillK: 0.1, rim: warm, rimK: 0.5));
    }
  }

  // ------------------------------------------------------------------ the stylised stage

  /// Where the figure's middle is on the picture (0..1), for the ascii's pop.
  Offset _popAt = const Offset(0.5, 0.45);

  void _artStage(DanceSurface c, Size s, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, DanceRig rig, double beats) {
    final pal = l.st.palette;
    final mid = cam.at(const V3(0, 0, 1.15));
    _popAt = Offset(mid.dx / s.width, mid.dy / s.height);
    switch (_art ?? DanceArt.mono) {
      case DanceArt.mono:
        // Black on white; in a drop, white on black by the bar — the cut on the downbeat.
        final inverted = l.rage && (beats / 4).floor().isOdd;
        final paper = inverted ? const Color(0xff050505) : const Color(0xfff3f2ee);
        final ink = inverted ? const Color(0xfff3f2ee) : const Color(0xff050505);
        c.fill(Offset.zero & s, paper);
        // The kick: the figure a hair bigger for a moment.
        _hero!.place(DanceSpot(scale: _heroScale * (1 + 0.018 * l.kick)));
        for (final (b, _, _) in bodies) {
          c.body(b, cam, DanceLook3(flat: ink, textured: false, shadeFlat: false), twoSided: true);
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
          c.body(b, cam, _chrome(l, pal.accent.withLightness(0.7).toColor()), twoSided: true);
        }
      case DanceArt.ascii:
        // The figure lit bright on black; the finish turns it to text.
        c.fill(Offset.zero & s, Colors.black);
        for (final (b, _, _) in bodies) {
          c.body(b, cam, _chrome(l, Colors.white), twoSided: true);
        }
      case DanceArt.dither:
        final top = HSLColor.fromAHSL(1, pal.primary.hue, 0.25, 0.3).toColor();
        _glow(c, s, Offset(s.width / 2, s.height * 0.42), s.height * 0.9, top, Colors.black);
        // The chrome figure: its reflections are what the dots draw.
        for (final (b, _, _) in bodies) {
          c.body(b, cam, _chrome(l, Colors.white), twoSided: true);
        }
      case DanceArt.contour:
      case DanceArt.halftone:
      case DanceArt.thermal:
      case DanceArt.lines:
        // The figures bright on black; the finish draws them its own way.
        c.fill(Offset.zero & s, Colors.black);
        for (final (b, _, _) in bodies) {
          c.body(b, cam, _chrome(l, Colors.white), twoSided: true);
        }
      case DanceArt.fluid:
        c.fill(Offset.zero & s, Colors.black);
        if (c is NativeDanceSurface) {
          c.fluid(_splats(cam, bodies, s, l), [for (final (b, _, _) in bodies) b], [
            pal.primary.withSaturation(0.85).withLightness(0.5).toColor(),
            pal.secondary.withSaturation(0.85).withLightness(0.5).toColor(),
            pal.accent.withSaturation(0.9).withLightness(0.55).toColor(),
          ], l.kick, l.rage ? 1.0 : (l.sleep ? 0.45 : 0.75));
        }
        for (final (b, _, _) in bodies) {
          c.body(b, cam, _chrome(l, pal.accent.withLightness(0.75).toColor()), twoSided: true);
        }
      case DanceArt.viewports:
        _viewports(c, s, l, beats);
      case DanceArt.plain:
        // The models as they are, and nothing else: the scan's skin under a plain
        // daylight on white — no floor, no shadow, no studio. Drawn at alpha 254/255
        // (replacing, not blending): MilkDrop under the scene leaves them as they are
        // and goes only into the white (under.frag).
        c.fill(Offset.zero & s, Colors.white);
        for (final (b, _, _) in bodies) {
          c.body(
              b,
              cam,
              const DanceLook3(
                key: V3(-0.35, -0.8, 0.65),
                keyColor: Color(0xfffffaf2),
                keyK: 0.55,
                fill: Color(0xffc8ccd4),
                fillK: 0.3,
                ambient: 0.5,
                rimK: 0,
                alpha: 254 / 255,
              ),
              blend: BlendMode.src);
        }
      case DanceArt.chrono:
        c.fill(Offset.zero & s, const Color(0xff060606));
        _studioFloor(c, cam, l, bodies, pal.primary.withSaturation(0.3).withLightness(0.7).toColor());
        _stamps(c, cam, l, rig, beats, pal.primary.withSaturation(0.3).withLightness(0.6).toColor());
        for (final (b, _, _) in bodies) {
          c.body(b, cam, _chrome(l, Colors.white), twoSided: true);
        }
    }
  }

  /// A model editor's viewports: the picture cut into a grid of panels, each a
  /// dancer seen straight on over the editor's ground grid, shaded by turns
  /// (textured, chrome, solid), every model dancing the lead's moves; the panel
  /// whose turn it is on the beat is outlined as the selection.
  void _viewports(DanceSurface c, Size s, _Look l, double beats) {
    final st = l.st;
    final salt = st.master.trackId ?? 0;
    final (cols, rows) = switch (l.mood) {
      MemeMood.sleep => (2, 2),
      MemeMood.rage => memeHash(salt % 9973, (beats / 16).floor(), 5) < 0.5 ? (4, 3) : (3, 3),
      _ => (3, 2),
    };
    c.fill(Offset.zero & s, const Color(0xff050506));
    final models = DanceModels.pool(st.macros.dancersOff);
    final pose = _pose!;
    final bob = l.sleep ? 0.0 : 0.022 * l.kick;
    final posed = <String, DanceBody>{};
    const gutter = 3.0;
    final cw = s.width / cols, ch = s.height / rows;
    final step = (l.beats * (l.rage ? 2 : 1)).floor();
    final pal = st.palette;
    final sel = HSLColor.fromAHSL(1, 30, 0.95, 0.58).toColor(); // the editor's orange
    for (var r = 0; r < rows; r++) {
      for (var k = 0; k < cols; k++) {
        final i = r * cols + k;
        final rect = Rect.fromLTWH(k * cw + gutter, r * ch + gutter, cw - 2 * gutter, ch - 2 * gutter);
        // the panel: a soft vertical wash, an editor's grey kept dark (MilkDrop shows
        // through it under the contrast)
        final q = DanceQuads()
          ..tri(rect.topLeft, rect.topRight, rect.bottomRight, const Color(0xff19191c), const Color(0xff19191c), const Color(0xff0c0c0e))
          ..tri(rect.topLeft, rect.bottomRight, rect.bottomLeft, const Color(0xff19191c), const Color(0xff0c0c0e), const Color(0xff0c0c0e));
        q.draw(c, blend: BlendMode.src);
        c.clip(rect);
        // a front camera framing one dancer in this panel: the whole picture's size,
        // its focal length the panel's, its middle moved to the panel's
        const fov = 0.6, dist = 4.0, height = 1.15, aim = 0.92;
        final focal = rect.height / 2 / math.tan(fov / 2);
        final full = 2 * math.atan(s.height / 2 / focal);
        final cam = DanceCam(
          eye: const V3(0, -dist, height),
          target: const V3(0, 0, aim),
          size: s,
          fov: full,
          shift: Offset((rect.center.dx - s.width / 2) / s.width, (rect.center.dy - s.height / 2) / s.height),
        );
        c.camera(cam);
        // the ground grid, a metre a line, the two axes in red and green
        final g = DanceQuads();
        for (var x = -4; x <= 4; x++) {
          final axis = x == 0;
          final col = axis ? const Color(0xff9a3b3b).withValues(alpha: 0.0) : const Color(0x33a0a0a8);
          g.quad(cam, V3(x - 0.008, -2, 0), V3(x + 0.008, -2, 0), V3(x + 0.008, 6, 0), V3(x - 0.008, 6, 0), col);
        }
        for (var y = -2; y <= 6; y++) {
          final col = y == 0 ? const Color(0xff9a3b3b) : const Color(0x33a0a0a8);
          g.quad(cam, V3(-4, y - 0.008, 0), V3(4, y - 0.008, 0), V3(4, y + 0.008, 0), V3(-4, y + 0.008, 0), col);
        }
        g.quad(cam, const V3(-0.01, -2, 0), const V3(0.01, -2, 0), const V3(0.01, 6, 0), const V3(-0.01, 6, 0), const Color(0xff5a8a3a));
        g.draw(c);
        // the dancer: the panels' models by turns, all on the lead's line
        final model = models[(i + salt) % models.length];
        final a = _ready(model);
        final rig = a.rig!;
        final body = _bodies.putIfAbsent('viewport/$model/$i', () => DanceBody(rig.meshes.first, a.skin!, gpu: gpu));
        final twin = posed[model];
        final sc = _scaleOf(rig);
        if (twin != null) {
          body.copyPose(twin);
        } else {
          _lead.pose(rig, beats, pose);
          pose.hips[2] -= bob / sc;
          body.pose(rig, pose);
          posed[model] = body;
        }
        body.place(DanceSpot(scale: sc));
        final look = switch (i % 3) {
          0 => _lit(l, pal.accent.withLightness(0.7).toColor()),
          1 => _chrome(l, pal.accent.withLightness(0.75).toColor()),
          _ => DanceLook3(flat: const Color(0xff8a8a90), textured: false, rim: Colors.white, rimK: 0.2, key: const V3(-0.4, -0.8, 0.6)),
        };
        c.floorShadow(body, cam, const V3(0.25, -0.35, 1), const Color(0xff101012));
        c.body(body, cam, look, twoSided: true);
        c.clip(null);
        // the selection: the panel whose turn it is, outlined
        if (step % (rows * cols) == i) {
          final o = DanceQuads();
          const t = 2.0;
          for (final e in [
            Rect.fromLTWH(rect.left, rect.top, rect.width, t),
            Rect.fromLTWH(rect.left, rect.bottom - t, rect.width, t),
            Rect.fromLTWH(rect.left, rect.top, t, rect.height),
            Rect.fromLTWH(rect.right - t, rect.top, t, rect.height),
          ]) {
            o
              ..tri(e.topLeft, e.topRight, e.bottomRight, sel)
              ..tri(e.topLeft, e.bottomRight, e.bottomLeft, sel);
          }
          o.draw(c);
        }
      }
    }
  }

  /// Where the fluid is pushed: every body's hands, feet and head, where they are on
  /// the picture and how fast they move there (against last frame), as splats — the
  /// lead's first, then the others' hands, up to thirty-two.
  List<(double, double, double, double, double)> _splats(DanceCam cam, List<(DanceBody, DanceSpot, double)> bodies, Size s, _Look l) {
    final out = <(double, double, double, double, double)>[];
    final now = <(DanceBody, String), Offset>{};
    final dt = (l.t - _splatT).clamp(1 / 240, 0.1);
    _splatT = l.t;
    for (final (b, _, _) in bodies) {
      final lead = identical(b, _hero);
      for (final j in lead ? const ['Hand_L', 'Hand_R', 'Toes_L', 'Toes_R', 'Head'] : const ['Hand_L', 'Hand_R']) {
        if (out.length >= 32) break;
        final p = b.jointWorld(j, j == 'Head' ? 0.16 : 0.08);
        if (p == null) continue;
        final (x, y, d) = cam.project(p);
        if (d < DanceCam.near) continue;
        final at = Offset(x, y);
        now[(b, j)] = at;
        final was = _jointsWas[(b, j)];
        if (was == null) continue;
        final v = (at - was) / dt;
        // as wide as a hand is near, wider for the head
        final r = cam.scaleAt(d) * (j == 'Head' ? 0.22 : 0.14);
        out.add((x, y, v.dx, v.dy, r));
      }
    }
    _jointsWas
      ..clear()
      ..addAll(now);
    return out;
  }

  final _jointsWas = <(DanceBody, String), Offset>{};
  double _splatT = 0;

  /// The figure in polished chrome (DanceBody's chrome): the studio round it in its
  /// surface, faintly tinted by the record's colour, a rim of [rim]. [dim] scales it
  /// all (an afterimage's share).
  DanceLook3 _chrome(_Look l, Color rim, {double dim = 1}) => DanceLook3(
        textured: false,
        chrome: true,
        keyColor: Color.lerp(Colors.white, l.st.palette.secondary.withSaturation(0.6).withLightness(0.75).toColor(), 0.18)!,
        rim: rim,
        rimK: 0.25 + 0.2 * l.beat,
        dim: dim,
      );

  /// A studio floor under the figure: a soft pool of light and the figure's shadow
  /// in it, so it stands somewhere rather than floating in the dark.
  void _studioFloor(DanceSurface c, DanceCam cam, _Look l, List<(DanceBody, DanceSpot, double)> bodies, Color light) {
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
      c.floorShadow(b, cam, const V3(0.25, -0.35, 1), const Color(0xff030303));
    }
  }

  /// Light swept behind the hands, the feet and the head: where they were over the
  /// last beat or two, as ribbons thinning and fading into the past.
  void _ribbons(DanceSurface c, DanceCam cam, _Look l, DanceRig rig, double beats, List<Color> cols) {
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
    final pose = _pose!;
    for (var k = 0; k <= n; k++) {
      _lead.pose(rig, beats - span * k / n, pose);
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
  void _stamps(DanceSurface c, DanceCam cam, _Look l, DanceRig rig, double beats, Color tint) {
    final step = l.rage ? 0.25 : 0.5;
    final count = l.rage ? 8 : 6;
    final pose = _pose!;
    final last = (beats / step).floor() * step;
    for (var k = count; k >= 1; k--) {
      final g = _ghost(rig, k - 1);
      _lead.pose(rig, last - (k - 1) * step - (beats - last < 0.02 ? step : 0), pose);
      g.pose(rig, pose);
      g.place(DanceSpot(scale: _heroScale));
      final age = (k - 1) / count;
      final fresh = k == 1 ? (1 - (beats - last) / (step * 0.6)).clamp(0.0, 1.0) : 0.0;
      final k0 = (0.42 * math.pow(1 - age, 1.6) + 0.25 * fresh).toDouble();
      c.body(g, cam, _chrome(l, Color.lerp(tint, Colors.white, 0.3)!, dim: k0), twoSided: true, blend: BlendMode.plus);
    }
  }

  /// The ascii or dither finish over the stylised stage's picture.
  ui.Image _post(ui.Image img, int w, int h, StagePrograms p, _Look l, {bool lens = false}) {
    final program = p.sims['dance_fx'];
    if (program == null) return img;
    final fx = _fx ??= program.fragmentShader();
    final glyphs = _glyphs ??= _makeGlyphs();
    final (:mode, :ink, :paper, :cell, :tint) = lens
        ? (mode: 7, ink: Colors.white, paper: Colors.black, cell: DanceFrame.fisheyeEdge, tint: math.tan(DanceFrame.fisheyeFov / 2))
        : _postParams(l, h);
    fx
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, mode.toDouble())
      ..setFloat(3, cell)
      ..setFloat(4, ink.r)
      ..setFloat(5, ink.g)
      ..setFloat(6, ink.b)
      ..setFloat(7, paper.r)
      ..setFloat(8, paper.g)
      ..setFloat(9, paper.b)
      ..setFloat(10, tint)
      ..setFloat(11, _ramp.length.toDouble())
      ..setFloat(12, l.kick.clamp(0.0, 1.0))
      ..setFloat(13, _popAt.dx)
      ..setFloat(14, _popAt.dy)
      ..setFloat(15, _t)
      ..setFloat(16, 0)
      ..setImageSampler(0, img)
      ..setImageSampler(1, glyphs);
    setFxKnobs(fx, 17, l.st, lens ? null : _fxName);
    final r = ui.PictureRecorder();
    Canvas(r).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx);
    final pic = r.endRecording();
    final out = pic.toImageSync(w, h);
    pic.dispose();
    img.dispose();
    return out;
  }

  /// The ascii's or the dither's colours and cell for a picture [h] high.
  ({int mode, Color ink, Color paper, double cell, double tint}) _postParams(_Look l, int h) {
    final q = _postDrawn(l, h);
    // Through the hands' knobs for the treatment (state/show/show_tune.dart).
    final t = tunedCell(l.st, _fxName, q.cell, q.tint);
    return (mode: q.mode, ink: q.ink, paper: q.paper, cell: t.cell, tint: t.tint);
  }

  /// The treatment the finish draws, by name (show_tune.dart's): the ascii where the
  /// art is none of them.
  String get _fxName => _art != null && treatmentFxMode.containsKey(_art!.name) ? _art!.name : 'ascii';

  /// The finish's colours and cell as the look draws them, before the knobs.
  ({int mode, Color ink, Color paper, double cell, double tint}) _postDrawn(_Look l, int h) {
    final pal = l.st.palette;
    final mode = danceFxMode[_art] ?? 1;
    final dark = HSLColor.fromAHSL(1, pal.primary.hue, 0.45, 0.035).toColor();
    return switch (_art) {
      DanceArt.dither => (mode: mode, ink: const Color(0xffeee7d6), paper: HSLColor.fromAHSL(1, pal.primary.hue, 0.4, 0.07).toColor(), cell: math.max(2.0, h / 220), tint: 0.0),
      DanceArt.contour => (mode: mode, ink: pal.accent.withSaturation(0.85).withLightness(0.62).toColor(), paper: dark, cell: 0.0, tint: 0.0),
      DanceArt.halftone => (mode: mode, ink: pal.primary.withSaturation(0.9).withLightness(0.55).toColor(), paper: const Color(0xff050506), cell: math.max(4.0, h / (l.rage ? 80 : 110)), tint: 0.0),
      DanceArt.thermal => (mode: mode, ink: Colors.white, paper: Colors.black, cell: 0.0, tint: 0.0),
      DanceArt.lines => (mode: mode, ink: pal.accent.withSaturation(0.35).withLightness(0.85).toColor(), paper: const Color(0xff030303), cell: math.max(5.0, h / 72), tint: 0.0),
      _ => (mode: mode, ink: pal.accent.withSaturation(0.55).withLightness(0.78).toColor(), paper: const Color(0xff040404), cell: h / (l.rage ? 52 : 40), tint: 0.2),
    };
  }

  /// The glyph ramp, light to dense, white on clear, side by side, as RGBA bytes:
  /// for the native stage's ascii.
  static Future<(int, int, Uint8List)?> glyphBytes() async {
    final img = _glyphs ??= _makeGlyphs();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data == null ? null : (img.width, img.height, data.buffer.asUint8List());
  }

  static int get glyphCount => _ramp.length;

  /// The glyph ramp as an image, for a treatment pass over any scene (show_canvas.dart).
  static ui.Image get glyphAtlas => _glyphs ??= _makeGlyphs();

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
  void _finish(DanceSurface c, Size s, _Look l, double dt) {
    final since = l.since;
    if (since != null && since >= 0 && since < 0.5) c.fill(Offset.zero & s, Colors.white.withValues(alpha: 0.4 * (1 - since * 2)));
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

/// What the dancers leave for the scene after them: every body's bones as segments
/// in the world (a joint to its parent), and the camera they were seen by. The flock
/// (show_flock.dart) seeds its birds along them and holds that camera for a bar, so
/// the dancer turns into birds where she stood. Fresh for a few seconds.
class DanceHandoff {
  const DanceHandoff._();
  static const _most = 12 * 32;

  /// x0 y0 z0 x1 y1 z1 per segment, [count] of them.
  static final segments = Float32List(_most * 6);
  static int count = 0;
  static V3 eye = const V3(0, -4, 1.2), target = const V3(0, 0, 1);
  static double fov = 0.62, roll = 0;
  static DateTime at = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get fresh => count > 0 && DateTime.now().difference(at) < const Duration(seconds: 3);

  static void note(List<(DanceBody, DanceSpot, double)> bodies, DanceRig rig, DanceCam cam) {
    var n = 0;
    for (final (b, _, _) in bodies) {
      for (var i = 0; i < rig.bones && n < _most; i++) {
        final p = rig.parent[i];
        if (p < 0) continue;
        final a = b.jointWorld(rig.names[i], 0), q = b.jointWorld(rig.names[p], 0);
        if (a == null || q == null) continue;
        final o = n * 6;
        segments[o] = a.x;
        segments[o + 1] = a.y;
        segments[o + 2] = a.z;
        segments[o + 3] = q.x;
        segments[o + 4] = q.y;
        segments[o + 5] = q.z;
        n++;
      }
      if (n >= _most) break;
    }
    if (n == 0) return;
    count = n;
    eye = cam.eye;
    target = cam.target;
    fov = cam.fov;
    roll = cam.roll;
    at = DateTime.now();
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
