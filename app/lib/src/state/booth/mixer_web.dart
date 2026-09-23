import 'dart:js_interop';

import 'deck.dart';
import 'mixer.dart';

/// The page's own script, which owns the decks' audio graph. See web/booth.js.
@JS('wetowlBooth')
external _PageBooth? get _pageBooth;

extension type _PageBooth._(JSObject _) implements JSObject {
  external void expect(JSString deck);
  external JSBoolean has(JSString deck);
  external JSString? ready();
  external void levels(JSString deck, JSNumber level, JSNumber seconds);
  external void kills(JSString deck, JSBoolean low, JSBoolean mid, JSBoolean high);
  external void filter(JSString deck, JSNumber value);
}

Mixer? webMixer() => _pageBooth == null ? null : WebMixer();

/// A browser: each deck's element through a gain, three bands, a filter and the
/// crossfader, every change scheduled on the audio clock.
class WebMixer extends Mixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;

  /// The browser hands each deck's element over the moment the deck makes it, so the
  /// script has to be told which deck is about to make one — see booth.js.
  @override
  void expecting(String deck) => _pageBooth?.expect(deck.toJS);

  @override
  Future<void> prepare(List<Deck> decks) async {
    // The decks' players make their elements as they are first spoken to; the script
    // was told which is which before each was made (Booth.init). Nothing to do here
    // but make sure the context is awake.
    _pageBooth?.ready();
  }

  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    final page = _pageBooth;
    if (page == null) return;
    for (final e in levels.entries) {
      if (page.has(e.key.name.toJS).toDart) {
        page.levels(e.key.name.toJS, e.value.clamp(0.0, 1.0).toJS,
            (over.inMicroseconds / 1e6).toJS);
      } else {
        // Not routed yet: the element's own volume until it is.
        await e.key.player.setVolume(e.value.clamp(0.0, 1.0));
      }
    }
  }

  @override
  Future<void> setKills(Deck deck, {bool low = false, bool mid = false, bool high = false}) async {
    _pageBooth?.kills(deck.name.toJS, low.toJS, mid.toJS, high.toJS);
  }

  @override
  Future<void> setFilter(Deck deck, double value) async {
    _pageBooth?.filter(deck.name.toJS, value.clamp(-1.0, 1.0).toJS);
  }
}

/// A browser is not a desk.
Mixer? desktopMixer() => null;
