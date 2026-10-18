// The show's own document: the pool, the hands' looks, the rig to start on, the
// panel's state — `show.json` beside `booth-session.json` on a desk, nowhere on the
// web. The preferences the show kept before (scenes and dancers off, who dances)
// are read once into it where there is no document yet.
import 'package:shared_preferences/shared_preferences.dart';

import 'show_pool.dart';
import 'show_rig.dart';
import 'show_store_none.dart' if (dart.library.io) 'show_store_io.dart' as device;

class ShowDoc {
  const ShowDoc({this.v = 1, this.pool = ShowPool.none, this.looks = const [], this.lastRig, this.panel = const {}});

  final int v;
  final ShowPool pool;

  /// The hands' own looks (the shipped ones come from assets/show/).
  final List<Look> looks;

  /// The rig on when the booth was last left: the one to start on.
  final ShowRig? lastRig;

  /// The panel's state (its tab, its split), by name.
  final Map<String, Object?> panel;

  static const none = ShowDoc();

  ShowDoc copyWith({ShowPool? pool, List<Look>? looks, ShowRig? lastRig, Map<String, Object?>? panel}) =>
      ShowDoc(v: v, pool: pool ?? this.pool, looks: looks ?? this.looks, lastRig: lastRig ?? this.lastRig, panel: panel ?? this.panel);

  Map<String, dynamic> toJson() => {
        'v': v,
        'pool': pool.toJson(),
        if (looks.isNotEmpty) 'looks': [for (final l in looks) l.toJson()],
        if (lastRig != null) 'lastRig': lastRig!.toJson(),
        if (panel.isNotEmpty) 'panel': panel,
      };

  factory ShowDoc.fromJson(Map<String, dynamic> j) => ShowDoc(
        v: (j['v'] as num?)?.toInt() ?? 1,
        pool: j['pool'] is Map ? ShowPool.fromJson((j['pool'] as Map).cast()) : ShowPool.none,
        looks: [for (final l in (j['looks'] as List? ?? const [])) if (l is Map) Look.fromJson(l.cast())],
        lastRig: j['lastRig'] is Map ? ShowRig.fromJson((j['lastRig'] as Map).cast()) : null,
        panel: j['panel'] is Map ? (j['panel'] as Map).cast<String, Object?>() : const {},
      );
}

abstract class ShowStore {
  /// The document, or null where there is none yet (or it could not be read).
  Future<ShowDoc?> load();
  Future<void> save(ShowDoc doc);

  /// This device's own store.
  factory ShowStore.forThisDevice() => device.showStore();
}

/// A store that forgets: tests, and a platform with nowhere to write.
class MemoryShowStore implements ShowStore {
  MemoryShowStore([this.kept]);
  ShowDoc? kept;
  int saves = 0;

  @override
  Future<ShowDoc?> load() async => kept;

  @override
  Future<void> save(ShowDoc doc) async {
    kept = ShowDoc.fromJson(doc.toJson());
    saves++;
  }
}

/// The document made of the preferences the show kept before it had one — the
/// scenes and the dancers switched off, who dances — for the first start with none.
Future<ShowDoc> migratedShowDoc() async {
  try {
    final p = await SharedPreferences.getInstance();
    return ShowDoc(
      pool: ShowPool.migrated(
        scenesOff: p.getStringList('muse.show.scenesOff') ?? const [],
        dancersOff: p.getStringList('muse.show.dancersOff') ?? const [],
        dancer: p.getString('muse.show.dancer'),
      ),
    );
  } catch (_) {
    return const ShowDoc(pool: ShowPool(off: ShowPool.shippedOff));
  }
}
