import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
  Directory? _home;

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
    final file = File('${_home!.path}/${entry.file}');
    return file.existsSync() ? file.path : null;
  }

  String? coverFor(int trackId) {
    final entry = _kept[trackId];
    if (entry == null || entry.cover == null || _home == null) return null;
    final file = File('${_home!.path}/${entry.cover}');
    return file.existsSync() ? file.path : null;
  }

  Future<void> init() async {
    if (!supported) return;
    try {
      final base = await getApplicationSupportDirectory();
      _home = Directory('${base.path}/offline');
      await _home!.create(recursive: true);
      await _readIndex();
      notifyListeners();
    } catch (e) {
      lastError = 'Cannot keep music here: $e';
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
        if (File('${_home!.path}/${t.file}').existsSync()) _kept[t.id] = t;
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
    final name = 'track-${track.id}${_extension(track)}';
    final into = File('${_home!.path}/$name.part');
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
      String? cover;
      final coverUrl = api.coverUrl(track, small: false);
      if (coverUrl != null) {
        try {
          final art = await client.getUrl(Uri.parse(coverUrl));
          final answer = await art.close();
          if (answer.statusCode < 400) {
            cover = 'cover-${track.id}.jpg';
            await File('${_home!.path}/$cover')
                .writeAsBytes(await answer.fold<List<int>>([], (a, b) => a..addAll(b)));
          }
        } catch (_) {
          // A missing picture is not a failed download.
        }
      }

      _kept[track.id] = OfflineTrack(
        id: track.id,
        title: track.displayTitle,
        artists: track.artistLine,
        album: track.albumLine,
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
      for (final name in [entry.file, entry.cover]) {
        if (name == null) continue;
        final file = File('${_home!.path}/$name');
        if (file.existsSync()) await file.delete();
      }
    }
    await _writeIndex();
    notifyListeners();
  }

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
