import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'offline.dart';
import 'art_cache.dart';
import 'playback_log.dart';
import 'sleeve_board.dart';
import 'coalesce.dart';
import 'keepalive.dart';
import 'player.dart';
import '../ui/favicon.dart';
import '../ui/feel.dart';
import '../ui/media_session.dart';
import '../ui/settings_page.dart' show appBuild;
import '../ui/theme.dart';
import '../ui/snack.dart';

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

  /// Records heard all the way through. Counted by the server from the listens it has
  /// already written down, so it is a fact about what happened rather than a tally
  /// that can drift away from it.
  int score = 0;
  String? avatarVersion;
  String? error;

  List<Queue> queues = const [];

  /// Which tab the home shell is on: 0 queues, 1 search, 2 library.
  ///
  /// It lives here rather than in the shell's own State because other screens need to
  /// send you to a tab — the player's "up next" is the queue, and the queue is a page
  /// people already know, not a sheet with its own half-copy of one.
  int homeTab = 0;

  /// Whether the column beside the page — what is playing, what is next — is folded
  /// out. Only ever asked on a screen wide enough to have one.
  bool deskDock = true;

  void toggleDeskDock() {
    deskDock = !deskDock;
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_kDeskDock, deskDock))
        .catchError((_) => false);
    notifyListeners();
  }

  void setHomeTab(int tab) {
    if (homeTab == tab) return;
    homeTab = tab;
    // Remembered, like the queue that was playing: opening the app again lands where
    // it was left rather than back at the queue every time.
    SharedPreferences.getInstance()
        .then((p) => p.setInt(_kHomeTab, tab))
        .catchError((_) => false);
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

  /// Whether a sleep timer of either kind is set.
  bool get sleepSet => sleepAt != null || sleepAtEndOfTrack;

  /// How long the music takes to go quiet before it stops.
  static const sleepFade = Duration(seconds: 10);
  Timer? _sleepFadeTimer;
  Timer? _sleepFadeStep;
  double? _volumeBeforeSleep;

  /// Fade out and pause. Nobody wants a record cut off mid-bar at 2am, and nobody
  /// wants to wake up to it either.
  ///
  /// [endOfTrack] stops when this song ends instead of at a time — the fade starts
  /// in its last seconds, and the next song never starts.
  void setSleepTimer(Duration? after, {bool endOfTrack = false}) {
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _stopFading(restore: true);
    sleepAtEndOfTrack = endOfTrack;
    sleepAt = after == null ? null : DateTime.now().add(after);
    if (after != null) {
      final fadeAt = after - sleepFade;
      _sleepFadeTimer =
          Timer(fadeAt.isNegative ? Duration.zero : fadeAt, _beginSleepFade);
      _sleepTimer = Timer(after, _sleepNow);
    }
    notifyListeners();
  }

  /// Where in the song the fade began, so a song that comes round again on repeat —
  /// or is dragged back to the start — is recognised as having ended.
  Duration? _fadeBeganAt;

  /// Bring the volume down over [sleepFade], leaving the listener's own setting
  /// untouched for when the music comes back.
  void _beginSleepFade() {
    final p = player;
    if (p == null || _sleepFadeStep != null) return;
    if (!(p.last?.playing ?? false)) return;
    final from = p.userVolume;
    _volumeBeforeSleep = from;
    _fadeBeganAt = p.last?.position;
    final steps = sleepFade.inMilliseconds ~/ 250;
    var step = 0;
    _sleepFadeStep = Timer.periodic(const Duration(milliseconds: 250), (t) {
      step++;
      final left = (1 - step / steps).clamp(0.0, 1.0);
      unawaited(p.setUserVolume(from * left * left));
      if (step >= steps) t.cancel();
    });
  }

  void _stopFading({required bool restore}) {
    _sleepFadeStep?.cancel();
    _sleepFadeStep = null;
    _fadeBeganAt = null;
    final back = _volumeBeforeSleep;
    _volumeBeforeSleep = null;
    if (restore && back != null) unawaited(player?.setUserVolume(back));
  }

  Future<void> _sleepNow() async {
    final p = player;
    sleepAt = null;
    sleepAtEndOfTrack = false;
    // Both timers, whichever of them got here first: a pause during the fade ends the
    // timer early, and the one still waiting would otherwise pause the music somebody
    // started again in the meantime.
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    if (p != null && (p.last?.playing ?? false)) {
      // pause(), not playPause(): a toggle that arrives after somebody paused by hand
      // would start the music again at exactly the moment they wanted it off.
      await p.pause();
    }
    // Quietly put back for next time; nothing is playing to hear it happen.
    _stopFading(restore: true);
    notifyListeners();
  }

  /// The player's clock, watched for the last seconds of the song a sleep timer is
  /// waiting on. Called from the snapshot stream.
  void _watchForEndOfTrack(PlayerSnapshot s, {required bool trackChanged}) {
    final fading = _volumeBeforeSleep != null;
    // The music stopped while it was being faded: paused by hand, or the queue ran
    // out under it. The timer has nothing left to do — and leaving the volume where
    // the fade had got to meant the next thing played started nearly silent.
    if (fading && !s.playing) {
      unawaited(_sleepNow());
      return;
    }
    if (!sleepAtEndOfTrack) return;
    final cameRound = fading &&
        _fadeBeganAt != null &&
        s.position + const Duration(seconds: 1) < _fadeBeganAt!;
    if (fading && (trackChanged || cameRound)) {
      // The song the timer was set on has ended: the next one has started, or on
      // repeat the same one has begun again. This is the moment.
      unawaited(_sleepNow());
      return;
    }
    final total = s.duration;
    if (total == null || total == Duration.zero) return;
    if (total - s.position <= sleepFade && s.playing) _beginSleepFade();
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

  /// Where the server used to live. It now only forwards to the new box, and only for
  /// as long as phones still have this address saved.
  static const _retiredServers = {'https://158-69-192-169.nip.io'};

  static const _kServer = 'muse.server';
  static const _kToken = 'muse.token';
  static const _kCoverStyle = 'muse.coverStyle';
  static const _kPalette = 'muse.palette';
  static const _kHalftone = 'muse.halftone';
  static const _kSpectrum = 'muse.spectrum';
  static const _kCoverScale = 'muse.coverScale';
  static const _kArmStyle = 'muse.armStyle';
  static const _kDiscScale = 'muse.discScale';
  static const _kDiscLabel = 'muse.discLabel';
  static const _kHaptics = 'muse.haptics';
  static const _kLayout = 'muse.playerLayout';
  static const _kShelfAxis = 'muse.shelfAxis';
  static const _kJamListening = 'muse.jamListening';
  static const _kLastQueue = 'muse.lastQueue';
  static const _kVolume = 'muse.volume';
  static const _kHomeTab = 'muse.homeTab';
  static const _kDeskDock = 'muse.deskDock';

  /// The queue that was on when the app was last closed, so opening it again lands
  /// there rather than on whichever queue happens to be first in the list.
  int? _lastQueueId;

  /// Where the volume was before it was muted, so unmuting puts it back rather than
  /// to full.
  double _volumeBeforeMute = 1.0;

  /// The listener's volume, kept across launches. The web build has no hardware
  /// volume to fall back on, so forgetting it meant every visit started at full.
  double _volume = 1.0;
  Timer? _volumeWrite;

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

  /// Which tonearm is drawn on the deck, or none at all.
  ArmStyle armStyle = ArmStyle.studio;

  /// How wide the record on the deck is drawn, as a fraction of the room there is.
  double discScale = 1.0;

  /// How much of the record's face the artwork covers, from a small paper label to a
  /// picture disc. Drawn by the server, so it travels in the URL — see
  /// ApiClient.discLabel.
  double discLabel = 0.31;

  /// Whether the phone answers a finger with a tick. On where there is a motor.
  bool haptics = true;

  Future<void> setHaptics(bool on) async {
    haptics = on;
    Haptics.enabled = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHaptics, on);
  }

  Future<void> setDiscScale(double value) async {
    discScale = value.clamp(0.6, 1.15);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDiscScale, discScale);
  }

  Future<void> setDiscLabel(double value) async {
    discLabel = value.clamp(0.18, 0.92);
    api.discLabel = discLabel;
    // Every record on screen is a different picture now, including the one turning.
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDiscLabel, discLabel);
  }

  Future<void> setArmStyle(ArmStyle value) async {
    armStyle = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kArmStyle, value.name);
  }

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

  /// The back of whatever record is turned over, and what is written on it.
  ///
  /// Its own notifier: a line being drawn moves with the finger, and the rest of the
  /// app has no business rebuilding sixty times a second for it.
  late final SleeveBoard sleeveBoard = SleeveBoard(api);

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
    await ArtCache.open();
    await PlaybackLog.load();
    // First line after a restart. If the one before it is not a goodbye, the process
    // did not choose to stop — it was killed, which is a different fault entirely.
    PlaybackLog.note('--- app started');
    unawaited(PlaybackLog.askWhyItDied());
    unawaited(checkTheBackgroundIsAllowed());
    final prefs = await SharedPreferences.getInstance();
    coverStyle = CoverStyle.values.firstWhere(
        (s) => s.name == prefs.getString(_kCoverStyle),
        orElse: () => CoverStyle.record);
    palette = Palette.byId(prefs.getString(_kPalette));
    // On by default on a phone, off by default in a browser: it is a field of dots
    // repainted across the whole screen for as long as the player is open, and a
    // browser pays for that twice — once to draw it and once to composite it. Anybody
    // who wants it can turn it on, and their choice is what is read back here.
    halftone = prefs.getBool(_kHalftone) ?? !kIsWeb;
    spectrum = prefs.getBool(_kSpectrum) ?? false;
    homeTab = (prefs.getInt(_kHomeTab) ?? 0).clamp(0, 3);
    deskDock = prefs.getBool(_kDeskDock) ?? true;
    coverScale = (prefs.getDouble(_kCoverScale) ?? 0.74).clamp(0.5, 1.0);
    discScale = (prefs.getDouble(_kDiscScale) ?? 1.0).clamp(0.6, 1.15);
    discLabel = (prefs.getDouble(_kDiscLabel) ?? 0.31).clamp(0.18, 0.92);
    haptics = prefs.getBool(_kHaptics) ?? true;
    Haptics.enabled = haptics;
    armStyle = ArmStyle.values.firstWhere(
        (a) => a.name == prefs.getString(_kArmStyle),
        orElse: () => ArmStyle.studio);
    playerLayout = PlayerLayout.values.firstWhere(
        (l) => l.name == prefs.getString(_kLayout),
        orElse: () => PlayerLayout.grouped);
    shelfAxis = ShelfAxis.values.firstWhere(
        (a) => a.name == prefs.getString(_kShelfAxis),
        orElse: () => ShelfAxis.sideways);
    jamListening = prefs.getBool(_kJamListening) ?? false;
    _lastQueueId = prefs.getInt(_kLastQueue);
    _volume = (prefs.getDouble(_kVolume) ?? 1.0).clamp(0.0, 1.0);
    // The address saved at sign-in outlives the build that saved it, so a phone that
    // signed in before the server moved would keep calling the old box after updating.
    // The accounts and tokens moved with the database, so it is simply pointed at the
    // address this build was made for — the session carries on without a sign-in.
    var server = prefs.getString(_kServer);
    if (server != null && _retiredServers.contains(server) &&
        defaultServer.startsWith('https://') && defaultServer != server) {
      server = defaultServer;
      await prefs.setString(_kServer, server);
    }
    api = ApiClient(
      // Served from the box itself on web, so the page's own origin is the server —
      // no one should have to type a URL into a page they loaded from that URL.
      baseUrl: server ?? defaultServer,
      token: prefs.getString(_kToken),
    );
    // After the client exists, not before: every setting read above is a plain field
    // on this object, and this one is the single setting that has to reach the client
    // as well. Set a dozen lines earlier it was read off a `late` field that nothing
    // had assigned yet, which is not a wrong picture — it is a crash before the first
    // frame, and a white page.
    api.discLabel = discLabel;
    if (api.token != null) {
      try {
        final me = await api.me();
        user = me['user'] as String?;
        userId = me['user_id'] as int?;
        score = (me['score'] ?? 0) as int;
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

  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  /// A server address as somebody types it, as something the app can call.
  ///
  /// "wetowl.example" with no scheme used to be taken literally, and the answer was
  /// "Cannot reach wetowl.example" — true, and no help. A public server is https; a
  /// machine on the same network, where nobody has a certificate, is http.
  static String normaliseServer(String typed) {
    var s = typed.trim().replaceAll(RegExp(r'/+$'), '');
    if (s.isEmpty) return defaultServer;
    if (!s.contains('://')) {
      final local = RegExp(r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')
          .hasMatch(s);
      s = '${local ? 'http' : 'https'}://$s';
    }
    return s;
  }

  Future<bool> login(String server, String username, String password) async {
    error = null;
    try {
      api.baseUrl = normaliseServer(server);
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
      api.baseUrl = normaliseServer(server);
      await api.redeemInvite(code.trim(), username.trim(), password, 'flutter');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kServer, api.baseUrl);
      await prefs.setString(_kToken, api.token!);
      user = username.trim();
      final me = await api.me();
      userId = me['user_id'] as int?;
      score = (me['score'] ?? 0) as int;
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
    player ??= PlayerService(api)..userVolume = _volume;
    watchWhatThePhoneSaid();
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
    // Removed first: signing out and back in runs this again, and a second listener
    // is every change to the kept music announced twice.
    offline
      ..removeListener(notifyListeners)
      ..addListener(notifyListeners);
    _lifecycle;                     // built lazily; touching it starts it listening
    bindPlayer();
    await api.ensureStreamKey();
    // All at once. These four ask the server four unrelated questions and used to ask
    // them one after another, so opening the app was five round trips of waiting
    // before the first screen had anything on it — a second of nothing on a phone
    // away from wifi.
    //
    // A jam survives closing the app: picking it back up is how the same person on
    // two devices stays in the same room.
    // The tab's icon, and the one a home screen keeps. Asked for rather than shipped,
    // so an admin changing it changes it everywhere.
    unawaited(_wearTheIcon());
    final status = _pollStatus();
    final library = refresh();
    final hearts = refreshFavourites();
    final room = refreshJam();
    // Status first of the four, because sleeve URLs carry the renderer's version and
    // a first pass at the wrong one is a screen's worth of artwork fetched twice.
    // Started with the others, waited for before anything is drawn.
    await status;
    await Future.wait([library, hearts, room]);
    await followJamQueue();
    _listenForEvents();
    _statusTimer?.cancel();
    _queueReload?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pollStatus());
    // The room's heartbeat. Five seconds is short enough that nobody drifts audibly
    // within a song and long enough to be nothing on a phone's battery; it costs
    // nothing at all when this device is not hosting a jam.
    _jamTimer?.cancel();
    _jamTimer = Timer.periodic(const Duration(seconds: 5), (_) => pushJamState());
  }

  /// Sign out, and take the session's state with it.
  ///
  /// Only the token used to go. The player kept the old account's queue loaded, the
  /// status and jam timers kept polling with no token, and signing in as somebody else
  /// found `activeQueue` already set — so the new account was shown, and played, the
  /// previous one's queue.
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kLastQueue);
    _events?.cancel();
    _events = null;
    _statusTimer?.cancel();
    _jamTimer?.cancel();
    _queueReload?.cancel();
    _playerSub?.cancel();
    _playerSub = null;
    setSleepTimer(null);

    final old = player;
    player = null;
    if (old != null) {
      // No cursor write on the way out: there is no token to write it with.
      old.onCursor = null;
      old.onScore = null;
      await old.pause();
      await old.dispose();
    }

    api.token = null;
    user = null;
    userId = null;
    score = 0;
    avatarVersion = null;
    queues = const [];
    activeQueue = null;
    playlists = const [];
    favourites = <int>{};
    favouritesPlaylistId = null;
    jam = null;
    jamPosition = null;
    roomIsPlaying = false;
    _jamPositionAt = null;
    downloadsPending = 0;
    ingestOnline = true;
    _prioritised = null;
    _lastQueueId = null;
    _describeForTheOs(null);
    notifyListeners();
  }

  Future<void> refresh() async {
    // Two questions, one wait: neither answer depends on the other.
    final asked = api.queues();
    final lists = api.playlists();
    queues = await asked;
    playlists = await lists;
    if (activeQueue == null && queues.isNotEmpty) {
      // The one that was on last time, if it is still there; otherwise the first.
      final remembered = _lastQueueId;
      final pick = queues.firstWhere((q) => q.id == remembered,
          orElse: () => queues.first);
      await openQueue(pick.id, autoplay: false);
    }
    notifyListeners();
  }

  /// Which queue to come back to. Written when the listener chooses one, not on every
  /// update to it — following a jam into somebody else's queue is not choosing it.
  void _rememberQueue(int id) {
    if (_lastQueueId == id) return;
    _lastQueueId = id;
    unawaited(SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt(_kLastQueue, id)));
  }

  /// Put a queue on.
  ///
  /// [autoplay] left unsaid means "keep doing what you were doing": tapping another
  /// queue while music is playing used to load it and stop, so looking at your Gym
  /// queue for a moment silenced whatever was on. Each queue keeps its own place, so
  /// switching with music playing now resumes the other queue from where it was.
  Future<void> openQueue(int id, {bool? autoplay}) async {
    final wasPlaying = player?.last?.playing ?? false;
    final switching = activeQueue?.id != id;
    activeQueue = await api.queue(id);
    if (activeQueue?.sharedFrom == null) _rememberQueue(id);
    await player?.loadQueue(activeQueue!,
        autoplay: autoplay ?? (switching && wasPlaying));
    // Hosting a jam means the room is whatever queue is on. Putting a different one
    // on and leaving the room pointed at the old one is the host listening alone
    // while everybody else watches a list nobody is playing.
    final room = jam;
    if (room != null && room.isHost && room.queueId != id) {
      try {
        jam = await api.moveJam(room.id, id);
      } catch (_) {
        // The room not following is not a reason for the queue not to open here.
      }
    }
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
  Future<void> addTrack(Track t, {String mode = 'end'}) => addTracks([t], mode: mode);

  /// Add several at once, in this order, as one request.
  ///
  /// "Add all to queue" on a playlist used to be one request per song, each one
  /// followed by re-reading every queue and reloading the player: two hundred songs
  /// was four hundred round trips and a list that flickered for the whole of it.
  Future<void> addTracks(List<Track> tracks, {String mode = 'end'}) async {
    if (tracks.isEmpty) return;
    activeQueue ??= await ensureQueue('Now');
    activeQueue = await api.addToQueue(
        activeQueue!.id, [for (final t in tracks) t.id], mode: mode);
    queues = await api.queues();      // a queue created just now must show in the chips
    await player?.loadQueue(activeQueue!);
    _rememberQueue(activeQueue!.id);
    notifyListeners();
  }

  /// Put this song on and play it, keeping the rest of the queue.
  ///
  /// The one thing you could not do to a song from a list: "play next" put it after
  /// the current one, "play" on a record wrote over the queue. This is what tapping
  /// a song in a search or a history means — hear it now, lose nothing.
  Future<void> playTrackNow(Track t) async {
    await addTracks([t], mode: 'next');
    // A guest's transport asks the room; putting it on next is as far as a guest
    // goes on their own.
    if (jamControlsTheRoom) return;
    await playAdded(t, mode: 'next');
  }

  /// Play a song that has just been added, without skipping what was queued before it.
  ///
  /// The copy that was added is brought up to sit straight after the song playing and
  /// played there. Jumping to wherever it had landed instead — the end of the queue,
  /// or behind three songs somebody had already put on next — moved playback past
  /// everything in between, and those songs quietly became history.
  Future<void> playAdded(Track t, {String mode = 'end'}) async {
    final p = player;
    final q = activeQueue;
    if (p == null || q == null || jamControlsTheRoom) return;
    final here = p.whereInQueue;
    final landed = whereItLanded(q, t.id, mode: mode, after: here);
    if (landed == null) return;
    final to = math.min(here + 1, q.total - 1);
    var updated = q;
    if (landed != to) {
      try {
        updated = await api.moveQueueItem(q.id, landed, to);
        await _applyQueue(updated);
      } catch (_) {
        await _resyncQueue();
        return;
      }
    }
    await p.playTrack(t.id, indexHint: to - updated.windowFrom);
    await pushJamState(force: true);
  }

  /// Where, in the whole queue, the copy of [trackId] just added with [mode] sits.
  ///
  /// Appended is the last row, whether or not the slice held here reaches that far.
  /// Put on next is the first copy after the song playing — behind any others that
  /// were put on next before it.
  @visibleForTesting
  static int? whereItLanded(Queue q, int trackId,
      {required String mode, required int after}) {
    if (q.total == 0) return null;
    if (mode != 'next') {
      // The last copy, where the slice held here reaches the end of the queue — so a
      // song appended by somebody else a moment later is not the one moved. Where it
      // does not reach, the last row is all that can be said.
      if (q.windowFrom + q.items.length < q.total) return q.total - 1;
      for (var i = q.items.length - 1; i >= 0; i--) {
        if (q.items[i].id == trackId) return q.windowFrom + i;
      }
      return null;
    }
    for (var i = math.max(0, after + 1 - q.windowFrom); i < q.items.length; i++) {
      if (q.items[i].id == trackId) return q.windowFrom + i;
    }
    return null;
  }

  /// A row already in the queue, put on after the song playing — which is what "play
  /// next" means for a song that is already there, rather than a second copy of it.
  Future<void> playNextFromQueue(int pos) async {
    final p = player;
    if (p == null) return;
    final here = p.index;
    if (pos == here) return;
    // `to` counts the list with the row already lifted out of it, the way a drag
    // does: above the song playing, lifting it moves that song up by one.
    await moveInQueue(pos, pos > here ? here + 1 : here);
  }

  /// Give a queue a new name.
  Future<void> renameQueue(int id, String name) async {
    final updated = await api.updateQueueSettings(id, name: name);
    queues = await api.queues();
    if (activeQueue?.id == id) await _applyQueue(updated);
    notifyListeners();
  }

  /// The listener's own volume, kept for next time.
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    if (_volume > 0) _volumeBeforeMute = _volume;
    await player?.setUserVolume(_volume);
    notifyListeners();
    // A slider fires many times a second; the disk hears about it once it settles.
    _volumeWrite?.cancel();
    _volumeWrite = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kVolume, _volume);
    });
  }

  /// Silence, and back to where it was — not to full.
  Future<void> toggleMute() async {
    final now = player?.userVolume ?? _volume;
    if (now > 0) {
      _volumeBeforeMute = now;
      await setVolume(0);
    } else {
      await setVolume(_volumeBeforeMute <= 0 ? 1.0 : _volumeBeforeMute);
    }
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
    // Dealt here first so the list moves at once, then the same deal is sent up — the
    // server used to deal its own and the rows reshuffled again when it answered.
    final order = player?.shuffleWhatIsComing();
    if (order == null) return;                      // nothing worth rearranging
    notifyListeners();
    try {
      await _applyQueue(await api.shuffleQueue(q.id, order: order));
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

  /// The queue that has been selected, so its songs are not asked for twice.
  int? _prioritised;

  Future<void> _applyQueue(Queue updated) async {
    final changed = activeQueue?.id != updated.id;
    activeQueue = updated;
    await player?.loadQueue(updated);
    notifyListeners();
    unawaited(_keepTheseCovers(updated));
    // Once per queue, when it becomes the one being listened to. Its songs go ahead of
    // any import waiting in the download queue — the first three were already moved up
    // by pressing play, which is right for the song about to be heard and no use at
    // all for the forty after it.
    if (changed || _prioritised != updated.id) {
      _prioritised = updated.id;
      unawaited(api.prioritiseQueue(updated.id).catchError((_) => 0));
    }
  }

  /// Put the covers of a queue on the device, once, in the background.
  ///
  /// A queue is the one list you are certain to scroll: it is what you chose to
  /// listen to. Fetching its artwork now — quietly, four at a time, behind whatever is
  /// streaming — is the difference between a list of grey squares filling in as you
  /// scroll and one that is simply there, including the next time the app is opened
  /// with no signal at all.
  Future<void> _keepTheseCovers(Queue queue) async {
    if (!ArtCache.supported) return;
    final small = <String>[];
    final large = <String>[];
    for (final t in queue.items) {
      final row = api.coverUrl(t, small: true);
      if (row != null) small.add(row);
    }
    // The one being played, and its neighbours, at full size — those are the ones the
    // player itself draws large.
    final at = player?.index ?? 0;
    for (var i = at - 1; i <= at + 2; i++) {
      if (i < 0 || i >= queue.items.length) continue;
      for (final url in [
        api.coverUrl(queue.items[i], small: false),
        api.jacketUrl(queue.items[i]),
        api.discUrl(queue.items[i]),
      ]) {
        if (url != null) large.add(url);
      }
    }
    await ArtCache.warm(large, limit: 12);
    await ArtCache.warm(small);
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
    // [pos] counts rows on screen; the server counts the whole queue. In a queue long
    // enough to arrive a slice at a time the two differ, and sending the first took
    // out a song six hundred rows above the one that was swiped.
    final row = (player?.windowFrom ?? 0) + pos;
    // Gone from the list at once — see moveInQueue for why.
    player?.removeLocally(pos);
    notifyListeners();
    try {
      await _applyQueue(await api.removeQueueItem(q.id, row));
    } catch (_) {
      await _resyncQueue();
      return;
    }
    if (context == null || removed == null || !context.mounted) return;

    ScaffoldMessenger.of(context).say(snack(Text('Removed ${removed.displayTitle}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _restoreToQueue(q.id, removed.id, row),
      ),
    ));
  }

  /// [row] is counted in the whole queue.
  Future<void> _restoreToQueue(int queueId, int trackId, int row) async {
    try {
      var updated = await api.addToQueue(queueId, [trackId]);
      // It goes back on the end, so walk it home to where it was. The end of the
      // whole queue, not of the slice held here.
      final landedAt = updated.total - 1;
      if (landedAt != row && row < updated.total) {
        updated = await api.moveQueueItem(queueId, landedAt, row);
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
    final offset = player?.windowFrom ?? 0;
    player?.moveLocally(from, to);
    notifyListeners();
    try {
      await _applyQueue(await api.moveQueueItem(q.id, offset + from, offset + to));
    } catch (_) {
      await _resyncQueue();
    }
  }

  /// Move a whole selection to one place, as one edit.
  Future<void> moveManyInQueue(List<int> froms, int to) async {
    final q = activeQueue;
    if (q == null || froms.isEmpty) return;
    final offset = player?.windowFrom ?? 0;
    player?.moveManyLocally(froms, to);
    notifyListeners();
    try {
      await _applyQueue(await api.moveQueueItems(
          q.id, [for (final f in froms) offset + f], offset + to));
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
        await openQueue(next.id, autoplay: false);
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
    ScaffoldMessenger.of(context).say(snack(Text(origin == 'radio'
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
  /// Have another go at a song that failed.
  ///
  /// Through the download queue, not through YouTube. This used to hand the track's
  /// provider id to the YouTube resolver whatever the track was — so retrying a
  /// SoundCloud song asked YouTube for a SoundCloud id, and either found nothing or
  /// invented a YouTube track out of it. The server knows every place a song lives and
  /// which of them it can reach; asking it is the whole job.
  Future<bool> retry(Track track) => fetchNow(track);

  /// Fetch this one now, for a song that is listed but has no file behind it.
  ///
  /// A mirrored library records far more than it downloads, so most songs sit like
  /// this until something asks for them. Pressing play asks; so does this.
  Future<bool> fetchNow(Track track) async {
    final started = await api.promoteDownload(track.id);
    final q = activeQueue;
    if (q != null) await _applyQueue(await api.queue(q.id));
    return started > 0;
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
    _rememberQueue(filled.id);
    await player?.loadQueue(filled);
    final at = shuffle ? 0 : startAt.clamp(0, ordered.length - 1);
    await player?.playTrack(ordered[at].id, indexHint: at);
    notifyListeners();
  }

  /// Put something on and keep playing what belongs next to it.
  ///
  /// A station of its own rather than a tail on the end of what was playing: that is
  /// the difference between "add five more" and "put this on", and it is why it can
  /// be named, kept, and saved to the library afterwards.
  Future<void> startStation(
      {String kind = 'track', Track? seed, String? album, String? artist}) async {
    final made = await api.startStation(
        kind: kind, trackId: seed?.id, album: album, artist: artist);
    activeQueue = made;
    queues = await api.queues();
    _rememberQueue(made.id);
    await player?.loadQueue(made, autoplay: false);
    if (made.items.isNotEmpty) {
      await player?.playTrack(made.items.first.id, indexHint: 0);
    }
    notifyListeners();
  }

  /// How close to the edge of the slice we hold is close enough to ask for the next.
  static const queueEdge = 60;

  DateTime? _recentred;
  bool _recentring = false;

  /// Fetch the part of a long queue around where the listener actually is.
  ///
  /// A queue of fourteen thousand songs is not sent whole — see Queue.windowed — so
  /// playing towards the end of what we were given has to ask for the next few
  /// hundred rows. Everything else about the queue keeps working: the player
  /// recognises the song it is on inside the new slice and carries on from it.
  Future<void> keepUpWithTheQueue() async {
    final q = activeQueue;
    final player = this.player;
    if (q == null || player == null || !q.windowed || _recentring) return;
    final within = player.index;
    final held = player.items.length;
    final atStart = q.windowFrom > 0 && within < queueEdge;
    final atEnd = q.windowFrom + held < q.total && within > held - queueEdge;
    if (!atStart && !atEnd) return;
    final now = DateTime.now();
    if (_recentred != null && now.difference(_recentred!) < const Duration(seconds: 5)) {
      return;
    }
    _recentring = true;
    _recentred = now;
    try {
      final slice = await api.queue(q.id, around: player.whereInQueue);
      activeQueue = slice;
      await player.loadQueue(slice);
      notifyListeners();
    } catch (_) {
      // No signal: the queue stays as it is, which is still several hundred songs.
    } finally {
      _recentring = false;
    }
  }

  /// When it was last topped up, so a queue that is nearly finished is not asked for
  /// more of itself twice a second.
  DateTime? _toppedUp;
  bool _toppingUp = false;

  /// How close to the end of a station is close enough to ask for more.
  static const stationTail = 3;

  /// Keep the station going.
  ///
  /// A station is endless from where somebody is standing and finite on the disk: it
  /// is topped up a handful at a time as it is listened through, so one left running
  /// for an hour costs an hour of downloads and one abandoned after two songs costs
  /// almost nothing.
  Future<void> topUpStation() async {
    final q = activeQueue;
    final player = this.player;
    if (q == null || !q.isStation || player == null || _toppingUp) return;
    if (player.items.length - player.index > stationTail) return;
    final now = DateTime.now();
    if (_toppedUp != null && now.difference(_toppedUp!) < const Duration(seconds: 20)) {
      return;
    }
    _toppingUp = true;
    _toppedUp = now;
    try {
      final grown = await api.extendStation(q.id);
      activeQueue = grown;
      await player.loadQueue(grown);
      notifyListeners();
    } catch (_) {
      // No signal, or nothing left to find. The station simply ends where it is.
    } finally {
      _toppingUp = false;
    }
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
      // The clock the screen runs on, kept up to date even though the speaker is not:
      // the record still turns, the bar still moves, the button still says pause.
      jamPosition = state.position;
      _jamPositionAt = DateTime.now();
      roomIsPlaying = state.playing;
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
  /// Whether the room is playing, as last reported by the host.
  bool roomIsPlaying = false;

  /// What this screen should say is happening.
  ///
  /// A guest who is not playing the music on this device is still *in* the room, and
  /// the room is playing: the bar should move, the record should turn, the printed
  /// background should breathe and the button should say pause. Everything on that
  /// screen is about the music, and the music is happening — it is simply coming out
  /// of somebody else's speaker. Reading the local engine there showed a stopped
  /// player to somebody who could hear the song.
  bool get musicIsPlaying {
    if (isJamGuest && !jamListening) return roomIsPlaying;
    return player?.last?.playing ?? false;
  }

  /// Where the music is, wherever it is playing from.
  ///
  /// The host's clock for a guest listening to the room, and this device's own for
  /// everybody else — including a guest who has turned their own speaker on, whose
  /// engine is the thing making the sound they can hear.
  Duration? get positionNow {
    if (isJamGuest && !jamListening) return hostPosition;
    return player?.last?.position;
  }

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
        roomIsPlaying = state.playing;
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
    } else if (!jam!.isHost) {
      // The host put something else on. Following the room means following what the
      // room is playing, which is now a different queue from the one on screen — and
      // before this a guest kept the old one for as long as the jam lasted, watching a
      // list nobody was playing.
      await followJamQueue();
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
      roomIsPlaying = state.playing;
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
    roomIsPlaying = false;
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

  /// Download progress, folded into one report every 250ms — see [Coalesce].
  late final Coalesce _progressed =
      Coalesce(const Duration(milliseconds: 250), () {
    if (!_disposed) notifyListeners();
  });

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
        //
        // And tell the screens at most four times a second. Six downloads running at
        // once is twenty reports a second, and every one of them rebuilt the bar at
        // the bottom of the page, the queue and every row in view — the app was at
        // its slowest exactly while it was fetching music, which is when somebody is
        // most likely to be looking at it.
        final id = e.data['track_id'] as int?;
        if (id != null) {
          player?.applyProgress(id, Map<String, dynamic>.from(e.data));
          _progressed();
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
      } else if (e.event == 'sleeve_mark') {
        // Somebody drawing on the record in front of you, as they draw it.
        sleeveBoard.arrived(Map<String, dynamic>.from(e.data));
      } else if (e.event == 'sleeve_erase') {
        sleeveBoard.erased(Map<String, dynamic>.from(e.data));
      } else if (e.event == 'sleeve_wiped') {
        sleeveBoard.wiped(Map<String, dynamic>.from(e.data));
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
  void _describeForTheOs(Track? track, {bool? playing}) {
    SystemChrome.setApplicationSwitcherDescription(ApplicationSwitcherDescription(
      label: track == null ? 'WetOwl' : '${track.displayTitle} · ${track.artistLine}',
      primaryColor: 0xFF121212,
    ));
    if (track == null) {
      nothingIsPlaying();
      return;
    }
    // And the browser, which has no other way of knowing. On iOS this is the
    // difference between a page that happens to be playing a sound and a media app:
    // the first has its work suspended when it is switched away from, so nothing runs
    // to start the next song and a queue plays exactly one record.
    describeToTheBrowser(
      title: track.displayTitle,
      artist: track.artistLine,
      album: track.albumLine ?? '',
      artwork: api.coverUrl(track, small: false),
      playing: playing ?? (player?.last?.playing ?? false),
      onPlay: playPause,
      onPause: playPause,
      onNext: skipNext,
      onPrevious: skipPrevious,
    );
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
    player?.onScore = (n) {
      if (n == score) return;
      score = n;
      notifyListeners();
    };
    int? named;
    bool? wasPlaying;
    String? shape;
    _playerSub = player?.snapshots.listen((s) {
      final trackChanged = named != null && s.current?.id != named;
      _watchForEndOfTrack(s, trackChanged: trackChanged);
      if (s.current?.id != named || s.playing != wasPlaying) {
        named = s.current?.id;
        wasPlaying = s.playing;
        // Also on play and pause: a lockscreen showing a play button on something that
        // is playing is worse than no lockscreen control at all.
        _describeForTheOs(s.current, playing: s.playing);
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
      // A station is asked for more as it is listened through, not once at the start.
      unawaited(topUpStation());
      // And a long queue is carried a few hundred rows at a time; walking towards the
      // edge of what we have asks for the next few hundred.
      unawaited(keepUpWithTheQueue());
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
      // Somebody may have just come back from the settings page having turned it on.
      unawaited(checkTheBackgroundIsAllowed());
      unawaited(player?.resumeIfStopped());
      unawaited(refreshJam());
      // And say what happened while nobody was looking — see sendPlaybackLog.
      unawaited(_sendTheLog());
    },
    // The other end of the interesting gap: everything between this line and the next
    // "app in front" happened with nobody watching, which is exactly the stretch a
    // report of "it stops when I switch away" is about.
    // One of these, not both: onHide and onPause both fire on the way out, and wiring
    // the same thing to each wrote every line in the log twice.
    onHide: _travelLight,
    onDetach: () => PlaybackLog.note('app being torn down'),
  );

  Future<void> _wearTheIcon() async {
    if (!kIsWeb) return;
    try {
      final icon = await api.appIcon();
      wearTheIcon(api.appIconUrl(size: 64, version: icon.version),
          api.appIconUrl(size: 180, version: icon.version));
    } catch (_) {
      // An older server, or no answer. The icon in the page stays as it was.
    }
  }

  /// Whether Android will stop the music the moment this app leaves the screen.
  ///
  /// True when the system will not let the app show its playing notification, which is
  /// the same thing as saying it cannot run a foreground service — see
  /// [Keepalive.allowedToShowThePlayer]. Worth a line on the screen, because it is a
  /// setting on the phone and nothing this app does can work around it.
  bool musicWillStopInTheBackground = false;

  /// Set on the player as soon as there is one, so the first play's answer comes back.
  void watchWhatThePhoneSaid() {
    player?.onNotificationAnswer = checkTheBackgroundIsAllowed;
  }

  Future<void> checkTheBackgroundIsAllowed() async {
    final allowed = await Keepalive.allowedToShowThePlayer();
    if (_disposed) return;
    if (musicWillStopInTheBackground == !allowed) return;
    musicWillStopInTheBackground = !allowed;
    notifyListeners();
  }

  /// When the log was last sent up, so coming back to the app forty times in an hour
  /// is not forty reports of the same minute.
  DateTime? _loggedAt;

  Future<void> _sendTheLog() async {
    if (user == null) return;
    final now = DateTime.now();
    if (_loggedAt != null && now.difference(_loggedAt!) < const Duration(minutes: 10)) {
      return;
    }
    _loggedAt = now;
    try {
      await api.sendPlaybackLog(PlaybackLog.lines,
          device: platformName(), build: appBuild);
    } catch (_) {
      // A log that cannot be sent is not worth a word on screen.
    }
  }

  /// Give back the memory nobody is looking at.
  ///
  /// A backgrounded app that is only playing audio is competing for room with whatever
  /// is in front of it, and the largest thing this one holds is decoded artwork —
  /// Flutter keeps up to a hundred megabytes of it, and the record stage alone has four
  /// full-size sleeves and their discs in hand. None of that is on screen while the
  /// screen is off, and every megabyte of it makes the process a better candidate for
  /// the low-memory killer, which is the one way music stops that no amount of watching
  /// the audio engine will catch.
  ///
  /// Nothing is lost: the artwork is on the disk now, so coming back reads it from
  /// there rather than from the server.
  void _travelLight() {
    PlaybackLog.note('app out of sight');
    // The one moment the answer matters: is anything holding this app up now that
    // nobody is looking at it.
    unawaited(PlaybackLog.checkTheService());
    final cache = PaintingBinding.instance.imageCache;
    final held = cache.currentSizeBytes ~/ (1024 * 1024);
    cache.clear();
    cache.clearLiveImages();
    if (held > 0) PlaybackLog.note('gave back ${held}MB of artwork');
  }

  Future<void> _pollStatus() async {
    if (_disposed) return;
    try {
      final s = await api.status();
      ingestOnline = (s['ingest_online'] ?? false) as bool;
      downloadsPending = (s['downloads_pending'] ?? 0) as int;
      // Put in every sleeve URL, so a change to how records are drawn reaches a
      // browser and this device's own store rather than sitting behind a year-long
      // immutable cache. See ApiClient.sleeveVersion.
      api.sleeveVersion = (s['sleeve_version'] ?? 0) as int;
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
    _progressed.dispose();
    _statusTimer?.cancel();
    _jamTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _sleepFadeStep?.cancel();
    _volumeWrite?.cancel();
    _lifecycle.dispose();
    sleeveBoard.dispose();
    _events?.cancel();
    _playerSub?.cancel();
    _events?.cancel();
    player?.dispose();
    super.dispose();
  }
}
