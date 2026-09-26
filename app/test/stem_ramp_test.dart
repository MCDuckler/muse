// A stem move takes the time it says it takes.
//
// It used to be a fixed count of twenty-millisecond steps with the engine awaited
// inside each one, so a slow engine made the move as long as the ramp plus every
// round trip it cost — a part changed by hand took a third of a second to be heard.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Deck stemDeck({required Duration engineTakes, required List<StemLevels> got}) {
    final d = Deck('A', api: ApiClient(baseUrl: 'http://example.invalid'))..stemmed = true;
    d.stemEngine = (deck, levels) async {
      await Future<void>.delayed(engineTakes);
      got.add(levels);
    };
    return d;
  }

  test('a slow engine takes fewer steps, not longer', () async {
    final got = <StemLevels>[];
    // Forty milliseconds a call, against a hundred-and-twenty millisecond move: the
    // old loop would have run six of those and taken about three hundred and sixty.
    final deck = stemDeck(engineTakes: const Duration(milliseconds: 40), got: got);
    final began = DateTime.now();
    await deck.setStemLevels(const StemLevels(drums: 0, rest: 0, vocals: 0));
    final took = DateTime.now().difference(began);

    expect(took.inMilliseconds, lessThan(260),
        reason: 'the move ran long: ${took.inMilliseconds} ms for a 120 ms ramp');
    expect(got.length, lessThan(6), reason: 'a slow engine should take fewer steps');
    expect(got.last.drums, 0, reason: 'and still arrive exactly where it was sent');
    expect(deck.stemLevels.drums, 0);
    deck.dispose();
  });

  test('no ramp at all is one call', () async {
    final got = <StemLevels>[];
    final deck = stemDeck(engineTakes: Duration.zero, got: got);
    await deck.setStemLevels(const StemLevels(vocals: 0), over: Duration.zero);
    expect(got.length, 1);
    expect(got.single.vocals, 0);
    deck.dispose();
  });

  test('a deck that is not in stems is not moved', () async {
    final got = <StemLevels>[];
    final deck = stemDeck(engineTakes: Duration.zero, got: got)..stemmed = false;
    await deck.setStemLevels(const StemLevels(drums: 0));
    expect(got, isEmpty);
    deck.dispose();
  });
}
