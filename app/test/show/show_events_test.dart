// The moments between two frames: a beat, the bar, the phrase, a section turning, a
// drop, a mix — and the things that are not moments: a seek, a frame skipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_state.dart';

ShowDeck deck({
  int? trackId = 1,
  bool playing = true,
  int? beat,
  int? inBar,
  int? bar,
  int? phraseBar,
  String? section,
  bool breakdown = false,
  double? drop,
}) =>
    ShowDeck(
      name: 'A',
      trackId: trackId,
      playing: playing,
      beatIndex: beat,
      beatInBar: inBar,
      barIndex: bar,
      phraseBar: phraseBar,
      section: section,
      breakdown: breakdown,
      dropBeatsAway: drop,
    );

ShowState frame(ShowDeck a, {ShowMix mix = ShowMix.none}) =>
    ShowState(now: DateTime(2026, 1, 1), a: a, b: const ShowDeck(name: 'B'), mix: mix);

List<ShowEventKind> kinds(ShowState? prev, ShowState next) =>
    [for (final e in eventsBetween(prev, next)) e.kind];

void main() {
  test('a beat, then the bar and the phrase on the one', () {
    final was = frame(deck(beat: 3, inBar: 3, bar: 0, phraseBar: 0));
    final now = frame(deck(beat: 4, inBar: 0, bar: 1, phraseBar: 1));
    expect(kinds(was, now), [ShowEventKind.beat, ShowEventKind.bar]);
    final phrase = frame(deck(beat: 16, inBar: 0, bar: 4, phraseBar: 0));
    final before = frame(deck(beat: 15, inBar: 3, bar: 3, phraseBar: 3));
    expect(kinds(before, phrase), [ShowEventKind.beat, ShowEventKind.bar, ShowEventKind.phrase]);
    final e = eventsBetween(before, phrase).first;
    expect(e.deck, 'A');
    expect(e.data['one'], isTrue);
    expect(e.onMaster, isTrue);
  });

  test('the same beat twice is nothing; a seek back is nothing; a long jump is nothing', () {
    final a = frame(deck(beat: 4, inBar: 0));
    expect(kinds(a, frame(deck(beat: 4, inBar: 0))), isEmpty);
    expect(kinds(a, frame(deck(beat: 1, inBar: 1))), isEmpty);
    expect(kinds(a, frame(deck(beat: 40, inBar: 0))), isEmpty);
  });

  test('a record put on, started, stopped', () {
    expect(kinds(frame(deck(trackId: null, playing: false)), frame(deck(trackId: 1, playing: false))),
        [ShowEventKind.loaded]);
    expect(kinds(frame(deck(playing: false)), frame(deck(playing: true))), [ShowEventKind.play]);
    expect(kinds(frame(deck(playing: true, beat: 4)), frame(deck(playing: false, beat: 4))), [ShowEventKind.pause]);
    // The first frame of all: a record is there.
    expect(kinds(null, frame(deck(beat: 4, inBar: 0))), [ShowEventKind.loaded]);
  });

  test('the section turning, and a breakdown beginning', () {
    final was = frame(deck(beat: 31, inBar: 3, section: 'drop'));
    final now = frame(deck(beat: 32, inBar: 0, section: 'breakdown', breakdown: true));
    final got = eventsBetween(was, now);
    expect([for (final e in got) e.kind],
        [ShowEventKind.beat, ShowEventKind.bar, ShowEventKind.section, ShowEventKind.breakdown]);
    final s = got.firstWhere((e) => e.kind == ShowEventKind.section);
    expect(s.data['label'], 'breakdown');
    expect(s.data['from'], 'drop');
  });

  test('the drop: beats away through nought', () {
    expect(kinds(frame(deck(beat: 1, drop: 0.3)), frame(deck(beat: 1, drop: -0.1))), [ShowEventKind.drop]);
    // Not when it was already past, or when the next drop simply came into range.
    expect(kinds(frame(deck(beat: 1, drop: -0.1)), frame(deck(beat: 1, drop: -0.4))), isEmpty);
    expect(kinds(frame(deck(beat: 1, drop: null)), frame(deck(beat: 1, drop: 60))), isEmpty);
    expect(kinds(frame(deck(beat: 1, drop: 60)), frame(deck(beat: 1, drop: -0.4))), isEmpty);
  });

  test('a mix armed, started, done', () {
    final d = deck(beat: 1);
    const armed = ShowMix(armed: true, kind: 'blend', from: 'A', to: 'B', startsIn: Duration(seconds: 2));
    const on = ShowMix(on: true, kind: 'blend', from: 'A', to: 'B', bars: 16, k: 0.1);
    expect(kinds(frame(d), frame(d, mix: armed)), [ShowEventKind.mixArmed]);
    expect(kinds(frame(d, mix: armed), frame(d, mix: on)), [ShowEventKind.mixStart]);
    expect(kinds(frame(d, mix: on), frame(d)), [ShowEventKind.mixEnd]);
    final end = eventsBetween(frame(d, mix: on), frame(d)).single;
    expect(end.data['to'], 'B');
  });

  test('an event goes to JSON and back', () {
    final e = ShowEvent(ShowEventKind.drop, DateTime.fromMillisecondsSinceEpoch(1234), deck: 'B', data: {'master': true});
    final back = ShowEvent.fromJson(e.toJson());
    expect(back.kind, ShowEventKind.drop);
    expect(back.deck, 'B');
    expect(back.onMaster, isTrue);
    expect(back.at.millisecondsSinceEpoch, 1234);
  });
}
