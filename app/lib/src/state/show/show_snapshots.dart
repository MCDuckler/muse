// The sets: the show as the hands set it up — how often everything comes (the plan,
// show_plan.dart), the effects, the director's temper, the knobs, the finish
// (ShowSetup) — named and kept, to switch the show between in a tap: a calm set for a
// dinner, the club set, one with the dancers never through the fisheye.
//
// Kept on this device (show.json, ShowDoc.snapshots), or shared on the server
// (server/muse/routes_show.py): a shared one is listed to every WetOwl account, which
// may switch to it and save over it (by its revision: one saved over since it was
// taken is said, and the hands choose theirs or ours). A desk on a shared snapshot,
// its rules not changed since, follows it: a newer revision is taken as it is seen.
//
// The document remembers the set on as it was taken (ShowDoc.snapshot): what the show
// is measured against ("changed"), and where a shared one is followed from. One kept
// before the sets (the combination rules alone, show_plan_legacy.dart) is read into a
// set when it is first used.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import 'show_pool.dart';

/// One set: a name and the show's setup.
class ShowSnapshot {
  const ShowSnapshot({required this.id, required this.name, this.setup = ShowSetup.shipped, this.legacy, this.rev = 0, this.owner, this.mine = true, this.updatedBy});

  /// `l:<n>` kept here; `s:<n>` shared, by the server's id.
  final String id;
  final String name;
  final ShowSetup setup;

  /// The combination rules of one kept before the sets, not read yet.
  final List<dynamic>? legacy;

  /// A shared one's: its revision, who shared it (whether it was this account), who
  /// saved it last.
  final int rev;
  final String? owner;
  final bool mine;
  final String? updatedBy;

  bool get shared => id.startsWith('s:');
  int? get serverId => shared ? int.tryParse(id.substring(2)) : null;

  bool same(ShowSetup other) => legacy == null && setup == other;

  ShowSnapshot copyWith({String? id, String? name, ShowSetup? setup, int? rev}) => ShowSnapshot(
      id: id ?? this.id,
      name: name ?? this.name,
      setup: setup ?? this.setup,
      legacy: setup == null ? legacy : null,
      rev: rev ?? this.rev,
      owner: owner,
      mine: mine,
      updatedBy: updatedBy);

  /// [s] as its setup (one kept before the sets, read).
  ShowSnapshot withSetup(ShowSetup s) => copyWith(setup: s);

  /// What the server keeps of it.
  Map<String, dynamic> get doc => legacy != null ? {'rules': legacy} : {'setup': setup.toJson()};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        ...doc,
        if (rev != 0) 'rev': rev,
        if (owner != null) 'owner': owner,
        if (!mine) 'mine': false,
      };

  static ShowSetup _setup(Object? doc) => doc is Map && doc['setup'] is Map ? ShowSetup.fromJson(doc['setup']) : ShowSetup.shipped;

  static List<dynamic>? _legacy(Object? doc) => doc is Map && doc['setup'] == null && doc['rules'] is List ? doc['rules'] as List : null;

  static ShowSnapshot? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String) return null;
    return ShowSnapshot(
      id: j['id'] as String,
      name: j['name'] as String,
      setup: _setup(j),
      legacy: _legacy(j),
      rev: (j['rev'] as num?)?.toInt() ?? 0,
      owner: j['owner'] as String?,
      mine: j['mine'] != false,
    );
  }

  /// A shared one as the server lists it.
  factory ShowSnapshot.fromServer(Map<String, dynamic> j) => ShowSnapshot(
        id: 's:${j['id']}',
        name: '${j['name']}',
        setup: _setup(j['doc']),
        legacy: _legacy(j['doc']),
        rev: (j['rev'] as num?)?.toInt() ?? 0,
        owner: j['owner'] as String?,
        mine: j['mine'] == true,
        updatedBy: j['updated_by'] as String?,
      );
}

/// A shared snapshot saved over since it was taken: ours not saved; [theirs] is it as
/// it is now.
class SnapshotConflict implements Exception {
  SnapshotConflict(this.theirs);
  final ShowSnapshot theirs;
}

/// What the shelf needs of the show: its setup, its document, and the server.
abstract class SnapshotHost {
  ShowSetup get setup;
  List<ShowSnapshot> get kept;
  ShowSnapshot? get taken;

  /// The setup, the sets kept here and the one taken, as one change.
  void put({ShowSetup? setup, List<ShowSnapshot>? kept, ShowSnapshot? taken, bool clearTaken = false});
  ApiClient get api;

  /// A set as the combination rules of before the sets said it.
  ShowSetup fromLegacy(List<dynamic> rules);
}

/// The snapshots: this device's and the shared ones, switched to, saved, shared.
class SnapshotShelf extends ChangeNotifier {
  SnapshotShelf(this.host);
  final SnapshotHost host;

  /// The shared snapshots as last listed (newest saved first).
  List<ShowSnapshot> shared = const [];

  /// Why the shared ones could not be listed or saved, in words; null when they were.
  String? trouble;
  bool loading = false;

  List<ShowSnapshot> get kept => host.kept;

  /// The snapshot on, as taken.
  ShowSnapshot? get on => host.taken;

  /// Whether the show is set up other than the set on says (with none on: other than
  /// as shipped).
  bool get changed {
    final s = on;
    return s == null ? host.setup != ShowSetup.shipped : !s.same(host.setup);
  }

  /// [s] as a set (one kept before the sets read into one).
  ShowSnapshot _read(ShowSnapshot s) => s.legacy == null ? s : s.withSetup(host.fromLegacy(s.legacy!));

  /// Every one by name and id, this device's first.
  List<ShowSnapshot> get all => [...kept, ...shared];

  /// [s] in force, and it the one on.
  void use(ShowSnapshot s) {
    final r = _read(s);
    host.put(setup: r.setup, taken: r, kept: r.shared || identical(r, s) ? null : [for (final k in kept) k.id == r.id ? r : k]);
    notifyListeners();
  }

  /// No set: the show as shipped.
  void useShipped() {
    host.put(setup: ShowSetup.shipped, clearTaken: true);
    notifyListeners();
  }

  /// The show as it is, as a new set kept here, and it the one on.
  ShowSnapshot saveAs(String name) {
    final s = ShowSnapshot(id: 'l:${DateTime.now().microsecondsSinceEpoch}', name: name.trim(), setup: host.setup);
    host.put(kept: [...kept, s], taken: s);
    notifyListeners();
    return s;
  }

  /// The show as it is over the set on. A shared one saved over since it was taken
  /// throws [SnapshotConflict] (nothing saved); [over] saves over that one.
  Future<void> save({ShowSnapshot? over}) async {
    final s = on;
    if (s == null) return;
    final setup = host.setup;
    if (!s.shared) {
      final next = s.copyWith(setup: setup);
      host.put(kept: [for (final k in kept) k.id == s.id ? next : k], taken: next);
      notifyListeners();
      return;
    }
    try {
      final j = await host.api.saveShowSnapshot(s.serverId!, s.copyWith(setup: setup).doc, (over ?? s).rev);
      _took(ShowSnapshot.fromServer(j));
      trouble = null;
    } on ShowSnapshotConflict catch (e) {
      final theirs = ShowSnapshot.fromServer(e.kept);
      _listed(theirs);
      throw SnapshotConflict(theirs);
    } catch (e) {
      trouble = 'could not save it: $e';
      notifyListeners();
      rethrow;
    }
  }

  void rename(ShowSnapshot s, String name) {
    final next = s.copyWith(name: name.trim());
    host.put(kept: [for (final k in kept) k.id == s.id ? next : k], taken: on?.id == s.id ? on!.copyWith(name: next.name) : null);
    notifyListeners();
  }

  /// One kept here forgotten (the show stays as it is).
  void forget(ShowSnapshot s) {
    host.put(kept: [for (final k in kept) if (k.id != s.id) k], clearTaken: on?.id == s.id);
    notifyListeners();
  }

  /// One kept here shared with everyone: on the server, and no longer here.
  Future<ShowSnapshot> share(ShowSnapshot s) async {
    try {
      final shared = ShowSnapshot.fromServer(await host.api.shareShowSnapshot(s.name, _read(s).doc));
      _listed(shared);
      host.put(kept: [for (final k in kept) if (k.id != s.id) k], taken: on?.id == s.id ? shared : null);
      trouble = null;
      notifyListeners();
      return shared;
    } catch (e) {
      trouble = 'could not share it: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// One shared by this account taken away from everyone: kept here instead.
  Future<ShowSnapshot> unshare(ShowSnapshot s) async {
    try {
      await host.api.unshareShowSnapshot(s.serverId!);
    } catch (e) {
      trouble = 'could not take it away: $e';
      notifyListeners();
      rethrow;
    }
    final r = _read(s);
    final here = ShowSnapshot(id: 'l:${DateTime.now().microsecondsSinceEpoch}', name: s.name, setup: r.setup);
    shared = [for (final x in shared) if (x.id != s.id) x];
    host.put(kept: [...kept, here], taken: on?.id == s.id ? here : null);
    trouble = null;
    notifyListeners();
    return here;
  }

  /// The shared ones listed again. The one on, the show not changed since it was
  /// taken and saved since by someone: taken again, as it is now.
  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    notifyListeners();
    try {
      shared = [for (final j in await host.api.showSnapshots()) ShowSnapshot.fromServer(j)];
      trouble = null;
      final s = on;
      if (s != null && s.shared && !changed) {
        final now = shared.where((x) => x.id == s.id).firstOrNull;
        if (now != null && now.rev > s.rev) {
          final r = _read(now);
          host.put(setup: r.setup, taken: r);
        }
      }
    } catch (e) {
      trouble = 'the shared ones could not be listed: ${e is ApiException ? e.message : e}';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// A shared one saved: listed as it is, and the one on.
  void _took(ShowSnapshot s) {
    _listed(s);
    host.put(taken: s);
    notifyListeners();
  }

  void _listed(ShowSnapshot s) {
    final i = shared.indexWhere((x) => x.id == s.id);
    shared = i < 0 ? [s, ...shared] : [for (final x in shared) x.id == s.id ? s : x];
  }

  // A shelf on a page: the shared ones listed again every minute while one is.
  Timer? _every;
  int _users = 0;

  void hold() {
    if (_users++ == 0) {
      unawaited(refresh());
      _every = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(refresh()));
    }
  }

  void release() {
    if (--_users == 0) {
      _every?.cancel();
      _every = null;
    }
  }
}
