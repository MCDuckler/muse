import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The equalizer: a curve somebody drew, and whatever this device can do about it.
///
/// What is kept is the *curve* — how much louder or quieter at ten fixed frequencies,
/// the ones printed on the front of every graphic equalizer since the seventies — and
/// never "slider three is at plus four". Devices disagree about what slider three is: a
/// browser and an iPhone are given all ten bands, an Android phone has whatever its
/// maker put in it, usually five, at frequencies of its own. So the curve is the truth
/// and an engine samples it at the bands it actually has. A preset made on the laptop
/// sounds like the same preset on the phone, and one list of presets serves them all.

/// The ten, in hertz: an octave apart from 31 to 16k.
const eqFrequencies = <double>[31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// How far a band goes, either way, in decibels.
const eqRange = 12.0;

String eqLabel(double hz) => hz >= 1000
    ? '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}k'
    : hz.round().toString();

@immutable
class EqPreset {
  const EqPreset(this.name, this.gains, {this.custom = false});

  final String name;

  /// Decibels at each of [eqFrequencies].
  final List<double> gains;

  /// One somebody made and named, rather than one that came with the app.
  final bool custom;

  Map<String, dynamic> toJson() => {'name': name, 'gains': gains};

  static EqPreset? fromJson(Object? j) {
    if (j is! Map) return null;
    final gains = j['gains'];
    final name = j['name'];
    if (name is! String || gains is! List || gains.length != eqFrequencies.length) {
      return null;
    }
    return EqPreset(name, [for (final g in gains) (g as num).toDouble()], custom: true);
  }
}

/// The ones that come with it. Named for what they are for rather than for a genre:
/// "Rock" says nothing about what it does, and "Small speakers" says all of it.
const eqPresets = <EqPreset>[
  EqPreset('Flat', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqPreset('Loudness', [6, 5, 3, 1, 0, 0, 0, 1, 3, 4]),
  EqPreset('Bass lift', [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
  EqPreset('Warm', [3, 3, 2, 1, 0, 0, -1, -2, -2, -3]),
  EqPreset('Bright', [0, 0, 0, 0, 0, 1, 2, 4, 5, 5]),
  EqPreset('Voices', [-3, -2, -1, 1, 3, 4, 4, 2, 0, -1]),
  EqPreset('Small speakers', [-6, -2, 3, 4, 2, 0, 1, 2, 3, 2]),
  EqPreset('Late night', [-5, -4, -2, 0, 1, 2, 2, 1, -1, -3]),
  EqPreset('Club', [5, 6, 3, 0, -1, -1, 0, 2, 3, 3]),
  EqPreset('Old radio', [-12, -9, -4, 0, 3, 5, 4, -2, -8, -12]),
];

/// What an engine can do, as it reports it.
@immutable
class EqBand {
  const EqBand(this.hz);
  final double hz;
}

/// Whatever actually changes the sound on this device.
abstract class EqEngine {
  /// Whether there is an equalizer here at all.
  bool get available;

  /// Why not, in a sentence somebody can read, when there is not.
  String? get whyNot => null;

  /// The bands it has. Empty until [prepare] has been awaited, or where unavailable.
  List<EqBand> get bands;

  /// Find out what this device has. Safe to call more than once.
  Future<void> prepare();

  /// Make the sound match: [gains] are decibels for each of [bands], in order;
  /// [preamp] is decibels over the whole thing; off is off.
  Future<void> apply({required bool enabled, required List<double> gains, required double preamp});
}

/// A device with nothing to offer. Says so, and does nothing.
class NoEqEngine extends EqEngine {
  NoEqEngine([this._why = 'There is no equalizer for this kind of device yet.']);
  final String _why;

  @override
  bool get available => false;
  @override
  String? get whyNot => _why;
  @override
  List<EqBand> get bands => const [];
  @override
  Future<void> prepare() async {}
  @override
  Future<void> apply(
      {required bool enabled, required List<double> gains, required double preamp}) async {}
}

/// The curve at any frequency: straight lines between the ten, on a logarithmic
/// frequency axis — which is a straight line as the ear hears it — and level beyond
/// either end.
double eqCurveAt(List<double> gains, double hz) {
  if (hz <= eqFrequencies.first) return gains.first;
  if (hz >= eqFrequencies.last) return gains.last;
  for (var i = 1; i < eqFrequencies.length; i++) {
    if (hz <= eqFrequencies[i]) {
      final a = math.log(eqFrequencies[i - 1]), b = math.log(eqFrequencies[i]);
      final t = (math.log(hz) - a) / (b - a);
      return gains[i - 1] + (gains[i] - gains[i - 1]) * t;
    }
  }
  return gains.last;
}

/// The state of it, and the one place it is changed from.
class Equalizer extends ChangeNotifier {
  Equalizer(this.engine);

  EqEngine engine;

  static const _kState = 'muse.eq.v1';

  bool enabled = false;
  List<double> gains = List<double>.filled(eqFrequencies.length, 0);

  /// Decibels over everything, set by hand. See [headroom] for the part that is not.
  double preamp = 0;

  /// Turn the whole thing down by as much as the curve turns anything up.
  ///
  /// Music is mastered to the top of what a file can hold. Six decibels more at 60 Hz
  /// is six decibels past that, and what comes out is not more bass, it is a crackle.
  /// On by default, because the alternative is an equalizer whose first impression is
  /// distortion.
  bool protect = true;

  /// Bypassed for a moment without being switched off: a finger held down to hear the
  /// record as it is, which is the only honest way to judge a curve.
  bool _listeningFlat = false;
  bool get listeningFlat => _listeningFlat;

  List<EqPreset> custom = const [];

  List<EqPreset> get presets => [...eqPresets, ...custom];

  /// What the pre-amplifier is actually set to: what was asked for, less the headroom.
  double get headroom =>
      protect ? -math.max(0.0, gains.fold<double>(0, math.max)) : 0;

  /// The preset the curve is, if it is exactly one of them.
  EqPreset? get current {
    for (final p in presets) {
      var same = true;
      for (var i = 0; i < gains.length; i++) {
        if ((p.gains[i] - gains[i]).abs() > 0.05) same = false;
      }
      if (same) return p;
    }
    return null;
  }

  bool get isFlat => gains.every((g) => g.abs() < 0.05) && preamp.abs() < 0.05;

  // ---------------------------------------------------------------- bass and treble
  //
  // The two knobs on the front of an amplifier, for somebody who does not want ten
  // sliders. They are not a separate setting: each is a shape laid over the curve —
  // a shelf below 250 Hz, a shelf above 4 kHz — so turning one moves the sliders, and
  // the sliders are still the truth.

  static const _bassShape = <double>[1, 1, 0.75, 0.35, 0, 0, 0, 0, 0, 0];
  static const _trebleShape = <double>[0, 0, 0, 0, 0, 0, 0.35, 0.75, 1, 1];

  /// Read back from the curve: how much of the shape is in it.
  double get bass => _amountOf(_bassShape);
  double get treble => _amountOf(_trebleShape);

  double _amountOf(List<double> shape) {
    var sum = 0.0, weight = 0.0;
    for (var i = 0; i < shape.length; i++) {
      sum += gains[i] * shape[i];
      weight += shape[i] * shape[i];
    }
    return (sum / weight).clamp(-eqRange, eqRange);
  }

  Future<void> setBass(double db) => _reshape(_bassShape, bass, db);
  Future<void> setTreble(double db) => _reshape(_trebleShape, treble, db);

  Future<void> _reshape(List<double> shape, double was, double now) async {
    final by = now.clamp(-eqRange, eqRange) - was;
    gains = [
      for (var i = 0; i < gains.length; i++)
        (gains[i] + by * shape[i]).clamp(-eqRange, eqRange)
    ];
    await _changed(dragging: true);
  }

  // ---------------------------------------------------------------- changing it
  Future<void> setEnabled(bool on) async {
    enabled = on;
    await _changed();
  }

  Future<void> setBand(int i, double db) async {
    gains = [...gains]..[i] = db.clamp(-eqRange, eqRange);
    await _changed(dragging: true);
  }

  Future<void> setPreamp(double db) async {
    preamp = db.clamp(-eqRange, eqRange);
    await _changed(dragging: true);
  }

  Future<void> setProtect(bool on) async {
    protect = on;
    await _changed();
  }

  Future<void> use(EqPreset preset) async {
    gains = [...preset.gains];
    // Choosing a curve is asking to hear it.
    enabled = true;
    await _changed();
  }

  Future<void> listenFlat(bool flat) async {
    if (_listeningFlat == flat) return;
    _listeningFlat = flat;
    notifyListeners();
    await _apply();
  }

  /// Keep the curve as it stands, under a name. The same name again replaces it.
  Future<void> saveAs(String name) async {
    final called = name.trim();
    if (called.isEmpty) return;
    custom = [
      for (final p in custom)
        if (p.name.toLowerCase() != called.toLowerCase()) p,
      EqPreset(called, [...gains], custom: true),
    ];
    await _changed();
  }

  Future<void> forget(EqPreset preset) async {
    custom = [for (final p in custom) if (p.name != preset.name) p];
    await _changed();
  }

  /// [dragging] is a change that is one of many in a row — a fader being pulled, the
  /// curve being drawn with a finger. The sound follows every one of them; what is
  /// written down is where it came to rest, a moment after it stops, rather than sixty
  /// times a second while it moves.
  Future<void> _changed({bool dragging = false}) async {
    notifyListeners();
    await _apply();
    _saveSoon?.cancel();
    if (dragging) {
      _saveSoon = Timer(const Duration(milliseconds: 400), _save);
    } else {
      await _save();
    }
  }

  Timer? _saveSoon;

  @override
  void dispose() {
    // Whatever was still waiting to be written down is written down.
    if (_saveSoon?.isActive ?? false) {
      _saveSoon!.cancel();
      _save();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- the device
  /// What the engine is given: the curve, read off at the bands it has.
  List<double> gainsFor(List<EqBand> bands) =>
      [for (final b in bands) eqCurveAt(gains, b.hz)];

  Future<void> _apply() async {
    if (!engine.available) return;
    try {
      await engine.apply(
        enabled: enabled && !_listeningFlat,
        gains: gainsFor(engine.bands),
        preamp: preamp + headroom,
      );
    } catch (e) {
      // An effect that will not take a value is not a reason for the music to stop,
      // or for the page somebody is dragging a slider on to fall over.
      debugPrint('equalizer: $e');
    }
  }

  /// Once, when the player exists: read what was kept, find out what the device has,
  /// and make the sound match.
  Future<void> start([EqEngine? withEngine]) async {
    if (withEngine != null) engine = withEngine;
    await _load();
    try {
      await engine.prepare();
    } catch (e) {
      debugPrint('equalizer: $e');
    }
    notifyListeners();
    await _apply();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kState);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      enabled = j['enabled'] == true;
      protect = j['protect'] != false;
      preamp = ((j['preamp'] ?? 0) as num).toDouble().clamp(-eqRange, eqRange);
      final g = j['gains'];
      if (g is List && g.length == eqFrequencies.length) {
        gains = [for (final v in g) (v as num).toDouble().clamp(-eqRange, eqRange)];
      }
      custom = [
        for (final p in (j['custom'] ?? const []) as List)
          if (EqPreset.fromJson(p) != null) EqPreset.fromJson(p)!
      ];
    } catch (_) {
      // Something unreadable in there: start flat rather than not start.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kState,
          jsonEncode({
            'enabled': enabled,
            'protect': protect,
            'preamp': preamp,
            'gains': gains,
            'custom': [for (final p in custom) p.toJson()],
          }));
    } catch (_) {
      // Not remembered this time; still applied.
    }
  }
}
