import 'board_store.dart';

/// A browser: the board lives for the session. The server's copy comes later.
BoardStore boardStore() => MemoryBoardStore();
