import 'dart:js_interop';

import 'equalizer.dart';

/// The page's own script, which owns the Web Audio graph. See web/eq.js.
@JS('wetowlEq')
external _PageEq? get _pageEq;

extension type _PageEq._(JSObject _) implements JSObject {
  /// Null when it worked, and a sentence saying why not when it did not.
  external JSString? apply(JSBoolean enabled, JSArray<JSNumber> hz, JSArray<JSNumber> gains,
      JSNumber preamp);
}

EqEngine webEqEngine() => WebEqEngine();

/// A browser: the audio element, routed through ten filters.
///
/// Nothing is routed anywhere until the equalizer is first switched on. Before that the
/// element plays the way it always has, so a browser where any of this goes wrong is a
/// browser with no equalizer rather than one with no sound.
class WebEqEngine extends EqEngine {
  String? _why;

  @override
  bool get available => _pageEq != null;

  @override
  String? get whyNot =>
      _why ?? (available ? null : 'This page was loaded without its equalizer script.');

  @override
  List<EqBand> get bands => [for (final hz in eqFrequencies) EqBand(hz)];

  @override
  Future<void> prepare() async {}

  @override
  Future<void> apply(
      {required bool enabled, required List<double> gains, required double preamp}) async {
    final page = _pageEq;
    if (page == null) return;
    final said = page.apply(
      enabled.toJS,
      [for (final hz in eqFrequencies) hz.toJS].toJS,
      [for (final g in gains) g.toJS].toJS,
      preamp.toJS,
    );
    _why = said?.toDart;
    if (_why != null) throw StateError(_why!);
  }
}
