import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/show/show_words.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    test('the same record and slot pick the same face; another slot may not', () {
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

    test('faces switched off are passed by', () {
      for (var i = 0; i < 20; i++) {
        expect(WordsClock.style('chorus', 0.5, 2, i, off: [WordsStyle.marker, WordsStyle.serif]), isIn([WordsStyle.poster, WordsStyle.grotesk]));
      }
      // Every one off: any.
      expect(WordsStyle.values, contains(WordsClock.style('chorus', 0.5, 2, 1, off: WordsStyle.values)));
    });
  });

  group('the shader', () {
    test('its floats are the ones WordsParams names, in its order', () {
      final src = File('shaders/show/sim/words_fx.frag').readAsStringSync();
      final decl = RegExp(r'uniform\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;');
      final inFile = [
        for (final m in decl.allMatches(src)) (m.group(2)!, switch (m.group(1)) { 'float' => 1, 'vec2' => 2, 'vec3' => 3, _ => 4 })
      ];
      expect(inFile, WordsParams.uniforms);
      expect(WordsParams.length, inFile.fold(0, (a, u) => a + u.$2));
      expect(WordsParams.at['uResolution'], 0);
      expect(WordsParams.at['uPremul'], WordsParams.length - 1);
      // The pictures, as the native stage binds them by name (words.t0, words.t1).
      expect(RegExp(r'uniform\s+sampler2D\s+(\w+)\s*;').allMatches(src).map((m) => m.group(1)).toList(), ['uT0', 'uT1']);
    });
  });

  group('setting a line', () {
    LyricLineOn line(String text) => LyricLineOn(text, 1, atSeconds: 0, atBeats: 0);

    test('every face sets a line within the stage, in its rows, and its picture is sized to the block', () {
      for (final style in WordsStyle.values) {
        final set = layoutWords(line('hold the night a little longer than it wants to be held'), style, 1280, 720, slot: 1);
        addTearDown(set.dispose);
        expect(set.rect.left, greaterThanOrEqualTo(-0.01), reason: style.name);
        expect(set.rect.right, lessThanOrEqualTo(1.01), reason: style.name);
        expect(set.rect.top, greaterThanOrEqualTo(-0.05), reason: style.name);
        expect(set.rect.bottom, lessThanOrEqualTo(1.05), reason: style.name);
        expect(set.rows, inInclusiveRange(1, 6), reason: style.name);
        expect(set.image.width, closeTo(set.rect.width * 1280, 1.5), reason: style.name);
        expect(set.image.height, closeTo(set.rect.height * 720, 1.5), reason: style.name);
        expect(set.slot, 1);
        expect(set.texName, 'words.t1');
      }
    });

    test('a word alone fills a row; a wide face stacks every word', () {
      final one = layoutWords(line('gone'), WordsStyle.poster, 1280, 720);
      addTearDown(one.dispose);
      expect(one.rows, 1);
      expect(one.rect.width, greaterThan(0.2));
      final stack = layoutWords(line('every window open'), WordsStyle.wide, 1280, 720);
      addTearDown(stack.dispose);
      expect(stack.rows, 3);
      expect(stack.rect.width, closeTo(0.9 + 2 * 0.04 * 720 / 1280, 0.01));
    });
  });
}
