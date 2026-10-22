// The selector's snapshots: kept here, switched between, saved; shared with every
// account on the server — saved over by revision, followed while not changed here,
// taken away again by whoever shared it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_snapshots.dart';
import 'package:muse/src/state/show/show_store.dart';

/// The show as far as the shelf goes: a document.
class _Host implements SnapshotHost {
  ShowDoc doc = const ShowDoc();
  @override
  final api = ApiClient(baseUrl: 'http://box', token: 't');
  @override
  List<ComboRule> get rules => doc.pool.rules;
  @override
  List<ShowSnapshot> get kept => doc.snapshots;
  @override
  ShowSnapshot? get taken => doc.snapshot;
  @override
  void put({List<ComboRule>? rules, List<ShowSnapshot>? kept, ShowSnapshot? taken, bool clearTaken = false}) =>
      doc = doc.copyWith(pool: rules == null ? null : doc.pool.copyWith(rules: rules), snapshots: kept, snapshot: taken, clearSnapshot: clearTaken);
  void hands(List<ComboRule> r) => put(rules: r);
}

/// The server's snapshots: one list for every account; `as` says who asks.
class _Box {
  final rows = <Map<String, dynamic>>[];
  var next = 1;
  var as = 'chris';

  Map<String, dynamic> _public(Map<String, dynamic> r) => {...r, 'mine': r['owner'] == as};

  Future<http.Response> handle(http.Request q) async {
    final path = q.url.path;
    final body = q.body.isEmpty ? null : jsonDecode(q.body) as Map<String, dynamic>;
    http.Response json(Object o, [int status = 200]) => http.Response(jsonEncode(o), status, headers: {'content-type': 'application/json'});
    if (path == '/booth/show/snapshots' && q.method == 'GET') return json({'snapshots': [for (final r in rows.reversed) _public(r)]});
    if (path == '/booth/show/snapshots' && q.method == 'POST') {
      final r = {'id': next++, 'name': body!['name'], 'doc': body['doc'], 'rev': 1, 'owner': as, 'updated_by': as};
      rows.add(r);
      return json(_public(r), 201);
    }
    final id = int.parse(path.split('/').last);
    final r = rows.firstWhere((r) => r['id'] == id);
    if (q.method == 'PUT') {
      if (body!['rev'] != r['rev']) return json({'detail': _public(r)}, 409);
      r
        ..['doc'] = body['doc']
        ..['rev'] = (r['rev'] as int) + 1
        ..['updated_by'] = as;
      return json(_public(r));
    }
    rows.remove(r);
    return http.Response('', 204);
  }
}

void main() {
  late _Host host;
  late _Box box;
  late SnapshotShelf shelf;
  const calm = [ComboRule(scenes: {'kinetic'}, weight: 0)];
  const club = [ComboRule(grounds: {'milk'}, weight: 4), ComboRule(shots: {'dancers.fisheye'}, weight: 0)];

  setUp(() {
    host = _Host();
    box = _Box();
    useThisClientInstead(MockClient(box.handle));
    shelf = SnapshotShelf(host);
  });
  tearDown(() => useThisClientInstead(http.Client()));

  test('kept here: saved as, switched between, changed and saved, forgotten', () {
    expect(shelf.changed, isFalse, reason: 'as shipped, nothing of the hands\'');
    host.hands(calm);
    expect(shelf.changed, isTrue);
    final a = shelf.saveAs(' Calm ');
    expect(a.name, 'Calm');
    expect(shelf.on?.id, a.id);
    expect(shelf.changed, isFalse);
    host.hands(club);
    final b = shelf.saveAs('Club');
    shelf.use(a);
    expect(host.rules, calm);
    shelf.use(b);
    expect(host.rules, club);
    host.hands([...club, const ComboRule(masks: {Mask.keyhole}, weight: 0)]);
    expect(shelf.changed, isTrue);
    shelf.save();
    expect(shelf.changed, isFalse);
    expect(shelf.kept.last.rules, hasLength(3));
    shelf.useShipped();
    expect(host.rules, isEmpty);
    expect(shelf.on, isNull);
    shelf.forget(a);
    expect(shelf.kept.map((s) => s.name), ['Club']);
    // The document keeps them.
    final back = ShowDoc.fromJson(jsonDecode(jsonEncode(host.doc.toJson())) as Map<String, dynamic>);
    expect(back.snapshots.single.rules, shelf.kept.single.rules);
  });

  test('shared: everyone lists it, saves over it by revision, follows it; its keeper takes it away', () async {
    host.hands(club);
    final mine = shelf.saveAs('Club');
    final shared = await shelf.share(mine);
    expect(shared.shared && shared.mine, isTrue);
    expect(shelf.kept, isEmpty, reason: 'shared, no longer only here');
    expect(shelf.on?.id, shared.id);
    expect(box.rows.single['doc'], {'rules': [for (final r in club) r.toJson()]});

    // Another desk: lists it, switches to it, saves over it.
    final other = _Host();
    final theirShelf = SnapshotShelf(other);
    box.as = 'joe';
    await theirShelf.refresh();
    expect(theirShelf.shared.single.mine, isFalse);
    theirShelf.use(theirShelf.shared.single);
    expect(other.rules, club);
    other.hands(calm);
    await theirShelf.save();
    expect(box.rows.single['rev'], 2);

    // This desk, its rules not changed: follows it.
    box.as = 'chris';
    await shelf.refresh();
    expect(host.rules, calm);
    expect(shelf.on?.rev, 2);
    expect(shelf.changed, isFalse);

    // Both change it: the later save is told, and may save over it.
    host.hands(club);
    box.as = 'joe';
    other.hands([...calm, ...club]);
    await theirShelf.refresh();
    await theirShelf.save();
    box.as = 'chris';
    await expectLater(shelf.save(), throwsA(isA<SnapshotConflict>().having((c) => c.theirs.updatedBy, 'by', 'joe')));
    expect(box.rows.single['rev'], 3);
    // Changed here: not followed over the hands' own.
    await shelf.refresh();
    expect(host.rules, club);
    final theirs = shelf.shared.single;
    await shelf.save(over: theirs);
    expect(box.rows.single['rev'], 4);
    expect(shelf.changed, isFalse);

    // Only its keeper takes it away; it stays on that desk.
    box.as = 'joe';
    await theirShelf.refresh();
    box.as = 'chris';
    final here = await shelf.unshare(shelf.on!);
    expect(box.rows, isEmpty);
    expect(here.shared, isFalse);
    expect(shelf.kept.single.rules, club);
    expect(shelf.on?.id, here.id);
  });

  test('a server not there: said, and nothing lost', () async {
    useThisClientInstead(MockClient((_) async => http.Response('down', 502)));
    host.hands(calm);
    final a = shelf.saveAs('Calm');
    await shelf.refresh();
    expect(shelf.trouble, isNotNull);
    await expectLater(shelf.share(a), throwsA(anything));
    expect(shelf.kept.single.id, a.id);
  });
}
