// This computer taking records apart for the pool: anybody's, not only its own.
//
// The same shape as the downloader beside it (downloader.dart): ask the server for
// work, holding the request open until there is some; do it; hand it in; say how it
// went. One record at a time — a split wants every core or the whole graphics card —
// and never at the same time as a split of the app's own (withSeparatorLock).
//
// The parts it makes are written straight into the app's own parts folder under the
// names the booth looks for, so a record split here for somebody else is one this
// computer's booth never has to ask anybody about.
//
// Nothing here may import Flutter: the windowless helper (bin/wetowl_fetch.dart) runs
// this too, so records go on being taken apart with the app shut.
import 'dart:async';
import 'dart:io';

import 'separation_kit.dart';
import 'told.dart';

/// One record to take apart, as the server hands it out.
class SplitJob {
  SplitJob({required this.id, required this.trackId, this.own = false});

  final int id;
  final int trackId;

  /// Claimed by this computer for its own person, rather than handed out by the pool.
  final bool own;

  static SplitJob? fromJson(Map<String, dynamic> j, {bool own = false}) {
    final payload = (j['payload'] ?? const {}) as Map;
    final track = payload['track_id'];
    if (j['id'] is! int || track is! int) return null;
    return SplitJob(id: j['id'] as int, trackId: track, own: own);
  }
}

/// The server, as far as taking records apart for it goes.
abstract class SplitServer {
  /// The house the separator's own files are fetched from.
  String get house;
  Future<List<SplitJob>> lease({required Map<String, dynamic> pool, int wait = 25});
  Future<SplitJob?> claim(int trackId);
  Future<void> progress(SplitJob job, String stage, double? percent);
  Future<void> handIn(SplitJob job, Map<String, File> parts, {double? seconds});
  Future<void> fail(SplitJob job, String reason, {required bool retryable});
  Future<void> release(SplitJob job);

  /// The record itself, into [into].
  Future<void> fetchRecord(int trackId, File into, {void Function(int got, int? total)? progress});
}

enum SplitterState { off, starting, idle, working, noSeparator, refused }

/// What the one record being taken apart here is doing.
class InSplit {
  InSplit(this.job);
  final SplitJob job;
  String stage = 'fetching';
  double? percent;

  /// 'cuda' or 'cpu', once the separator says.
  String? device;
  final DateTime started = DateTime.now();
}

/// The parts, in the order the booth thinks of them. The same the server keeps —
/// `stems` the three that add back up to the record in one six-channel file, which a
/// stem deck plays (DesktopMixer).
const splitParts = ['instrumental', 'drums', 'music', 'vocals', 'stems'];

/// A part's file extension: the stems are Opus, the rest AAC.
String partExt(String name) => name == 'stems' ? 'opus' : 'm4a';

/// The version the parts are made at: the trained separator's (render_parts_io.dart).
const splitVersion = 2;

class Splitter extends Told {
  Splitter({
    required this.server,
    required this.appFolder,
    required this.findFfmpeg,
    required this.pool,
    this.program,
  });

  final SplitServer server;

  /// The app's own folder: the separator's files are fetched into `separation` here,
  /// the parts written into `stems`, and the lock is kept here.
  final Directory appFolder;

  final Future<String?> Function() findFfmpeg;

  /// What this computer says about itself when it asks for work.
  final Map<String, dynamic> Function() pool;

  /// The separator program; found beside the running one when not given.
  final String? program;

  SplitterState state = SplitterState.off;
  String? problem;
  InSplit? now;
  int done = 0, failed = 0;

  /// Whether the separator runs on the graphics card here. Known once started.
  bool gpu = false;

  final log = <String>[];

  bool _wanted = false;
  bool _gpuOff = false;

  /// Failures on the graphics card in a row. One is no verdict on the card — a file
  /// pulled from under the separator fails it just the same — so the processor
  /// takes over for that record only, and for good only after [_gpuGivesUp].
  int _gpuMisses = 0;
  static const _gpuGivesUp = 2;
  Future<void>? _loop;
  Process? _running;

  bool get running => _wanted;

  Directory get partsFolder => Directory('${appFolder.path}${Platform.pathSeparator}stems');

  File partFile(int trackId, String name) => File(
      '${partsFolder.path}${Platform.pathSeparator}$trackId-$name-v$splitVersion.${partExt(name)}');

  void _say(String line) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    log.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $line');
    if (log.length > 300) log.removeRange(0, log.length - 300);
    notifyListeners();
  }

  void _set(SplitterState s) {
    if (state == s) return;
    state = s;
    notifyListeners();
  }

  Future<String?> _program() async => program ?? await separatorProgram();

  /// Whether this computer can take records apart at all, and how: the program is
  /// beside the app, and the runtime is built for this processor. Asks about the
  /// graphics card the first time.
  Future<bool> able() async {
    final p = await _program();
    if (p == null || runtimeFile == null) return false;
    gpu = cudaFiles != null && await cudaHere(p);
    return true;
  }

  Future<void> start() async {
    if (_wanted) return;
    _wanted = true;
    problem = null;
    _set(SplitterState.starting);
    if (!await able()) {
      _wanted = false;
      problem = 'The separator is not part of this copy of WetOwl.';
      _set(SplitterState.noSeparator);
      return;
    }
    _say('started — on the ${gpu ? 'graphics card' : 'processor'}');
    _loop = _run();
  }

  Future<void> stop() async {
    if (!_wanted) return;
    _wanted = false;
    final job = now?.job;
    _running?.kill();
    if (job != null && !job.own) {
      try {
        await server.release(job);
      } catch (_) {}
    }
    // Waited for only while a record was in hand. A loop that is only asking for work
    // hears no in its own time, and gives back whatever it is handed after this.
    if (job != null) await _loop;
    _loop = null;
    _say('stopped');
    _set(SplitterState.off);
  }

  @override
  void dispose() {
    _wanted = false;
    _running?.kill();
    super.dispose();
  }

  Future<void> _run() async {
    while (_wanted) {
      if (now != null) {
        // An own split is running: nothing else is asked for until it is done.
        await _pause(const Duration(seconds: 2));
        continue;
      }
      _set(SplitterState.idle);
      List<SplitJob> jobs;
      try {
        jobs = await server.lease(pool: pool(), wait: 25);
      } on SplitRefused catch (e) {
        _wanted = false;
        problem = e.message;
        _say('the server said no: ${e.message}');
        _set(SplitterState.refused);
        return;
      } catch (e) {
        _say('could not reach the server: $e');
        await _pause(const Duration(seconds: 10));
        continue;
      }
      for (final job in jobs) {
        if (!_wanted) {
          await _quietly(() => server.release(job));
          continue;
        }
        await _take(job);
      }
    }
  }

  /// Take the record the person at this computer asked for apart now, ahead of the
  /// pool: claimed from the queue so nobody else starts on it too. Answers the parts
  /// made, by name; null where there was nothing to claim — it is done, or another
  /// computer has it — or it failed. [audio] is the record where it is already on this
  /// computer.
  Future<Map<String, String>?> splitNow(int trackId,
      {String? audio, void Function(InSplit)? heard}) async {
    SplitJob? job;
    try {
      job = await server.claim(trackId);
    } catch (e) {
      _say('could not claim track $trackId: $e');
      return null;
    }
    if (job == null) return null;
    return _take(job, audio: audio);
  }

  Future<Map<String, String>?> _take(SplitJob job, {String? audio}) => _work(job, audio: audio);

  Future<Map<String, String>?> _work(SplitJob job, {String? audio}) async {
    final flight = now = InSplit(job);
    _set(SplitterState.working);
    final clock = Stopwatch()..start();
    File? borrowed;
    try {
      _say('track ${job.trackId}${job.own ? ' (asked for here)' : ''}: taking apart');
      final ffmpeg = await findFfmpeg();
      if (ffmpeg == null) throw StateError('no ffmpeg on this computer');
      var record = audio;
      if (record == null) {
        final work = Directory('${appFolder.path}${Platform.pathSeparator}split-work');
        await work.create(recursive: true);
        borrowed = File('${work.path}${Platform.pathSeparator}${job.trackId}.audio');
        flight.stage = 'fetching';
        notifyListeners();
        await server.fetchRecord(job.trackId, borrowed, progress: (got, total) {
          if (total != null && total > 0) {
            flight.percent = got / total;
            notifyListeners();
          }
        });
        record = borrowed.path;
      }

      final toSplit = record;
      await partsFolder.create(recursive: true);
      final into = {for (final p in splitParts) p: partFile(job.trackId, p).path};
      var gpuNow = !_gpuOff;
      // The separator is this computer's to share with the app's own splits: held
      // only while it runs. Held through the fetching and the handing in as well, the
      // record somebody was about to play waited a minute and a half for each of the
      // pool's, and the card sat idle most of it.
      flight.stage = 'waiting for the card';
      notifyListeners();
      await withSeparatorLock(appFolder, () async {
        while (true) {
          flight
            ..stage = 'getting the separator'
            ..percent = null;
          notifyListeners();
          final s = await readySeparator(server.house,
              into: kitDirIn(appFolder),
              gpu: gpuNow,
              program: await _program(), fetching: (f, got, total) {
            flight.percent = total == null ? null : got / total;
            notifyListeners();
          });
          if (s == null) throw StateError('no separator for this computer');
          flight
            ..stage = 'separating'
            ..percent = 0
            ..device = s.gpu ? 'cuda' : 'cpu';
          notifyListeners();
          var lastSaid = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            await runSeparator(s,
                ffmpeg: ffmpeg,
                audio: toSplit,
                into: into,
                upToSeconds: 12 * 60,
                progress: (f) {
                  flight.percent = f;
                  notifyListeners();
                  final t = DateTime.now();
                  if (t.difference(lastSaid) >= const Duration(seconds: 2)) {
                    lastSaid = t;
                    unawaited(_quietly(() => server.progress(job, 'separating', f)));
                  }
                },
                device: (d) {
                  flight.device = d.startsWith('cuda') ? 'cuda' : 'cpu';
                  notifyListeners();
                },
                started: (p) => _running = p);
            if (gpuNow && flight.device == 'cuda') _gpuMisses = 0;
            break;
          } catch (e) {
            if (s.gpu && gpuNow) {
              _gpuMisses++;
              if (_gpuMisses >= _gpuGivesUp) {
                _gpuOff = true;
                _say('the graphics card failed $_gpuMisses times running, so the processor '
                    'from now on: $e');
              } else {
                _say('the graphics card failed on it, so the processor for this one: $e');
              }
              gpuNow = false;
              continue;
            }
            rethrow;
          } finally {
            _running = null;
          }
        }
      });

      flight
        ..stage = 'uploading'
        ..percent = null;
      notifyListeners();
      await _quietly(() => server.progress(job, 'uploading', null));
      final seconds = clock.elapsedMilliseconds / 1000;
      // Handed in again if the house was not there to take it (a restart, a 502): the
      // parts are on disk, and throwing away a minute of the card for one bad answer
      // is how splits went missing.
      for (var attempt = 1;; attempt++) {
        try {
          await server.handIn(job, {for (final e in into.entries) e.key: File(e.value)},
              seconds: seconds);
          break;
        } catch (e) {
          if (attempt >= 4 || !_wanted) rethrow;
          _say('track ${job.trackId}: could not hand it in ($e), again in ${attempt * 10} s');
          await _pause(Duration(seconds: attempt * 10));
          if (!_wanted) rethrow;
        }
      }
      done++;
      _say('track ${job.trackId}: parts handed in · ${seconds.toStringAsFixed(0)} s '
          'on the ${flight.device == 'cuda' ? 'card' : 'processor'}');
      return into;
    } catch (e) {
      failed++;
      _say('track ${job.trackId} failed: $e');
      // Stopped on purpose: given back, not failed.
      if (!_wanted && !job.own) {
        await _quietly(() => server.release(job));
      } else {
        await _quietly(() => server.fail(job, '$e', retryable: true));
      }
      return null;
    } finally {
      if (borrowed != null) await _quietly(() => borrowed!.delete());
      now = null;
      if (_wanted) _set(SplitterState.idle);
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ sharing
  /// Records whose parts were made here before they could be shared — by a build from
  /// before the pool, or while the house could not be reached — and have not been
  /// handed in yet. Counted while [shareWhatIsHere] runs, for the pool page.
  int sharing = 0, shared = 0;

  File get _sharedList => File('${appFolder.path}${Platform.pathSeparator}shared-parts.json');

  /// Hand in every record taken apart on this computer that the house has not got,
  /// one at a time. Each is claimed from the queue first — the house queues it if it
  /// has to — so nobody else is taking the same record apart meanwhile; one the house
  /// already has, or that another computer is doing, is simply left. Remembered, so a
  /// record is asked about once.
  Future<void> shareWhatIsHere() async {
    final done = <int>{};
    try {
      final j = await _sharedList.readAsString();
      done.addAll([for (final x in (j.isEmpty ? const [] : _decodeIds(j))) x]);
    } catch (_) {}
    final byTrack = <int, Map<String, File>>{};
    try {
      if (!await partsFolder.exists()) return;
      await for (final f in partsFolder.list()) {
        if (f is! File) continue;
        final m =
            RegExp(r'^(\d+)-([a-z]+)-v(\d+)\.(m4a|opus)$').firstMatch(f.uri.pathSegments.last);
        if (m == null || int.parse(m.group(3)!) != splitVersion) continue;
        final id = int.parse(m.group(1)!);
        if (done.contains(id) || !splitParts.contains(m.group(2))) continue;
        (byTrack[id] ??= {})[m.group(2)!] = f;
      }
    } catch (_) {
      return;
    }
    if (byTrack.isEmpty) return;
    sharing = byTrack.length;
    shared = 0;
    _say('sharing ${byTrack.length} records taken apart here before');
    for (final e in byTrack.entries) {
      try {
        final job = await server.claim(e.key);
        if (job != null) {
          await server.handIn(job, e.value);
          shared++;
          notifyListeners();
        }
        // Nothing to claim: the house has them, or another computer is on it.
        done.add(e.key);
      } on SplitRefused {
        break;
      } catch (err) {
        // Not a record the house knows any more, say: tried again next time.
        _say('could not share track ${e.key}: $err');
      }
      try {
        await _sharedList.writeAsString('[${done.join(',')}]');
      } catch (_) {}
    }
    _say('shared $shared of ${byTrack.length}');
    sharing = 0;
    notifyListeners();
  }

  static List<int> _decodeIds(String j) => [
        for (final x in j.replaceAll(RegExp(r'[\[\]\s]'), '').split(','))
          if (int.tryParse(x) case final n?) n
      ];

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
}

/// The server will not give this computer splits: an admin has kept it out.
class SplitRefused implements Exception {
  SplitRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
