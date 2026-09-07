import 'dart:async';

import 'package:flutter/foundation.dart';
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
  Queue? activeQueue;
  List<Playlist> playlists = const [];

  StreamSubscription? _events;

  static const _kServer = 'muse.server';
  static const _kToken = 'muse.token';

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
    api = ApiClient(
      baseUrl: prefs.getString(_kServer) ?? 'http://127.0.0.1:8770',
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

  Future<void> _afterLogin() async {
    player ??= PlayerService(api);
    await player!.init();
    await refresh();
    _listenForEvents();
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

  Future<Queue> ensureQueue(String name) async {
    final existing = queues.where((q) => q.name == name);
    if (existing.isNotEmpty) return api.queue(existing.first.id);
    final made = await api.createQueue(name);
    queues = await api.queues();
    return made;
  }

  /// Add to the active queue, creating one on first use so nothing is ever dropped.
  Future<void> addTrack(Track t, {String mode = 'end'}) async {
    activeQueue ??= await ensureQueue('Now');
    activeQueue = await api.addToQueue(activeQueue!.id, [t.id], mode: mode);
    await player?.loadQueue(activeQueue!);
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

  void _listenForEvents() {
    _events?.cancel();
    _events = api.events().listen((e) async {
      if (e.event == 'track_ready') {
        final id = e.data['track_id'] as int?;
        if (id != null) {
          player?.onTrackReady(id);
          if (activeQueue != null) activeQueue = await api.queue(activeQueue!.id);
          notifyListeners();
        }
      } else if (e.event == 'track_failed') {
        if (activeQueue != null) {
          activeQueue = await api.queue(activeQueue!.id);
          notifyListeners();
        }
      }
    }, onError: (_) {
      // SSE drops on a sleeping phone; reconnect when the app resumes.
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    player?.dispose();
    super.dispose();
  }
}
