import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/connection.dart';
import '../api/models.dart';
import 'eq_engines.dart';
import 'equalizer.dart';
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
/// Where each tab is. Named, because they move: Home was put in front of the others,
/// and every tab number written out by hand was a number that then meant the wrong tab.
abstract final class Tabs {
  static const home = 0;
  static const queue = 1;
  static const search = 2;
  static const library = 3;
  static const people = 4;
  static const count = 5;
}

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
  int homeTab = Tabs.home;

  /// Whether the column beside the page — what is playing, what is next — is folded
  /// out. Only ever asked on a screen wide enough to have one.
  bool deskDock = true;

  /// On a desk, your library down the side rather than a rail of four icons.
  bool sidebar = true;

  /// How wide the column beside the page is, and how wide the library's own list is.
  /// Both are lines somebody can pull, and both are remembered — a width is a thing
  /// you set once and then want left alone.
  double dockWidth = 420;
  double paneWidth = 330;

  void setDockWidth(double v, {bool remember = false}) {
    dockWidth = v.clamp(320, 640);
    notifyListeners();
    if (remember) {
      SharedPreferences.getInstance()
          .then((p) => p.setDouble(_kDockWidth, dockWidth))
          .catchError((_) => false);
    }
  }

  void toggleSidebar() {
    sidebar = !sidebar;
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_kSidebar, sidebar))
        .catchError((_) => false);
    notifyListeners();
  }

  void setPaneWidth(double v, {bool remember = false}) {
    paneWidth = v.clamp(240, 560);
    notifyListeners();
    if (remember) {
      SharedPreferences.getInstance()
          .then((p) => p.setDouble(_kPaneWidth, paneWidth))
          .catchError((_) => false);
    }
  }

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
  static const _kUser = 'muse.user';
  static const _kUserId = 'muse.userId';
  static const _kToken = 'muse.token';
  static const _kCoverStyle = 'muse.coverStyle';
  static const _kPalette = 'muse.palette';
  static const _kHalftone = 'muse.halftone';
  static const _kSeamless = 'muse.seamless';
  static const _kSpectrum = 'muse.spectrum';
  static const _kCoverScale = 'muse.coverScale';
  static const _kArmStyle = 'muse.armStyle';
  static const _kArmMoved = 'muse.armStyle.classic';
  static const _kDiscScale = 'muse.discScale';
  static const _kDiscLabel = 'muse.discLabel';
  static const _kHaptics = 'muse.haptics';
  static const _kLayout = 'muse.playerLayout';
  static const _kShelfAxis = 'muse.shelfAxis';
  static const _kJamListening = 'muse.jamListening';
  static const _kLastQueue = 'muse.lastQueue';
  static const _kVolume = 'muse.volume';
  // Moved each time the tabs did — Home put in front, Queues taken out into the
  // player, the queue put back in the bar — because every number an old key holds
  // means some other tab now.
  static const _kHomeTab = 'muse.homeTab.v4';
  static const _kHomeTabV3 = 'muse.homeTab.v3';
  static const _kDeskDock = 'muse.deskDock';
  static const _kSidebar = 'muse.sidebar';
  static const _kDockWidth = 'muse.dockWidth';
  static const _kPaneWidth = 'muse.paneWidth';

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
  Palette palette = Palette.red;

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
  ArmStyle armStyle = ArmStyle.classic;

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
      // From the room's clock as it stands now. What came with the jam when it was
      // last read is up to half a minute old, and joining there was joining the song
      // half a minute ago.
      if (hostPosition != null) {
        await _followTheRoomAgain();
      } else {
        final state = jam?.playback;
        if (state != null) await followJamPlayback(state);
      }
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

  /// Whether one song is played straight into the next, without the second or two of
  /// nothing most files have at either end. On unless somebody turns it off: the
  /// silence is an accident of how files are made, not part of the record.
  bool seamless = true;

  Future<void> setSeamless(bool on) async {
    seamless = on;
    player?.seamless = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSeamless, on);
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
    seamless = prefs.getBool(_kSeamless) ?? true;
    player?.seamless = seamless;
    spectrum = prefs.getBool(_kSpectrum) ?? false;
    // A phone that remembers a tab from before Home existed opens on Home, once:
    // it is the new thing, and the place the app now starts.
    // One step back from the last move: v3 was the same tabs without the queue
    // between Home and Search. Anything older opens on Home.
    final v3 = prefs.getInt(_kHomeTabV3);
    homeTab = (prefs.getInt(_kHomeTab) ??
            switch (v3) {
              1 => Tabs.search,
              2 => Tabs.library,
              3 => Tabs.people,
              _ => Tabs.home,
            })
        .clamp(0, Tabs.count - 1);
    deskDock = prefs.getBool(_kDeskDock) ?? true;
    sidebar = prefs.getBool(_kSidebar) ?? true;
    dockWidth = (prefs.getDouble(_kDockWidth) ?? 420).clamp(320, 640);
    paneWidth = (prefs.getDouble(_kPaneWidth) ?? 330).clamp(240, 560);
    coverScale = (prefs.getDouble(_kCoverScale) ?? 0.74).clamp(0.5, 1.0);
    discScale = (prefs.getDouble(_kDiscScale) ?? 1.0).clamp(0.6, 1.15);
    discLabel = (prefs.getDouble(_kDiscLabel) ?? 0.31).clamp(0.18, 0.92);
    haptics = prefs.getBool(_kHaptics) ?? true;
    Haptics.enabled = haptics;
    armStyle = ArmStyle.values.firstWhere(
        (a) => a.name == prefs.getString(_kArmStyle),
        orElse: () => ArmStyle.classic);
    // Studio was the default for as long as there was one, so a phone that says
    // studio almost certainly never chose it. Once, move those to the arm that can be
    // picked up; anybody who then picks studio again keeps it.
    if (armStyle == ArmStyle.studio && !(prefs.getBool(_kArmMoved) ?? false)) {
      armStyle = ArmStyle.classic;
      unawaited(prefs.setString(_kArmStyle, armStyle.name));
    }
    unawaited(prefs.setBool(_kArmMoved, true));
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
        await _signedInAs(await api.me(), prefs);
        await _afterLogin();
      } on ApiException {
        api.token = null; // revoked or a different server
      } catch (_) {
        // No answer at all: a plane, a tunnel, the box switched off. That used to be
        // the end of it — nothing caught this, `ready` was never set, and the app sat
        // on its loading screen for ever with a phone full of kept music behind it.
        // The token is still good as far as anybody knows, so this is the same
        // person, signed in, with whatever is on the device.
        user = prefs.getString(_kUser) ?? 'you';
        userId = prefs.getInt(_kUserId);
        await _startWithoutTheServer();
      }
    }
    ready = true;
    notifyListeners();
  }

  /// Who this is, as the server just said — and remembered, for a start with no
  /// server to ask.
  Future<void> _signedInAs(Map<String, dynamic> me, SharedPreferences prefs) async {
    user = me['user'] as String?;
    userId = me['user_id'] as int?;
    score = (me['score'] ?? 0) as int;
    avatarVersion = me['avatar_version'] as String?;
    if (user != null) await prefs.setString(_kUser, user!);
    if (userId != null) await prefs.setInt(_kUserId, userId!);
  }

  /// Started with no connection: the player and the kept music, and nothing that
  /// needs the box. See [backOnline] for the rest of the start, when it can happen.
  bool offlineSession = false;

  Future<void> _startWithoutTheServer() async {
    offlineSession = true;
    await _startThePlayer();
  }

  /// The connection is back. For a session that started without one, this is the rest
  /// of signing in; for any other, it is a refresh.
  Future<void> backOnline() async {
    if (!offlineSession) return refresh();
    final prefs = await SharedPreferences.getInstance();
    try {
      await _signedInAs(await api.me(), prefs);
    } on ApiException {
      // The token did not survive the time away. Signed out, properly.
      offlineSession = false;
      await logout();
      return;
    }
    offlineSession = false;
    await _afterLogin();
    notifyListeners();
  }

  /// A queue that exists only on this device: made offline, from kept songs. The
  /// server has never heard of it, so nothing about it is sent there.
  bool get _queueIsLocal => (activeQueue?.id ?? 0) < 0;

  /// Play these from the device, asking the server nothing.
  Future<void> _playFromTheDevice(List<Track> tracks,
      {required int startAt, required bool shuffle, String? named}) async {
    final first = tracks[startAt.clamp(0, tracks.length - 1)];
    var kept = [for (final t in tracks) if (offline.has(t.id)) t];
    if (kept.isEmpty) {
      throw ApiException(0, 'None of that is kept on this device, and the server '
          'cannot be reached.');
    }
    if (shuffle) kept = [...kept]..shuffle(math.Random());
    final local = Queue(
      id: -1,
      name: named ?? 'On this device',
      cursorIndex: 0,
      positionMs: 0,
      shuffle: false,
      repeat: 'off',
      rev: 1,
      items: kept,
    );
    activeQueue = local;
    await player?.loadQueue(local, autoplay: false);
    // The song that was tapped if it is here, the top of the list if it is not.
    final at = shuffle ? 0 : kept.indexWhere((t) => t.id == first.id);
    await player?.playTrack(kept[at < 0 ? 0 : at].id, indexHint: at < 0 ? 0 : at);
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
      await prefs.setString(_kUser, username);
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

  bool _playerStarted = false;

  /// The player and the kept music: everything about starting that needs no server.
  Future<void> _startThePlayer() async {
    if (_playerStarted && player != null) return;
    player ??= PlayerService(api)
      ..userVolume = _volume
      ..seamless = seamless;
    // The equalizer belongs to the player it shapes the sound of: started with it, from
    // whatever was kept, on whichever kind of equalizer this device has.
    unawaited(equalizer.start(eqEngineFor(
        equalizer: player!.androidEqualizer, loudness: player!.androidLoudness)));
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
    _playerStarted = true;
  }

  Future<void> _afterLogin() async {
    await _startThePlayer();
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
    // What this device is doing, for the others. Ten seconds while something is
    // playing; the report itself keeps quiet when nothing is.
    _deviceTimer?.cancel();
    _deviceTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => reportDevice());
    unawaited(refreshDevices());
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
    _playerStarted = false;
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
    // Queued again is wanted again: it is back in the library, so back in the lists.
    _removedTracks.removeAll([for (final t in tracks) t.id]);
    if (_queueIsLocal) activeQueue = null;
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
  ///
  /// A song that is still being fetched is the exception. Going to it at once would
  /// stop the music and leave silence until the download lands, so while something
  /// is on it waits its turn as the next song, and is put on the moment it can be
  /// played — unless whoever asked has moved on to something else by then.
  Future<void> playTrackNow(Track t) async {
    await addTracks([t], mode: 'next');
    // A guest's transport asks the room; putting it on next is as far as a guest
    // goes on their own.
    if (jamControlsTheRoom) return;
    final p = player;
    if (!t.isReady && p != null && p.isPlaying) {
      _wantedWhenReady = (track: t, during: p.current?.id);
      return;
    }
    _wantedWhenReady = null;
    await playAdded(t, mode: 'next');
  }

  /// The song somebody tapped while it was still being fetched, and what was on when
  /// they did.
  ({Track track, int? during})? _wantedWhenReady;

  Future<void> _playWhatWasWanted(int readyId, Future<void>? refreshed) async {
    final wanted = _wantedWhenReady;
    if (wanted == null || wanted.track.id != readyId) return;
    _wantedWhenReady = null;
    await refreshed;
    // Still on the song that was playing when they asked: nothing else was chosen
    // in the meantime, so this is still what they want to hear.
    if (player?.current?.id != wanted.during) return;
    await playAdded(wanted.track, mode: 'next');
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

  /// Put the covers of a list somebody just opened on the device, quietly.
  ///
  /// The queue has done this for a while — it is the list you are certain to scroll —
  /// and every other list filled in as you went: a screen of grey squares turning into
  /// covers one at a time, every time, because nothing had asked for them until they
  /// were on screen. A playlist somebody just opened is about to be scrolled too.
  void keepCoversFor(List<Track> tracks) {
    if (!ArtCache.supported || tracks.isEmpty) return;
    final small = <String>[];
    for (final t in tracks.take(80)) {
      final url = api.coverUrl(t, small: true);
      if (url != null) small.add(url);
    }
    // Not awaited and not reported: it is four at a time behind whatever is playing,
    // and if it does not finish the pictures arrive the old way.
    unawaited(ArtCache.warm(small));
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
  /// Songs taken out of the library this session. Every list draws its rows through
  /// SongRow, which asks here — so a removed song is gone from whatever is open, at
  /// once, without each of a dozen lists having to be told to fetch itself again.
  final Set<int> _removedTracks = <int>{};
  bool wasRemoved(int trackId) => _removedTracks.contains(trackId);

  /// Take songs out of the library: the wrong match, the one that was never wanted.
  ///
  /// The server takes them off this person's playlists and queues as well, and deletes
  /// outright whatever nobody else holds. Here: the kept copy on the device goes, the
  /// heart goes, and the queue is read again since it may just have lost rows.
  Future<({int removed, int deleted})> removeFromLibrary(List<int> trackIds) async {
    final done = await api.removeFromLibrary(trackIds);
    _removedTracks.addAll(trackIds);
    favourites.removeAll(trackIds);
    for (final id in trackIds) {
      await offline.forget(id);
    }
    notifyListeners();
    await _resyncQueue();
    unawaited(refreshPlaylists().catchError((_) {}));
    return done;
  }

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
    _removedTracks.removeAll([for (final t in tracks) t.id]);
    if (offlineSession || !serverIsThere.value) {
      return _playFromTheDevice(tracks, startAt: startAt, shuffle: shuffle, named: named);
    }
    // A queue made offline is this device's own; the server gets a real one.
    if (_queueIsLocal) activeQueue = null;
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

  /// The count on the last report sent as host, and on the last one heard as a guest.
  int _jamSeqOut = 0;
  int? _jamSeqIn;
  int? _clockIsFor;

  /// Which song the room is on and which row of the queue, as the host last said.
  int? _roomTrack;
  int? _roomRow;

  /// How long catching up takes on this device and this connection.
  ///
  /// A seek on a stream is not instant, and while it happens the room plays on: a guest
  /// sent to exactly where the host *was* arrives late by however long the seek took.
  /// When that was longer than the drift allowed, it was out of step again at once,
  /// sought again at the next chance, and never got there. So it aims ahead by what the
  /// last ones cost.
  Duration _catchUpCost = Duration.zero;

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
    final shape = '${snap?.current?.id}|${snap?.current?.queueItemId}|${snap?.playing}';
    final now = DateTime.now();
    // A little under the heartbeat's own five seconds: asked "has it been more than
    // five" by a timer that fires every five, the answer was no about half the time,
    // and the room heard from its host every ten.
    final due = _pushedAt == null ||
        now.difference(_pushedAt!) >= const Duration(seconds: 4);
    if (!force && shape == _pushedState && !due) return;
    _pushedState = shape;
    _pushedAt = now;
    // Counted, so that two of these overtaking each other on the way are put back in
    // order at the other end rather than played out as a skip backwards.
    final stamp = now.millisecondsSinceEpoch;
    _jamSeqOut = stamp > _jamSeqOut ? stamp : _jamSeqOut + 1;
    try {
      await api.pushJamPlayback(current.id,
          trackId: snap?.current?.id,
          itemId: snap?.current?.queueItemId,
          seq: _jamSeqOut,
          // The engine's position as this is sent, not the last one drawn: everybody
          // else carries it forward from the moment they hear it.
          positionMs: p.livePosition.inMilliseconds,
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

    // Another room has another host, whose count starts wherever it starts.
    if (_clockIsFor != jam?.id) {
      _clockIsFor = jam?.id;
      _jamSeqIn = null;
    }
    // Overtaken on the way: this is about where the room was, and something newer has
    // already been heard.
    final heard = _jamSeqIn;
    if (state.seq != null && heard != null && state.seq! < heard) return;
    _jamSeqIn = state.seq ?? heard;

    // The room's clock, which everything on screen reads and which is carried forward
    // from here until the host speaks again.
    jamPosition = state.position;
    _jamPositionAt = DateTime.now();
    roomIsPlaying = state.playing;
    _roomTrack = state.trackId;
    _roomRow = state.itemId;

    final onAnother = state.trackId != null &&
        (p.current?.id != state.trackId ||
            (state.itemId != null &&
                p.current?.queueItemId != null &&
                p.current?.queueItemId != state.itemId));

    // Following without listening: the screen keeps up with the room, the speaker
    // stays out of it. This is the normal case — everyone in one room hearing the
    // same record out of five phones is not listening together.
    if (!jamListening) {
      if (p.last?.playing ?? false) await p.pause();
      if (onAnother) await p.showTrack(state.trackId!, row: state.itemId);
      notifyListeners();
      return;
    }

    if (onAnother) {
      // This device reached the end of the song a moment before the host did and has
      // gone on to the next, which is where the host will be in a second or two. Going
      // back for the last bars of the old one and forward again is the queue skipping
      // about, and it is audible.
      if (_onlyJustAhead(p, state)) {
        notifyListeners();
        return;
      }
      // A different song: join it where the room is, not at the top.
      final began = DateTime.now();
      await p.playTrack(state.trackId!,
          row: state.itemId, startAt: _whereTheRoomWillBe());
      _learnWhatCatchingUpCosts(DateTime.now().difference(began));
      _lastFollowSeek = DateTime.now();
      if (!state.playing) await p.pause();
      notifyListeners();
      return;
    }

    if (!state.playing) {
      if (p.last?.playing ?? false) await p.pause();
      // Still worth landing on the right spot: a paused room is paused *somewhere*.
      if (((p.last?.position ?? Duration.zero) - state.position).abs() >
          const Duration(milliseconds: 400)) {
        await p.seek(state.position);
      }
      notifyListeners();
      return;
    }

    final here = p.livePosition;
    final drift = (here - (hostPosition ?? state.position)).abs();
    final settled = _lastFollowSeek == null ||
        DateTime.now().difference(_lastFollowSeek!) > const Duration(seconds: 6);
    if (drift > const Duration(milliseconds: 1500) && settled) {
      _lastFollowSeek = DateTime.now();
      final began = DateTime.now();
      await p.seek(_whereTheRoomWillBe());
      _learnWhatCatchingUpCosts(DateTime.now().difference(began));
    }
    if (!(p.last?.playing ?? false)) await p.resumeForJam();
    notifyListeners();
  }

  /// Where the room will have got to by the time this device has caught up with it.
  Duration _whereTheRoomWillBe() {
    final now = hostPosition ?? jamPosition ?? Duration.zero;
    return roomIsPlaying ? now + _catchUpCost : now;
  }

  void _learnWhatCatchingUpCosts(Duration took) {
    final next = (_catchUpCost + took) ~/ 2;
    _catchUpCost = next > const Duration(seconds: 3) ? const Duration(seconds: 3) : next;
  }

  /// True when this device is on the song straight after the one the host is still
  /// finishing.
  bool _onlyJustAhead(PlayerService p, JamPlayback state) {
    if (!state.playing) return false;
    final i = p.index;
    if (i <= 0 || i >= p.items.length) return false;
    final before = p.items[i - 1];
    if (before.id != state.trackId) return false;
    if (state.itemId != null &&
        before.queueItemId != null &&
        before.queueItemId != state.itemId) {
      return false;
    }
    final length = before.duration;
    if (length == null || length == Duration.zero) return false;
    return length - state.position < const Duration(seconds: 8) &&
        p.livePosition < const Duration(seconds: 8);
  }

  /// Get back in step with what the room last said, after something here changed —
  /// the queue was re-read, the speaker was turned on.
  Future<void> _followTheRoomAgain() async {
    final at = hostPosition;
    if (!isJamGuest || at == null) return;
    await followJamPlayback(JamPlayback(
      trackId: _roomTrack,
      itemId: _roomRow,
      positionMs: at.inMilliseconds,
      playing: roomIsPlaying,
      seq: _jamSeqIn,
    ));
  }

  // ---------------------------------------------------------------- guest → room
  // ------------------------------------------------------------ arriving by link
  //
  // Everything here arrives from somewhere else and nothing ever left: on a box four
  // people share there was no way to say "listen to this". A link is the smallest
  // thing that fixes it, and because everybody signs in to the same server the link
  // is this server with a path on it — /p/12 a playlist, /t/34 a song, /a/Low a
  // record, /r/Bicep an artist.
  //
  // Held rather than acted on, because a link usually arrives before there is anybody
  // to show it to: the app may still be signing in, and the screen that knows how to
  // open a playlist does not exist yet. The shell asks for this once it is up.
  String? _arrivedAt;

  /// Where this session was opened, if it was opened at something.
  ///
  /// Read once: a link is a thing that happened, not a place the app stays.
  String? takeTheLink() {
    final link = _arrivedAt;
    _arrivedAt = null;
    return link;
  }

  void arrivedAt(String path) {
    if (path.isEmpty || path == '/') return;
    _arrivedAt = path;
  }

  // ------------------------------------------------------------ several devices
  //
  // One account, several things to listen on. A device says what it is doing every few
  // seconds while it plays and whenever that changes; the others read it, and any one
  // of them can ask another to pause, to skip, or to take the music over from where it
  // has got to. What none of them do is guess: everything a screen shows about another
  // device is something that device said about itself.

  /// Which device you are on, as the server knows it.
  int? thisDevice;

  /// Everything this account listens on, as of the last look.
  List<DeviceInfo> devices = const [];

  /// The device the music is meant to be coming out of, when it is not this one.
  ///
  /// Null means here. While it is set, the transport on this screen is a remote
  /// control: play, pause, skip and seek are sent there rather than done here, which
  /// is the whole point of picking another device.
  int? playingOn;

  bool get controllingAnother => playingOn != null && playingOn != thisDevice;

  /// What that device is, for a screen that wants to say its name.
  DeviceInfo? get elsewhere => controllingAnother
      ? devices.where((d) => d.id == playingOn).firstOrNull
      : null;

  Timer? _deviceTimer;
  Timer? _tellFallback;
  DateTime _saidDevice = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> refreshDevices() async {
    try {
      final got = await api.devices();
      devices = got.devices;
      thisDevice = got.thisOne ?? thisDevice;
      // A device that stopped answering is not where the music is any more.
      if (controllingAnother && (elsewhere == null || !elsewhere!.live)) {
        playingOn = null;
      }
      await _followTheOtherDevice();
      notifyListeners();
    } catch (_) {
      // A list of devices is not worth a message on screen.
    }
  }

  /// One of this account's devices said what it is doing.
  ///
  /// What it said comes with the announcement, so the list is corrected where it
  /// stands. Going to ask for the list again after every report — which is what this
  /// did — put a screen working another device a round trip behind it, and its seek
  /// bar was not following that device at all.
  @visibleForTesting
  Future<void> heardFromADevice(Map<String, dynamic> data) async {
    _tellFallback?.cancel();
    final id = data['device_id'] as int?;
    final known = devices.where((d) => d.id == id).firstOrNull;
    final said = data.containsKey('position_ms');
    // A rename, a device never seen, a server from before it said all this, or a song
    // and a queue this list has no names for yet: ask.
    if (!said ||
        known == null ||
        known.track?.id != data['track_id'] ||
        known.queueId != data['queue_id']) {
      await refreshDevices();
      return;
    }
    devices = [
      for (final d in devices)
        d.id == id
            ? d.saying(
                playing: (data['playing'] ?? false) as bool,
                positionMs: (data['position_ms'] ?? 0) as int,
                itemId: data['item_id'] as int?)
            : d,
    ];
    await _followTheOtherDevice();
    notifyListeners();
  }

  /// Show what the device being worked from here is playing.
  ///
  /// This screen is its remote control, and a remote control that shows the song this
  /// phone happened to be on when it was picked up, at the place it was paused, is
  /// showing nothing about the music. The player here stays silent and is moved to the
  /// other one's queue, song and row; where in the song comes from [positionNow].
  Future<void> _followTheOtherDevice() async {
    final there = elsewhere;
    final p = player;
    if (there == null || p == null || isJamGuest) return;
    try {
      final queueId = there.queueId;
      if (queueId != null && queueId != activeQueue?.id) {
        activeQueue = await api.queue(queueId);
        await p.loadQueue(activeQueue!);
      }
      final song = there.track;
      if (song == null) return;
      final row = there.itemId;
      if (p.current?.id != song.id ||
          (row != null &&
              p.current?.queueItemId != null &&
              p.current?.queueItemId != row)) {
        await p.showTrack(song.id, row: row);
      }
    } catch (_) {
      // Not being able to show it is not a reason to stop being able to work it.
    }
  }

  /// Say what this device is doing, so the others can show it and take it over.
  ///
  /// Called when something changes and every ten seconds while playing. Quiet
  /// otherwise: a phone in a pocket with nothing playing has nothing to report.
  Future<void> reportDevice({bool force = false}) async {
    if (api.token == null) return;
    final snapshot = player?.last;
    final playing = snapshot?.playing ?? false;
    final now = DateTime.now();
    if (!force && now.difference(_saidDevice) < const Duration(seconds: 9)) return;
    _saidDevice = now;
    try {
      await api.reportDevice(
        playing: playing && !controllingAnother,
        trackId: snapshot?.current?.id,
        queueId: activeQueue?.id,
        itemId: snapshot?.current?.queueItemId,
        // While this is the device making the sound, the engine's position as this is
        // sent: whoever reads it carries it forward from the moment they hear it.
        positionMs: ((playing && !controllingAnother && !isJamGuest
                    ? player?.livePosition
                    : positionNow) ??
                snapshot?.position ??
                Duration.zero)
            .inMilliseconds,
        kind: kIsWeb
            ? 'browser'
            : (defaultTargetPlatform == TargetPlatform.linux ||
                    defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.macOS)
                ? 'desktop'
                : 'phone',
      );
    } catch (_) {
      // Missing one of these costs a minute of staleness on somebody else's screen.
    }
  }

  /// Move the music to one of your other devices, from exactly where it is.
  ///
  /// The device being handed to is told what to play and where to start; everything
  /// else of yours is told to let go. Handing it back to *this* device is the same
  /// conversation in reverse: it takes what the other one had and starts there.
  Future<void> playOn(DeviceInfo device) async {
    final snapshot = player?.last;
    final here = device.id == thisDevice;
    if (here) {
      final from = elsewhere ?? devices.where((d) => d.playing).firstOrNull;
      playingOn = null;
      notifyListeners();
      if (from != null && from.queueId != null) {
        await openQueue(from.queueId!);
        if (from.track != null) {
          // Straight in at where it has got to — carried forward from what it last
          // said — and on the row it is on, rather than the top of the song and a
          // jump a moment later.
          await player?.playTrack(from.track!.id,
              row: from.itemId, startAt: from.at);
        }
        // And whoever had it lets go, so the room is not playing two of the same song.
        await api.deviceCommand(from.id, 'stop').catchError((_) {});
      } else {
        await player?.playPause();
      }
      await reportDevice(force: true);
      return;
    }

    await api.deviceCommand(
      device.id,
      'take',
      queueId: activeQueue?.id,
      trackId: snapshot?.current?.id,
      positionMs:
          (positionNow ?? snapshot?.position ?? Duration.zero).inMilliseconds,
    );
    // Stop making a sound here the moment the other one is asked to start: two rooms
    // playing the same song a second apart is worse than either of them.
    await player?.pause();
    playingOn = device.id;
    notifyListeners();
    await reportDevice(force: true);
    await refreshDevices();
  }

  /// Something one of your other devices asked this one to do.
  ///
  /// Public so a test can be the other device: this is a protocol between two copies
  /// of this app, and the half that receives is the half worth checking.
  @visibleForTesting
  Future<void> obey(Map<String, dynamic> order) async {
    final to = order['to'] as int?;
    final action = (order['action'] ?? '') as String;
    if (action == 'yield') {
      // Somebody else is taking the music. Everything except the one taking it stops.
      if (order['except'] != thisDevice) {
        await player?.pause();
        playingOn = order['except'] as int?;
        notifyListeners();
      }
      return;
    }
    if (to != thisDevice || thisDevice == null) return;

    switch (action) {
      case 'take':
        playingOn = null;
        final queueId = order['queue_id'] as int?;
        if (queueId != null && queueId != activeQueue?.id) {
          await openQueue(queueId);
        }
        final trackId = order['track_id'] as int?;
        final at = order['position_ms'] as int?;
        if (trackId != null) {
          await player?.playTrack(trackId,
              startAt: at != null && at > 0 ? Duration(milliseconds: at) : null);
        } else if (at != null && at > 0) {
          await player?.seek(Duration(milliseconds: at));
        }
        await player?.resumeForJam();
      case 'play':
        playingOn = null;
        await player?.resumeForJam();
      case 'pause':
      case 'stop':
        await player?.pause();
      case 'next':
        await player?.next();
      case 'previous':
        await player?.previous();
      case 'seek':
        await player?.seek(
            Duration(milliseconds: (order['position_ms'] ?? 0) as int));
    }
    notifyListeners();
    await reportDevice(force: true);
  }

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
    // The music is in another room: this is a remote control, and the button under
    // the finger belongs to the device that is actually making the sound.
    if (controllingAnother) {
      return _tell((elsewhere?.playing ?? false) ? 'pause' : 'play');
    }
    await player?.playPause();
    await pushJamState(force: true);
    await reportDevice(force: true);
  }

  Future<void> skipNext() async {
    if (jamControlsTheRoom) return _ask('next');
    if (controllingAnother) return _tell('next');
    await player?.next();
    await pushJamState(force: true);
    await reportDevice(force: true);
  }

  Future<void> skipPrevious() async {
    if (jamControlsTheRoom) return _ask('previous');
    if (controllingAnother) return _tell('previous');
    await player?.previous();
    await pushJamState(force: true);
    await reportDevice(force: true);
  }

  Future<void> seekTo(Duration to) async {
    if (jamControlsTheRoom) return _ask('seek', positionMs: to.inMilliseconds);
    if (controllingAnother) {
      return _tell('seek', positionMs: to.inMilliseconds);
    }
    await player?.seek(to);
    await pushJamState(force: true);
    await reportDevice(force: true);
  }

  /// Pass one of these on to whichever device has the music.
  Future<void> _tell(String action, {int? positionMs}) async {
    final there = playingOn;
    if (there == null) return;
    // On screen at once. The other device says what it did a moment later and that is
    // what is believed — but a pause button that waits for a round trip before it
    // looks pressed gets pressed twice, and the second press is "play".
    final was = elsewhere;
    if (was != null) {
      final at = positionMs ?? was.at.inMilliseconds;
      final DeviceInfo? will = switch (action) {
        'pause' => was.saying(playing: false, positionMs: at),
        'play' => was.saying(playing: true, positionMs: at),
        'seek' => was.saying(playing: was.playing, positionMs: at),
        _ => null,
      };
      if (will != null) {
        devices = [for (final d in devices) d.id == there ? will : d];
        notifyListeners();
      }
    }
    try {
      await api.deviceCommand(there, action, positionMs: positionMs);
      // It says what it did, and that arrives by itself. Only if nothing has been
      // heard after a while is it asked — asking straight away read back what it was
      // doing *before* it obeyed, and undid what had just been drawn.
      _tellFallback?.cancel();
      _tellFallback = Timer(const Duration(seconds: 3), refreshDevices);
    } catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ the equalizer
  /// The curve somebody drew, and whatever this device can do about it. Its own
  /// notifier: a slider being dragged redraws the equalizer, not the whole app.
  final equalizer = Equalizer(NoEqEngine('The equalizer starts with the player.'));

  // ------------------------------------------------------------------ reactions
  final _reactions = StreamController<Reaction>.broadcast();

  /// Nods at the music, arriving and leaving. Drawn by ReactionLayer.
  Stream<Reaction> get reactions => _reactions.stream;

  /// One arriving from somebody else. Only the handful there are: what comes down the
  /// stream is drawn large on this screen, and it is not a way to send text.
  @visibleForTesting
  void heardAReaction(Map<String, dynamic> data) {
    final emoji = data['emoji'];
    if (emoji is String && reactionEmoji.contains(emoji)) {
      _reactions.add(Reaction(emoji: emoji, who: '${data['from'] ?? 'somebody'}'));
    }
  }

  /// Send one. It goes up this screen at once as well — the other end is somebody
  /// else's phone, and a button that does nothing you can see gets pressed again.
  Future<void> react(int personId, String name, String emoji, {int? trackId}) async {
    _reactions.add(Reaction(emoji: emoji, who: name, sent: true));
    try {
      await api.react(personId, emoji, trackId: trackId);
    } catch (_) {
      // One a second is all the server passes on, and one that did not get there is
      // not worth a message: it was a nod.
    }
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
    // A remote control: the music is wherever it was sent, and so is the answer.
    if (controllingAnother) return elsewhere?.playing ?? false;
    return player?.last?.playing ?? false;
  }

  /// Where the music is, wherever it is playing from.
  ///
  /// The host's clock for a guest listening to the room, and this device's own for
  /// everybody else — including a guest who has turned their own speaker on, whose
  /// engine is the thing making the sound they can hear.
  Duration? get positionNow {
    if (isJamGuest && !jamListening) return hostPosition;
    if (controllingAnother) return elsewhere?.at;
    return player?.last?.position;
  }

  Duration? get hostPosition {
    final at = _jamPositionAt, base = jamPosition;
    if (at == null || base == null || jam == null || (jam?.isHost ?? true)) return null;
    final since = DateTime.now().difference(at);
    if (since > const Duration(minutes: 2)) return null;   // stale: say nothing
    // A paused room is paused somewhere, and stays there: carried forward regardless,
    // the bar crept on through a pause every time something redrew it.
    if (!roomIsPlaying) return base;
    final now = base + since;
    final length = player?.current?.duration;
    return length != null && length > Duration.zero && now > length ? length : now;
  }

  Future<void> _onQueueChanged(Map<String, dynamic> data) async {
    final id = data['queue_id'] as int?;
    if (id == null || id != activeQueue?.id) return;
    // The position that comes with this is not read. It is the queue's *saved* place —
    // written every ten seconds, and straight after a skip still a place in the song
    // before — and a guest's seek bar used to be set from it: every skip and every song
    // anybody added threw the bar somewhere wrong until the host next spoke. The room
    // has a clock of its own; see followJamPlayback.
    final rev = data['rev'] as int?;
    // Every client of this user hears every announcement, this one included: a skip
    // writes its cursor, the server tells everybody, and the device that skipped is
    // told about its own move. Re-reading the queue for that is at best wasted work
    // and at worst a reload landing on top of a load still in flight.
    //
    // In a jam that is still true of the host: nobody else writes the cursor. Without
    // it the host re-read and reloaded its own queue after every one of its own skips,
    // and two quick skips had the first reload landing on top of the second song.
    final ourOwnMove = (jam == null || (jam?.isHost ?? false)) &&
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
    // Which for a guest may be the wrong place: the host went to a song that was not
    // in this device's copy of the queue until just now.
    await _followTheRoomAgain();
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
        await followJamPlayback(
            JamPlayback.fromJson(Map<String, dynamic>.from(data)));
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
      await _followTheRoomAgain();
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
          final refreshed = player?.onTrackReady(id);
          _queueMayHaveChanged(trackId: id);
          unawaited(_playWhatWasWanted(id, refreshed));
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
      } else if (e.event == 'device_command') {
        await obey(Map<String, dynamic>.from(e.data));
      } else if (e.event == 'devices') {
        // Somebody's state changed — usually whoever is playing.
        await heardFromADevice(Map<String, dynamic>.from(e.data));
      } else if (e.event == 'jam') {
        await _onJamEvent(e.data);
      } else if (e.event == 'reaction') {
        heardAReaction(Map<String, dynamic>.from(e.data));
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
    var heardPosition = Duration.zero;
    DateTime? heardAt;
    _playerSub = player?.snapshots.listen((s) {
      final trackChanged = named != null && s.current?.id != named;
      _watchForEndOfTrack(s, trackChanged: trackChanged);
      // The music is somewhere it did not get to by playing: a seek from the lock
      // screen or a headset, which never passes through seekTo, or a stream that
      // stalled. Anybody following this device is carrying the old position forward
      // and would go on doing so until the next heartbeat.
      final seen = DateTime.now();
      final expected = heardAt == null
          ? null
          : heardPosition + ((wasPlaying ?? false) ? seen.difference(heardAt!) : Duration.zero);
      final jumped = expected != null &&
          !trackChanged &&
          (s.position - expected).abs() > const Duration(milliseconds: 1500);
      heardPosition = s.position;
      heardAt = seen;
      if (jumped) {
        if (jam?.isHost ?? false) unawaited(pushJamState(force: true));
        unawaited(reportDevice(force: true));
      }
      if (s.current?.id != named || s.playing != wasPlaying) {
        named = s.current?.id;
        wasPlaying = s.playing;
        // Also on play and pause: a lockscreen showing a play button on something that
        // is playing is worse than no lockscreen control at all.
        _describeForTheOs(s.current, playing: s.playing);
        // And the other devices of this account, so "where is it playing" is answered
        // the moment it changes rather than at the next heartbeat.
        unawaited(reportDevice(force: true));
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
