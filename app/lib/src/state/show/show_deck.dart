// One deck, read for the show: where the record is on its own grid, what the analysis
// says of that bar, the pulse at the needle with this channel's mixer over it.
//
// A function of plain values rather than of a Deck, so a test can hand it a grid and
// a position and read the answer; the engine (show_engine.dart) reads the Deck and
// the Booth and calls this.
import 'dart:math' as math;
import 'dart:ui' show Color;

import '../../api/models.dart';
import '../../api/pulse.dart';
import '../booth/mixer.dart';
import 'show_state.dart';

/// What the mixer has this channel set to.
class ChannelSettings {
  const ChannelSettings({
    this.level = 1,
    this.eq = EqSet.flat,
    this.filter = 0,
    this.stems = StemLevels.all,
    this.looping = false,
  });

  /// This channel's share of the output, 0 to 1 (Booth.levels).
  final double level;
  final EqSet eq;

  /// -1 all the way low-pass, 1 all the way high-pass, 0 open.
  final double filter;
  final StemLevels stems;
  final bool looping;
}

/// A band's gain in decibels as a factor; the kill is nothing.
double gainOf(double db) => db <= EqSet.killed ? 0 : math.pow(10, db / 20).toDouble();

/// What a filter at [f] leaves of a band, 0 to 1, by where the band sits: the
/// low-pass (f < 0) takes the top first, the high-pass (f > 0) the bottom. [place]
/// is the band's place from 0 (sub) to 1 (air).
double filterLeaves(double f, double place) {
  if (f == 0) return 1;
  // How far the sweep has come, 0 to 1, and from which end.
  final sweep = f.abs();
  final fromTop = f < 0;
  // A band is gone once the sweep has passed it: the low-pass closing from the top
  // reaches the air first, the sub last; the high-pass the other way round.
  final reach = fromTop ? 1 - place : place;
  // A band is gone by the time the sweep reaches it, and going over the fifth of the
  // travel before that: a sweep moves through a band rather than switching it, and
  // a filter all the way shut leaves nothing.
  final gone = ((sweep - reach) / 0.2 + 1.0).clamp(0.0, 1.0);
  return 1 - gone;
}

/// The pulse at [at] through the channel: the EQ on its bands, the filter over them,
/// the stems' faders on the stems, and the channel's level over all of it.
ShowAudio audioThrough(Pulse? pulse, Duration at, ChannelSettings s) {
  if (pulse == null || s.level <= 0) return ShowAudio.silence;
  final low = gainOf(s.eq.low), mid = gainOf(s.eq.mid), high = gainOf(s.eq.high);
  double band(String name, double gain, double place) =>
      (pulse.at(name, at) * gain * filterLeaves(s.filter, place)).clamp(0.0, 1.0);
  return ShowAudio(
    sub: band('sub', low, 0.0),
    low: band('low', low, 0.25),
    mid: band('mid', mid, 0.5),
    high: band('high', high, 0.75),
    air: band('air', high, 1.0),
    // The kick is in the low band; the onsets are everywhere.
    kick: (pulse.peak('kick', at) * low * filterLeaves(s.filter, 0.1)).clamp(0.0, 1.0),
    onset: pulse.peak('onset', at).clamp(0.0, 1.0),
    drums: (pulse.at('drums', at) * s.stems.drums).clamp(0.0, 1.0),
    rest: (pulse.at('rest', at) * s.stems.rest).clamp(0.0, 1.0),
    vocals: (pulse.at('vocals', at) * s.stems.vocals).clamp(0.0, 1.0),
  ) * s.level;
}

/// The key as a hue round the wheel: Camelot's twelve positions, 1A at the top.
double? keyHueOf(String? camelot) {
  if (camelot == null || camelot.length < 2) return null;
  final n = int.tryParse(camelot.substring(0, camelot.length - 1));
  if (n == null) return null;
  return ((n - 1) % 12) / 12;
}

Color? colorOfHex(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'ff$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

/// The index of the last of [sorted] at or before [ms], or -1.
int _lastAtOrBefore(List<int> sorted, int ms) {
  var lo = 0, hi = sorted.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] <= ms) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/// Within how many beats a drop is looked for ahead, and how long after one it is
/// still "just dropped".
const dropLookaheadBeats = 64.0;
const dropHoldBeats = 2.0;

/// The deck as the show sees it, at [position] (the ear's, latency taken off).
ShowDeck deriveDeck({
  required String name,
  Track? track,
  String? coverUrl,
  required bool playing,
  required Duration position,
  TrackTiming? timing,
  VocalMap? vocals,
  Pulse? pulse,
  ChannelSettings channel = const ChannelSettings(),
}) {
  final ms = position.inMilliseconds;
  int? beatIndex, beatInBar, barIndex, phraseBar;
  double beatPhase = 0, barPhase = 0, phrasePhase = 0;
  double? bpm;
  String? section;
  double sectionK = 0, buildK = 0, energy = 0, vocal = 0, lyricK = 0;
  double? sectionBarsLeft, dropBeatsAway;
  bool breakdown = false, hook = false;
  String? lyric;

  if (timing != null && timing.hasBeats) {
    bpm = timing.gridBpm;
    final beat = timing.smoothBeatAt(position);
    if (beat != null) {
      beatIndex = beat.index;
      beatPhase = beat.phase;
      final fromOne = beat.index - timing.barStartsOn;
      beatInBar = ((fromOne % 4) + 4) % 4;
      barIndex = (fromOne / 4).floor();
      barPhase = (beatInBar + beat.phase) / 4;
      final place = timing.placeInPhrase(position);
      if (place != null) {
        phraseBar = place.bar;
        phrasePhase = ((place.bar + barPhase) / place.of).clamp(0.0, 1.0);
      }
      // The bar's energy, by the downbeat the needle is past.
      final downs = timing.downbeats;
      final e = timing.energy;
      final bar = _lastAtOrBefore(downs, ms);
      if (bar >= 0 && bar < e.length) energy = e[bar] / 255;
      final period = beat.period;

      // The section, from the structure where there is one.
      final s = timing.structure?.sectionAt(position);
      if (s != null) {
        section = s.label;
        final span = s.endMs - s.startMs;
        sectionK = span > 0 ? ((ms - s.startMs) / span).clamp(0.0, 1.0) : 0;
        sectionBarsLeft = (s.endMs - ms) / (4 * period);
        breakdown = s.label == 'breakdown' || s.label == 'break';
        if (s.label == 'build') buildK = sectionK;
      }

      // The next drop: the structure's where it has them (the drums coming back),
      // the energy curve's otherwise.
      final drops = timing.structure?.dropsMs.isNotEmpty == true
          ? timing.structure!.dropsMs
          : timing.drops;
      if (drops.isNotEmpty) {
        final hold = (dropHoldBeats * period).round();
        final i = _lastAtOrBefore(drops, ms + hold);
        // The one just passed, within the hold; else the next ahead.
        final at = i >= 0 && drops[i] >= ms - hold ? drops[i] : (i + 1 < drops.length ? drops[i + 1] : null);
        if (at != null) {
          final away = (at - ms) / period;
          if (away <= dropLookaheadBeats) dropBeatsAway = away;
        }
        if (dropBeatsAway != null && dropBeatsAway > 0 && dropBeatsAway <= 32 && section != 'build') {
          buildK = math.max(buildK, 1 - dropBeatsAway / 32);
        }
      }

      // The voice: its share of the bar, the line being sung, the hook.
      if (vocals != null && bar >= 0) {
        final v = vocals.bars;
        if (v != null && bar < v.length) vocal = v[bar] / 255;
        if (vocals.timed && vocals.lines.isNotEmpty) {
          final lines = vocals.lines;
          var li = -1;
          for (var k = 0; k < lines.length; k++) {
            final at = lines[k].ms;
            if (at != null && at <= ms) li = k;
            if (at != null && at > ms) break;
          }
          if (li >= 0) {
            lyric = lines[li].text;
            final from = lines[li].ms!;
            int? to;
            for (var k = li + 1; k < lines.length; k++) {
              if (lines[k].ms != null) {
                to = lines[k].ms;
                break;
              }
            }
            final span = (to ?? from + 4000) - from;
            lyricK = span > 0 ? ((ms - from) / span).clamp(0.0, 1.0) : 1;
          }
        }
        final h = vocals.hook;
        if (h != null) {
          final barMs = 4 * period;
          hook = h.at.any((t) => ms >= t && ms < t + barMs * 2);
        }
      }
    }
  }

  return ShowDeck(
    name: name,
    trackId: track?.id,
    title: track?.title,
    artist: track?.artists.isNotEmpty == true ? track!.artists.join(', ') : null,
    playing: playing,
    position: position,
    bpm: bpm,
    beatIndex: beatIndex,
    beatPhase: beatPhase,
    beatInBar: beatInBar,
    barIndex: barIndex,
    barPhase: barPhase,
    phraseBar: phraseBar,
    phrasePhase: phrasePhase,
    section: section,
    sectionK: sectionK,
    sectionBarsLeft: sectionBarsLeft,
    dropBeatsAway: dropBeatsAway,
    breakdown: breakdown,
    buildK: buildK,
    energy: energy,
    vocal: vocal,
    lyric: lyric,
    lyricK: lyricK,
    hook: hook,
    key: timing?.key,
    camelot: timing?.camelot,
    keyHue: keyHueOf(timing?.camelot),
    coverColor: colorOfHex(track?.coverColor),
    coverUrl: coverUrl,
    level: channel.level,
    eqLow: gainOf(channel.eq.low),
    eqMid: gainOf(channel.eq.mid),
    eqHigh: gainOf(channel.eq.high),
    filter: channel.filter,
    stemDrums: channel.stems.drums,
    stemRest: channel.stems.rest,
    stemVocals: channel.stems.vocals,
    looping: channel.looping,
    audio: playing ? audioThrough(pulse, position, channel) : ShowAudio.silence,
  );
}
