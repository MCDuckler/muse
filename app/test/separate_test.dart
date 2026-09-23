// Taking a record apart on this computer — held to the same standard as the server.
//
// Deliberately the same cases as `server/tests/test_stems.py`, built from the same
// made-up sound: a tone dead centre has to leave when the middle goes, one in the
// sides has to stay, and a record split into hits and notes has to add back up to the
// record. The two implementations are one algorithm written twice, and this is half
// of what keeps them honest — the other half is that every constant in separate.dart
// has a named twin in stems.py.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/separate.dart';

Float32List tone(double hz, double seconds, {double amp = 0.3}) {
  final n = (rate * seconds).round();
  final x = Float32List(n);
  for (var i = 0; i < n; i++) {
    x[i] = amp * math.sin(2 * math.pi * hz * i / rate);
  }
  return x;
}

/// How much of [x] is at [hz], as an amplitude. A plain correlation against the tone
/// rather than a transform: the test should not lean on the code it is testing.
double at(Float32List x, double hz, {int from = 0, int? to}) {
  final end = to ?? x.length;
  var re = 0.0, im = 0.0;
  for (var i = from; i < end; i++) {
    final a = 2 * math.pi * hz * i / rate;
    re += x[i] * math.cos(a);
    im += x[i] * math.sin(a);
  }
  return 2 * math.sqrt(re * re + im * im) / (end - from);
}

/// How much louder [x] is at the moments [hits] happen than the rest of the time.
///
/// The point of the drums half is that its sound is *at* the hits and nowhere else,
/// and the point of the music half is that it carries on between them. One number
/// says both, and it needs no spectrum — so the test does not lean on the arithmetic
/// it is checking.
double punch(Float32List x, List<int> hits, {int window = 640}) {
  final loud = Uint8List(x.length);
  for (final h in hits) {
    for (var i = h; i < h + window && i < x.length; i++) {
      loud[i] = 1;
    }
  }
  var onSum = 0.0, offSum = 0.0;
  var on = 0, off = 0;
  for (var i = 0; i < x.length; i++) {
    if (loud[i] == 1) {
      onSum += x[i] * x[i];
      on++;
    } else {
      offSum += x[i] * x[i];
      off++;
    }
  }
  if (on == 0 || off == 0) return 0;
  return math.sqrt(onSum / on) / math.max(math.sqrt(offSum / off), 1e-9);
}

double rms(Float32List x, {int from = 0, int? to}) {
  final end = to ?? x.length;
  var sum = 0.0;
  for (var i = from; i < end; i++) {
    sum += x[i] * x[i];
  }
  return math.sqrt(sum / (end - from));
}

/// Four seconds with a voice-ish tone dead centre, a bass note centre, and a
/// counter-melody entirely in the sides. Interleaved, as ffmpeg hands it over.
Float32List record() {
  final voice = tone(1000, 4), bass = tone(60, 4), wide = tone(3000, 4);
  final out = Float32List(voice.length * 2);
  for (var i = 0; i < voice.length; i++) {
    out[i * 2] = voice[i] + bass[i] + wide[i];
    out[i * 2 + 1] = voice[i] + bass[i] - wide[i];
  }
  return out;
}

({Float32List mid, Float32List side}) sides(Float32List stereo) {
  final n = stereo.length ~/ 2;
  final mid = Float32List(n), side = Float32List(n);
  for (var i = 0; i < n; i++) {
    mid[i] = (stereo[i * 2] + stereo[i * 2 + 1]) / 2;
    side[i] = (stereo[i * 2] - stereo[i * 2 + 1]) / 2;
  }
  return (mid: mid, side: side);
}

void main() {
  group('the middle of it', () {
    test('what is in the middle goes', () {
      final before = record();
      final out = withoutVoice(before);
      expect(at(sides(out).mid, 1000), lessThan(0.02 * at(sides(before).mid, 1000)),
          reason: 'a tone dead centre in a voice\'s band is gone');
    });

    test('the sides are kept whole', () {
      final before = record();
      final out = withoutVoice(before);
      expect(at(sides(out).side, 3000),
          closeTo(at(sides(before).side, 3000), at(sides(before).side, 3000) * 0.05),
          reason: 'what was only ever in the sides is untouched');
    });

    test('the bottom end stays', () {
      // The kick and the bass are in the middle too. A record with those taken out is
      // not an instrumental, so the band stops short of them.
      final before = record();
      final out = withoutVoice(before);
      expect(at(sides(out).mid, 60), greaterThan(0.9 * at(sides(before).mid, 60)));
    });

    test('a mono record is honest about itself', () {
      final one = tone(1000, 4), low = tone(60, 4);
      final stereo = Float32List(one.length * 2);
      for (var i = 0; i < one.length; i++) {
        stereo[i * 2] = one[i] + low[i];
        stereo[i * 2 + 1] = one[i] + low[i];
      }
      final out = withoutVoice(stereo);
      final mid = sides(out).mid;
      expect(at(mid, 1000), lessThan(0.02 * at(one, 1000)));
      expect(at(mid, 60), greaterThan(0.9 * at(low, 60)));
    });
  });

  group('hits and notes', () {
    /// A held note with a hit on top of it every quarter of a second.
    Float32List band() {
      final x = tone(440, 4);
      final seed = math.Random(5);
      final tick = (rate * 0.02).round();
      final hit = Float32List(tick);
      for (var i = 0; i < tick; i++) {
        hit[i] = ((seed.nextDouble() * 2 - 1) * math.exp(-i / (rate * 0.004))) * 0.8;
      }
      for (var k = 0; k < 16; k++) {
        final at = (k * 0.25 * rate).round();
        for (var i = 0; i < tick && at + i < x.length; i++) {
          x[at + i] += hit[i];
        }
      }
      return x;
    }

    test('the note lands in the music and the hits in the drums', () {
      final (drums, music) = hitsAndNotes(band());
      // Away from the ends, where there is no overlap.
      final from = rate ~/ 2, to = band().length - rate ~/ 2;
      expect(at(music, 440, from: from, to: to),
          greaterThan(5 * at(drums, 440, from: from, to: to)),
          reason: 'the held note is a note');
      final hits = [for (var k = 0; k < 16; k++) (k * 0.25 * rate).round()];
      expect(punch(drums, hits), greaterThan(4),
          reason: 'the drums half sounds at the hits and hardly at all between them');
      expect(punch(music, hits), lessThan(1.6),
          reason: 'the music half carries on through them');
    });

    test('the two halves add back up to the record', () {
      final x = band();
      final (drums, music) = hitsAndNotes(x);
      final from = rate ~/ 2, to = x.length - rate ~/ 2;
      final error = Float32List(to - from);
      for (var i = from; i < to; i++) {
        error[i - from] = (drums[i] + music[i]) - x[i];
      }
      expect(rms(error), lessThan(0.02 * rms(x, from: from, to: to)),
          reason: 'nothing is lost between the two, and nothing is invented');
    });

    test('a snippet shorter than one window is silence, not a crash', () {
      final tiny = tone(440, 0.01);
      final (drums, music) = hitsAndNotes(tiny);
      expect(drums.length, tiny.length);
      expect(music.length, tiny.length);
      expect(drums.every((v) => v == 0), isTrue);
      final stereo = Float32List(tiny.length * 2);
      expect(withoutVoice(stereo).length, tiny.length * 2);
    });

    test('a long record is worked through in blocks with no seam', () {
      // Longer than one block of frames, so the boundaries between blocks are
      // exercised: they must not be audible, which here means the halves still add
      // up across them.
      final seconds = 384 * 512 / rate * 2.5;
      final a = tone(440, seconds), b = tone(90, seconds, amp: 0.2);
      final x = Float32List(a.length);
      for (var i = 0; i < a.length; i++) {
        x[i] = a[i] + b[i];
      }
      final (drums, music) = hitsAndNotes(x);
      final from = rate ~/ 2, to = x.length - rate ~/ 2;
      final error = Float32List(to - from);
      for (var i = from; i < to; i++) {
        error[i - from] = (drums[i] + music[i]) - x[i];
      }
      expect(rms(error), lessThan(0.02 * rms(x, from: from, to: to)));
    });
  });

  test('splitting a record gives both halves, and there is no such part as vocals', () {
    final out = separate(record(), 'drums');
    expect(out.sound.keys, containsAll(['drums', 'music']));
    expect(out.channels, 1);
    expect(separate(record(), 'instrumental').channels, 2);
    expect(() => separate(record(), 'vocals'), throwsArgumentError);
  });
}
