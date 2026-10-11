// Which preset is on. MilkDrop's own clock would change presets every so many
// seconds; here the music does: a hit or a drop cuts to another, a breakdown
// blends into one, and every so many bars (the hands' setting) the next comes on
// a blend — unless the hands locked the one that is on.
//
// Shipped presets know nothing of wo_*, so this is how they follow the record's
// structure; presets made here can read it themselves.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'milk_feed.dart';
import 'milk_library.dart';
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

  static const _kEvery = 'muse.milk.everyBars', _kFav = 'muse.milk.favouritesOnly', _kDrop = 'muse.milk.cutOnDrop';

  void unawaitedLoad() {
    SharedPreferences.getInstance().then((p) {
      everyBars = p.getInt(_kEvery) ?? everyBars;
      favouritesOnly = p.getBool(_kFav) ?? favouritesOnly;
      cutOnDrop = p.getBool(_kDrop) ?? cutOnDrop;
      notifyListeners();
    }).ignore();
  }

  void set({int? everyBars, bool? favouritesOnly, bool? cutOnDrop, bool? locked}) {
    if (everyBars != null) this.everyBars = everyBars;
    if (favouritesOnly != null) this.favouritesOnly = favouritesOnly;
    if (cutOnDrop != null) this.cutOnDrop = cutOnDrop;
    if (locked != null) {
      this.locked = locked;
      feed.lock(locked);
    }
    SharedPreferences.getInstance().then((p) async {
      await p.setInt(_kEvery, this.everyBars);
      await p.setBool(_kFav, this.favouritesOnly);
      await p.setBool(_kDrop, this.cutOnDrop);
    }).ignore();
    notifyListeners();
  }

  /// The helper just came up: the preset on last, or any.
  void started() {
    final p = feed.library.last ?? _pick();
    if (p != null) feed.load(p);
    feed.lock(locked);
  }

  MilkPreset? _pick({MilkPreset? not}) {
    final pool = feed.library.pool(favouritesOnly: favouritesOnly);
    if (pool.isEmpty) return null;
    if (pool.length == 1) return pool.first;
    MilkPreset p;
    do {
      p = pool[_random.nextInt(pool.length)];
    } while (p.path == not?.path);
    return p;
  }

  // ---------------------------------------------------------------- the hands
  void next() => _step(1);
  void previous() => _step(-1);

  void random({bool soft = false}) {
    final p = _pick(not: feed.preset);
    if (p != null) feed.load(p, soft: soft);
  }

  void _step(int by) {
    final list = feed.library.search('', favouritesOnly: favouritesOnly);
    if (list.isEmpty) return;
    final cur = feed.preset;
    final i = cur == null ? -1 : list.indexWhere((p) => p.path == cur.path);
    final n = i < 0 ? 0 : (i + by) % list.length;
    feed.load(list[n < 0 ? n + list.length : n]);
  }

  // ---------------------------------------------------------------- the music
  int _lastBar = -1;

  /// Every tick, with what the engine said happened since the last.
  void frame(ShowState st, List<ShowEvent> said) {
    if (!feed.running || locked) return;
    for (final e in said) {
      switch (e.kind) {
        case ShowEventKind.hit:
        case ShowEventKind.drop:
          if (cutOnDrop) random();
          return;
        case ShowEventKind.breakdown:
          random(soft: true);
          return;
        case ShowEventKind.loaded:
          // A new record on the master: a new look for it.
          if (e.deck == st.masterName) random(soft: true);
          return;
        default:
          break;
      }
    }
    final bar = st.master.barIndex;
    if (everyBars > 0 && bar != null && bar != _lastBar) {
      _lastBar = bar;
      if (bar % everyBars == 0 && st.master.playing) random(soft: true);
    }
  }
}
