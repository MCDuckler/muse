// Which preset is on. MilkDrop's own clock would change presets every so many
// seconds; here the music does: a hit cuts to another, a drop cuts — or, where
// MilkDrop is the picture, more often than not datamoshes into another — a
// breakdown blends into one over four bars, and once so many bars have gone by (the
// hands' setting) the next comes on with the next phrase, blended over a bar where
// it is loud, two where not — unless the hands locked the one that is on.
//
// The hands moving on from one the director put on, in its first bars, is a skip:
// it comes less (MilkLibrary.skips).
//
// Shipped presets know nothing of wo_*, so this is how they follow the record's
// structure; presets made here can read it themselves.
//
// Which one: by how it measured (combo_scores.dart's MilkScores) — under a figure, the
// ones a figure is not lost in; and as
// intense as where the record is (show_director.dart's intensityFor): a calm one in
// an intro or a breakdown, a wild one on the drop — and in a loud part, one that moves
// with the music by itself (measured on real records). The favourites come more often.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'combo_scores.dart';
import 'milk_feed.dart';
import 'milk_library.dart';
import 'show_director.dart';
import 'show_events.dart';
import 'show_state.dart';

class MilkDirector extends ChangeNotifier {
  MilkDirector(this.feed) {
    unawaitedLoad();
  }

  final MilkFeed feed;
  final _random = math.Random();

  /// Hold the preset that is on: nothing changes it but the hands.
  bool locked = false;

  /// Only the favourites, where there are any.
  bool favouritesOnly = false;

  /// Blend to the next preset every so many bars; 0 is never by the clock.
  int everyBars = 16;

  /// Cut on a drop, and on the hands' hit.
  bool cutOnDrop = true;

  /// Move the preset on with the beat (milk_accent.dart): in a loud part its own
  /// motion made bigger on the kick, the bar, the snare; a build pushes in, a drop
  /// bursts.
  bool accents = true;

  /// The least an author's rating may be for the director to pick it: the
  /// originals rate themselves 1..5, and under 3 is mostly the dull ones.
  double minRating = 3;

  static const _kEvery = 'muse.milk.everyBars', _kFav = 'muse.milk.favouritesOnly', _kDrop = 'muse.milk.cutOnDrop', _kRating = 'muse.milk.minRating',
      _kAccents = 'muse.milk.accents';

  void unawaitedLoad() {
    SharedPreferences.getInstance().then((p) {
      everyBars = p.getInt(_kEvery) ?? everyBars;
      favouritesOnly = p.getBool(_kFav) ?? favouritesOnly;
      cutOnDrop = p.getBool(_kDrop) ?? cutOnDrop;
      minRating = p.getDouble(_kRating) ?? minRating;
      accents = p.getBool(_kAccents) ?? accents;
      notifyListeners();
    }).ignore();
  }

  void set({int? everyBars, bool? favouritesOnly, bool? cutOnDrop, bool? locked, double? minRating, bool? accents}) {
    if (everyBars != null) this.everyBars = everyBars;
    if (minRating != null) this.minRating = minRating;
    if (favouritesOnly != null) this.favouritesOnly = favouritesOnly;
    if (cutOnDrop != null) this.cutOnDrop = cutOnDrop;
    if (accents != null) this.accents = accents;
    if (locked != null) {
      this.locked = locked;
      feed.lock(locked);
    }
    SharedPreferences.getInstance().then((p) async {
      await p.setInt(_kEvery, this.everyBars);
      await p.setBool(_kFav, this.favouritesOnly);
      await p.setBool(_kDrop, this.cutOnDrop);
      await p.setDouble(_kRating, this.minRating);
      await p.setBool(_kAccents, this.accents);
    }).ignore();
    notifyListeners();
  }

  /// The helper just came up: the preset on last (unless it was on when the
  /// helper died, or has been switched off since), or any.
  void started() {
    final last = feed.library.last;
    final p = last != null && !feed.crashed.contains(last.path) && !feed.library.isOff(last) ? last : _pick();
    if (p != null) feed.load(p);
    feed.lock(locked);
  }

  /// How intense the picture should be now (null: no record to say), and whether
  /// MilkDrop is a background under a figure (rather than the picture itself): set
  /// every frame.
  double? target;
  bool underFigure = false;

  /// The measures; null: the app's own.
  MilkScores? scores;

  MilkPreset? _pick({MilkPreset? not}) {
    final pool = feed.library.pool(favouritesOnly: favouritesOnly, minRating: minRating).where((p) => !feed.crashed.contains(p.path)).toList();
    if (pool.isEmpty) return null;
    if (pool.length == 1) return pool.first;
    final weights = [for (final p in pool) p.path == not?.path ? 0.0 : weigh(p)];
    if (weights.every((w) => w <= 0)) {
      MilkPreset p;
      do {
        p = pool[_random.nextInt(pool.length)];
      } while (p.path == not?.path);
      return p;
    }
    final total = weights.fold(0.0, (a, b) => a + b);
    var x = _random.nextDouble() * total;
    for (var i = 0; i < pool.length; i++) {
      x -= weights[i];
      if (x <= 0 && weights[i] > 0) return pool[i];
    }
    return pool[weights.lastIndexWhere((w) => w > 0)];
  }

  /// How likely [p] is now: under a figure, how well a figure stands out on it; how
  /// near it is to the [target]; and a favourite's lean. How it looks on its own is
  /// not weighed (measured off the stage, it disagrees with the hands' favourites). One
  /// never measured (the hands' own, an imported pack, a render that failed) is
  /// taken as it comes.
  double weigh(MilkPreset p) {
    final s = scores ?? MilkScores.shipped;
    var w = ComboScores.lean(underFigure ? s?.ground(p.fullName) : null);
    if (w <= 0) return 0;
    final t = target, i = s?.intensity(p.fullName);
    if (t != null && i != null) {
      final d = i - t;
      w *= math.exp(-d * d / (2 * 0.22 * 0.22));
    }
    // Loud: the ones that move with the music by themselves, more; deaf ones less (the
    // accents carry those, but only so far). Quiet: as they come.
    final r = s?.react(p.fullName);
    if (t != null && r != null && t > 0.5) w *= 1 + 1.6 * (t - 0.5) * 2 * (r - 0.5);
    if (feed.library.isFavourite(p)) w *= 2.5;
    return w * feed.library.skipLean(p);
  }

  /// How far the preset on is from the [target]; null where either is not known.
  double? get _offTarget {
    final t = target, p = feed.preset;
    final i = p == null ? null : (scores ?? MilkScores.shipped)?.intensity(p.fullName);
    return t == null || i == null ? null : (i - t).abs();
  }

  // ---------------------------------------------------------------- the hands
  /// A preset the hands picked stays until a drop or a hit (where those cut), or
  /// the hands pick again: the bar clock, a breakdown, a new record leave it be.
  bool heldByHand = false;

  /// The hands' choice: a cut, and held.
  void pick(MilkPreset p) {
    heldByHand = true;
    feed.load(p);
    notifyListeners();
  }

  /// Let the director change a preset the hands picked before the next drop.
  void release() {
    heldByHand = false;
    notifyListeners();
  }

  /// Switch the preset that is on off, and on to another (a cut; the hands'
  /// hold, if any, moves to the new one).
  void switchOff() {
    final p = feed.preset;
    if (p == null) return;
    if (!feed.library.isOff(p)) feed.library.toggleOff(p);
    final n = _pick(not: p);
    if (n != null && !feed.library.isOff(n)) feed.load(n);
  }

  void next() => _step(1);
  void previous() => _step(-1);

  /// Another preset: a cut, or a blend into it over [blend] seconds.
  void random({bool soft = false, bool byHand = false, double? blend}) {
    if (byHand) _skip();
    final p = _pick(not: feed.preset);
    if (p == null) return;
    final was = heldByHand;
    heldByHand = byHand;
    _mine = byHand ? null : p.path;
    feed.load(p, soft: soft && !byHand, blend: blend);
    if (was != heldByHand) notifyListeners();
  }

  /// The hands moving on from one the director put on, in its first bars: "not this".
  void _skip() {
    final p = feed.preset;
    if (p != null && p.path == _mine && _barsOn < skipBars) feed.library.skipped(p);
    _mine = null;
  }

  /// Within this many bars of the director putting a preset on, the hands' next says
  /// "not this".
  static const skipBars = 4;

  void _step(int by) {
    _skip();
    final list = feed.library.search('', favouritesOnly: favouritesOnly, minRating: minRating, hideOff: true);
    if (list.isEmpty) return;
    final cur = feed.preset;
    final i = cur == null ? -1 : list.indexWhere((p) => p.path == cur.path);
    final n = i < 0 ? 0 : (i + by) % list.length;
    pick(list[n < 0 ? n + list.length : n]);
  }

  // ---------------------------------------------------------------- the music
  /// The preset on (by path), the bars it has been on, and the bars since the
  /// record's last phrase began.
  String? _onPath;
  int _barsOn = 0, _barsSincePhrase = 999;

  /// The director's own pick on (by path): the hands moving on from it soon is a skip.
  String? _mine;

  /// How often a drop is datamoshed into where MilkDrop is the picture (rather than
  /// cut): the stage melts the old preset's picture through the new one's motion.
  static const moshOnDrop = 0.6;

  /// The datamoshes asked of the stage (ShowState.mosh, with the scenes' own).
  int moshes = 0;

  /// A drop's preset, put on a couple of ticks after its datamosh was asked for, so
  /// the melt starts from the one before.
  MilkPreset? _due;
  int _dueIn = 0;

  /// Every tick, with what the engine said happened since the last.
  void frame(ShowState st, List<ShowEvent> said) {
    if (!feed.running || locked) return;
    final m = st.master;
    target = m.playing || m.bpm != null ? ShowDirector.intensityFor(m) : null;
    underFigure = st.scene != 'milk';
    final due = _due;
    if (due != null && --_dueIn <= 0) {
      _due = null;
      _mine = due.path;
      feed.load(due);
    }
    if (feed.preset?.path != _onPath) {
      _onPath = feed.preset?.path;
      _barsOn = 0;
    }
    var phrase = false;
    for (final e in said) {
      if (!e.onMaster) continue;
      if (e.kind == ShowEventKind.bar) {
        _barsOn++;
        _barsSincePhrase++;
      }
      if (e.kind == ShowEventKind.phrase) {
        phrase = true;
        _barsSincePhrase = 0;
      }
    }
    // A blend as long as the music says: a bar where it is loud, two where it is
    // not, four into a breakdown.
    double blendOf(int bars) => (bars * 240 / (m.bpm ?? 120)).clamp(1.0, 10.0);
    final loud = ShowDirector.drive(m) > 0.5;
    for (final e in said) {
      switch (e.kind) {
        case ShowEventKind.drop:
          if (cutOnDrop) _drop(st);
          return;
        case ShowEventKind.hit:
          if (cutOnDrop && _due == null) random();
          return;
        case ShowEventKind.breakdown:
          if (!heldByHand) random(soft: true, blend: blendOf(4));
          return;
        case ShowEventKind.loaded:
          // A new record on the master: a new look for it.
          if (e.deck == st.masterName && !heldByHand) random(soft: true, blend: blendOf(2));
          return;
        case ShowEventKind.section:
          // A section far from what is on (a breakdown under a wild one, a chorus
          // under a still one): another, blended into.
          if (!heldByHand && (_offTarget ?? 0) > 0.35) random(soft: true, blend: blendOf(loud ? 1 : 2));
          return;
        default:
          break;
      }
    }
    if (heldByHand || everyBars <= 0 || !m.playing || _due != null) return;
    // By the clock: on a phrase's first bar once [everyBars] have gone by (a record
    // with no phrases to go by, on the bar count alone).
    if (_barsOn >= everyBars && (phrase || _barsSincePhrase > 32)) random(soft: true, blend: blendOf(loud ? 1 : 2));
  }

  /// The drop: another preset at once — datamoshed into, more often than not, where
  /// MilkDrop is the picture.
  void _drop(ShowState st) {
    final p = _pick(not: feed.preset);
    if (p == null) return;
    final was = heldByHand;
    heldByHand = false;
    if (st.scene == 'milk' && _random.nextDouble() < moshOnDrop) {
      moshes++;
      _due = p;
      _dueIn = 2;
    } else {
      _mine = p.path;
      feed.load(p);
    }
    if (was) notifyListeners();
  }
}
