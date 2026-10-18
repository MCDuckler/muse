import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/show/show_words.dart';

void main() {
  group('the score', () {
    test('a new line comes with the words, and the same words started again', () {
      final s = LyricScore();
      s.feed(lyric: null, k: 0, hook: false, dt: 0.1, seconds: 0, beats: 0);
      expect(s.current, isNull);
      s.feed(lyric: 'you came in with the lights', k: 0, hook: false, dt: 0.1, seconds: 0.1, beats: 0.2);
      expect(s.current?.text, 'you came in with the lights');
      expect(s.lines.length, 1);
      // The same text, the clock running on: the same line.
      s.feed(lyric: 'you came in with the lights', k: 0.3, hook: false, dt: 0.5, seconds: 0.6, beats: 1.2);
      expect(s.lines.length, 1);
      // The same text, the clock back at nought: a chorus's line again.
      s.feed(lyric: 'you came in with the lights', k: 0.0, hook: false, dt: 0.5, seconds: 1.1, beats: 2.2);
      expect(s.lines.length, 2);
      expect(s.previous?.text, 'you came in with the lights');
      // Other words: another line; the old ones kept, up to eight.
      for (var i = 0; i < 10; i++) {
        s.feed(lyric: 'line $i', k: 0, hook: i == 3, dt: 0.5, seconds: 2 + i.toDouble(), beats: 4 + i * 2.0);
      }
      expect(s.lines.length, LyricScore.keep);
      expect(s.current?.text, 'line 9');
      expect(s.lines.where((l) => l.hook).map((l) => l.text), ['line 3']);
    });

    test('the reveal grows with the time the words take, and the words are counted off', () {
      final s = LyricScore();
      s.feed(lyric: 'this is where we meet', k: 0, hook: false, dt: 0, seconds: 0, beats: 0);
      final l = s.current!;
      expect(l.words, ['this', 'is', 'where', 'we', 'meet']);
      expect(l.span, closeTo(0.55 + 0.34 * 5, 1e-9));
      expect(l.reveal, 0);
      expect(l.wordOn, 0);
      final seen = <int>{};
      var pops = 0;
      var was = l.wordOn;
      for (var i = 1; i <= 60; i++) {
        s.feed(lyric: 'this is where we meet', k: i / 100, hook: false, dt: 0.05, seconds: i * 0.05, beats: i * 0.1);
        seen.add(l.wordOn);
        if (l.wordOn != was) pops++;
        was = l.wordOn;
        expect(l.reveal, inInclusiveRange(0.0, 1.0));
      }
      // Three seconds in, a two-and-a-quarter-second line is sung: every word seen,
      // in order, each with a pop.
      expect(l.reveal, 1);
      expect(seen, {0, 1, 2, 3, 4});
      expect(pops, 4);
      expect(l.wordAt.every((t) => t >= 0), isTrue);
    });

    test('the lyric clock shortens a line it says is quick', () {
      final s = LyricScore();
      // Ten words would take four seconds by the count; the clock runs the line in one.
      const text = 'one two three four five six seven eight nine ten';
      s.feed(lyric: text, k: 0, hook: false, dt: 0, seconds: 0, beats: 0);
      for (var i = 1; i <= 10; i++) {
        s.feed(lyric: text, k: i / 10, hook: false, dt: 0.1, seconds: i * 0.1, beats: i * 0.2);
      }
      expect(s.current!.reveal, greaterThan(0.9));
    });

    test('a line that is long gone is stale; another record clears the score', () {
      final s = LyricScore();
      s.feed(lyric: 'hey', k: 0, hook: false, dt: 0, seconds: 0, beats: 0);
      expect(s.stale, isFalse);
      s.feed(lyric: null, k: 0, hook: false, dt: 30, seconds: 30, beats: 60);
      expect(s.stale, isTrue);
      s.clear();
      expect(s.current, isNull);
      expect(s.stale, isTrue);
    });
  });

  group('the clock', () {
    test('the same record and slot pick the same style; another slot may not', () {
      final a = WordsClock.style('verse', 0.5, 7, 3);
      final b = WordsClock.style('verse', 0.5, 7, 3);
      expect(a, b);
      final picks = {for (var i = 0; i < 40; i++) WordsClock.style('verse', 0.5, 7, i)};
      expect(picks.length, greaterThan(1));
      expect(picks.every(WordsClock.mid.contains), isTrue);
    });

    test('a breakdown is calm, a drop is hot, and the one on is not picked again', () {
      for (var i = 0; i < 20; i++) {
        expect(WordsClock.calm, contains(WordsClock.style('verse', 0.6, 1, i, breakdown: true)));
        expect(WordsClock.hot, contains(WordsClock.style('drop', 0.9, 1, i)));
        expect(WordsClock.style('chorus', 0.5, 1, i, not: WordsStyle.poster), isNot(WordsStyle.poster));
      }
    });

    test('styles switched off are passed by', () {
      for (var i = 0; i < 20; i++) {
        expect(WordsClock.style('chorus', 0.5, 2, i, off: [WordsStyle.stencil, WordsStyle.ribbon]), isIn([WordsStyle.poster, WordsStyle.kinetic]));
      }
      // Every one off: any.
      expect(WordsStyle.values, contains(WordsClock.style('chorus', 0.5, 2, 1, off: WordsStyle.values)));
    });
  });

  group('the stencil rows', () {
    test('the words are packed into rows of about the same length, in order', () {
      final rows = WordsSim.packRows('nothing left to learn tonight my friend'.split(' '), 3);
      expect(rows.length, 3);
      expect(rows.expand((r) => r).join(' '), 'nothing left to learn tonight my friend');
      final lens = [for (final r in rows) r.join(' ').length];
      expect(lens.reduce((a, b) => a > b ? a : b) - lens.reduce((a, b) => a < b ? a : b), lessThan(10));
    });

    test('fewer words than rows: a row a word; none: nothing', () {
      expect(WordsSim.packRows(['oh'], 3), [['oh']]);
      expect(WordsSim.packRows(const [], 2), isEmpty);
    });
  });
}
