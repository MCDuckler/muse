// Where the board is kept between sessions: a file on a device, nothing in a test.
import 'board_store_none.dart' if (dart.library.io) 'board_store_io.dart' as device;
import 'pad_spec.dart';

/// Keeps the board's document.
abstract class BoardStore {
  Future<BoardDoc?> load();

  /// Keeps [doc]. Returns a board to use *instead* when the store has a newer one
  /// (another screen saved since this one read), null otherwise.
  Future<BoardDoc?> save(BoardDoc doc);

  /// This device's own store.
  factory BoardStore.forThisDevice() => device.boardStore();
}

/// A store that forgets: tests, and a platform with nowhere to write.
class MemoryBoardStore implements BoardStore {
  BoardDoc? kept;
  int saves = 0;

  @override
  Future<BoardDoc?> load() async => kept;

  @override
  Future<BoardDoc?> save(BoardDoc doc) async {
    kept = BoardDoc.fromJson(doc.toJson());
    saves++;
    return null;
  }
}

/// The account's board on the server, with this device's own file as the copy that
/// opens at once and works offline. Loading takes whichever is newer; saving writes
/// the file and then the server, and a save the server turns down (another screen
/// saved first) hands that screen's board back to be used instead.
class ServerBoardStore implements BoardStore {
  ServerBoardStore({required this.local, required this.read, required this.write});

  final BoardStore local;

  /// GET: the kept board and its revision.
  final Future<({Map<String, dynamic>? doc, int rev})> Function() read;

  /// PUT: returns the new revision, or throws with the server's board and revision.
  final Future<int> Function(Map<String, dynamic> doc, int rev) write;

  /// The server's revision of what this device last had, 0 before any.
  int serverRev = 0;

  @override
  Future<BoardDoc?> load() async {
    final mine = await local.load();
    try {
      final theirs = await read();
      serverRev = theirs.rev;
      if (theirs.doc != null) {
        final t = BoardDoc.fromJson(theirs.doc!);
        // The server's copy wins when it has been saved since this device last saved.
        if (mine == null || theirs.rev > (mine.serverRev ?? -1)) {
          t.serverRev = theirs.rev;
          await local.save(t);
          return t;
        }
      }
    } catch (_) {
      // No server just now: the device's own copy, as it is.
    }
    return mine;
  }

  @override
  Future<BoardDoc?> save(BoardDoc doc) async {
    doc.serverRev ??= serverRev;
    await local.save(doc);
    try {
      serverRev = await write(doc.toJson(), doc.serverRev ?? serverRev);
      doc.serverRev = serverRev;
      await local.save(doc);
      return null;
    } on Object catch (e) {
      final theirs = _conflict(e);
      if (theirs == null) return null; // offline: the file has it; next time
      serverRev = theirs.rev;
      theirs.doc.serverRev = theirs.rev;
      await local.save(theirs.doc);
      return theirs.doc;
    }
  }

  /// A conflict, from whatever the API's own exception type is: anything with a
  /// `doc` map and a `rev`.
  static ({BoardDoc doc, int rev})? _conflict(Object e) {
    try {
      final d = (e as dynamic).doc, r = (e as dynamic).rev;
      if (d is Map<String, dynamic> && r is int) return (doc: BoardDoc.fromJson(d), rev: r);
    } catch (_) {}
    return null;
  }
}
