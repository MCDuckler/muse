import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';

/// Music kept on the device.
///
/// Everything else in muse streams: the library lives on the server and the phone asks
/// for it a song at a time, which is right when there is signal and useless when there
/// is not. This is the other half — the songs somebody has chosen to keep, held as
/// files the player reads directly, with what is kept decided by hand rather than by a
/// cache guessing.
///
/// Deliberately manual. An automatic cache fills up with whatever happened to play,
/// and the answer to "will this work on the plane" becomes "probably". Here the answer
/// is a list you chose.
class OfflineStore extends ChangeNotifier {
  OfflineStore(this.api);

  final ApiClient api;

  /// Where the files are. Application Support rather than a cache directory: a cache
  /// is something the system may delete when it wants room, which is exactly what
  /// "keep this for the flight" must not mean.
  ///
  /// Or wherever somebody said. On a desk the music folder is a real place — the one
  /// every other player on the machine reads — and songs kept there in an artist's
  /// folder, in the record's folder, are a library rather than a cache. The phone
  /// keeps the app's own storage: the system does not let an app write into a folder
  /// somebody picked without a fight nobody wants to have on a phone.
  Directory? _home;

  /// Where the files are, for showing. Null before init, and in a browser.
  String? get home => _home?.path;

  /// Whether the folder was chosen rather than the default.
  bool get homeIsChosen => _chosen != null;
  String? _chosen;

  /// Whether this platform lets the folder be chosen at all.
  static bool get canChooseHome =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  static const _kHome = 'muse.offline.home';

  /// What is here, by track id. Held in memory and written beside the files, so the
  /// downloaded list can be shown without asking the server anything.
  final Map<int, OfflineTrack> _kept = {};

  /// Waiting to be fetched, in the order they were asked for.
  final List<Track> _queue = [];
  bool _working = false;

  int? get downloading => _current?.id;
  Track? _current;
  double _progress = 0;
  double get progress => _progress;
  int get waiting => _queue.length;
  String? lastError;

  /// Whether keeping music on the device is possible at all. The browser has no
  /// filesystem to keep it in; a phone does.
  static bool get supported => !kIsWeb;

  Iterable<OfflineTrack> get kept => _kept.values;
  int get count => _kept.length;
  int get bytes => _kept.values.fold(0, (sum, t) => sum + t.bytes);

  bool has(int trackId) => _kept.containsKey(trackId);
  bool isQueued(int trackId) =>
      _current?.id == trackId || _queue.any((t) => t.id == trackId);

  /// The file for a track, if it is here. What the player asks before reaching for the
  /// network.
  String? pathFor(int trackId) {
    final entry = _kept[trackId];
    if (entry == null || _home == null) return null;
    final file = File(_absolute(entry.file));
    return file.existsSync() ? file.path : null;
  }

  String? coverFor(int trackId) {
    final entry = _kept[trackId];
    if (entry == null || entry.cover == null || _home == null) return null;
    final file = File(_absolute(entry.cover!));
    return file.existsSync() ? file.path : null;
  }

  Future<void> init() async {
    if (!supported) return;
    try {
      _home = await _defaultHome();
      if (canChooseHome) {
        try {
          final chosen = (await SharedPreferences.getInstance()).getString(_kHome);
          if (chosen != null && chosen.isNotEmpty) {
            final dir = Directory(chosen);
            await dir.create(recursive: true);
            _home = dir;
            _chosen = chosen;
          }
        } catch (e) {
          // The folder that was chosen is gone — a drive unplugged, say. The default
          // is still there; what was kept in the other place waits for it to come back.
          lastError = 'The music folder could not be opened: $e';
        }
      }
      await _home!.create(recursive: true);
      await _readIndex();
      notifyListeners();
    } catch (e) {
      lastError = 'Cannot keep music here: $e';
    }
  }

  Future<Directory> _defaultHome() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/offline');
  }

  /// Keep music in [path] from now on, and take what is already kept there with it.
  ///
  /// Moved rather than left behind: a library split across two folders, one of them
  /// invisible, is what "where did my songs go" looks like. Each file is moved into
  /// its artist's and record's folder under the new home — which also tidies anything
  /// kept before the folders existed. Null puts it back to the app's own storage.
  Future<void> moveTo(String? path) async {
    if (!supported || _home == null) return;
    final from = _home!;
    final to = path == null ? await _defaultHome() : Directory(path);
    if (to.path == from.path) return;
    try {
      await to.create(recursive: true);
      // Somewhere it can actually be written to, found out before anything moves.
      final probe = File('${to.path}/.wetowl-write-test');
      await probe.writeAsString('', flush: true);
      await probe.delete();
    } catch (e) {
      lastError = 'That folder cannot be written to: $e';
      notifyListeners();
      return;
    }
    final moved = <int, OfflineTrack>{};
    for (final entry in _kept.values) {
      try {
        // Named against what has already moved, not what is still to: two songs
        // of one name on one record must not land on the same file.
        final file = await _move(File(_absolute(entry.file)), to,
            _placeFor(entry.asTrack, among: moved.values));
        String? cover;
        if (entry.cover != null) {
          final old = File(_absolute(entry.cover!));
          cover = _coverPlaceFor(entry.asTrack);
          final target = File('${to.path}/$cover');
          if (target.existsSync()) {
            // Another song from the same record already brought the picture.
            if (old.existsSync() && !_coverShared(entry)) await old.delete();
          } else if (old.existsSync()) {
            if (_coverShared(entry)) {
              await target.parent.create(recursive: true);
              await old.copy(target.path);
            } else {
              await _move(old, to, cover);
            }
          } else {
            cover = null;
          }
        }
        moved[entry.id] = entry.at(file: file, cover: cover);
      } catch (e) {
        lastError = 'Could not move "${entry.title}": $e';
      }
    }
    // What could not be moved stays where it was, and stays kept: the index in the
    // new home lists it by its old absolute path.
    for (final entry in _kept.values) {
      moved.putIfAbsent(entry.id,
          () => entry.at(file: _absolute(entry.file),
              cover: entry.cover == null ? null : _absolute(entry.cover!)));
    }
    _kept
      ..clear()
      ..addAll(moved);
    _home = to;
    _chosen = path;
    await _writeIndex();
    await _pruneTree(from);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (path == null) {
        await prefs.remove(_kHome);
      } else {
        await prefs.setString(_kHome, path);
      }
    } catch (_) {}
    notifyListeners();
  }

  /// [file] to [rel] under [home], across drives if it has to be.
  Future<String> _move(File file, Directory home, String rel) async {
    final target = File('${home.path}/$rel');
    await target.parent.create(recursive: true);
    if (!file.existsSync()) throw 'the file is missing';
    try {
      await file.rename(target.path);
    } on FileSystemException {
      // Another drive: a rename cannot cross, a copy can.
      await file.copy(target.path);
      await file.delete();
    }
    return rel;
  }

  bool _coverShared(OfflineTrack of) =>
      _kept.values.any((o) => o.id != of.id && o.cover == of.cover);

  // ---------------------------------------------------------------- where a song goes
  /// A name a filesystem will take, on every filesystem this runs on.
  ///
  /// Windows is the strict one: no `\/:*?"<>|`, nothing that ends in a dot or a
  /// space, and a few reserved names — and a folder made on a Mac has to open on a
  /// Windows share without renaming, so everybody gets Windows's rules.
  static String safeName(String name, {String fallback = 'Unknown'}) {
    var s = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.length > 120) s = s.substring(0, 120).trim();
    if (s.isEmpty) return fallback;
    const reserved = {'CON', 'PRN', 'AUX', 'NUL'};
    if (reserved.contains(s.toUpperCase()) ||
        RegExp(r'^(COM|LPT)[1-9]$', caseSensitive: false).hasMatch(s)) {
      return '_$s';
    }
    return s;
  }

  /// Where a song lives, under the home: the artist's folder, the record's folder
  /// inside it, the song's own name — the shape every music library on a disk has,
  /// so a folder of kept music opens in any other player and reads as a collection.
  /// A song from no record sits in the artist's folder itself.
  ///
  /// The name carries the song's id at the end only when two songs would otherwise
  /// share one — a live take and a studio one with the same title on the same record.
  String _placeFor(Track track, {String? ext, Iterable<OfflineTrack>? among}) {
    final artist = safeName(track.artists.isEmpty ? '' : track.artists.first,
        fallback: 'Unknown Artist');
    final album = track.album == null || track.album!.trim().isEmpty
        ? null
        : safeName(track.album!, fallback: 'Unknown Album');
    final title = safeName(track.displayTitle, fallback: 'Untitled');
    final folder = album == null ? artist : '$artist/$album';
    final e = ext ?? _extension(track);
    final plain = '$folder/$title$e';
    final taken = (among ?? _kept.values).any((o) => o.id != track.id && o.file == plain);
    return taken ? '$folder/$title (${track.id})$e' : plain;
  }

  /// The record's picture, once per record: `cover.jpg` beside its songs, the name
  /// every other player looks for. A song from no record keeps its own.
  String _coverPlaceFor(Track track) {
    final artist = safeName(track.artists.isEmpty ? '' : track.artists.first,
        fallback: 'Unknown Artist');
    if (track.album == null || track.album!.trim().isEmpty) {
      return '$artist/${safeName(track.displayTitle, fallback: 'Untitled')}.jpg';
    }
    return '$artist/${safeName(track.album!, fallback: 'Unknown Album')}/cover.jpg';
  }

  /// Every empty folder under [root], and none of the rest. The root itself stays.
  Future<void> _pruneTree(Directory root) async {
    try {
      final dirs = root.listSync(recursive: true).whereType<Directory>().toList()
        ..sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        if (d.existsSync() && d.listSync().isEmpty) await d.delete();
      }
    } catch (_) {}
  }

  /// Folders left empty by a song going: gone too, up to the home, which stays.
  Future<void> _pruneEmpty(Directory from, {Directory? upTo}) async {
    final stop = upTo ?? _home;
    var dir = from;
    while (stop != null && dir.path != stop.path && dir.path.startsWith(stop.path)) {
      try {
        if (!dir.existsSync() || dir.listSync().isNotEmpty) return;
        await dir.delete();
      } catch (_) {
        return;
      }
      dir = dir.parent;
    }
  }

  File get _index => File('${_home!.path}/index.json');

  Future<void> _readIndex() async {
    if (!_index.existsSync()) return;
    try {
      final raw = jsonDecode(await _index.readAsString());
      _kept.clear();
      for (final entry in (raw as List)) {
        final t = OfflineTrack.fromJson(entry as Map<String, dynamic>);
        // A file somebody deleted from underneath us is not kept, whatever the index
        // says.
        if (File(_absolute(t.file)).existsSync()) _kept[t.id] = t;
      }
    } catch (e) {
      lastError = 'The list of kept music could not be read: $e';
    }
  }

  Future<void> _writeIndex() async {
    if (_home == null) return;
    // Written beside itself and renamed, so a kill in the middle leaves the old list
    // rather than half of a new one. And guarded: somebody clearing the app's storage
    // while a download is running takes the directory out from under this, which is
    // not a reason to throw out of a background loop nobody is awaiting.
    try {
      final tmp = File('${_index.path}.new');
      await tmp.writeAsString(
          jsonEncode([for (final t in _kept.values) t.toJson()]), flush: true);
      await tmp.rename(_index.path);
    } catch (e) {
      lastError = 'The list of kept music could not be written: $e';
    }
  }

  // ---------------------------------------------------------------- keeping
  /// Keep these, in this order. Already-kept songs are skipped rather than fetched
  /// again, so "download this album" after one song is one song's worth of work.
  Future<void> keep(Iterable<Track> tracks) async {
    if (!supported) return;
    for (final track in tracks) {
      if (!track.isReady || has(track.id) || isQueued(track.id)) continue;
      _queue.add(track);
    }
    notifyListeners();
    unawaited(_work());
  }

  Future<void> _work() async {
    if (_working || _home == null) return;
    _working = true;
    try {
      while (_queue.isNotEmpty) {
        final track = _queue.removeAt(0);
        _current = track;
        _progress = 0;
        notifyListeners();
        try {
          await _fetch(track);
        } catch (e) {
          lastError = 'Could not keep "${track.displayTitle}": $e';
        }
        _current = null;
        _progress = 0;
        notifyListeners();
      }
      await _writeIndex();
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> _fetch(Track track) async {
    await api.ensureStreamKey();
    final name = _placeFor(track);
    final into = File('${_home!.path}/$name.part');
    await into.parent.create(recursive: true);
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(api.streamUrl(track)));
      // Native platforms can send the header, which saves relying on the signed URL.
      api.streamHeaders.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw 'the server said ${response.statusCode}';
      }
      final total = response.contentLength;
      var got = 0;
      final sink = into.openWrite();
      await response.forEach((chunk) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          final now = got / total;
          // Reporting every chunk would rebuild the list a hundred times a second.
          if (now - _progress > 0.02) {
            _progress = now;
            notifyListeners();
          }
        }
      });
      await sink.flush();
      await sink.close();

      final file = File('${_home!.path}/$name');
      await into.rename(file.path);

      // The cover too, so a downloaded library still looks like one with no signal.
      // Once per record: the second song from the same album finds it there.
      String? cover;
      final coverUrl = api.coverUrl(track, small: false);
      if (coverUrl != null) {
        final place = _coverPlaceFor(track);
        final art = File('${_home!.path}/$place');
        if (art.existsSync()) {
          cover = place;
        } else {
          try {
            final ask = await client.getUrl(Uri.parse(coverUrl));
            final answer = await ask.close();
            if (answer.statusCode < 400) {
              await art.parent.create(recursive: true);
              await art.writeAsBytes(
                  await answer.fold<List<int>>([], (a, b) => a..addAll(b)));
              cover = place;
            }
          } catch (_) {
            // A missing picture is not a failed download.
          }
        }
      }

      _kept[track.id] = OfflineTrack(
        id: track.id,
        title: track.displayTitle,
        artists: track.artistLine,
        // The record's own name, not the line shown under the title: that one is
        // blank when it would only repeat the title, and a folder needs the name.
        album: track.album,
        durationMs: track.durationMs,
        bytes: await file.length(),
        file: name,
        cover: cover,
        gainDb: track.gainDb,
        keptAt: DateTime.now(),
      );
      await _writeIndex();
    } finally {
      client.close();
      if (into.existsSync()) await into.delete();
    }
  }

  String _extension(Track track) {
    final path = track.streamPath ?? '';
    if (path.endsWith('.mp3')) return '.mp3';
    // Everything ingested here is m4a unless it came from Bandcamp as mp3; the
    // extension only has to be something the player will open.
    return track.source == 'bandcamp' ? '.mp3' : '.m4a';
  }

  // ---------------------------------------------------------------- forgetting
  Future<void> forget(int trackId) async {
    final entry = _kept.remove(trackId);
    _queue.removeWhere((t) => t.id == trackId);
    if (entry != null && _home != null) {
      // The picture stays while another song from the same record is still here.
      final names = [
        entry.file,
        if (entry.cover != null && !_coverShared(entry)) entry.cover!,
      ];
      for (final name in names) {
        final file = File(_absolute(name));
        if (file.existsSync()) await file.delete();
        await _pruneEmpty(file.parent);
      }
    }
    await _writeIndex();
    notifyListeners();
  }

  /// A file named in the index: under the home, unless it could not be moved there
  /// and is still named by where it was.
  String _absolute(String name) =>
      name.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(name)
          ? name
          : '${_home!.path}/$name';

  Future<void> forgetAll() async {
    for (final id in _kept.keys.toList()) {
      await forget(id);
    }
  }

  /// Stop what has not started yet. What is being fetched now finishes — half a file
  /// is worse than either answer.
  void stopWaiting() {
    _queue.clear();
    notifyListeners();
  }
}

/// One song kept on the device. Carries enough of itself to be listed and played with
/// no server in reach.
class OfflineTrack {
  const OfflineTrack({
    required this.id,
    required this.title,
    required this.artists,
    required this.bytes,
    required this.file,
    this.album,
    this.durationMs,
    this.cover,
    this.gainDb,
    required this.keptAt,
  });

  final int id;
  final String title;
  final String artists;
  final String? album;
  final int? durationMs;
  final int bytes;
  final String file;
  final String? cover;
  final double? gainDb;
  final DateTime keptAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artists': artists,
        'album': album,
        'duration_ms': durationMs,
        'bytes': bytes,
        'file': file,
        'cover': cover,
        'gain_db': gainDb,
        'kept_at': keptAt.toIso8601String(),
      };

  /// The same song, filed somewhere else.
  OfflineTrack at({required String file, String? cover}) => OfflineTrack(
        id: id,
        title: title,
        artists: artists,
        album: album,
        durationMs: durationMs,
        bytes: bytes,
        file: file,
        cover: cover,
        gainDb: gainDb,
        keptAt: keptAt,
      );

  factory OfflineTrack.fromJson(Map<String, dynamic> j) => OfflineTrack(
        id: j['id'] as int,
        title: (j['title'] ?? '') as String,
        artists: (j['artists'] ?? '') as String,
        album: j['album'] as String?,
        durationMs: j['duration_ms'] as int?,
        bytes: (j['bytes'] ?? 0) as int,
        file: j['file'] as String,
        cover: j['cover'] as String?,
        gainDb: (j['gain_db'] as num?)?.toDouble(),
        keptAt: DateTime.tryParse((j['kept_at'] ?? '') as String) ?? DateTime.now(),
      );

  /// As a track the rest of the app can show, so a downloaded list is an ordinary list.
  Track get asTrack => Track(
        id: id,
        title: title,
        artists: artists.isEmpty ? const [] : artists.split(', '),
        album: album,
        durationMs: durationMs,
        state: 'ready',
        source: 'youtube',
        streamPath: '/tracks/$id/stream',
        gainDb: gainDb,
      );
}
