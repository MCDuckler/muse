import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'models.dart';

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
    final r = await http.post(_u('/auth/login'), body: {
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
    final d = await _decode(await http.get(_u('/auth/stream-key'), headers: _headers))
        as Map<String, dynamic>;
    _streamKey = d['key'] as String;
    _streamKeyExpiry = d['expires_at'] as int;
  }

  /// Turn an invite into an account and sign in with it. The only route that creates
  /// a user without already being signed in.
  Future<String> redeemInvite(String code, String user, String password,
      String device) async {
    final r = await http.post(_u('/auth/redeem'), body: {
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
    await _decode(await http.post(_u('/auth/password'),
        headers: _headers, body: jsonEncode({'password': password})));
  }

  Future<({List<Map<String, dynamic>> items, int you})> accounts() async {
    final d = await _decode(await http.get(_u('/accounts'), headers: _headers))
        as Map<String, dynamic>;
    return (
      items: (d['items'] as List).cast<Map<String, dynamic>>(),
      you: (d['you'] ?? 0) as int,
    );
  }

  Future<Map<String, dynamic>> createAccount(String name, String password) async =>
      await _decode(await http.post(_u('/accounts'),
              headers: _headers,
              body: jsonEncode({'name': name, 'password': password})))
          as Map<String, dynamic>;

  Future<void> resetPassword(int id, String password,
      {bool signOutDevices = false}) async {
    await _decode(await http.post(_u('/accounts/$id/password'),
        headers: _headers,
        body: jsonEncode({
          'password': password,
          'sign_out_devices': signOutDevices,
        })));
  }

  Future<void> deleteAccount(int id) async {
    await _decode(await http.delete(_u('/accounts/$id'), headers: _headers));
  }

  Future<Map<String, dynamic>> createInvite({String? note}) async =>
      await _decode(await http.post(_u('/accounts/invites'),
              headers: _headers,
              body: jsonEncode({if (note != null) 'note': note})))
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> me() async =>
      await _decode(await http.get(_u('/me'), headers: _headers)) as Map<String, dynamic>;

  /// Local catalog first, then YouTube Music. Remote hits are flagged `known` when
  /// the library already has them, so the UI never offers to fetch a track twice.
  Future<({List<Track> local, List<RemoteHit> remote})> search(String q) async {
    final d = await _decode(await http.get(_u('/search', {'q': q}), headers: _headers))
        as Map<String, dynamic>;
    return (
      local: ((d['local'] ?? []) as List).map((e) => Track.fromJson(e)).toList(),
      remote: ((d['remote'] ?? []) as List).map((e) => RemoteHit.fromJson(e)).toList(),
    );
  }

  /// 200 when the server already had it, 202 when it just queued a download.
  Future<Track> resolve({String? videoId, String? query}) async {
    final r = await http.post(_u('/tracks/resolve'),
        headers: _headers,
        body: jsonEncode({if (videoId != null) 'video_id': videoId, if (query != null) 'query': query}));
    return Track.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<Track> track(int id) async =>
      Track.fromJson(await _decode(await http.get(_u('/tracks/$id'), headers: _headers))
          as Map<String, dynamic>);

  String streamUrl(Track t) {
    final key = _streamKey;
    return key == null
        ? '$baseUrl${t.streamPath}'
        : '$baseUrl${t.streamPath}?k=${Uri.encodeQueryComponent(key)}';
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
  String? sleeveUrl(Track t, {bool small = false, String part = 'sleeve'}) {
    final flat = coverUrl(t, small: small);
    return flat == null ? null : '$flat&style=$part';
  }

  String? jacketUrl(Track t, {bool small = false}) =>
      sleeveUrl(t, small: small, part: 'jacket');

  String? discUrl(Track t, {bool small = false}) =>
      sleeveUrl(t, small: small, part: 'disc');

  /// Take the whole thing: queue the audio for everything in a playlist that has none.
  Future<int> downloadPlaylist(int playlistId) async {
    final d = await _decode(await http.post(_u('/playlists/$playlistId/download'),
        headers: _headers)) as Map<String, dynamic>;
    return (d['queued'] ?? 0) as int;
  }

  /// A playlist's own art. Immutable per version, so it caches forever and still
  /// changes the moment the playlist does.
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
      await _decode(await http.get(_u('/downloads'), headers: _headers))
          as Map<String, dynamic>);

  Future<bool> pauseDownloads(bool paused) async {
    final d = await _decode(await http.post(_u('/downloads/pause'),
        headers: _headers, body: jsonEncode({'paused': paused})))
        as Map<String, dynamic>;
    return (d['paused'] ?? false) as bool;
  }

  Future<int> retryFailedDownloads({String? batchId, String? failCode}) async {
    final d = await _decode(await http.post(_u('/downloads/retry-failed'),
        headers: _headers,
        body: jsonEncode({
          if (batchId != null) 'batch_id': batchId,
          if (failCode != null) 'fail_code': failCode,
        })))
        as Map<String, dynamic>;
    return (d['retrying'] ?? 0) as int;
  }

  Future<int> cancelDownloads({String? batchId, int? trackId, bool all = false}) async {
    final d = await _decode(await http.post(_u('/downloads/cancel'),
        headers: _headers,
        body: jsonEncode({
          if (batchId != null) 'batch_id': batchId,
          if (trackId != null) 'track_id': trackId,
          if (all) 'all': true,
        }))) as Map<String, dynamic>;
    return (d['cancelled'] ?? 0) as int;
  }

  Future<void> promoteDownload(int trackId) => promoteDownloads([trackId]);

  /// Tracks in playing order: the one under the needle, then what follows it.
  Future<void> promoteDownloads(List<int> trackIds) async {
    if (trackIds.isEmpty) return;
    await _decode(await http.post(_u('/downloads/promote'),
        headers: _headers, body: jsonEncode({'track_ids': trackIds})));
  }

  /// Pull the start of a track through the cache so it is there when it is wanted.
  ///
  /// A range request rather than the whole file: enough that playback starts on what
  /// is already local, cheap enough to do on every track change. The browser and the
  /// native HTTP cache both keep it; failures are silent because this is a nicety.
  Future<void> warmStream(Track t) async {
    try {
      await http.get(Uri.parse(streamUrl(t)),
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
    final d = await _decode(await http.get(
        _u('/sources/search?source=$source&limit=$limit'
            '&q=${Uri.encodeQueryComponent(query)}'),
        headers: _headers)) as Map<String, dynamic>;
    return ((d['items'] ?? const []) as List)
        .map((e) => SourceHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Track> addFromSource(SourceHit hit) async => Track.fromJson(await _decode(
      await http.post(_u('/sources/resolve'),
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
      await _decode(await http.get(
          _u('/sources/preview?url=${Uri.encodeQueryComponent(url)}'),
          headers: _headers)) as Map<String, dynamic>);

  Future<Map<String, dynamic>> importAlbum(String url) async =>
      await _decode(await http.post(_u('/sources/import'),
          headers: _headers, body: jsonEncode({'url': url}))) as Map<String, dynamic>;

  // ---------------- jam ----------------
  Future<Jam> startJam(int queueId) async => Jam.fromJson(await _decode(
      await http.post(_u('/jams'),
          headers: _headers, body: jsonEncode({'queue_id': queueId}))) as Map<String, dynamic>);

  Future<Jam> joinJam(String code) async => Jam.fromJson(await _decode(
      await http.post(_u('/jams/join'),
          headers: _headers, body: jsonEncode({'code': code}))) as Map<String, dynamic>);

  /// The jam you are in, and a heartbeat that keeps you listed as here.
  Future<Jam?> currentJam() async {
    final d = await _decode(await http.get(_u('/jams/current'), headers: _headers))
        as Map<String, dynamic>;
    return d['jam'] == null ? null : Jam.fromJson(d['jam'] as Map<String, dynamic>);
  }

  Future<Jam> setJamRules(int jamId, {bool? guestsCanAdd, bool? guestsCanSkip}) async =>
      Jam.fromJson(await _decode(await http.patch(_u('/jams/$jamId'),
          headers: _headers,
          body: jsonEncode({
            if (guestsCanAdd != null) 'guests_can_add': guestsCanAdd,
            if (guestsCanSkip != null) 'guests_can_skip': guestsCanSkip,
          }))) as Map<String, dynamic>);

  Future<void> leaveJam(int jamId) async =>
      await _decode(await http.post(_u('/jams/$jamId/leave'), headers: _headers));

  Future<void> removeFromJam(int jamId, int userId) async =>
      await _decode(await http.post(_u('/jams/$jamId/remove'),
          headers: _headers, body: jsonEncode({'user_id': userId})));

  /// Ask for the current track to be dropped. Returns how many have asked.
  Future<Map<String, dynamic>> voteSkip(int jamId) async =>
      await _decode(await http.post(_u('/jams/$jamId/skip-vote'),
          headers: _headers, body: jsonEncode({}))) as Map<String, dynamic>;

  Future<Map<String, dynamic>> status() async =>
      await _decode(await http.get(_u('/status'), headers: _headers))
          as Map<String, dynamic>;

  Map<String, String> get streamHeaders => {'Authorization': 'Bearer $token'};

  bool get hasStreamKey => _streamKey != null;

  // ---------------- queues ----------------
  Future<List<Queue>> queues() async {
    final d = await _decode(await http.get(_u('/queues'), headers: _headers)) as List;
    return d.map((e) => Queue.fromJson(e)).toList();
  }

  Future<Queue> queue(int id) async =>
      Queue.fromJson(await _decode(await http.get(_u('/queues/$id'), headers: _headers))
          as Map<String, dynamic>);

  Future<Queue> createQueue(String name) async => Queue.fromJson(await _decode(
      await http.post(_u('/queues'), headers: _headers, body: jsonEncode({'name': name})))
      as Map<String, dynamic>);

  /// Order is versioned. A 409 means someone else reordered it; the caller gets the
  /// live state back so it can merge instead of overwriting.
  Future<Queue> replaceQueue(int id, int rev, List<int> trackIds) async {
    final r = await http.put(_u('/queues/$id'),
        headers: _headers, body: jsonEncode({'rev': rev, 'items': trackIds}));
    if (r.statusCode == 409) {
      final d = jsonDecode(r.body)['detail'] as Map<String, dynamic>;
      throw QueueConflict(Queue.fromJson(d['current'] as Map<String, dynamic>));
    }
    return Queue.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<Queue> addToQueue(int id, List<int> trackIds, {String mode = 'end'}) async =>
      Queue.fromJson(await _decode(await http.post(_u('/queues/$id/items'),
              headers: _headers, body: jsonEncode({'track_ids': trackIds, 'mode': mode})))
          as Map<String, dynamic>);

  /// The cursor is not versioned: the device that is playing is the authority.
  Future<void> setCursor(int id, {int? index, int? positionMs}) async {
    await _decode(await http.patch(_u('/queues/$id/cursor'),
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
    final r = await http.patch(_u('/queues/$id'),
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
              await http.delete(_u('/queues/$id/items/$pos'), headers: _headers))
          as Map<String, dynamic>);

  Future<Queue> moveQueueItem(int id, int from, int to) async =>
      Queue.fromJson(await _decode(await http.post(_u('/queues/$id/move'),
              headers: _headers, body: jsonEncode({'from': from, 'to': to})))
          as Map<String, dynamic>);

  /// `origin: 'radio'` clears only the machine-picked tail.
  Future<Queue> clearQueue(int id, {String? origin}) async =>
      Queue.fromJson(await _decode(await http.post(_u('/queues/$id/clear'),
              headers: _headers,
              body: jsonEncode({if (origin != null) 'origin': origin})))
          as Map<String, dynamic>);

  Future<void> deleteQueue(int id) async {
    await _decode(await http.delete(_u('/queues/$id'), headers: _headers));
  }

  Future<Queue> radio(int queueId, int seedTrackId, {int count = 5}) async =>
      Queue.fromJson(await _decode(await http.post(_u('/queues/$queueId/radio'),
              headers: _headers,
              body: jsonEncode({'seed_track_id': seedTrackId, 'count': count})))
          as Map<String, dynamic>);

  // ---------------- library ----------------
  Future<List<Playlist>> playlists() async {
    final d = await _decode(await http.get(_u('/playlists'), headers: _headers)) as List;
    return d.map((e) => Playlist.fromJson(e)).toList();
  }

  Future<Playlist> playlist(int id) async =>
      Playlist.fromJson(await _decode(await http.get(_u('/playlists/$id'), headers: _headers))
          as Map<String, dynamic>);

  Future<Playlist> createPlaylist(String name) async =>
      Playlist.fromJson(await _decode(await http.post(_u('/playlists'),
              headers: _headers, body: jsonEncode({'name': name})))
          as Map<String, dynamic>);

  Future<Playlist> addToPlaylist(int id, List<int> trackIds) async =>
      Playlist.fromJson(await _decode(await http.post(_u('/playlists/$id/items'),
              headers: _headers, body: jsonEncode({'track_ids': trackIds})))
          as Map<String, dynamic>);

  Future<Playlist> removePlaylistItem(int id, int pos) async =>
      Playlist.fromJson(await _decode(
              await http.delete(_u('/playlists/$id/items/$pos'), headers: _headers))
          as Map<String, dynamic>);

  Future<void> deletePlaylist(int id) async {
    await _decode(await http.delete(_u('/playlists/$id'), headers: _headers));
  }

  Future<Playlist> saveQueueAsPlaylist(int queueId, {String? name}) async =>
      Playlist.fromJson(await _decode(await http.post(
              _u('/queues/$queueId/save-as-playlist'),
              headers: _headers,
              body: jsonEncode({if (name != null) 'name': name})))
          as Map<String, dynamic>);

  // ---------------- browsing ----------------
  Future<({List<Track> items, int total})> libraryTracks(
      {String sort = 'added', int limit = 200, int offset = 0}) async {
    final d = await _decode(await http.get(
        _u('/library/tracks', {'sort': sort, 'limit': limit, 'offset': offset}),
        headers: _headers)) as Map<String, dynamic>;
    return (
      items: (d['items'] as List).map((e) => Track.fromJson(e)).toList(),
      total: (d['total'] ?? 0) as int,
    );
  }

  Future<List<AlbumSummary>> albums() async {
    final d = await _decode(await http.get(_u('/library/albums'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => AlbumSummary.fromJson(e)).toList();
  }

  Future<List<Track>> albumTracks(String album, {String? artist}) async {
    final d = await _decode(await http.get(
        _u('/library/albums/tracks',
            {'album': album, if (artist != null) 'artist': artist}),
        headers: _headers)) as Map<String, dynamic>;
    return (d['items'] as List).map((e) => Track.fromJson(e)).toList();
  }

  Future<List<ArtistSummary>> artists() async {
    final d = await _decode(await http.get(_u('/library/artists'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => ArtistSummary.fromJson(e)).toList();
  }

  Future<List<Track>> artistTracks(String artist) async {
    final d = await _decode(await http.get(
        _u('/library/artists/tracks', {'artist': artist}), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => Track.fromJson(e)).toList();
  }

  Future<List<PlayedTrack>> playHistory() async {
    final d = await _decode(await http.get(_u('/library/history'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => PlayedTrack.fromJson(e)).toList();
  }

  Future<void> clearHistory() async {
    await _decode(await http.delete(_u('/library/history'), headers: _headers));
  }

  Future<Playlist> renamePlaylist(int id, String name) async =>
      Playlist.fromJson(await _decode(await http.patch(_u('/playlists/$id'),
              headers: _headers, body: jsonEncode({'name': name})))
          as Map<String, dynamic>);

  Future<Playlist> movePlaylistItem(int id, int from, int to) async =>
      Playlist.fromJson(await _decode(await http.post(_u('/playlists/$id/move'),
              headers: _headers, body: jsonEncode({'from': from, 'to': to})))
          as Map<String, dynamic>);

  Future<({String? synced, String? plain, String? source})> lyrics(int trackId) async {
    final d = await _decode(
            await http.get(_u('/tracks/$trackId/lyrics'), headers: _headers))
        as Map<String, dynamic>;
    return (
      synced: d['synced'] as String?,
      plain: d['plain'] as String?,
      source: d['source'] as String?,
    );
  }

  Future<Track> updateTrack(int id, Map<String, dynamic> fields) async =>
      Track.fromJson(await _decode(await http.patch(_u('/tracks/$id'),
              headers: _headers, body: jsonEncode(fields))) as Map<String, dynamic>);

  Future<Map<String, dynamic>> storage() async =>
      await _decode(await http.get(_u('/admin/storage'), headers: _headers))
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
      await _decode(await http.get(_u('/spotify/account'), headers: _headers))
          as Map<String, dynamic>;

  Future<String> spotifyAuthorizeUrl() async {
    final d = await _decode(await http.get(_u('/spotify/authorize'), headers: _headers))
        as Map<String, dynamic>;
    return d['url'] as String;
  }

  Future<void> unlinkSpotify() async {
    await _decode(await http.delete(_u('/spotify/account'), headers: _headers));
  }

  /// What is on the Spotify side, each marked with whether it is already mirrored.
  Future<List<SpotifyPlaylist>> spotifyPlaylists() async {
    final d = await _decode(
            await http.get(_u('/spotify/playlists'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => SpotifyPlaylist.fromJson(e)).toList();
  }

  /// Mirror the named playlists, or — with no names — refresh the ones already
  /// mirrored. Never everything: an account can hold hundreds.
  Future<List<Map<String, dynamic>>> syncSpotify({String? remoteId}) async {
    final d = await _decode(await http.post(_u('/spotify/sync'),
        headers: _headers,
        body: jsonEncode({if (remoteId != null) 'remote_id': remoteId})))
        as Map<String, dynamic>;
    return (d['playlists'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<UnmatchedTrack>> unmatched(int playlistId) async {
    final d = await _decode(await http.get(
        _u('/spotify/playlists/$playlistId/unmatched'), headers: _headers))
        as Map<String, dynamic>;
    return (d['items'] as List).map((e) => UnmatchedTrack.fromJson(e)).toList();
  }

  Future<List<RemoteHit>> unmatchedSuggestions(int playlistId, int pos) async {
    final d = await _decode(await http.get(
        _u('/spotify/playlists/$playlistId/suggestions', {'pos': pos}),
        headers: _headers)) as Map<String, dynamic>;
    return (d['items'] as List).map((e) => RemoteHit.fromJson(e)).toList();
  }

  Future<void> resolveUnmatched(int playlistId, int pos, {String? videoId}) async {
    await _decode(await http.post(
        _u('/spotify/playlists/$playlistId/unmatched/$pos/resolve'),
        headers: _headers,
        body: jsonEncode({'video_id': videoId})));
  }

  Future<Playlist> clonePlaylist(int playlistId, {String? name}) async =>
      Playlist.fromJson(await _decode(await http.post(
              _u('/spotify/playlists/$playlistId/clone'),
              headers: _headers,
              body: jsonEncode({if (name != null) 'name': name})))
          as Map<String, dynamic>);

  Future<List<Track>> history() async {
    final d = await _decode(await http.get(_u('/history'), headers: _headers)) as List;
    return d.map((e) => Track.fromJson(e)).toList();
  }

  Future<void> recordListen(int trackId, int msPlayed, bool completed) async {
    await _decode(await http.post(_u('/listens'),
        headers: _headers,
        body: jsonEncode(
            {'track_id': trackId, 'ms_played': msPlayed, 'completed': completed})));
  }

  /// Server-sent events: a track finishing its download un-greys it everywhere.
  Stream<({String event, Map<String, dynamic> data})> events() async* {
    final req = http.Request('GET', _u('/events'))..headers.addAll(_headers);
    final res = await req.send();
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

String _platformName() {
  // Avoids dart:io so the same code compiles for web.
  return const bool.fromEnvironment('dart.library.html') ? 'web' : 'app';
}
