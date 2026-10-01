// How smoothly the desk's booth draws, measured on the machine it runs on.
//
// The whole room — both decks, the waveforms, the mixer, the log — built as the app
// builds it, two records playing on the real engine (libmpv, sent to its null output),
// fed by a little house on the loopback that serves their audio, their analysis and
// their shapes the way the real one does. Then the frames are counted: once with the
// two records simply playing, once with a mix going on — the crossfader travelling and
// the EQ moving every frame or so, which is what the room is doing when it is busiest.
//
//   flutter drive --profile -d linux --driver=test_driver/integration_test.dart \
//     --target=integration_test/booth_perf_test.dart
//
// Profile, not debug: a debug build is a different program as far as speed goes. The
// numbers land in build/integration_response_data.json and on the console.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FramePhase;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart' show EqSet;
import 'package:muse/src/ui/booth_page.dart';
import 'package:muse/src/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';
import 'dart:developer' as dev;
import 'dart:isolate';

const _seconds = 240;
const _rate = 44100;

/// A record of sorts, stereo at 44.1 kHz like the house's: a kick on every beat, hats between, a bassline that comes and
/// goes by the phrase — enough that the shape has bass, middle and top in it.
Uint8List _wav(double bpm, int seed) {
  final n = _seconds * _rate;
  final data = ByteData(44 + n * 4);
  void s(int o, String t) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  data.setUint32(4, 36 + n * 4, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, _rate, Endian.little);
  data.setUint32(28, _rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  s(36, 'data');
  data.setUint32(40, n * 4, Endian.little);
  final beat = 60 / bpm;
  final r = math.Random(seed);
  for (var i = 0; i < n; i++) {
    final t = i / _rate;
    final inBeat = t % beat;
    final kick = math.exp(-inBeat * 30) * math.sin(2 * math.pi * 55 * inBeat);
    final hat = (inBeat - beat / 2).abs() < 0.01 ? (r.nextDouble() - 0.5) : 0.0;
    final phrase = (t / (beat * 64)).floor();
    final bass = phrase.isOdd ? 0.3 * math.sin(2 * math.pi * 82 * t) : 0.0;
    final v = (0.5 * kick + 0.3 * hat + bass).clamp(-1.0, 1.0);
    final pcm = (v * 20000).round();
    data.setInt16(44 + i * 4, pcm, Endian.little);
    data.setInt16(46 + i * 4, pcm, Endian.little);
  }
  return data.buffer.asUint8List();
}

Map<String, dynamic> _analysis(double bpm) {
  final beat = 60000 / bpm;
  final beats = [for (var t = 500.0; t < _seconds * 1000 - 500; t += beat) t.round()];
  final downbeats = [for (var i = 0; i < beats.length; i += 4) beats[i]];
  final phrases = [for (var i = 0; i < beats.length; i += 64) beats[i]];
  final sections = <Map<String, dynamic>>[];
  const labels = ['intro', 'build', 'drop', 'breakdown', 'build', 'drop', 'outro'];
  for (var i = 0; i + 1 < phrases.length; i++) {
    sections.add({'start_ms': phrases[i], 'end_ms': phrases[i + 1], 'label': labels[i % labels.length]});
  }
  return {
    'duration_ms': _seconds * 1000,
    'bpm': bpm,
    'beats': beats,
    'downbeats': downbeats,
    'bar_starts_on': 0,
    'camelot': '8A',
    'key': 'A minor',
    'energy': [for (var i = 0; i < 120; i++) 120 + (i * 7) % 120],
    'phrases': phrases,
    'four_bars': [for (var i = 0; i < downbeats.length; i += 4) downbeats[i]],
    'drops': [phrases[2], phrases[5]],
    'cues': {
      'first_downbeat_ms': beats.first,
      'mix_in_ms': phrases[1],
      'mix_out_ms': phrases[phrases.length - 2],
      'sound_end_ms': _seconds * 1000 - 500,
    },
    'structure': {
      'sections': sections,
      'drops_ms': [phrases[2], phrases[5]],
    },
  };
}

Map<String, dynamic> _bands(int slices, int seed) {
  final r = math.Random(seed);
  List<int> one(double scale, double period) => [
        for (var i = 0; i < slices; i++)
          ((0.35 + 0.65 * (math.sin(i / period) * 0.5 + 0.5)) * (60 + r.nextInt(195)) * scale)
              .clamp(0, 255)
              .round(),
      ];
  return {
    'bands': {'low': one(1, 90), 'mid': one(0.8, 40), 'high': one(0.55, 13)}
  };
}

/// The house, on the loopback: audio with Range, analysis, shapes, nothing else.
Future<HttpServer> _house(Map<int, Uint8List> audio, Map<int, double> bpms) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    final path = req.uri.path;
    final m = RegExp(r'^/tracks/(\d+)/(\w+)').firstMatch(path);
    final id = m == null ? null : int.parse(m.group(1)!);
    try {
      if (path.endsWith('/auth/stream-key')) {
        res.headers.contentType = ContentType.json;
        res.write('{"key": "k", "expires_at": 99999999999}');
      } else if (m != null && m.group(2) == 'stream' && audio[id] != null) {
        final bytes = audio[id]!;
        final range = req.headers.value('range');
        res.headers.contentType = ContentType('audio', 'wav');
        res.headers.set('accept-ranges', 'bytes');
        if (range != null) {
          final mm = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
          final from = int.parse(mm.group(1)!);
          final to = mm.group(2)!.isEmpty ? bytes.length - 1 : math.min(int.parse(mm.group(2)!), bytes.length - 1);
          res.statusCode = 206;
          res.headers.set('content-range', 'bytes $from-$to/${bytes.length}');
          res.contentLength = to - from + 1;
          res.add(Uint8List.sublistView(bytes, from, to + 1));
        } else {
          res.contentLength = bytes.length;
          res.add(bytes);
        }
      } else if (m != null && m.group(2) == 'analysis' && bpms[id] != null) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_analysis(bpms[id]!)));
      } else if (m != null && m.group(2) == 'peaks' && bpms[id] != null) {
        final slices = int.tryParse(req.uri.queryParameters['slices'] ?? '') ?? 1600;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_bands(slices, id!)));
      } else {
        res.statusCode = 404;
        res.write('{"detail": "not here"}');
      }
    } catch (_) {
      res.statusCode = 500;
    }
    await res.close();
  });
  return server;
}

Track _track(int id, String title) => Track.fromJson({
      'id': id,
      'title': title,
      'artists': ['Probe'],
      'duration_ms': _seconds * 1000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

/// Frames as Flutter reports them, over a stretch.
class _Frames {
  final builds = <int>[], rasters = <int>[], totals = <int>[];
  final rows = <String>[];
  void _cb(List<FrameTiming> fs) {
    for (final f in fs) {
      builds.add(f.buildDuration.inMicroseconds);
      rasters.add(f.rasterDuration.inMicroseconds);
      totals.add(f.totalSpan.inMicroseconds);
      rows.add('${f.timestampInMicroseconds(FramePhase.vsyncStart)},'
          '${f.buildDuration.inMicroseconds},${f.rasterDuration.inMicroseconds},'
          '${f.totalSpan.inMicroseconds}');
    }
  }
  final _clock = Stopwatch();

  void start() {
    _clock.start();
    SchedulerBinding.instance.addTimingsCallback(_cb);
  }

  Map<String, Object> stop(String name) {
    SchedulerBinding.instance.removeTimingsCallback(_cb);
    _clock.stop();
    double pct(List<int> xs, double p) {
      if (xs.isEmpty) return 0;
      final s = [...xs]..sort();
      return s[math.min(s.length - 1, (s.length * p).floor())] / 1000;
    }

    double avg(List<int> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length / 1000;
    final secs = _clock.elapsedMicroseconds / 1e6;
    final out = <String, Object>{
      'fps': double.parse((builds.length / secs).toStringAsFixed(1)),
      'frames': builds.length,
      'build_avg_ms': double.parse(avg(builds).toStringAsFixed(2)),
      'build_p90_ms': pct(builds, 0.9),
      'build_p99_ms': pct(builds, 0.99),
      'build_worst_ms': pct(builds, 1),
      'raster_avg_ms': double.parse(avg(rasters).toStringAsFixed(2)),
      'raster_p90_ms': pct(rasters, 0.9),
      'raster_p99_ms': pct(rasters, 0.99),
      'raster_worst_ms': pct(rasters, 1),
      'late_pct': double.parse(
          (100 * totals.where((t) => t > 16700).length / math.max(1, totals.length)).toStringAsFixed(1)),
    };
    // ignore: avoid_print
    print('PERF $name ${jsonEncode(out)}');
    return out;
  }
}

/// How busy the UI isolate is between frames: a timer that should fire every 4 ms,
/// and how late it fires. Work done outside frames — timers, engine events, decoding —
/// never shows in a frame's build time, and it is exactly what keeps frames from
/// starting on time.
class _Busy {
  final lates = <int>[];
  Timer? _t;
  final _sw = Stopwatch();
  int _last = 0;

  void start() {
    _sw.start();
    _last = 0;
    _t = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final now = _sw.elapsedMicroseconds;
      lates.add(now - _last - 4000);
      _last = now;
    });
  }

  Map<String, Object> stop() {
    _t?.cancel();
    final s = [...lates]..sort();
    double p(double q) => s.isEmpty ? 0 : s[math.min(s.length - 1, (s.length * q).floor())] / 1000;
    return {'timer_late_p50_ms': p(0.5), 'timer_late_p99_ms': p(0.99), 'timer_late_worst_ms': p(1)};
  }
}

/// Where the UI isolate's time went over a stretch, from the VM's own CPU samples:
/// the functions it was found in most, counted inclusively, ours (package:muse) and
/// everyone's.
class _Cpu {
  vm.VmService? _service;
  String? _isolate;
  int _from = 0;

  Future<void> start() async {
    final info = await dev.Service.getInfo();
    final uri = info.serverWebSocketUri;
    if (uri == null) return;
    _service = await vmServiceConnectUri(uri.toString());
    _isolate = dev.Service.getIsolateId(Isolate.current);
    await _service!.clearCpuSamples(_isolate!);
    _from = (await _service!.getVMTimelineMicros()).timestamp!;
  }

  Future<Map<String, Object>> stop() async {
    final s = _service, id = _isolate;
    if (s == null || id == null) return {};
    final now = (await s.getVMTimelineMicros()).timestamp!;
    final got = await s.getCpuSamples(id, _from, now - _from);
    final fns = got.functions ?? const [];
    String name(int i) {
      final f = fns[i].function;
      if (f is vm.FuncRef) {
        final owner = f.owner;
        final cls = owner is vm.ClassRef ? '${owner.name}.' : '';
        final lib = fns[i].resolvedUrl ?? '';
        final short = lib.replaceFirst(RegExp(r'^.*/lib/'), '');
        return '$cls${f.name} [$short]';
      }
      if (f is vm.NativeFunction) return 'native ${f.name}';
      return '$f';
    }

    final inclusive = <String, int>{}, exclusive = <String, int>{};
    final samples = got.samples ?? const [];
    for (final sm in samples) {
      final stack = sm.stack ?? const [];
      if (stack.isEmpty) continue;
      exclusive.update(name(stack.first), (v) => v + 1, ifAbsent: () => 1);
      for (final n in {for (final i in stack) name(i)}) {
        inclusive.update(n, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    List<String> top(Map<String, int> m, bool Function(String) want, int k) {
      final e = m.entries.where((e) => want(e.key)).toList()..sort((a, b) => b.value - a.value);
      return [for (final x in e.take(k)) '${x.value} ${x.key}'];
    }

    await s.dispose();
    return {
      'samples': samples.length,
      'period_us': got.samplePeriod ?? 0,
      'top_self': top(exclusive, (_) => true, 25),
      'top_muse': top(inclusive, (n) => n.contains('src/'), 40),
    };
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.pitch = false;
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: true);

  testWidgets('the booth draws two playing records smoothly', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    SharedPreferences.setMockInitialValues({'muse.booth.logFolded': false});
    final bpms = {701: 126.0, 702: 128.0};
    late HttpServer house;
    late AppState app;
    final one = _track(701, 'Probe One'), two = _track(702, 'Probe Two');
    await tester.runAsync(() async {
      house = await _house({701: _wav(126, 1), 702: _wav(128, 2)}, bpms);
      app = AppState()..api = (ApiClient(baseUrl: 'http://127.0.0.1:${house.port}')..token = 'x');
    });
    addTearDown(() => house.close(force: true));
    final b = app.booth;
    await tester.runAsync(() async {
      await b.init();
      await b.load(b.a, one, at: const Duration(seconds: 60));
      await b.load(b.b, two, at: const Duration(seconds: 20));
      for (final d in b.decks) {
        final native = JustAudioMediaKit.instanceIfRegistered?.playerFor(d.player.platformId!)?.raw.platform;
        if (native is NativePlayer) await native.setProperty('ao', 'null');
      }
    });
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MuseTheme.dark(),
        home: const BoothPage(),
      ),
    ));
    // Settle: the shapes fetched, the fonts in.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.runAsync(() async {
      await b.a.play();
      await b.b.play();
      await b.setCrossfader(0.5);
    });
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    final report = <String, Object>{};

    Future<void> stretch(String name, Duration long, Future<void> Function(int i)? meanwhile) async {
      // Sampling the CPU costs frames of its own, so only when asked for.
      const sample = bool.fromEnvironment('PERF_CPU');
      final cpu = _Cpu();
      if (sample) await tester.runAsync(cpu.start);
      final f = _Frames()..start();
      final busy = _Busy()..start();
      await tester.runAsync(() async {
        final end = DateTime.now().add(long);
        var i = 0;
        while (DateTime.now().isBefore(end)) {
          if (meanwhile != null) await meanwhile(i++);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
      final r = f.stop(name)..addAll(busy.stop());
      // ignore: avoid_print
      print('PERF $name ${jsonEncode(r)}');
      final where = sample ? await tester.runAsync(cpu.stop) ?? const {} : const {};
      const out = String.fromEnvironment('PERF_OUT');
      if (out.isNotEmpty) {
        File('$out/frames-$name.csv').writeAsStringSync('vsync_us,build_us,raster_us,total_us\n${f.rows.join('\n')}\n');
        File('$out/cpu-$name.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(where));
      }
      report[name] = r;
    }

    await stretch('playing', const Duration(seconds: 12), null);
    await stretch('mixing', const Duration(seconds: 12), (i) async {
      final k = (i % 200) / 200;
      await b.setCrossfader(k);
      final Deck d = i.isEven ? b.a : b.b;
      final eq = b.eqOf(d);
      await b.setEq(d, EqSet(low: -20 * k, mid: eq.mid, high: eq.high));
    });
    binding.reportData = {'booth': report};
    await tester.runAsync(() async {
      await b.stopAll();
    });
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 4)));
}
