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
  /// Who put this on. Only meaningful in a jam, where the queue has several authors.
  final String? addedBy;

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
    this.addedBy,
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
        addedBy: addedBy,
      );

  Track withProgress(Map<String, dynamic>? p) => Track(
        id: id, title: title, artists: artists, album: album,
        durationMs: durationMs, state: state, failReason: failReason,
        failCode: failCode, progress: p, source: source,
        discoveredVia: discoveredVia, gainDb: gainDb, bytes: bytes,
        streamPath: streamPath, coverPath: coverPath, coverColor: coverColor,
        coverVersion: coverVersion, providerId: providerId,
        displayTitle: displayTitle, origin: origin, addedBy: addedBy,
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
        addedBy: j['added_by'] as String?,
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
  final String kind;              // local | spotify | ytmusic
  final int itemCount;
  final List<Track> items;
  /// How many of the source playlist's songs could not be translated.
  final int unmatched;
  final String? sourceName;
  final bool editable;
  /// Art built from the records in it. Every playlist has one; see playlist_art.py.
  final String? coverPath;
  final String? coverVersion;
  /// 'all' — the audio was queued with the list. 'on_play' — a library too big to fetch
  /// up front, where songs arrive when you play them.
  final String downloadMode;

  const Playlist({
    required this.id,
    required this.name,
    required this.kind,
    this.itemCount = 0,
    this.items = const [],
    this.unmatched = 0,
    this.sourceName,
    this.coverPath,
    this.coverVersion,
    this.downloadMode = 'all',
    bool? editable,
  }) : editable = editable ?? (kind == 'local');

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? 'local') as String,
        itemCount: (j['items'] is int) ? j['items'] as int : ((j['items'] ?? const []) as List).length,
        items: (j['items'] is List)
            ? (j['items'] as List).map((e) => Track.fromJson(e as Map<String, dynamic>)).toList()
            : const [],
        unmatched: (j['unmatched'] ?? 0) as int,
        sourceName: j['source_name'] as String?,
        coverPath: j['cover_url'] as String?,
        coverVersion: j['cover_version'] as String?,
        downloadMode: (j['download_mode'] ?? 'all') as String,
        editable: j['editable'] as bool?,
      );

  bool get isMirror => kind != 'local';

  /// True when the songs are listed but the files are not here yet.
  bool get fetchesOnPlay => downloadMode == 'on_play';
}

/// A song in a mirrored playlist that could not be translated into something muse can
/// play. Kept and shown, rather than silently making the playlist shorter.
class UnmatchedTrack {
  final int pos;
  final String title;
  final List<String> artists;
  final String reason;

  const UnmatchedTrack({
    required this.pos,
    required this.title,
    required this.artists,
    required this.reason,
  });

  factory UnmatchedTrack.fromJson(Map<String, dynamic> j) => UnmatchedTrack(
        pos: (j['pos'] ?? 0) as int,
        title: (j['title'] ?? 'Unknown') as String,
        artists: ((j['artists'] ?? const []) as List).cast<String>(),
        reason: (j['reason'] ?? 'Could not be matched') as String,
      );

  String get artistLine => artists.isEmpty ? 'Unknown artist' : artists.join(', ');
}


/// An album, derived from track metadata rather than stored — grouped by name *and*
/// artist, because two records can share a title.
class AlbumSummary {
  final String name;
  final String artist;
  final int tracks;
  final int? year;
  final int? durationMs;
  final String? coverPath;

  const AlbumSummary({
    required this.name,
    required this.artist,
    required this.tracks,
    this.year,
    this.durationMs,
    this.coverPath,
  });

  factory AlbumSummary.fromJson(Map<String, dynamic> j) => AlbumSummary(
        name: (j['name'] ?? '') as String,
        artist: (j['artist'] ?? '') as String,
        tracks: (j['tracks'] ?? 0) as int,
        year: j['year'] as int?,
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        coverPath: j['cover_url'] as String?,
      );

  String get subtitle => [
        artist,
        if (year != null) '$year',
        '$tracks ${tracks == 1 ? 'track' : 'tracks'}',
      ].join(' · ');
}

class ArtistSummary {
  final String name;
  final int tracks;
  final int albums;
  final String? coverPath;

  const ArtistSummary({
    required this.name,
    required this.tracks,
    this.albums = 0,
    this.coverPath,
  });

  factory ArtistSummary.fromJson(Map<String, dynamic> j) => ArtistSummary(
        name: (j['name'] ?? '') as String,
        tracks: (j['tracks'] ?? 0) as int,
        albums: (j['albums'] ?? 0) as int,
        coverPath: j['cover_url'] as String?,
      );

  String get subtitle => [
        '$tracks ${tracks == 1 ? 'track' : 'tracks'}',
        if (albums > 0) '$albums ${albums == 1 ? 'album' : 'albums'}',
      ].join(' · ');
}

/// A track with when it was played. The history had no sense of when until now.
class PlayedTrack {
  final Track track;
  final DateTime? playedAt;
  final bool completed;

  const PlayedTrack({required this.track, this.playedAt, this.completed = false});

  factory PlayedTrack.fromJson(Map<String, dynamic> j) => PlayedTrack(
        track: Track.fromJson(j),
        playedAt: j['played_at'] == null
            ? null
            : DateTime.tryParse(j['played_at'] as String)?.toLocal(),
        completed: (j['completed'] ?? false) as bool,
      );
}


/// A playlist as Spotify describes it. Development mode returns a stripped object —
/// no track count, no images — so those are genuinely unknown until it is mirrored.
class SpotifyPlaylist {
  final String remoteId;
  final String name;
  final String? owner;
  final int? count;
  final int? playlistId;      // set once mirrored into muse
  final int mirroredTracks;
  final int unmatched;

  const SpotifyPlaylist({
    required this.remoteId,
    required this.name,
    this.owner,
    this.count,
    this.playlistId,
    this.mirroredTracks = 0,
    this.unmatched = 0,
  });

  factory SpotifyPlaylist.fromJson(Map<String, dynamic> j) {
    final mirror = j['mirror'] as Map<String, dynamic>?;
    return SpotifyPlaylist(
      remoteId: j['remote_id'] as String,
      name: (j['name'] ?? 'Untitled') as String,
      owner: j['owner'] as String?,
      count: j['count'] as int?,
      playlistId: mirror?['playlist_id'] as int?,
      mirroredTracks: (mirror?['tracks'] ?? 0) as int,
      unmatched: (mirror?['unmatched'] ?? 0) as int,
    );
  }

  bool get isMirrored => playlistId != null;

  String get subtitle {
    if (isMirrored) {
      return [
        '$mirroredTracks in muse',
        if (unmatched > 0) '$unmatched not matched',
      ].join(' · ');
    }
    return [if (owner != null) 'by $owner', if (count != null) '$count songs']
        .join(' · ');
  }
}


/// One import, as a person thinks about it: a name and a progress bar, not a hundred
/// and twenty anonymous rows.
class DownloadBatch {
  final String id;
  final String label;
  final int total;
  final int done;
  final int failed;
  final int remaining;

  const DownloadBatch({
    required this.id,
    required this.label,
    required this.total,
    required this.done,
    required this.failed,
    required this.remaining,
  });

  factory DownloadBatch.fromJson(Map<String, dynamic> j) => DownloadBatch(
        id: (j['batch_id'] ?? '') as String,
        label: (j['label'] ?? 'Import') as String,
        total: (j['total'] ?? 0) as int,
        done: (j['done'] ?? 0) as int,
        failed: (j['failed'] ?? 0) as int,
        remaining: (j['remaining'] ?? 0) as int,
      );

  double get fraction => total == 0 ? 0 : (done + failed) / total;
  bool get finished => remaining == 0;

  String get summary => [
        '$done of $total',
        if (failed > 0) '$failed failed',
      ].join(' · ');
}

/// A queued, running or failed download, with the track behind it.
class DownloadItem {
  final int? jobId;
  final Track? track;
  final String? batchLabel;
  final String? error;
  final Map<String, dynamic>? progress;

  const DownloadItem({this.jobId, this.track, this.batchLabel, this.error,
      this.progress});

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        jobId: j['job_id'] as int?,
        track: j['track'] == null
            ? null
            : Track.fromJson(j['track'] as Map<String, dynamic>),
        batchLabel: j['batch_label'] as String?,
        error: j['error'] as String?,
        progress: (j['progress'] as Map?)?.cast<String, dynamic>(),
      );

  double? get fraction => (progress?['percent'] as num?)?.toDouble();

  String get line {
    final p = progress;
    if (p != null) {
      final pct = fraction;
      return pct == null
          ? '${p['label'] ?? 'Working'}…'
          : '${p['label']} ${(pct * 100).round()}%'
              '${p['speed'] == null ? '' : ' · ${p['speed']}'}';
    }
    return track?.artistLine ?? '';
  }
}

class DownloadOverview {
  final bool paused;
  final bool workerOnline;
  final String? workerName;
  final int waiting;
  final int downloading;
  final int failed;
  final List<DownloadItem> active;
  final List<DownloadItem> queued;
  final List<DownloadItem> failures;
  final List<DownloadBatch> batches;

  /// How many imports are still going, which is not always how many [batches] lists.
  final int batchesTotal;

  const DownloadOverview({
    required this.paused,
    required this.workerOnline,
    this.workerName,
    required this.waiting,
    required this.downloading,
    required this.failed,
    this.active = const [],
    this.queued = const [],
    this.failures = const [],
    this.batches = const [],
    this.batchesTotal = 0,
  });

  factory DownloadOverview.fromJson(Map<String, dynamic> j) {
    final counts = (j['counts'] as Map?) ?? {};
    final worker = (j['worker'] as Map?) ?? {};
    List<DownloadItem> items(String key) =>
        ((j[key] ?? const []) as List).map((e) => DownloadItem.fromJson(e)).toList();
    return DownloadOverview(
      paused: (j['paused'] ?? false) as bool,
      workerOnline: (worker['online'] ?? false) as bool,
      workerName: worker['name'] as String?,
      waiting: (counts['waiting'] ?? 0) as int,
      downloading: (counts['downloading'] ?? 0) as int,
      failed: (counts['failed'] ?? 0) as int,
      active: items('active'),
      queued: items('waiting'),
      failures: items('failed'),
      batchesTotal: (j['batches_total'] ?? (j['batches'] as List?)?.length ?? 0) as int,
      batches: ((j['batches'] ?? const []) as List)
          .map((e) => DownloadBatch.fromJson(e))
          .toList(),
    );
  }

  int get outstanding => waiting + downloading;
  bool get idle => outstanding == 0 && failed == 0;
}


/// How the player draws the artwork.
enum CoverStyle {
  /// The record: a cardboard sleeve that stands up, with the disc sliding out and
  /// turning while it plays.
  record,

  /// The cover on its own, square and still.
  flat;

  String get label => this == CoverStyle.record ? 'Record' : 'Album cover';

  String get description => this == CoverStyle.record
      ? 'The sleeve stands up and the disc spins while it plays'
      : 'The artwork on its own, no animation';
}

/// Someone in a jam.
class JamMember {
  final int userId;
  final String name;
  final bool host;
  final bool online;

  const JamMember({required this.userId, required this.name,
      this.host = false, this.online = false});

  factory JamMember.fromJson(Map<String, dynamic> j) => JamMember(
        userId: (j['user_id'] ?? 0) as int,
        name: (j['name'] ?? '') as String,
        host: (j['host'] ?? false) as bool,
        online: (j['online'] ?? false) as bool,
      );
}

/// A shared queue: the host's device plays, everyone else can put something on.
class Jam {
  final int id;
  final String code;
  final int queueId;
  final String? host;
  final bool isHost;
  final bool guestsCanAdd;
  final bool guestsCanSkip;
  final List<JamMember> members;
  final int listening;
  final Track? nowPlaying;
  final int skipVotes;

  const Jam({
    required this.id,
    required this.code,
    required this.queueId,
    this.host,
    this.isHost = false,
    this.guestsCanAdd = true,
    this.guestsCanSkip = true,
    this.members = const [],
    this.listening = 0,
    this.nowPlaying,
    this.skipVotes = 0,
  });

  factory Jam.fromJson(Map<String, dynamic> j) => Jam(
        id: (j['id'] ?? 0) as int,
        code: (j['code'] ?? '') as String,
        queueId: (j['queue_id'] ?? 0) as int,
        host: j['host'] as String?,
        isHost: (j['is_host'] ?? false) as bool,
        guestsCanAdd: (j['guests_can_add'] ?? true) as bool,
        guestsCanSkip: (j['guests_can_skip'] ?? true) as bool,
        members: ((j['members'] ?? const []) as List)
            .map((e) => JamMember.fromJson(e as Map<String, dynamic>))
            .toList(),
        listening: (j['listening'] ?? 0) as int,
        nowPlaying: j['now_playing'] == null
            ? null
            : Track.fromJson(j['now_playing'] as Map<String, dynamic>),
        skipVotes: (j['skip_votes'] ?? 0) as int,
      );

  /// What a guest is allowed to do, said the way a person would say it.
  String get rules => [
        guestsCanAdd ? 'anyone can add' : 'only the host adds',
        if (guestsCanSkip) 'skipping is a vote',
      ].join(' · ');
}


/// A hit from a source the server fetches itself — SoundCloud, Bandcamp.
class SourceHit {
  final String provider;
  final String providerId;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final String? url;
  /// Already in the library, if it is.
  final Track? track;

  const SourceHit({
    required this.provider,
    required this.providerId,
    required this.title,
    this.artists = const [],
    this.album,
    this.durationMs,
    this.url,
    this.track,
  });

  factory SourceHit.fromJson(Map<String, dynamic> j) => SourceHit(
        provider: (j['provider'] ?? '') as String,
        providerId: (j['provider_id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        artists: ((j['artists'] ?? const []) as List).cast<String>(),
        album: j['album'] as String?,
        durationMs: j['duration_ms'] as int?,
        url: j['url'] as String?,
        track: j['track'] == null
            ? null
            : Track.fromJson(j['track'] as Map<String, dynamic>),
      );

  String get artistLine => artists.join(', ');
  bool get known => track != null;
  String get sourceLabel => provider == 'bandcamp' ? 'Bandcamp' : 'SoundCloud';

  String get lengthLine {
    if (durationMs == null) return '';
    final d = Duration(milliseconds: durationMs!);
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}

/// What is behind a pasted album link, before anything is added.
class AlbumPreview {
  final String? album;
  final String? artist;
  final List<SourceHit> tracks;
  final int unavailable;

  const AlbumPreview({this.album, this.artist, this.tracks = const [],
      this.unavailable = 0});

  factory AlbumPreview.fromJson(Map<String, dynamic> j) => AlbumPreview(
        album: j['album'] as String?,
        artist: j['artist'] as String?,
        tracks: ((j['tracks'] ?? const []) as List)
            .map((e) => SourceHit.fromJson(e as Map<String, dynamic>))
            .toList(),
        unavailable: (j['unavailable'] ?? 0) as int,
      );
}
