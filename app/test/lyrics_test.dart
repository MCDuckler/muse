import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/lyrics_sheet.dart';

void main() {
  group('parsing LRC', () {
    test('reads timestamps and text', () {
      final lines = parseLrc('[00:12.50]First line\n[01:05.00]Second line');
      expect(lines.length, 2);
      expect(lines.first.at, const Duration(seconds: 12, milliseconds: 500));
      expect(lines.first.text, 'First line');
      expect(lines.last.at, const Duration(minutes: 1, seconds: 5));
    });

    test('a line repeated at several times appears at each of them', () {
      // Choruses are written this way, and dropping the repeats loses most of a song.
      final lines = parseLrc('[00:30.00][01:30.00][02:30.00]Chorus');
      expect(lines.length, 3);
      expect(lines.map((l) => l.text).toSet(), {'Chorus'});
      expect(lines[1].at, const Duration(minutes: 1, seconds: 30));
    });

    test('output is sorted even when the file is not', () {
      final lines = parseLrc('[02:00.00]Later\n[00:10.00]Earlier');
      expect(lines.map((l) => l.text).toList(), ['Earlier', 'Later']);
    });

    test('metadata headers and empty timestamps are skipped', () {
      final lines = parseLrc('[ar:Someone]\n[00:05.00]\n[00:08.00]Real words');
      expect(lines.length, 1);
      expect(lines.single.text, 'Real words');
    });

    test('two-digit fractions are hundredths, not milliseconds', () {
      expect(parseLrc('[00:01.50]x').single.at,
          const Duration(seconds: 1, milliseconds: 500));
    });

    test('a missing fraction is fine', () {
      expect(parseLrc('[01:02]x').single.at, const Duration(minutes: 1, seconds: 2));
    });

    test('plain text with no timestamps yields nothing to sync', () {
      expect(parseLrc('just some words\nand more'), isEmpty);
    });
  });

  group('following along', () {
    final lines = parseLrc('[00:00.00]One\n[00:10.00]Two\n[00:20.00]Three');

    test('before the first line, nothing is highlighted', () {
      expect(currentLineIndex(parseLrc('[00:05.00]Late'), Duration.zero), -1);
    });

    test('the current line is the last one that has started', () {
      expect(currentLineIndex(lines, const Duration(seconds: 5)), 0);
      expect(currentLineIndex(lines, const Duration(seconds: 10)), 1);
      expect(currentLineIndex(lines, const Duration(seconds: 19)), 1);
      expect(currentLineIndex(lines, const Duration(seconds: 20)), 2);
    });

    test('past the end it stays on the last line', () {
      expect(currentLineIndex(lines, const Duration(minutes: 9)), 2);
    });

    test('an empty file never crashes the follow', () {
      expect(currentLineIndex(const [], const Duration(seconds: 5)), -1);
    });
  });
}
