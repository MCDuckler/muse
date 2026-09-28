// Where the shape's slices are laid, and where the rules over them are printed.
//
// A deck's strip draws two things from two places: the waveform, from slices the house
// measured across the audio file, and the beat ticks and four-bar rules, from the
// analysis of that same file. They only agree if they are laid out against the same
// length of record. The engine has its own idea of that length, and on some containers
// it is a second out — which is two beats of a four-minute record, and a picture that
// argues with its own ruler about where the drop is.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/booth/wave_strip.dart';

TrackTiming timingOf(int durationMs) =>
    TrackTiming(durationMs: durationMs, bpm: 132, beats: const [74, 529, 983]);

void main() {
  test('the slices are laid over the file, not over the engine\'s idea of it', () {
    // Four minutes of record, and an engine that calls it a second and a half longer.
    // The old code stretched 222.155 s of shape over 223.655 s of strip, so everything
    // in it slid later and later: at the drop two-thirds of the way in, two-thirds of
    // that second and a half.
    const fileMs = 222155, engineUs = 223655.0 * 1000;
    final over = slicesSpan(timingOf(fileMs), engineUs);
    expect(over, fileMs * 1000.0);

    // What that stretch was worth where it was noticed, in beats at this record's 132.
    final slideMs = 0.66 * (engineUs - fileMs * 1000.0) / 1000;
    expect(slideMs / (60000 / 132), greaterThan(2.0),
        reason: 'a stretch too small to be worth a test is not worth a fix either');
  });

  test('the engine is used when the analysis has no length to give', () {
    // An older house, or a record with no analysis at all: better the engine's number
    // than a strip drawn over nothing.
    expect(slicesSpan(null, 1000.0), 1000.0);
    expect(slicesSpan(timingOf(0), 1000.0), 1000.0);
  });

  test('a record the two agree about is laid out exactly as before', () {
    expect(slicesSpan(timingOf(222155), 222155.0 * 1000), 222155.0 * 1000);
  });
}
