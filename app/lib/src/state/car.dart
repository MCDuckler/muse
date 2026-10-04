import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../api/models.dart';
import 'app_state.dart';
import 'library_arrangement.dart';
import 'library_query.dart';
import 'player.dart';

/// The library as a car sees it.
///
/// Android Auto browses the media session: a tree of things to play, a search box, and
/// the buttons of the playback screen. The tree here is the library read the way the
/// Library tab reads it — what was opened lately and the heart on the first page, then
/// the box with its dividers, the records as a wall of covers, the artists — with every
/// playlist one tap from playing, because a car is no place to open a list and pick.
///
/// Ids are `kind:what`, so a tap in the car names the thing and this plays it. The
/// heart on the playback screen is the heart on the song: the same favourite the rows
/// in the app toggle, drawn filled or hollow for the song playing now.
class CarBrowser implements MediaSessionHooks {
  CarBrowser(this.app) {
    app.addListener(_changed);
  }

  final AppState app;

  /// The names the tree is browsed by. The root is what audio_service calls it.
  static const root = 'root';
  static const home = 'home';
  static const playlists = 'playlists';
  static const records = 'records';
  static const artists = 'artists';
  static const queueNode = 'queue';
  static const favourites = 'favourites';

  /// What the heart button is called when it is pressed.
  static const heartAction = 'heart';
  static const shuffleAction = 'shuffle';

  /// Android's content style hints: how a node's children are drawn.
  static const _styleSupported = 'android.media.browse.CONTENT_STYLE_SUPPORTED';
  static const _browsableHint = 'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const _playableHint = 'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const _groupTitle = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
  static const _list = 1;
  static const _grid = 2;

  /// What the root is told, so the car knows the hints are meant.
  static const rootExtras = <String, dynamic>{
    _styleSupported: true,
    _browsableHint: _list,
    _playableHint: _list,
  };

  /// Put one of these in charge of the session. Once, from main, after the app state
  /// exists; harmless where there is no session to be in charge of.
  static CarBrowser? install(AppState app) {
    if (kIsWeb) return null;
    final browser = CarBrowser(app);
    JustAudioBackground.hooks = browser;
    return browser;
  }

  // ---------------------------------------------------------------- the tree

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId) async {
    final id = parentMediaId;
    if (id == root || id == 'media_root_id' || id == '/') return _root();
    if (id == home) return _home();
    if (id == playlists) return _playlists();
    if (id == records) return _records();
    if (id == artists) return _artists();
    if (id == queueNode) return _queue();
    final sep = id.indexOf(':');
    if (sep < 0) return const [];
    final kind = id.substring(0, sep), what = id.substring(sep + 1);
    switch (kind) {
      case 'folder':
        final f = int.tryParse(what);
        final arranged = LibraryArrangement(app.playlists, app.folders);
        final shelf = arranged.shelves.where((s) => s.folder.id == f).firstOrNull;
        return [for (final p in shelf?.playlists ?? const <Playlist>[]) _playlistItem(p)];
      case 'playlist':
        final p = int.tryParse(what);
        if (p == null) return const [];
        return [for (final t in (await app.api.playlist(p)).items) _trackItem(t)];
      case 'artist':
        return _artist(what);
      case 'album':
        final (name, artist) = _album(what);
        return [for (final t in await app.api.albumTracks(name, artist: artist)) _trackItem(t)];
    }
    return const [];
  }

  List<MediaItem> _root() => const [
        MediaItem(id: home, title: 'Home', playable: false,
            extras: {_browsableHint: _list, _playableHint: _list}),
        MediaItem(id: playlists, title: 'Playlists', playable: false,
            extras: {_browsableHint: _list, _playableHint: _list}),
        MediaItem(id: records, title: 'Records', playable: false,
            extras: {_browsableHint: _grid, _playableHint: _grid}),
        MediaItem(id: artists, title: 'Artists', playable: false,
            extras: {_browsableHint: _list, _playableHint: _grid}),
      ];

  /// The first page: what is on now, what was opened lately, the heart, and the lists
  /// that fill themselves in.
  Future<List<MediaItem>> _home() async {
    final q = LibraryQuery(playlists: app.playlists, folders: app.folders);
    final out = <MediaItem>[];
    if (app.activeQueue != null && (app.player?.current) != null) {
      out.add(MediaItem(
        id: queueNode,
        title: app.activeQueue!.name,
        displaySubtitle: 'What is playing, and what is next',
        playable: false,
        extras: const {_groupTitle: 'On now', _browsableHint: _list},
      ));
    }
    for (final p in q.recent.take(8)) {
      out.add(_playlistItem(p, group: 'Opened lately'));
    }
    final hearts = app.playlists.where((p) => p.isFavourites).firstOrNull;
    if (hearts != null && hearts.itemCount > 0) {
      out.add(MediaItem(
        id: favourites,
        title: 'Favourites',
        displaySubtitle: '${hearts.itemCount} songs you hearted',
        playable: true,
        artUri: _artOf(hearts),
        extras: const {_groupTitle: 'Yours'},
      ));
    }
    for (final p in q.pinned) {
      out.add(_playlistItem(p, group: 'Yours'));
    }
    try {
      for (final l in await app.api.smartLists()) {
        if (l.count == 0) continue;
        out.add(MediaItem(
          id: 'smart:${l.id}',
          title: l.name,
          displaySubtitle: '${l.count} songs · ${l.blurb}',
          playable: true,
          extras: const {_groupTitle: 'Lists that fill themselves in'},
        ));
      }
    } catch (_) {
      // A server from before these: the page is shorter.
    }
    return out;
  }

  /// The box: pinned, the dividers, the rest — every list one tap from playing.
  Future<List<MediaItem>> _playlists() async {
    final q = LibraryQuery(playlists: app.playlists, folders: app.folders,
        sort: LibrarySort.recent);
    return [
      for (final p in q.pinned) _playlistItem(p, group: q.flat ? null : 'Pinned'),
      for (final s in q.shelves)
        MediaItem(
          id: 'folder:${s.folder.id}',
          title: s.folder.name,
          displaySubtitle:
              '${s.playlists.length} ${s.playlists.length == 1 ? 'playlist' : 'playlists'}',
          playable: false,
          artUri: s.playlists.isEmpty ? null : _artOf(s.playlists.first),
          extras: const {_groupTitle: 'Folders', _browsableHint: _list},
        ),
      for (final p in q.loose)
        _playlistItem(p, group: q.flat ? null : 'Everything else'),
    ];
  }

  Future<List<MediaItem>> _records() async {
    final page = await app.api.albums(limit: 200, sort: 'added');
    return [for (final a in page.items) _albumItem(a)];
  }

  Future<List<MediaItem>> _artists() async {
    final page = await app.api.artists(limit: 200);
    return [
      for (final a in page.items)
        MediaItem(
          id: 'artist:${a.name}',
          title: a.name,
          displaySubtitle: '${a.tracks} ${a.tracks == 1 ? 'song' : 'songs'}',
          playable: false,
          artUri: _uri(app.api.coverUrlForPath(a.coverPath, small: false)),
          extras: const {_browsableHint: _list, _playableHint: _grid},
        ),
    ];
  }

  /// One artist: everything by them to play at once, then their records.
  Future<List<MediaItem>> _artist(String name) async {
    final records = await app.api.albums(limit: 100, q: name);
    return [
      MediaItem(
        id: 'artist-all:$name',
        title: 'Everything by $name',
        playable: true,
        extras: const {_groupTitle: 'Play'},
      ),
      for (final a in records.items)
        if (a.artist.toLowerCase() == name.toLowerCase()) _albumItem(a, group: 'Records'),
    ];
  }

  Future<List<MediaItem>> _queue() async {
    final p = app.player;
    if (p == null) return const [];
    return [for (final t in p.items) _trackItem(t, queueRow: true)];
  }

  // ---------------------------------------------------------------- items

  MediaItem _playlistItem(Playlist p, {String? group}) => MediaItem(
        id: 'playlist:${p.id}',
        title: p.name,
        displaySubtitle: [
          if (p.isMirror) _serviceName(p.kind),
          if (p.saved) 'from ${p.ownerName ?? 'somebody'}',
          '${p.itemCount} ${p.itemCount == 1 ? 'song' : 'songs'}',
        ].join(' · '),
        playable: true,
        artUri: _artOf(p),
        extras: group == null ? null : {_groupTitle: group},
      );

  MediaItem _albumItem(AlbumSummary a, {String? group}) => MediaItem(
        id: 'album:${a.name}\u0001${a.artist}',
        title: a.name,
        artist: a.artist,
        displaySubtitle: a.artist,
        playable: true,
        artUri: _uri(app.api.coverUrlForPath(a.coverPath, small: false)),
        extras: group == null ? null : {_groupTitle: group},
      );

  MediaItem _trackItem(Track t, {bool queueRow = false}) => MediaItem(
        id: queueRow && t.queueItemId != null ? 'row:${t.queueItemId}' : 'track:${t.id}',
        title: t.displayTitle,
        artist: t.artistLine,
        album: t.albumLine,
        duration: t.duration,
        playable: true,
        artUri: _uri(app.api.coverUrl(t, small: false)),
      );

  Uri? _artOf(Playlist p) => _uri(app.api.playlistCoverUrl(p, small: false));
  static Uri? _uri(String? url) => url == null ? null : Uri.tryParse(url);

  static (String, String?) _album(String what) {
    final at = what.indexOf('\u0001');
    if (at < 0) return (what, null);
    final artist = what.substring(at + 1);
    return (what.substring(0, at), artist.isEmpty ? null : artist);
  }

  static String _serviceName(String kind) => switch (kind) {
        'spotify' => 'Spotify',
        'youtube' || 'ytmusic' => 'YouTube Music',
        'deezer' => 'Deezer',
        'soundcloud' => 'SoundCloud',
        'bandcamp' => 'Bandcamp',
        _ => kind,
      };

  // ---------------------------------------------------------------- playing

  @override
  Future<void> playFromMediaId(String mediaId) async {
    if (mediaId == favourites) {
      final hearts = app.playlists.where((p) => p.isFavourites).firstOrNull;
      if (hearts == null) return;
      return _play((await app.api.playlist(hearts.id)).items, named: 'Favourites');
    }
    final sep = mediaId.indexOf(':');
    if (sep < 0) return;
    final kind = mediaId.substring(0, sep), what = mediaId.substring(sep + 1);
    switch (kind) {
      case 'playlist':
        final id = int.tryParse(what);
        if (id == null) return;
        final list = await app.api.playlist(id);
        return _play(list.items, named: list.name);
      case 'folder':
        final id = int.tryParse(what);
        if (id == null) return;
        final name = app.folders.where((f) => f.id == id).map((f) => f.name).firstOrNull;
        return _play(await app.api.folderTracks(id), named: name);
      case 'album':
        final (name, artist) = _album(what);
        return _play(await app.api.albumTracks(name, artist: artist), named: name);
      case 'artist':
      case 'artist-all':
        return _play(await app.api.artistTracks(what), named: what);
      case 'smart':
        return _play(await app.api.smartList(what));
      case 'track':
        final id = int.tryParse(what);
        if (id == null) return;
        return app.playTrackNow(await app.api.track(id));
      case 'row':
        // A row of the queue on show: go there rather than starting a new queue.
        final row = int.tryParse(what);
        final p = app.player;
        if (row == null || p == null) return;
        final at = p.items.indexWhere((t) => t.queueItemId == row);
        if (at >= 0) await app.playNextFromQueue(at);
    }
  }

  Future<void> _play(List<Track> tracks, {String? named}) async {
    if (tracks.isEmpty) return;
    await app.playNow(tracks, named: named);
  }

  @override
  Future<void> playFromSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      // "Play something" with no words: what was on, or the heart.
      final p = app.player;
      if (p != null && p.items.isNotEmpty) {
        if (!p.isPlaying) await app.playPause();
        return;
      }
      return playFromMediaId(favourites);
    }
    // A playlist called that first — "play my gym playlist" — then the songs.
    final list = app.playlists
        .where((p) => !p.isFavourites && p.name.toLowerCase() == q.toLowerCase())
        .firstOrNull ??
        app.playlists
            .where((p) => !p.isFavourites && p.name.toLowerCase().contains(q.toLowerCase()))
            .firstOrNull;
    if (list != null) return playFromMediaId('playlist:${list.id}');
    final found = await app.api.search(q);
    if (found.local.isNotEmpty) return _play(found.local, named: q);
  }

  @override
  Future<List<MediaItem>> search(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = <MediaItem>[
      for (final p in app.playlists)
        if (!p.isFavourites && p.name.toLowerCase().contains(q))
          _playlistItem(p, group: 'Playlists'),
    ];
    final (songs, records) = await (app.api.search(query), app.api.albums(limit: 12, q: query)).wait;
    out.addAll([for (final a in records.items) _albumItem(a, group: 'Records')]);
    out.addAll([for (final t in songs.local.take(30)) _trackItem(t)]);
    return out;
  }

  // ---------------------------------------------------------------- buttons

  /// The song playing now, as the buttons need it. Overridable where there is no
  /// engine to ask — the tests.
  @visibleForTesting
  Track? Function()? nowPlaying;
  Track? get _now => nowPlaying != null ? nowPlaying!() : app.player?.current;

  @override
  List<MediaControl> extraControls() {
    final t = _now;
    if (t == null) return const [];
    final hearted = app.isFavourite(t.id);
    return [
      MediaControl.custom(
        androidIcon: hearted ? 'drawable/ic_media_heart' : 'drawable/ic_media_heart_outline',
        label: hearted ? 'Unheart' : 'Heart',
        name: heartAction,
        extras: {'track': t.id},
      ),
      // Shuffle here is a deal of what is coming, not a mode: see
      // AppState.shuffleWhatIsComing.
      MediaControl.custom(
        androidIcon: 'drawable/ic_media_shuffle',
        label: 'Shuffle what is coming',
        name: shuffleAction,
      ),
    ];
  }

  @override
  Future<void> customAction(String name, Map<String, dynamic>? extras) async {
    switch (name) {
      case heartAction:
        final id = (extras?['track'] as num?)?.toInt() ?? _now?.id;
        if (id == null) return;
        await app.toggleFavourite(id);
        JustAudioBackground.refreshState();
      case shuffleAction:
        await app.shuffleWhatIsComing();
    }
  }

  @override
  AudioServiceRepeatMode get repeatMode => switch (app.player?.repeat) {
        QueueRepeat.one => AudioServiceRepeatMode.one,
        QueueRepeat.all => AudioServiceRepeatMode.all,
        _ => AudioServiceRepeatMode.none,
      };

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async {
    // The car cycles; so does the app. One press moves on one step whatever the car
    // asked for, so the two stay in step with what the queue actually does.
    await app.cycleRepeat();
    JustAudioBackground.refreshState();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) async {
    if (mode == AudioServiceShuffleMode.none) return;
    await app.shuffleWhatIsComing();
    JustAudioBackground.refreshState();
  }

  // ---------------------------------------------------------------- change

  Timer? _settle;
  int _lists = -1;
  int _hearts = -1;
  int? _playing;

  /// The app changed something the car is showing: the heart on the song playing, the
  /// playlists. Said once things have settled, not on every tick of the position.
  void _changed() {
    final lists = Object.hash(app.playlists.length, app.folders.length,
        [for (final p in app.playlists) p.pinned ? p.id : -p.id].join(','));
    final hearts = app.favourites.length;
    final playing = _now?.id;
    if (lists == _lists && hearts == _hearts && playing == _playing) return;
    final listsChanged = lists != _lists;
    _lists = lists;
    _hearts = hearts;
    _playing = playing;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 400), () {
      JustAudioBackground.refreshState();
      if (listsChanged) {
        for (final node in [home, playlists]) {
          JustAudioBackground.notifyChildrenChanged(node);
        }
      }
    });
  }

  void dispose() {
    _settle?.cancel();
    app.removeListener(_changed);
    if (JustAudioBackground.hooks == this) JustAudioBackground.hooks = null;
  }
}
