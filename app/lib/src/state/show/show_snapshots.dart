// The selector's snapshots: the hands' combination rules (show_combos.dart), named
// and kept, to switch the show between in a tap — a calm set for a dinner, the club
// set, one with the dancers never through the fisheye.
//
// Kept on this device (show.json, ShowDoc.snapshots), or shared on the server
// (server/muse/routes_show.py): a shared one is listed to every WetOwl account, which
// may switch to it and save over it (by its revision: one saved over since it was
// taken is said, and the hands choose theirs or ours). A desk on a shared snapshot,
// its rules not changed since, follows it: a newer revision is taken as it is seen.
//
// The document remembers the snapshot on as it was taken (ShowDoc.snapshot): what the
// rules are measured against ("changed"), and where a shared one is followed from.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import 'show_combos.dart';

/// One snapshot: a name and the hands' rules (the shipped ones are under every one).
class ShowSnapshot {
  const ShowSnapshot({required this.id, required this.name, this.rules = const [], this.rev = 0, this.owner, this.mine = true, this.updatedBy});

  /// `l:<n>` kept here; `s:<n>` shared, by the server's id.
  final String id;
  final String name;
  final List<ComboRule> rules;

  /// A shared one's: its revision, who shared it (whether it was this account), who
  /// saved it last.
  final int rev;
  final String? owner;
  final bool mine;
  final String? updatedBy;

  bool get shared => id.startsWith('s:');
  int? get serverId => shared ? int.tryParse(id.substring(2)) : null;

  bool sameRules(List<ComboRule> other) => listEquals(rules, other);

  ShowSnapshot copyWith({String? id, String? name, List<ComboRule>? rules, int? rev}) =>
      ShowSnapshot(id: id ?? this.id, name: name ?? this.name, rules: rules ?? this.rules, rev: rev ?? this.rev, owner: owner, mine: mine, updatedBy: updatedBy);

  /// What the server keeps of it.
  Map<String, dynamic> get doc => {
        'rules': [for (final r in rules) r.toJson()]
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        ...doc,
        if (rev != 0) 'rev': rev,
        if (owner != null) 'owner': owner,
        if (!mine) 'mine': false,
      };

  static List<ComboRule> _rules(Object? list) => list is List ? [for (final r in list) ComboRule.fromJson(r)].whereType<ComboRule>().toList() : const [];

  static ShowSnapshot? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String) return null;
    return ShowSnapshot(
      id: j['id'] as String,
      name: j['name'] as String,
      rules: _rules(j['rules']),
      rev: (j['rev'] as num?)?.toInt() ?? 0,
      owner: j['owner'] as String?,
      mine: j['mine'] != false,
    );
  }

  /// A shared one as the server lists it.
  factory ShowSnapshot.fromServer(Map<String, dynamic> j) => ShowSnapshot(
        id: 's:${j['id']}',
        name: '${j['name']}',
        rules: _rules((j['doc'] as Map?)?['rules']),
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

/// What the shelf needs of the show: its rules, its document, and the server.
abstract class SnapshotHost {
  List<ComboRule> get rules;
  List<ShowSnapshot> get kept;
  ShowSnapshot? get taken;

  /// The rules, the snapshots kept here and the one taken, as one change.
  void put({List<ComboRule>? rules, List<ShowSnapshot>? kept, ShowSnapshot? taken, bool clearTaken = false});
  ApiClient get api;
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

  /// Whether the rules are other than the snapshot on's (with none on: whether there
  /// are any of the hands' at all).
  bool get changed {
    final s = on;
    return s == null ? host.rules.isNotEmpty : !s.sameRules(host.rules);
  }

  /// Every one by name and id, this device's first.
  List<ShowSnapshot> get all => [...kept, ...shared];

  /// The rules of [s] in force, and it the one on.
  void use(ShowSnapshot s) {
    host.put(rules: s.rules, taken: s);
    notifyListeners();
  }

  /// No snapshot: the rules as shipped.
  void useShipped() {
    host.put(rules: const [], clearTaken: true);
    notifyListeners();
  }

  /// The rules as they are, as a new snapshot kept here, and it the one on.
  ShowSnapshot saveAs(String name) {
    final s = ShowSnapshot(id: 'l:${DateTime.now().microsecondsSinceEpoch}', name: name.trim(), rules: host.rules);
    host.put(kept: [...kept, s], taken: s);
    notifyListeners();
    return s;
  }

  /// The rules as they are over the snapshot on. A shared one saved over since it was
  /// taken throws [SnapshotConflict] (nothing saved); [over] saves over that one.
  Future<void> save({ShowSnapshot? over}) async {
    final s = on;
    if (s == null) return;
    final rules = host.rules;
    if (!s.shared) {
      final next = s.copyWith(rules: rules);
      host.put(kept: [for (final k in kept) k.id == s.id ? next : k], taken: next);
      notifyListeners();
      return;
    }
    try {
      final j = await host.api.saveShowSnapshot(s.serverId!, s.copyWith(rules: rules).doc, (over ?? s).rev);
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

  /// One kept here forgotten (the rules on stay as they are).
  void forget(ShowSnapshot s) {
    host.put(kept: [for (final k in kept) if (k.id != s.id) k], clearTaken: on?.id == s.id);
    notifyListeners();
  }

  /// One kept here shared with everyone: on the server, and no longer here.
  Future<ShowSnapshot> share(ShowSnapshot s) async {
    try {
      final shared = ShowSnapshot.fromServer(await host.api.shareShowSnapshot(s.name, s.doc));
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
    final here = ShowSnapshot(id: 'l:${DateTime.now().microsecondsSinceEpoch}', name: s.name, rules: s.rules);
    shared = [for (final x in shared) if (x.id != s.id) x];
    host.put(kept: [...kept, here], taken: on?.id == s.id ? here : null);
    trouble = null;
    notifyListeners();
    return here;
  }

  /// The shared ones listed again. The one on, its rules not changed since it was
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
        if (now != null && now.rev > s.rev) host.put(rules: now.rules, taken: now);
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
