import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../api/connection.dart';

/// Artwork kept on the device, not fetched again every time the app opens.
///
/// Flutter's own image cache lives in memory and dies with the process, so every cold
/// start re-downloaded every cover that scrolled past — on a queue of a few hundred
/// songs that is a few hundred requests before anything is on screen, and on a phone
/// away from wifi it is why covers arrive one at a time behind a grey square.
///
/// The server already says these never change (`immutable`, a year), and the URL
/// carries the artwork's own hash, so a file on disk is as good as a fresh request for
/// ever. This is that file.
///
/// Nothing here on the web: a browser has its own disk cache and is already honouring
/// those headers.
class ArtCache {
  static Directory? _dir;
  static int _writes = 0;

  /// How much artwork is worth keeping. A small cover is a few kilobytes and a large
  /// one a few dozen; a couple of hundred megabytes is a very large library's worth,
  /// and it is bounded so it cannot quietly become the largest thing on the phone.
  static const int maxBytes = 220 * 1024 * 1024;

  static bool get supported => !kIsWeb;

  static Future<void> open() async {
    if (!supported || _dir != null) return;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/art');
      await dir.create(recursive: true);
      _dir = dir;
      unawaited(_prune());
    } catch (_) {
      // No filesystem, no cache. Everything still works, just over the wire.
    }
  }

  /// A name for this picture that survives a new session.
  ///
  /// The signing key in the query changes every time the app signs in, so keying on
  /// the whole URL would file the same cover under a new name each session and the
  /// cache would never hit. What identifies the image is the path and the rest of the
  /// query — which already contains the artwork's own hash.
  static String keyFor(String url) {
    final uri = Uri.parse(url);
    final parts = <String>[
      uri.path,
      for (final e in uri.queryParameters.entries)
        if (e.key != 'k') '${e.key}=${e.value}',
    ];
    final raw = parts.join('&');
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  }

  static File? fileFor(String url) {
    final dir = _dir;
    return dir == null ? null : File('${dir.path}/${keyFor(url)}');
  }

  /// True if this picture is already here — no request, no wait.
  static bool has(String url) {
    final file = fileFor(url);
    return file != null && file.existsSync();
  }

  /// The bytes, from disk if they are there and from the server if they are not.
  static Future<Uint8List?> bytes(String url) async {
    final file = fileFor(url);
    if (file != null) {
      try {
        if (await file.exists()) {
          final got = await file.readAsBytes();
          if (got.isNotEmpty) return got;
        }
      } catch (_) {
        // A file we cannot read is a file we fetch again.
      }
    }

    final Uint8List got;
    try {
      final r = await net.get(Uri.parse(url));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      got = r.bodyBytes;
    } catch (_) {
      return null;
    }

    if (file != null) {
      // Written beside and renamed, so a half-written file is never read back as a
      // half-drawn cover.
      unawaited(() async {
        try {
          final part = File('${file.path}.part');
          await part.writeAsBytes(got, flush: true);
          await part.rename(file.path);
          if (++_writes % 200 == 0) await _prune();
        } catch (_) {}
      }());
    }
    return got;
  }

  /// Fetch these in the background, a few at a time, and stop at the first sign that
  /// nobody is waiting for them.
  ///
  /// Four at once: enough that a queue's worth arrives while somebody is still looking
  /// at the first screen of it, few enough that it is not competing with the song
  /// being streamed for the same connection.
  static Future<void> warm(Iterable<String> urls, {int limit = 240}) async {
    if (!supported || _dir == null) return;
    final wanted = <String>[];
    for (final url in urls) {
      if (wanted.length >= limit) break;
      if (!has(url)) wanted.add(url);
    }
    if (wanted.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (next < wanted.length) {
        final url = wanted[next++];
        await bytes(url);
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
  }

  static Future<int> size() async {
    final dir = _dir;
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final entry in dir.list()) {
        if (entry is File) total += await entry.length();
      }
    } catch (_) {}
    return total;
  }

  static Future<void> forgetAll() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    } catch (_) {}
  }

  /// Oldest first, until it is back under the cap.
  static Future<void> _prune() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final files = <File>[];
      var total = 0;
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        files.add(entry);
        total += await entry.length();
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final file in files) {
        if (total <= maxBytes * 0.8) break;
        total -= await file.length();
        await file.delete();
      }
    } catch (_) {}
  }
}

/// An image that comes off the disk when it is there.
///
/// The same shape as NetworkImage from the outside — it is handed to an Image widget
/// and behaves — but the bytes come through [ArtCache], so the second time the app is
/// opened the picture is already here.
@immutable
class ArtImage extends ImageProvider<ArtImage> {
  const ArtImage(this.url, {this.scale = 1.0});

  final String url;
  final double scale;

  @override
  Future<ArtImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<ArtImage>(this);

  @override
  ImageStreamCompleter loadImage(ArtImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, decode),
        scale: key.scale,
        debugLabel: key.url,
      );

  Future<ui.Codec> _load(ArtImage key, ImageDecoderCallback decode) async {
    final bytes = await ArtCache.bytes(key.url);
    if (bytes == null || bytes.isEmpty) {
      // Evicted, or the Image widget keeps a broken entry and never tries again.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      throw StateError('no artwork at ${key.url}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is ArtImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'ArtImage("$url")';
}

/// The right provider for wherever this is running.
ImageProvider artwork(String url) =>
    ArtCache.supported ? ArtImage(url) : NetworkImage(url);
