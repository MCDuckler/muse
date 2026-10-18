import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'show_store.dart';

ShowStore showStore() => FileShowStore();

/// `show.json` beside `booth-session.json`, in the app's own directory.
class FileShowStore implements ShowStore {
  Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}show.json');

  @override
  Future<ShowDoc?> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      return ShowDoc.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('show: its document could not be read — $e');
      return null;
    }
  }

  @override
  Future<void> save(ShowDoc doc) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(doc.toJson()), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('show: its document could not be kept — $e');
    }
  }
}
