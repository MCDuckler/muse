// Moving a record by hand: dragging the waveform and pressing the nudge arrows.
//
// Both used to fire a seek at the engine per event with nothing awaiting them, so on
// a fast screen a drag queued a hundred and twenty a second and the record lurched
// about long after the finger stopped; and a nudge read where the engine *said* the
// record was, which for the few frames a seek takes to land is the old place, so a
// second press inside that window threw the first one away.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/deck.dart';

import 'fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio audio;

  setUp(() {
    audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
  });

  Deck bare() => Deck('A', api: ApiClient(baseUrl: 'http://example.invalid')..token = 'x');

  /// A deck with a record on it, so there is a real engine to be told about seeks.
  Future<Deck> loaded() async {
    final d = bare();
    await d.load(Track.fromJson({
      'id': 1,
      'title': 'Track 1',
      'artists': ['Someone'],
      'duration_ms': 600000,
      'state': 'ready',
      'stream_url': '/tracks/1/stream',
      'source': 'youtube',
    }));
    return d;
  }

  test('nudges land on top of each other, not on top of a stale position', () async {
    final deck = bare();
    // Three presses in a row, faster than any seek can land.
    unawaited1(deck.nudgeByHand(const Duration(milliseconds: 100)));
    unawaited1(deck.nudgeByHand(const Duration(milliseconds: 100)));
    await deck.nudgeByHand(const Duration(milliseconds: 100));
    expect(deck.position.inMilliseconds, closeTo(300, 30),
        reason: 'three nudges of 100 ms should be 300 ms, not 100');
    expect(deck.aimedAt.inMilliseconds, closeTo(300, 30),
        reason: 'and the aim agrees once the engine has caught up');
    deck.dispose();
  });

  test('a drag tells the engine far less often than it moves', () async {
    final deck = await loaded();
    audio.only.calls.clear();
    final calls = <Future<void>>[];
    // A hundred pointer frames, as a fast screen gives in under a second.
    for (var i = 1; i <= 100; i++) {
      calls.add(deck.seekByHand(Duration(milliseconds: i * 10)));
    }
    await Future.wait(calls);
    final seeks = audio.only.calls.where((c) => c.startsWith('seek')).length;
    expect(seeks, lessThan(100),
        reason: 'every frame reached the engine: $seeks seeks for 100 frames');
    // And wherever it stopped telling the engine, it ends up where the hand left it.
    expect(deck.position.inMilliseconds, closeTo(1000, 40));
    deck.dispose();
  });

  test('a drag never asks for a place before the start', () async {
    final deck = bare();
    await deck.seekByHand(const Duration(milliseconds: -5000));
    expect(deck.position, Duration.zero);
    deck.dispose();
  });
}

void unawaited1(Future<void> f) {
  f.ignore();
}
