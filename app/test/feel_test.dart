// What a tap feels like.
//
// A buzz is the one piece of feedback in the app that cannot be seen in a screenshot
// and cannot be checked by looking, so it is checked here: that it is silent where
// there is no motor, that it stops when somebody turns it off, and that a list flung
// past a hundred rows is not a hundred ticks.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/feel.dart';

void main() {
  // The channel the buzz goes down needs a binding, and a test has no platform to
  // answer it — so it is answered here, and what the app asked for is what is checked.
  TestWidgetsFlutterBinding.ensureInitialized();
  final asked = <String>[];
  setUp(() {
    Haptics.forget();
    asked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') asked.add('${call.arguments}');
      return null;
    });
  });
  tearDown(() {
    Haptics.enabled = true;
    debugDefaultTargetPlatformOverride = null;
  });

  test('a phone with a motor gets one', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(Haptics.available, isTrue);
    feel(Feel.tap);
    expect(Haptics.count, 1);
  });

  test('a browser and a desktop get nothing at all', () {
    // A browser's vibrate is the length of a text message rather than a tick, and a
    // desktop has nothing to buzz: doing something wrong is worse than doing nothing.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(Haptics.available, isFalse);
    feel(Feel.commit);
    expect(Haptics.count, 0);
  });

  test('turned off is off', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    Haptics.enabled = false;
    feel(Feel.commit);
    expect(Haptics.count, 0);
  });

  test('a flung list is not a hundred ticks', () async {
    // A motor already moving cannot give a second distinct tick; what it gives is a
    // longer buzz, which reads as the phone complaining.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (var i = 0; i < 20; i++) {
      feel(Feel.pick);
    }
    expect(Haptics.count, 1);

    await Future<void>.delayed(const Duration(milliseconds: 70));
    feel(Feel.pick);
    expect(Haptics.count, 2, reason: 'and a later one still lands');
  });

  test('felt() does the thing as well as saying it', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var done = 0;
    felt(Feel.tap, () => done++)();
    expect(done, 1);
    expect(Haptics.count, 1);

    // Nothing to do, nothing to say: a disabled button that still buzzed would be the
    // app answering for something it did not do.
    Haptics.forget();
    felt(Feel.tap, null)();
    expect(Haptics.count, 0);
  });
}
