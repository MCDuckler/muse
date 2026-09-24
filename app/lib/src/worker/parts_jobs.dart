// Taking records apart, as jobs you can watch: which record, what stage it is at,
// how far through, how long it has left, and when it was ready.
//
// A split is a minute and a half of every core the computer will give it, and the
// automix asks for them three records ahead — so it is background work in the way a
// download is, and it is shown the way downloads are: a queue with the one being
// done now, what is waiting, what is ready, and what failed and why.
import 'package:flutter/foundation.dart';

import '../api/models.dart';

/// Where a record is on its way to being in parts.
enum PartsStage {
  /// In the line, behind the one being taken apart now.
  waiting,

  /// The record itself being fetched from the house, to be taken apart here.
  fetching,

  /// The separator's own files, the first time: the network and its runtime.
  gettingSeparator,

  /// Being taken apart.
  separating,

  /// Asked of the pool: waiting for a computer with a graphics card, or being taken
  /// apart by one ([PartsJob.device] says which). The parts come from the house.
  pooled,

  ready,
  failed,
  cancelled,
}

/// One record's parts being made.
class PartsJob {
  PartsJob(this.trackId, {this.track}) : queued = DateTime.now();

  final int trackId;

  /// What it is, for the rows: title, artist, artwork.
  Track? track;

  PartsStage stage = PartsStage.waiting;

  /// How far through the stage it is at, 0 to 1 — or null when that cannot be told.
  double? progress;

  /// For the stages that fetch something: how much has come, of how much.
  int? bytes, total;

  final DateTime queued;
  DateTime? started, stageStarted, finished;

  /// Why it failed, in a few words.
  String? error;

  /// The parts it makes.
  List<String> parts = const [];

  /// Made by the trained separator, rather than the old arithmetic.
  bool trained = true;

  /// The computer in the pool taking it apart, when that is not this one.
  String? device;

  String get title => track?.displayTitle ?? 'Track $trackId';
  String get artist => track?.artistLine ?? '';

  bool get active =>
      stage == PartsStage.fetching ||
      stage == PartsStage.gettingSeparator ||
      stage == PartsStage.separating ||
      stage == PartsStage.pooled;
  bool get done => stage == PartsStage.ready || stage == PartsStage.failed || stage == PartsStage.cancelled;

  /// How long the stage it is at has left, from how fast it has gone so far. Null
  /// until there is enough of it to tell.
  Duration? get left {
    final p = progress, since = stageStarted;
    if (p == null || since == null || p < 0.04 || p >= 1) return null;
    final spent = DateTime.now().difference(since);
    return Duration(microseconds: (spent.inMicroseconds * (1 - p) / p).round());
  }

  /// How long it took, once it is done.
  Duration? get took {
    final a = started, b = finished;
    return a == null || b == null ? null : b.difference(a);
  }
}

/// Every job this session, the one running first. Listened to by the booth and the
/// downloads page.
class PartsJobs extends ChangeNotifier {
  final _jobs = <int, PartsJob>{};

  /// Wired by whoever runs the queue (render_parts): what the buttons do.
  void Function(int trackId)? onCancel, onPromote, onRetry;

  /// The job for [trackId], or null when it was never asked for this session.
  PartsJob? of(int trackId) => _jobs[trackId];

  List<PartsJob> _where(bool Function(PartsJob) test) =>
      [for (final j in _jobs.values) if (test(j)) j];

  /// Every job this session, in the order asked.
  List<PartsJob> get all => _jobs.values.toList();

  List<PartsJob> get running => _where((j) => j.active);
  List<PartsJob> get waiting => _where((j) => j.stage == PartsStage.waiting);

  /// Newest first.
  List<PartsJob> get ready => _where((j) => j.stage == PartsStage.ready)
    ..sort((a, b) => b.finished!.compareTo(a.finished!));
  List<PartsJob> get failed => _where((j) => j.stage == PartsStage.failed);

  bool get busy => _jobs.values.any((j) => j.active || j.stage == PartsStage.waiting);

  /// A job for [trackId] — a fresh one if the last was finished, or the same one
  /// with more parts to make — at [stage] if that is said, in one change.
  PartsJob add(int trackId,
      {Track? track, List<String> parts = const [], bool trained = true, PartsStage? stage}) {
    final was = _jobs[trackId];
    final fresh = was == null || was.done;
    final job = fresh ? PartsJob(trackId, track: track ?? was?.track) : was;
    if (track != null) job.track = track;
    if (parts.isNotEmpty) job.parts = fresh ? parts : {...job.parts, ...parts}.toList();
    job.trained = trained;
    // Newest last, so the line reads in the order asked — but one already waiting
    // keeps its place: a second part of it is not a reason to go to the back.
    if (fresh || job.stage != PartsStage.waiting) {
      _jobs.remove(trackId);
      _jobs[trackId] = job;
    }
    if (stage != null) {
      _move(job, stage);
    }
    _notify(now: true);
    return job;
  }

  /// Forget [trackId] altogether: a job that turned out not to be one.
  void drop(int trackId) {
    if (_jobs.remove(trackId) != null) _notify(now: true);
  }

  /// Move [trackId] to [stage].
  void stage(int trackId, PartsStage stage, {String? error, bool? trained}) {
    final j = _jobs[trackId];
    if (j == null) return;
    if (trained != null) j.trained = trained;
    _move(j, stage, error: error);
    _notify(now: true);
  }

  void _move(PartsJob j, PartsStage stage, {String? error}) {
    final was = j.stage;
    j.stage = stage;
    j.progress = null;
    j.bytes = j.total = null;
    j.stageStarted = DateTime.now();
    // The clock for "took" starts when this computer starts on it, not when it was
    // asked for: time spent in the line is the line's, not the record's.
    if (j.active && (j.started == null || was == PartsStage.waiting)) {
      j.started = DateTime.now();
    }
    if (j.done) j.finished = DateTime.now();
    j.error = error;
  }

  /// How far through its stage [trackId] is.
  void progress(int trackId, double? p, {int? bytes, int? total}) {
    final j = _jobs[trackId];
    if (j == null) return;
    j.progress = p?.clamp(0.0, 1.0);
    j.bytes = bytes;
    j.total = total;
    _notify();
  }

  /// Where [trackId] is in the line: 1 is next. Null when it is not waiting.
  int? placeOf(int trackId) {
    final line = waiting;
    final i = line.indexWhere((j) => j.trackId == trackId);
    return i < 0 ? null : i + 1;
  }

  /// Put [trackId] first in the line, among the waiting.
  void first(int trackId) {
    final j = _jobs.remove(trackId);
    if (j == null) return;
    // The map is in the order asked; waiting jobs are read off it in that order, so
    // one put first is taken out and put back in front of the others.
    final rest = Map.of(_jobs);
    _jobs
      ..clear()
      ..[trackId] = j
      ..addAll(rest);
    _notify(now: true);
  }

  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pending = false;

  /// At most ten times a second for progress: a fetch reports every few kilobytes.
  void _notify({bool now = false}) {
    final t = DateTime.now();
    if (now || t.difference(_last) > const Duration(milliseconds: 100)) {
      _last = t;
      notifyListeners();
      return;
    }
    if (_pending) return;
    _pending = true;
    Future<void>.delayed(const Duration(milliseconds: 110), () {
      _pending = false;
      _last = DateTime.now();
      notifyListeners();
    });
  }

  /// Forget every job: between tests, where one track number is reused by the next.
  void forget() {
    _jobs.clear();
    notifyListeners();
  }
}

/// The one queue of parts being made on this computer.
final partsJobs = PartsJobs();

/// A stage in a few words, as a row says it.
String stageLine(PartsJob j) {
  String mb(int b) => (b / 1048576).toStringAsFixed(b < 10485760 ? 1 : 0);
  String clock(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '${s}s';
  }

  switch (j.stage) {
    case PartsStage.waiting:
      final place = partsJobs.placeOf(j.trackId);
      return place == null ? 'Waiting' : place == 1 ? 'Next' : 'Waiting · $place in line';
    case PartsStage.fetching:
      return j.bytes == null
          ? 'Fetching the record'
          : 'Fetching the record · ${mb(j.bytes!)}${j.total == null ? '' : ' of ${mb(j.total!)}'} MB';
    case PartsStage.gettingSeparator:
      return j.bytes == null
          ? 'Getting the separator'
          : 'Getting the separator · ${mb(j.bytes!)}${j.total == null ? '' : ' of ${mb(j.total!)}'} MB';
    case PartsStage.separating:
      final p = j.progress;
      final left = j.left;
      if (!j.trained) return 'Taking apart (simple)';
      return p == null
          ? 'Taking apart'
          : 'Taking apart · ${(p * 100).floor()}%${left == null ? '' : ' · ${clock(left)} left'}';
    case PartsStage.pooled:
      final p = j.progress;
      return j.device == null
          ? 'In the pool · waiting for a computer to take it apart'
          : 'Being taken apart on ${j.device}${p == null ? '' : ' · ${(p * 100).floor()}%'}';
    case PartsStage.ready:
      final took = j.took;
      final at = j.finished!;
      return 'Ready ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'
          '${took == null ? '' : ' · took ${clock(took)}'}${j.trained ? '' : ' · simple'}';
    case PartsStage.failed:
      return j.error == null ? 'Failed' : 'Failed · ${j.error}';
    case PartsStage.cancelled:
      return 'Cancelled';
  }
}
