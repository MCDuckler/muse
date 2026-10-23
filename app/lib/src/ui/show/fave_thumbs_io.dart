import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// The favourites' pictures: `show_faves/<id>.png` beside show.json.
class FaveThumbs {
  const FaveThumbs._();

  static String? _dir;

  /// Where they are, looked up once (before [image] can say).
  static Future<void> ready() async {
    if (_dir != null) return;
    try {
      _dir = '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}show_faves';
    } catch (_) {}
  }

  static File? _file(String id) => _dir == null ? null : File('$_dir${Platform.pathSeparator}$id.png');

  static Future<void> keep(String id, Uint8List png) async {
    await ready();
    final f = _file(id);
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(png, flush: true);
      // A picture written over one of the same name is not the one in the cache.
      await FileImage(f).evict();
    } catch (e) {
      debugPrint('show: a favourite\'s picture could not be kept — $e');
    }
  }

  static Future<void> forget(String id) async {
    await ready();
    try {
      final f = _file(id);
      if (f != null && f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// The pictures of none of [ids] thrown away (a favourite forgotten: its picture
  /// is kept until then, for an UNDO).
  static Future<void> prune(Set<String> ids) async {
    await ready();
    final d = _dir;
    if (d == null) return;
    try {
      final dir = Directory(d);
      if (!dir.existsSync()) return;
      await for (final f in dir.list()) {
        final name = f.uri.pathSegments.last;
        if (f is File && name.endsWith('.png') && !ids.contains(name.substring(0, name.length - 4))) await f.delete();
      }
    } catch (_) {}
  }

  /// [id]'s picture, where there is one.
  static ImageProvider? image(String id) {
    final f = _file(id);
    return f != null && f.existsSync() ? FileImage(f) : null;
  }
}
