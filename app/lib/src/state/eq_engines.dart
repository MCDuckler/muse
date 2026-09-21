import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'equalizer.dart';
import 'eq_engine_none.dart' if (dart.library.js_interop) 'eq_engine_web.dart' as web;

/// Whichever equalizer this device has.
///
/// Three different things behind one interface, because the three platforms have
/// nothing in common here:
///
///  * Android has an equalizer of its own in the system, with whatever bands the
///    phone's maker chose — five, usually — attached to the player's audio session.
///  * A browser has none, but will route an audio element through filters of any shape
///    (Web Audio). A small script in the page does that; see web/eq.js.
///  * iOS has none either, and its player will not be routed through anything — but it
///    will hand over the samples of each song as they are played (an audio processing
///    tap), and the filters are run on those. See WetowlEq.m in the patched player.
EqEngine eqEngineFor({AndroidEqualizer? equalizer, AndroidLoudnessEnhancer? loudness}) {
  if (kIsWeb) return web.webEqEngine();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return equalizer == null
          ? NoEqEngine()
          : AndroidEqEngine(equalizer, loudness);
    case TargetPlatform.iOS:
      return ChannelEqEngine();
    default:
      return NoEqEngine();
  }
}

/// Android's own, with the bands the phone has.
class AndroidEqEngine extends EqEngine {
  AndroidEqEngine(this._equalizer, this._loudness);

  final AndroidEqualizer _equalizer;
  final AndroidLoudnessEnhancer? _loudness;

  AndroidEqualizerParameters? _has;
  List<EqBand> _bands = const [];
  String? _why;

  @override
  bool get available => _has != null;

  @override
  String? get whyNot => _why;

  @override
  List<EqBand> get bands => _bands;

  @override
  Future<void> prepare() async {
    if (_has != null) return;
    try {
      // Only answers once the player has an audio session, which is once it has been
      // given something to play: asked for again whenever the page is opened.
      final has = await _equalizer.parameters.timeout(const Duration(seconds: 3));
      _has = has;
      _bands = [for (final b in has.bands) EqBand(b.centerFrequency)];
      _why = null;
    } catch (_) {
      _why = 'The equalizer wakes up with the first song. Put something on, and come back.';
    }
  }

  @override
  Future<void> apply(
      {required bool enabled, required List<double> gains, required double preamp}) async {
    final has = _has;
    if (has == null) return;
    // The system's pre-amplifier only goes up. Turning everything down is the same as
    // turning every band down by that much, so that is where a cut goes; a boost goes
    // to the loudness stage, which is what it is for.
    final cut = math.min(0.0, preamp), boost = math.max(0.0, preamp);
    for (var i = 0; i < has.bands.length && i < gains.length; i++) {
      final to = (gains[i] + cut).clamp(has.minDecibels, has.maxDecibels);
      if ((has.bands[i].gain - to).abs() > 0.01) await has.bands[i].setGain(to);
    }
    await _equalizer.setEnabled(enabled);
    final loudness = _loudness;
    if (loudness != null) {
      await loudness.setTargetGain(boost);
      await loudness.setEnabled(enabled && boost > 0.05);
    }
  }
}

/// The ten bands, run by native code the app talks to over a channel: iOS.
class ChannelEqEngine extends EqEngine {
  static const _channel = MethodChannel('wetowl/eq');

  bool _there = false;
  String? _why;

  @override
  bool get available => _there;

  @override
  String? get whyNot => _why;

  @override
  List<EqBand> get bands => [for (final hz in eqFrequencies) EqBand(hz)];

  @override
  Future<void> prepare() async {
    try {
      _there = await _channel.invokeMethod<bool>('available') ?? false;
      _why = _there ? null : 'This build of the app has no equalizer in it.';
    } on MissingPluginException {
      _there = false;
      _why = 'This build of the app has no equalizer in it.';
    }
  }

  @override
  Future<void> apply(
      {required bool enabled, required List<double> gains, required double preamp}) async {
    await _channel.invokeMethod<void>('apply', {
      'enabled': enabled,
      'preamp': preamp,
      'bands': [
        for (var i = 0; i < gains.length; i++)
          {
            'hz': eqFrequencies[i],
            'gain': gains[i],
            // A shelf at either end, so "more bass" means everything down there and
            // not a bump at 31 Hz; bells an octave wide in between.
            'type': i == 0
                ? 'lowshelf'
                : i == gains.length - 1
                    ? 'highshelf'
                    : 'peaking',
            'q': 1.41,
          },
      ],
    });
  }
}
