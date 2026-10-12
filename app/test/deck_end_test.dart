// A record played to its end, and started again.
//
// The engine says "completed" at the end and goes on saying it; just_audio goes on
// calling itself playing. A deck started again from there took two presses of PLAY:
// the first was swallowed by just_audio (already "playing", so nothing reached the
// engine) or, where something had paused the deck since, reached the engine — the
// record was heard — while the state just_audio sent with it still said "completed",
// and the deck read that as the end all over again: the sound on, the waveform, the
// clock and the show stopped, until a second press.
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

  /// A deck that has played its record to the end.
  Future<Deck> playedOut({bool stickyEnd = false}) async {
    final d = Deck('A', api: ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    await d.load(Track.fromJson({
      'id': 1,
      'title': 'Track 1',
      'artists': ['Someone'],
      'duration_ms': 60000,
      'state': 'ready',
      'stream_url': '/tracks/1/stream',
      'source': 'youtube',
    }));
    audio.only.stickyEnd = stickyEnd;
    await d.play();
    await pumpEventQueue();
    expect(d.playing, isTrue);
    audio.only.runOut();
    await pumpEventQueue();
    expect(d.playing, isFalse, reason: 'a record that has run out is not playing');
    return d;
  }

  /// PLAY pressed once: the engine is told, and the deck plays with it.
  Future<void> onePress(Deck d) async {
    audio.only.calls.clear();
    await d.play();
    await pumpEventQueue();
    expect(audio.only.calls, contains('play'), reason: 'the engine was never told to play');
    expect(audio.only.playing, isTrue);
    expect(d.playing, isTrue, reason: 'the record is heard and the deck says it is stopped');
  }

  test('played out, back to the start by hand, PLAY once', () async {
    final d = await playedOut();
    await d.seekByHand(Duration.zero);
    await onePress(d);
    d.dispose();
  });

  test('played out, then stopped, then PLAY once', () async {
    final d = await playedOut();
    // STOP, or the booth parking both decks: the deck paused at its end.
    await d.pause();
    await d.placeByHand(const Duration(seconds: 4));
    await onePress(d);
    d.dispose();
  });

  test('played out, then stopped, then PLAY once — an engine still saying "completed"', () async {
    // just_audio_media_kit as it was: off the end, still reporting the end.
    final d = await playedOut(stickyEnd: true);
    await d.pause();
    await d.placeByHand(const Duration(seconds: 4));
    await onePress(d);
    d.dispose();
  });

  test('played out, PLAY once where it stands: from the cue point, or the top', () async {
    var d = await playedOut();
    await onePress(d);
    expect(d.position, lessThan(const Duration(seconds: 1)));
    d.dispose();

    d = await playedOut();
    d.cuePoint = const Duration(seconds: 12);
    await onePress(d);
    expect(d.position.inMilliseconds, closeTo(12000, 500));
    d.dispose();
  });

  test('and the end after that is an end again', () async {
    final d = await playedOut();
    await d.seekByHand(Duration.zero);
    await onePress(d);
    audio.only.runOut();
    await pumpEventQueue();
    expect(d.playing, isFalse);
    d.dispose();
  });
}
