// The presets there are: MilkDrop's own (shipped with the app, copied out once so
// the helper can read them as files), the ones made here, and any folder brought
// in. Plus what the hands think of them: the favourites, and what was on last.
//
// A preset is a text file (`[preset00]` and key=value lines; see
// docs/milk-presets.md), named after its author and title the way the MilkDrop
// world does: "Author - Title.milk". Nothing is parsed here beyond the name.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class MilkPreset {
  const MilkPreset({required this.path, required this.name, required this.author, required this.collection, this.rating = 3});

  /// The author's own word on it, 0..5 (fRating); 3 where the file does not say.
  final double rating;

  /// The file, as the helper is told it.
  final String path;

  /// The title without the author and the extension.
  final String name;
  final String author;

  /// `shipped`, `mine`, or the imported folder's name.
  final String collection;

  String get fullName => author.isEmpty ? name : '$author - $name';

  /// Author and title off a file name, by the convention "Author - Title.milk".
  static MilkPreset of(String path, String collection, {double rating = 3}) {
    var base = path.split(Platform.pathSeparator).last;
    if (base.toLowerCase().endsWith('.milk')) base = base.substring(0, base.length - 5);
    final dash = base.indexOf(' - ');
    return MilkPreset(
      path: path,
      name: dash > 0 ? base.substring(dash + 3) : base,
      author: dash > 0 ? base.substring(0, dash) : '',
      collection: collection,
      rating: rating,
    );
  }

  /// The rating read off the file's head, where it has one.
  static Future<double> ratingOf(String path) async {
    try {
      final f = File(path).openRead(0, 400);
      final head = await f.transform(const SystemEncoding().decoder).join();
      final m = RegExp(r'fRating=([\d.]+)').firstMatch(head);
      return m == null ? 3 : (double.tryParse(m.group(1)!) ?? 3).clamp(0.0, 5.0);
    } catch (_) {
      return 3;
    }
  }
}

class MilkLibrary extends ChangeNotifier {
  static const shippedDir = 'assets/milk/presets/';

  /// Where the library's folders are, once [ready].
  String home = '';
  String get texturesDir => '$home${Platform.pathSeparator}textures';
  String get mineDir => '$home${Platform.pathSeparator}mine';

  final presets = <MilkPreset>[];
  final favourites = <String>{};
  final recent = <String>[];

  /// The imported folders, by the name they are listed under.
  final imported = <String, String>{};
  bool _ready = false;
  Future<void>? _readying;

  Future<void> ready() => _readying ??= _init();

  Future<void> _init() async {
    final env = Platform.environment['WETOWL_MILK_HOME'];
    if (env != null) {
      home = env;
    } else {
      try {
        home = '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}milk';
      } catch (_) {
        // No platform to ask (a test): somewhere, rather than nowhere.
        home = '${Directory.systemTemp.path}${Platform.pathSeparator}wetowl-milk';
      }
    }
    for (final d in ['shipped', 'mine', 'textures']) {
      await Directory('$home${Platform.pathSeparator}$d').create(recursive: true);
    }
    await _copyShipped();
    await _loadNotes();
    await rescan();
    _ready = true;
  }

  /// The app's own presets, written out once per build: the helper reads files,
  /// not assets.
  Future<void> _copyShipped() async {
    final dir = Directory('$home${Platform.pathSeparator}shipped');
    final stampFile = File('${dir.path}${Platform.pathSeparator}.stamp');
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final paths = manifest.listAssets().where((p) => p.startsWith(shippedDir) && p.endsWith('.milk')).toList();
      final stamp = '${paths.length}';
      if (stampFile.existsSync() && stampFile.readAsStringSync() == stamp) return;
      for (final asset in paths) {
        final bytes = await rootBundle.load(asset);
        final name = asset.substring(shippedDir.length);
        await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      }
      await stampFile.writeAsString(stamp);
    } catch (e) {
      debugPrint('milk: shipped presets: $e');
    }
  }

  File get _notesFile => File('$home${Platform.pathSeparator}notes.json');

  Future<void> _loadNotes() async {
    try {
      if (!_notesFile.existsSync()) return;
      final j = jsonDecode(await _notesFile.readAsString());
      if (j is! Map) return;
      favourites.addAll([for (final f in (j['favourites'] as List? ?? const [])) '$f']);
      recent.addAll([for (final r in (j['recent'] as List? ?? const [])) '$r']);
      (j['imported'] as Map? ?? const {}).forEach((k, v) => imported['$k'] = '$v');
    } catch (e) {
      debugPrint('milk: notes: $e');
    }
  }

  Future<void> _saveNotes() async {
    try {
      await _notesFile.writeAsString(jsonEncode({
        'favourites': favourites.toList()..sort(),
        'recent': recent,
        'imported': imported,
      }));
    } catch (e) {
      debugPrint('milk: notes: $e');
    }
  }

  /// Everything on disk, read again.
  Future<void> rescan() async {
    final found = <MilkPreset>[];
    Future<void> walk(String dir, String collection) async {
      final d = Directory(dir);
      if (!d.existsSync()) return;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.milk')) {
          found.add(MilkPreset.of(e.path, collection, rating: await MilkPreset.ratingOf(e.path)));
        }
      }
    }
    await walk('$home${Platform.pathSeparator}shipped', 'shipped');
    await walk(mineDir, 'mine');
    for (final e in imported.entries) {
      await walk(e.value, e.key);
    }
    found.sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    presets
      ..clear()
      ..addAll(found);
    if (_ready) notifyListeners();
  }

  MilkPreset? byName(String fullName) => presets.cast<MilkPreset?>().firstWhere((p) => p!.fullName == fullName, orElse: () => null);

  MilkPreset? byPath(String? path) => path == null ? null : presets.cast<MilkPreset?>().firstWhere((p) => p!.path == path, orElse: () => null);

  bool isFavourite(MilkPreset p) => favourites.contains(p.fullName);

  void toggleFavourite(MilkPreset p) {
    if (!favourites.remove(p.fullName)) favourites.add(p.fullName);
    unawaited(_saveNotes());
    notifyListeners();
  }

  void noteUsed(MilkPreset p) {
    recent.remove(p.path);
    recent.insert(0, p.path);
    if (recent.length > 50) recent.removeRange(50, recent.length);
    unawaited(_saveNotes());
  }

  /// The preset on last, if it is still there.
  MilkPreset? get last => byPath(recent.firstOrNull);

  /// A folder of presets brought in by name: read in place, not copied.
  Future<void> import(String dir, {String? as}) async {
    final name = as ?? dir.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;
    imported[name] = dir;
    await _saveNotes();
    await rescan();
  }

  Future<void> forget(String collection) async {
    imported.remove(collection);
    await _saveNotes();
    await rescan();
  }

  /// A preset of the hands' own, written to mine/ and listed; the one it replaces
  /// (same name) is overwritten.
  Future<MilkPreset> save(String fullName, String text) async {
    final safe = fullName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    final path = '$mineDir${Platform.pathSeparator}$safe.milk';
    await File(path).writeAsString(text);
    await rescan();
    return byPath(path) ?? MilkPreset.of(path, 'mine');
  }

  Future<void> delete(MilkPreset p) async {
    if (p.collection != 'mine') return;
    try {
      await File(p.path).delete();
    } catch (_) {}
    await rescan();
  }

  /// The pool the director draws from: the favourites where there are enough,
  /// or everything.
  List<MilkPreset> pool({bool favouritesOnly = false, double minRating = 0}) {
    if (favouritesOnly) {
      final f = presets.where(isFavourite).toList();
      if (f.isNotEmpty) return f;
    }
    final rated = presets.where((p) => p.rating >= minRating || p.collection == 'mine').toList();
    return rated.isEmpty ? presets : rated;
  }

  List<MilkPreset> search(String query, {String? collection, bool favouritesOnly = false, double minRating = 0}) {
    final q = query.trim().toLowerCase();
    return [
      for (final p in presets)
        if ((collection == null || p.collection == collection) &&
            (!favouritesOnly || isFavourite(p)) &&
            (p.rating >= minRating || p.collection == 'mine') &&
            (q.isEmpty || p.fullName.toLowerCase().contains(q)))
          p,
    ];
  }
}
