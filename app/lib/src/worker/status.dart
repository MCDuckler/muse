import 'downloader.dart';

/// What the downloader is doing, as something that can be written down.
///
/// The page in the app draws from this whichever program is doing the fetching: read
/// straight off the downloader when it is the app's own, read out of a file when it is
/// the windowless one's. One shape for both is what keeps the page from having two
/// ideas of what "fetching three songs" looks like.
class FetchStatus {
  const FetchStatus({
    required this.state,
    this.problem,
    this.missing = const [],
    this.slots = 0,
    this.coolingUntil,
    this.inFlight = const [],
    this.done = 0,
    this.failed = 0,
    this.log = const [],
    this.pid,
    this.at,
  });

  final DownloaderState state;
  final String? problem;

  /// The programs that could not be found, where that is the problem.
  final List<String> missing;
  final int slots;
  final DateTime? coolingUntil;
  final List<({String videoId, String stage, double? percent, String? speed})> inFlight;
  final int done;
  final int failed;
  final List<String> log;

  /// Whose this is and when it was said, for a status that came out of a file: a file
  /// goes on saying "fetching" long after the program that wrote it has died.
  final int? pid;
  final DateTime? at;

  bool get running => state != DownloaderState.off &&
      state != DownloaderState.noTools &&
      state != DownloaderState.refused;

  /// Said within the last [within]: the program that wrote it is still there.
  bool fresh({Duration within = const Duration(seconds: 20), DateTime? now}) =>
      at != null && (now ?? DateTime.now()).difference(at!) < within;

  factory FetchStatus.of(Downloader d, {int? pid}) => FetchStatus(
        state: d.state,
        problem: d.problem,
        missing: d.state == DownloaderState.noTools ? (d.tools?.missing ?? const []) : const [],
        slots: d.slots,
        coolingUntil: d.coolingUntil,
        inFlight: [
          for (final f in d.inFlight.values)
            (videoId: f.job.videoId, stage: f.stage, percent: f.percent, speed: f.speed)
        ],
        done: d.done,
        failed: d.failed,
        log: d.log.length > 60 ? d.log.sublist(d.log.length - 60) : List.of(d.log),
        pid: pid,
        at: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'state': state.name,
        'problem': problem,
        'missing': missing,
        'slots': slots,
        'cooling_until': coolingUntil?.toUtc().toIso8601String(),
        'in_flight': [
          for (final f in inFlight)
            {'video_id': f.videoId, 'stage': f.stage, 'percent': f.percent, 'speed': f.speed}
        ],
        'done': done,
        'failed': failed,
        'log': log,
        'pid': pid,
        'at': at?.toUtc().toIso8601String(),
      };

  /// Null for anything that is not a status: a file half written, or somebody else's.
  static FetchStatus? fromJson(Object? j) {
    if (j is! Map) return null;
    final state = DownloaderState.values.where((s) => s.name == j['state']).firstOrNull;
    if (state == null) return null;
    DateTime? when(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return FetchStatus(
      state: state,
      problem: j['problem'] as String?,
      missing: [for (final m in (j['missing'] as List?) ?? const []) '$m'],
      slots: (j['slots'] as num?)?.toInt() ?? 0,
      coolingUntil: when(j['cooling_until']),
      inFlight: [
        for (final f in (j['in_flight'] as List?) ?? const [])
          if (f is Map)
            (
              videoId: '${f['video_id'] ?? ''}',
              stage: '${f['stage'] ?? ''}',
              percent: (f['percent'] as num?)?.toDouble(),
              speed: f['speed'] as String?,
            )
      ],
      done: (j['done'] as num?)?.toInt() ?? 0,
      failed: (j['failed'] as num?)?.toInt() ?? 0,
      log: [for (final l in (j['log'] as List?) ?? const []) '$l'],
      pid: (j['pid'] as num?)?.toInt(),
      at: when(j['at']),
    );
  }
}
