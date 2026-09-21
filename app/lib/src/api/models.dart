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
  final String source; // youtube | soundcloud | bandcamp | custom
  final String? discoveredVia;
  final double? gainDb;

  /// How loud the track was measured to be, in LUFS. The player normalises with
  /// [gainDb]; this is the raw figure, and it is what the halftone breathes to.
  final double? loudnessLufs;
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

  /// Who that is, and the picture they chose — so a queue in a jam can show a face
  /// against a song rather than a name nobody reads in a list of forty.
  final int? addedById;
  final String? addedByAvatar;

  /// Which row of a queue this is, when it came from one.
  ///
  /// A queue can hold the same song twice — radio produces that, and so does adding a
  /// favourite again — and two rows that are the same track are the same track: there
  /// is nothing in the song itself to tell copy one from copy two. The row has a name
  /// of its own for exactly that, and unlike its position it does not change when
  /// something is inserted above it.
  final int? queueItemId;

  /// Where that row sits in the queue as it stands.
  final int? queuePos;

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
    this.loudnessLufs,
    this.bytes,
    this.streamPath,
    this.coverPath,
    this.coverColor,
    this.providerId,
    this.coverVersion,
    String? displayTitle,
    this.origin = 'user',
    this.addedBy,
    this.addedById,
    this.addedByAvatar,
    this.queueItemId,
    this.queuePos,
  }) : displayTitle = displayTitle ?? title;

  /// This song's fresh details, sitting in the queue row [row] was sitting in.
  ///
  /// A freshly fetched track knows nothing about the queue: not who added it, not
  /// where it sits, and not which *row* it is. Losing the row name is the expensive
  /// one — with a song in the queue twice, the player could no longer tell its copies
  /// apart, disagreed with the engine about which was playing, and hopped between them.
  Track inRowOf(Track row) => Track(
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
        loudnessLufs: loudnessLufs,
        bytes: bytes,
        streamPath: streamPath,
        coverPath: coverPath,
        coverColor: coverColor,
        coverVersion: coverVersion,
        providerId: providerId,
        displayTitle: displayTitle,
        origin: row.origin,
        addedBy: row.addedBy,
        addedById: row.addedById,
        addedByAvatar: row.addedByAvatar,
        queueItemId: row.queueItemId,
        queuePos: row.queuePos,
      );

  Track withProgress(Map<String, dynamic>? p) => Track(
        id: id, title: title, artists: artists, album: album,
        durationMs: durationMs, state: state, failReason: failReason,
        failCode: failCode, progress: p, source: source,
        discoveredVia: discoveredVia, gainDb: gainDb, bytes: bytes,
        streamPath: streamPath, coverPath: coverPath, coverColor: coverColor,
        coverVersion: coverVersion, providerId: providerId,
        displayTitle: displayTitle, origin: origin, addedBy: addedBy,
        addedById: addedById, addedByAvatar: addedByAvatar,
        queueItemId: queueItemId, queuePos: queuePos,
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
    if (isPending) return failReason ?? 'Not downloaded yet';
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

  /// Actually coming down the wire right now.
  ///
  /// `pending` means only "no file here yet", and in a mirrored library that is true of
  /// twenty thousand songs nobody has asked for. Showing all of them a spinner said
  /// every one of them was stuck; the spinner belongs to the ones the worker has in
  /// hand, which is exactly the ones reporting progress.
  bool get isDownloading =>
      state == 'downloading' || (state == 'pending' && progress != null);

  /// Listed, but not here — and not on its way either.
  bool get isNotFetched => isPending && !isDownloading;
  String get artistLine => artists.isEmpty ? 'Unknown artist' : artists.join(', ');

  /// Where this recording came from, named only when it is worth naming. Almost
  /// everything is from YouTube, so saying so on every row is noise; a song that came
  /// from Bandcamp or SoundCloud is worth knowing about — the quality differs, and so
  /// does who got paid.
  String? get sourceLabel => switch (source) {
        'soundcloud' => 'SoundCloud',
        'bandcamp' => 'Bandcamp',
        'custom' => 'Your upload',
        _ => null,
      };
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
        loudnessLufs: (j['loudness_lufs'] as num?)?.toDouble(),
        bytes: j['bytes'] as int?,
        streamPath: j['stream_url'] as String?,
        coverPath: j['cover_url'] as String?,
        coverColor: j['cover_color'] as String?,
        providerId: j['provider_id'] as String?,
        coverVersion: j['cover_version'] as String?,
        displayTitle: j['display_title'] as String?,
        origin: (j['origin'] ?? 'user') as String,
        addedBy: j['added_by'] as String?,
        addedById: j['added_by_id'] as int?,
        addedByAvatar: j['added_by_avatar'] as String?,
        // Only a queue sends these; everywhere else a track has no row of its own.
        queueItemId: (j['item_id'] as num?)?.toInt(),
        queuePos: (j['pos'] as num?)?.toInt(),
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

  /// Whose jam this queue belongs to, when it is not yours. A guest listening with
  /// somebody else needs to see that queue in their own list, or they lose it the
  /// moment anything reopens a queue for them.
  final String? sharedFrom;

  /// How long the queue really is, and where the part of it we have starts.
  ///
  /// A queue of fourteen thousand songs is sent a slice at a time: seven megabytes of
  /// JSON and fourteen thousand objects is a browser on a phone being killed and a
  /// browser on a laptop locking up every time anything changes. [items] is the slice,
  /// [total] is the queue, and [windowFrom] is which row of it the slice starts at.
  final int total;
  final int windowFrom;

  /// True when what is here is only part of it.
  bool get windowed => total > items.length;

  /// What this queue is a station of — "track", "album", "artist" — or null when it
  /// is an ordinary queue somebody built themselves. A station is a queue that can be
  /// asked for more of the same when it runs down.
  final String? stationKind;

  const Queue({
    required this.id,
    required this.name,
    required this.cursorIndex,
    required this.positionMs,
    required this.shuffle,
    required this.repeat,
    required this.rev,
    this.items = const [],
    this.sharedFrom,
    this.stationKind,
    this.windowFrom = 0,
    int? total,
    int? itemCount,
  })  : itemCount = itemCount ?? items.length,
        total = total ?? itemCount ?? items.length;

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
        total: j['total'] as int?,
        windowFrom: (j['window_from'] ?? 0) as int,
        sharedFrom: j['shared_from'] as String?,
        stationKind: j['station'] is Map
            ? ((j['station'] as Map)['kind'] as String?)
            : null,
      );

  /// A queue that keeps going.
  bool get isStation => stationKind != null;
}

/// Somebody else on this server.
///
/// The catalog has always been shared; this is the part of that you can see. What
/// matters on the list is the jam: a jam is happening now, and a thing happening now
/// is no use to anybody who has to go looking for it.
class Person {
  const Person({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.avatarVersion,
    this.songs = 0,
    this.playlists = 0,
    this.played = 0,
    this.lastSeen,
    this.lastListened,
    this.jam,
    this.playing,
    this.recent = const [],
    this.since,
  });

  final int id;
  final String name;
  final String? avatarUrl;
  final String? avatarVersion;
  final int songs;
  final int playlists;

  /// Records listened to all the way through.
  final int played;
  final DateTime? lastSeen;
  final DateTime? lastListened;
  final DateTime? since;

  /// The jam they are hosting right now, if any.
  final JamGlimpse? jam;

  /// What they have on. Null when nobody has heard from them in half an hour.
  final NowPlaying? playing;

  /// What they have been playing.
  final List<Track> recent;

  static DateTime? _when(Object? v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  factory Person.fromJson(Map<String, dynamic> j) => Person(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        avatarUrl: j['avatar_url'] as String?,
        avatarVersion: j['avatar_version'] as String?,
        songs: (j['songs'] ?? 0) as int,
        playlists: (j['playlists'] ?? 0) as int,
        played: (j['played'] ?? 0) as int,
        lastSeen: _when(j['last_seen']),
        lastListened: _when(j['last_listened']),
        since: _when(j['since']),
        jam: j['jam'] is Map
            ? JamGlimpse.fromJson((j['jam'] as Map).cast<String, dynamic>())
            : null,
        playing: j['playing'] is Map
            ? NowPlaying.fromJson((j['playing'] as Map).cast<String, dynamic>())
            : null,
        recent: ((j['recent'] ?? const []) as List)
            .map((e) => Track.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// What somebody has on, and how long ago that was true.
///
/// Worked out from the place their player keeps in its queue, which it writes down
/// every ten seconds while it is playing — so this is a fact the server already had
/// and nobody had ever read out.
class NowPlaying {
  const NowPlaying({required this.track, this.queue, this.at, this.now = false});

  final Track track;

  /// The queue it is coming from, which is often the most interesting part: "Evening"
  /// says more than the name of one song.
  final String? queue;
  final DateTime? at;

  /// Whether this is happening rather than having happened. A pause stamps the queue
  /// too, so it goes quiet a minute and a half after somebody stops.
  final bool now;

  factory NowPlaying.fromJson(Map<String, dynamic> j) => NowPlaying(
        track: Track.fromJson((j['track'] as Map).cast<String, dynamic>()),
        queue: j['queue'] as String?,
        at: j['at'] == null ? null : DateTime.tryParse('${j['at']}')?.toLocal(),
        now: (j['now'] ?? false) as bool,
      );
}

/// One of the things this account listens on.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    this.platform,
    this.kind,
    this.isThis = false,
    this.live = false,
    this.playing = false,
    this.positionMs = 0,
    this.queue,
    this.queueId,
    this.track,
    this.lastSeen,
    this.ageMs = 0,
    this.itemId,
    this.heardAt,
  });

  final int id;
  final String name;
  final String? platform;
  final String? kind;

  /// Whether this is the device you are holding.
  final bool isThis;

  /// Whether it has said anything in the last minute. One that has not is still
  /// listed — it is still yours — but it is not offering to play anything.
  final bool live;
  final bool playing;
  final int positionMs;
  final String? queue;
  final int? queueId;
  final Track? track;
  final DateTime? lastSeen;

  /// How old [positionMs] already was when the server handed it over, and when this
  /// device heard it: together, how far the music has moved since it was true.
  final int ageMs;
  final DateTime? heardAt;

  /// Which row of its queue it is on.
  final int? itemId;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: (j['id'] ?? 0) as int,
        name: (j['name'] ?? 'A device') as String,
        platform: j['platform'] as String?,
        kind: j['kind'] as String?,
        isThis: (j['this'] ?? false) as bool,
        live: (j['live'] ?? false) as bool,
        playing: (j['playing'] ?? false) as bool,
        positionMs: (j['position_ms'] ?? 0) as int,
        queue: j['queue'] as String?,
        queueId: j['queue_id'] as int?,
        track: j['track'] is Map
            ? Track.fromJson((j['track'] as Map).cast<String, dynamic>())
            : null,
        lastSeen: j['last_seen'] == null
            ? null
            : DateTime.tryParse('${j['last_seen']}')?.toLocal(),
        ageMs: (j['age_ms'] ?? 0) as int,
        itemId: j['item_id'] as int?,
        heardAt: DateTime.now(),
      );

  /// The same device, having just said something new about itself.
  DeviceInfo saying({required bool playing, required int positionMs, int? itemId}) =>
      DeviceInfo(
        id: id,
        name: name,
        platform: platform,
        kind: kind,
        isThis: isThis,
        live: true,
        playing: playing,
        positionMs: positionMs,
        queue: queue,
        queueId: queueId,
        track: track,
        lastSeen: lastSeen,
        itemId: itemId ?? this.itemId,
        heardAt: DateTime.now(),
      );

  /// Where it has got to *now*: what it said, carried forward while it plays. What it
  /// said alone is up to ten seconds old, which on a seek bar is a thumb that stands
  /// still and then jumps.
  Duration get at {
    final heard = heardAt;
    if (!playing || heard == null) return Duration(milliseconds: positionMs);
    return Duration(milliseconds: positionMs + ageMs) + DateTime.now().difference(heard);
  }
}

/// Enough of somebody's jam to say it is happening and to get into it.
class JamGlimpse {
  const JamGlimpse({required this.code, this.people = 0, this.since});
  final String code;
  final int people;
  final DateTime? since;

  factory JamGlimpse.fromJson(Map<String, dynamic> j) => JamGlimpse(
        code: (j['code'] ?? '') as String,
        people: (j['people'] ?? 0) as int,
        since: j['since'] == null
            ? null
            : DateTime.tryParse('${j['since']}')?.toLocal(),
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

  /// True when somebody chose a picture rather than letting one be drawn.
  final bool customCover;
  /// 'all' — the audio was queued with the list. 'on_play' — a library too big to fetch
  /// up front, where songs arrive when you play them.
  final String downloadMode;

  /// How many songs in it have no audio here yet.
  ///
  /// Separate from [downloadMode], which only says what was *meant* to happen when the
  /// playlist was made. A playlist marked "download everything" whose songs were all
  /// already in the catalog had nothing queued for it at all, and this is the number
  /// that catches that.
  final int waiting;

  /// Yours, or somebody else's kept in your library.
  final bool mine;

  /// You have kept somebody else's list.
  final bool saved;

  /// Its owner let everybody add to it.
  final bool openEdit;

  /// Whose it is, when it is not yours.
  final String? ownerName;
  final int? ownerId;

  const Playlist({
    required this.id,
    required this.name,
    required this.kind,
    this.itemCount = 0,
    this.items = const [],
    this.customCover = false,
    this.unmatched = 0,
    this.sourceName,
    this.coverPath,
    this.coverVersion,
    this.downloadMode = 'all',
    this.waiting = 0,
    this.mine = true,
    this.saved = false,
    this.openEdit = false,
    this.ownerName,
    this.ownerId,
    bool? editable,
  }) : editable = editable ??
            ((kind == 'local' || kind == 'favourites') && mine);

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
        customCover: (j['custom_cover'] ?? false) as bool,
        downloadMode: (j['download_mode'] ?? 'all') as String,
        waiting: (j['waiting'] ?? 0) as int,
        // A list of your own says nothing about ownership; one of somebody else's
        // says both whose it is and that it is theirs.
        mine: j['mine'] as bool? ?? !(j['saved'] == true),
        saved: j['saved'] == true,
        openEdit: j['open_edit'] == true,
        ownerName: j['owner_name'] as String? ??
            (j['owner'] is Map ? (j['owner'] as Map)['name'] as String? : null),
        ownerId: j['owner'] is Map ? (j['owner'] as Map)['id'] as int? : null,
        editable: j['editable'] as bool?,
      );

  bool get isMirror => kind != 'local' && kind != 'favourites';

  /// The one playlist nobody made and nobody can remove.
  bool get isFavourites => kind == 'favourites';

  /// True when the songs are listed but the files are not here yet.
  bool get fetchesOnPlay => downloadMode == 'on_play';

  /// Worth offering to fetch the whole thing: something in it has no audio.
  bool get hasHoles => waiting > 0;
}

/// What one account actually listened to, over one stretch of time.
///
/// Every play has been written down since the first day — one row per listen — and the
/// only questions ever asked of it were "what did I play recently" and a single
/// lifetime tally. This is the ordinary one: what have I been listening to this month.
class Listening {
  final int whoId;
  final String whoName;
  final String since;
  final List<({int id, String name})> people;
  final int plays;
  final int started;
  final int minutes;
  final int tracks;
  final List<PlayedOften> songs;
  final List<CountedRow> artists;
  final List<CountedRow> albums;

  const Listening({
    required this.whoId,
    required this.whoName,
    required this.since,
    required this.people,
    required this.plays,
    required this.started,
    required this.minutes,
    required this.tracks,
    required this.songs,
    required this.artists,
    required this.albums,
  });

  factory Listening.fromJson(Map<String, dynamic> j) {
    // Typed empties: a bare `const {}` is a Map<dynamic, dynamic>, and casting that to
    // Map<String, dynamic> throws — so a reply missing either part failed whole.
    final who = (j['who'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final totals = (j['totals'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    return Listening(
      whoId: (who['id'] ?? 0) as int,
      whoName: (who['name'] ?? '') as String,
      since: (j['since'] ?? 'month') as String,
      people: [
        for (final p in (j['people'] ?? const []) as List)
          (id: (p['id'] ?? 0) as int, name: (p['name'] ?? '') as String)
      ],
      plays: (totals['plays'] ?? 0) as int,
      started: (totals['started'] ?? 0) as int,
      minutes: (totals['minutes'] ?? 0) as int,
      tracks: (totals['tracks'] ?? 0) as int,
      songs: [
        for (final x in (j['songs'] ?? const []) as List) PlayedOften.fromJson(x)
      ],
      artists: [
        for (final x in (j['artists'] ?? const []) as List) CountedRow.fromJson(x)
      ],
      albums: [
        for (final x in (j['albums'] ?? const []) as List) CountedRow.fromJson(x)
      ],
    );
  }

  bool get isEmpty => plays == 0 && started == 0;
}

/// A song, and how often it was played.
class PlayedOften {
  final int id;
  final String title;
  final List<String> artists;
  final String? album;
  final int plays;
  final int started;
  final int minutes;
  final String? coverPath;

  /// Its place on this chart, and on the one before: null there means it was not on
  /// the last one — a new entry. And how many charts it has been on, looking back.
  final int? rank;
  final int? lastRank;
  final int charts;

  const PlayedOften({
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    required this.plays,
    required this.started,
    required this.minutes,
    this.coverPath,
    this.rank,
    this.lastRank,
    this.charts = 0,
  });

  factory PlayedOften.fromJson(Map<String, dynamic> j) => PlayedOften(
        id: (j['id'] ?? 0) as int,
        title: (j['title'] ?? '') as String,
        artists: ((j['artists'] ?? const []) as List).cast<String>(),
        album: j['album'] as String?,
        plays: (j['plays'] ?? 0) as int,
        started: (j['started'] ?? 0) as int,
        minutes: (((j['ms'] ?? 0) as num) / 60000).round(),
        coverPath: j['cover_url'] as String?,
        rank: j['rank'] as int?,
        lastRank: j['last_rank'] as int?,
        charts: (j['charts'] ?? 0) as int,
      );

  String get artistLine => artists.isEmpty ? 'Unknown artist' : artists.join(', ');
}

/// An artist or a record, and how much of it was played.
class CountedRow {
  final String name;
  final String? subtitle;
  final int plays;
  final int minutes;

  const CountedRow(
      {required this.name, this.subtitle, required this.plays,
      required this.minutes});

  factory CountedRow.fromJson(Map<String, dynamic> j) => CountedRow(
        name: (j['name'] ?? '') as String,
        subtitle: j['artist'] as String?,
        plays: (j['plays'] ?? 0) as int,
        minutes: (((j['ms'] ?? 0) as num) / 60000).round(),
      );
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

  /// The list Shazam keeps here. Worth saying out loud because it is the answer to
  /// "can muse have my Shazams" — and because in an account with four hundred
  /// playlists it is otherwise impossible to find.
  final bool isShazam;

  const SpotifyPlaylist({
    required this.remoteId,
    required this.name,
    this.owner,
    this.count,
    this.playlistId,
    this.mirroredTracks = 0,
    this.unmatched = 0,
    this.isShazam = false,
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
      isShazam: (j['shazam'] ?? false) as bool,
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

/// One line drawn on the back of a sleeve.
///
/// Points are in the sleeve's own square, 0 to 1, so a drawing made on a phone is the
/// same drawing on a laptop and the same one again when the record is small on a shelf.
class SleeveStroke {
  const SleeveStroke({
    required this.id,
    required this.ink,
    required this.width,
    required this.points,
    this.done = false,
    this.authorId,
    this.author,
    this.authorAvatar,
  });

  final String id;

  /// An index into the palette rather than a colour. The palette is the app's business
  /// and can get prettier; a board drawn on today should still look right after it has.
  final int ink;
  final double width;

  /// x, y, x, y… flat, because that is how it goes over the wire and how it is drawn.
  final List<double> points;
  final bool done;

  final int? authorId;
  final String? author;
  final String? authorAvatar;

  SleeveStroke copyWith({List<double>? points, bool? done}) => SleeveStroke(
        id: id,
        ink: ink,
        width: width,
        points: points ?? this.points,
        done: done ?? this.done,
        authorId: authorId,
        author: author,
        authorAvatar: authorAvatar,
      );

  factory SleeveStroke.fromJson(Map<String, dynamic> j) => SleeveStroke(
        id: (j['stroke_id'] ?? '') as String,
        ink: (j['ink'] ?? 0) as int,
        width: ((j['width'] ?? 1.0) as num).toDouble(),
        points: [for (final v in (j['points'] ?? const []) as List) (v as num).toDouble()],
        done: (j['done'] ?? false) as bool,
        authorId: j['author_id'] as int?,
        author: j['author'] as String?,
        authorAvatar: j['author_avatar'] as String?,
      );
}

/// Which way the records travel when the song changes.
enum ShelfAxis {
  /// A shelf: the record you are on slides off to the left and the next one takes its
  /// place, the way you would flip through a crate.
  sideways,

  /// A stack: the record lifts away upwards and the next one comes up under it.
  upwards;

  String get label =>
      this == ShelfAxis.sideways ? 'Side to side' : 'Up and down';

  String get description => this == ShelfAxis.sideways
      ? 'Records move across, like flipping through a crate'
      : 'Records move up, like lifting one off a stack';
}

/// Where the player's controls live.
///
/// Three arrangements rather than one, because this is the screen people look at most
/// and there is no answer that suits everybody: the icons used to be in the top
/// corners, which is furthest from a thumb; grouping them under the transport put them
/// where the hand already is; and giving the whole panel more room suits a phone used
/// one-handed.
/// Which arm is on the deck, if any.
///
/// Three ways of drawing the same machine, because the record is the one part of this
/// app somebody sits and looks at, and what reads as right there is a matter of taste
/// rather than of correctness. And off, because an arm across the label is still a
/// thing between somebody and the artwork.
/// One row of a search, whatever it is and wherever it came from.
///
/// A song in your library, a record on YouTube Music and an artist on Spotify all
/// arrive in this one shape, because the list they go in is one list. What differs
/// between them is what tapping does, which is [kind] and [place].
class Found {
  const Found({
    required this.kind,
    required this.place,
    required this.id,
    required this.title,
    required this.subtitle,
    this.coverUrl,
    this.durationMs,
    this.track,
    this.known = false,
    this.mine = false,
    this.lyric,
    this.tracks,
    this.album,
    this.url,
    this.year,
  });

  /// song, album or artist.
  final String kind;

  /// library, ytmusic, spotify, soundcloud or bandcamp.
  final String place;

  /// Whatever that place calls this thing: a track id here, a video id there.
  final String id;

  final String title;
  final String subtitle;

  /// Addressed through this server, whoever's picture it is.
  final String? coverUrl;
  final int? durationMs;

  /// The library's own row for it, when the library has one.
  final Track? track;

  /// This server already knows this song — it may still be downloading.
  final bool known;

  /// And it is in *your* library, not merely on the box.
  final bool mine;

  /// The line the words were found in, when the search was for words.
  final String? lyric;

  /// How many songs, for a record or an artist.
  final int? tracks;
  final String? album;
  final String? url;
  final String? year;

  bool get isSong => kind == 'song';

  /// Something that plays: a song, or an ordinary YouTube video kept as its sound.
  bool get plays => kind == 'song' || kind == 'video';

  static int? _ms(Object? v) => v == null ? null : (v as num).toInt();

  factory Found.fromJson(Map<String, dynamic> j) => Found(
        kind: j['kind'] as String? ?? 'song',
        place: j['place'] as String? ?? 'library',
        id: '${j['id']}',
        title: j['title'] as String? ?? '',
        subtitle: j['subtitle'] as String? ?? '',
        coverUrl: j['cover_url'] as String?,
        durationMs: _ms(j['duration_ms']),
        track: j['track'] == null
            ? null
            : Track.fromJson(j['track'] as Map<String, dynamic>),
        known: j['known'] == true,
        mine: j['mine'] == true,
        lyric: j['lyric'] as String?,
        tracks: j['tracks'] == null ? null : (j['tracks'] as num).toInt(),
        album: j['album'] as String?,
        url: j['url'] as String?,
        year: j['year']?.toString(),
      );
}

/// A record somebody found, opened: what is on it, before any of it is added.
class FoundAlbum {
  const FoundAlbum(
      {required this.title, this.artist, this.year, this.coverUrl,
      this.tracks = const []});
  final String title;
  final String? artist;
  final String? year;
  final String? coverUrl;
  final List<Found> tracks;

  factory FoundAlbum.fromJson(Map<String, dynamic> j) => FoundAlbum(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String?,
        year: j['year']?.toString(),
        coverUrl: j['cover_url'] as String?,
        tracks: ((j['tracks'] ?? const []) as List)
            .map((e) => Found.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

enum ArmStyle {
  off,

  /// A real deck's: a matte black S-arm on a charcoal plinth, drawn after a photograph
  /// of one from above. The one that can be picked up and put down anywhere on the
  /// record.
  classic,

  /// The one it has always had: black metal, lit along its top edge.
  studio,

  /// Line-work. One weight of line, no shading, nothing filled but the cartridge —
  /// the way a part is drawn in a manual.
  drawn,

  /// Made of the app's own colours, with the app's own soft round edges.
  palette,

  /// One flat shape, the way a tonearm looks cut out of veneer and laid into a deck:
  /// a square weight, a round pivot, a long taper and a wedge for the head.
  inlay;

  String get label => switch (this) {
        ArmStyle.off => 'No arm',
        ArmStyle.classic => 'Classic',
        ArmStyle.studio => 'Studio',
        ArmStyle.drawn => 'Drawn',
        ArmStyle.palette => 'In your colours',
        ArmStyle.inlay => 'Inlay',
      };

  String get description => switch (this) {
        ArmStyle.off => 'Just the record, turning',
        ArmStyle.classic => 'A matte black S-arm on its plinth',
        ArmStyle.studio => 'Black metal, lit along its edge',
        ArmStyle.drawn => 'One weight of line, like a diagram of itself',
        ArmStyle.palette => "The palette you picked, in the app's own shapes",
        ArmStyle.inlay => 'One flat shape, cut out and laid in like veneer',
      };
}

enum PlayerLayout {
  /// The original: lyrics, up next and the rest in the top bar, artwork given the room.
  topBar,

  /// Everything that acts on the song under the transport, in one panel.
  grouped,

  /// The same, with the panel taller and the buttons bigger — smaller artwork, larger
  /// targets.
  roomy,

  /// Musicolet's arrangement: the song's own buttons in a row of their own above the
  /// bar, the times at either end of it rather than under it, and the transport large
  /// and plain across the bottom with no panel around any of it.
  plain;

  String get label => switch (this) {
        PlayerLayout.topBar => 'Icons at the top',
        PlayerLayout.grouped => 'Grouped with the controls',
        PlayerLayout.roomy => 'Roomy controls',
        PlayerLayout.plain => 'Plain and wide',
      };

  String get description => switch (this) {
        PlayerLayout.topBar => 'Lyrics, up next and the rest in the top bar',
        PlayerLayout.grouped => 'All of it under the play buttons',
        PlayerLayout.roomy => 'Bigger buttons and more space, artwork a little smaller',
        PlayerLayout.plain =>
          'No panel: icons in a row, times beside the bar, big transport underneath',
      };
}

/// A jam that is running now, as seen from outside it.
class OpenJam {
  final int id;
  final String code;
  final int queueId;
  final String host;
  final String? hostAvatar;
  final String queue;
  final int listening;
  final String? playing;
  final String? by;
  final bool joined;

  const OpenJam({
    required this.id,
    required this.code,
    required this.queueId,
    required this.host,
    required this.queue,
    this.hostAvatar,
    this.listening = 0,
    this.playing,
    this.by,
    this.joined = false,
  });

  factory OpenJam.fromJson(Map<String, dynamic> j) => OpenJam(
        id: (j['id'] ?? 0) as int,
        code: (j['code'] ?? '') as String,
        queueId: (j['queue_id'] ?? 0) as int,
        host: (j['host'] ?? '') as String,
        hostAvatar: j['avatar_sig'] as String?,
        queue: (j['queue'] ?? '') as String,
        listening: (j['listening'] ?? 0) as int,
        playing: j['playing'] as String?,
        by: j['by'] as String?,
        joined: (j['joined'] ?? false) as bool,
      );

  /// What is on, said the way somebody would say it.
  String get nowPlaying => playing == null
      ? 'nothing playing yet'
      : by == null
          ? playing!
          : '$playing · $by';
}

/// Someone in a jam.
class JamMember {
  final int userId;
  final String name;
  final bool host;
  final bool online;

  /// The version of their picture, if they have chosen one.
  final String? avatarVersion;

  const JamMember({required this.userId, required this.name,
      this.host = false, this.online = false, this.avatarVersion});

  factory JamMember.fromJson(Map<String, dynamic> j) => JamMember(
        userId: (j['user_id'] ?? 0) as int,
        name: (j['name'] ?? '') as String,
        host: (j['host'] ?? false) as bool,
        online: (j['online'] ?? false) as bool,
        avatarVersion: j['avatar_sig'] as String?,
      );
}

/// What the host's player is doing, and how old that answer is.
///
/// The age matters more than it looks: the message has been through a server and a
/// phone's event stream by the time it is read, and a position from two seconds ago
/// applied as though it were from now puts the room two seconds apart for the rest of
/// the song.
class JamPlayback {
  final int? trackId;

  /// Which row of the queue, where the host said: a queue can hold a song twice, and
  /// the song alone does not say which copy the room is on.
  final int? itemId;
  final int positionMs;
  final bool playing;
  final int ageMs;

  /// The host's own count of its reports. One with a lower count than the last one
  /// heard was overtaken on the way and is about the past.
  final int? seq;

  const JamPlayback({
    this.trackId,
    this.itemId,
    this.positionMs = 0,
    this.playing = false,
    this.ageMs = 0,
    this.seq,
  });

  factory JamPlayback.fromJson(Map<String, dynamic> j) => JamPlayback(
        trackId: j['track_id'] as int?,
        itemId: j['item_id'] as int?,
        positionMs: (j['position_ms'] ?? 0) as int,
        playing: (j['playing'] ?? false) as bool,
        ageMs: (j['age_ms'] ?? 0) as int,
        seq: (j['seq'] as num?)?.toInt(),
      );

  /// Where the music is now, rather than where it was when this was written.
  Duration get position => Duration(milliseconds: positionMs + (playing ? ageMs : 0));
}

/// A shared queue and a shared transport: everyone hears the same song, in the same
/// place, and anyone in the room can add to it or work the controls.
class Jam {
  final int id;
  final String code;
  final int queueId;
  final String? host;
  final bool isHost;
  final List<JamMember> members;
  final int listening;
  final Track? nowPlaying;

  /// Where the host's player is, when the server was asked. Only /jams/current
  /// carries this; the live events carry the same thing as it changes.
  final JamPlayback? playback;

  const Jam({
    required this.id,
    required this.code,
    required this.queueId,
    this.host,
    this.isHost = false,
    this.members = const [],
    this.listening = 0,
    this.nowPlaying,
    this.playback,
  });

  factory Jam.fromJson(Map<String, dynamic> j) => Jam(
        id: (j['id'] ?? 0) as int,
        code: (j['code'] ?? '') as String,
        queueId: (j['queue_id'] ?? 0) as int,
        host: j['host'] as String?,
        isHost: (j['is_host'] ?? false) as bool,
        members: ((j['members'] ?? const []) as List)
            .map((e) => JamMember.fromJson(e as Map<String, dynamic>))
            .toList(),
        listening: (j['listening'] ?? 0) as int,
        nowPlaying: j['now_playing'] == null
            ? null
            : Track.fromJson(j['now_playing'] as Map<String, dynamic>),
        playback: j['playback'] == null
            ? null
            : JamPlayback.fromJson(j['playback'] as Map<String, dynamic>),
      );

  /// How a jam works, said the way a person would say it. There is nothing to
  /// configure: everybody in the room shares the queue and the controls.
  String get rules => 'anyone can add, play and skip';
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


/// A service linked by typing a name rather than signing in.
class LinkedService {
  final String provider;
  final String label;
  final String hint;
  /// False for Deezer: it can tell us what is in a playlist, but not play it.
  final bool plays;

  /// How this one is signed in to: a public 'name', Google's 'code' flow, or a block
  /// of browser headers to 'paste'.
  final String signIn;
  final String? handle;
  final String? displayName;

  const LinkedService({
    required this.provider,
    required this.label,
    required this.hint,
    this.plays = true,
    this.signIn = 'name',
    this.handle,
    this.displayName,
  });

  factory LinkedService.fromJson(Map<String, dynamic> j) {
    final l = j['linked'] as Map<String, dynamic>?;
    return LinkedService(
      provider: (j['provider'] ?? '') as String,
      label: (j['label'] ?? '') as String,
      hint: (j['hint'] ?? '') as String,
      plays: (j['plays'] ?? true) as bool,
      signIn: (j['sign_in'] ?? 'name') as String,
      handle: l?['handle'] as String?,
      displayName: l?['display_name'] as String?,
    );
  }

  bool get isLinked => handle != null;
}

/// One of a linked service's lists, and whether we already mirror it.
class RemoteList {
  final String remoteId;
  final String name;
  final int? count;
  final bool mirrored;
  final int mirroredItems;

  const RemoteList({required this.remoteId, required this.name, this.count,
      this.mirrored = false, this.mirroredItems = 0});

  factory RemoteList.fromJson(Map<String, dynamic> j) {
    final m = j['mirror'] as Map<String, dynamic>?;
    return RemoteList(
      remoteId: (j['remote_id'] ?? '') as String,
      name: (j['name'] ?? '') as String,
      count: j['count'] as int?,
      mirrored: m != null,
      mirroredItems: (m?['items'] ?? 0) as int,
    );
  }
}

/// One line of a record: the song as the release lists it, and the copy we hold if
/// there is one. A row with no [track] is a song that exists and we have not fetched.
class ReleaseTrack {
  final int pos;
  final String title;
  final List<String> artists;
  final int? durationMs;
  final String? remoteId;
  final Track? track;

  const ReleaseTrack({
    required this.pos,
    required this.title,
    this.artists = const [],
    this.durationMs,
    this.remoteId,
    this.track,
  });

  bool get have => track != null;

  factory ReleaseTrack.fromJson(Map<String, dynamic> j) => ReleaseTrack(
        pos: (j['pos'] ?? 0) as int,
        title: (j['title'] ?? '') as String,
        artists: ((j['artists'] ?? const []) as List)
            .whereType<String>()
            .toList(),
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        remoteId: j['remote_id'] as String?,
        track: j['track'] == null
            ? null
            : Track.fromJson(j['track'] as Map<String, dynamic>),
      );

  String get artistLine => artists.isEmpty ? '' : artists.join(', ');
}

/// A record, whether or not the library holds any of it.
class AlbumDetail {
  final String name;
  final String? artist;
  final String? cover;
  final String? releaseDate;
  final String? recordType;
  final String? remoteId;
  final String? unavailable;
  final List<ReleaseTrack> tracks;
  final List<Track> extra;
  final int missing;

  const AlbumDetail({
    required this.name,
    this.artist,
    this.cover,
    this.releaseDate,
    this.recordType,
    this.remoteId,
    this.unavailable,
    this.tracks = const [],
    this.extra = const [],
    this.missing = 0,
  });

  bool get complete => remoteId != null;
  int get have => tracks.length - missing;
  String? get year =>
      (releaseDate != null && releaseDate!.length >= 4) ? releaseDate!.substring(0, 4) : null;

  factory AlbumDetail.fromJson(Map<String, dynamic> j) {
    final a = (j['album'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    return AlbumDetail(
      name: (a['name'] ?? '') as String,
      artist: a['artist'] as String?,
      cover: a['cover'] as String?,
      releaseDate: a['release_date'] as String?,
      recordType: a['record_type'] as String?,
      remoteId: a['remote_id'] as String?,
      unavailable: a['unavailable'] as String?,
      tracks: ((j['tracks'] ?? const []) as List)
          .map((e) => ReleaseTrack.fromJson(e as Map<String, dynamic>))
          .toList(),
      extra: ((j['extra'] ?? const []) as List)
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList(),
      missing: (j['missing'] ?? 0) as int,
    );
  }
}

/// A record in an artist's discography.
class ArtistAlbum {
  final String remoteId;
  final String title;
  final String? cover;
  final String? releaseDate;
  final String? recordType;
  final int? tracks;
  final int have;

  const ArtistAlbum({
    required this.remoteId,
    required this.title,
    this.cover,
    this.releaseDate,
    this.recordType,
    this.tracks,
    this.have = 0,
  });

  String? get year => (releaseDate != null && releaseDate!.length >= 4)
      ? releaseDate!.substring(0, 4)
      : null;

  factory ArtistAlbum.fromJson(Map<String, dynamic> j) => ArtistAlbum(
        remoteId: (j['remote_id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        cover: j['cover'] as String?,
        releaseDate: j['release_date'] as String?,
        recordType: j['record_type'] as String?,
        tracks: j['tracks'] as int?,
        have: (j['have'] ?? 0) as int,
      );
}

class ArtistDetail {
  final String name;
  final String? image;
  final String? remoteId;
  final String? unavailable;
  final bool following;
  final int? fans;
  final List<ArtistAlbum> albums;
  final List<ReleaseTrack> top;
  final List<Track> tracks;

  const ArtistDetail({
    required this.name,
    this.image,
    this.remoteId,
    this.unavailable,
    this.following = false,
    this.fans,
    this.albums = const [],
    this.top = const [],
    this.tracks = const [],
  });

  factory ArtistDetail.fromJson(Map<String, dynamic> j) {
    final a = (j['artist'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    return ArtistDetail(
      name: (a['name'] ?? '') as String,
      image: a['image'] as String?,
      remoteId: a['remote_id'] as String?,
      unavailable: a['unavailable'] as String?,
      following: (a['following'] ?? false) as bool,
      fans: a['fans'] as int?,
      albums: ((j['albums'] ?? const []) as List)
          .map((e) => ArtistAlbum.fromJson(e as Map<String, dynamic>))
          .toList(),
      top: ((j['top'] ?? const []) as List)
          .map((e) => ReleaseTrack.fromJson(e as Map<String, dynamic>))
          .toList(),
      tracks: ((j['tracks'] ?? const []) as List)
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class FollowedArtist {
  final String remoteId;
  final String name;
  final String? image;
  final int releases;

  const FollowedArtist(
      {required this.remoteId, required this.name, this.image, this.releases = 0});

  factory FollowedArtist.fromJson(Map<String, dynamic> j) => FollowedArtist(
        remoteId: (j['remote_id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        image: j['image'] as String?,
        releases: (j['releases'] ?? 0) as int,
      );
}

/// A record by somebody you follow.
class FeedItem {
  final String albumId;
  final String title;
  final String artist;
  final String artistId;
  final String? cover;
  final String? releaseDate;
  final String? recordType;
  final int? tracks;
  final bool unseen;
  final bool inLibrary;

  const FeedItem({
    required this.albumId,
    required this.title,
    required this.artist,
    required this.artistId,
    this.cover,
    this.releaseDate,
    this.recordType,
    this.tracks,
    this.unseen = false,
    this.inLibrary = false,
  });

  factory FeedItem.fromJson(Map<String, dynamic> j) => FeedItem(
        albumId: (j['album_id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        artist: (j['artist'] ?? '') as String,
        artistId: (j['artist_id'] ?? '') as String,
        cover: j['cover'] as String?,
        releaseDate: j['release_date'] as String?,
        recordType: j['record_type'] as String?,
        tracks: j['tracks'] as int?,
        unseen: (j['unseen'] ?? false) as bool,
        inLibrary: (j['in_library'] ?? false) as bool,
      );
}

/// A nod at what somebody has on: a fire, a heart, a dancer.
///
/// Sent from the People page at whoever is playing something, and drawn here on the
/// other end — it comes up the screen from the bottom, says who it was from, and is
/// gone in three seconds. Nothing is kept and nothing has to be answered.
class Reaction {
  const Reaction({required this.emoji, required this.who, this.sent = false});

  final String emoji;

  /// Who it is from — or, for one of your own, who it went to.
  final String who;

  /// One you sent: shown going up your own screen too, so that pressing the button
  /// visibly did something.
  final bool sent;
}

/// The ones there are. The server has the same list and takes nothing else.
const reactionEmoji = ['❤️', '🔥', '🕺', '😮', '😂', '🤘'];
