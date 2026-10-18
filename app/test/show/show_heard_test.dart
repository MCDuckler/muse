// The sound as heard: the engine's measure laid over a deck keeps the pulse's stems
// and every other part of the deck; the snare's and the hats' own onsets travel to a
// stage in another window; and the dynamics take the snare off its own onsets where
// the sound is heard.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_dynamics.dart';
import 'package:muse/src/state/show/show_heard.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  test('heard over modelled: the measure, and the stems of the pulse', () {
    const heard = ShowAudio(sub: 0.1, low: 0.2, mid: 0.3, high: 0.4, air: 0.5, kick: 0.6, snare: 0.7, hat: 0.8, onset: 0.9);
    const modelled = ShowAudio(sub: 1, low: 1, kick: 1, drums: 0.25, rest: 0.5, vocals: 0.75);
    final a = ShowHeard.over(heard, modelled);
    expect([a.sub, a.low, a.mid, a.high, a.air, a.kick, a.snare, a.hat, a.onset], [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]);
    expect([a.drums, a.rest, a.vocals], [0.25, 0.5, 0.75]);
  });

  test('a deck with its sound swapped is the same deck otherwise, its stream kept', () {
    const d = ShowDeck(
      name: 'A',
      trackId: 7,
      playing: true,
      bpm: 120,
      beatPhase: 0.5,
      beatInBar: 1,
      streamUrl: 'http://x/7',
      level: 0.8,
      audio: ShowAudio(kick: 0.2),
    );
    final w = d.withAudio(const ShowAudio(kick: 0.9, snare: 0.4));
    expect(w.audio.kick, 0.9);
    expect(w.audio.snare, 0.4);
    expect(w.trackId, 7);
    expect(w.streamUrl, 'http://x/7');
    expect(w.level, 0.8);
    expect(w.beatPhase, 0.5);
    // Carried forward over a wire, the stream is kept too (it was dropped).
    expect(d.advanced(0.25).streamUrl, 'http://x/7');
    expect(d.advanced(0.25).beatInBar, 2);
  });

  test('the snare and the hats go over the wire', () {
    const a = ShowAudio(snare: 0.3, hat: 0.6);
    final back = ShowAudio.fromJson(a.toJson());
    expect(back.snare, 0.3);
    expect(back.hat, 0.6);
    final m = <String, double>{};
    a.flatInto(m, 'audio');
    expect(m['audio.snare'], 0.3);
    expect(m['audio.hat'], 0.6);
  });

  test('heard, the snare hits on its own onsets, not on the middle band', () {
    ShowState frame(ShowAudio audio) => ShowState(
          now: DateTime(2026),
          a: ShowDeck(name: 'A', playing: true, bpm: 120, level: 1, audio: audio),
          b: const ShowDeck(name: 'B'),
          audio: audio,
        );
    double snareAfter(bool heard, ShowAudio hit) {
      final d = ShowDynamics();
      for (var i = 0; i < 60; i++) {
        d.frame(frame(const ShowAudio(mid: 0.3)), 1 / 60, heard: heard);
      }
      return d.frame(frame(hit), 1 / 60, heard: heard)['dyn.hit.snare']!;
    }

    // A snare's onset with the middle band steady: heard, it hits; modelled, nothing
    // in the bands says so.
    const snare = ShowAudio(mid: 0.3, snare: 0.9);
    expect(snareAfter(true, snare), greaterThan(0.5));
    expect(snareAfter(false, snare), lessThan(0.1));
  });
}
