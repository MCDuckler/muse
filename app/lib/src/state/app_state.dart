import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'player.dart';

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
  /// Whether anything is able to download right now. The ingest worker runs on a
  /// machine that sleeps, and a row spinning forever with no explanation is the worst
  /// possible way to communicate that.
  bool ingestOnline = true;
  int downloadsPending = 0;
  Timer? _statusTimer;
  Queue? activeQueue;
  List<Playlist> playlists = const [];

  StreamSubscription? _events;

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

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
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
  Future<void> _afterLogin() async {
    player ??= PlayerService(api);
    // The player writes the cursor through the app rather than knowing the API: it
    // reports where playback is, and the app decides how to persist that.
    player!.onCursor = (queueId, {cursorIndex, positionMs}) {
      api
          .setCursor(queueId, index: cursorIndex, positionMs: positionMs)
          .catchError((_) {});
    };
    await player!.init();
    bindPlayer();
    await api.ensureStreamKey();
    await refresh();
    _listenForEvents();
    await _pollStatus();
    _statusTimer?.cancel();
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
  Future<Queue> ensureQueue(String name) async {
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

  Future<void> refreshPlaylists() async {
    playlists = await api.playlists();
    notifyListeners();
  }

  /// Play a list of tracks now, replacing the queue.
  ///
  /// This is what "play album" means everywhere else, and there was no way to express
  /// it: the only route into the queue was adding one track at a time.
  Future<void> playNow(List<Track> tracks, {int startAt = 0, bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    final target = activeQueue ?? await ensureQueue('Now');
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

  void _listenForEvents() {
    _events?.cancel();
    _events = api.events().listen((e) async {
      _eventBackoff = 1;
      if (e.event == 'track_ready') {
        final id = e.data['track_id'] as int?;
        if (id != null) {
          player?.onTrackReady(id);
          if (activeQueue != null) activeQueue = await api.queue(activeQueue!.id);
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
          if (activeQueue != null) activeQueue = await api.queue(activeQueue!.id);
          notifyListeners();
        }
      } else if (e.event == 'track_failed') {
        final id = e.data['track_id'] as int?;
        if (id != null) await player?.onTrackUpdated(id);
        if (activeQueue != null) {
          activeQueue = await api.queue(activeQueue!.id);
          notifyListeners();
        }
        await _pollStatus();
      }
    }, onError: (_) => _reconnectEvents(), onDone: _reconnectEvents);
  }

  /// The event stream dies whenever the phone sleeps or a proxy times out. Without a
  /// reconnect, tracks that finish downloading stay greyed out forever and the app
  /// looks broken while the server is perfectly fine.
  void _reconnectEvents() {
    if (user == null) return;
    final wait = Duration(seconds: _eventBackoff);
    _eventBackoff = (_eventBackoff * 2).clamp(1, 60);
    Future.delayed(wait, () {
      if (user != null) _listenForEvents();
    });
  }

  /// Player state changes (track advanced, paused) have to reach the queue list, or
  /// the highlighted row stops matching what is actually playing.
  void bindPlayer() {
    _playerSub?.cancel();
    _playerSub = player?.snapshots.listen((_) => notifyListeners());
  }

  StreamSubscription? _playerSub;

  Future<void> _pollStatus() async {
    try {
      final s = await api.status();
      ingestOnline = (s['ingest_online'] ?? false) as bool;
      downloadsPending = (s['downloads_pending'] ?? 0) as int;
      notifyListeners();
    } catch (_) {
      // A failed status check says nothing about the worker; leave the last answer.
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _playerSub?.cancel();
    _events?.cancel();
    player?.dispose();
    super.dispose();
  }
}
