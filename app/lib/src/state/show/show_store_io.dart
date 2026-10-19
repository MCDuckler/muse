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
    File? f;
    try {
      f = await _file();
      if (!f.existsSync()) return null;
      return ShowDoc.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      // Kept aside rather than written over: the rules and the switches in it are the
      // hands' work, and a fresh document is about to take its place.
      debugPrint('show: its document could not be read — $e');
      try {
        if (f != null && f.existsSync()) {
          final aside = '${f.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}';
          await f.copy(aside);
          debugPrint('show: the unreadable document is kept as $aside');
        }
      } catch (_) {}
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
