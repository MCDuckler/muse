import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'connection.dart';
import 'models.dart';

/// What the server has of one part of a record.
enum Stem {
  /// Made, and playing it is a fetch like any other.
  ready,

  /// Being made, or waiting its turn to be. A minute, give or take.
  beingMade,

  /// Not something this record gets: too long to take apart.
  never,
}

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

/// Talks to one muse server. The token is per device and revocable; there is no
/// signup, so there is no account flow to build.
class ApiClient {
  ApiClient({required this.baseUrl, this.token});

  String baseUrl;
  String? token;

  Map<String, String> get _headers => {
        if (token != null) 'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Uri _u(String path, [Map<String, dynamic>? q]) => Uri.parse('$baseUrl$path').replace(
      queryParameters: q?.map((k, v) => MapEntry(k, '$v')));

  Future<dynamic> _decode(http.Response r) async {
    if (r.statusCode >= 400) {
      String detail = r.body;
      try {
        final d = jsonDecode(r.body);
        if (d is Map && d['detail'] != null) {
          final v = d['detail'];
          if (v is List) {
            // FastAPI validation errors arrive as a list of objects; printing them
            // raw put "[{type: missing, loc: [body, user]…}]" in front of the user.
            detail = v
                .map((e) => e is Map ? (e['msg'] ?? '').toString() : '$e')
                .where((s) => s.isNotEmpty)
                .join('. ');
          } else {
            detail = '$v';
          }
        }
      } catch (_) {}
      if (detail.trim().isEmpty) detail = 'Request failed (${r.statusCode})';
      if (detail.startsWith('<!DOCTYPE') || detail.startsWith('<html')) {
        // A proxy served the app shell where the API should be: a routing problem,
        // not an API error. Say so instead of dumping HTML at the user.
        detail = 'Server returned a web page, not data (${r.statusCode})';
      }
      throw ApiException(r.statusCode, detail);
    }
    if (r.body.isEmpty) return null;
    try {
      return jsonDecode(r.body);
    } on FormatException {
      throw ApiException(r.statusCode,
          'Server returned a web page, not data — check the API routing');
    }
  }

  Future<String> login(String user, String password, String device) async {
    final r = await net.post(_u('/auth/login'), body: {
      'user': user,
      'password': password,
      'device': device,
      'platform': _platformName(),
    });
    final d = await _decode(r) as Map<String, dynamic>;
    token = d['token'] as String;
    return token!;
  }

  String? _streamKey;
  int _streamKeyExpiry = 0;

  /// The browser's audio element cannot send an Authorization header, so media URLs
  /// carry a short-lived signed key instead. Fetched once and reused until it ages out.
  Future<void> ensureStreamKey({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!force && _streamKey != null && _streamKeyExpiry - 300 > now) return;
    final d = await _decode(await net.get(_u('/auth/stream-key'), headers: _headers))
        as Map<String, dynamic>;
    _streamKey = d['key'] as String;
    _streamKeyExpiry = d['expires_at'] as int;
  }

  /// Turn an invite into an account and sign in with it. The only route that creates
  /// a user without already being signed in.
  Future<String> redeemInvite(String code, String user, String password,
      String device) async {
    final r = await net.post(_u('/auth/redeem'), body: {
      'code': code,
      'user': user,
      'password': password,
      'device': device,
      'platform': _platformName(),
    });
    final d = await _decode(r) as Map<String, dynamic>;
    token = d['token'] as String;
    return token!;
  }

  Future<void> changePassword(String password) async {
    await _decode(await net.post(_u('/auth/password'),
        headers: _headers, body: jsonEncode({'password': password})));
  }

  Future<({List<Map<String, dynamic>> items, int you})> accounts() async {
    final d = await _decode(await net.get(_u('/accounts'), headers: _headers))
        as Map<String, dynamic>;
    return (
      items: (d['items'] as List).cast<Map<String, dynamic>>(),
      you: (d['you'] ?? 0) as int,
    );
  }

  Future<Map<String, dynamic>> createAccount(String name, String password) async =>
      await _decode(await net.post(_u('/accounts'),
              headers: _headers,
              body: jsonEncode({'name': name, 'password': password})))
          as Map<String, dynamic>;

  Future<void> resetPassword(int id, String password,
      {bool signOutDevices = false}) async {
    await _decode(await net.post(_u('/accounts/$id/password'),
        headers: _headers,
        body: jsonEncode({
          'password': password,
          'sign_out_devices': signOutDevices,
        })));
  }

  Future<void> deleteAccount(int id) async {
    await _decode(await net.delete(_u('/accounts/$id'), headers: _headers));
  }

  Future<Map<String, dynamic>> createInvite({String? note}) async =>
      await _decode(await net.post(_u('/accounts/invites'),
              headers: _headers,
              body: jsonEncode({if (note != null) 'note': note})))
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> me() async =>
      await _decode(await net.get(_u('/me'), headers: _headers)) as Map<String, dynamic>;

  /// Local catalog first, then YouTube Music. Remote hits are flagged `known` when
  /// the library already has them, so the UI never offers to fetch a track twice.
  Future<({List<Track> local, List<RemoteHit> remote, String? remoteError})> search(
      String q) async {
    final d = await _decode(await net.get(_u('/search', {'q': q}), headers: _headers))
        as Map<String, dynamic>;
    return (
      local: ((d['local'] ?? []) as List).map((e) => Track.fromJson(e)).toList(),
      remote: ((d['remote'] ?? []) as List).map((e) => RemoteHit.fromJson(e)).toList(),
      // YouTube answers this server's address with a challenge page often enough that
      // the search has to be able to say so instead of looking empty.
      remoteError: d['remote_error'] as String?,
    );
  }

  // ---------------- the other people here ----------------
  /// Everybody on this server, with what each has and whether they have a jam going.
  /// Where each letter starts in the records list or the artists list, sorted by name.
  ///
  /// The songs list has several alphabetical orders, so it says which: [sort] is
  /// 'title', 'artist' or 'album', and [readyOnly] as the list itself is asked.
  Future<List<({String letter, int offset})>> letters(String of,
      {String? sort, bool readyOnly = false}) async {
    final d = await _decode(await net.get(
        _u('/library/$of/index', {
          if (sort != null) 'sort': sort,
          if (readyOnly) 'ready_only': true,
        }),
        headers: _headers)) as Map<String, dynamic>;
    return [
      for (final l in (d['letters'] ?? const []) as List)
        (letter: '${l['letter']}', offset: (l['offset'] ?? 0) as int)
    ];
  }

  /// Where the voice is in a song and what it sings. See VocalMap.
  Future<VocalMap> vocals(int trackId) async => VocalMap.fromJson(
      await _decode(await net.get(_u('/tracks/$trackId/vocals'), headers: _headers))
          as Map<String, dynamic>);

  /// Where a song's sound starts and ends, its tempo and its beats. See TrackTiming.
  Future<TrackTiming> timing(int trackId) async => TrackTiming.fromJson(
      await _decode(await net.get(_u('/tracks/$trackId/analysis'), headers: _headers))
          as Map<String, dynamic>);

  // ---------------- the pool ----------------
  /// Everything the pool screen shows: the computers, what each is doing, what is
  /// waiting, the pauses. See server/muse/pool.py.
  Future<Map<String, dynamic>> pool() async =>
      Map<String, dynamic>.from(await _decode(await net.get(_u('/pool'), headers: _headers)) as Map);

  Future<void> poolPause(String kind, bool paused) async => _decode(await net.post(
      _u('/pool/pause'),
      headers: _headers,
      body: jsonEncode({'kind': kind, 'paused': paused})));

  Future<void> poolBlock(int deviceId, bool blocked) async => _decode(await net.post(
      _u('/pool/devices/$deviceId/block'),
      headers: _headers,
      body: jsonEncode({'blocked': blocked})));

  /// Have the pool take a record apart, now.
  Future<void> poolSplit(int trackId) async =>
      _decode(await net.post(_u('/pool/split/$trackId'), headers: _headers));

  /// Where one record is on its way to being in parts: the parts kept, and who has
  /// the split.
  Future<Map<String, dynamic>> poolSplitState(int trackId) async => Map<String, dynamic>.from(
      await _decode(await net.get(_u('/pool/split/$trackId'), headers: _headers)) as Map);

  Future<void> poolCancel(int jobId) async =>
      _decode(await net.post(_u('/pool/jobs/$jobId/cancel'), headers: _headers));

  Future<void> poolRetry(int jobId) async =>
      _decode(await net.post(_u('/pool/jobs/$jobId/retry'), headers: _headers));

  // ---------------- this computer fetching music ----------------
  /// Whether this device may fetch music for the house, and whether it has asked.
  Future<({bool allowed, bool asked})> ingestStanding() async => _standing(
      await _decode(await net.get(_u('/devices/ingest'), headers: _headers)));

  /// Offer this computer. An admin's own is allowed at once; anybody else's waits for
  /// an admin to say yes.
  Future<({bool allowed, bool asked})> askToIngest() async => _standing(
      await _decode(await net.post(_u('/devices/ingest/ask'), headers: _headers)));

  Future<({bool allowed, bool asked})> stopIngesting() async => _standing(
      await _decode(await net.delete(_u('/devices/ingest'), headers: _headers)));

  ({bool allowed, bool asked}) _standing(dynamic d) =>
      (allowed: d['allowed'] == true, asked: d['asked'] == true);

  /// Everything that fetches, and everything asking to. Admins only.
  Future<Map<String, dynamic>> ingestWorkers() async =>
      await _decode(await net.get(_u('/devices/workers'), headers: _headers))
          as Map<String, dynamic>;

  Future<void> allowIngest(int deviceId, bool allowed) async =>
      await _decode(await net.post(_u('/devices/$deviceId/ingest'),
          headers: _headers, body: jsonEncode({'allowed': allowed})));

  /// The worker protocol, for a device that has been allowed. Raw, because what uses it
  /// lives with the downloader: see worker/this_computer_io.dart.
  Future<dynamic> workerPost(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final asked = net.post(_u(path), headers: _headers, body: jsonEncode(body));
    return _decode(await (timeout == null ? asked : asked.timeout(timeout)));
  }

  // ---------------- a listening diary kept elsewhere ----------------
  Future<Scrobbling> scrobbling() async => Scrobbling.fromJson(
      await _decode(await net.get(_u('/scrobbling'), headers: _headers))
          as Map<String, dynamic>);

  /// The token is checked by the server before it is kept, and never comes back.
  Future<Scrobbling> connectListenBrainz(String token) async => Scrobbling.fromJson(
      await _decode(await net.put(_u('/scrobbling/listenbrainz'),
          headers: _headers, body: jsonEncode({'token': token}))) as Map<String, dynamic>);

  Future<Scrobbling> disconnectListenBrainz() async => Scrobbling.fromJson(
      await _decode(await net.delete(_u('/scrobbling/listenbrainz'), headers: _headers))
          as Map<String, dynamic>);

  /// A nod at what somebody is playing. See routes_social.react: one of a fixed
  /// handful, to that one person, kept nowhere.
  Future<void> react(int personId, String emoji, {int? trackId}) async =>
      await _decode(await net.post(_u('/social/people/$personId/react'),
          headers: _headers,
          body: jsonEncode({'emoji': emoji, if (trackId != null) 'track_id': trackId})));

  Future<({List<Person> people, int you})> people() async {
    final d = await _decode(await net.get(_u('/social/people'), headers: _headers))
        as Map<String, dynamic>;
    return (
      people: ((d['people'] ?? const []) as List)
          .map((e) => Person.fromJson(e as Map<String, dynamic>))
          .toList(),
      you: (d['you'] ?? 0) as int,
    );
  }

  Future<Person> person(int id) async => Person.fromJson(await _decode(
      await net.get(_u('/social/people/$id'), headers: _headers))
      as Map<String, dynamic>);

  /// What somebody has kept, newest first.
  Future<({List<Track> items, int total})> personLibrary(int id,
      {int limit = 60, int offset = 0}) async {
    final d = await _decode(await net.get(
        _u('/social/people/$id/library',
            {'limit': '$limit', 'offset': '$offset'}),
        headers: _headers)) as Map<String, dynamic>;
    return (
      items: ((d['items'] ?? const []) as List)
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (d['total'] ?? 0) as int,
    );
  }

  Future<List<Playlist>> personPlaylists(int id) async =>
      ((await _decode(await net.get(_u('/social/people/$id/playlists'),
              headers: _headers)) ?? const []) as List)
          .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
          .toList();

  /// Keep somebody else's playlist in your own library. A save, not a copy.
  Future<void> savePlaylist(int id) async => await _decode(await net.post(
      _u('/playlists/$id/save'), headers: _headers, body: '{}'));

  Future<void> unsavePlaylist(int id) async => await _decode(
      await net.delete(_u('/playlists/$id/save'), headers: _headers));

  /// Have the pool take every song in a list apart, now and as songs arrive — or
  /// stop. Answers how many songs were queued.
  Future<int> setPlaylistAutoSplit(int id, bool on) async {
    final d = await _decode(await net.post(_u('/playlists/$id/auto-split'),
        headers: _headers, body: jsonEncode({'auto_split': on}))) as Map;
    return (d['queued'] as num?)?.toInt() ?? 0;
  }

  /// Let everybody else add to a list of yours, or stop letting them.
  Future<bool> setPlaylistOpenEdit(int id, bool on) async {
    final d = await _decode(await net.post(_u('/playlists/$id/open-edit'),
        headers: _headers, body: jsonEncode({'open_edit': on}))) as Map;
    return d['open_edit'] == true;
  }

  /// Everything, everywhere, in one list.
  ///
  /// The old [search] answers in the shape the sectioned screen wanted — library here,
  /// YouTube Music there. This one answers with rows that are all the same shape,
  /// ranked together, each saying where it came from.
  Future<({List<Found> items, Map<String, String> notes})> searchEverything(
    String q, {
    String where = 'all',
    String kind = 'all',
    bool lyrics = false,
    int limit = 30,
  }) async {
    final d = await _decode(await net.get(
        _u('/search/everything', {
          'q': q,
          'where': where,
          'kind': kind,
          if (lyrics) 'lyrics': 'true',
          'limit': '$limit',
        }),
        headers: _headers)) as Map<String, dynamic>;
    return (
      items: ((d['items'] ?? const []) as List)
          .map((e) => Found.fromJson(e as Map<String, dynamic>))
          .toList(),
      notes: ((d['notes'] ?? const {}) as Map)
          .map((k, v) => MapEntry('$k', '$v')),
    );
  }

  /// What is on a record that was found somewhere else.
  Future<FoundAlbum> foundAlbum(String place, String id) async =>
      FoundAlbum.fromJson(await _decode(await net.get(
          _u('/search/album', {'place': place, 'id': id}),
          headers: _headers)) as Map<String, dynamic>);

  /// Take one row from a search, whatever service it came from.
  Future<Track> addFound(Found found) async => Track.fromJson(await _decode(
      await net.post(_u('/search/add'),
          headers: _headers,
          body: jsonEncode({
            'place': found.place,
            'id': found.id,
            'title': found.title,
            'subtitle': found.subtitle,
            if (found.album != null) 'album': found.album,
            if (found.durationMs != null) 'duration_ms': found.durationMs,
            if (found.url != null) 'url': found.url,
          }))) as Map<String, dynamic>);

  /// 200 when the server already had it, 202 when it just queued a download.
  Future<Track> resolve({String? videoId, String? query}) async {
    final r = await net.post(_u('/tracks/resolve'),
        headers: _headers,
        body: jsonEncode({if (videoId != null) 'video_id': videoId, if (query != null) 'query': query}));
    return Track.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<Track> track(int id) async =>
      Track.fromJson(await _decode(await net.get(_u('/tracks/$id'), headers: _headers))
          as Map<String, dynamic>);

  String streamUrl(Track t) {
    final key = _streamKey;
    return key == null
        ? '$baseUrl${t.streamPath}'
        : '$baseUrl${t.streamPath}?k=${Uri.encodeQueryComponent(key)}';
  }

  /// Where a part of a record is: its drums, the music under them, or the whole of
  /// it with the voice taken out. Signed the same way the record itself is.
  String stemUrl(Track t, String part) {
    final key = _streamKey;
    return '$baseUrl${t.streamPath}'.replaceFirst(RegExp(r'/stream$'), '/stem/$part') +
        (key == null ? '' : '?k=${Uri.encodeQueryComponent(key)}');
  }

  /// Whether that part has been made yet, asking for it to be if not.
  ///
  /// The server answers 202 while it is on the bench, so this is both the question
  /// and the request: ask once, wait, ask again. A record it will not take apart at
  /// all — one longer than a record — answers 404, which is a different answer from
  /// "not yet" and has to stay one.
  Future<Stem> stemState(Track t, String part) async {
    await ensureStreamKey();
    final r = await net.get(Uri.parse(stemUrl(t, part)),
        headers: {...(kIsWeb ? const {} : streamHeaders), 'Range': 'bytes=0-0'});
    if (r.statusCode == 202) return Stem.beingMade;
    if (r.statusCode == 404) return Stem.never;
    if (r.statusCode >= 400) throw ApiException(r.statusCode, 'could not ask for the $part');
    return Stem.ready;
  }

  /// Same signed-key trick as audio: an <img> cannot send an Authorization header.
  String? coverUrl(Track t, {bool small = false}) {
    if (t.coverPath == null) return null;
    final key = _streamKey;
    final size = small ? 'sm' : 'lg';
    final auth = key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}';
    // The version changes when the artwork does; without it a client that already
    // cached "no cover" or an older image by URL would never pick up the new one.
    final version = t.coverVersion == null ? '' : '&v=${t.coverVersion}';
    return '$baseUrl${t.coverPath}?size=$size$version$auth';
  }

  /// Artwork for a search hit, which lives on the provider's CDN and is proxied by
  /// our server so the browser stays on one origin.
  String? remoteCoverUrl(String? path) {
    if (path == null) return null;
    final key = _streamKey;
    return '$baseUrl$path${key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}'}';
  }

  /// A cover addressed by path rather than by track — album and artist rows borrow a
  /// cover from one of their tracks.
  /// The cover as a record: the whole thing as one picture, or the pieces the player
  /// animates separately. Same cache rules as the flat cover; the server renders each
  /// once per cover and never again.
  /// How the server is drawing records at the moment.
  ///
  /// Carried in every sleeve URL. Covers are cached for a year and marked immutable,
  /// which is right — the artwork's hash is in the address — but it means a change to
  /// the *renderer* has nothing to make a browser, or this app's own store, ask again.
  /// The number does that, and it comes from the server rather than being compiled in
  /// so the two can never disagree.
  int sleeveVersion = 0;

  String? sleeveUrl(Track t, {bool small = false, String part = 'sleeve'}) {
    final flat = coverUrl(t, small: small);
    return flat == null ? null : '$flat&style=$part&r=$sleeveVersion';
  }

  String? jacketUrl(Track t, {bool small = false}) =>
      sleeveUrl(t, small: small, part: 'jacket');

  /// How much of the record's face the picture covers, as a fraction of its radius.
  ///
  /// The server draws the disc and caches it per size, so this rides in the URL: a
  /// different number is a different picture and therefore a different address, which
  /// is also what makes every cache between here and the disk let go of the old one.
  double discLabel = 0.31;

  String? discUrl(Track t, {bool small = false}) {
    final url = sleeveUrl(t, small: small, part: 'disc');
    if (url == null || (discLabel - 0.31).abs() < 0.005) return url;
    return '$url&label=${discLabel.toStringAsFixed(2)}';
  }

  // ---------------- the back of a sleeve ----------------
  /// Everything drawn on this record's back, on whichever board this device is on:
  /// your own, or the host's when you are in a jam.
  Future<List<SleeveStroke>> marks(int trackId) async {
    final d = await _decode(await net.get(_u('/tracks/$trackId/marks'),
        headers: _headers)) as Map<String, dynamic>;
    return [
      for (final s in (d['strokes'] ?? const []) as List)
        SleeveStroke.fromJson(s as Map<String, dynamic>)
    ];
  }

  /// A line, or as much of one as has been drawn so far.
  ///
  /// Sent whole every time rather than as a difference: a stroke is a few dozen
  /// numbers, and "here is the line as it stands" cannot arrive out of order or land
  /// twice, which is worth more than the bytes it costs.
  Future<void> draw(int trackId, SleeveStroke stroke) async {
    await _decode(await net.post(_u('/tracks/$trackId/marks'),
        headers: _headers,
        body: jsonEncode({
          'stroke_id': stroke.id,
          'ink': stroke.ink,
          'width': stroke.width,
          'points': stroke.points,
          'done': stroke.done,
        })));
  }

  Future<void> undoMark(int trackId, String strokeId) async {
    await _decode(await net.delete(
        _u('/tracks/$trackId/marks/$strokeId'), headers: _headers));
  }

  Future<void> wipeMarks(int trackId) async {
    await _decode(
        await net.delete(_u('/tracks/$trackId/marks'), headers: _headers));
  }

  /// Put this queue's own songs ahead of everything else waiting to download.
  ///
  /// A queue is a statement about what is going to be listened to; an import is a
  /// statement about what might be wanted some day. Answers with how many were moved
  /// up or started.
  Future<int> prioritiseQueue(int queueId) async {
    final d = await _decode(await net.post(
        _u('/queues/$queueId/prioritise'), headers: _headers)) as Map<String, dynamic>;
    return ((d['moved'] ?? 0) as int) + ((d['queued'] ?? 0) as int);
  }

  /// Take the whole thing: queue the audio for everything in a playlist that has none.
  Future<int> downloadPlaylist(int playlistId) async {
    final d = await _decode(await net.post(_u('/playlists/$playlistId/download'),
        headers: _headers)) as Map<String, dynamic>;
    return (d['queued'] ?? 0) as int;
  }

  /// A playlist's own art. Immutable per version, so it caches forever and still
  /// changes the moment the playlist does.
  /// A picture for the account, sent as it came off the phone.
  Future<String> setAvatar(List<int> bytes) async {
    final d = await _decode(await net.post(_u('/me/avatar'),
        headers: {..._headers, 'Content-Type': 'application/octet-stream'},
        body: bytes)) as Map<String, dynamic>;
    return d['avatar_version'] as String;
  }

  /// Hand the phone's own record of what the audio engine did to the server.
  ///
  /// So that "it stopped again" can be answered by reading what happened rather than
  /// by asking somebody to describe a minute they were not watching.
  Future<void> sendPlaybackLog(List<String> lines,
      {String? device, String? build}) async {
    if (lines.isEmpty) return;
    await _decode(await net.post(_u('/playback-log'),
        headers: _headers,
        body: jsonEncode({
          'lines': lines,
          if (device != null) 'device': device,
          if (build != null) 'build': build,
        })));
  }

  // ---------------- the app's own icon ----------------

  /// What the icon is now, and whether this account may change it.
  Future<({String version, bool custom, bool mayChange})> appIcon() async {
    final d = await _decode(await net.get(_u('/icon.json'), headers: _headers))
        as Map<String, dynamic>;
    return (
      version: '${d['version'] ?? ''}',
      custom: (d['custom'] ?? false) as bool,
      mayChange: (d['may_change'] ?? false) as bool,
    );
  }

  /// Where to draw it. The version is in the URL so a changed icon is a different
  /// picture as far as every cache between here and the server is concerned.
  String appIconUrl({int size = 192, String? version}) =>
      '$baseUrl/icon?size=$size${version == null || version.isEmpty ? '' : '&v=$version'}';

  Future<String> setAppIcon(List<int> bytes) async {
    final d = await _decode(await net.post(_u('/icon'),
        headers: {..._headers, 'Content-Type': 'application/octet-stream'},
        body: bytes)) as Map<String, dynamic>;
    return '${d['version'] ?? ''}';
  }

  Future<String> clearAppIcon() async {
    final d = await _decode(await net.delete(_u('/icon'), headers: _headers))
        as Map<String, dynamic>;
    return '${d['version'] ?? ''}';
  }

  Future<void> clearAvatar() async =>
      await _decode(await net.delete(_u('/me/avatar'), headers: _headers));

  /// Somebody's picture, if they have one. Signed like every other image the app shows,
  /// because an <img> cannot carry a header.
  String avatarUrl(int userId, {String? version, bool small = true}) {
    final key = _streamKey;
    return '$baseUrl/users/$userId/avatar?size=${small ? 'sm' : 'lg'}'
        '${version == null ? '' : '&v=$version'}'
        '${key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}'}';
  }

  /// A cover of your own for a playlist, instead of the one drawn from its records.
  Future<void> setPlaylistCover(int playlistId, List<int> bytes) async =>
      await _decode(await net.post(_u('/playlists/$playlistId/cover'),
          headers: {..._headers, 'Content-Type': 'application/octet-stream'},
          body: bytes));

  Future<void> clearPlaylistCover(int playlistId) async => await _decode(
      await net.delete(_u('/playlists/$playlistId/cover'), headers: _headers));

  String? playlistCoverUrl(Playlist p, {bool small = true}) {
    if (p.coverPath == null) return null;
    final key = _streamKey;
    return '$baseUrl${p.coverPath}?size=${small ? 'sm' : 'lg'}'
        '${p.coverVersion == null ? '' : '&v=${p.coverVersion}'}'
        '${key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}'}';
  }

  String? coverUrlForPath(String? path, {bool small = true}) {
    if (path == null) return null;
    final key = _streamKey;
    return '$baseUrl$path?size=${small ? 'sm' : 'lg'}'
        '${key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}'}';
  }

  // ---------------- downloads ----------------
  Future<DownloadOverview> downloads() async => DownloadOverview.fromJson(
      await _decode(await net.get(_u('/downloads'), headers: _headers))
          as Map<String, dynamic>);

  Future<bool> pauseDownloads(bool paused) async {
    final d = await _decode(await net.post(_u('/downloads/pause'),
        headers: _headers, body: jsonEncode({'paused': paused})))
        as Map<String, dynamic>;
    return (d['paused'] ?? false) as bool;
  }

  Future<int> retryFailedDownloads({String? batchId, String? failCode}) async {
    final d = await _decode(await net.post(_u('/downloads/retry-failed'),
        headers: _headers,
        body: jsonEncode({
          if (batchId != null) 'batch_id': batchId,
          if (failCode != null) 'fail_code': failCode,
        })))
        as Map<String, dynamic>;
    return (d['retrying'] ?? 0) as int;
  }

  Future<int> cancelDownloads({String? batchId, int? trackId, bool all = false}) async {
    final d = await _decode(await net.post(_u('/downloads/cancel'),
        headers: _headers,
        body: jsonEncode({
          if (batchId != null) 'batch_id': batchId,
          if (trackId != null) 'track_id': trackId,
          if (all) 'all': true,
        }))) as Map<String, dynamic>;
    return (d['cancelled'] ?? 0) as int;
  }

  /// Go looking for another copy of songs whose copy has gone. Returns how many were
  /// found somewhere else.
  Future<Map<String, dynamic>> refindFailed() async =>
      await _decode(await net.post(_u('/downloads/refind'),
          headers: _headers, body: jsonEncode({}))) as Map<String, dynamic>;

  /// Ask for this one now. Says how many of them actually got a job.
  ///
  /// The answer matters: a track with nowhere left to fetch it from cannot be started,
  /// and a button that silently does nothing is worse than one that says why.
  Future<int> promoteDownload(int trackId) => promoteDownloads([trackId]);

  /// Tracks in playing order: the one under the needle, then what follows it.
  ///
  /// Answers with how many were actually started. Zero out of one means the song has
  /// nowhere left to be fetched from, which is worth saying out loud.
  Future<int> promoteDownloads(List<int> trackIds) async {
    if (trackIds.isEmpty) return 0;
    final d = await _decode(await net.post(_u('/downloads/promote'),
        headers: _headers,
        body: jsonEncode({'track_ids': trackIds}))) as Map<String, dynamic>;
    return (d['promoted'] ?? 0) as int;
  }

  /// Pull the start of a track through the cache so it is there when it is wanted.
  ///
  /// A range request rather than the whole file: enough that playback starts on what
  /// is already local, cheap enough to do on every track change. The browser and the
  /// native HTTP cache both keep it; failures are silent because this is a nicety.
  Future<void> warmStream(Track t) async {
    try {
      await net.get(Uri.parse(streamUrl(t)),
          headers: {...(kIsWeb ? const {} : streamHeaders), 'Range': 'bytes=0-524287'});
    } catch (_) {
      // Not being able to warm the cache is not a failure worth reporting.
    }
  }

  // ---------------- other sources ----------------
  /// SoundCloud or Bandcamp. The server fetches these itself, so they arrive without
  /// the machine at home being awake.
  Future<List<SourceHit>> searchSource(String source, String query,
      {int limit = 8}) async {
    final d = await _decode(await net.get(
        _u('/sources/search?source=$source&limit=$limit'
            '&q=${Uri.encodeQueryComponent(query)}'),
        headers: _headers)) as Map<String, dynamic>;
    return ((d['items'] ?? const []) as List)
        .map((e) => SourceHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Track> addFromSource(SourceHit hit) async => Track.fromJson(await _decode(
      await net.post(_u('/sources/resolve'),
          headers: _headers,
          body: jsonEncode({
            'provider': hit.provider,
            'provider_id': hit.providerId,
            'title': hit.title,
            'artists': hit.artists,
            'album': hit.album,
            'duration_ms': hit.durationMs,
            'url': hit.url,
          }))) as Map<String, dynamic>);

  Future<AlbumPreview> previewAlbum(String url) async => AlbumPreview.fromJson(
      await _decode(await net.get(
          _u('/sources/preview?url=${Uri.encodeQueryComponent(url)}'),
          headers: _headers)) as Map<String, dynamic>);

  Future<Map<String, dynamic>> importAlbum(String url) async =>
      await _decode(await net.post(_u('/sources/import'),
          headers: _headers, body: jsonEncode({'url': url}))) as Map<String, dynamic>;

  // ---------------- linked services ----------------
  Future<List<LinkedService>> linkedServices() async {
    final d = await _decode(await net.get(_u('/linked'), headers: _headers))
        as Map<String, dynamic>;
    return ((d['accounts'] ?? const []) as List)
        .map((e) => LinkedService.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> linkService(String provider, String handle) async =>
      await _decode(await net.post(_u('/linked/$provider'),
          headers: _headers, body: jsonEncode({'handle': handle})));

  Future<void> unlinkService(String provider) async =>
      await _decode(await net.delete(_u('/linked/$provider'), headers: _headers));

  /// Whether this server can sign people in with a code at all, and where its OAuth
  /// client came from. Never the client itself: the tail of the id is all that comes
  /// back, which is enough to tell one from another.
  Future<({bool configured, bool maySet, String? from, String? endsWith})>
      youtubeSignInClient() async {
    final d = await _decode(await net.get(_u('/linked/youtube/oauth/client'),
        headers: _headers)) as Map<String, dynamic>;
    return (
      configured: d['configured'] == true,
      maySet: d['may_set'] == true,
      from: d['from'] as String?,
      endsWith: d['ends_with'] as String?,
    );
  }

  /// Give the server an OAuth client, so everybody on it can sign in with a code.
  /// Admins only, and checked with Google before it is kept.
  Future<void> setYoutubeSignInClient(String clientId, String clientSecret) async =>
      await _decode(await net.put(_u('/linked/youtube/oauth/client'),
          headers: _headers,
          body: jsonEncode(
              {'client_id': clientId, 'client_secret': clientSecret})));

  Future<void> clearYoutubeSignInClient() async => await _decode(
      await net.delete(_u('/linked/youtube/oauth/client'), headers: _headers));

  /// Start signing in to YouTube Music with a code. Answers with the code to read out
  /// and where to type it.
  Future<({String deviceCode, String userCode, String url, int interval})>
      startYoutubeSignIn() async {
    final d = await _decode(await net.post(_u('/linked/youtube/oauth'),
        headers: _headers, body: '{}')) as Map<String, dynamic>;
    return (
      deviceCode: d['device_code'] as String,
      userCode: d['user_code'] as String,
      url: d['url'] as String,
      interval: (d['interval'] ?? 5) as int,
    );
  }

  /// Ask whether they have finished over there. Throws with status 409 while they have
  /// not, which is "not yet" rather than "no".
  Future<void> finishYoutubeSignIn(String deviceCode) async =>
      await _decode(await net.post(_u('/linked/youtube/oauth/finish'),
          headers: _headers, body: jsonEncode({'device_code': deviceCode})));

  Future<List<RemoteList>> serviceLists(String provider) async {
    final d = await _decode(
        await net.get(_u('/linked/$provider/playlists'), headers: _headers))
        as Map<String, dynamic>;
    return ((d['items'] ?? const []) as List)
        .map((e) => RemoteList.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> mirrorList(String provider, RemoteList list) async =>
      await _decode(await net.post(_u('/linked/$provider/sync'),
          headers: _headers,
          body: jsonEncode({'remote_id': list.remoteId, 'name': list.name})));

  /// Copy one list by its id or its link, without having listed anything first — a
  /// public playlist somebody sent you needs no account here.
  Future<void> syncServiceList(String provider, String remoteId) async =>
      await _decode(await net.post(_u('/linked/$provider/sync'),
          headers: _headers, body: jsonEncode({'remote_id': remoteId})));

  // ---------------- jam ----------------
  Future<Jam> startJam(int queueId) async => Jam.fromJson(await _decode(
      await net.post(_u('/jams'),
          headers: _headers, body: jsonEncode({'queue_id': queueId}))) as Map<String, dynamic>);

  Future<Jam> joinJam(String code) async => Jam.fromJson(await _decode(
      await net.post(_u('/jams/join'),
          headers: _headers, body: jsonEncode({'code': code}))) as Map<String, dynamic>);

  /// Every jam running now. Everybody here has an account on this server, so a room
  /// is something to walk into rather than something to be let into.
  Future<List<OpenJam>> openJams() async {
    final d = await _decode(await net.get(_u('/jams'), headers: _headers))
        as Map<String, dynamic>;
    return [
      for (final e in (d['items'] ?? const []) as List)
        OpenJam.fromJson(e as Map<String, dynamic>)
    ];
  }

  /// The jam you are in, and a heartbeat that keeps you listed as here.
  /// The host putting a different queue on, with the room following it.
  Future<Jam> moveJam(int jamId, int queueId) async => Jam.fromJson(await _decode(
      await net.post(_u('/jams/$jamId/queue'),
          headers: _headers,
          body: jsonEncode({'queue_id': queueId}))) as Map<String, dynamic>);

  Future<Jam?> currentJam() async {
    final d = await _decode(await net.get(_u('/jams/current'), headers: _headers))
        as Map<String, dynamic>;
    return d['jam'] == null ? null : Jam.fromJson(d['jam'] as Map<String, dynamic>);
  }

  /// The host telling the room where the music is. Fire and forget: a dropped one is
  /// replaced by the next heartbeat a few seconds later.
  Future<void> pushJamPlayback(int jamId,
          {int? trackId,
          int? itemId,
          int? seq,
          required int positionMs,
          required bool playing}) async =>
      await _decode(await net.post(_u('/jams/$jamId/playback'),
          headers: _headers,
          body: jsonEncode({
            'track_id': trackId,
            'position_ms': positionMs,
            'playing': playing,
            if (itemId != null) 'item_id': itemId,
            if (seq != null) 'seq': seq,
          })));

  /// A guest reaching for the transport. The host's device does the work.
  Future<void> jamControl(int jamId, String action, {int? positionMs}) async =>
      await _decode(await net.post(_u('/jams/$jamId/control'),
          headers: _headers,
          body: jsonEncode({
            'action': action,
            if (positionMs != null) 'position_ms': positionMs,
          })));

  Future<void> leaveJam(int jamId) async =>
      await _decode(await net.post(_u('/jams/$jamId/leave'), headers: _headers));

  Future<void> removeFromJam(int jamId, int userId) async =>
      await _decode(await net.post(_u('/jams/$jamId/remove'),
          headers: _headers, body: jsonEncode({'user_id': userId})));

  /// Ask for the current track to be dropped. Returns how many have asked.
  Future<Map<String, dynamic>> status() async =>
      await _decode(await net.get(_u('/status'), headers: _headers))
          as Map<String, dynamic>;

  Map<String, String> get streamHeaders => {'Authorization': 'Bearer $token'};

  bool get hasStreamKey => _streamKey != null;

  // ---------------- queues ----------------
  Future<List<Queue>> queues() async {
    final d = await _decode(await net.get(_u('/queues'), headers: _headers)) as List;
    return d.map((e) => Queue.fromJson(e)).toList();
  }

  /// A queue — or, when it is a long one, the few hundred rows around where you are.
  ///
  /// [around] asks for the slice centred somewhere else, which is what the app sends
  /// when playback has walked to the edge of the slice it was given.
  Future<Queue> queue(int id, {int? around}) async => Queue.fromJson(
      await _decode(await net.get(
          _u('/queues/$id', {if (around != null) 'around': '$around'}),
          headers: _headers)) as Map<String, dynamic>);

  Future<Queue> createQueue(String name) async => Queue.fromJson(await _decode(
      await net.post(_u('/queues'), headers: _headers, body: jsonEncode({'name': name})))
      as Map<String, dynamic>);

  /// Order is versioned. A 409 means someone else reordered it; the caller gets the
  /// live state back so it can merge instead of overwriting.
  Future<Queue> replaceQueue(int id, int rev, List<int> trackIds) async {
    final r = await net.put(_u('/queues/$id'),
        headers: _headers, body: jsonEncode({'rev': rev, 'items': trackIds}));
    if (r.statusCode == 409) {
      final d = jsonDecode(r.body)['detail'] as Map<String, dynamic>;
      throw QueueConflict(Queue.fromJson(d['current'] as Map<String, dynamic>));
    }
    return Queue.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  /// Deal the rest of the queue again. Once — see the server's own note on it.
  /// Move several rows as one. Dragging one row of a selection brings the rest.
  Future<Queue> moveQueueItems(int id, List<int> froms, int to) async =>
      Queue.fromJson(await _decode(await net.post(_u('/queues/$id/move'),
          headers: _headers,
          body: jsonEncode({'from': froms, 'to': to}))) as Map<String, dynamic>);

  ///
  /// [order] is the order the app already dealt — the track ids after the song
  /// playing, as they now stand on screen — so the server keeps that one rather than
  /// dealing its own on top of it. An older server ignores it and shuffles itself.
  Future<Queue> shuffleQueue(int id, {List<int>? order}) async =>
      Queue.fromJson(await _decode(await net.post(_u('/queues/$id/shuffle'),
              headers: _headers,
              body: jsonEncode({if (order != null) 'order': order})))
          as Map<String, dynamic>);

  Future<Queue> addToQueue(int id, List<int> trackIds, {String mode = 'end'}) async =>
      Queue.fromJson(await _decode(await net.post(_u('/queues/$id/items'),
              headers: _headers, body: jsonEncode({'track_ids': trackIds, 'mode': mode})))
          as Map<String, dynamic>);

  /// The cursor is not versioned: the device that is playing is the authority.
  Future<void> setCursor(int id, {int? index, int? positionMs}) async {
    await _decode(await net.patch(_u('/queues/$id/cursor'),
        headers: _headers,
        body: jsonEncode({
          if (index != null) 'cursor_index': index,
          if (positionMs != null) 'position_ms': positionMs,
        })));
  }

  /// Settings only. Deliberately not PUT: that endpoint replaces the item list, and
  /// sending settings through it used to empty the queue.
  Future<Queue> updateQueueSettings(int id,
      {String? name, bool? shuffle, String? repeat}) async {
    final r = await net.patch(_u('/queues/$id'),
        headers: _headers,
        body: jsonEncode({
          if (name != null) 'name': name,
          if (shuffle != null) 'shuffle': shuffle,
          if (repeat != null) 'repeat': repeat,
        }));
    return Queue.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<Queue> removeQueueItem(int id, int pos) async =>
      Queue.fromJson(await _decode(
              await net.delete(_u('/queues/$id/items/$pos'), headers: _headers))
          as Map<String, dynamic>);

  Future<Queue> moveQueueItem(int id, int from, int to) async =>
      Queue.fromJson(await _decode(await net.post(_u('/queues/$id/move'),
              headers: _headers, body: jsonEncode({'from': from, 'to': to})))
          as Map<String, dynamic>);

  /// `origin: 'radio'` clears only the machine-picked tail.
  Future<Queue> clearQueue(int id, {String? origin}) async =>
      Queue.fromJson(await _decode(await net.post(_u('/queues/$id/clear'),
              headers: _headers,
              body: jsonEncode({if (origin != null) 'origin': origin})))
          as Map<String, dynamic>);

  Future<void> deleteQueue(int id) async {
    await _decode(await net.delete(_u('/queues/$id'), headers: _headers));
  }

  // ---------------- stations ----------------

  /// Put a song, a record or an artist on, and keep playing what belongs next to it.
  ///
  /// Answers with the queue the station is: it has its own name and its own place in
  /// the list of queues, so everything a queue can do it can do — reorder, remove,
  /// keep on the device, save to the library.
  Future<Queue> startStation(
      {String kind = 'track', int? trackId, String? album, String? artist}) async =>
      Queue.fromJson(await _decode(await net.post(_u('/stations'),
              headers: _headers,
              body: jsonEncode({
                'kind': kind,
                if (trackId != null) 'track_id': trackId,
                if (album != null) 'album': album,
                if (artist != null) 'artist': artist,
              }))) as Map<String, dynamic>);

  /// More of the same, asked for as it runs down.
  Future<Queue> extendStation(int queueId, {int count = 8}) async =>
      Queue.fromJson(await _decode(await net.post(
              _u('/stations/$queueId/extend'),
              headers: _headers,
              body: jsonEncode({'count': count}))) as Map<String, dynamic>);

  // ---------------- library ----------------
  Future<List<Playlist>> playlists() async {
    final d = await _decode(await net.get(_u('/playlists'), headers: _headers)) as List;
    return d.map((e) => Playlist.fromJson(e)).toList();
  }

  Future<Playlist> playlist(int id) async =>
      Playlist.fromJson(await _decode(await net.get(_u('/playlists/$id'), headers: _headers))
          as Map<String, dynamic>);

  Future<Playlist> createPlaylist(String name) async =>
      Playlist.fromJson(await _decode(await net.post(_u('/playlists'),
              headers: _headers, body: jsonEncode({'name': name})))
          as Map<String, dynamic>);

  /// Songs from your own library that would sit well in this playlist: more by the
  /// artists already in it, never one that is in it, turned over daily.
  Future<List<Track>> suggestedFor(int playlistId, {int limit = 8}) async {
    final d = await _decode(await net.get(
        _u('/playlists/$playlistId/suggested', {'limit': limit}),
        headers: _headers)) as Map<String, dynamic>;
    return [
      for (final t in (d['items'] ?? const []) as List)
        Track.fromJson((t as Map).cast<String, dynamic>())
    ];
  }

  Future<Playlist> addToPlaylist(int id, List<int> trackIds) async =>
      Playlist.fromJson(await _decode(await net.post(_u('/playlists/$id/items'),
              headers: _headers, body: jsonEncode({'track_ids': trackIds})))
          as Map<String, dynamic>);

  /// Which of your playlists already hold any of these songs, and how many.
  ///
  /// Keyed by playlist id, so the sheet can draw a tick, a dash or nothing without
  /// fetching a single playlist's contents.
  Future<Map<int, int>> playlistsHolding(List<int> trackIds) async {
    final d = await _decode(await net.post(_u('/playlists/holding'),
        headers: _headers, body: jsonEncode({'track_ids': trackIds})));
    final holding = (d['holding'] as Map).cast<String, dynamic>();
    return {
      for (final e in holding.entries) int.parse(e.key): (e.value as num).toInt()
    };
  }

  Future<Playlist> removeFromPlaylist(int id, List<int> trackIds) async =>
      Playlist.fromJson(await _decode(await net.post(
              _u('/playlists/$id/items/remove'),
              headers: _headers,
              body: jsonEncode({'track_ids': trackIds}))) as Map<String, dynamic>);

  Future<Playlist> removePlaylistItem(int id, int pos) async =>
      Playlist.fromJson(await _decode(
              await net.delete(_u('/playlists/$id/items/$pos'), headers: _headers))
          as Map<String, dynamic>);

  Future<void> deletePlaylist(int id) async {
    await _decode(await net.delete(_u('/playlists/$id'), headers: _headers));
  }

  Future<Playlist> saveQueueAsPlaylist(int queueId, {String? name}) async =>
      Playlist.fromJson(await _decode(await net.post(
              _u('/queues/$queueId/save-as-playlist'),
              headers: _headers,
              body: jsonEncode({if (name != null) 'name': name})))
          as Map<String, dynamic>);

  // ---------------- browsing ----------------
  Future<({List<Track> items, int total})> libraryTracks(
      {String sort = 'added', int limit = 200, int offset = 0,
      bool readyOnly = false}) async {
    final d = await _decode(await net.get(
        _u('/library/tracks', {
          'sort': sort,
          'limit': limit,
          'offset': offset,
          if (readyOnly) 'ready_only': true,
        }),
        headers: _headers)) as Map<String, dynamic>;
    return (
      items: (d['items'] as List).map((e) => Track.fromJson(e)).toList(),
      total: (d['total'] ?? 0) as int,
    );
  }

  /// A page of records, and how many there are in all.
  ///
  /// A library of ten thousand albums used to arrive as the two hundred the server
  /// answers with by default, with nothing to say the list went on — so it simply
  /// stopped, a fifth of the way through the alphabet.
  Future<({List<AlbumSummary> items, int total})> albums(
      {int limit = 200, int offset = 0, String? q, String sort = 'name'}) async {
    final d = await _decode(await net.get(
        _u('/library/albums', {
          'limit': limit,
          'offset': offset,
          'sort': sort,
          if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        }),
        headers: _headers)) as Map<String, dynamic>;
    final items =
        (d['items'] as List).map((e) => AlbumSummary.fromJson(e)).toList();
    return (items: items, total: (d['total'] ?? items.length) as int);
  }

  /// The whole record — the parts we hold and the parts we do not.
  Future<AlbumDetail> albumDetail(
      {String? album, String? artist, String? remoteId}) async {
    final d = await _decode(await net.get(
        _u('/library/albums/detail', {
          if (album != null) 'album': album,
          if (artist != null) 'artist': artist,
          if (remoteId != null) 'remote_id': remoteId,
        }),
        headers: _headers)) as Map<String, dynamic>;
    return AlbumDetail.fromJson(d);
  }

  /// Fetch what is missing from a record. Empty [remoteIds] means all of it.
  Future<({int queued, int notMatched})> fillAlbum(
      {String? album, String? artist, String? remoteId,
      List<String> remoteIds = const []}) async {
    final d = await _decode(await net.post(_u('/library/albums/fill'),
        headers: _headers,
        body: jsonEncode({
          if (album != null) 'album': album,
          if (artist != null) 'artist': artist,
          if (remoteId != null) 'remote_id': remoteId,
          if (remoteIds.isNotEmpty) 'remote_ids': remoteIds,
        }))) as Map<String, dynamic>;
    return (queued: (d['queued'] ?? 0) as int,
            notMatched: (d['not_matched'] ?? 0) as int);
  }

  Future<ArtistDetail> artistDetail(String artist) async {
    final d = await _decode(await net.get(
        _u('/library/artists/detail', {'artist': artist}),
        headers: _headers)) as Map<String, dynamic>;
    return ArtistDetail.fromJson(d);
  }

  /// Everyone with an account here, and whether they are around right now.
  Future<List<({int id, String name, bool online, String? avatarVersion})>>
      jamPeople() async {
    final d = await _decode(await net.get(_u('/jams/people'), headers: _headers))
        as Map<String, dynamic>;
    return [
      for (final e in (d['items'] ?? const []) as List)
        (
          id: (e['id'] ?? 0) as int,
          name: (e['name'] ?? '') as String,
          online: (e['online'] ?? false) as bool,
          avatarVersion: e['avatar_sig'] as String?,
        )
    ];
  }

  Future<Jam> inviteToJam(int jamId, int userId) async => Jam.fromJson(
      await _decode(await net.post(_u('/jams/$jamId/invite'),
          headers: _headers, body: jsonEncode({'user_id': userId})))
          as Map<String, dynamic>);

  // ---------------- favourites ----------------
  /// The ids, so a screen full of hearts is one request rather than one per song.
  Future<({int playlistId, List<int> trackIds})> favourites() async {
    final d = await _decode(await net.get(_u('/favourites'), headers: _headers))
        as Map<String, dynamic>;
    return (
      playlistId: (d['playlist_id'] ?? 0) as int,
      trackIds: ((d['track_ids'] ?? const []) as List).cast<int>(),
    );
  }

  /// No value toggles, which is what a tap on a heart means.
  Future<bool> setFavourite(int trackId, {bool? favourite}) async {
    final d = await _decode(await net.post(_u('/favourites/$trackId'),
        headers: _headers,
        body: jsonEncode({if (favourite != null) 'favourite': favourite})))
        as Map<String, dynamic>;
    return (d['favourite'] ?? false) as bool;
  }

  // ---------------- following ----------------
  /// Playlists from another player's backup file.
  ///
  /// The whole file goes up as it came off disk: the server knows the shape, and a
  /// backup that names four hundred songs is still a small thing to send.
  Future<Map<String, dynamic>> importPlaylists(Map<String, dynamic> backup,
          {bool dryRun = false}) async =>
      await _decode(await net.post(_u('/playlists/import'),
              headers: _headers,
              body: jsonEncode({...backup, 'dry_run': dryRun})))
          as Map<String, dynamic>;

  /// What a device would have to fetch to have a playlist or a queue playable with no
  /// signal, and how big that is. Asked before downloading, so the size is a number
  /// somebody agreed to rather than a surprise.
  Future<({int count, double mb, List<int> trackIds})> downloadManifest(
      {int? playlistId, int? queueId}) async {
    final d = await _decode(await net.get(
        _u('/downloads/manifest', {
          if (playlistId != null) 'playlist_id': playlistId,
          if (queueId != null) 'queue_id': queueId,
        }),
        headers: _headers)) as Map<String, dynamic>;
    return (
      count: (d['count'] ?? 0) as int,
      mb: ((d['mb'] ?? 0) as num).toDouble(),
      trackIds: [
        for (final i in (d['items'] ?? const []) as List) (i['track_id'] ?? 0) as int
      ],
    );
  }

  Future<List<FollowedArtist>> follows() async {
    final d = await _decode(await net.get(_u('/follows'), headers: _headers))
        as Map<String, dynamic>;
    return ((d['items'] ?? const []) as List)
        .map((e) => FollowedArtist.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> follow({String? name, String? remoteId, String? image}) async =>
      await _decode(await net.post(_u('/follows'),
          headers: _headers,
          body: jsonEncode({
            if (name != null) 'name': name,
            if (remoteId != null) 'remote_id': remoteId,
            if (image != null) 'image': image,
          })));

  Future<void> unfollow(String remoteId) async => await _decode(
      await net.delete(_u('/follows/$remoteId'), headers: _headers));

  /// Take the artists already followed somewhere else. Answers with what it managed:
  /// how many were found, how many were new, and the names it could not place.
  Future<Map<String, dynamic>> importFollows(String provider) async =>
      await _decode(await net.post(_u('/follows/import'),
          headers: _headers,
          body: jsonEncode({'provider': provider}))) as Map<String, dynamic>;

  Future<({List<FeedItem> items, int unseen, int following})> feed(
      {int limit = 60}) async {
    final d = await _decode(
            await net.get(_u('/feed', {'limit': limit}), headers: _headers))
        as Map<String, dynamic>;
    return (
      items: ((d['items'] ?? const []) as List)
          .map((e) => FeedItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      unseen: (d['unseen'] ?? 0) as int,
      following: (d['following'] ?? 0) as int,
    );
  }

  Future<void> markFeedSeen(List<String> albumIds) async => await _decode(
      await net.post(_u('/feed/seen'),
          headers: _headers, body: jsonEncode({'album_ids': albumIds})));

  Future<void> refreshFeed() async =>
      await _decode(await net.post(_u('/feed/refresh'), headers: _headers));

  Future<List<Track>> albumTracks(String album, {String? artist}) async {
    final d = await _decode(await net.get(
        _u('/library/albums/tracks',
            {'album': album, if (artist != null) 'artist': artist}),
        headers: _headers)) as Map<String, dynamic>;
    return (d['items'] as List).map((e) => Track.fromJson(e)).toList();
  }

  Future<({List<ArtistSummary> items, int total})> artists(
      {int limit = 300, int offset = 0, String? q, String sort = 'name'}) async {
    final d = await _decode(await net.get(
        _u('/library/artists', {
          'limit': limit,
          'offset': offset,
          'sort': sort,
          if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        }),
        headers: _headers)) as Map<String, dynamic>;
    final items =
        (d['items'] as List).map((e) => ArtistSummary.fromJson(e)).toList();
    return (items: items, total: (d['total'] ?? items.length) as int);
  }

  Future<List<Track>> artistTracks(String artist) async {
    final d = await _decode(await net.get(
        _u('/library/artists/tracks', {'artist': artist}), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => Track.fromJson(e)).toList();
  }

  /// The lists that fill themselves in, and how many songs each has right now.
  Future<List<({String id, String name, String blurb, int count})>> smartLists() async =>
      (await smartShelves()).lists;

  /// The lists that fill themselves in, and the decades there is anything from: both
  /// are ways into the library that nobody had to file anything under.
  Future<
      ({
        List<({String id, String name, String blurb, int count})> lists,
        List<({String id, String name, String short, String blurb, int count})> decades,
      })> smartShelves() async {
    final d = await _decode(await net.get(_u('/library/smart'), headers: _headers))
        as Map<String, dynamic>;
    return (
      lists: [
        for (final l in (d['lists'] ?? const []) as List)
          (
            id: '${l['id']}',
            name: (l['name'] ?? '') as String,
            blurb: (l['blurb'] ?? '') as String,
            count: (l['count'] ?? 0) as int,
          )
      ],
      decades: [
        for (final l in (d['decades'] ?? const []) as List)
          (
            id: '${l['id']}',
            name: (l['name'] ?? '') as String,
            short: (l['short'] ?? '') as String,
            blurb: (l['blurb'] ?? '') as String,
            count: (l['count'] ?? 0) as int,
          )
      ],
    );
  }

  /// One of them, answered now.
  Future<List<Track>> smartList(String id) async {
    final d = await _decode(await net.get(_u('/library/smart/$id'), headers: _headers))
        as Map<String, dynamic>;
    return [for (final t in (d['items'] ?? const []) as List) Track.fromJson(t)];
  }

  /// What one account listened to, over one stretch of time.
  ///
  /// Or, with [everyone], what the whole house did: every account added together.
  Future<Listening> listening(
      {String since = 'month', int? who, bool everyone = false}) async {
    final d = await _decode(await net.get(
        _u('/library/stats', {
          'since': since,
          if (everyone) 'everyone': 'true' else if (who != null) 'who': who,
        }),
        headers: _headers)) as Map<String, dynamic>;
    return Listening.fromJson(d);
  }

  // ---------------- the devices this account listens on ----------------
  Future<({List<DeviceInfo> devices, int? thisOne})> devices() async {
    final d = await _decode(await net.get(_u('/devices'), headers: _headers))
        as Map<String, dynamic>;
    return (
      devices: (d['devices'] as List)
          .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      thisOne: d['this'] as int?,
    );
  }

  /// This device, saying what it is doing. Everything any other screen shows about it
  /// comes from here, so it is the only thing that writes it.
  Future<void> reportDevice({
    required bool playing,
    int? trackId,
    int? queueId,
    int? itemId,
    int positionMs = 0,
    String? kind,
  }) async =>
      await _decode(await net.post(_u('/devices/state'),
          headers: _headers,
          body: jsonEncode({
            'playing': playing,
            'track_id': trackId,
            'queue_id': queueId,
            if (itemId != null) 'item_id': itemId,
            'position_ms': positionMs,
            if (kind != null) 'kind': kind,
          })));

  Future<void> deviceCommand(int deviceId, String action,
          {int? queueId, int? trackId, int? positionMs}) async =>
      await _decode(await net.post(_u('/devices/$deviceId/command'),
          headers: _headers,
          body: jsonEncode({
            'action': action,
            if (queueId != null) 'queue_id': queueId,
            if (trackId != null) 'track_id': trackId,
            if (positionMs != null) 'position_ms': positionMs,
          })));

  /// Gone from the list, and signed out.
  Future<void> forgetDevice(int deviceId) async =>
      await _decode(await net.delete(_u('/devices/$deviceId'), headers: _headers));

  Future<void> renameDevice(int deviceId, String name) async =>
      await _decode(await net.patch(_u('/devices/$deviceId'),
          headers: _headers, body: jsonEncode({'name': name})));

  /// Get the audio for songs that have none yet: a record, an artist, or a handful of
  /// rows picked out of a list.
  Future<({int queued, int unfetchable, int alreadyHere, int aboutMb})> fetchAudio({
    List<int>? trackIds,
    String? album,
    String? artist,
  }) async {
    final d = await _decode(await net.post(_u('/library/fetch'),
        headers: _headers,
        body: jsonEncode({
          if (trackIds != null) 'track_ids': trackIds,
          if (album != null) 'album': album,
          if (artist != null) 'artist': artist,
        }))) as Map<String, dynamic>;
    return (
      queued: (d['queued'] ?? 0) as int,
      unfetchable: (d['unfetchable'] ?? 0) as int,
      alreadyHere: (d['already_here'] ?? 0) as int,
      aboutMb: (d['about_mb'] ?? 0) as int,
    );
  }

  /// A playlist as a file something else can read. A URL rather than bytes: the
  /// browser should save it the way it saves anything else.
  String playlistExportUrl(int playlistId, {String format = 'm3u'}) {
    final key = _streamKey;
    final auth = key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}';
    return '$baseUrl/playlists/$playlistId/export?format=$format$auth';
  }

  Future<List<PlayedTrack>> playHistory() async {
    final d = await _decode(await net.get(_u('/library/history'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => PlayedTrack.fromJson(e)).toList();
  }

  Future<void> clearHistory() async {
    await _decode(await net.delete(_u('/library/history'), headers: _headers));
  }

  /// Keep what the booth did between this playlist's songs on it — or take it off.
  Future<Playlist> setPlaylistMix(int id, Map<String, dynamic>? mix) async =>
      Playlist.fromJson(await _decode(await net.patch(_u('/playlists/$id'),
              headers: _headers, body: jsonEncode({'mix': mix})))
          as Map<String, dynamic>);

  Future<Playlist> renamePlaylist(int id, String name) async =>
      Playlist.fromJson(await _decode(await net.patch(_u('/playlists/$id'),
              headers: _headers, body: jsonEncode({'name': name})))
          as Map<String, dynamic>);

  Future<Playlist> movePlaylistItem(int id, int from, int to) async =>
      Playlist.fromJson(await _decode(await net.post(_u('/playlists/$id/move'),
              headers: _headers, body: jsonEncode({'from': from, 'to': to})))
          as Map<String, dynamic>);

  /// The song's loudness a slice at a time, 0 to 255, for drawing the seek bar as its
  /// shape. Null for a song whose audio is not here yet: its shape is not known.
  Future<List<int>?> peaks(int trackId, {int? slices}) async {
    try {
      final d = await _decode(await net.get(
              _u('/tracks/$trackId/peaks${slices == null ? '' : '?slices=$slices'}'),
              headers: _headers))
          as Map<String, dynamic>;
      return [for (final v in (d['peaks'] as List)) (v as num).toInt()];
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// The same shape in three bands — bass, middle, top — each 0 to 255, for a deck's
  /// waveform, where "the bass drops out here" is the thing worth seeing.
  Future<({List<int> low, List<int> mid, List<int> high})?> peakBands(int trackId,
      {int slices = 1600}) async {
    try {
      final d = await _decode(await net.get(
              _u('/tracks/$trackId/peaks?slices=$slices&bands=true'),
              headers: _headers))
          as Map<String, dynamic>;
      final b = (d['bands'] as Map).cast<String, dynamic>();
      List<int> ints(String k) => [for (final v in (b[k] as List)) (v as num).toInt()];
      return (low: ints('low'), mid: ints('mid'), high: ints('high'));
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<({String? synced, String? plain, String? source})> lyrics(int trackId) async {
    final d = await _decode(
            await net.get(_u('/tracks/$trackId/lyrics'), headers: _headers))
        as Map<String, dynamic>;
    return (
      synced: d['synced'] as String?,
      plain: d['plain'] as String?,
      source: d['source'] as String?,
    );
  }

  /// Out of the library, its playlists and its queues — and off the server, audio and
  /// all, when nobody else holds the song. `deleted` says how many went that far.
  Future<({int removed, int deleted})> removeFromLibrary(List<int> trackIds) async {
    final j = await _decode(await net.post(_u('/library/remove'),
        headers: _headers,
        body: jsonEncode({'track_ids': trackIds}))) as Map<String, dynamic>;
    return (
      removed: (j['removed'] as num?)?.toInt() ?? 0,
      deleted: (j['deleted'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Track> updateTrack(int id, Map<String, dynamic> fields) async =>
      Track.fromJson(await _decode(await net.patch(_u('/tracks/$id'),
              headers: _headers, body: jsonEncode(fields))) as Map<String, dynamic>);

  Future<Map<String, dynamic>> storage() async =>
      await _decode(await net.get(_u('/admin/storage'), headers: _headers))
          as Map<String, dynamic>;

  /// Upload a file from the device. Bytes rather than a path, because the web build
  /// never has a path to give.
  Future<Track> upload(List<int> bytes, String filename) async {
    final request = http.MultipartRequest('POST', _u('/uploads'))
      ..headers.addAll({if (token != null) 'Authorization': 'Bearer $token'})
      ..files.add(http.MultipartFile.fromBytes('audio', bytes, filename: filename));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    return Track.fromJson(await _decode(response) as Map<String, dynamic>);
  }

  // ---------------- Spotify ----------------
  Future<Map<String, dynamic>> spotifyAccount() async =>
      await _decode(await net.get(_u('/spotify/account'), headers: _headers))
          as Map<String, dynamic>;

  Future<String> spotifyAuthorizeUrl() async {
    final d = await _decode(await net.get(_u('/spotify/authorize'), headers: _headers))
        as Map<String, dynamic>;
    return d['url'] as String;
  }

  Future<void> unlinkSpotify() async {
    await _decode(await net.delete(_u('/spotify/account'), headers: _headers));
  }

  /// What is on the Spotify side, each marked with whether it is already mirrored.
  Future<List<SpotifyPlaylist>> spotifyPlaylists() async {
    final d = await _decode(
            await net.get(_u('/spotify/playlists'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => SpotifyPlaylist.fromJson(e)).toList();
  }

  /// Mirror the named playlists, or — with no names — refresh the ones already
  /// mirrored. Never everything: an account can hold hundreds.
  Future<List<Map<String, dynamic>>> syncSpotify({String? remoteId}) async {
    final d = await _decode(await net.post(_u('/spotify/sync'),
        headers: _headers,
        body: jsonEncode({if (remoteId != null) 'remote_id': remoteId})))
        as Map<String, dynamic>;
    return (d['playlists'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<UnmatchedTrack>> unmatched(int playlistId) async {
    final d = await _decode(await net.get(
        _u('/spotify/playlists/$playlistId/unmatched'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => UnmatchedTrack.fromJson(e)).toList();
  }

  Future<List<RemoteHit>> unmatchedSuggestions(int playlistId, int pos) async {
    final d = await _decode(await net.get(
        _u('/spotify/playlists/$playlistId/suggestions', {'pos': pos}),
        headers: _headers)) as Map<String, dynamic>;
    return (d['items'] as List).map((e) => RemoteHit.fromJson(e)).toList();
  }

  Future<void> resolveUnmatched(int playlistId, int pos, {String? videoId}) async {
    await _decode(await net.post(
        _u('/spotify/playlists/$playlistId/unmatched/$pos/resolve'),
        headers: _headers,
        body: jsonEncode({'video_id': videoId})));
  }

  Future<Playlist> clonePlaylist(int playlistId, {String? name}) async =>
      Playlist.fromJson(await _decode(await net.post(
              _u('/spotify/playlists/$playlistId/clone'),
              headers: _headers,
              body: jsonEncode({if (name != null) 'name': name})))
          as Map<String, dynamic>);

  Future<List<Track>> history() async {
    final d = await _decode(await net.get(_u('/history'), headers: _headers)) as List;
    return d.map((e) => Track.fromJson(e)).toList();
  }

  /// One play, and the score it leaves behind.
  ///
  /// Answers with how many records have now been heard all the way through, so the
  /// number can move at the moment a record ends rather than the next time the app is
  /// opened.
  Future<int> recordListen(int trackId, int msPlayed, bool completed) async {
    final d = await _decode(await net.post(_u('/listens'),
        headers: _headers,
        body: jsonEncode({
          'track_id': trackId,
          'ms_played': msPlayed,
          'completed': completed
        }))) as Map<String, dynamic>;
    return (d['score'] ?? 0) as int;
  }

  /// Server-sent events: a track finishing its download un-greys it everywhere.
  Stream<({String event, Map<String, dynamic> data})> events() async* {
    final req = http.Request('GET', _u('/events'))..headers.addAll(_headers);
    // Through the app's own client rather than `req.send()`, which opens a client of
    // its own: this is the longest-lived request the app makes, and it is the one
    // whose failure says soonest that the box has gone away.
    final res = await net.send(req);
    String? current;
    await for (final line
        in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('event: ')) {
        current = line.substring(7).trim();
      } else if (line.startsWith('data: ') && current != null) {
        final payload = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        yield (event: current, data: payload);
      }
    }
  }
}

class QueueConflict implements Exception {
  final Queue current;
  QueueConflict(this.current);
}

/// Which kind of thing this is running on, for the server's device list and for the
/// playback reports.
String platformName() => _platformName();

String _platformName() {
  // Avoids dart:io so the same code compiles for web.
  return const bool.fromEnvironment('dart.library.html') ? 'web' : 'app';
}
