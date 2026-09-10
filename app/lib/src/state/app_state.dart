import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'offline.dart';
import 'playback_log.dart';
import 'player.dart';
import '../ui/theme.dart';

/// One place the UI reads from. Deliberately small: the server is the truth, and a
/// local mirror (drift) is a later phase, not something to half-build now.
class AppState extends ChangeNotifier {
  AppState();

  late ApiClient api;
  PlayerService? player;

  /// Music kept on this device. Created once the server is known, because it fetches
  /// through the same client.
  late final OfflineStore offline = OfflineStore(api);

  bool ready = false;
  String? user;

  /// Who this is on the server, and the version of their picture — both come back with
  /// the first "who am I" and are what the app draws a face from.
  int? userId;
  String? avatarVersion;
  String? error;

  List<Queue> queues = const [];

  /// Which tab the home shell is on: 0 queues, 1 search, 2 library.
  ///
  /// It lives here rather than in the shell's own State because other screens need to
  /// send you to a tab — the player's "up next" is the queue, and the queue is a page
  /// people already know, not a sheet with its own half-copy of one.
  int homeTab = 0;

  void setHomeTab(int tab) {
    if (homeTab == tab) return;
    homeTab = tab;
    notifyListeners();
  }

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
  static const _kSpectrum = 'muse.spectrum';
  static const _kCoverScale = 'muse.coverScale';
  static const _kLayout = 'muse.playerLayout';
  static const _kShelfAxis = 'muse.shelfAxis';
  static const _kJamListening = 'muse.jamListening';

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

  /// How much of the stage the record in the middle takes up. Bigger than it was —
  /// the record is the thing you are looking at — and adjustable, because how big it
  /// should be depends on the phone and on how far away it is being read from.
  double coverScale = 0.74;

  Future<void> setCoverScale(double value) async {
    coverScale = value.clamp(0.5, 1.0);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kCoverScale, coverScale);
  }

  /// The bars under the artwork: what is actually coming out of the speaker. Off by
  /// default because switching it on asks for a permission, and a permission nobody
  /// asked for is alarming.
  bool spectrum = false;

  Future<void> setSpectrum(bool on) async {
    spectrum = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSpectrum, on);
  }

  /// Whether this device plays the jam's music, or only follows along.
  ///
  /// Off by default, and deliberately. Everybody in a room hearing the same record out
  /// of five phones a half-second apart is not listening together, it is a mess — the
  /// host's speaker is the one playing. A guest who *is* somewhere else turns this on
  /// and hears it too.
  bool jamListening = false;

  Future<void> setJamListening(bool on) async {
    jamListening = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kJamListening, on);
    if (!on) {
      await player?.pause();
    } else {
      final state = jam?.playback;
      if (state != null) await followJamPlayback(state);
    }
  }

  /// Which way the records travel when the song changes.
  ///
  /// Sideways is a shelf of records; upwards is a stack of them. Neither is more
  /// correct, and which one reads better depends on how the phone is held — so it is
  /// a choice rather than a decision made here.
  ShelfAxis shelfAxis = ShelfAxis.sideways;

  Future<void> setShelfAxis(ShelfAxis next) async {
    shelfAxis = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShelfAxis, next.name);
  }

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
    await PlaybackLog.load();
    // First line after a restart. If the one before it is not a goodbye, the process
    // did not choose to stop — it was killed, which is a different fault entirely.
    PlaybackLog.note('--- app started');
    final prefs = await SharedPreferences.getInstance();
    coverStyle = CoverStyle.values.firstWhere(
        (s) => s.name == prefs.getString(_kCoverStyle),
        orElse: () => CoverStyle.record);
    palette = Palette.byId(prefs.getString(_kPalette));
    halftone = prefs.getBool(_kHalftone) ?? true;
    spectrum = prefs.getBool(_kSpectrum) ?? false;
    coverScale = (prefs.getDouble(_kCoverScale) ?? 0.74).clamp(0.5, 1.0);
    playerLayout = PlayerLayout.values.firstWhere(
        (l) => l.name == prefs.getString(_kLayout),
        orElse: () => PlayerLayout.grouped);
    shelfAxis = ShelfAxis.values.firstWhere(
        (a) => a.name == prefs.getString(_kShelfAxis),
        orElse: () => ShelfAxis.sideways);
    jamListening = prefs.getBool(_kJamListening) ?? false;
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
        userId = me['user_id'] as int?;
        avatarVersion = me['avatar_version'] as String?;
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
      final me = await api.me();
      userId = me['user_id'] as int?;
      avatarVersion = me['avatar_version'] as String?;
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
      // A guest is playing the host's queue, so writing where *this* device has got to
      // moves the host's cursor: two people listening together fought over one number,
      // and each one's playback dragged the other's back. The host's player is the one
      // that keeps the place; a guest keeps its own place in its own head.
      if (jam != null && !(jam?.isHost ?? false)) return;
      // Remembered so the announcement this write causes can be recognised as our own
      // when it arrives back over the event stream.
      _cursorWrittenAt = DateTime.now();
      api
          .setCursor(queueId, index: cursorIndex, positionMs: positionMs)
          .catchError((_) {});
    };
    await player!.init();
    // The player reaches for a local file before the network — see _sourceFor.
    await offline.init();
    player!.offlinePath = offline.pathFor;
    offline.addListener(notifyListeners);
    _lifecycle;                     // built lazily; touching it starts it listening
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
    // The room's heartbeat. Five seconds is short enough that nobody drifts audibly
    // within a song and long enough to be nothing on a phone's battery; it costs
    // nothing at all when this device is not hosting a jam.
    _jamTimer?.cancel();
    _jamTimer = Timer.periodic(const Duration(seconds: 5), (_) => pushJamState());
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

  /// Choose a picture for this account, or take it away again.
  Future<void> setAvatar(List<int> bytes) async {
    avatarVersion = await api.setAvatar(bytes);
    notifyListeners();
  }

  Future<void> clearAvatar() async {
    await api.clearAvatar();
    avatarVersion = null;
    notifyListeners();
  }

  /// Keep these on the device, or stop keeping them.
  ///
  /// Everything about what is kept is asked for by hand: nothing is downloaded because
  /// it happened to play, so "is this here for the flight" has a definite answer.
  Future<void> keepOffline(Iterable<Track> tracks) => offline.keep(tracks);

  Future<void> forgetOffline(int trackId) => offline.forget(trackId);

  /// Everything on a playlist or in a queue, in one go. The server says how much that
  /// is before anything is fetched — see the manifest.
  Future<({int count, double mb})> offlineSize(
      {int? playlistId, int? queueId}) async {
    final d = await api.downloadManifest(playlistId: playlistId, queueId: queueId);
    return (count: d.count, mb: d.mb);
  }

  /// Rearrange what is coming, once.
  ///
  /// Shuffle used to be a switch: on, and every song after this one came in an order
  /// the queue did not show; off, and nothing went back to where it had been. This
  /// shuffles the rows themselves — the song playing stays playing, everything after
  /// it is dealt again — and then it is done, so the list is the running order.
  Future<void> shuffleWhatIsComing() async {
    final q = activeQueue;
    if (q == null) return;
    player?.shuffleWhatIsComing();
    notifyListeners();
    try {
      await _applyQueue(await api.shuffleQueue(q.id));
    } catch (_) {
      await _resyncQueue();
    }
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
    // Gone from the list at once — see moveInQueue for why.
    player?.removeLocally(pos);
    notifyListeners();
    try {
      await _applyQueue(await api.removeQueueItem(q.id, pos));
    } catch (_) {
      await _resyncQueue();
      return;
    }
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
    // On screen first, then ask. The server's answer replaces this a moment later and
    // agrees with it; if it does not — somebody else changed the queue underneath —
    // what it says is what the list goes back to.
    player?.moveLocally(from, to);
    notifyListeners();
    try {
      await _applyQueue(await api.moveQueueItem(q.id, from, to));
    } catch (_) {
      await _resyncQueue();
    }
  }

  /// Move a whole selection to one place, as one edit.
  Future<void> moveManyInQueue(List<int> froms, int to) async {
    final q = activeQueue;
    if (q == null || froms.isEmpty) return;
    player?.moveManyLocally(froms, to);
    notifyListeners();
    try {
      await _applyQueue(await api.moveQueueItems(q.id, froms, to));
    } catch (_) {
      await _resyncQueue();
    }
  }

  /// Put the list back to whatever the server actually has.
  Future<void> _resyncQueue() async {
    await _reloadActiveQueue();
    final live = activeQueue;
    if (live != null) await player?.loadQueue(live);
    notifyListeners();
  }

  /// Get rid of a queue. The songs in it are library rows and stay where they are;
  /// what goes is the list and the order.
  Future<void> deleteQueue(int id) async {
    await api.deleteQueue(id);
    final wasActive = activeQueue?.id == id;
    queues = await api.queues();
    if (wasActive) {
      activeQueue = null;
      // Land somewhere rather than on an empty screen with no queue selected.
      final next = queues.where((q) => q.sharedFrom == null).firstOrNull;
      if (next != null) {
        await openQueue(next.id);
      } else {
        await player?.loadQueue(await ensureQueue('Now'));
      }
    }
    notifyListeners();
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

  /// Fetch this one now, for a song that is listed but has no file behind it.
  ///
  /// A mirrored library records far more than it downloads, so most songs sit like
  /// this until something asks for them. Pressing play asks; so does this.
  Future<void> fetchNow(Track track) async {
    await api.promoteDownload(track.id);
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

    // "Shuffle" on a record or a playlist is the same one-shot deal as the button in
    // the player: the queue is built in a shuffled order and then played from the top.
    // Nothing is left switched on afterwards, and the list shows the order it will
    // play in — which a shuffle mode never did.
    final ordered = shuffle ? ([...tracks]..shuffle(math.Random())) : tracks;
    final ids = [for (final t in ordered) t.id];
    final live = await api.queue(target.id);
    final filled = await api.replaceQueue(target.id, live.rev, ids);
    activeQueue = filled;
    queues = await api.queues();
    await player?.loadQueue(filled);
    final at = shuffle ? 0 : startAt.clamp(0, ordered.length - 1);
    await player?.playTrack(ordered[at].id, indexHint: at);
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

  /// The last transport this device sent as host, so heartbeats that say nothing new
  /// are not sent at all.
  String? _pushedState;
  DateTime? _pushedAt;

  /// A guest is only allowed to correct its own playback so often: seeking on every
  /// heartbeat would stutter through the whole song.
  DateTime? _lastFollowSeek;

  /// True while this device is somebody else's guest.
  bool get isJamGuest => jam != null && !(jam?.isHost ?? true);

  /// True when working the controls here reaches the room rather than this device.
  /// Which, for a guest, is always: a jam has no rules — everybody in it shares the
  /// queue and the transport.
  bool get jamControlsTheRoom => isJamGuest;

  // ---------------------------------------------------------------- host → room
  /// Say where the music is, if it has moved somewhere worth saying.
  ///
  /// Called whenever the player's shape changes and on a few-second heartbeat: the
  /// changes keep the room in step with a skip or a pause, and the heartbeat keeps it
  /// from drifting over the length of a song.
  Future<void> pushJamState({bool force = false}) async {
    final current = jam;
    final p = player;
    if (current == null || p == null || !current.isHost) return;
    final snap = p.last;
    final shape = '${snap?.current?.id}|${snap?.playing}';
    final now = DateTime.now();
    final due = _pushedAt == null ||
        now.difference(_pushedAt!) > const Duration(seconds: 5);
    if (!force && shape == _pushedState && !due) return;
    _pushedState = shape;
    _pushedAt = now;
    try {
      await api.pushJamPlayback(current.id,
          trackId: snap?.current?.id,
          positionMs: (snap?.position ?? Duration.zero).inMilliseconds,
          playing: snap?.playing ?? false);
    } catch (_) {
      // The next heartbeat says the same thing; a dropped one costs nothing.
    }
  }

  // ---------------------------------------------------------------- room → guest
  /// Play what the host is playing, where the host is playing it.
  Future<void> followJamPlayback(JamPlayback state) async {
    if (!isJamGuest) return;
    final p = player;
    if (p == null) return;

    // Following without listening: the screen keeps up with the room, the speaker
    // stays out of it. This is the normal case — everyone in one room hearing the
    // same record out of five phones is not listening together.
    if (!jamListening) {
      if (p.last?.playing ?? false) await p.pause();
      if (state.trackId != null && p.current?.id != state.trackId) {
        await p.showTrack(state.trackId!);
      }
      notifyListeners();
      return;
    }
    // Reported position plus however long the message took to get here.
    final target = state.position;

    if (state.trackId != null && p.current?.id != state.trackId) {
      // A different song: catch up to it, then to the place in it.
      await p.playTrack(state.trackId!);
      await p.seek(target);
      if (!state.playing) await p.pause();
      notifyListeners();
      return;
    }

    if (!state.playing) {
      if (p.last?.playing ?? false) await p.pause();
      // Still worth landing on the right spot: a paused room is paused *somewhere*.
      await p.seek(target);
      notifyListeners();
      return;
    }

    final here = p.last?.position ?? Duration.zero;
    final drift = (here - target).abs();
    final settled = _lastFollowSeek == null ||
        DateTime.now().difference(_lastFollowSeek!) > const Duration(seconds: 4);
    if (drift > const Duration(milliseconds: 2500) && settled) {
      _lastFollowSeek = DateTime.now();
      await p.seek(target);
    }
    if (!(p.last?.playing ?? false)) await p.resumeForJam();
    notifyListeners();
  }

  // ---------------------------------------------------------------- guest → room
  /// The transport, wherever it is pressed.
  ///
  /// In a jam a guest's play button is a request: the host's device is the clock, and
  /// two devices deciding for themselves is exactly the drift this is here to stop.
  Future<void> playPause() async {
    if (jamControlsTheRoom) {
      final playing = player?.last?.playing ?? false;
      await _ask(playing ? 'pause' : 'play');
      return;
    }
    await player?.playPause();
    await pushJamState(force: true);
  }

  Future<void> skipNext() async {
    if (jamControlsTheRoom) return _ask('next');
    await player?.next();
    await pushJamState(force: true);
  }

  Future<void> skipPrevious() async {
    if (jamControlsTheRoom) return _ask('previous');
    await player?.previous();
    await pushJamState(force: true);
  }

  Future<void> seekTo(Duration to) async {
    if (jamControlsTheRoom) return _ask('seek', positionMs: to.inMilliseconds);
    await player?.seek(to);
    await pushJamState(force: true);
  }

  /// What went wrong last time somebody reached for the controls, if anything.
  String? jamRefusal;

  Future<void> _ask(String action, {int? positionMs}) async {
    final current = jam;
    if (current == null) return;
    try {
      await api.jamControl(current.id, action, positionMs: positionMs);
      jamRefusal = null;
    } catch (e) {
      jamRefusal = '$e';
      notifyListeners();
    }
  }

  /// The host carrying out what somebody asked for.
  Future<void> _obeyJamControl(Map<String, dynamic> data) async {
    final p = player;
    if (p == null || !(jam?.isHost ?? false)) return;
    switch (data['action']) {
      case 'play':
        if (!(p.last?.playing ?? false)) await p.playPause();
      case 'pause':
        if (p.last?.playing ?? false) await p.playPause();
      case 'next':
        await p.next();
      case 'previous':
        await p.previous();
      case 'seek':
        await p.seek(Duration(milliseconds: (data['position_ms'] ?? 0) as int));
    }
    await pushJamState(force: true);
  }

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

    // The two live halves of a jam, before anything else: they arrive several times a
    // minute and neither of them needs the jam re-read from the server.
    if (data['what'] == 'playback') {
      if (isJamGuest) {
        final state = JamPlayback.fromJson(Map<String, dynamic>.from(data));
        jamPosition = state.position;
        _jamPositionAt = DateTime.now();
        await followJamPlayback(state);
      }
      return;
    }
    if (data['what'] == 'control') {
      await _obeyJamControl(Map<String, dynamic>.from(data));
      return;
    }

    if (data['what'] == 'skip' && (jam?.isHost ?? false)) {
      if (player?.current?.id == data['track_id']) await player?.next();
    }
    // Held onto before asking, because what it answers may be "there is no jam any
    // more" — and by then there is nothing left to say which queue was the room's.
    final wasQueue = jam?.queueId;
    final wasHost = jam?.isHost ?? false;

    await refreshJam();
    if (jam == null) {
      // Ended by the host, or this device was removed from it.
      await _outOfTheJam(wasQueue, wasHost: wasHost);
      return;
    }
    if (activeQueue?.id == jam!.queueId) {
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
    // Say where the music is immediately: the first person to join wants the song
    // that is on, not the one the heartbeat gets round to mentioning.
    await pushJamState(force: true);
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
    if (activeQueue?.id != current.queueId) {
      try {
        activeQueue = await api.queue(current.queueId);
        await player?.loadQueue(activeQueue!);
        notifyListeners();
      } catch (_) {
        // The jam ended under us; refreshJam will clear it.
        return;
      }
    }
    // Land in the right place in the right song. Joining halfway through a record and
    // starting it from the top is not listening together.
    final state = current.playback;
    if (state != null && isJamGuest) {
      jamPosition = state.position;
      _jamPositionAt = DateTime.now();
      await followJamPlayback(state);
    } else if (current.isHost) {
      await pushJamState(force: true);
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
    await _outOfTheJam(current.queueId, wasHost: current.isHost);
  }

  /// The room is over for this device — left, removed, or the host closed it.
  ///
  /// A guest was listening to the host's queue, which is in their list only for as
  /// long as they are in the jam. Clearing the jam alone left that queue sitting in
  /// the strip and selected, so the screen still showed somebody else's list, still
  /// said what was on it, and refused every edit — the room had gone and the app had
  /// not noticed.
  Future<void> _outOfTheJam(int? jamQueueId, {bool wasHost = false}) async {
    jam = null;
    jamPosition = null;
    _jamPositionAt = null;
    queues = await api.queues();

    // The host keeps their own queue; only a guest is left holding one that is not
    // theirs to hold.
    if (!wasHost && jamQueueId != null && activeQueue?.id == jamQueueId) {
      // The music was the room's. Stopping is what ending a shared listen sounds
      // like; carrying on into somebody else's list from your own queue is not.
      await player?.pause();
      final mine = queues.where((q) => q.sharedFrom == null).toList();
      final next = mine.isEmpty
          ? await ensureQueue('Now')
          : await api.queue(mine.first.id);
      activeQueue = next;
      await player?.loadQueue(next);
    }
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
        s.repeat,
        s.finished,
        s.waitingForDownload,
        s.needsGesture,
        s.error,
      ].join('|');
      if (next == shape) return;
      shape = next;
      // A jam's host is the room's clock: every change here is news to everybody else.
      if (jam?.isHost ?? false) unawaited(pushJamState());
      notifyListeners();
    });
  }

  StreamSubscription? _playerSub;
  Timer? _jamTimer;

  /// Coming back to the app is the moment to find out what happened while it was away:
  /// a phone freezes what it is not showing, and a stream that died out of sight stays
  /// dead until something looks at it.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () {
      PlaybackLog.note('app in front');
      unawaited(player?.resumeIfStopped());
      unawaited(refreshJam());
    },
    // The other end of the interesting gap: everything between this line and the next
    // "app in front" happened with nobody watching, which is exactly the stretch a
    // report of "it stops when I switch away" is about.
    onHide: () => PlaybackLog.note('app out of sight'),
    onPause: () => PlaybackLog.note('app paused by the system'),
    onDetach: () => PlaybackLog.note('app being torn down'),
  );

  Future<void> _pollStatus() async {
    if (_disposed) return;
    try {
      final s = await api.status();
      ingestOnline = (s['ingest_online'] ?? false) as bool;
      downloadsPending = (s['downloads_pending'] ?? 0) as int;
      notifyListeners();
      // The same tick keeps this device listed as present in the jam. Without it the
      // others would see everyone drift to "away" while they were still listening.
      if (jam != null) {
        await refreshJam();
        // And it is the way back into step after a missed event — a tunnel, a sleeping
        // phone, an event stream that dropped and came back.
        final state = jam?.playback;
        if (state != null && isJamGuest) await followJamPlayback(state);
      }
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
    _jamTimer?.cancel();
    _lifecycle.dispose();
    _events?.cancel();
    _playerSub?.cancel();
    _events?.cancel();
    player?.dispose();
    super.dispose();
  }
}
