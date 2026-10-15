// MilkDrop's ear: a record that cannot be decoded is not asked for again the next
// frame. It was — a new isolate and a new ffmpeg sixty times a second, which froze
// the desk whenever the scenes were skipped onto MilkDrop on a computer without
// ffmpeg (wetowl.log, 2026-10-13: 4920 failures in two minutes).
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/deck_pcm.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  test('a record that will not decode is not asked for every frame', () async {
    // A file that is not there: ffmpeg fails on it, or there is no ffmpeg at all.
    // Either way, one try.
    final pcm = DeckPcm()..source = (id) => (url: 'no-such-record-$id.m4a', headers: const {});
    final st = ShowState(
      now: DateTime(2026),
      a: const ShowDeck(name: 'A', trackId: 7, playing: true, level: 1),
      b: const ShowDeck(name: 'B'),
    );
    expect(pcm.slice(st), isNull);
    expect(pcm.decodes, 1);
    for (var i = 0; i < 200 && pcm.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(pcm.busy, isFalse);
    // The frames after it.
    for (var i = 0; i < 30; i++) {
      expect(pcm.slice(st), isNull);
    }
    expect(pcm.decodes, 1);
  });
}
