// The order a playlist is played in, as it is handed to the engine.
//
// just_audio_background runs in the app's own isolate and keeps the load message as
// its source. It used to be given the playlist's live shuffle list in it, so every
// change made while that player was not listening reshaped the order under children
// that never heard of the change — and the next time the player woke, indexing the
// children by that order threw "RangeError (length): Invalid value: Only valid value
// is 0: 1" before anything loaded. Playback stayed dead until a restart.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import 'fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(session, (call) async => null);

  test('the order sent with a load is the order at that load, not a live list', () async {
    final audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    final player = AudioPlayer();
    addTearDown(player.dispose);

    await player.setAudioSource(AudioSource.uri(Uri.parse('file:///a.mp3')));
    final sent = audio.only.loaded! as ConcatenatingAudioSourceMessage;
    expect(sent.children, hasLength(1));
    expect(sent.shuffleOrder, [0]);

    // A change the engine is told about separately, as an insert.
    await player.addAudioSource(AudioSource.uri(Uri.parse('file:///b.mp3')));
    await player.addAudioSource(AudioSource.uri(Uri.parse('file:///c.mp3')));
    expect(sent.shuffleOrder, [0],
        reason: 'what was handed over stays what it was: ${sent.shuffleOrder}');
    expect(sent.shuffleOrder.length, sent.children.length);
  });

  test('an order that does not describe its children is played as listed', () {
    // One child, an order saying "the second": what a stale source looked like.
    final bad = ConcatenatingAudioSourceMessage(
      id: 'p',
      children: [ProgressiveAudioSourceMessage(id: 'a', uri: 'file:///a.mp3')],
      useLazyPreparation: true,
      shuffleOrder: [1],
    );
    expect(bad.shuffleIndices, [0]);

    final good = ConcatenatingAudioSourceMessage(
      id: 'q',
      children: [
        ProgressiveAudioSourceMessage(id: 'a', uri: 'file:///a.mp3'),
        ProgressiveAudioSourceMessage(id: 'b', uri: 'file:///b.mp3'),
        ProgressiveAudioSourceMessage(id: 'c', uri: 'file:///c.mp3'),
      ],
      useLazyPreparation: true,
      shuffleOrder: [2, 0, 1],
    );
    expect(good.shuffleIndices, [2, 0, 1], reason: 'a real order is kept');
  });
}
