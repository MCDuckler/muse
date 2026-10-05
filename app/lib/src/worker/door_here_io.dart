import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../state/player.dart';
import '../ui/mag.dart';
import '../ui/mag_parts.dart';
import 'package:path_provider/path_provider.dart';

import 'door_pull.dart';
import 'exit_tunnel.dart';

/// Phones. A computer runs yt-dlp itself (this_computer_io.dart) and a browser cannot
/// open the connections. The real system, not defaultTargetPlatform: widget tests
/// pretend to be Android, and a door opened inside one would knock on the test's server.
bool get canOpenDoorHere => Platform.isAndroid || Platform.isIOS;

const _kOn = 'muse.door.on';
const _kData = 'muse.door.mobileData';
const _build = String.fromEnvironment('MUSE_BUILD');

/// This phone opening the door to YouTube for the songs its person is about to play.
/// See exit_tunnel.dart for what goes through it, and server/muse/exits.py for what the
/// server does with it.
///
/// The door is open while somebody is signed in, it is switched on, and the app is
/// either on the screen or playing. Away from the screen and quiet, it shuts after a
/// minute; the phone would freeze the app soon anyway, and an open door is only useful
/// while songs are being asked for. Nothing has to ask it to fetch. The player's
/// look-ahead already tells the server what is coming up, and the server takes those
/// songs through this phone's door when it is open.
class DoorHere extends ChangeNotifier {
  DoorHere._(this.app);

  static DoorHere? _instance;
  static DoorHere? get instance => _instance;

  static Future<DoorHere?> forApp(AppState app) async {
    if (!canOpenDoorHere) return null;
    final have = _instance;
    if (have != null && identical(have.app, app)) return have;
    have?.dispose();
    final d = _instance = DoorHere._(app);
    await d._init();
    return d;
  }

  /// With a tunnel and a network of the test's own, on any system.
  @visibleForTesting
  static Future<DoorHere> forTest(AppState app, ExitTunnel tunnel,
      {List<ConnectivityResult> now = const [ConnectivityResult.wifi],
      Stream<List<ConnectivityResult>> changes = const Stream.empty()}) async {
    _instance?.dispose();
    final d = _instance = DoorHere._(app);
    await d._init(tunnel: tunnel, now: now, changes: changes);
    return d;
  }

  final AppState app;
  late final ExitTunnel tunnel;
  late final DoorPuller puller;

  /// Fetch songs through this phone at all.
  bool on = true;

  /// And when the server cannot pull a song itself, let it come through this phone's
  /// own data, not only over Wi-Fi.
  bool mobileData = true;

  /// wifi, cellular, ethernet, none or unknown: said to the server with every hello.
  String network = 'unknown';

  bool _inFront = true;
  bool _playing = false;
  Timer? _shutting;
  StreamSubscription<List<ConnectivityResult>>? _net;
  StreamSubscription<PlayerSnapshot>? _heard;
  PlayerService? _watched;
  AppLifecycleListener? _life;
  String? _token;

  /// The token the server last turned away: not offered again until it changes.
  String? _turnedAway;
  bool _gone = false;

  Future<void> _init({ExitTunnel? tunnel, List<ConnectivityResult>? now,
      Stream<List<ConnectivityResult>>? changes}) async {
    final prefs = await SharedPreferences.getInstance();
    on = prefs.getBool(_kOn) ?? true;
    mobileData = prefs.getBool(_kData) ?? true;
    puller = DoorPuller(
      baseUrl: () => app.api.baseUrl,
      token: () => app.api.token,
      keepDir: _keepDir,
      onArrived: (track, _) {
        notifyListeners();
        // If the player is waiting on this one, it plays now, from this phone.
        unawaited(app.player?.localArrived(track));
      },
      onSaid: (line) => debugPrint('door: $line'),
    );
    this.tunnel = tunnel ??
        ExitTunnel(
          url: () => exitUrlFor(app.api.baseUrl),
          token: () => app.api.token,
          hello: hello,
          onPull: pull,
        );
    if (tunnel == null) unawaited(_keepDir().then(DoorPuller.tidy).catchError((_) {}));
    this.tunnel.addListener(_tunnelChanged);
    try {
      network = _named(now ?? await Connectivity().checkConnectivity());
    } catch (_) {
      // No answer: the server treats an unknown network like a phone's data.
    }
    _net = (changes ?? Connectivity().onConnectivityChanged).listen((now) {
      final n = _named(now);
      if (n == network) return;
      network = n;
      this.tunnel.sayHello();
      notifyListeners();
    }, onError: (Object _) {});
    _life = AppLifecycleListener(
      onShow: () {
        _inFront = true;
        _consider();
      },
      onHide: () {
        _inFront = false;
        _consider();
      },
    );
    app.addListener(_appChanged);
    _appChanged();
  }

  /// What this phone tells the server about itself.
  Map<String, Object?> hello() => {
        'network': network,
        'mobile_data': mobileData,
        'platform': defaultTargetPlatform.name,
        'build': _build,
        // It fetches a song itself when told where it is (door_pull.dart).
        'pulls': 1,
      };

  static Future<Directory> _keepDir() async => Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}pulled');

  /// The server's word: fetch this song here.
  void pull(Map<String, dynamic> order) {
    final o = PullOrder.fromJson(order);
    if (o == null) return;
    notifyListeners();
    unawaited(puller.pull(o).whenComplete(notifyListeners));
  }

  /// A song this phone fetched itself, where it is on the disk.
  String? pulledPath(int track) => puller.kept[track];

  static String _named(List<ConnectivityResult> said) {
    if (said.contains(ConnectivityResult.wifi)) return 'wifi';
    if (said.contains(ConnectivityResult.ethernet)) return 'ethernet';
    if (said.contains(ConnectivityResult.mobile)) return 'cellular';
    if (said.isEmpty || said.every((r) => r == ConnectivityResult.none)) return 'none';
    return 'unknown';
  }

  void _tunnelChanged() {
    if (tunnel.state == ExitState.refused) _turnedAway = _token;
    notifyListeners();
  }

  void _appChanged() {
    if (_gone) return;
    final p = app.player;
    if (!identical(p, _watched)) {
      _heard?.cancel();
      _watched = p;
      _playing = p?.isPlaying ?? false;
      _heard = p?.changes.listen((s) => heardPlaying(s.playing));
    }
    String? token;
    try {
      token = app.user == null ? null : app.api.token;
    } catch (_) {
      token = null;                  // no client yet: still starting up
    }
    if (token != _token) {
      final was = _token;
      _token = token;
      if (was != null && tunnel.wanted) {
        // Signed in again: the door is opened with the new token, not the old one.
        unawaited(tunnel.stop().then((_) => _consider()));
        return;
      }
    }
    _consider();
  }

  /// The player started or stopped: playing keeps the door open out of sight.
  @visibleForTesting
  void heardPlaying(bool playing) {
    if (playing == _playing) return;
    _playing = playing;
    _consider();
  }

  void _consider() {
    if (_gone) return;
    final wanted = on && _token != null;
    if (!wanted) {
      _shutting?.cancel();
      _shutting = null;
      if (tunnel.state != ExitState.off) unawaited(tunnel.stop());
      return;
    }
    if (_inFront || _playing) {
      _shutting?.cancel();
      _shutting = null;
      final refused = tunnel.state == ExitState.refused && _turnedAway == _token;
      if (!tunnel.wanted && !refused) unawaited(tunnel.start());
      return;
    }
    if (tunnel.wanted && _shutting == null) {
      _shutting = Timer(const Duration(seconds: 60), () {
        _shutting = null;
        if (!_inFront && !_playing) unawaited(tunnel.stop());
      });
    }
  }

  Future<void> set({bool? on, bool? mobileData}) async {
    final prefs = await SharedPreferences.getInstance();
    if (on != null) {
      this.on = on;
      await prefs.setBool(_kOn, on);
      // Switched on by hand: worth one more try even after being turned away.
      if (on) _turnedAway = null;
    }
    if (mobileData != null) {
      this.mobileData = mobileData;
      await prefs.setBool(_kData, mobileData);
      tunnel.sayHello();
    }
    notifyListeners();
    _consider();
  }

  Future<void> shut() async {
    _shutting?.cancel();
    _shutting = null;
    _token = null;
    await tunnel.stop();
    notifyListeners();
  }

  /// One line on what the door is doing, for the settings row and the pool screen.
  String get line {
    if (!on) return 'Off. Songs wait for a computer in the pool.';
    return switch (tunnel.state) {
      ExitState.off => _inFront || _playing
          ? 'Opening…'
          : 'Shut while WetOwl is in the background and quiet.',
      ExitState.connecting => 'Opening…',
      ExitState.open => puller.working > 0
          ? 'Fetching a song right now.'
          : tunnel.streams > 0
              ? 'Asking YouTube for a song right now.'
              : 'Open. Songs you play that the house does not have come through here.',
      ExitState.waiting => 'Lost the server. Trying again.',
      ExitState.refused => tunnel.problem ?? 'The server said no.',
    };
  }

  @override
  void dispose() {
    _gone = true;
    _shutting?.cancel();
    _net?.cancel();
    _heard?.cancel();
    _life?.dispose();
    app.removeListener(_appChanged);
    tunnel.removeListener(_tunnelChanged);
    tunnel.dispose();
    if (identical(_instance, this)) _instance = null;
    super.dispose();
  }
}

Future<void> openDoorHere(AppState app) async {
  try {
    await DoorHere.forApp(app);
  } catch (e) {
    debugPrint('door: could not open: $e');
  }
}

Future<void> shutDoorHere() async => DoorHere.instance?.shut();

/// A song this phone fetched itself, while it still has it.
String? doorPulledPath(int trackId) => DoorHere.instance?.pulledPath(trackId);

/// The settings row: what the door is doing, and the way to its switches.
Widget doorHereTile() => const _DoorTile();

/// The same, on the pool screen, with the switches right there.
Widget doorHereCard() => const _DoorCard();

/// Listens to the door for as long as the widget is up.
mixin _Watching<T extends StatefulWidget> on State<T> {
  DoorHere? door;

  @override
  void initState() {
    super.initState();
    final d = door = DoorHere.instance;
    d?.addListener(_changed);
  }

  @override
  void dispose() {
    door?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }
}

class _DoorTile extends StatefulWidget {
  const _DoorTile();

  @override
  State<_DoorTile> createState() => _DoorTileState();
}

class _DoorTileState extends State<_DoorTile> with _Watching {
  @override
  Widget build(BuildContext context) {
    final d = door;
    if (d == null) return const SizedBox.shrink();
    return ListTile(
      leading: Icon(d.tunnel.state == ExitState.open
          ? Icons.sensor_door_outlined
          : Icons.door_front_door_outlined),
      title: const Text('Fetch songs through this phone'),
      subtitle: Text(d.line),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('This phone')),
                body: ListView(children: const [_DoorCard()]),
              ))),
    );
  }
}

class _DoorCard extends StatefulWidget {
  const _DoorCard();

  @override
  State<_DoorCard> createState() => _DoorCardState();
}

class _DoorCardState extends State<_DoorCard> with _Watching {
  @override
  Widget build(BuildContext context) {
    final d = door;
    if (d == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final typed = Mag.typewriter(11.5, color: scheme.onSurfaceVariant);
    final t = d.tunnel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.5)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Kicker('This phone'),
            const SizedBox(height: 6),
            Text(
                'YouTube only gives songs to a home or a phone connection, never to the '
                'server. With this on, a song you play that the house does not have yet is '
                'asked for through this phone, so it arrives with no computer switched on. '
                'Asking costs about 400 KB. Usually this phone then fetches the song itself, '
                'about 4 MB, plays it straight away and hands the house its copy.',
                style: typed),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Fetch songs through this phone'),
              subtitle: Text(d.line),
              value: d.on,
              onChanged: (v) => d.set(on: v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also on mobile data'),
              subtitle: Text(d.mobileData
                  ? 'Away from Wi-Fi, a song can come through your data plan. A computer at '
                      'home fetches it instead when one is switched on.'
                  : 'Away from Wi-Fi, songs wait for a computer or for Wi-Fi.'),
              value: d.mobileData,
              onChanged: d.on ? (v) => d.set(mobileData: v) : null,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                  '${switch (d.network) {
                    'wifi' => 'On Wi-Fi',
                    'cellular' => 'On mobile data',
                    'ethernet' => 'On a cable',
                    'none' => 'No connection',
                    _ => 'Connection unknown',
                  }} · ${d.puller.pulled} fetched here · '
                  '${_mb(t.bytes + d.puller.bytes)} through this phone',
                  style: typed),
            ),
          ],
        ),
      ),
    );
  }

  static String _mb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
