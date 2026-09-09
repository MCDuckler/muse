import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'player.dart';
import '../ui/theme.dart';

/// One place the UI reads from. Deliberately small: the server is the truth, and a
/// local mirror (drift) is a later phase, not something to half-build now.
class AppState extends ChangeNotifier {
  AppState();

  late ApiClient api;
  PlayerService? player;

  bool ready = false;
  String? user;
  String? error;

  List<Queue> queues = const [];

  /// The hearted songs, as ids. Held here rather than asked per row: a list of four
  /// hundred would otherwise be four hundred requests to draw one icon each.
  Set<int> favourites = <int>{};
  int? favouritesPlaylistId;
  /// Whether anything is able to download right now. The ingest worker runs on a
  /// machine that sleeps, and a row spinning forever with no explanation is the worst
  /// possible way to communicate that.
  bool ingestOnline = true;
  int downloadsPending = 0;
  Timer? _statusTimer;

  /// The jam this device is in, if any. Null is the normal state: most listening is
  /// one person in one room.
  Jam? jam;

  /// Stop playing at a time you chose. Null when nothing is set.
  DateTime? sleepAt;
  Timer? _sleepTimer;
  /// Set instead of [sleepAt] when the timer should run to the end of this track.
  bool sleepAtEndOfTrack = false;

  Duration? get sleepIn => sleepAt?.difference(DateTime.now());

  /// Fade out and pause. Nobody wants a record cut off mid-bar at 2am, and nobody
  /// wants to wake up to it either.
  void setSleepTimer(Duration? after, {bool endOfTrack = false}) {
    _sleepTimer?.cancel();
    sleepAtEndOfTrack = endOfTrack;
    sleepAt = after == null ? null : DateTime.now().add(after);
    if (after != null) {
      _sleepTimer = Timer(after, () async {
        if (player?.last?.playing ?? false) await player?.playPause();
        sleepAt = null;
        sleepAtEndOfTrack = false;
        notifyListeners();
      });
    }
    notifyListeners();
  }
  Queue? activeQueue;
  List<Playlist> playlists = const [];

  StreamSubscription? _events;
  bool _disposed = false;

  /// On web the app is served by the same host it talks to, so its own origin is the
  /// answer. A device has no such hint, so the server is baked in at build time
  ///   flutter build apk --dart-define=MUSE_SERVER=https://your.server
  /// rather than hardcoded here — the address is deployment detail, not source.
  static String get defaultServer {
    const configured = String.fromEnvironment('MUSE_SERVER');
    if (configured.isNotEmpty) return configured;
    return kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8770';
  }

  static const _kServer = 'muse.server';
  static const _kToken = 'muse.token';
  static const _kCoverStyle = 'muse.coverStyle';
  static const _kPalette = 'muse.palette';
  static const _kHalftone = 'muse.halftone';
  static const _kLayout = 'muse.playerLayout';

  /// How the player draws the artwork: as the record it came on, or as the cover on
  /// its own. A per-device choice — the phone in a pocket and the laptop on a desk are
  /// not the same screen.
  CoverStyle coverStyle = CoverStyle.record;

  /// The colours. Per device like the cover style, because a phone at night and a
  /// laptop in a bright room do not want the same thing.
  Palette palette = Palette.ember;

  Future<void> setPalette(Palette next) async {
    palette = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPalette, next.id);
  }

  /// The printed pattern behind the record. On by default: it is ambience, and the
  /// screen is emptier without it — but a phone with a small battery is a good reason
  /// to turn a moving background off, so it is a switch and not a fact.
  bool halftone = true;

  /// How the now-playing screen is arranged. Per device, like the rest of the look.
  PlayerLayout playerLayout = PlayerLayout.grouped;

  Future<void> setPlayerLayout(PlayerLayout next) async {
    playerLayout = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLayout, next.name);
  }

  Future<void> setHalftone(bool on) async {
    halftone = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHalftone, on);
  }

  Future<void> setCoverStyle(CoverStyle style) async {
    coverStyle = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCoverStyle, style.name);
  }

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
    coverStyle = CoverStyle.values.firstWhere(
        (s) => s.name == prefs.getString(_kCoverStyle),
        orElse: () => CoverStyle.record);
    palette = Palette.byId(prefs.getString(_kPalette));
    halftone = prefs.getBool(_kHalftone) ?? true;
    playerLayout = PlayerLayout.values.firstWhere(
        (l) => l.name == prefs.getString(_kLayout),
        orElse: () => PlayerLayout.grouped);
    api = ApiClient(
      // Served from the box itself on web, so the page's own origin is the server —
      // no one should have to type a URL into a page they loaded from that URL.
      baseUrl: prefs.getString(_kServer) ?? defaultServer,
      token: prefs.getString(_kToken),
    );
    if (api.token != null) {
      try {
        final me = await api.me();
        user = me['user'] as String?;
        await _afterLogin();
      } on ApiException {
        api.token = null; // revoked or a different server
      }
    }
    ready = true;
    notifyListeners();
  }

  void reportError(String message) {
    error = message;
    notifyListeners();
  }

  Future<bool> login(String server, String username, String password) async {
    error = null;
    try {
      api.baseUrl = server.replaceAll(RegExp(r'/+$'), '');
      await api.login(username, password, 'flutter');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kServer, api.baseUrl);
      await prefs.setString(_kToken, api.token!);
      user = username;
      await _afterLogin();
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      error = e.status == 401 ? 'Wrong user or password' : e.message;
    } catch (e) {
      error = 'Cannot reach $server';
    }
    notifyListeners();
    return false;
  }

  /// Anything in here that throws must not leave the session half-built: the login
  /// path reports failure loudly rather than showing a signed-in shell with no data.
  /// Join a server with an invite code rather than a password someone else chose.
  Future<bool> redeem(String server, String code, String username,
      String password) async {
    error = null;
    try {
      api.baseUrl = server.replaceAll(RegExp(r'/+$'), '');
      await api.redeemInvite(code.trim(), username.trim(), password, 'flutter');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kServer, api.baseUrl);
      await prefs.setString(_kToken, api.token!);
      user = username.trim();
      await _afterLogin();
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Cannot reach $server';
    }
    notifyListeners();
    return false;
  }

  Future<void> _afterLogin() async {
    player ??= PlayerService(api);
    // The player writes the cursor through the app rather than knowing the API: it
    // reports where playback is, and the app decides how to persist that.
    player!.onCursor = (queueId, {cursorIndex, positionMs}) {
      // Remembered so the announcement this write causes can be recognised as our own
      // when it arrives back over the event stream.
      _cursorWrittenAt = DateTime.now();
      api
          .setCursor(queueId, index: cursorIndex, positionMs: positionMs)
          .catchError((_) {});
    };
    await player!.init();
    bindPlayer();
    await api.ensureStreamKey();
    await refresh();
    await refreshFavourites();
    // A jam survives closing the app: picking it back up is how the same person on
    // two devices stays in the same room.
    await refreshJam();
    await followJamQueue();
    _listenForEvents();
    await _pollStatus();
    _statusTimer?.cancel();
    _queueReload?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pollStatus());
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    api.token = null;
    user = null;
    _events?.cancel();
    notifyListeners();
  }

  Future<void> refresh() async {
    queues = await api.queues();
    playlists = await api.playlists();
    if (activeQueue == null && queues.isNotEmpty) {
      await openQueue(queues.first.id, autoplay: false);
    }
    notifyListeners();
  }

  Future<void> openQueue(int id, {bool autoplay = false}) async {
    activeQueue = await api.queue(id);
    await player?.loadQueue(activeQueue!, autoplay: autoplay);
    notifyListeners();
  }

  /// Find or create a queue by name.
  ///
  /// The local list is a cache, and it goes stale the moment another device (or an
  /// earlier session on this one) makes a queue. Trusting it meant trying to create a
  /// queue the server already had, and the resulting 409 escaped as a failed "add to
  /// queue" — which is what made queues feel unreliable. So: check the cache, re-read
  /// the server, and treat a 409 as "someone got there first" rather than an error.
  /// The queue called [name], made if it is not there.
  ///
  /// [fresh] reuses the one with that name if it exists rather than making a second —
  /// playing the same album twice should land in the same place, not leave a trail of
  /// queues behind.
  Future<Queue> ensureQueue(String name, {bool fresh = false}) async {
    Queue? found = _byName(name);
    if (found == null) {
      queues = await api.queues();
      found = _byName(name);
    }
    if (found != null) return api.queue(found.id);

    try {
      final made = await api.createQueue(name);
      queues = await api.queues();
      return made;
    } on ApiException catch (e) {
      if (e.status != 409) rethrow;
      queues = await api.queues();
      final raced = _byName(name);
      if (raced == null) rethrow;
      return api.queue(raced.id);
    }
  }

  Queue? _byName(String name) {
    for (final q in queues) {
      if (q.name == name) return q;
    }
    return null;
  }

  /// Add to the active queue, creating one on first use so nothing is ever dropped.
  Future<void> addTrack(Track t, {String mode = 'end'}) async {
    activeQueue ??= await ensureQueue('Now');
    activeQueue = await api.addToQueue(activeQueue!.id, [t.id], mode: mode);
    queues = await api.queues();      // a queue created just now must show in the chips
    await player?.loadQueue(activeQueue!);
    notifyListeners();
  }

  /// Shuffle and repeat live on the queue, so they persist across devices. They go
  /// through PATCH, never PUT — a settings update must not touch the item list.
  Future<void> setShuffle(bool value) async {
    final q = activeQueue;
    if (q == null) return;
    await player?.setShuffle(value);
    notifyListeners();
    await api.updateQueueSettings(q.id, shuffle: value).catchError((_) => q);
  }

  Future<void> cycleRepeat() async {
    final q = activeQueue;
    final p = player;
    if (q == null || p == null) return;
    final next = switch (p.repeat) {
      QueueRepeat.off => QueueRepeat.all,
      QueueRepeat.all => QueueRepeat.one,
      QueueRepeat.one => QueueRepeat.off,
    };
    p.setRepeat(next);
    notifyListeners();
    await api
        .updateQueueSettings(q.id, repeat: queueRepeatTo(next))
        .catchError((_) => q);
  }

  Future<void> _applyQueue(Queue updated) async {
    activeQueue = updated;
    await player?.loadQueue(updated);
    notifyListeners();
  }

  /// Remove a track, offering to put it back.
  ///
  /// Every destructive action here used to be final. A swipe is easy to do by
  /// accident, so the removal is announced with a way to reverse it — restoring the
  /// track to the position it came from, not to the end.
  Future<void> removeFromQueue(int pos, {BuildContext? context}) async {
    final q = activeQueue;
    if (q == null) return;
    final removed = (player?.items.length ?? 0) > pos ? player!.items[pos] : null;
    await _applyQueue(await api.removeQueueItem(q.id, pos));
    if (context == null || removed == null || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Removed ${removed.displayTitle}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _restoreToQueue(q.id, removed.id, pos),
      ),
    ));
  }

  Future<void> _restoreToQueue(int queueId, int trackId, int pos) async {
    try {
      var updated = await api.addToQueue(queueId, [trackId]);
      // It goes back on the end, so walk it home to where it was.
      final landedAt = updated.items.length - 1;
      if (landedAt != pos && pos < updated.items.length) {
        updated = await api.moveQueueItem(queueId, landedAt, pos);
      }
      if (activeQueue?.id == queueId) await _applyQueue(updated);
    } catch (_) {
      await refresh();
    }
  }

  Future<void> moveInQueue(int from, int to) async {
    final q = activeQueue;
    if (q == null) return;
    await _applyQueue(await api.moveQueueItem(q.id, from, to));
  }

  Future<void> clearQueue({String? origin, BuildContext? context}) async {
    final q = activeQueue;
    if (q == null) return;
    // Snapshot before clearing: undo has to put back exactly what was there, in order.
    final before = [for (final t in player?.items ?? const <Track>[]) t.id];
    final cleared = await api.clearQueue(q.id, origin: origin);
    await _applyQueue(cleared);
    queues = await api.queues();
    notifyListeners();
    if (context == null || before.isEmpty || !context.mounted) return;

    final removedCount = before.length - cleared.items.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(origin == 'radio'
          ? 'Cleared $removedCount radio ${removedCount == 1 ? 'track' : 'tracks'}'
          : 'Cleared the queue'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          final live = await api.queue(q.id);
          await _applyQueue(await api.replaceQueue(q.id, live.rev, before));
        },
      ),
    ));
  }

  /// A track that failed to download can be asked for again: resolve() retries a
  /// failed ingest, so the UI does not need a separate endpoint.
  Future<void> retry(Track track) async {
    if (track.providerId == null) return;
    await api.resolve(videoId: track.providerId);
    final q = activeQueue;
    if (q != null) await _applyQueue(await api.queue(q.id));
  }

  bool isFavourite(int trackId) => favourites.contains(trackId);

  Future<void> refreshFavourites() async {
    try {
      final f = await api.favourites();
      favourites = f.trackIds.toSet();
      favouritesPlaylistId = f.playlistId;
      notifyListeners();
    } catch (_) {
      // A heart that cannot be read is not worth an error on screen.
    }
  }

  /// Turned over straight away and put back if the server disagrees: a heart that waits
  /// for a round trip feels broken, and this is the most-tapped control in the app.
  Future<void> toggleFavourite(int trackId) async {
    final wanted = !favourites.contains(trackId);
    if (wanted) {
      favourites.add(trackId);
    } else {
      favourites.remove(trackId);
    }
    notifyListeners();
    try {
      final actual = await api.setFavourite(trackId, favourite: wanted);
      if (actual != wanted) {
        actual ? favourites.add(trackId) : favourites.remove(trackId);
        notifyListeners();
      }
      unawaited(refreshPlaylists());
    } catch (e) {
      wanted ? favourites.remove(trackId) : favourites.add(trackId);
      notifyListeners();
    }
  }

  Future<void> refreshPlaylists() async {
    playlists = await api.playlists();
    notifyListeners();
  }

  /// Play a list of tracks now, replacing the queue.
  ///
  /// This is what "play album" means everywhere else, and there was no way to express
  /// it: the only route into the queue was adding one track at a time.
  /// Play a list of songs.
  ///
  /// [named] makes a queue of its own rather than writing over the one you are
  /// listening to. Playing an album used to empty the queue you had built — an hour of
  /// picking gone because you wanted to hear a record — so anything with a name of its
  /// own gets its own queue, and the old one is still in the list to go back to.
  Future<void> playNow(List<Track> tracks,
      {int startAt = 0, bool shuffle = false, String? named}) async {
    if (tracks.isEmpty) return;
    final target = named == null
        ? (activeQueue ?? await ensureQueue('Now'))
        : await ensureQueue(named, fresh: true);
    final ids = [for (final t in tracks) t.id];
    final live = await api.queue(target.id);
    final filled = await api.replaceQueue(target.id, live.rev, ids);
    activeQueue = filled;
    queues = await api.queues();
    await player?.loadQueue(filled);
    if (shuffle) await player?.setShuffle(true);
    final first = tracks[startAt.clamp(0, tracks.length - 1)];
    await player?.playTrack(first.id, indexHint: startAt);
    notifyListeners();
  }

  Future<void> startRadio({int count = 5}) async {
    final q = activeQueue;
    final seed = player?.current;
    if (q == null || seed == null) return;
    activeQueue = await api.radio(q.id, seed.id, count: count);
    await player?.loadQueue(activeQueue!);
    notifyListeners();
  }

  int _eventBackoff = 1;

  /// Another device changed a queue: a guest in the jam added a song, or the same
  /// person queued something from a laptop while their phone is playing.
  ///
  /// Only worth acting on for the queue actually loaded here, and only when the
  /// revision is one this device has not seen — our own edits come back in the
  /// response, so this skips the echo of what we just did.
  /// Where the host has got to, and when we heard it.
  ///
  /// In a jam the host's device is the one making sound: a guest's own player is
  /// stopped, so drawing the seek bar from it showed nothing moving at zero. The host
  /// reports its position as it plays, and this is that report plus the clock — near
  /// enough for a bar that is telling you where somebody else is in a song.
  Duration? jamPosition;
  DateTime? _jamPositionAt;

  /// When this device last wrote a cursor of its own.
  DateTime? _cursorWrittenAt;

  /// The host's position now, carried forward since it was last reported.
  Duration? get hostPosition {
    final at = _jamPositionAt, base = jamPosition;
    if (at == null || base == null || jam == null || (jam?.isHost ?? true)) return null;
    final since = DateTime.now().difference(at);
    if (since > const Duration(minutes: 2)) return null;   // stale: say nothing
    return base + since;
  }

  Future<void> _onQueueChanged(Map<String, dynamic> data) async {
    final id = data['queue_id'] as int?;
    if (id == null || id != activeQueue?.id) return;
    final reported = data['position_ms'] as int?;
    if (reported != null && jam != null && !(jam?.isHost ?? false)) {
      jamPosition = Duration(milliseconds: reported);
      _jamPositionAt = DateTime.now();
    }
    final rev = data['rev'] as int?;
    // Every client of this user hears every announcement, this one included: a skip
    // writes its cursor, the server tells everybody, and the device that skipped is
    // told about its own move. Re-reading the queue for that is at best wasted work
    // and at worst a reload landing on top of a load still in flight.
    final ourOwnMove = jam == null &&
        _cursorWrittenAt != null &&
        DateTime.now().difference(_cursorWrittenAt!) < const Duration(seconds: 3);
    if (rev != null &&
        rev == activeQueue?.rev &&
        (data['cursor_moved'] != true || ourOwnMove)) {
      return;
    }

    await _reloadActiveQueue();
    final live = activeQueue;
    if (live == null) return;
    // loadQueue keeps the song that is playing where it is: it relocates the loaded
    // track rather than starting anything over.
    await player?.loadQueue(live);
    notifyListeners();
  }

  /// Something happened in the jam: somebody joined, added, voted, or it ended.
  ///
  /// The host's device is the one that actually skips — a vote that passes is a
  /// request, and this is where it is carried out.
  Future<void> _onJamEvent(Map<String, dynamic> data) async {
    if (jam == null && data['what'] != 'started') return;
    if (jam != null && data['jam_id'] != jam!.id) return;

    if (data['what'] == 'skip' && (jam?.isHost ?? false)) {
      if (player?.current?.id == data['track_id']) await player?.next();
    }
    await refreshJam();
    if (jam != null && activeQueue?.id == jam!.queueId) {
      await _reloadActiveQueue();
      if (activeQueue != null) await player?.loadQueue(activeQueue!);
    }
    notifyListeners();
  }

  /// Ask where the jam stands. Doubles as the heartbeat that keeps this device listed
  /// as present, which is why it runs on the status timer too.
  /// Re-read the queue being played, and cope with it having gone.
  ///
  /// A queue can disappear under you now: a jam you were in ended, or it was deleted
  /// on another device. Before this, the refetch threw into an unawaited future and
  /// the app carried on pointing at a queue the server no longer had.
  Timer? _queueReload;

  /// Refetch the queue, at most once a second, and only for news that concerns it.
  ///
  /// A mirror of twelve thousand songs enriches twelve thousand tracks, and every one
  /// of those used to make every open client fetch its whole queue again. The queue is
  /// the thing on screen; the other 11,990 tracks are not.
  void _queueMayHaveChanged({int? trackId}) {
    if (trackId != null &&
        !(player?.items.any((t) => t.id == trackId) ?? false)) {
      return;
    }
    _queueReload?.cancel();
    _queueReload = Timer(const Duration(milliseconds: 600), () async {
      await _reloadActiveQueue();
      notifyListeners();
    });
  }

  Future<void> _reloadActiveQueue() async {
    final q = activeQueue;
    if (q == null) return;
    try {
      activeQueue = await api.queue(q.id);
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      activeQueue = null;
      jam = null;
      await refresh();
    }
  }

  Future<Jam?> refreshJam() async {
    try {
      jam = await api.currentJam();
    } catch (_) {
      // A jam that cannot be reached is not worth an error on screen.
    }
    notifyListeners();
    return jam;
  }

  Future<void> startJam() async {
    final queue = activeQueue;
    if (queue == null) return;
    jam = await api.startJam(queue.id);
    notifyListeners();
  }

  Future<void> joinJam(String code) async {
    jam = await api.joinJam(code);
    queues = await api.queues();          // the host's queue is in your list now
    await followJamQueue();
    notifyListeners();
  }

  /// Listen to the jam's queue, not your own.
  ///
  /// Joining did this once and then never again, so the first thing that reopened a
  /// queue — starting the app, most of all — put a guest back on their own queue while
  /// the screen still said they were in a jam. Everything they added from then on went
  /// somewhere the host could not see, which is exactly what "it does not influence the
  /// host" looks like from the other end.
  Future<void> followJamQueue() async {
    final current = jam;
    if (current == null) return;
    if (activeQueue?.id == current.queueId) return;
    try {
      activeQueue = await api.queue(current.queueId);
      await player?.loadQueue(activeQueue!);
      notifyListeners();
    } catch (_) {
      // The jam ended under us; refreshJam will clear it.
    }
  }

  Future<void> inviteToJam(int userId) async {
    final current = jam;
    if (current == null) return;
    jam = await api.inviteToJam(current.id, userId);
    notifyListeners();
  }

  Future<void> leaveJam() async {
    final current = jam;
    if (current == null) return;
    await api.leaveJam(current.id);
    jam = null;
    notifyListeners();
  }

  void _listenForEvents() {
    _events?.cancel();
    _events = api.events().listen((e) async {
      _eventBackoff = 1;
      if (e.event == 'track_ready') {
        final id = e.data['track_id'] as int?;
        if (id != null) {
          player?.onTrackReady(id);
          _queueMayHaveChanged(trackId: id);
          notifyListeners();
        }
      } else if (e.event == 'track_progress') {
        // Progress arrives several times a second per track; patch the row in place
        // rather than re-fetching the queue for every tick.
        final id = e.data['track_id'] as int?;
        if (id != null) {
          player?.applyProgress(id, Map<String, dynamic>.from(e.data));
          notifyListeners();
        }
      } else if (e.event == 'track_updated') {
        // Artwork and metadata arrive after the audio does. Refresh in place so a
        // cover appears while you are looking at the list, not on the next launch.
        final id = e.data['track_id'] as int?;
        if (id != null) {
          await player?.onTrackUpdated(id);
          _queueMayHaveChanged(trackId: id);
          notifyListeners();
        }
      } else if (e.event == 'queue_changed') {
        await _onQueueChanged(e.data);
      } else if (e.event == 'jam') {
        await _onJamEvent(e.data);
      } else if (e.event == 'track_failed') {
        final id = e.data['track_id'] as int?;
        if (id != null) await player?.onTrackUpdated(id);
        _queueMayHaveChanged(trackId: id);
        notifyListeners();
        await _pollStatus();
      }
    }, onError: (_) => _reconnectEvents(), onDone: _reconnectEvents);
  }

  /// The event stream dies whenever the phone sleeps or a proxy times out. Without a
  /// reconnect, tracks that finish downloading stay greyed out forever and the app
  /// looks broken while the server is perfectly fine.
  void _reconnectEvents() {
    if (_disposed || user == null) return;
    final wait = Duration(seconds: _eventBackoff);
    _eventBackoff = (_eventBackoff * 2).clamp(1, 60);
    Future.delayed(wait, () {
      if (!_disposed && user != null) _listenForEvents();
    });
  }

  /// Player state changes (track advanced, paused) have to reach the queue list, or
  /// the highlighted row stops matching what is actually playing.
  /// On the web this is the browser tab's title, which is how you find the tab that
  /// is making the noise. Elsewhere it names the entry in the task switcher.
  void _describeForTheOs(Track? track) {
    SystemChrome.setApplicationSwitcherDescription(ApplicationSwitcherDescription(
      label: track == null ? 'muse' : '${track.displayTitle} · ${track.artistLine}',
      primaryColor: 0xFF121212,
    ));
  }

  /// Follow the player, and tell the app only when something it can see has changed.
  ///
  /// The player reports four times a second, because a progress bar has to move. This
  /// used to call notifyListeners on every one of those, so every screen watching the
  /// app — the whole queue, the library, the settings page — rebuilt four times a
  /// second while a song played. Anything that genuinely needs the position reads the
  /// snapshot stream directly and still gets every tick; everything else only needs to
  /// know when the shape of things changed.
  void bindPlayer() {
    _playerSub?.cancel();
    int? named;
    String? shape;
    _playerSub = player?.snapshots.listen((s) {
      if (s.current?.id != named) {
        named = s.current?.id;
        _describeForTheOs(s.current);
      }
      final next = [
        s.current?.id,
        s.loadedTrackId,
        s.index,
        s.itemCount,
        s.playing,
        s.shuffle,
        s.repeat,
        s.finished,
        s.waitingForDownload,
        s.needsGesture,
        s.error,
      ].join('|');
      if (next == shape) return;
      shape = next;
      notifyListeners();
    });
  }

  StreamSubscription? _playerSub;

  Future<void> _pollStatus() async {
    if (_disposed) return;
    try {
      final s = await api.status();
      ingestOnline = (s['ingest_online'] ?? false) as bool;
      downloadsPending = (s['downloads_pending'] ?? 0) as int;
      notifyListeners();
      // The same tick keeps this device listed as present in the jam. Without it the
      // others would see everyone drift to "away" while they were still listening.
      if (jam != null) await refreshJam();
    } catch (_) {
      // A failed status check says nothing about the worker; leave the last answer.
    }
  }

  /// Several things here outlive a single screen: a status poll every thirty seconds,
  /// an event stream that reconnects with backoff, a player that keeps going. Any of
  /// them can come back after the app is torn down, and notifying a disposed listener
  /// throws — so this is the one place that has to know.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _events?.cancel();
    _playerSub?.cancel();
    _events?.cancel();
    player?.dispose();
    super.dispose();
  }
}
