import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'board_store.dart';
import 'pad_spec.dart';

BoardStore boardStore() => FileBoardStore();

/// `board.json` beside `booth-session.json`, in the app's own directory.
class FileBoardStore implements BoardStore {
  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}board.json');

  @override
  Future<BoardDoc?> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      return BoardDoc.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('board: could not be read — $e');
      return null;
    }
  }

  @override
  Future<BoardDoc?> save(BoardDoc doc) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(doc.toJson()), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('board: could not be kept — $e');
    }
    return null;
  }
}
