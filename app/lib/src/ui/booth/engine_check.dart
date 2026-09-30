import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart' show platformName;
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/booth/deck_router.dart';
import '../../state/booth/mixer_desktop.dart';
import '../settings_page.dart' show appBuild;
import 'desk/console.dart';

/// Booth → engine check: what this device's deck engine can actually do, asked of it
/// rather than assumed, and sent to the house so it can be read there.
///
/// Every question is one the desk's chain depends on: whether libmpv started at all,
/// which of the desk's filter chains it takes (the kills, the filter, the echo, the
/// ceiling, and which stretcher), whether a band can be turned while it plays, how
/// true its tempo is when a record is pulled to another one's, and whether the stems —
/// six channels of Opus — open as six. Made for the iPhone and the iPad, where the
/// answers were not known; it asks a desk the same.
Future<void> openEngineCheck(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const EngineCheckPage(), fullscreenDialog: true));

class EngineCheckPage extends StatefulWidget {
  const EngineCheckPage({super.key});

  @override
  State<EngineCheckPage> createState() => _EngineCheckPageState();
}

class _EngineCheckPageState extends State<EngineCheckPage> {
  final _lines = <String>[];
  bool _running = false;
  String? _sent;

  void _say(String line) {
    debugPrint('ENGINE $line');
    if (mounted) setState(() => _lines.add(line));
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _lines.clear();
      _sent = null;
    });
    final app = context.read<AppState>();
    try {
      await EngineCheck(app, _say).run();
    } catch (e, st) {
      _say('STOPPED: $e');
      debugPrint('$st');
    }
    try {
      await app.api.sendPlaybackLog(['ENGINE CHECK', ..._lines],
          device: 'engine-check ${platformName()}', build: appBuild);
      if (mounted) setState(() => _sent = 'Sent to the house.');
    } catch (e) {
      if (mounted) setState(() => _sent = 'Could not send it: $e');
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Console.ground,
      appBar: AppBar(
        backgroundColor: Console.panel,
        foregroundColor: Console.ink,
        title: Text('ENGINE CHECK', style: Console.label(12, color: Console.ink)),
      ),
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Plays a click track and a record from your library quietly for about half a '
              'minute, tries the desk\'s filter chains on this device\'s deck engine, and '
              'sends what it found to the house. Leave the booth\'s decks stopped.',
              style: TextStyle(color: Console.quiet, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(_running ? 'Checking…' : 'Check this device'),
            ),
          ),
          if (_sent != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_sent!, style: TextStyle(color: Console.quiet, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final l in _lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: SelectableText(l,
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: l.contains('FAIL') || l.contains('NO ') ? Console.b : Console.ink)),
                  ),
              ],
            ),
          ),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final wasOn = DeckRouter.active;
                  await DeckRouter.setWanted(!wasOn);
                  messenger.showSnackBar(SnackBar(
                      content: Text(wasOn
                          ? 'Decks go back to AVPlayer from the next start.'
                          : 'Decks go to libmpv from the next start.')));
                },
                child: Text(DeckRouter.active
                    ? 'Put the decks back on AVPlayer (from the next start)'
                    : 'Put the decks on libmpv (from the next start)'),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The questions, in order. Kept apart from the page so it can be read as a list.
class EngineCheck {
  EngineCheck(this.app, this.say);

  final AppState app;
  final void Function(String) say;

  Future<void> run() async {
    say('device ${platformName()} · build ${appBuild.isEmpty ? 'dev' : appBuild}');
    say('decks routed to libmpv: ${DeckRouter.active ? 'yes' : 'no'}'
        '${DeckRouter.failed == null ? '' : ' (libmpv failed: ${DeckRouter.failed})'}');
    final m = app.booth.mixer;
    say('mixer ${m.runtimeType}: kill=${m.canKill} filter=${m.canFilter} '
        'stem=${m.canStem} shift=${m.canShift} gate=${m.canGate}');
    if (JustAudioMediaKit.instanceIfRegistered == null) {
      say('FAIL no libmpv here: nothing more to check');
      return;
    }

    final dir = await getTemporaryDirectory();
    final wav = File('${dir.path}/engine-check-clicks.wav');
    await wav.writeAsBytes(_clicks(seconds: 30, bpm: 120));

    final player = AudioPlayer(engine: DeckRouter.active ? DeckRouter.mpv : null);
    try {
      await player.setVolume(0.25);
      await player.setFilePath(wav.path);
      final mpv = _native(player);
      if (mpv == null) {
        say('FAIL the check player is not on libmpv');
        return;
      }
      // What mpv complains of while this runs, said at the end.
      final raw = JustAudioMediaKit.instanceIfRegistered?.playerFor(player.platformId!)?.raw;
      final complaints = <String>[];
      final heard = raw?.stream.error.listen(complaints.add);
      say('mpv ${await _prop(mpv, 'mpv-version')} · ffmpeg ${await _prop(mpv, 'ffmpeg-version')}');
      say('audio out ${await _prop(mpv, 'current-ao')}');
      await DeckRouter.wake();
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // Moving at all, before any chain goes on?
      final p0 = player.position, t0 = await _prop(mpv, 'time-pos');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      say('bare, 1.5 s: position ${p0.inMilliseconds}→${player.position.inMilliseconds} ms · '
          'mpv time-pos $t0→${await _prop(mpv, 'time-pos')} · ${await _state(mpv)}');

      // The chains, in the order the desk tries them.
      String? took;
      var tried = 0;
      for (final chain in DesktopMixer.standingFor(500)) {
        tried++;
        try {
          await mpv.setProperty('af', chain);
          final got = await mpv.getProperty('af');
          if (got.contains('wetowl')) {
            took = chain;
            break;
          }
        } catch (_) {}
      }
      if (took == null) {
        say('FAIL none of the desk\'s $tried chains went on');
        // Which filters are missing, one at a time.
        for (final f in const ['asplit', 'lowpass=f=300', 'highpass=f=300', 'volume=1', 'amix=inputs=1',
          'aecho=0.7:0.8:300:0.5', 'alimiter', 'aloop=loop=0:size=1', 'scaletempo2', 'rubberband']) {
          try {
            await mpv.setProperty('af', f == 'scaletempo2' || f == 'rubberband' ? f : 'lavfi=[$f]');
            say('  filter ${f.split('=').first}: ${(await mpv.getProperty('af')).isEmpty ? 'NO' : 'yes'}');
          } catch (e) {
            say('  filter ${f.split('=').first}: NO ($e)');
          }
        }
      } else {
        final stretcher = took.split(',').last;
        say('chain ${tried == 1 ? 'first' : 'number $tried'} of the desk\'s went on: '
            '${took.contains('alimiter') ? 'with a ceiling' : 'NO ceiling'}, stretcher $stretcher');
        // Turned while it plays, as the kills are. What mpv refuses is said in its log
        // rather than thrown — mpv 0.36, the Apple builds' own, refused every one of
        // these while this counted them as taken — so the log is what is counted.
        final refused = <String>[];
        final refusing = raw?.stream.log.listen((l) {
          if (l.level == 'error' && l.text.contains('af-command')) refused.add(l.text);
        });
        var turned = 0;
        for (final (target, value) in const [('volume@low', '0.01'), ('volume@low', '1'),
          ('volume@es', '0.5'), ('volume@es', '0')]) {
          try {
            await mpv.command(['af-command', 'wetowl', 'volume', value, target]);
            turned++;
          } catch (e) {
            say('FAIL af-command $target: $e');
          }
        }
        try {
          await mpv.command(['af-command', 'wetowl', 'f', '400', 'highpass@hp']);
          turned++;
        } catch (e) {
          say('FAIL af-command highpass@hp: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await refusing?.cancel();
        turned -= refused.length;
        say('bands turned while playing: $turned of 5'
            '${refused.isEmpty ? '' : ' — FAIL mpv refused: ${refused.first}'}');
      }

      // How true the tempo is, pulled down as a record synced to a slower one is.
      say('mpv state: ${await _state(mpv)} · just_audio ${player.processingState.name}, '
          '${player.playing ? 'playing' : 'not playing'} at ${player.position.inMilliseconds} ms');
      for (final speed in const [0.976, 1.04]) {
        await player.setSpeed(speed);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final from = player.position;
        final mpvFrom = double.tryParse(await _prop(mpv, 'time-pos'));
        final clock = Stopwatch()..start();
        await Future<void>.delayed(const Duration(seconds: 6));
        final seconds = clock.elapsedMicroseconds / 1e6;
        final moved = (player.position - from).inMicroseconds / 1e6;
        final mpvTo = double.tryParse(await _prop(mpv, 'time-pos'));
        final ratio = moved / seconds;
        final mpvRatio = mpvFrom == null || mpvTo == null ? null : (mpvTo - mpvFrom) / seconds;
        say('speed ${speed.toStringAsFixed(3)}: position ${ratio.toStringAsFixed(4)}× '
            '(${((ratio / speed - 1) * 1000).toStringAsFixed(2)} ‰ off) · mpv clock '
            '${mpvRatio?.toStringAsFixed(4) ?? '?'}× · ${await _state(mpv)}');
      }
      await player.setSpeed(1);
      await heard?.cancel();
      say('mpv said ${complaints.length} error${complaints.length == 1 ? '' : 's'}'
          '${complaints.isEmpty ? '' : ', first: ${complaints.take(3).join(' | ')}'}');
      await player.stop();

      await _twoDecks(wav);

      // Stems: six channels, if a record here has them.
      final stems = await _aRecordWithStems();
      if (stems == null) {
        say('stems: no record in the last 40 added has stems yet — not checked');
      } else {
        await player.setAudioSource(AudioSource.uri(Uri.parse(app.api.stemUrl(stems, 'stems')),
            headers: app.api.streamHeaders));
        final mpv2 = _native(player);
        if (mpv2 != null) {
          await mpv2.setProperty('ad-lavc-downmix', 'no');
          await player.play();
          await Future<void>.delayed(const Duration(seconds: 2));
          final channels = await _prop(mpv2, 'audio-params/channel-count');
          say('stems of "${stems.displayTitle}": ${channels == '6' ? '6 channels' : 'FAIL $channels channels'}'
              ' · codec ${await _prop(mpv2, 'audio-codec-name')}');
          var went = false;
          for (final chain in DesktopMixer.stemStandingFor(500)) {
            try {
              await mpv2.setProperty('af', chain);
              if ((await mpv2.getProperty('af')).contains('wetowl')) {
                went = true;
                break;
              }
            } catch (_) {}
          }
          say('stem chain: ${went ? 'went on' : 'FAIL none went on'}');
          if (went) {
            try {
              await mpv2.command(['af-command', 'wetowl', 'volume', '0', 'volume@v']);
              say('voice taken out while playing: yes');
            } catch (e) {
              say('FAIL voice out: $e');
            }
          }
          await player.stop();
        }
      }

      if (!kIsWeb) {
        say('memory ${(ProcessInfo.currentRss / 1e6).round()} MB now');
      }
      final main = app.player?.raw;
      if (main != null) {
        say('the app\'s own player: ${main.processingState.name}, '
            '${main.playing ? 'playing' : 'not playing'}');
      }
      say('done');
    } finally {
      await player.dispose();
    }
  }

  /// Two decks on the same click track, started together, read as the booth reads
  /// them: every 20 ms for 8 s, each deck's position. Two things come out of it.
  /// How smooth each deck's clock is — its readings against a straight line through
  /// them, which is what the booth's sync steers by: steps the size of an audio
  /// buffer make it chase noise. And how far apart the two read, which on the same
  /// record started together should be only the start-up difference, holding still.
  Future<void> _twoDecks(File wav) async {
    final a = AudioPlayer(engine: DeckRouter.active ? DeckRouter.mpv : null);
    final b = AudioPlayer(engine: DeckRouter.active ? DeckRouter.mpv : null);
    try {
      await a.setVolume(0.15);
      await b.setVolume(0.15);
      await a.setFilePath(wav.path);
      await b.setFilePath(wav.path);
      for (final p in [a, b]) {
        final mpv = _native(p);
        if (mpv != null) {
          for (final chain in DesktopMixer.standingFor(500)) {
            try {
              await mpv.setProperty('af', chain);
              if ((await mpv.getProperty('af')).contains('wetowl')) break;
            } catch (_) {}
          }
        }
      }
      unawaited(a.play());
      unawaited(b.play());
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final clock = Stopwatch()..start();
      final t = <double>[], pa = <double>[], pb = <double>[];
      var stepsA = 0, stepsB = 0;
      double? lastA, lastB;
      while (clock.elapsedMilliseconds < 8000) {
        final x = clock.elapsedMicroseconds / 1000;
        final ya = a.position.inMicroseconds / 1000, yb = b.position.inMicroseconds / 1000;
        if (lastA != null && ya == lastA) stepsA++;
        if (lastB != null && yb == lastB) stepsB++;
        lastA = ya;
        lastB = yb;
        t.add(x);
        pa.add(ya);
        pb.add(yb);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      String fit(List<double> y) {
        final n = t.length;
        final mx = t.reduce((p, q) => p + q) / n, my = y.reduce((p, q) => p + q) / n;
        var sxy = 0.0, sxx = 0.0;
        for (var i = 0; i < n; i++) {
          sxy += (t[i] - mx) * (y[i] - my);
          sxx += (t[i] - mx) * (t[i] - mx);
        }
        final slope = sxy / sxx;
        final res = [for (var i = 0; i < n; i++) (y[i] - (my + slope * (t[i] - mx))).abs()]..sort();
        return 'rate ${slope.toStringAsFixed(4)}×, off the line: half within '
            '${res[n ~/ 2].toStringAsFixed(1)} ms, worst ${res.last.toStringAsFixed(1)} ms';
      }
      final gaps = [for (var i = 0; i < t.length; i++) pa[i] - pb[i]];
      final g = [...gaps]..sort();
      final spread = [for (final x in gaps) (x - g[g.length ~/ 2]).abs()]..sort();
      say('two decks, ${t.length} readings: A ${fit(pa)} ($stepsA unchanged readings)');
      say('  B ${fit(pb)} ($stepsB unchanged readings)');
      say('  A−B: ${g[g.length ~/ 2].toStringAsFixed(1)} ms typical, moving by half within '
          '${spread[spread.length ~/ 2].toStringAsFixed(1)} ms, nine tenths within '
          '${spread[(spread.length * 0.9).floor()].toStringAsFixed(1)} ms, worst ${spread.last.toStringAsFixed(1)} ms');
      final ma = _native(a);
      if (ma != null) {
        say('  mpv buffer: audio-buffer=${await _prop(ma, 'audio-buffer')} '
            'ao-delay?=${await _prop(ma, 'audio-delay')} '
            'avsync=${await _prop(ma, 'avsync')}');
      }
    } catch (e) {
      say('FAIL two decks: $e');
    } finally {
      await a.dispose();
      await b.dispose();
    }
  }

  NativePlayer? _native(AudioPlayer p) {
    final id = p.platformId;
    final raw = id == null ? null : JustAudioMediaKit.instanceIfRegistered?.playerFor(id)?.raw;
    final platform = raw?.platform;
    return platform is NativePlayer ? platform : null;
  }

  /// What mpv says it is doing: paused, idle for want of data or of an output.
  Future<String> _state(NativePlayer mpv) async => [
        for (final p in const ['pause', 'core-idle', 'paused-for-cache', 'eof-reached',
          'audio-device', 'speed', 'time-pos'])
          '$p=${await _prop(mpv, p)}'
      ].join(' ');

  Future<String> _prop(NativePlayer mpv, String name) async {
    try {
      return await mpv.getProperty(name);
    } catch (e) {
      return '? ($e)';
    }
  }

  Future<Track?> _aRecordWithStems() async {
    final recent = (await app.api.libraryTracks(sort: 'added', limit: 40, readyOnly: true)).items;
    for (final t in recent) {
      try {
        if ((await app.api.partsHere(t.id)).contains('stems')) return t;
      } catch (_) {}
    }
    return null;
  }

  /// A click track: a short 1 kHz burst on every beat, 44.1 kHz mono 16-bit.
  static Uint8List _clicks({required int seconds, required int bpm}) {
    const rate = 44100;
    final n = rate * seconds;
    final pcm = Int16List(n);
    final every = (rate * 60 / bpm).round();
    for (var i = 0; i < n; i++) {
      final at = i % every;
      if (at < 220) {
        pcm[i] = (math.sin(2 * math.pi * 1000 * at / rate) * 20000 * (1 - at / 220)).round();
      }
    }
    final data = pcm.buffer.asUint8List();
    final b = BytesBuilder();
    void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
    void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
    b.add('RIFF'.codeUnits);
    u32(36 + data.length);
    b.add('WAVEfmt '.codeUnits);
    u32(16);
    u16(1);
    u16(1);
    u32(rate);
    u32(rate * 2);
    u16(2);
    u16(16);
    b.add('data'.codeUnits);
    u32(data.length);
    b.add(data);
    return b.toBytes();
  }
}
