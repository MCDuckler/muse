// The datamosh played by the music (mosh_clock.dart): off but where the effect is the
// datamosh; a few patches let through on each bar; a key frame on the drop and every
// so many bars, closer through a build, each beat of its last bar; never too long
// without one; a slow smooth melt in a breakdown, the hardest and blockiest just
// after the drop; a snare's burst of grain; the knobs move it all.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/mosh_clock.dart';
import 'package:muse/src/state/show/show_combos.dart' show Fx;
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';

/// A record at 120 (a beat half a second, a bar two), played a frame at a time (60 a
/// second): its section as [sectionAt] says, by the bar.
class _Record {
  _Record(this.sectionAt, {this.buildK, this.dropAway});
  final String? Function(int bar) sectionAt;
  final double Function(int bar, double barPhase)? buildK;
  final double? Function(int bar, int beatInBar)? dropAway;
  double t = 0;

  ShowState frame({double snare = 0}) {
    t += 1 / 60;
    final beat = (t / 0.5).floor();
    final bar = beat ~/ 4;
    final barPhase = (t % 2) / 2;
    return ShowState(
      now: DateTime(2026).add(Duration(microseconds: (t * 1e6).round())),
      dt: 1 / 60,
      a: ShowDeck(
        name: 'A',
        playing: true,
        bpm: 120,
        beatIndex: beat,
        barIndex: bar,
        beatInBar: beat % 4,
        phraseBar: bar % 8,
        section: sectionAt(bar),
        buildK: buildK?.call(bar, barPhase) ?? 0,
        dropBeatsAway: dropAway?.call(bar, beat % 4),
        level: 1,
      ),
      b: const ShowDeck(name: 'B'),
      dyn: {'dyn.hit.snare': snare},
    );
  }
}

final _mosh = TransformSet.standard.of(Fx.mosh);

/// [seconds] of [r] through [c]: every frame's numbers.
List<MoshDrive> _play(MoshClock c, _Record r, double seconds, {RigTransform? t}) => [for (var i = 0; i < seconds * 60; i++) c.frame(r.frame(), t ?? _mosh)];

void main() {
  test('off but under the datamosh; on, it takes the picture as it is (no key frame)', () {
    final c = MoshClock();
    final r = _Record((_) => 'verse');
    expect(c.frame(r.frame(), TransformSet.standard.of(Fx.kaleidoscope)).on, isFalse);
    final first = c.frame(r.frame(), _mosh);
    expect(first.on, isTrue);
    expect(first.keys, 0);
  });

  test('a verse: patches on the bars, a key frame every eight bars, all smear between', () {
    final c = MoshClock();
    final d = _play(c, _Record((_) => 'verse'), 40);
    // Bars every two seconds: the heal pulses on them, and falls back between.
    final heals = [for (final x in d) x.heal];
    final most = heals.reduce((a, b) => a > b ? a : b), least = heals.reduce((a, b) => a < b ? a : b);
    expect(most, greaterThan(0.4));
    expect(least, lessThan(0.25));
    // Forty seconds, twenty bars: two key frames (every eight bars).
    expect(d.last.keys, 2);
    expect(d.every((x) => x.heal < 0.9), isTrue);
  });

  test('a build: the key frames closer as it climbs, then each beat of its last bar', () {
    final c = MoshClock();
    // Sixteen bars of build, the last bar four beats from the drop.
    final r = _Record((_) => 'build', buildK: (bar, p) => ((bar + p) / 16).clamp(0.0, 1.0), dropAway: (bar, beat) => bar == 15 ? (4 - beat).toDouble() : 99);
    final first = _play(c, r, 16);
    final second = _play(c, r, 14);
    final last = _play(c, r, 2);
    final early = first.last.keys;
    final late = second.last.keys - early;
    expect(late, greaterThan(early), reason: 'one every bar late in the build, every two early');
    expect(last.last.keys - second.last.keys, greaterThanOrEqualTo(3), reason: 'each beat of the last bar');
    // The grain and the drag rise with it.
    expect(last.last.grain, greaterThan(first.first.grain));
    expect(last.last.strength, greaterThan(first.first.strength));
  });

  test('the drop: whole on it, then the hardest and blockiest, then easing', () {
    final c = MoshClock();
    final r = _Record((bar) => bar < 4 ? 'build' : 'drop');
    final before = _play(c, r, 7.9);
    final onDrop = _play(c, r, 0.2);
    expect(onDrop.last.keys, greaterThan(before.last.keys), reason: 'a key frame on the drop');
    final hard = _play(c, r, 2);
    expect(hard.last.grain, greaterThan(0.8));
    expect(hard.last.strength, greaterThan(1.5));
    final after = _play(c, r, 10);
    expect(after.last.strength, lessThan(hard.last.strength), reason: 'four bars, then easing');
  });

  test('a breakdown: a slow smooth melt, whole as it comes', () {
    final c = MoshClock();
    final r = _Record((bar) => bar < 2 ? 'verse' : 'breakdown');
    final verse = _play(c, r, 3.9);
    final melt = _play(c, r, 6);
    expect(melt[30].keys, greaterThan(verse.last.keys), reason: 'whole as the breakdown comes');
    expect(melt.last.grain, lessThan(verse.last.grain));
    expect(melt.last.strength, lessThan(verse.last.strength));
  });

  test('a snare: a burst of grain; the knobs move it all; never too long without a key frame', () {
    final c = MoshClock();
    final r = _Record((_) => 'verse');
    final quiet = c.frame(r.frame(), _mosh);
    final hit = c.frame(r.frame(snare: 1), _mosh);
    expect(hit.grain, greaterThan(quiet.grain));
    // Less grain, more melt (longer smears: less healed between the pulses).
    final smooth = MoshClock();
    final r2 = _Record((_) => 'verse');
    final soft = _play(smooth, r2, 1, t: const TransformSet(grain: 0.1, melt: 1).of(Fx.mosh));
    expect(soft.last.grain, lessThan(quiet.grain));
    expect(soft.last.heal, lessThan(quiet.heal));
    // A record with no grid and a long calm: bars by the clock, a key frame by the
    // longest wait at the latest.
    final lone = MoshClock();
    var t = 0.0;
    var keys = 0;
    for (var i = 0; i < 60 * 70; i++) {
      t += 1 / 60;
      keys = lone
          .frame(ShowState(now: DateTime(2026).add(Duration(milliseconds: (t * 1000).round())), dt: 1 / 60, a: const ShowDeck(name: 'A', section: 'intro'), b: const ShowDeck(name: 'B')), _mosh)
          .keys;
    }
    expect(keys, greaterThanOrEqualTo(2));
  });
}
