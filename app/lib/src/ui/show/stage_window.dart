// The stage in a window of its own: this program started again with `--stage`,
// showing nothing but the show — on the second screen, full screen, at a set. The
// same shape as the board's window (board_window.dart): a second process, not a
// second window, for the same reasons.
//
//   wetowl --stage ws://127.0.0.1:<port>/stage?t=<token>   the show off the desk
//   wetowl --stage --demo [--scene <id>]                    a made-up record (one scene held)
//   wetowl --stage --record <id> [--at <s>] [--scene <id>]   a real record off the house, played
//                                                           here through the booth's own engine
//   … --shot [--shot-every <ms>]                             frames to the temp directory
//   … --camera [<device>]                                    the room's camera on (C toggles)
//   wetowl --stage --spike [--passes n --scale x --shot]     the perf spike
//   … --fullscreen                                           from the start
//
// Keys: F11 or Esc full screen on/off · ← → the scene · H hit · B blackout · S
// strobe (held) · F freeze · Q quits. (The spike has its own: see show_spike.dart.)
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'dart:math' as math;

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../state/app_state.dart' show AppState;
import '../../state/booth/booth.dart';
import '../../state/playback_log.dart';
import '../../state/show/camera_feed.dart';
import '../../state/player.dart' show PlayerService;
import '../../state/show/show_demo.dart';
import '../../state/show/show_feed.dart';
import '../../state/show/show_wire.dart';
import 'show_spike.dart';
import 'stage_kit.dart';
import 'stage_page.dart';

/// The argument that makes this program a stage window.
const stageWindowFlag = '--stage';

bool wantsStageWindow(List<String> args) => args.contains(stageWindowFlag);

/// The url after [stageWindowFlag] in [args], or null (a demo, or the spike).
String? stageWindowUrl(List<String> args) {
  final i = args.indexOf(stageWindowFlag);
  final next = i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  return next != null && next.startsWith('ws') ? next : null;
}

/// Before the first frame of a stage window: its title and size, and full screen when
/// asked for on the command line.
Future<void> readyTheStageWindow(List<String> args) async {
  if (kIsWeb) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('WetOwl · Stage');
    await windowManager.setMinimumSize(const Size(320, 180));
    await windowManager.setSize(const Size(1920, 1080));
    await windowManager.show();
    if (args.contains('--fullscreen')) await windowManager.setFullScreen(true);
  } catch (e) {
    debugPrint('stage window: $e');
  }
}

class StageWindowApp extends StatelessWidget {
  const StageWindowApp({super.key, required this.args});
  final List<String> args;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WetOwl · Stage',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: args.contains('--spike') ? _SpikePage(args: args) : _StageWindow(args: args),
    );
  }
}

// ------------------------------------------------------------------ the show
class _StageWindow extends StatefulWidget {
  const _StageWindow({required this.args});
  final List<String> args;

  @override
  State<_StageWindow> createState() => _StageWindowState();
}

class _StageWindowState extends State<_StageWindow> {
  ShowFeed? _feed;
  DemoShowFeed? _demo;
  RemoteShowFeed? _remote;
  Booth? _booth;
  WebSocket? _ws;
  Timer? _ping, _reconnect;
  String _word = 'Connecting…';
  final _focus = FocusNode();
  final _shot = GlobalKey();
  bool _closing = false;

  int _frames = 0, _raster = 0, _worst = 0;
  Timer? _saying, _counting;
  void _took(List<FrameTiming> frames) {
    for (final f in frames) {
      _frames++;
      final r = f.rasterDuration.inMicroseconds;
      _raster += r;
      if (r > _worst) _worst = r;
    }
  }

  /// The dynamics, counted: how many times each hit fired in the last five seconds,
  /// and the loudest the bands got — to be read against the record's tempo.
  int _kicks = 0, _snares = 0, _tops = 0;
  double _kickWas = 0, _snareWas = 0, _topWas = 0, _lowSum = 0, _expMax = 0;
  int _samples = 0;
  void _count() {
    final f = _feed?.state.flat;
    if (f == null) return;
    final k = f['dyn.hit.kick'] ?? 0, sn = f['dyn.hit.snare'] ?? 0, t = f['dyn.hit.top'] ?? 0;
    if (k > 0.5 && _kickWas <= 0.5) _kicks++;
    if (sn > 0.5 && _snareWas <= 0.5) _snares++;
    if (t > 0.5 && _topWas <= 0.5) _tops++;
    _kickWas = k;
    _snareWas = sn;
    _topWas = t;
    _lowSum += f['dyn.band.low'] ?? 0;
    _samples++;
    _expMax = math.max(_expMax, f['dyn.exposure'] ?? 0);
  }

  void _say() {
    final n = _frames;
    if (n == 0) return;
    // ignore: avoid_print
    print('STAGE fps=${(n / 5).toStringAsFixed(1)} raster ${(_raster / n / 1000).toStringAsFixed(1)}/${(_worst / 1000).toStringAsFixed(1)} ms '
        'scene=${_feed?.state.scene} hits kick=$_kicks snare=$_snares top=$_tops low~${(_samples == 0 ? 0 : _lowSum / _samples).toStringAsFixed(2)} exp=${_expMax.toStringAsFixed(2)}');
    _frames = _raster = _worst = 0;
    _kicks = _snares = _tops = 0;
    _lowSum = _expMax = 0;
    _samples = 0;
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_took);
    _saying = Timer.periodic(const Duration(seconds: 5), (_) => _say());
    _counting = Timer.periodic(const Duration(milliseconds: 8), (_) => _count());
    // `--shot`: a frame saved on its own after six seconds, and again every four,
    // for a run nobody is watching.
    if (widget.args.contains('--shot')) {
      final e = widget.args.indexOf('--shot-every');
      final every = e >= 0 && e + 1 < widget.args.length ? int.tryParse(widget.args[e + 1]) ?? 4000 : 4000;
      final sc = widget.args.indexOf('--shot-scale');
      if (sc >= 0 && sc + 1 < widget.args.length) shotScale = double.tryParse(widget.args[sc + 1]) ?? 1.0;
      Timer(const Duration(seconds: 6), () {
        unawaited(saveStageShot(_shot, at: _booth?.a.position));
        Timer.periodic(Duration(milliseconds: every), (_) => unawaited(saveStageShot(_shot, at: _booth?.a.position)));
      });
    }
    final c = widget.args.indexOf('--camera');
    if (c >= 0) {
      final cam = CameraFeed.shared;
      final dev = c + 1 < widget.args.length && !widget.args[c + 1].startsWith('--') ? widget.args[c + 1] : null;
      if (dev != null) cam.device = dev;
      cam.pinned = true;
      unawaited(cam.start());
    }
    final url = stageWindowUrl(widget.args);
    final r = widget.args.indexOf('--record');
    if (r >= 0 && r + 1 < widget.args.length) {
      final at = widget.args.indexOf('--at');
      final secs = at >= 0 && at + 1 < widget.args.length ? double.tryParse(widget.args[at + 1]) ?? 0 : 0.0;
      unawaited(_startRecord(int.tryParse(widget.args[r + 1]) ?? 0, Duration(milliseconds: (secs * 1000).round())));
    } else if (url == null) {
      unawaited(_startDemo());
    } else {
      _remote = RemoteShowFeed();
      _feed = _remote;
      unawaited(_connect(url));
    }
  }

  Future<void> _startDemo() async {
    final kit = await StageKit.load();
    final demo = DemoShowFeed(scenes: kit.book.metas)..start();
    // `--scene <id>`: that scene held, for looking at it.
    final i = widget.args.indexOf('--scene');
    if (i >= 0 && i + 1 < widget.args.length) {
      demo.director
        ..choose(widget.args[i + 1])
        ..locked = true;
    }
    if (!mounted) return;
    setState(() {
      _demo = demo;
      _feed = demo;
      _word = '';
    });
  }

  /// A real record, played here: the booth's own engine (libmpv), the booth's own
  /// show engine on it, the account this desk is signed into. The bench for what
  /// the show does with music — and a way to put a record on the stage without
  /// opening the booth.
  Future<void> _startRecord(int id, Duration at) async {
    try {
      JustAudioMediaKit.title = 'WetOwl · Stage';
      JustAudioMediaKit.prefetchPlaylist = false;
      JustAudioMediaKit.pitch = false;
      PlayerService.gainToVolume = (g) => g <= 0 ? 0 : math.pow(g, 1 / 3).toDouble();
      JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: true);
      final prefs = await SharedPreferences.getInstance();
      final api = ApiClient(
        baseUrl: prefs.getString('muse.server') ?? AppState.defaultServer,
        token: prefs.getString('muse.token'),
      );
      final kit = await StageKit.load();
      final booth = Booth(api);
      await booth.init();
      final track = await api.track(id);
      await booth.load(booth.a, track, at: at, byHand: false);
      booth.show.director.scenes = kit.book.metas;
      final sc = widget.args.indexOf('--scene');
      if (sc >= 0 && sc + 1 < widget.args.length) {
        booth.show.director
          ..choose(widget.args[sc + 1])
          ..locked = true;
      }
      booth.show.start();
      await booth.play(booth.a);
      final t = booth.timing.peek(id);
      final st = t?.structure;
      // ignore: avoid_print
      print('RECORD ${track.id} "${track.title}" ${track.artists.join(', ')} bpm ${t?.gridBpm?.toStringAsFixed(2)} '
          'drops ${(st?.dropsMs.isNotEmpty == true ? st!.dropsMs : t?.drops ?? const []).map((d) => (d / 1000).toStringAsFixed(1)).join(' ')} '
          'sections ${st?.sections.map((s) => '${s.label}@${(s.startMs / 1000).round()}').join(' ') ?? '-'}');
      if (!mounted) return;
      setState(() {
        _booth = booth;
        _feed = booth.show;
        _word = '';
      });
    } catch (e) {
      // ignore: avoid_print
      print('RECORD could not start: $e');
      PlaybackLog.note('stage record: $e');
      if (mounted) setState(() => _word = 'The record could not be put on: $e');
    }
  }

  Future<void> _connect(String url) async {
    if (_closing) return;
    try {
      final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 3));
      _ws = ws;
      if (mounted) setState(() => _word = '');
      _ping = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          ws.add('{"t":"ping"}');
        } catch (_) {}
      });
      ws.listen(
        (data) {
          if (data is String) _remote?.arrived(data);
        },
        onDone: () => _lost(url),
        onError: (Object _) => _lost(url),
      );
    } catch (_) {
      _lost(url);
    }
  }

  void _lost(String url) {
    _ping?.cancel();
    _ws = null;
    if (!mounted || _closing) return;
    setState(() => _word = 'The booth went away. Trying again…');
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 2), () => _connect(url));
  }

  @override
  void dispose() {
    _closing = true;
    SchedulerBinding.instance.removeTimingsCallback(_took);
    _saying?.cancel();
    _counting?.cancel();
    _ping?.cancel();
    _reconnect?.cancel();
    unawaited(_ws?.close());
    _demo?.dispose();
    _remote?.dispose();
    _booth?.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.f11 || k == LogicalKeyboardKey.escape) {
      unawaited(windowManager.isFullScreen().then((full) => windowManager.setFullScreen(!full)));
    } else if (k == LogicalKeyboardKey.keyQ) {
      exit(0);
    } else if (k == LogicalKeyboardKey.keyC) {
      final cam = CameraFeed.shared;
      if (cam.running) {
        cam.pinned = false;
        cam.stop();
      } else {
        cam.pinned = true;
        unawaited(cam.start());
      }
    } else if (k == LogicalKeyboardKey.space && _booth != null) {
      final b = _booth!;
      unawaited(b.a.playing ? b.a.pause() : b.play(b.a));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    final demo = _demo;
    final booth = _booth;
    final hands = booth != null
        ? StageHands.ofEngine(booth)
        : demo == null
        ? StageHands.none
        : StageHands(
            next: demo.director.next,
            previous: () => demo.director.next(by: -1),
            hit: () => demo.macros = demo.macros.copyWith(hit: 1),
            macros: () => demo.macros,
            setMacros: (m) => demo.macros = m,
          );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _keys,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _shot,
            child: feed != null ? StagePage(feed: feed, onKey: hands, canPop: false) : const ColoredBox(color: Colors.black),
          ),
          if (_word.isNotEmpty)
            Positioned(
              left: 24,
              bottom: 24,
              child: Text(_word, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
            ),
          // The camera is on: a red dot, always, while it is.
          Positioned(
            right: 16,
            top: 12,
            child: ListenableBuilder(
              listenable: CameraFeed.shared,
              builder: (context, _) => CameraFeed.shared.running
                  ? Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xffe0302a), shape: BoxShape.circle))
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture under [key], as a PNG in the temp directory; its path on stdout.
int _shots = 0;
double shotScale = 1.0;
Future<void> saveStageShot(GlobalKey key, {Duration? at}) async {
  final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return;
  // The record's position as the frame is taken, so a clip can be cut to the sound.
  final pos = at?.inMilliseconds;
  final image = await boundary.toImage(pixelRatio: shotScale);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) return;
  final file = File('${Directory.systemTemp.path}/wetowl-stage-$pid-${_shots++}.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  // ignore: avoid_print
  print('STAGE shot ${file.path}${pos == null ? '' : ' pos=$pos'}');
}

// ------------------------------------------------------------------ the spike
class _SpikePage extends StatefulWidget {
  const _SpikePage({required this.args});
  final List<String> args;

  @override
  State<_SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<_SpikePage> {
  ShowPrograms? _programs;
  String? _trouble;
  double _scale = 1.0;
  bool _flip = false;
  int _passes = 5;
  final _focus = FocusNode();
  final _shot = GlobalKey();

  @override
  void initState() {
    super.initState();
    final s = widget.args.indexOf('--scale');
    if (s >= 0 && s + 1 < widget.args.length) _scale = double.tryParse(widget.args[s + 1]) ?? 1.0;
    _flip = widget.args.contains('--flip');
    final p = widget.args.indexOf('--passes');
    if (p >= 0 && p + 1 < widget.args.length) _passes = int.tryParse(widget.args[p + 1]) ?? 5;
    // ignore: avoid_print
    print('STAGE args ${widget.args} scale $_scale passes $_passes flip $_flip');
    // `--shot`: a frame saved on its own after six seconds, for a run nobody is
    // watching (the measurements in tool/).
    if (widget.args.contains('--shot')) {
      Timer(const Duration(seconds: 6), () => unawaited(_save()));
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final p = await ShowPrograms.load();
      if (mounted) setState(() => _programs = p);
    } catch (e) {
      if (mounted) setState(() => _trouble = '$e');
    }
  }

  Future<void> _save() => saveStageShot(_shot);

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.f11 || k == LogicalKeyboardKey.escape) {
      unawaited(windowManager.isFullScreen().then((full) => windowManager.setFullScreen(!full)));
    } else if (k == LogicalKeyboardKey.digit1) {
      setState(() => _scale = 1.0);
    } else if (k == LogicalKeyboardKey.digit2) {
      setState(() => _scale = 0.75);
    } else if (k == LogicalKeyboardKey.digit3) {
      setState(() => _scale = 0.5);
    } else if (k == LogicalKeyboardKey.keyF) {
      setState(() => _flip = !_flip);
    } else if (k == LogicalKeyboardKey.keyS) {
      unawaited(_save());
    } else if (k == LogicalKeyboardKey.keyQ) {
      exit(0);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = _programs;
    Widget body;
    if (_trouble != null) {
      body = Center(child: Text('The stage could not load its shaders.\n$_trouble'));
    } else if (p == null) {
      body = const SizedBox.shrink();
    } else {
      body = RepaintBoundary(key: _shot, child: ShowSpike(programs: p, scale: _scale, flip: _flip, passes: _passes));
    }
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _keys,
      child: Scaffold(backgroundColor: Colors.black, body: body),
    );
  }
}
