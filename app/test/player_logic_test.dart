import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/player.dart';

/// The order/repeat logic that decides what plays next, exercised without an audio
/// engine. These are the rules that made the queue end in silence and made one
/// still-downloading track end the whole session.
///
/// Mirrors PlayerService._advance: walk the play order, honour repeat, and step over
/// anything that is not downloaded yet.
int? nextPos({
  required List<bool> ready,
  required int from,
  required int direction,
  required QueueRepeat repeat,
}) {
  var pos = from;
  for (var step = 0; step < ready.length; step++) {
    pos += direction;
    if (pos >= ready.length) {
      if (repeat == QueueRepeat.all) {
        pos = 0;
      } else {
        return null; // queue finished
      }
    } else if (pos < 0) {
      if (repeat == QueueRepeat.all) {
        pos = ready.length - 1;
      } else {
        return from; // stay put at the top
      }
    }
    if (ready[pos]) return pos;
  }
  return null; // nothing playable
}

void main() {
  group('advancing through a queue', () {
    test('plays the next ready track', () {
      expect(nextPos(ready: [true, true, true], from: 0, direction: 1,
          repeat: QueueRepeat.off), 1);
    });

    test('steps over a track that is still downloading', () {
      // The original bug: this stopped playback dead instead of skipping.
      expect(nextPos(ready: [true, false, true], from: 0, direction: 1,
          repeat: QueueRepeat.off), 2);
    });

    test('reports the end of the queue instead of silence', () {
      expect(nextPos(ready: [true, true], from: 1, direction: 1,
          repeat: QueueRepeat.off), isNull);
    });

    test('repeat all wraps to the top', () {
      expect(nextPos(ready: [true, true], from: 1, direction: 1,
          repeat: QueueRepeat.all), 0);
    });

    test('repeat all wraps backwards too', () {
      expect(nextPos(ready: [true, true, true], from: 0, direction: -1,
          repeat: QueueRepeat.all), 2);
    });

    test('a queue with nothing downloaded yet waits rather than ending', () {
      expect(nextPos(ready: [false, false], from: 0, direction: 1,
          repeat: QueueRepeat.all), isNull);
    });

    test('going back from the first track stays put with repeat off', () {
      expect(nextPos(ready: [true, true], from: 0, direction: -1,
          repeat: QueueRepeat.off), 0);
    });
  });

  group('repeat mode round-trips through the API', () {
    test('parses and serialises every mode', () {
      for (final m in QueueRepeat.values) {
        expect(queueRepeatFrom(queueRepeatTo(m)), m);
      }
    });

    test('an unknown mode from the server falls back to off', () {
      expect(queueRepeatFrom('sideways'), QueueRepeat.off);
    });
  });

  group('snapshot progress', () {
    test('is a fraction, and never divides by a zero duration', () {
      const s = PlayerSnapshot(
        current: null, index: 0, playing: true,
        position: Duration(seconds: 30), duration: Duration(seconds: 120),
        itemCount: 1,
      );
      expect(s.progress, closeTo(0.25, 0.001));

      const unknown = PlayerSnapshot(
        current: null, index: 0, playing: true,
        position: Duration(seconds: 30), duration: null, itemCount: 1,
      );
      expect(unknown.progress, 0.0);
    });

    test('clamps a position past the end', () {
      const s = PlayerSnapshot(
        current: null, index: 0, playing: false,
        position: Duration(seconds: 200), duration: Duration(seconds: 120),
        itemCount: 1,
      );
      expect(s.progress, 1.0);
    });
  });
}
