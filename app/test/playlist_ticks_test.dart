// The tick-boxes in the add-to-playlist sheet: what they say, and what they write.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/playlist_ticks.dart';

void main() {
  test('a list with all of them is ticked, with some of them is the third state', () {
    final ticks = PlaylistTicks(songs: 3)..held = {1: 3, 2: 1};
    expect(ticks.stateOf(1), isTrue);
    expect(ticks.stateOf(2), isNull);
    expect(ticks.stateOf(3), isFalse, reason: 'a list not in the answer holds none');
  });

  test('nothing is written for a list nobody touched', () {
    final ticks = PlaylistTicks(songs: 2)..held = {1: 2, 2: 0};
    expect(ticks.plan([1, 2]).add, isEmpty);
    expect(ticks.plan([1, 2]).remove, isEmpty);
    expect(ticks.changes([1, 2]), 0);
  });

  test('ticking adds, unticking a list that had them takes them off', () {
    final ticks = PlaylistTicks(songs: 2)..held = {1: 2};
    ticks.toggle(2);
    ticks.toggle(1);
    final plan = ticks.plan([1, 2]);
    expect(plan.add, [2]);
    expect(plan.remove, [1]);
  });

  test('a tap over and back writes nothing', () {
    final ticks = PlaylistTicks(songs: 1)..held = {};
    ticks.toggle(7);
    ticks.toggle(7);
    expect(ticks.changes([7]), 0, reason: 'back where it started is not a change');
  });

  test('a partly filled list fills up rather than emptying', () {
    final ticks = PlaylistTicks(songs: 4)..held = {5: 2};
    ticks.toggle(5);
    expect(ticks.stateOf(5), isTrue);
    expect(ticks.plan([5]).add, [5]);
    expect(ticks.plan([5]).remove, isEmpty);
  });

  test('emptying a partly filled list takes two taps, and says so on the way', () {
    final ticks = PlaylistTicks(songs: 4)..held = {5: 2};
    ticks.toggle(5);
    ticks.toggle(5);
    expect(ticks.stateOf(5), isFalse);
    expect(ticks.plan([5]).remove, [5], reason: 'it did hold some of them');
  });
}
