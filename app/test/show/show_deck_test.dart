// One deck read for the show: the beat and the bar off the grid, the section and
// the drop off the structure, the voice off the vocal map, and the pulse through
// the channel's EQ and filter.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/api/pulse.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_deck.dart';

/// 120 BPM, a beat every 500 ms, the bar on beat 0, for a minute; energy rising bar
/// by bar; a structure with an intro, a build and a drop at 16 s; a drop at 48 s too.
TrackTiming record({int barStartsOn = 0}) {
  final beats = [for (var t = 0; t < 60000; t += 500) t];
  final downs = [for (var i = barStartsOn; i < beats.length; i += 4) beats[i]];
  return TrackTiming(
    durationMs: 60000,
    bpm: 120,
    beats: beats,
    barStartsOn: barStartsOn,
    downbeats: downs,
    energy: [for (var i = 0; i < downs.length - 1; i++) (i * 255 / (downs.length - 2)).round().clamp(0, 255)],
    fourBars: [for (var i = 0; i < downs.length; i += 4) downs[i]],
    drops: const [16000, 48000],
    camelot: '8A',
    key: 'A minor',
    structure: const TrackStructure(
      barsMs: [],
      sections: [
        TrackSection(label: 'intro', startBar: 0, endBar: 4, startMs: 0, endMs: 8000, drums: false, vocals: false, energyDb: -20),
        TrackSection(label: 'build', startBar: 4, endBar: 8, startMs: 8000, endMs: 16000, drums: false, vocals: false, energyDb: -14),
        TrackSection(label: 'drop', startBar: 8, endBar: 16, startMs: 16000, endMs: 32000, drums: true, vocals: false, energyDb: -8),
        TrackSection(label: 'breakdown', startBar: 16, endBar: 24, startMs: 32000, endMs: 48000, drums: false, vocals: true, energyDb: -16),
        TrackSection(label: 'drop', startBar: 24, endBar: 30, startMs: 48000, endMs: 60000, drums: true, vocals: false, energyDb: -8),
      ],
      dropsMs: [16000, 48000],
      breakdownsMs: [32000],
    ),
  );
}

Track song() => Track.fromJson({
      'id': 7,
      'title': 'Song',
      'artists': ['Someone', 'Else'],
      'duration_ms': 60000,
      'state': 'ready',
      'stream_url': '/tracks/7/stream',
      'source': 'youtube',
      'cover_color': '#ff4000',
    });

/// A pulse that is flat 200 in every band, with a kick of 255 on every beat.
Pulse flatPulse() {
  final n = 50 * 60;
  Uint8List flat(int v) => Uint8List(n)..fillRange(0, n, v);
  final kick = Uint8List(n);
  for (var i = 0; i < n; i += 25) {
    kick[i] = 255;
  }
  return Pulse(hz: 50, n: n, channels: {
    'sub': flat(200), 'low': flat(200), 'mid': flat(200), 'high': flat(200), 'air': flat(200),
    'kick': kick, 'onset': flat(0),
  });
}

void main() {
  group('the grid', () {
    test('beat, bar and phrase at two seconds', () {
      final d = deriveDeck(name: 'A', track: song(), playing: true, position: const Duration(seconds: 2), timing: record());
      expect(d.beatIndex, 4);
      expect(d.beatInBar, 0);
      expect(d.beatPhase, closeTo(0, 1e-6));
      expect(d.barIndex, 1);
      expect(d.barPhase, closeTo(0, 1e-6));
      expect(d.phraseBar, 1);
      expect(d.phrasePhase, closeTo(0.25, 1e-6));
      expect(d.bpm, closeTo(120, 0.01));
      expect(d.onBeatOne, isTrue);
    });

    test('half way through the third beat of a bar', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(milliseconds: 3250), timing: record());
      expect(d.beatIndex, 6);
      expect(d.beatInBar, 2);
      expect(d.beatPhase, closeTo(0.5, 1e-6));
      expect(d.barPhase, closeTo((2 + 0.5) / 4, 1e-6));
    });

    test('the bar starting on beat 2 of the grid', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 3), timing: record(barStartsOn: 2));
      expect(d.beatIndex, 6);
      expect(d.beatInBar, 0);
      expect(d.barIndex, 1);
    });

    test('no grid: nothing on the beat, still a deck', () {
      final d = deriveDeck(name: 'B', track: song(), playing: true, position: const Duration(seconds: 3));
      expect(d.beatIndex, isNull);
      expect(d.title, 'Song');
      expect(d.artist, 'Someone, Else');
      expect(d.coverColor, isNotNull);
    });
  });

  group('the structure', () {
    test('the section, how far through, bars left', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 12), timing: record());
      expect(d.section, 'build');
      expect(d.sectionK, closeTo(0.5, 1e-6));
      expect(d.sectionBarsLeft, closeTo(2, 1e-6));
      expect(d.buildK, closeTo(0.5, 1e-6));
      expect(d.breakdown, isFalse);
    });

    test('the drop ahead, in beats', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 12), timing: record());
      expect(d.dropBeatsAway, closeTo(8, 1e-6));
    });

    test('just after the drop it is still the drop', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(milliseconds: 16300), timing: record());
      expect(d.dropBeatsAway, closeTo(-0.6, 1e-6));
      expect(d.section, 'drop');
    });

    test('a drop too far ahead is not one', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 1), timing: record());
      // 16 s away at 500 ms a beat is 30 beats: within the look-ahead.
      expect(d.dropBeatsAway, closeTo(30, 1e-6));
      // 48 s away from 17.5 s is 61 beats: within; the one at 16 s is three beats
      // gone, past the hold.
      final later = deriveDeck(name: 'A', playing: true, position: const Duration(milliseconds: 17500), timing: record());
      expect(later.dropBeatsAway, closeTo(61, 1e-6));
      // From 2 s the second drop is 92 beats off: not one yet, the first is.
      final early = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 2), timing: record());
      expect(early.dropBeatsAway, closeTo(28, 1e-6));
      final far = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 16, milliseconds: 100), timing: record());
      expect(far.dropBeatsAway, closeTo(-0.2, 1e-6));
    });

    test('a breakdown', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 40), timing: record());
      expect(d.section, 'breakdown');
      expect(d.breakdown, isTrue);
      // The build towards the next drop where none is labelled: 16 beats away of 32.
      expect(d.buildK, closeTo(0.5, 1e-6));
    });

    test('the energy of the bar', () {
      final first = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 1), timing: record());
      final last = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 57), timing: record());
      expect(first.energy, 0);
      expect(last.energy, closeTo(1, 0.02));
    });

    test('the key as a hue', () {
      final d = deriveDeck(name: 'A', playing: true, position: Duration.zero, timing: record());
      expect(d.camelot, '8A');
      expect(d.keyHue, closeTo(7 / 12, 1e-9));
      expect(keyHueOf('1A'), 0);
      expect(keyHueOf('12B'), closeTo(11 / 12, 1e-9));
      expect(keyHueOf(null), isNull);
    });
  });

  group('the voice', () {
    final words = VocalMap(
      bars: [for (var i = 0; i < 30; i++) i >= 16 && i < 24 ? 200 : 20],
      timed: true,
      lines: const [(ms: 32000, text: 'first line'), (ms: 34000, text: 'second line'), (ms: null, text: 'untimed')],
      hook: const (text: 'the hook', at: [36000]),
    );

    test('sung bars, the line, the hook', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 33), timing: record(), vocals: words);
      expect(d.vocal, closeTo(200 / 255, 1e-6));
      expect(d.lyric, 'first line');
      expect(d.lyricK, closeTo(0.5, 1e-6));
      expect(d.hook, isFalse);
      final h = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 37), timing: record(), vocals: words);
      expect(h.hook, isTrue);
      expect(h.lyric, 'second line');
    });

    test('nothing sung in the drop', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 20), timing: record(), vocals: words);
      expect(d.vocal, closeTo(20 / 255, 1e-6));
      expect(d.lyric, isNull);
    });
  });

  group('the channel over the pulse', () {
    test('flat: the bands as they are, the kick on the beat', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 2), timing: record(), pulse: flatPulse());
      expect(d.audio.low, closeTo(200 / 255, 1e-6));
      expect(d.audio.air, closeTo(200 / 255, 1e-6));
      expect(d.audio.kick, closeTo(1, 1e-6));
      final off = deriveDeck(name: 'A', playing: true, position: const Duration(milliseconds: 2250), timing: record(), pulse: flatPulse());
      expect(off.audio.kick, 0);
    });

    test('the bass killed: no sub, no low, no kick; the top untouched', () {
      final d = deriveDeck(
        name: 'A',
        playing: true,
        position: const Duration(seconds: 2),
        timing: record(),
        pulse: flatPulse(),
        channel: const ChannelSettings(eq: EqSet(low: EqSet.killed)),
      );
      expect(d.audio.sub, 0);
      expect(d.audio.low, 0);
      expect(d.audio.kick, 0);
      expect(d.audio.high, closeTo(200 / 255, 1e-6));
      expect(d.eqLow, 0);
      expect(d.eqHigh, 1);
    });

    test('a low-pass sweep takes the air first and the sub last', () {
      final half = deriveDeck(
        name: 'A', playing: true, position: const Duration(seconds: 2), timing: record(), pulse: flatPulse(),
        channel: const ChannelSettings(filter: -0.5),
      );
      expect(half.audio.air, 0);
      expect(half.audio.sub, closeTo(200 / 255, 1e-6));
      expect(half.audio.mid, lessThan(half.audio.low));
      final shut = deriveDeck(
        name: 'A', playing: true, position: const Duration(seconds: 2), timing: record(), pulse: flatPulse(),
        channel: const ChannelSettings(filter: -1),
      );
      expect(shut.audio.level, lessThan(0.2));
    });

    test('the fader scales it all, and a parked deck is silent', () {
      final d = deriveDeck(
        name: 'A', playing: true, position: const Duration(seconds: 2), timing: record(), pulse: flatPulse(),
        channel: const ChannelSettings(level: 0.5),
      );
      expect(d.audio.low, closeTo(100 / 255, 1e-6));
      final parked = deriveDeck(name: 'A', playing: false, position: const Duration(seconds: 2), timing: record(), pulse: flatPulse());
      expect(parked.audio.level, 0);
    });

    test('no pulse: silence, the rest still read', () {
      final d = deriveDeck(name: 'A', playing: true, position: const Duration(seconds: 2), timing: record());
      expect(d.audio.level, 0);
      expect(d.beatIndex, 4);
    });
  });

  test('the flat names a scene binds to', () {
    final d = deriveDeck(name: 'A', track: song(), playing: true, position: const Duration(seconds: 12), timing: record(), pulse: flatPulse());
    final m = <String, double>{};
    d.flatInto(m, 'master');
    expect(m['master.beat.phase'], closeTo(0, 1e-6));
    expect(m['master.drop.beatsAway'], closeTo(8, 1e-6));
    expect(m['master.drop.near'], closeTo(0.75, 1e-6));
    expect(m['master.build.k'], closeTo(0.5, 1e-6));
    expect(m['master.audio.low'], closeTo(200 / 255, 1e-6));
    expect(m['master.key.hue'], closeTo(7 / 12, 1e-6));
  });
}
