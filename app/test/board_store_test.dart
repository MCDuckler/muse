// The board between a device and the server: the newer copy opens, a save goes
// to both, and a save the server turns down (another screen saved first) hands
// that screen's board back.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart' show BoardConflict;
import 'package:muse/src/state/booth/board/board_store.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/samples.dart';

void main() {
  BoardDoc doc(double level) => BoardDoc.empty()..level = level;

  test('with nothing kept anywhere, there is nothing; a first save reaches the server', () async {
    Map<String, dynamic>? server;
    var rev = 0;
    final store = ServerBoardStore(
      local: MemoryBoardStore(),
      read: () async => (doc: server, rev: rev),
      write: (d, r) async {
        server = d;
        return ++rev;
      },
    );
    expect(await store.load(), isNull);
    expect(await store.save(doc(0.5)), isNull);
    expect(rev, 1);
    expect(server!['level'], 0.5);
    expect((await store.local.load())!.serverRev, 1, reason: 'the device remembers which revision it has');
  });

  test('the server\'s newer board wins on load; an older one does not', () async {
    final local = MemoryBoardStore()..kept = (doc(0.3)..serverRev = 2);
    var store = ServerBoardStore(
      local: local,
      read: () async => (doc: doc(0.9).toJson(), rev: 5),
      write: (d, r) async => r + 1,
    );
    final got = await store.load();
    expect(got!.level, 0.9, reason: 'rev 5 beats the rev 2 this device had');
    expect(got.serverRev, 5);

    local.kept = doc(0.3)..serverRev = 7;
    store = ServerBoardStore(
      local: local,
      read: () async => (doc: doc(0.9).toJson(), rev: 5),
      write: (d, r) async => r + 1,
    );
    expect((await store.load())!.level, 0.3, reason: 'this device saved after the server copy');
  });

  test('a save over a board another screen saved first comes back as theirs', () async {
    final local = MemoryBoardStore();
    final theirs = doc(0.1)..banks[0].pads[0] = const PadSpec(sampleId: SampleKit.impact, name: 'THEIRS');
    final store = ServerBoardStore(
      local: local,
      read: () async => (doc: null, rev: 0),
      write: (d, r) async => throw BoardConflict(theirs.toJson(), 9),
    );
    await store.load();
    final replaced = await store.save(doc(0.6));
    expect(replaced, isNotNull);
    expect(replaced!.pad(0, 0)!.name, 'THEIRS');
    expect(replaced.serverRev, 9);
    expect(store.serverRev, 9);
    expect(local.kept!.level, 0.1, reason: 'the device keeps theirs too');
  });

  test('no server: the device keeps its own, and a save still lands in the file', () async {
    final local = MemoryBoardStore()..kept = doc(0.4);
    final store = ServerBoardStore(
      local: local,
      read: () async => throw Exception('offline'),
      write: (d, r) async => throw Exception('offline'),
    );
    expect((await store.load())!.level, 0.4);
    expect(await store.save(doc(0.7)), isNull);
    expect(local.kept!.level, 0.7);
  });
}
