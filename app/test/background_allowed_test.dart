// Whether the phone will let the music keep playing once the app is not on screen.
//
// This is the whole of the background-playback question on a modern Android: no
// notification is no foreground service, and a process without a foreground service is
// a cached one, which the system may freeze the moment the app leaves the screen. The
// phone it was chased on had notifications off and every recorded kill had the app
// down as cached. The app cannot fix that from inside — it can only know, and say so.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('muse/notify');
  final asked = <String>[];

  void phoneSays(bool? allowed) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      asked.add(call.method);
      if (call.method == 'allowed') {
        if (allowed == null) throw PlatformException(code: 'no');
        return allowed;
      }
      return null;
    });
  }

  setUp(asked.clear);
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('a phone that will not show the notification says so', () async {
    phoneSays(false);
    expect(await Keepalive.allowedToShowThePlayer(), isFalse);
    expect(asked, ['allowed']);
  });

  test('a phone that will is not worth a word on the screen', () async {
    phoneSays(true);
    expect(await Keepalive.allowedToShowThePlayer(), isTrue);
  });

  test('no answer is not evidence of a problem', () async {
    // An older Android, a platform with no such rule, or no activity to ask through.
    // Telling somebody their music is about to stop because a channel did not answer
    // is worse than saying nothing.
    phoneSays(null);
    expect(await Keepalive.allowedToShowThePlayer(), isTrue);
  });

  test('the way to the settings is offered, not another prompt', () async {
    // Refused twice, the permission dialog never appears again — so an app that only
    // knows how to ask is an app that goes quiet forever with no way back.
    phoneSays(false);
    await Keepalive.takeMeToTheSettings();
    expect(asked, contains('settings'));
  });
}
