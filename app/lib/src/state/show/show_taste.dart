// The hands' taste, learnt from what they do rather than asked: a combination skipped
// with NEXT in its first bars comes less (and its kin, the same scene, style and
// background under another mask or blend, a little less); a favourite rated three
// stars or more brings its kind round more often. Kept in the show's document
// (ShowDoc.taste: the skips by combination), the favourites as they are.
import 'show_combos.dart';
import 'show_faves.dart';

class ShowTaste {
  const ShowTaste._();

  /// A NEXT within this many bars of a combination coming on says "not this".
  static const skipBars = 4;

  /// How many combinations' skips are kept; the oldest go first.
  static const kept = 400;

  /// [skips] with one more for [c], the oldest dropped past [kept].
  static Map<String, double> skipped(Map<String, double> skips, Combo c) {
    final k = c.key;
    final out = {for (final e in skips.entries) if (e.key != k) e.key: e.value, k: (skips[k] ?? 0) + 1};
    while (out.length > kept) {
      out.remove(out.keys.first);
    }
    return out;
  }

  static String _kin(String key) => key.split('|').take(3).join('|');

  /// How much the hands lean on [c]: under 1 for the skipped, over 1 for the kind
  /// of their best favourites.
  static double lean(Combo c, Map<String, double> skips, List<ShowFave> faves) {
    var k = 1.0;
    if (skips.isNotEmpty) {
      final own = skips[c.key] ?? 0;
      final kin = _kin(c.key);
      var family = 0.0;
      for (final e in skips.entries) {
        if (e.key != c.key && _kin(e.key) == kin) family += e.value;
      }
      k /= 1 + own + 0.25 * family;
    }
    var lift = 1.0;
    for (final f in faves) {
      if (f.stars < 3 || f.combo.scene != c.scene || f.combo.style != c.style) continue;
      final more = f.combo.ground == c.ground ? 0.25 : 0.1;
      lift += more * (f.stars - 2);
    }
    return k * lift.clamp(1.0, 3.0);
  }
}
