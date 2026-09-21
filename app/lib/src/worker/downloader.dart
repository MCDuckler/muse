import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'told.dart';
import 'tools.dart';
import 'ytdlp.dart';

/// One job, as the server hands it out.
class IngestJob {
  IngestJob({required this.id, required this.trackId, required this.videoId, this.priority = 100});

  final int id;
  final int trackId;
  final String videoId;
  final int priority;

  /// Somebody is waiting for this one now, as opposed to a backfill.
  bool get urgent => priority <= 90;

  static IngestJob? fromJson(Map<String, dynamic> j) {
    final payload = (j['payload'] ?? const {}) as Map;
    final track = payload['track_id'], video = payload['video_id'];
    if (j['id'] is! int || track is! int || video is! String) return null;
    return IngestJob(
        id: j['id'] as int,
        trackId: track,
        videoId: video,
        priority: (j['priority'] ?? 100) as int);
  }
}

/// The server, as far as a downloader needs it. The app's own client in the app; a
/// pretend one in the tests.
abstract class IngestServer {
  Future<List<IngestJob>> lease({required int limit, required int busy, bool urgentOnly, int wait});
  Future<void> progress(IngestJob job, String stage, {double? percent, String? speed});
  Future<void> complete(IngestJob job, File audio, Map<String, dynamic> meta);
  Future<void> fail(IngestJob job, String reason, {required bool retryable});
  Future<void> release(IngestJob job);
}

/// Running a program: the real thing in the app, a script of answers in the tests.
abstract class Runner {
  /// Lines of output as they come, then the exit code.
  Future<int> stream(String exe, List<String> args, void Function(String line) onLine);
  Future<({int code, String out, String err})> run(String exe, List<String> args);
}

class ProcessRunner implements Runner {
  final _running = <Process>{};

  @override
  Future<int> stream(String exe, List<String> args, void Function(String) onLine) async {
    // Never through a shell: the arguments are a list, and stay one.
    final p = await Process.start(exe, args, runInShell: false);
    _running.add(p);
    final both = [
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(onLine),
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(onLine),
    ];
    final code = await p.exitCode;
    await Future.wait(both);
    _running.remove(p);
    return code;
  }

  @override
  Future<({int code, String out, String err})> run(String exe, List<String> args) async {
    final r = await Process.run(exe, args, runInShell: false);
    return (code: r.exitCode, out: '${r.stdout}', err: '${r.stderr}');
  }

  void killAll() {
    for (final p in _running.toList()) {
      p.kill();
    }
  }
}

/// What one song is doing, for the page that shows it.
class InFlight {
  InFlight(this.job);
  final IngestJob job;
  String stage = 'downloading';
  double? percent;
  String? speed;
}

enum DownloaderState { off, starting, idle, working, coolingDown, noTools, refused }

/// This computer fetching music for the house.
///
/// The loop the Python worker runs, in the app: ask the server for work — holding the
/// request open so a song somebody just asked for starts at once — fetch each with
/// yt-dlp, look at it, hand it over, and say how it went. A few at a time; fewer after
/// YouTube has pushed back, and none at all for ten minutes when it does. When somebody
/// is waiting for a song, nothing else is taken until they have it.
class Downloader extends Told {
  Downloader({
    required this.server,
    required this.findTools,
    Runner? runner,
    this.workDir,
    this.maxSlots = 3,
    this.cooldown = const Duration(minutes: 10),
  }) : runner = runner ?? ProcessRunner();

  final IngestServer server;
  final Future<Tools> Function() findTools;
  final Runner runner;

  /// Where downloads are put while they are being worked on. The system's temp folder
  /// by default; nothing is kept — this computer's disk is not the archive.
  final Directory? workDir;

  /// As many at once as this, at most. Fewer after a challenge; see [slots].
  int maxSlots;
  final Duration cooldown;

  DownloaderState state = DownloaderState.off;
  Tools? tools;
  String? problem;

  /// How many at a time right now: [maxSlots], less one for each time YouTube has
  /// pushed back, earned back by a long run without trouble.
  late int slots = maxSlots;
  int _streak = 0;
  DateTime? coolingUntil;

  final inFlight = <int, InFlight>{};
  int done = 0;
  int failed = 0;

  /// The last things that happened, newest last: the page's log.
  final log = <String>[];

  bool _wanted = false;
  Future<void>? _loop;

  bool get running => _wanted;

  void _say(String line) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    log.add('${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $line');
    if (log.length > 300) log.removeRange(0, log.length - 300);
    notifyListeners();
  }

  void _set(DownloaderState next) {
    if (state == next) return;
    state = next;
    notifyListeners();
  }

  Future<void> start() async {
    if (_wanted) return;
    _wanted = true;
    problem = null;
    _set(DownloaderState.starting);
    final found = await findTools();
    tools = found;
    if (!found.ready) {
      _wanted = false;
      problem = 'Missing: ${found.missing.join(', ')}. ${Tools.howToInstall(found.missing)}';
      _say('cannot start — ${found.missing.join(', ')} not found');
      _set(DownloaderState.noTools);
      return;
    }
    _say('started — up to $slots at a time, ${found.js!.name} for JavaScript');
    _loop = _run();
  }

  /// Stop, and give back whatever was being worked on so it does not sit locked for
  /// the ten minutes a lease lasts.
  Future<void> stop() async {
    if (!_wanted) return;
    _wanted = false;
    final r = runner;
    if (r is ProcessRunner) r.killAll();
    final holding = inFlight.values.map((f) => f.job).toList();
    for (final job in holding) {
      try {
        await server.release(job);
      } catch (_) {
        // The lease expires by itself; this is only the fast way.
      }
    }
    inFlight.clear();
    await _loop;
    _loop = null;
    if (holding.isNotEmpty) _say('gave back ${holding.length} unfinished');
    _say('stopped');
    _set(DownloaderState.off);
  }

  @override
  void dispose() {
    _wanted = false;
    final r = runner;
    if (r is ProcessRunner) r.killAll();
    super.dispose();
  }

  Future<void> _run() async {
    while (_wanted) {
      final cooling = coolingUntil != null && DateTime.now().isBefore(coolingUntil!);
      if (cooling && inFlight.isEmpty) {
        _set(DownloaderState.coolingDown);
        // Visibly alive, asking for nothing.
        await _quietly(() => server.lease(limit: 0, busy: 0, wait: 0));
        await _pause(const Duration(seconds: 5));
        continue;
      }
      final free = cooling ? 0 : slots - inFlight.length;
      if (free <= 0) {
        await _quietly(() => server.lease(limit: 0, busy: inFlight.length, wait: 0));
        await _pause(const Duration(seconds: 2));
        continue;
      }
      _set(inFlight.isEmpty ? DownloaderState.idle : DownloaderState.working);
      List<IngestJob> jobs;
      try {
        jobs = await server.lease(
          limit: free,
          busy: inFlight.length,
          // Somebody is waiting: nothing but more of the same until they have it.
          urgentOnly: inFlight.values.any((f) => f.job.urgent),
          // Held open by the server until there is work; shorter while something is
          // running, so a slot that frees up is filled promptly.
          wait: inFlight.isEmpty ? 25 : 5,
        );
      } on IngestRefused catch (e) {
        _wanted = false;
        problem = e.message;
        _say('the server said no: ${e.message}');
        _set(DownloaderState.refused);
        return;
      } catch (e) {
        _say('could not reach the server: $e');
        await _pause(const Duration(seconds: 10));
        continue;
      }
      for (final job in jobs) {
        inFlight[job.id] = InFlight(job);
        unawaited(_work(job));
      }
      if (jobs.isNotEmpty) _set(DownloaderState.working);
    }
  }

  Future<void> _pause(Duration d) async {
    final until = DateTime.now().add(d);
    while (_wanted && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> _quietly(Future<Object?> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  void _backOff(String why) {
    _streak = 0;
    coolingUntil = DateTime.now().add(cooldown);
    if (slots > 1) slots -= 1;
    _say('YouTube pushed back — pausing ${cooldown.inMinutes} min, then $slots at a time: '
        '${why.length > 120 ? why.substring(0, 120) : why}');
  }

  void _wentWell() {
    _streak += 1;
    if (_streak >= 60 && slots < maxSlots) {
      slots += 1;
      _streak = 0;
      _say('steady for 60 downloads — back up to $slots at a time');
    }
  }

  Future<void> _work(IngestJob job) async {
    try {
      await _handle(job);
    } catch (e) {
      failed += 1;
      _say('job ${job.id} crashed: $e');
      await _quietly(() => server.fail(job, '$e', retryable: true));
    } finally {
      inFlight.remove(job.id);
      if (_wanted) _set(inFlight.isEmpty ? DownloaderState.idle : DownloaderState.working);
      notifyListeners();
    }
  }

  Future<void> _handle(IngestJob job) async {
    final t = tools!;
    if (!isVideoId(job.videoId)) {
      await server.fail(job, 'not a YouTube video id', retryable: false);
      return;
    }
    final flight = inFlight[job.id];
    final dir = await (workDir ?? Directory.systemTemp).createTemp('wetowl-');
    try {
      _say('job ${job.id} ${job.videoId} downloading');
      await _quietly(() => server.progress(job, 'downloading', percent: 0));

      var lastError = '';
      var throttled = false;
      var lastSaid = DateTime.fromMillisecondsSinceEpoch(0);
      final code = await runner.stream(
        t.ytdlp!,
        ytdlpArgs(videoId: job.videoId, outDir: dir.path, jsRuntime: t.js!.name),
        (raw) {
          final line = YtdlpLine.read(raw);
          if (line.throttled) throttled = true;
          if (line.error != null) lastError = line.error!;
          if (line.percent != null) {
            flight?.percent = line.percent;
            flight?.speed = line.speed;
            // Once a second is enough: it crosses the network to a server that then
            // tells every open app.
            final now = DateTime.now();
            if (now.difference(lastSaid) >= const Duration(seconds: 1)) {
              lastSaid = now;
              notifyListeners();
              unawaited(_quietly(() => server.progress(job, 'downloading',
                  percent: line.percent, speed: line.speed)));
            }
          }
        },
      );
      if (!_wanted) return;                 // stopped while it ran: already given back

      final files = [
        await for (final f in dir.list())
          if (f is File && !f.path.endsWith('.json') && !f.path.endsWith('.txt') &&
              !f.path.endsWith('.part'))
            f
      ]..sort((a, b) => a.path.compareTo(b.path));

      if (code != 0 || files.isEmpty) {
        final reason = lastError.isEmpty ? 'yt-dlp failed' : lastError;
        switch (judge(lastError: reason, throttled: throttled)) {
          case Verdict.backOff:
            _backOff(throttled ? 'YouTube is rate-limiting this connection (HTTP 429)' : reason);
            await server.release(job);
          case Verdict.needsAge:
            failed += 1;
            _say('job ${job.id} needs an age-verified account');
            await server.fail(
                job,
                'YouTube wants an age-verified account for this one — it will not '
                'download here.',
                retryable: false);
          case Verdict.dead:
            failed += 1;
            _say('job ${job.id} FAILED: $reason');
            await server.fail(job, reason, retryable: false);
          case Verdict.retry:
            failed += 1;
            _say('job ${job.id} failed, will be tried again: $reason');
            await server.fail(job, reason, retryable: true);
        }
        return;
      }

      var audio = files.first;
      if (!audio.path.endsWith('.m4a')) {
        flight?.stage = 'converting';
        notifyListeners();
        await _quietly(() => server.progress(job, 'converting', percent: 0));
        final to = File('${audio.path.substring(0, audio.path.lastIndexOf('.'))}.m4a');
        final r = await runner.run(t.ffmpeg!,
            ['-v', 'error', '-y', '-i', audio.path, '-c:a', 'aac', '-b:a', '160k', to.path]);
        if (r.code != 0) throw StateError('ffmpeg could not convert it: ${r.err}');
        audio = to;
      }

      flight?.stage = 'measuring';
      notifyListeners();
      await _quietly(() => server.progress(job, 'measuring'));
      final probed = await runner.run(t.ffprobe!, [
        '-v', 'error', '-show_entries',
        'format=duration,bit_rate:stream=codec_name,sample_rate,channels',
        '-of', 'json', audio.path,
      ]);
      final info = _probe(probed.out);
      final heard = await runner.run(t.ffmpeg!, [
        '-nostats', '-hide_banner', '-i', audio.path,
        '-af', 'ebur128=framelog=quiet', '-f', 'null', '-',
      ]);
      final loud = loudnessFrom(heard.err);

      flight?.stage = 'uploading';
      notifyListeners();
      await _quietly(() => server.progress(job, 'uploading'));
      await server.complete(job, audio, {
        'track_id': job.trackId,
        'video_id': job.videoId,
        ...info,
        'loudness_lufs': loud.lufs,
        'gain_db': loud.gainDb,
      });
      done += 1;
      _say('job ${job.id} ready');
      _wentWell();
    } finally {
      // Nothing is kept here.
      await _quietly(() => dir.delete(recursive: true));
    }
  }

  static Map<String, dynamic> _probe(String json) {
    try {
      final d = jsonDecode(json) as Map<String, dynamic>;
      final streams = (d['streams'] ?? const []) as List;
      final st = streams.isEmpty ? const <String, dynamic>{} : streams.first as Map;
      final fmt = (d['format'] ?? const {}) as Map;
      final seconds = double.tryParse('${fmt['duration']}');
      return {
        'codec': st['codec_name'],
        'bitrate': int.tryParse('${fmt['bit_rate']}'),
        'duration_ms': seconds == null ? null : (seconds * 1000).round(),
      };
    } catch (_) {
      return {'codec': null, 'bitrate': null, 'duration_ms': null};
    }
  }
}

/// The server will not give this device work: it has not been allowed to fetch, or the
/// permission was taken away.
class IngestRefused implements Exception {
  IngestRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
