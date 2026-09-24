// Wire models. Everything the server calls a track looks the same here, whether it
// came from YouTube Music or off your own disk.

import 'dart:math' as math;

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

  /// Beats a minute, once the server has listened to the song for them. Null before
  /// that, and for something with no steady pulse.
  final double? bpm;

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
    this.bpm,
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
        bpm: bpm,
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
        discoveredVia: discoveredVia, gainDb: gainDb, bpm: bpm, bytes: bytes,
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
        bpm: (j['bpm'] as num?)?.toDouble(),
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
  DeviceInfo saying({
    required bool playing,
    required int positionMs,
    int? itemId,
    Track? track,
    int? queueId,
    String? queue,
  }) =>
      DeviceInfo(
        id: id,
        name: name,
        platform: platform,
        kind: kind,
        isThis: isThis,
        live: true,
        playing: playing,
        positionMs: positionMs,
        queue: queue ?? this.queue,
        queueId: queueId ?? this.queueId,
        track: track ?? this.track,
        lastSeen: DateTime.now(),
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

  /// What the booth did between these songs, when this playlist is a mix that was
  /// kept: see AutoMix. Null for an ordinary playlist.
  final Map<String, dynamic>? mix;
  bool get isMix => mix != null;

  /// Yours, or somebody else's kept in your library.
  final bool mine;

  /// You have kept somebody else's list.
  final bool saved;

  /// Its owner let everybody add to it.
  final bool openEdit;

  /// Every song in it is taken apart by the pool as it arrives: a crate for the booth.
  final bool autoSplit;

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
    this.mix,
    this.mine = true,
    this.saved = false,
    this.openEdit = false,
    this.autoSplit = false,
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
        mix: j['mix'] is Map ? (j['mix'] as Map).cast<String, dynamic>() : null,
        // A list of your own says nothing about ownership; one of somebody else's
        // says both whose it is and that it is theirs.
        mine: j['mine'] as bool? ?? !(j['saved'] == true),
        saved: j['saved'] == true,
        openEdit: j['open_edit'] == true,
        autoSplit: j['auto_split'] == true,
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

  /// The whole house added together, rather than one account.
  final bool everyone;

  /// How many accounts the listening was done by: one, unless it is [everyone]'s.
  final int listeners;
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
    this.everyone = false,
    this.listeners = 0,
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
      everyone: j['everyone'] == true,
      listeners: (totals['listeners'] ?? 0) as int,
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

  /// How many accounts played it. Only worth saying on the house's chart.
  final int listeners;

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
    this.listeners = 0,
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
        listeners: (j['listeners'] ?? 0) as int,
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

  /// What this house has made of it: see [LinerNotes].
  final LinerNotes notes;

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
    this.notes = const LinerNotes(),
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
      notes: j['notes'] is Map
          ? LinerNotes.fromJson((j['notes'] as Map).cast<String, dynamic>())
          : const LinerNotes(),
    );
  }
}

/// What goes under a record's tracklist: how often you have played it, who else in
/// the house plays it, and what else by the same artist is already on your shelf.
class LinerNotes {
  const LinerNotes({
    this.plays = 0,
    this.lastPlayed,
    this.house = const [],
    this.more = const [],
  });

  final int plays;
  final DateTime? lastPlayed;
  final List<({int id, String name, int plays})> house;
  final List<AlbumSummary> more;

  bool get isEmpty => plays == 0 && house.isEmpty && more.isEmpty;

  factory LinerNotes.fromJson(Map<String, dynamic> j) => LinerNotes(
        plays: (j['plays'] ?? 0) as int,
        lastPlayed: j['last_played'] == null
            ? null
            : DateTime.tryParse('${j['last_played']}')?.toLocal(),
        house: [
          for (final h in (j['house'] ?? const []) as List)
            (
              id: (h['id'] ?? 0) as int,
              name: '${h['name'] ?? ''}',
              plays: (h['plays'] ?? 0) as int,
            )
        ],
        more: [
          for (final m in (j['more'] ?? const []) as List)
            AlbumSummary.fromJson((m as Map).cast<String, dynamic>())
        ],
      );
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

  /// The artist as this house knows them: see [ArtistNotes].
  final ArtistNotes yours;

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
    this.yours = const ArtistNotes(),
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
      yours: j['yours'] is Map
          ? ArtistNotes.fromJson((j['yours'] as Map).cast<String, dynamic>())
          : const ArtistNotes(),
    );
  }
}

/// An artist as this house knows them: what *you* play of theirs — which is not what
/// the world plays of theirs — how much the others here have them on, and who they
/// turn up alongside in your library.
class ArtistNotes {
  const ArtistNotes({
    this.plays = 0,
    this.lastPlayed,
    this.top = const [],
    this.house = const [],
    this.beside = const [],
  });

  final int plays;
  final DateTime? lastPlayed;
  final List<({Track track, int plays})> top;
  final List<({int id, String name, int plays})> house;
  final List<({String name, int songs})> beside;

  bool get isEmpty => plays == 0 && house.isEmpty && beside.isEmpty;

  factory ArtistNotes.fromJson(Map<String, dynamic> j) => ArtistNotes(
        plays: (j['plays'] ?? 0) as int,
        lastPlayed: j['last_played'] == null
            ? null
            : DateTime.tryParse('${j['last_played']}')?.toLocal(),
        top: [
          for (final t in (j['top'] ?? const []) as List)
            if (t['track'] is Map)
              (
                track: Track.fromJson((t['track'] as Map).cast<String, dynamic>()),
                plays: (t['plays'] ?? 0) as int,
              )
        ],
        house: [
          for (final h in (j['house'] ?? const []) as List)
            (
              id: (h['id'] ?? 0) as int,
              name: '${h['name'] ?? ''}',
              plays: (h['plays'] ?? 0) as int,
            )
        ],
        beside: [
          for (final w in (j['with'] ?? const []) as List)
            (name: '${w['name'] ?? ''}', songs: (w['songs'] ?? 0) as int)
        ],
      );
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

/// Whether what is played here is being written into a diary kept elsewhere, and how
/// that is going. Never the token: it goes to the server once and stays there.
class Scrobbling {
  const Scrobbling({
    this.connected = false,
    this.name,
    this.sent = 0,
    this.owed = 0,
    this.lastSent,
    this.error,
  });

  final bool connected;
  final String? name;
  final int sent;

  /// Plays not yet written down — the service was unreachable, or has not been tried.
  final int owed;
  final DateTime? lastSent;
  final String? error;

  factory Scrobbling.fromJson(Map<String, dynamic> j) {
    final lb = (j['listenbrainz'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    return Scrobbling(
      connected: (lb['connected'] ?? false) as bool,
      name: lb['name'] as String?,
      sent: (lb['sent'] ?? 0) as int,
      owed: (lb['owed'] ?? 0) as int,
      lastSent: lb['last_sent'] == null
          ? null
          : DateTime.tryParse('${lb['last_sent']}')?.toLocal(),
      error: lb['error'] as String?,
    );
  }
}

/// What a song is made of in time: where the sound really starts and ends in its file,
/// how fast it goes, and where its beats fall. Worked out by the server, once per song.
class TrackTiming {
  const TrackTiming({
    this.durationMs = 0,
    this.leadMs = 0,
    this.tailMs = 0,
    this.bpm,
    this.beats = const [],
    this.barStartsOn = 0,
    this.ends = '',
    this.key,
    this.camelot,
    this.keyConfidence = 0,
    this.downbeats = const [],
    this.energy = const [],
    this.phrases = const [],
    this.drops = const [],
    this.fourBars = const [],
    this.cues,
    this.structure,
  });

  /// What the record is made of — its sections, its stems bar by bar, where it drops
  /// and breaks down — where the house has built it (structure.py). Null on the plain
  /// analysis.
  final TrackStructure? structure;

  /// "A minor", "F# major" — or null for something in no key: noise, speech.
  final String? key;

  /// The same key on the wheel DJs mix by: "8A" is A minor, "8B" C major, and a step
  /// round the wheel is a fifth away. Two records a step apart mix; two across the
  /// wheel do not.
  final String? camelot;
  final double keyConfidence;

  /// Where each bar starts, in milliseconds. The beats, every fourth from the one.
  final List<int> downbeats;

  /// How loud each bar is, 0 to 255, loudest at 255: the song's shape bar by bar.
  final List<int> energy;

  /// Where the phrases begin, in milliseconds — on downbeats, on the four-bar grid.
  final List<int> phrases;

  /// The four-bar markers, in milliseconds: every fourth downbeat, counted from where
  /// the record's sections start rather than from its first bar — a pickup or an
  /// intro of three bars puts that one bar or more out, and a section of odd length
  /// moves them on from there. What two records are lined up by in a mix: each
  /// record's markers falling together is each record's phrases falling together.
  final List<int> fourBars;

  /// [fourBars], or for an analysis from before there were any, every fourth
  /// downbeat from the first.
  List<int> get markers {
    if (fourBars.isNotEmpty) return fourBars;
    final kept = _markersOf[this];
    if (kept != null) return kept;
    final downs = downbeats.isNotEmpty
        ? downbeats
        : [for (var i = barStartsOn; i >= 0 && i < beats.length; i += 4) beats[i]];
    return _markersOf[this] = [for (var i = 0; i < downs.length; i += 4) downs[i]];
  }

  static final _markersOf = Expando<List<int>>('four-bar markers');

  /// The marker nearest [at], on the steady grid where there is one — or [at] itself
  /// for a record with no bars.
  Duration onMarker(Duration at) {
    final m = markers;
    if (m.isEmpty) return at;
    final ms = at.inMilliseconds;
    var best = m.first;
    for (final x in m) {
      if ((x - ms).abs() < (best - ms).abs()) best = x;
    }
    return onGrid(Duration(milliseconds: best), every: 4);
  }

  /// The last marker at or before [at] — the first where [at] is before them all —
  /// on the steady grid, or null for a record with no bars.
  Duration? markerAtOrBefore(Duration at) {
    final m = markers;
    if (m.isEmpty) return null;
    final ms = at.inMilliseconds;
    var best = m.first;
    for (final x in m) {
      if (x > ms) break;
      best = x;
    }
    return onGrid(Duration(milliseconds: best), every: 4);
  }

  /// A bar of this record, in its own time: four beats on the steady grid, or at its
  /// tempo where there is none. Null with no tempo.
  Duration? get bar {
    final s = steady;
    final period = s?.period ?? ((bpm ?? 0) > 0 ? 60000 / bpm! : null);
    return period == null ? null : Duration(microseconds: (4 * period * 1000).round());
  }

  /// Which bar of its four-bar phrase [at] falls in, from 0 on the marker, and how many
  /// bars that phrase has — four, or fewer where a section of odd length cuts it
  /// short. Null before the first marker, or with no bars.
  ({int bar, int of})? placeInPhrase(Duration at) {
    final m = markers;
    final b = bar;
    if (m.isEmpty || b == null) return null;
    final ms = at.inMicroseconds / 1000;
    final barMs = b.inMicroseconds / 1000;
    // A hair before a marker is that marker: a place read off a clock a millisecond
    // early is still the bar it was aimed at.
    final slack = barMs / 8;
    var i = -1;
    for (var k = 0; k < m.length; k++) {
      if (m[k] <= ms + slack) {
        i = k;
      } else {
        break;
      }
    }
    if (i < 0) return null;
    final since = ((ms + slack - m[i]) / barMs).floor();
    if (i + 1 >= m.length) return (bar: since % 4, of: 4);
    final of = ((m[i + 1] - m[i]) / barMs).round().clamp(1, 4);
    return (bar: since.clamp(0, of - 1), of: of);
  }

  /// Where the song opens up: a breakdown, then everything at once. What a mix is
  /// landed on, and what two records must not do over each other by accident.
  final List<int> drops;

  /// The first drop after [at], or null when the song has none left.
  Duration? dropAfter(Duration at) {
    for (final d in drops) {
      if (d >= at.inMilliseconds) return Duration(milliseconds: d);
    }
    return null;
  }

  /// Where a DJ would come in and go out.
  final MixCues? cues;

  /// Records a step or less apart on the wheel, or the same place in the other mode.
  bool inKeyWith(TrackTiming other) {
    final a = camelot, b = other.camelot;
    if (a == null || b == null) return false;
    final na = int.parse(a.substring(0, a.length - 1)), ma = a[a.length - 1];
    final nb = int.parse(b.substring(0, b.length - 1)), mb = b[b.length - 1];
    if (ma == mb) {
      final d = (na - nb).abs();
      return d <= 1 || d == 11;
    }
    return na == nb;
  }

  final int durationMs;

  /// Nothing, at the start of the file, before the first sound.
  final int leadMs;

  /// Nothing, at the end of it, after the last.
  final int tailMs;

  /// Beats a minute — null for something with no steady pulse, which is not given one.
  final double? bpm;

  /// Where each beat falls, in milliseconds from the start of the file.
  final List<int> beats;

  /// Which beat of four the bar most likely starts on. A guess, and treated as one.
  final int barStartsOn;

  /// 'cold', 'fade', or '' when it could not be said.
  final String ends;

  Duration get lead => Duration(milliseconds: leadMs);

  /// Where the sound ends — null when the file has no dead air after it worth skipping,
  /// or its length is not known.
  Duration? get soundEnds =>
      tailMs > 0 && durationMs > tailMs ? Duration(milliseconds: durationMs - tailMs) : null;

  bool get hasBeats => beats.length >= 8;

  /// Which beat the music is on at [at], and how far through it: 0 on the beat, rising
  /// to 1 at the next. Null before the first beat, after the last, and where there are
  /// none — a light that pulses through a silence is keeping time with nothing.
  ({int index, double phase})? beatAt(Duration at) {
    if (!hasBeats) return null;
    final ms = at.inMilliseconds;
    if (ms < beats.first || ms >= beats.last) return null;
    var lo = 0, hi = beats.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (beats[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = beats[hi] - beats[lo];
    return (index: lo, phase: span <= 0 ? 0 : (ms - beats[lo]) / span);
  }

  /// The beat grid as it runs around [at]: a straight line through the [span] beats
  /// either side of the nearest one — where the beats are, not where two of them are.
  ///
  /// A beat is found to within a frame of the analysis, about 6 ms either way, and a
  /// phase read off two neighbouring beats wobbles by that much; a tempo read off the
  /// whole song is wrong for a record that drifts, which a live drummer's does. A line
  /// through the beats nearby is steady and local. Extrapolated a few beats past
  /// either end of the grid, so a record parked on its first beat still has one.
  ({double origin, double period, int first})? gridAround(Duration at, {int span = 8}) {
    if (!hasBeats) return null;
    final ms = at.inMilliseconds;
    var lo = 0, hi = beats.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (beats[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final near = (ms - beats[lo]).abs() <= (beats[hi] - ms).abs() ? lo : hi;
    final from = (near - span).clamp(0, beats.length - 1);
    final to = (near + span).clamp(0, beats.length - 1);
    final n = to - from + 1;
    if (n < 4) return null;
    // Least squares of beat time against beat number, the numbers counted from [from].
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (var i = from; i <= to; i++) {
      final x = (i - from).toDouble(), y = beats[i].toDouble();
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final d = n * sxx - sx * sx;
    if (d == 0) return null;
    final period = (n * sxy - sx * sy) / d;
    if (period <= 0) return null;
    final origin = (sy - period * sx) / n;
    // Too far outside the grid to be believed.
    if (ms < beats.first - 4 * period || ms > beats.last + 4 * period) return null;
    return (origin: origin, period: period, first: from);
  }

  /// Beats a minute here, from the beats around [at] — or the song's own figure where
  /// there are none to read.
  double? tempoAround(Duration at) {
    final g = gridAround(at, span: 16);
    return g == null ? bpm : 60000 / g.period;
  }

  /// The beats as one steady grid: a first beat and a period, every beat a whole
  /// number of periods from it. Null where they are not one — a live drummer, a
  /// tempo change — and the grid is read off the beats nearby instead ([gridAround]).
  ///
  /// A record made on a computer runs to a clock, and its beats are exactly that. The
  /// analysis does not find them exactly: it places each one to within a frame (11.6
  /// ms), swings between neighbouring frames from beat to beat, and where the music
  /// thins out it can lose the beat altogether — one record's last eighteen beats sat
  /// 45 ms late, exactly where a mix out of it happens. A grid read off the beats
  /// nearby moves with all of that, and whatever is held to it moves too. A line
  /// through all of them, the stray ones left out, does not.
  ///
  /// Numbered so that the analysis's bar start is a bar start here too, so beat
  /// numbers on this grid and in [beats] agree wherever the tracker missed none.
  ({double origin, double period})? get steady {
    final kept = _steadyOf[this];
    if (kept != null) return identical(kept, _notSteady) ? null : kept as ({double origin, double period});
    final found = _steady();
    _steadyOf[this] = found ?? _notSteady;
    return found;
  }

  static final _steadyOf = Expando<Object>('steady grid');
  static const _notSteady = Object();

  ({double origin, double period})? _steady() {
    final n = beats.length;
    if (n < 16) return null;
    // A first period: the figure the analysis read off the same pulse, or the middle
    // gap where it gave none. Each beat is then numbered by where it falls on that
    // grid, so one the tracker missed or doubled does not shift every beat after it.
    var period = (bpm ?? 0) > 0 ? 60000 / bpm! : 0.0;
    if (period <= 0) {
      final gaps = [for (var i = 1; i < n; i++) beats[i] - beats[i - 1]]..sort();
      period = gaps[gaps.length ~/ 2].toDouble();
      if (period <= 0) return null;
    }
    var origin = beats.first.toDouble();
    final number = List<int>.filled(n, 0);
    final keep = List<bool>.filled(n, true);
    final res = List<double>.filled(n, 0);
    for (var round = 0; round < 6; round++) {
      for (var i = 0; i < n; i++) {
        number[i] = ((beats[i] - origin) / period).round();
      }
      var m = 0;
      var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
      for (var i = 0; i < n; i++) {
        if (!keep[i]) continue;
        final x = number[i].toDouble(), y = beats[i].toDouble();
        m++;
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
      }
      final d = m * sxx - sx * sx;
      if (m < 16 || d == 0) return null;
      final p = (m * sxy - sx * sy) / d;
      if (p <= 0) return null;
      period = p;
      origin = (sy - period * sx) / m;
      // The strays: further from the line than the analysis's own wobble explains.
      for (var i = 0; i < n; i++) {
        res[i] = beats[i] - (origin + period * number[i]);
      }
      final spread = [for (final r in res) r.abs()]..sort();
      final limit = math.max(15.0, 3 * 1.4826 * spread[n ~/ 2]);
      var changed = false;
      for (var i = 0; i < n; i++) {
        final k = res[i].abs() <= limit;
        if (k != keep[i]) changed = true;
        keep[i] = k;
      }
      if (!changed) break;
    }
    // One grid, or not: most beats on it, and those close to it.
    var m = 0;
    var ss = 0.0;
    for (var i = 0; i < n; i++) {
      if (!keep[i]) continue;
      m++;
      ss += res[i] * res[i];
    }
    if (m < n * 0.75 || math.sqrt(ss / m) > period * 0.05) return null;
    // And no drift: a record whose tempo wanders — a band, not a computer — sits on a
    // line only on average, above it in the middle and below at the ends. Where the
    // beats through the middle of the record stray from the line by a steady amount
    // for bars at a time, it is not one grid. (The ends are left out of this: that is
    // where the tracker loses the beat, not where a drummer finds another.)
    const window = 32;
    final from = (n * 0.1).floor(), to = (n * 0.9).ceil();
    for (var w = from; w + window <= to; w += window ~/ 2) {
      var sum = 0.0;
      var k = 0;
      for (var i = w; i < w + window; i++) {
        if (!keep[i]) continue;
        sum += res[i];
        k++;
      }
      if (k >= window ~/ 2 && (sum / k).abs() > math.max(12.0, period * 0.03)) return null;
    }
    final bar = beats[barStartsOn.clamp(0, n - 1)];
    final nb = ((bar - origin) / period).round();
    return (origin: origin - (barStartsOn - nb) * period, period: period);
  }

  /// Beats a minute on the steady grid — the figure a deck shows, SYNC matches and the
  /// beat-holding holds, so that the three agree — or the analysis's own where the
  /// beats are not steady.
  double? get gridBpm {
    final s = steady;
    return s == null ? bpm : 60000 / s.period;
  }

  /// [at], moved onto the nearest beat of the steady grid — or of the bars, with
  /// [every] 4. Unmoved where the beats are not steady.
  Duration onGrid(Duration at, {int every = 1}) {
    final s = steady;
    if (s == null) return at;
    final x = (at.inMicroseconds / 1000 - s.origin) / s.period;
    final k = every <= 1 ? x.round() : barStartsOn + ((x - barStartsOn) / every).round() * every;
    return Duration(microseconds: ((s.origin + k * s.period) * 1000).round());
  }

  /// The first beat of the steady grid at or after [at] — with [every] 4, the first
  /// downbeat — or null where the beats are not steady or the record has run out of
  /// them.
  Duration? nextOnGrid(Duration at, {int every = 1}) {
    final s = steady;
    if (s == null) return null;
    final x = (at.inMicroseconds / 1000 - s.origin) / s.period;
    var k = (x - 1e-6).ceil();
    if (every > 1) {
      final r = ((k - barStartsOn) % every + every) % every;
      if (r != 0) k += every - r;
    }
    final t = s.origin + k * s.period;
    if (t > beats.last + 4 * s.period) return null;
    return Duration(microseconds: (t * 1000).round());
  }

  /// Where beat [index] falls, as a place in the file: on the steady grid, or on the
  /// grid read off the beats [near] it where there is none.
  Duration? beatTime(int index, {required Duration near}) {
    final s = steady;
    if (s != null) return Duration(microseconds: ((s.origin + index * s.period) * 1000).round());
    final g = gridAround(near);
    if (g == null) return null;
    return Duration(microseconds: ((g.origin + (index - g.first) * g.period) * 1000).round());
  }

  /// Which beat [at] is on and how far through it, read off the fitted grid rather
  /// than the two beats either side: what two records are held together by. The
  /// steady grid where there is one; the beats nearby where there is not.
  ({int index, double phase, double period})? smoothBeatAt(Duration at) {
    final s = steady;
    if (s != null) {
      final ms = at.inMicroseconds / 1000;
      if (ms < beats.first - 4 * s.period || ms > beats.last + 4 * s.period) return null;
      final x = (ms - s.origin) / s.period;
      final whole = x.floor();
      return (index: whole, phase: x - whole, period: s.period);
    }
    final g = gridAround(at);
    if (g == null) return null;
    final x = (at.inMicroseconds / 1000 - g.origin) / g.period;
    final whole = x.floor();
    return (index: g.first + whole, phase: x - whole, period: g.period);
  }

  /// How far apart two keys are on the wheel, in the steps a DJ counts: 0 the same
  /// key, 1 a neighbour or the relative major/minor, 2 two steps or a diagonal, and
  /// so on. Null where either has no key.
  int? keyStepsTo(TrackTiming other) {
    final a = camelot, b = other.camelot;
    if (a == null || b == null || a.length < 2 || b.length < 2) return null;
    final na = int.tryParse(a.substring(0, a.length - 1));
    final nb = int.tryParse(b.substring(0, b.length - 1));
    if (na == null || nb == null) return null;
    var around = (na - nb).abs() % 12;
    if (around > 6) around = 12 - around;
    final sameLetter = a[a.length - 1] == b[b.length - 1];
    return around + (sameLetter ? 0 : 1);
  }

  factory TrackTiming.fromJson(Map<String, dynamic> j) => TrackTiming(
        durationMs: (j['duration_ms'] ?? 0) as int,
        leadMs: (j['lead_ms'] ?? 0) as int,
        tailMs: (j['tail_ms'] ?? 0) as int,
        bpm: (j['bpm'] as num?)?.toDouble(),
        beats: [for (final b in (j['beats'] ?? const []) as List) (b as num).toInt()],
        barStartsOn: (j['bar_starts_on'] ?? 0) as int,
        ends: (j['ends'] ?? '') as String,
        key: j['key'] as String?,
        camelot: j['camelot'] as String?,
        keyConfidence: (j['key_confidence'] as num?)?.toDouble() ?? 0,
        downbeats: [for (final b in (j['downbeats'] ?? const []) as List) (b as num).toInt()],
        energy: [for (final b in (j['energy'] ?? const []) as List) (b as num).toInt()],
        phrases: [for (final b in (j['phrases'] ?? const []) as List) (b as num).toInt()],
        drops: [for (final b in (j['drops'] ?? const []) as List) (b as num).toInt()],
        fourBars: [for (final b in (j['four_bars'] ?? const []) as List) (b as num).toInt()],
        cues: j['cues'] is Map ? MixCues.fromJson((j['cues'] as Map).cast<String, dynamic>()) : null,
        structure: j['structure'] is Map
            ? TrackStructure.fromJson((j['structure'] as Map).cast<String, dynamic>())
            : null,
      );
}

/// One section of a record, as the house read it off the stems: what it is called the
/// way a DJ calls it, which bars it spans, whether the drums and the voice are in it,
/// how hard it hits, and its key where it is long enough to have one.
class TrackSection {
  const TrackSection({
    required this.label,
    required this.startBar,
    required this.endBar,
    required this.startMs,
    required this.endMs,
    required this.drums,
    required this.vocals,
    required this.energyDb,
    this.key,
    this.camelot,
    this.keyConfidence = 0,
  });

  /// intro, verse, chorus, inst, breakdown, build, drop, break, outro — or on, where
  /// only the mix could be read.
  final String label;
  final int startBar, endBar;
  final int startMs, endMs;
  final bool drums, vocals;
  final double energyDb;
  final String? key, camelot;
  final double keyConfidence;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
  int get bars => endBar - startBar;

  /// Whether a record could come in over this without two of anything: no voice, and
  /// the drums either in or out on purpose.
  bool get percussive => !vocals && drums;
  bool get plays => drums && label != 'intro' && label != 'outro';

  factory TrackSection.fromJson(Map<String, dynamic> j) => TrackSection(
        label: (j['label'] ?? 'on') as String,
        startBar: (j['start_bar'] ?? 0) as int,
        endBar: (j['end_bar'] ?? 0) as int,
        startMs: (j['start_ms'] ?? 0) as int,
        endMs: (j['end_ms'] ?? 0) as int,
        drums: (j['drums'] ?? true) as bool,
        vocals: (j['vocals'] ?? false) as bool,
        energyDb: (j['energy_db'] as num?)?.toDouble() ?? 0,
        key: j['key'] as String?,
        camelot: j['camelot'] as String?,
        keyConfidence: (j['key_confidence'] as num?)?.toDouble() ?? 0,
      );
}

/// A place a DJ would come into a record or go out of it, and why.
class CuePoint {
  const CuePoint({required this.ms, required this.bar, required this.why});
  final int ms, bar;
  final String why;
  Duration get at => Duration(milliseconds: ms);

  factory CuePoint.fromJson(Map<String, dynamic> j) =>
      CuePoint(ms: (j['ms'] ?? 0) as int, bar: (j['bar'] ?? 0) as int, why: (j['why'] ?? '') as String);
}

/// What a record is made of (the server's structure.py): how loud the mix and each
/// stem is in every bar, its sections, its drops and breakdowns, its loudness, and the
/// places to come in and go out. What the automix plans by, where the house has it.
class TrackStructure {
  const TrackStructure({
    this.sources = const {},
    this.barsMs = const [],
    this.mixDb = const [],
    this.drumsDb,
    this.restDb,
    this.vocalsDb,
    this.lufs,
    this.sections = const [],
    this.dropsMs = const [],
    this.breakdownsMs = const [],
    this.outs = const [],
    this.ins = const [],
  });

  /// What it was built from: beats 'grid' | 'tracked' | 'neural', bar_phase 'house' |
  /// 'neural', stems true where the stems were read.
  final Map<String, dynamic> sources;

  /// The bars, and how loud each is in dB below full scale: the mix, and each stem
  /// where the stems were there (null otherwise).
  final List<int> barsMs;
  final List<double> mixDb;
  final List<double>? drumsDb, restDb, vocalsDb;

  /// The record's integrated loudness, LUFS, as the house measured it on arrival.
  final double? lufs;
  final List<TrackSection> sections;
  final List<int> dropsMs, breakdownsMs;
  final List<CuePoint> outs, ins;

  bool get fromStems => sources['stems'] == true;
  bool get barByNeural => sources['bar_phase'] == 'neural';

  /// The section [at] falls in, or null before the first or after the last.
  TrackSection? sectionAt(Duration at) {
    final ms = at.inMilliseconds;
    for (final s in sections) {
      if (ms >= s.startMs && ms < s.endMs) return s;
    }
    return null;
  }

  /// Of [label], in order.
  Iterable<TrackSection> of(String label) => sections.where((s) => s.label == label);

  static List<double>? _doubles(Object? v) =>
      v is List ? [for (final x in v) (x as num).toDouble()] : null;

  factory TrackStructure.fromJson(Map<String, dynamic> j) => TrackStructure(
        sources: j['sources'] is Map ? (j['sources'] as Map).cast<String, dynamic>() : const {},
        barsMs: [for (final b in (j['bars_ms'] ?? const []) as List) (b as num).toInt()],
        mixDb: _doubles(j['mix_db']) ?? const [],
        drumsDb: _doubles(j['drums_db']),
        restDb: _doubles(j['rest_db']),
        vocalsDb: _doubles(j['vocals_db']),
        lufs: (j['lufs'] as num?)?.toDouble(),
        sections: [
          for (final s in (j['sections'] ?? const []) as List)
            TrackSection.fromJson((s as Map).cast<String, dynamic>()),
        ],
        dropsMs: [for (final b in (j['drops_ms'] ?? const []) as List) (b as num).toInt()],
        breakdownsMs: [for (final b in (j['breakdowns_ms'] ?? const []) as List) (b as num).toInt()],
        outs: [
          for (final c in ((j['cues'] as Map?)?['outs'] ?? const []) as List)
            CuePoint.fromJson((c as Map).cast<String, dynamic>()),
        ],
        ins: [
          for (final c in ((j['cues'] as Map?)?['ins'] ?? const []) as List)
            CuePoint.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );
}

/// Where a DJ would come in and go out of a song, as the server reads it.
class MixCues {
  const MixCues({
    required this.firstDownbeatMs,
    required this.mixInMs,
    required this.mixOutMs,
    required this.soundEndMs,
  });

  final int firstDownbeatMs;

  /// Where the intro ends: the song is on from here.
  final int mixInMs;

  /// Where the outro starts, or thirty-two bars before the sound ends.
  final int mixOutMs;
  final int soundEndMs;

  Duration get firstDownbeat => Duration(milliseconds: firstDownbeatMs);
  Duration get mixIn => Duration(milliseconds: mixInMs);
  Duration get mixOut => Duration(milliseconds: mixOutMs);
  Duration get soundEnd => Duration(milliseconds: soundEndMs);

  factory MixCues.fromJson(Map<String, dynamic> j) => MixCues(
        firstDownbeatMs: (j['first_downbeat_ms'] ?? 0) as int,
        mixInMs: (j['mix_in_ms'] ?? 0) as int,
        mixOutMs: (j['mix_out_ms'] ?? 0) as int,
        soundEndMs: (j['sound_end_ms'] ?? 0) as int,
      );
}

/// Where the voice is in a record, and what it sings (the server's vocals.py): how
/// loud the voice is bar by bar, the lyrics' lines — with their times where those can
/// be trusted to be where the voice is — and the hook, the line sung most.
class VocalMap {
  const VocalMap({this.bars, this.lines = const [], this.timed = false, this.hook, this.lyrics});

  /// 0 to 255 a bar, on the analysis's downbeats; null until the record is in parts.
  final List<int>? bars;
  final List<({int? ms, String text})> lines;
  final bool timed;
  final ({String text, List<int> at})? hook;

  /// Where the words came from, or "later" while they are still to be asked for.
  final String? lyrics;

  /// A bar is sung where the voice is within 16 dB of its loudest.
  static const sung = 118;

  bool get complete => bars != null && lyrics != 'later';

  bool sungAt(int bar) {
    final b = bars;
    return b != null && bar >= 0 && bar < b.length && b[bar] >= sung;
  }

  /// How many of [from]..[to) (bars) are sung.
  int sungIn(int from, int to) {
    var n = 0;
    for (var i = from; i < to; i++) {
      if (sungAt(i)) n++;
    }
    return n;
  }

  factory VocalMap.fromJson(Map<String, dynamic> j) {
    final h = j['hook'];
    return VocalMap(
      bars: (j['bars'] as List?)?.map((e) => (e as num).toInt()).toList(),
      lines: [
        for (final l in (j['lines'] as List? ?? const []))
          if (l is Map) (ms: (l['ms'] as num?)?.toInt(), text: '${l['text'] ?? ''}')
      ],
      timed: j['timed'] == true,
      hook: h is Map
          ? (text: '${h['text'] ?? ''}', at: [for (final a in (h['at'] as List? ?? const [])) (a as num).toInt()])
          : null,
      lyrics: j['lyrics'] as String?,
    );
  }
}
