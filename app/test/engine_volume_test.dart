// A gain meant is a gain heard.
//
// mpv's volume is (volume / 100) cubed — measured on a tone: 70.7 came out at -9.0 dB
// and 50 at -18.1. The booth's crossfader, meant as constant power (-3 dB a deck in the
// middle, two records together as loud as one alone), was told to it as it was and came
// out at -9 dB a deck: the room went quiet whenever both were up. The player's loudness
// match went the same way: a record 6 dB too loud was turned down 18.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/booth/mixer_desktop.dart';

import 'beatmatch_test.dart' show song;
import 'fake_audio.dart';

/// What mpv does with a volume.
double mpvGain(double volume) => math.pow(volume, 3).toDouble();

class _Desk extends DesktopMixer {
  double engine(double level) => toEngine(level);
  double back(double volume) => fromEngine(volume);
}

class _Plain extends VolumeMixer {
  double engine(double level) => toEngine(level);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the crossfader\'s middle is -3 dB a deck on a desk, not -9', () {
    final desk = _Desk();
    final l = Booth.levelsFor(0.5);
    for (final g in [l.a, l.b]) {
      final heard = mpvGain(desk.engine(g));
      expect(20 * math.log(heard) / math.ln10, closeTo(-3.01, 0.01));
    }
    // Two records at once are as loud as one alone, all the way across.
    for (var x = 0.0; x <= 1.0; x += 0.125) {
      final f = Booth.levelsFor(x);
      final a = mpvGain(desk.engine(f.a)), b = mpvGain(desk.engine(f.b));
      expect(a * a + b * b, closeTo(1, 1e-9), reason: 'at $x');
    }
    expect(desk.engine(0), 0);
    expect(desk.back(desk.engine(0.3)), closeTo(0.3, 1e-12));
  });

  test('anywhere else the volume is a gain already, and passes through', () {
    expect(_Plain().engine(0.7071), 0.7071);
  });

  test('a deck on a desk is told the volume that makes the level the booth meant', () async {
    JustAudioPlatform.instance = FakeJustAudio();
    final booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: _Desk());
    addTearDown(booth.dispose);
    await booth.init();
    await booth.load(booth.a, song(1));
    await booth.load(booth.b, song(2));
    await booth.setCrossfader(0.5);
    for (final d in booth.decks) {
      expect(mpvGain(d.player.volume), closeTo(math.sqrt1_2, 1e-9), reason: d.name);
    }
    // A ramp goes through the same gains the curve does, not mpv's.
    await booth.setCrossfader(1, over: const Duration(milliseconds: 200));
    expect(mpvGain(booth.a.player.volume), closeTo(0, 1e-9));
    expect(mpvGain(booth.b.player.volume), closeTo(1, 1e-9));
  });
}
