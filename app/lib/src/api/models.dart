// Wire models. Everything the server calls a track looks the same here, whether it
// came from YouTube Music or off your own disk.

class Track {
  final int id;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final String state; // pending | downloading | ready | failed
  final String? failReason;
  final String? failCode;
  /// Live ingest state while the audio is being fetched: stage, label, percent.
  final Map<String, dynamic>? progress;
  final String source; // youtube | custom
  final String? discoveredVia;
  final double? gainDb;
  final int? bytes;
  final String? streamPath;
  final String? coverPath;
  /// Dominant colour of the artwork, computed server-side (#rrggbb).
  final String? coverColor;
  final String? providerId;
  /// Changes when the artwork changes, so a cached image is not shown forever.
  final String? coverVersion;
  /// Platform noise stripped for display; `title` keeps whatever the source said.
  final String displayTitle;
  final String origin; // user | autoplay | radio (queue items only)

  const Track({
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    this.durationMs,
    required this.state,
    this.failReason,
    this.failCode,
    this.progress,
    required this.source,
    this.discoveredVia,
    this.gainDb,
    this.bytes,
    this.streamPath,
    this.coverPath,
    this.coverColor,
    this.providerId,
    this.coverVersion,
    String? displayTitle,
    this.origin = 'user',
  }) : displayTitle = displayTitle ?? title;

  /// Queue membership carries `origin`, which a freshly fetched track does not know.
  Track copyWithOrigin(String origin) => Track(
        id: id,
        title: title,
        artists: artists,
        album: album,
        durationMs: durationMs,
        state: state,
        failReason: failReason,
        failCode: failCode,
        progress: progress,
        source: source,
        discoveredVia: discoveredVia,
        gainDb: gainDb,
        bytes: bytes,
        streamPath: streamPath,
        coverPath: coverPath,
        coverColor: coverColor,
        coverVersion: coverVersion,
        providerId: providerId,
        displayTitle: displayTitle,
        origin: origin,
      );

  Track withProgress(Map<String, dynamic>? p) => Track(
        id: id, title: title, artists: artists, album: album,
        durationMs: durationMs, state: state, failReason: failReason,
        failCode: failCode, progress: p, source: source,
        discoveredVia: discoveredVia, gainDb: gainDb, bytes: bytes,
        streamPath: streamPath, coverPath: coverPath, coverColor: coverColor,
        coverVersion: coverVersion, providerId: providerId,
        displayTitle: displayTitle, origin: origin,
      );

  bool get isReady => state == 'ready' && streamPath != null;

  double? get progressFraction => (progress?['percent'] as num?)?.toDouble();

  /// What to tell someone looking at this row right now.
  String get statusLine {
    if (state == 'failed') return failReason ?? 'Download failed';
    final p = progress;
    if (p != null) {
      final label = (p['label'] ?? 'Working') as String;
      final pct = progressFraction;
      final speed = p['speed'] as String?;
      if (pct == null) return '$label…';
      return '$label ${(pct * 100).round()}%'
          '${speed != null && speed.trim().isNotEmpty ? ' · $speed' : ''}';
    }
    if (isPending) return failReason ?? 'Waiting to download';
    return artistLine;
  }
  bool get hasCover => coverPath != null;
  /// Hide an album line that only repeats the title. Singles are usually released
  /// under their own name, so "Around the World (Radio Edit) · Around the World" is
  /// the common case rather than the exception.
  String? get albumLine {
    final a = album;
    if (a == null || a.trim().isEmpty) return null;
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    final na = norm(a), nt = norm(displayTitle);
    if (na.isEmpty || na == nt || nt.startsWith(na) || na.startsWith(nt)) return null;
    return a;
  }
  bool get isPending => state == 'pending' || state == 'downloading';
  String get artistLine => artists.isEmpty ? 'Unknown artist' : artists.join(', ');
  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  factory Track.fromJson(Map<String, dynamic> j) => Track(
        id: j['id'] as int,
        title: (j['title'] ?? 'Untitled') as String,
        artists: ((j['artists'] ?? const []) as List).cast<String>(),
        album: j['album'] as String?,
        durationMs: j['duration_ms'] as int?,
        state: (j['state'] ?? 'pending') as String,
        failReason: j['fail_reason'] as String?,
        failCode: j['fail_code'] as String?,
        progress: (j['progress'] as Map?)?.cast<String, dynamic>(),
        source: (j['source'] ?? 'youtube') as String,
        discoveredVia: j['discovered_via'] as String?,
        gainDb: (j['gain_db'] as num?)?.toDouble(),
        bytes: j['bytes'] as int?,
        streamPath: j['stream_url'] as String?,
        coverPath: j['cover_url'] as String?,
        coverColor: j['cover_color'] as String?,
        providerId: j['provider_id'] as String?,
        coverVersion: j['cover_version'] as String?,
        displayTitle: j['display_title'] as String?,
        origin: (j['origin'] ?? 'user') as String,
      );
}

/// A remote search hit that is not in the library yet.
class RemoteHit {
  final String videoId;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final bool known;
  /// Artwork for something not in the library yet, proxied through our own server.
  final String? coverPath;

  const RemoteHit({
    required this.videoId,
    required this.title,
    required this.artists,
    this.album,
    this.durationMs,
    this.known = false,
    this.coverPath,
  });

  factory RemoteHit.fromJson(Map<String, dynamic> j) => RemoteHit(
        videoId: j['video_id'] as String,
        title: (j['title'] ?? '') as String,
        artists: ((j['artists'] ?? const []) as List).cast<String>(),
        album: j['album'] as String?,
        durationMs: j['duration_ms'] as int?,
        known: (j['known'] ?? false) as bool,
        coverPath: j['cover_url'] as String?,
      );

  /// Enough of a Track to render a row with artwork before anything is downloaded.
  Track asPreview() => Track(
        id: -1,
        title: title,
        artists: artists,
        album: album,
        durationMs: durationMs,
        state: 'remote',
        source: 'youtube',
        coverPath: coverPath,
      );

  String get artistLine => artists.isEmpty ? 'Unknown artist' : artists.join(', ');
}

/// A queue is an object, not "the" queue: it has a name, its own order, its own
/// cursor and its own shuffle/repeat, and switching to it resumes where it was.
class Queue {
  final int id;
  final String name;
  final int cursorIndex;
  final int positionMs;
  final bool shuffle;
  final String repeat;
  final int rev;
  final List<Track> items;

  /// The list endpoint returns `items` as a COUNT and the detail endpoint returns it
  /// as a LIST. Assuming one shape threw a TypeError on every login that had a queue,
  /// which left the app signed in but with no queues, no playlists and no live events.
  final int itemCount;

  const Queue({
    required this.id,
    required this.name,
    required this.cursorIndex,
    required this.positionMs,
    required this.shuffle,
    required this.repeat,
    required this.rev,
    this.items = const [],
    int? itemCount,
  }) : itemCount = itemCount ?? items.length;

  factory Queue.fromJson(Map<String, dynamic> j) => Queue(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        cursorIndex: (j['cursor_index'] ?? 0) as int,
        positionMs: (j['position_ms'] ?? 0) as int,
        shuffle: (j['shuffle'] ?? false) as bool,
        repeat: (j['repeat'] ?? 'off') as String,
        rev: (j['rev'] ?? 1) as int,
        items: j['items'] is List
            ? (j['items'] as List)
                .map((e) => Track.fromJson(e as Map<String, dynamic>))
                .toList()
            : const [],
        itemCount: j['items'] is int ? j['items'] as int : null,
      );
}

class Playlist {
  final int id;
  final String name;
  final String kind;
  final int itemCount;
  final List<Track> items;

  const Playlist({
    required this.id,
    required this.name,
    required this.kind,
    this.itemCount = 0,
    this.items = const [],
  });

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? 'local') as String,
        itemCount: (j['items'] is int) ? j['items'] as int : ((j['items'] ?? const []) as List).length,
        items: (j['items'] is List)
            ? (j['items'] as List).map((e) => Track.fromJson(e as Map<String, dynamic>)).toList()
            : const [],
      );
}
